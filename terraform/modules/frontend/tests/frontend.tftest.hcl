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

run "one_origin_cdn" {
  command = plan
  variables {
    name                      = "prod-ecommerce"
    domain                    = "shop.example.com"
    certificate_arn_us_east_1 = "arn:aws:acm:us-east-1:123456789012:certificate/cf"
    alb_origin_domain         = "origin-api.shop.example.com"
  }
  assert {
    condition = (aws_s3_bucket_public_access_block.site.block_public_acls && aws_s3_bucket_public_access_block.site.block_public_policy &&
    aws_s3_bucket_public_access_block.site.ignore_public_acls && aws_s3_bucket_public_access_block.site.restrict_public_buckets)
    error_message = "The site bucket is private (CloudFront reads it through origin access control)."
  }
  assert {
    condition     = length(aws_cloudfront_distribution.this.custom_error_response) == 0
    error_message = "No distribution-wide error rewriting: it would turn the API's 404s into the SPA's index.html."
  }
  assert {
    condition     = toset([for b in aws_cloudfront_distribution.this.ordered_cache_behavior : b.path_pattern]) == toset(["/api/*", "/.well-known/*"])
    error_message = "Only /api/* and /.well-known/* go to the API."
  }
  assert {
    condition     = alltrue([for b in aws_cloudfront_distribution.this.ordered_cache_behavior : b.viewer_protocol_policy == "https-only" && b.target_origin_id == "api" && contains(b.allowed_methods, "POST")])
    error_message = "API behaviors: HTTPS only, all methods forwarded to the ALB."
  }
  assert {
    condition     = one([for o in aws_cloudfront_distribution.this.origin : o.custom_origin_config[0].origin_protocol_policy if o.origin_id == "api"]) == "https-only"
    error_message = "CloudFront talks to the ALB over HTTPS only."
  }
  assert {
    condition     = strcontains(aws_cloudfront_response_headers_policy.site.security_headers_config[0].content_security_policy[0].content_security_policy, "connect-src 'self'")
    error_message = "CSP: the app may call its own origin only."
  }
  assert {
    condition     = aws_cloudfront_distribution.this.viewer_certificate[0].minimum_protocol_version == "TLSv1.2_2021"
    error_message = "TLS 1.2+ for visitors."
  }
}
