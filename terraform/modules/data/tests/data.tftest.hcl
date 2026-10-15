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

variables {
  name                      = "prod-ecommerce"
  vpc_id                    = "vpc-1"
  private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
  client_security_group_ids = ["sg-tasks"]
  alarm_topic_arn           = "arn:aws:sns:ap-south-1:123456789012:alarms"
}

run "prod" {
  command = plan
  variables {
    multi_az              = true
    docdb_instances       = 2
    backup_retention_days = 14
    deletion_protection   = true
  }
  assert {
    condition = (
      aws_db_instance.postgres.storage_encrypted && !aws_db_instance.postgres.publicly_accessible &&
      aws_db_instance.postgres.manage_master_user_password && aws_db_instance.postgres.multi_az &&
      aws_db_instance.postgres.deletion_protection && !aws_db_instance.postgres.skip_final_snapshot &&
      aws_db_instance.postgres.backup_retention_period == 14
    )
    error_message = "prod PostgreSQL: encrypted, private, RDS-managed password, Multi-AZ, protected, final snapshot, 14-day backups."
  }
  assert {
    condition     = one([for p in aws_db_parameter_group.postgres.parameter : p.value if p.name == "rds.force_ssl"]) == "1"
    error_message = "PostgreSQL requires TLS."
  }
  assert {
    condition     = aws_docdb_cluster.this.storage_encrypted && aws_docdb_cluster.this.deletion_protection && aws_docdb_cluster.this.manage_master_user_password && length(aws_docdb_cluster_instance.this) == 2
    error_message = "prod DocumentDB: encrypted, protected, managed password, one replica."
  }
  assert {
    condition     = one([for p in aws_docdb_cluster_parameter_group.this.parameter : p.value if p.name == "tls"]) == "enabled"
    error_message = "DocumentDB requires TLS."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.postgres) == 1 && aws_vpc_security_group_ingress_rule.postgres[0].referenced_security_group_id == "sg-tasks" && aws_vpc_security_group_ingress_rule.postgres[0].cidr_ipv4 == null
    error_message = "Databases accept connections from the task security group only."
  }
}

run "dev_can_be_torn_down" {
  command = plan
  variables {
    deletion_protection = false
  }
  assert {
    condition     = !aws_db_instance.postgres.deletion_protection && aws_db_instance.postgres.skip_final_snapshot && !aws_db_instance.postgres.multi_az
    error_message = "dev: no deletion protection or final snapshot, single AZ."
  }
}
