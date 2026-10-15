terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
      # CloudFront-scoped resources (the WAF ACL) must be created in us-east-1.
      configuration_aliases = [aws.us_east_1]
    }
  }
}
