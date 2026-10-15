# Plans a WHOLE environment with a mocked AWS provider (no credentials, no API calls): proves the modules
# wire together and that nothing depends on values unknown before apply. Module guarantees are tested in
# each module's own tests/ directory.

mock_provider "aws" {
  override_during = plan
  mock_data "aws_availability_zones" {
    defaults = { names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"] }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-south-1", name = "ap-south-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_db_instance" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds", kms_key_id = "k", secret_status = "active" }] }
  }
  mock_resource "aws_docdb_cluster" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:docdb", kms_key_id = "k", secret_status = "active" }] }
  }
}

mock_provider "aws" {
  alias           = "us_east_1"
  override_during = plan
  mock_data "aws_availability_zones" {
    defaults = { names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"] }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-south-1", name = "ap-south-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_db_instance" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds", kms_key_id = "k", secret_status = "active" }] }
  }
  mock_resource "aws_docdb_cluster" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:docdb", kms_key_id = "k", secret_status = "active" }] }
  }
}

variables {
  environment                = "prod"
  domain                     = "shop.example.com"
  alb_origin_domain          = "origin-api.shop.example.com"
  alb_certificate_arn        = "arn:aws:acm:ap-south-1:123456789012:certificate/alb"
  cloudfront_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/cf"
  github_owner               = "example-org"
  github_environment         = "production"
  smtp_host                  = "email-smtp.ap-south-1.amazonaws.com"
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

run "prod_plans" {
  command = plan
  assert {
    condition     = length(output.service_secret_arns) == 7 && length(output.deploy_role_arns) == 8
    error_message = "Seven services (each with its own secret) and eight deploy roles (services + frontend)."
  }
  assert {
    condition     = output.shop_url == "https://shop.example.com"
    error_message = "The shop and its API share one HTTPS origin."
  }
}

run "dev_plans" {
  command = plan
  variables {
    environment        = "dev"
    github_environment = "dev"
    size = {
      az_count          = 2
      nat_gateways      = 1
      multi_az_db       = false
      docdb_instances   = 1
      postgres_class    = "db.t4g.micro"
      docdb_class       = "db.t4g.medium"
      backup_days       = 3
      min_tasks         = 1
      max_tasks         = 2
      use_spot          = true
      log_retention     = 14
      protect_resources = false
    }
  }
  assert {
    condition     = length(output.service_secret_arns) == 7
    error_message = "dev deploys the same seven services."
  }
}
