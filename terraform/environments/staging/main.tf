# staging environment. Isolated AWS resources and isolated Terraform state.
# DO NOT apply without explicit approval. Initialise with:
#   terraform init -backend-config=backend.hcl
# where backend.hcl is created from backend.hcl.example.

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

variable "alarm_topic_arns" {
  type    = list(string)
  default = []
}

module "messaging" {
  source           = "../../modules/messaging"
  environment      = "staging"
  alarm_topic_arns = var.alarm_topic_arns
}

output "topic_arns" { value = module.messaging.topic_arns }
output "queue_urls" { value = module.messaging.queue_urls }
