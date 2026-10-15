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

run "edge" {
  command = plan
  variables {
    name              = "prod-ecommerce"
    vpc_id            = "vpc-1"
    public_subnet_ids = ["subnet-a", "subnet-b"]
    certificate_arn   = "arn:aws:acm:ap-south-1:123456789012:certificate/alb"
    repositories      = ["auth-service", "order-service"]
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_https.prefix_list_id != null && aws_vpc_security_group_ingress_rule.alb_https.cidr_ipv4 == null
    error_message = "The ALB accepts traffic from CloudFront's prefix list only, never 0.0.0.0/0."
  }
  assert {
    condition     = anytrue([for c in aws_lb_listener_rule.block_internal.condition : anytrue([for pp in c.path_pattern : contains(pp.values, "/internal/*")])]) && aws_lb_listener_rule.block_internal.priority == 1
    error_message = "/internal/* is blocked at the public ALB, before any service rule."
  }
  assert {
    condition     = anytrue([for c in aws_lb_listener_rule.block_internal.condition : anytrue([for pp in c.path_pattern : contains(pp.values, "/mock-provider/*")])])
    error_message = "The mock payment page is unreachable from the internet."
  }
  assert {
    condition     = aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06" && aws_lb.api.drop_invalid_header_fields
    error_message = "TLS 1.2+ only; malformed headers dropped."
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_tag_mutability == "IMMUTABLE" && r.image_scanning_configuration[0].scan_on_push])
    error_message = "Immutable, scanned image tags (a tag always means the same image: exact rollbacks)."
  }
}
