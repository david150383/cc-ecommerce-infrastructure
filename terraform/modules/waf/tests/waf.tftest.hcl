# Plans this module with a MOCKED AWS provider (no credentials, no API calls) and asserts its guarantees.

mock_provider "aws" {
  override_during = plan
}

run "edge_protection" {
  command = plan
  variables {
    name = "prod-ecommerce"
  }
  assert {
    condition     = aws_wafv2_web_acl.this.scope == "CLOUDFRONT"
    error_message = "The ACL protects CloudFront (and must therefore be created in us-east-1)."
  }
  assert {
    condition     = one([for r in aws_wafv2_web_acl.this.rule : r.statement[0].rate_based_statement[0].limit if r.name == "rate-auth"]) == 100
    error_message = "Auth endpoints: 100 requests per IP per 5 minutes, across all tasks."
  }
  assert {
    condition     = length([for r in aws_wafv2_web_acl.this.rule : r if r.name == "rate-auth" && length(r.action[0].block) == 1]) == 1
    error_message = "Over the limit is blocked, not merely counted."
  }
  assert {
    condition     = toset([for r in aws_wafv2_web_acl.this.rule : r.name]) == toset(["rate-auth", "rate-api", "AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet", "AWSManagedRulesAmazonIpReputationList"])
    error_message = "Rate limits plus the AWS managed common, known-bad-inputs and IP-reputation rule sets."
  }
}
