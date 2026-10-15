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
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:prod-ecommerce/payment-service-AbCdEf" }
  }
  mock_resource "aws_db_instance" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds", kms_key_id = "k", secret_status = "active" }] }
  }
  mock_resource "aws_docdb_cluster" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-south-1:123456789012:secret:docdb", kms_key_id = "k", secret_status = "active" }] }
  }
}

variables {
  name               = "payment-service"
  env_name           = "prod-ecommerce"
  cluster_arn        = "arn:aws:ecs:ap-south-1:123456789012:cluster/prod-ecommerce"
  cluster_name       = "prod-ecommerce"
  namespace_arn      = "arn:aws:servicediscovery:ap-south-1:123456789012:namespace/ns-1"
  image              = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/prod-ecommerce/payment-service"
  port               = 4005
  subnet_ids         = ["subnet-a", "subnet-b"]
  security_group_ids = ["sg-tasks"]
  vpc_id             = "vpc-1"
  alarm_topic_arn    = "arn:aws:sns:ap-south-1:123456789012:alarms"
  environment        = { PAYMENT_PROVIDER = "stripe", ORDER_SERVICE_URL = "http://order-service:4004" }
  secret_keys        = ["DATABASE_URL", "STRIPE_SECRET_KEY"]
  public_paths       = ["/api/v1/payments", "/api/v1/payments/*", "/api/v1/admin/payments", "/api/v1/admin/payments/*", "/api/v1/extra", "/api/v1/extra/*"]
  listener_arn       = "arn:aws:elasticloadbalancing:ap-south-1:123456789012:listener/app/x/1/2"
  alb_arn_suffix     = "app/x/1"
  attach_task_policy = true
  task_policy_json   = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
}

run "hardened_service" {
  command = plan
  assert {
    condition     = aws_ecs_service.this.deployment_circuit_breaker[0].enable && aws_ecs_service.this.deployment_circuit_breaker[0].rollback
    error_message = "A failed deployment rolls back automatically."
  }
  assert {
    condition     = aws_ecs_service.this.deployment_minimum_healthy_percent == 100
    error_message = "Rolling deploys never drop below current capacity."
  }
  assert {
    condition     = !aws_ecs_service.this.enable_execute_command && !aws_ecs_service.this.network_configuration[0].assign_public_ip
    error_message = "No shell into containers; no public IPs."
  }
  assert {
    condition = alltrue([for c in jsondecode(aws_ecs_task_definition.this.container_definitions) :
    c.readonlyRootFilesystem && c.user == "1000:1000" && c.linuxParameters.initProcessEnabled])
    error_message = "Read-only root filesystem, non-root user, init process (signals reach the app)."
  }
  assert {
    condition = alltrue([for c in jsondecode(aws_ecs_task_definition.this.container_definitions) :
      toset([for x in c.secrets : x.name]) == toset(["DATABASE_URL", "STRIPE_SECRET_KEY"]) &&
      alltrue([for x in c.secrets : startswith(x.valueFrom, aws_secretsmanager_secret.this.arn)]) &&
      !contains([for e in c.environment : e.name], "STRIPE_SECRET_KEY")
    ])
    error_message = "Secrets are injected from this service's own secret, never as plain environment values."
  }
  assert {
    condition     = strcontains(aws_ecs_task_definition.this.container_definitions, "\"NODE_ENV\",\"value\":\"production\"")
    error_message = "Containers run with NODE_ENV=production (which refuses dev-only settings such as the mock provider)."
  }
  assert {
    condition     = length(aws_lb_listener_rule.this) == 2
    error_message = "Six public paths need two ALB rules."
  }
  assert {
    condition     = sum([for c in aws_lb_listener_rule.this[0].condition : sum([for pp in c.path_pattern : length(pp.values)])]) == 5
    error_message = "An ALB rule holds at most 5 path patterns."
  }
  assert {
    condition     = aws_lb_target_group.this[0].health_check[0].path == "/health/ready"
    error_message = "The load balancer routes only to READY tasks (database reachable, not shutting down)."
  }
  assert {
    condition     = length(aws_iam_role_policy.task) == 1 && length(aws_ecs_task_definition.migrate) == 1
    error_message = "Task role gets the messaging policy; a migration task exists."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.target_5xx) == 1 && length(aws_cloudwatch_metric_alarm.latency) == 1
    error_message = "Public services alarm on 5xx rate and p99 latency."
  }
}

run "internal_only_service_has_no_public_route" {
  command = plan
  variables {
    public_paths = []
  }
  assert {
    condition     = length(aws_lb_target_group.this) == 0 && length(aws_lb_listener_rule.this) == 0 && length(aws_cloudwatch_metric_alarm.target_5xx) == 0
    error_message = "No public paths: no target group, no ALB rule."
  }
}

run "root_is_refused" {
  command = plan
  variables {
    run_as = "0:0"
  }
  expect_failures = [var.run_as]
}
