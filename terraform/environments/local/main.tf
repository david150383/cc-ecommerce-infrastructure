# Applies the real messaging module to Floci, the local AWS emulator (no AWS account involved).
#   terraform init && terraform apply
# Requires `docker compose up -d floci` from the repository root.

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "local" {}
}

variable "aws_endpoint" {
  description = "Floci endpoint: http://localhost:4566 from your machine, http://floci:4566 from the compose network."
  type        = string
  default     = "http://localhost:4566"
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    sns        = var.aws_endpoint
    sqs        = var.aws_endpoint
    sts        = var.aws_endpoint
    iam        = var.aws_endpoint
    cloudwatch = var.aws_endpoint
  }
}

module "messaging" {
  source        = "../../modules/messaging"
  environment   = "local"
  create_alarms = false
  tags          = { project = "ecommerce", environment = "local" }
}

output "topic_arns" { value = module.messaging.topic_arns }
output "queue_urls" { value = module.messaging.queue_urls }
