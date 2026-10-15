# One microservice on ECS Fargate: task definition (+ a one-off migration task), service with
# Service Connect, optional public routes on the shared ALB, autoscaling, IAM, logs and alarms.
#
# Deployments are rolling with the ECS circuit breaker: if new tasks do not become healthy, ECS rolls
# back to the previous task definition by itself. Images are tagged with the git SHA (immutable ECR
# tags), so "roll back to X" is exact. CI deploys by registering a new task definition revision
# (only the image changes); Terraform ignores that drift (lifecycle below).

variable "name" {
  description = "Service name, e.g. order-service."
  type        = string
}

variable "env_name" {
  description = "Prefix, e.g. prod-ecommerce."
  type        = string
}

variable "cluster_arn" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "namespace_arn" {
  type = string
}

variable "image" {
  description = "Repository URL; the tag comes from var.image_tag."
  type        = string
}

variable "image_tag" {
  description = "Initial image tag (CI deploys later revisions)."
  type        = string
  default     = "bootstrap"
}

variable "port" {
  type = number
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "min_count" {
  type    = number
  default = 2
}

variable "max_count" {
  type    = number
  default = 6
}

variable "environment" {
  description = "Plain (non-secret) environment variables."
  type        = map(string)
  default     = {}
}

variable "secret_keys" {
  description = "Environment variable names read from the service's Secrets Manager secret (JSON keys of the same name)."
  type        = list(string)
  default     = []
}

variable "task_policy_json" {
  description = "IAM policy for the task role (e.g. the messaging module's per-service policy)."
  type        = string
  default     = null
}

variable "attach_task_policy" {
  description = "Whether task_policy_json is set. A plain bool because the policy JSON is only known at apply time, and `count` must be known at plan time."
  type        = bool
  default     = false
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "public_paths" {
  description = "Path patterns routed from the public ALB (empty = internal only)."
  type        = list(string)
  default     = []
}

variable "listener_arn" {
  type    = string
  default = null
}

variable "listener_priority" {
  description = "First ALB rule priority for this service (it uses one per 5 paths)."
  type        = number
  default     = 100
}

variable "vpc_id" {
  type = string
}

variable "alb_arn_suffix" {
  type    = string
  default = null
}

variable "has_migrations" {
  description = "Create a one-off migration task definition (the image's `migrate` target)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "alarm_topic_arn" {
  type = string
}

variable "run_as" {
  description = "uid:gid the container runs as, enforced by ECS even if an image regressed to root (node images: 1000; product-service: 10001)."
  type        = string
  default     = "1000:1000"
  validation {
    condition     = !startswith(var.run_as, "0:") && var.run_as != "0"
    error_message = "Containers never run as root."
  }
}

variable "use_spot" {
  description = "Run on Fargate Spot (dev/staging: ~70% cheaper, tasks may be reclaimed)."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_region" "current" {}

locals {
  full_name   = "${var.env_name}-${var.name}"
  public      = length(var.public_paths) > 0
  path_chunks = chunklist(var.public_paths, 5) # an ALB rule takes at most 5 path values
  secrets = [for k in var.secret_keys : {
    name      = k
    valueFrom = "${aws_secretsmanager_secret.this.arn}:${k}::"
  }]
  log_config = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.this.name
      awslogs-region        = data.aws_region.current.region
      awslogs-stream-prefix = var.name
    }
  }
}

# ---- secret (container only: VALUES are never managed by Terraform) ------------------------------
resource "aws_secretsmanager_secret" "this" {
  name        = "${var.env_name}/${var.name}"
  description = "Runtime secrets of ${var.name} (JSON). Keys: ${join(", ", var.secret_keys)}. Set with the AWS CLI, never in Terraform."
  tags        = var.tags
}

# ---- logs -------------------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.full_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---- IAM --------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: what ECS needs to START the task (pull the image, read THIS service's secret, logs).
resource "aws_iam_role" "execution" {
  name               = "${local.full_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secret" {
  statement {
    sid       = "ReadOwnSecretOnly"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.this.arn]
  }
}

resource "aws_iam_role_policy" "execution_secret" {
  name   = "read-own-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secret.json
}

# Task role: what the APPLICATION may do (publish its topic, consume its queues: least privilege).
resource "aws_iam_role" "task" {
  name               = "${local.full_name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "task" {
  count  = var.attach_task_policy ? 1 : 0
  name   = "messaging"
  role   = aws_iam_role.task.id
  policy = var.task_policy_json
}

# ---- task definitions -------------------------------------------------------------------------------
resource "aws_ecs_task_definition" "this" {
  family                   = local.full_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # Graviton: ~20% cheaper; images are built multi-arch in CI
  }
  container_definitions = jsonencode([{
    name                   = var.name
    image                  = "${var.image}:${var.image_tag}"
    essential              = true
    readonlyRootFilesystem = true # the app writes only to stdout; /tmp is a tmpfs-like ephemeral mount
    user                   = var.run_as
    linuxParameters        = { initProcessEnabled = true }
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    portMappings           = [{ name = var.name, containerPort = var.port, protocol = "tcp", appProtocol = "http" }]
    environment            = [for k, v in merge({ NODE_ENV = "production", PORT = tostring(var.port) }, var.environment) : { name = k, value = v }]
    secrets                = local.secrets
    healthCheck = {
      command     = ["CMD-SHELL", "wget -qO- http://127.0.0.1:${var.port}/health/live >/dev/null || exit 1"]
      interval    = 15
      timeout     = 3
      retries     = 3
      startPeriod = 20
    }
    stopTimeout      = 30 # SIGTERM → graceful shutdown (each service drains within SHUTDOWN_TIMEOUT_MS)
    logConfiguration = local.log_config
  }])
  volume {
    name = "tmp"
  }
  tags = var.tags

  lifecycle {
    # CI registers new revisions (new image); Terraform must not roll them back.
    ignore_changes = [container_definitions]
  }
}

