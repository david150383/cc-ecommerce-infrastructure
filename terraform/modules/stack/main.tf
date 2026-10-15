# One complete environment of the platform. dev/staging/prod differ only in the variables they pass.
# Secret VALUES are never here: each service gets an empty Secrets Manager secret whose keys are listed
# below; they are filled with the AWS CLI (docs/architecture/deployment.md).

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "domain" {
  description = "Public hostname of the shop (and, under /api, of its API)."
  type        = string
}

variable "alb_origin_domain" {
  description = "Hostname CloudFront uses for the ALB (DNS → ALB, covered by alb_certificate_arn)."
  type        = string
}

variable "alb_certificate_arn" {
  description = "ACM certificate for alb_origin_domain, in the deployment region."
  type        = string
}

variable "cloudfront_certificate_arn" {
  description = "ACM certificate for domain, in us-east-1."
  type        = string
}

variable "github_owner" {
  type = string
}

variable "github_environment" {
  type = string
}

variable "create_github_oidc_provider" {
  type    = bool
  default = false
}

variable "alarm_emails" {
  type    = list(string)
  default = []
}

variable "admin_alert_emails" {
  type    = list(string)
  default = []
}

variable "email_from" {
  type    = string
  default = "Shop <no-reply@example.com>"
}

variable "smtp_host" {
  description = "e.g. email-smtp.ap-south-1.amazonaws.com (SES SMTP interface, STARTTLS on 587)."
  type        = string
}

