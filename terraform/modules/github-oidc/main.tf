# CI/CD access without long-lived AWS keys: GitHub Actions exchanges its OIDC token for a short-lived
# role session. One role per repository and environment, assumable ONLY by workflows of that repository
# running in that GitHub environment (prod: protected by required reviewers in GitHub), and allowed to do
# only that repository's deployment.

variable "env_name" {
  description = "Prefix, e.g. prod-ecommerce."
  type        = string
}

variable "github_environment" {
  description = "GitHub environment name the workflows must run in (dev, staging, production)."
  type        = string
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the repositories."
  type        = string
}

variable "create_provider" {
  description = "The OIDC provider exists once per AWS account: create it in one environment only."
  type        = bool
  default     = false
}

variable "services" {
  description = "Per deployable service: its repository and the resources its pipeline may touch."
  type = map(object({
    repository          = string
    ecr_repository_arn  = string
    cluster_arn         = string
    service_name        = string
    task_family         = string
    migrate_task_family = optional(string)
    pass_role_arns      = list(string)
    log_group           = string
  }))
}

variable "frontend" {
  type = object({
    repository       = string
    bucket_arn       = string
    distribution_arn = string
  })
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  issuer  = "token.actions.githubusercontent.com"
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_provider ? 1 : 0
  url            = "https://${local.issuer}"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

locals {
  provider_arn = var.create_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${local.account}:oidc-provider/${local.issuer}"
}

data "aws_iam_policy_document" "trust" {
  for_each = merge({ for k, v in var.services : k => v.repository }, { frontend = var.frontend.repository })
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Exactly this repository, exactly this GitHub environment: a fork, another branch's workflow
    # without the environment, or another repository cannot assume it.
    condition {
      test     = "StringEquals"
      variable = "${local.issuer}:sub"
      values   = ["repo:${var.github_owner}/${each.value}:environment:${var.github_environment}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each             = data.aws_iam_policy_document.trust
  name                 = "${var.env_name}-deploy-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
  tags                 = var.tags
}

# ---- service pipelines ------------------------------------------------------------------------------
data "aws_iam_policy_document" "service" {
  for_each = var.services

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # account-level call, no resource
  }
  statement {
    sid = "PushOwnImages"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:DescribeImages",
      "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = [each.value.ecr_repository_arn]
  }
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"] # RegisterTaskDefinition supports no resource-level permissions
  }
  statement {
    sid       = "DeployOwnService"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = ["arn:aws:ecs:${local.region}:${local.account}:service/${split("/", each.value.cluster_arn)[1]}/${each.value.service_name}"]
  }
  dynamic "statement" {
    for_each = each.value.migrate_task_family == null ? [] : [1]
    content {
      sid       = "RunOwnMigrations"
      actions   = ["ecs:RunTask"]
      resources = ["arn:aws:ecs:${local.region}:${local.account}:task-definition/${each.value.migrate_task_family}:*"]
      condition {
        test     = "ArnEquals"
        variable = "ecs:cluster"
        values   = [each.value.cluster_arn]
      }
    }
  }
  statement {
    sid       = "WatchTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = ["arn:aws:ecs:${local.region}:${local.account}:task/${split("/", each.value.cluster_arn)[1]}/*"]
  }
  statement {
    sid       = "PassOwnRolesToEcsOnly"
    actions   = ["iam:PassRole"]
    resources = each.value.pass_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    sid       = "ReadOwnLogs"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account}:log-group:${each.value.log_group}:*"]
  }
}

resource "aws_iam_role_policy" "service" {
  for_each = var.services
  name     = "deploy"
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.service[each.key].json
}

# ---- frontend pipeline ------------------------------------------------------------------------------
data "aws_iam_policy_document" "frontend" {
  statement {
    sid       = "UploadSite"
    actions   = ["s3:ListBucket"]
    resources = [var.frontend.bucket_arn]
  }
  statement {
    sid       = "WriteSiteObjects"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"]
    resources = ["${var.frontend.bucket_arn}/*"]
  }
  statement {
    sid       = "Invalidate"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [var.frontend.distribution_arn]
  }
}

resource "aws_iam_role_policy" "frontend" {
  name   = "deploy"
  role   = aws_iam_role.deploy["frontend"].id
  policy = data.aws_iam_policy_document.frontend.json
}

output "role_arns" {
  description = "Set as AWS_DEPLOY_ROLE_ARN in each repository's GitHub environment."
  value       = { for k, r in aws_iam_role.deploy : k => r.arn }
}