resource "aws_ecs_task_definition" "migrate" {
  count                    = var.has_migrations ? 1 : 0
  family                   = "${local.full_name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
  container_definitions = jsonencode([{
    name             = "${var.name}-migrate"
    image            = "${var.image}:${var.image_tag}-migrate"
    essential        = true
    user             = var.run_as
    environment      = [{ name = "NODE_ENV", value = "production" }]
    secrets          = local.secrets
    logConfiguration = merge(local.log_config, { options = merge(local.log_config.options, { awslogs-stream-prefix = "${var.name}-migrate" }) })
  }])
  tags = var.tags

  lifecycle {
    ignore_changes = [container_definitions]
  }
}

# ---- load balancer (public paths only) --------------------------------------------------------------
resource "aws_lb_target_group" "this" {
  count                = local.public ? 1 : 0
  name                 = substr(replace(local.full_name, "ecommerce-", ""), 0, 32)
  port                 = var.port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
  health_check {
    path                = "/health/ready"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = var.tags
}

resource "aws_lb_listener_rule" "this" {
  count        = local.public ? length(local.path_chunks) : 0
  listener_arn = var.listener_arn
  priority     = var.listener_priority + count.index
  condition {
    path_pattern {
      values = local.path_chunks[count.index]
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }
  tags = var.tags
}

# ---- service ----------------------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  name                               = var.name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.desired_count
  deployment_minimum_healthy_percent = 100 # never below capacity during a deploy
  deployment_maximum_percent         = 200
  enable_execute_command             = false # no shell into production containers
  propagate_tags                     = "SERVICE"
  health_check_grace_period_seconds  = local.public ? 30 : null

  capacity_provider_strategy {
    capacity_provider = var.use_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true # unhealthy new tasks → ECS returns to the last good revision by itself
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = var.namespace_arn
    service {
      port_name      = var.name
      discovery_name = var.name
      client_alias {
        port     = var.port
        dns_name = var.name
      }
    }
  }

  dynamic "load_balancer" {
    for_each = local.public ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.name
      container_port   = var.port
    }
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count] # owned by CI and the autoscaler
  }

  tags = var.tags
}

# ---- autoscaling ------------------------------------------------------------------------------------
resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.full_name}-cpu"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  policy_type        = "TargetTrackingScaling"
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# ---- alarms -----------------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "running_tasks" {
  alarm_name          = "${local.full_name}-running-tasks-low"
  alarm_description   = "${var.name}: fewer running tasks than the minimum (crash loop, failed deploy, capacity)."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = aws_ecs_service.this.name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  threshold           = var.min_count
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "${local.full_name}-memory-high"
  alarm_description   = "${var.name}: memory above 85% (leak, or the task size is too small)."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = aws_ecs_service.this.name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  count               = local.public ? 1 : 0
  alarm_name          = "${local.full_name}-5xx"
  alarm_description   = "${var.name}: more than 5% of responses are 5xx."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 5
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
  metric_query {
    id          = "rate"
    expression  = "IF(requests > 20, 100 * errors / requests, 0)"
    label       = "5xx %"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = aws_lb_target_group.this[0].arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = aws_lb_target_group.this[0].arn_suffix }
      period      = 60
      stat        = "Sum"
    }
  }
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "latency" {
  count               = local.public ? 1 : 0
  alarm_name          = "${local.full_name}-p99-latency"
  alarm_description   = "${var.name}: p99 response time above 2 s."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = aws_lb_target_group.this[0].arn_suffix }
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 5
  threshold           = 2
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
  tags                = var.tags
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "task_definition_family" {
  value = aws_ecs_task_definition.this.family
}

output "migrate_task_definition_family" {
  value = var.has_migrations ? aws_ecs_task_definition.migrate[0].family : null
}

output "secret_arn" {
  value = aws_secretsmanager_secret.this.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.this.name
}