variable "size" {
  description = "Capacity and resilience knobs per environment."
  type = object({
    az_count          = number
    nat_gateways      = number
    multi_az_db       = bool
    docdb_instances   = number
    postgres_class    = string
    docdb_class       = string
    backup_days       = number
    min_tasks         = number
    max_tasks         = number
    use_spot          = bool
    log_retention     = number
    protect_resources = bool
  })
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_region" "current" {}

locals {
  name   = "${var.environment}-ecommerce"
  origin = "https://${var.domain}"
  region = data.aws_region.current.region

  # One definition per service: port, public routes, configuration, secret keys.
  common = {
    LOG_LEVEL            = "info"
    AWS_REGION           = local.region
    CORS_ALLOWED_ORIGINS = local.origin
    JWT_ISSUER           = "ecommerce-auth-service"
    JWT_AUDIENCE         = "ecommerce-api"
    JWKS_URL             = "http://auth-service:4001/.well-known/jwks.json"
    MESSAGING_ENABLED    = "true"
  }
  topic = module.messaging.topic_arns
  queue = module.messaging.queue_names
  services = {
    auth-service = {
      port         = 4001
      public_paths = ["/api/v1/auth/*", "/api/v1/admin/users", "/api/v1/admin/users/*", "/.well-known/jwks.json"]
      env = {
        FRONTEND_BASE_URL        = local.origin
        NOTIFICATION_DELIVERY    = "http"
        NOTIFICATION_SERVICE_URL = "http://notification-service:4006"
        COOKIE_SECURE            = "true"
        TRUST_PROXY_HOPS         = "2" # CloudFront → ALB → task: rate limits must see the client address
        EVENTS_TOPIC_ARN         = local.topic["auth-events"]
      }
      secrets = ["DATABASE_URL", "JWT_SIGNING_KEYS", "SERVICE_CLIENTS"]
      run_as  = "1000:1000"
    }
    product-service = {
      port         = 4002
      public_paths = ["/api/v1/products", "/api/v1/products/*", "/api/v1/categories", "/api/v1/categories/*"]
      env          = { JWT_SERVICE_AUDIENCE = "ecommerce-product-service", MESSAGING_ENABLED = "false" }
      secrets      = ["DATABASE_URL"]
      run_as       = "10001:10001"
    }
    inventory-service = {
      port         = 4003
      public_paths = ["/api/v1/inventory", "/api/v1/inventory/*"]
      env = {
        JWT_SERVICE_AUDIENCE = "ecommerce-inventory-service"
        EVENTS_TOPIC_ARN     = local.topic["inventory-events"]
        COMMANDS_QUEUE_NAME  = local.queue["inventory-commands"]
      }
      secrets = ["DATABASE_URL"]
      run_as  = "1000:1000"
    }
    order-service = {
      port         = 4004
      public_paths = ["/api/v1/orders", "/api/v1/orders/*", "/api/v1/admin/orders", "/api/v1/admin/orders/*"]
      env = {
        JWT_SERVICE_AUDIENCE = "ecommerce-order-service"
        AUTH_SERVICE_URL     = "http://auth-service:4001"
        SERVICE_CLIENT_ID    = "ecommerce-order-service"
        PRODUCT_SERVICE_URL  = "http://product-service:4002"
        EVENTS_TOPIC_ARN     = local.topic["order-events"]
        COMMANDS_QUEUE_NAME  = local.queue["order-commands"]
      }
      secrets = ["MONGODB_URI", "SERVICE_CLIENT_SECRET"]
      run_as  = "1000:1000"
    }
    payment-service = {
      port = 4005
      # Webhooks come from the provider through the same origin; /mock-provider is blocked at the ALB.
      public_paths = ["/api/v1/payments", "/api/v1/payments/*", "/api/v1/admin/payments", "/api/v1/admin/payments/*"]
      env = {
        JWT_SERVICE_AUDIENCE = "ecommerce-payment-service"
        AUTH_SERVICE_URL     = "http://auth-service:4001"
        SERVICE_CLIENT_ID    = "ecommerce-payment-service"
        ORDER_SERVICE_URL    = "http://order-service:4004"
        PAYMENT_PROVIDER     = "stripe" # the mock is refused in production by the service itself
        PUBLIC_BASE_URL      = local.origin
        EVENTS_TOPIC_ARN     = local.topic["payment-events"]
        COMMANDS_QUEUE_NAME  = local.queue["payment-commands"]
      }
      secrets = ["DATABASE_URL", "SERVICE_CLIENT_SECRET", "STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"]
      run_as  = "1000:1000"
    }
    notification-service = {
      port         = 4006
      public_paths = ["/api/v1/notifications/*", "/api/v1/admin/notifications", "/api/v1/admin/notifications/*"]
      env = {
        JWT_SERVICE_AUDIENCE  = "ecommerce-notification-service"
        TRANSACTIONAL_CALLERS = "ecommerce-auth-service"
        SMTP_HOST             = var.smtp_host
        SMTP_PORT             = "587"
        EMAIL_FROM            = var.email_from
        ADMIN_ALERT_EMAILS    = join(",", var.admin_alert_emails)
        SHOP_BASE_URL         = local.origin
        COMMANDS_QUEUE_NAME   = local.queue["notification-commands"]
        INBOX_QUEUE_NAME      = local.queue["notification-inbox"]
        DLQ_NAMES             = "${local.name}-notification-commands-dlq,${local.name}-notification-inbox-dlq"
      }
      secrets = ["DATABASE_URL", "SMTP_USER", "SMTP_PASSWORD"]
      run_as  = "1000:1000"
    }
    saga-orchestrator = {
      port         = 4007
      public_paths = ["/api/v1/checkout", "/api/v1/checkout/*", "/api/v1/admin/sagas", "/api/v1/admin/sagas/*"]
      env = {
        JWT_SERVICE_AUDIENCE          = "ecommerce-saga-orchestrator"
        AUTH_SERVICE_URL              = "http://auth-service:4001"
        SERVICE_CLIENT_ID             = "ecommerce-saga-orchestrator"
        ORDER_SERVICE_URL             = "http://order-service:4004"
        PAYMENT_SERVICE_URL           = "http://payment-service:4005"
        FRONTEND_BASE_URL             = local.origin
        SAGA_INBOX_QUEUE_NAME         = local.queue["saga-inbox"]
        INVENTORY_COMMANDS_QUEUE_NAME = local.queue["inventory-commands"]
        ORDER_COMMANDS_QUEUE_NAME     = local.queue["order-commands"]
        PAYMENT_COMMANDS_QUEUE_NAME   = local.queue["payment-commands"]
        SAGA_EVENTS_TOPIC_ARN         = local.topic["saga-events"]
      }
      secrets = ["DATABASE_URL", "SERVICE_CLIENT_SECRET"]
      run_as  = "1000:1000"
    }
  }
  service_names = keys(local.services)
}

module "network" {
  source       = "../network"
  name         = local.name
  az_count     = var.size.az_count
  nat_gateways = var.size.nat_gateways
  tags         = var.tags
}

module "platform" {
  source              = "../platform"
  name                = local.name
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  certificate_arn     = var.alb_certificate_arn
  repositories        = toset(local.service_names)
  alarm_emails        = var.alarm_emails
  deletion_protection = var.size.protect_resources
  tags                = var.tags
}

module "messaging" {
  source           = "../messaging"
  environment      = var.environment
  alarm_topic_arns = [module.platform.alarm_topic_arn]
  tags             = var.tags
}

module "data" {
  source                    = "../data"
  name                      = local.name
  vpc_id                    = module.network.vpc_id
  private_subnet_ids        = module.network.private_subnet_ids
  client_security_group_ids = [module.platform.tasks_security_group_id]
  multi_az                  = var.size.multi_az_db
  docdb_instances           = var.size.docdb_instances
  postgres_instance_class   = var.size.postgres_class
  docdb_instance_class      = var.size.docdb_class
  backup_retention_days     = var.size.backup_days
  deletion_protection       = var.size.protect_resources
  alarm_topic_arn           = module.platform.alarm_topic_arn
  tags                      = var.tags
}

module "service" {
  source             = "../service"
  for_each           = local.services
  name               = each.key
  env_name           = local.name
  cluster_arn        = module.platform.cluster_arn
  cluster_name       = module.platform.cluster_name
  namespace_arn      = module.platform.namespace_arn
  image              = module.platform.repository_urls[each.key]
  port               = each.value.port
  environment        = merge(local.common, each.value.env)
  secret_keys        = each.value.secrets
  run_as             = each.value.run_as
  task_policy_json   = lookup(module.messaging.service_policy_json, each.key, null)
  attach_task_policy = lookup(each.value.env, "MESSAGING_ENABLED", "true") != "false" # every service but product-service uses SNS/SQS
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.platform.tasks_security_group_id]
  vpc_id             = module.network.vpc_id
  public_paths       = each.value.public_paths
  listener_arn       = module.platform.https_listener_arn
  listener_priority  = 100 + index(local.service_names, each.key) * 10
  alb_arn_suffix     = module.platform.alb_arn_suffix
  desired_count      = var.size.min_tasks
  min_count          = var.size.min_tasks
  max_count          = var.size.max_tasks
  use_spot           = var.size.use_spot
  log_retention_days = var.size.log_retention
  alarm_topic_arn    = module.platform.alarm_topic_arn
  tags               = var.tags
}

