# Web application firewall in front of CloudFront (scope CLOUDFRONT: the provider passed in MUST be
# us-east-1). Rate limits here hold across every ECS task and survive deployments; the services' own
# in-memory limits (express-rate-limit) are per task and reset on deploy.

variable "name" {
  type = string
}

variable "auth_limit_per_5min" {
  description = "Requests per client IP per 5 minutes to /api/v1/auth/* (login, register, password reset)."
  type        = number
  default     = 100
}

variable "api_limit_per_5min" {
  description = "Requests per client IP per 5 minutes to /api/* overall."
  type        = number
  default     = 3000
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.name}-edge"
  description = "Managed protections and per-IP rate limits for the shop and its API"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-auth"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = var.auth_limit_per_5min
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/v1/auth/"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-auth"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-api"
    priority = 2
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = var.api_limit_per_5min
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-api"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = {
      AWSManagedRulesCommonRuleSet          = 10
      AWSManagedRulesKnownBadInputsRuleSet  = 11
      AWSManagedRulesAmazonIpReputationList = 12
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
          # The payment webhook and admin product descriptions carry large bodies; the common rule set's
          # 8 KB body limit would block them. Count instead of block for that one rule.
          dynamic "rule_action_override" {
            for_each = rule.key == "AWSManagedRulesCommonRuleSet" ? ["SizeRestrictions_BODY"] : []
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-edge"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

output "web_acl_arn" {
  value = aws_wafv2_web_acl.this.arn
}
