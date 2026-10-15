# Shared per-environment platform: ECS cluster + Service Connect namespace, the public ALB, ECR
# repositories, the alarm topic, and the security groups tasks and the ALB use.

variable "name" {
  description = "Prefix, e.g. prod-ecommerce."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "certificate_arn" {
  description = "ACM certificate (same region) for the ALB's HTTPS listener."
  type        = string
}

variable "repositories" {
  description = "ECR repositories to create (one per deployable image)."
  type        = set(string)
}

variable "alarm_emails" {
  description = "Addresses subscribed to the alarm topic (each must confirm the subscription)."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---- ECS --------------------------------------------------------------------------------------------
resource "aws_service_discovery_http_namespace" "this" {
  name        = var.name
  description = "Service Connect namespace: services call each other by name (order-service:4004)."
  tags        = var.tags
}

resource "aws_ecs_cluster" "this" {
  name = var.name
  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.this.arn
  }
  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ---- security groups --------------------------------------------------------------------------------
# The API is reached only through CloudFront (same origin as the shop; see modules/frontend): the ALB
# accepts traffic from CloudFront's origin-facing addresses only, so it cannot be called directly.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "HTTPS from CloudFront only"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 4001
  to_port                      = 4007
}

resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks"
  description = "ECS tasks: from the ALB and from each other (Service Connect); egress to anything (NAT, endpoints, databases)"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 4001
  to_port                      = 4007
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_tasks" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 4001
  to_port                      = 4007
}

resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---- ALB --------------------------------------------------------------------------------------------
resource "aws_lb" "api" {
  name                       = substr("${var.name}-api", 0, 32)
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  idle_timeout               = 60
  tags                       = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  # Anything not matched by a service rule.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"type\":\"about:blank\",\"title\":\"Not Found\",\"status\":404,\"code\":\"NOT_FOUND\"}"
      status_code  = "404"
    }
  }
}

# Service-to-service routes never come in through the public load balancer (conventions.md).
resource "aws_lb_listener_rule" "block_internal" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 1
  condition {
    path_pattern {
      values = ["/internal/*", "/health/*", "/mock-provider/*"]
    }
  }
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"type\":\"about:blank\",\"title\":\"Not Found\",\"status\":404,\"code\":\"NOT_FOUND\"}"
      status_code  = "404"
    }
  }
}

# ---- ECR --------------------------------------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  for_each             = var.repositories
  name                 = "${var.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a tag (the git SHA) always means the same image: rollbacks are exact
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = var.repositories
  repository = aws_ecr_repository.this[each.key].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 30 images (enough to roll back weeks)"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}

# ---- alarms -----------------------------------------------------------------------------------------
resource "aws_sns_topic" "alarms" {
  name              = "${var.name}-alarms"
  kms_master_key_id = "alias/aws/sns"
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "alarm_email" {
  for_each  = toset(var.alarm_emails)
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.key
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  alarm_description   = "The load balancer itself returned 5xx (no healthy target, timeouts)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.api.arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  tags                = var.tags
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "namespace_arn" {
  value = aws_service_discovery_http_namespace.this.arn
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}

output "alb_arn_suffix" {
  value = aws_lb.api.arn_suffix
}

output "alb_dns_name" {
  value = aws_lb.api.dns_name
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "tasks_security_group_id" {
  value = aws_security_group.tasks.id
}

output "repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  value = { for k, r in aws_ecr_repository.this : k => r.arn }
}

output "alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