module "frontend" {
  source                    = "../frontend"
  name                      = local.name
  domain                    = var.domain
  certificate_arn_us_east_1 = var.cloudfront_certificate_arn
  alb_origin_domain         = var.alb_origin_domain
  tags                      = var.tags
}

module "github_oidc" {
  source             = "../github-oidc"
  env_name           = local.name
  github_owner       = var.github_owner
  github_environment = var.github_environment
  create_provider    = var.create_github_oidc_provider
  services = {
    for name, svc in module.service : name => {
      repository          = "ecommerce-${name}"
      ecr_repository_arn  = module.platform.repository_arns[name]
      cluster_arn         = module.platform.cluster_arn
      service_name        = svc.service_name
      task_family         = svc.task_definition_family
      migrate_task_family = svc.migrate_task_definition_family
      pass_role_arns      = [svc.task_role_arn, svc.execution_role_arn]
      log_group           = svc.log_group
    }
  }
  frontend = {
    repository       = "ecommerce-frontend"
    bucket_arn       = module.frontend.bucket_arn
    distribution_arn = module.frontend.distribution_arn
  }
  tags = var.tags
}

output "shop_url" {
  value = local.origin
}

output "cloudfront_domain" {
  description = "Point var.domain here (CNAME / ALIAS)."
  value       = module.frontend.distribution_domain_name
}

output "alb_dns_name" {
  description = "Point var.alb_origin_domain here."
  value       = module.platform.alb_dns_name
}

output "deploy_role_arns" {
  value = module.github_oidc.role_arns
}

output "service_secret_arns" {
  value = { for k, s in module.service : k => s.secret_arn }
}

output "postgres_endpoint" {
  value = module.data.postgres_endpoint
}

output "docdb_endpoint" {
  value = module.data.docdb_endpoint
}

output "site_bucket" {
  value = module.frontend.bucket_name
}

# For CI (GitHub environment variables): where one-off migration tasks run.
output "cluster_name" {
  value = module.platform.cluster_name
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "tasks_security_group_id" {
  value = module.platform.tasks_security_group_id
}
