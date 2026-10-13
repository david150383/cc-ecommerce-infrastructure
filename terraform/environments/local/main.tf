# Applies the real messaging module to LocalStack (no AWS account involved).
#   terraform init && terraform apply
# Requires `docker compose up -d localstack` from the repository root.

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

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    sns        = "http://localhost:4566"
    sqs        = "http://localhost:4566"
    sts        = "http://localhost:4566"
    iam        = "http://localhost:4566"
    cloudwatch = "http://localhost:4566"
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
