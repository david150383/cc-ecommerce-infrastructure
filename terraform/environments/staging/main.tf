# staging environment. Isolated AWS resources and isolated Terraform state.
# DO NOT apply without explicit approval. Initialise with:
#   terraform init -backend-config=backend.hcl
# where backend.hcl is created from backend.hcl.example. Inputs: terraform.tfvars (see the example).

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration; bucket/key/region come from backend.hcl.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project     = "ecommerce"
      environment = "staging"
      managed-by  = "terraform"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "domain" {
  type    = string
  default = "staging.shop.example.com"
}

variable "alb_origin_domain" {
  type    = string
  default = "origin-api.staging.shop.example.com"
}

variable "alb_certificate_arn" {
  description = "ACM certificate for alb_origin_domain in aws_region."
  type        = string
}

variable "cloudfront_certificate_arn" {
  description = "ACM certificate for domain in us-east-1."
  type        = string
}

variable "github_owner" {
  type = string
}

variable "smtp_host" {
  type    = string
  default = "email-smtp.ap-south-1.amazonaws.com"
}

variable "alarm_emails" {
  type    = list(string)
  default = []
}

variable "admin_alert_emails" {
  type    = list(string)
  default = []
}

module "stack" {
  source                      = "../../modules/stack"
  environment                 = "staging"
  domain                      = var.domain
  alb_origin_domain           = var.alb_origin_domain
  alb_certificate_arn         = var.alb_certificate_arn
  cloudfront_certificate_arn  = var.cloudfront_certificate_arn
  github_owner                = var.github_owner
  github_environment          = "staging"
  create_github_oidc_provider = false # once per AWS account
  smtp_host                   = var.smtp_host
  alarm_emails                = var.alarm_emails
  admin_alert_emails          = var.admin_alert_emails
  size = {
    az_count          = 2
    nat_gateways      = 1
    multi_az_db       = false
    docdb_instances   = 1
    postgres_class    = "db.t4g.small"
    docdb_class       = "db.t4g.medium"
    backup_days       = 7
    min_tasks         = 1
    max_tasks         = 4
    use_spot          = true
    log_retention     = 30
    protect_resources = true
  }
}

output "shop_url" { value = module.stack.shop_url }
output "cloudfront_domain" { value = module.stack.cloudfront_domain }
output "alb_dns_name" { value = module.stack.alb_dns_name }
output "deploy_role_arns" { value = module.stack.deploy_role_arns }
output "service_secret_arns" { value = module.stack.service_secret_arns }
