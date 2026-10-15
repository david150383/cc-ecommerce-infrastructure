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

run "least_privilege_deploy_roles" {
  command = plan
  variables {
    env_name           = "prod-ecommerce"
    github_environment = "production"
    github_owner       = "example-org"
    services = {
      order-service = {
        repository          = "ecommerce-order-service"
        ecr_repository_arn  = "arn:aws:ecr:ap-south-1:123456789012:repository/prod-ecommerce/order-service"
        cluster_arn         = "arn:aws:ecs:ap-south-1:123456789012:cluster/prod-ecommerce"
        service_name        = "order-service"
        task_family         = "prod-ecommerce-order-service"
        migrate_task_family = "prod-ecommerce-order-service-migrate"
        pass_role_arns      = ["arn:aws:iam::123456789012:role/task", "arn:aws:iam::123456789012:role/exec"]
        log_group           = "/ecs/prod-ecommerce-order-service"
      }
    }
    frontend = {
      repository       = "ecommerce-frontend"
      bucket_arn       = "arn:aws:s3:::site"
      distribution_arn = "arn:aws:cloudfront::123456789012:distribution/E1"
    }
  }
  assert {
    condition     = length(aws_iam_role.deploy) == 2
    error_message = "One role per repository."
  }
  assert {
    condition = alltrue([for k, d in data.aws_iam_policy_document.trust : anytrue([
      for c in d.statement[0].condition : c.variable == "token.actions.githubusercontent.com:sub" && c.test == "StringEquals" &&
      length(c.values) == 1 && endswith(c.values[0], ":environment:production") && startswith(c.values[0], "repo:example-org/ecommerce-")
    ])])
    error_message = "A role is assumable only from its own repository, in the protected GitHub environment (exact match, no wildcards)."
  }
  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.service["order-service"].statement :
    s.sid == "PushOwnImages" && s.resources == toset(["arn:aws:ecr:ap-south-1:123456789012:repository/prod-ecommerce/order-service"])])
    error_message = "A service pipeline pushes to its own repository only."
  }
  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.service["order-service"].statement :
    s.sid == "PassOwnRolesToEcsOnly" && anytrue([for c in s.condition : c.variable == "iam:PassedToService" && contains(c.values, "ecs-tasks.amazonaws.com")])])
    error_message = "iam:PassRole is limited to the service's own roles, passed to ECS tasks only."
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "The OIDC provider is created once per account (create_provider)."
  }
}
