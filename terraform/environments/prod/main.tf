# prod environment. Isolated AWS resources and isolated Terraform state.
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
      environment = "prod"
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
  default = "shop.example.com"
}

variable "alb_origin_domain" {
  type    = string
  default = "origin-api.shop.example.com"
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
  environment                 = "prod"
  domain                      = var.domain
  alb_origin_domain           = var.alb_origin_domain
  alb_certificate_arn         = var.alb_certificate_arn
  cloudfront_certificate_arn  = var.cloudfront_certificate_arn
  github_owner                = var.github_owner
  github_environment          = "production"
  create_github_oidc_provider = false # once per AWS account
  smtp_host                   = var.smtp_host
  alarm_emails                = var.alarm_emails
  admin_alert_emails          = var.admin_alert_emails
  size = {
    az_count          = 3
    nat_gateways      = 3
    multi_az_db       = true
    docdb_instances   = 2
    postgres_class    = "db.m7g.large"
    docdb_class       = "db.r6g.large"
    backup_days       = 14
    min_tasks         = 2
    max_tasks         = 10
    use_spot          = false
    log_retention     = 90
    protect_resources = true
  }
}

output "shop_url" { value = module.stack.shop_url }
output "cloudfront_domain" { value = module.stack.cloudfront_domain }
output "alb_dns_name" { value = module.stack.alb_dns_name }
output "deploy_role_arns" { value = module.stack.deploy_role_arns }
output "service_secret_arns" { value = module.stack.service_secret_arns }
output "cluster_name" { value = module.stack.cluster_name }
output "private_subnet_ids" { value = module.stack.private_subnet_ids }
output "tasks_security_group_id" { value = module.stack.tasks_security_group_id }
output "site_bucket" { value = module.stack.site_bucket }
