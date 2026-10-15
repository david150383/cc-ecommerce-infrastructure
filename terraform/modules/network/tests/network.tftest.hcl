# Plans this module with a MOCKED AWS provider (no credentials, no API calls) and asserts its guarantees.

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

run "prod_three_azs_nat_per_az" {
  command = plan
  variables {
    name         = "prod-ecommerce"
    az_count     = 3
    nat_gateways = 3
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 3 && length(aws_subnet.private) == 3 && length(aws_subnet.public) == 3
    error_message = "prod: three AZs, one NAT each."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "Nothing gets a public IP implicitly."
  }
  assert {
    condition     = length(aws_vpc_endpoint.interface) == 6 && aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway"
    error_message = "ECR, logs, Secrets Manager, SNS, SQS (interface) and S3 (gateway) endpoints: AWS traffic stays off the NAT."
  }
}

run "dev_shares_one_nat" {
  command = plan
  variables {
    name         = "dev-ecommerce"
    az_count     = 2
    nat_gateways = 1
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 1 && alltrue([for r in aws_route_table.private : r.route != null])
    error_message = "dev: one shared NAT."
  }
}
