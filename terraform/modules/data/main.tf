# Databases: one PostgreSQL instance (a database + role per service: auth, product, inventory, payment,
# notification, saga) and one DocumentDB cluster (order-service, MongoDB API). Private subnets only,
# encrypted, TLS required, backups and deletion protection on. No password ever enters Terraform state:
# RDS manages the master secret itself; per-service credentials are created by a bootstrap task
# (docs/architecture/deployment.md) and stored in each service's secret.

variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "client_security_group_ids" {
  description = "Security groups allowed to connect (the ECS tasks)."
  type        = list(string)
}

variable "postgres_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "postgres_allocated_storage_gb" {
  type    = number
  default = 50
}

variable "multi_az" {
  description = "Standby in a second AZ with automatic failover (prod)."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "docdb_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "docdb_instances" {
  description = "1 = no replica (dev); 2+ = replicas for failover (prod)."
  type        = number
  default     = 1
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "alarm_topic_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_security_group" "db" {
  name        = "${var.name}-databases"
  description = "PostgreSQL and DocumentDB, from ECS tasks only"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  # count, not for_each: the group IDs are unknown until apply, their number is known at plan time.
  count                        = length(var.client_security_group_ids)
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = var.client_security_group_ids[count.index]
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "docdb" {
  # count, not for_each: the group IDs are unknown until apply, their number is known at plan time.
  count                        = length(var.client_security_group_ids)
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = var.client_security_group_ids[count.index]
  ip_protocol                  = "tcp"
  from_port                    = 27017
  to_port                      = 27017
}

# ---- PostgreSQL -------------------------------------------------------------------------------------
resource "aws_db_subnet_group" "postgres" {
  name       = "${var.name}-postgres"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_db_parameter_group" "postgres" {
  name   = "${var.name}-postgres17"
  family = "postgres17"
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # log statements slower than 1 s
  }
  tags = var.tags
}

resource "aws_db_instance" "postgres" {
  identifier                      = "${var.name}-postgres"
  engine                          = "postgres"
  engine_version                  = "17"
  instance_class                  = var.postgres_instance_class
  allocated_storage               = var.postgres_allocated_storage_gb
  max_allocated_storage           = var.postgres_allocated_storage_gb * 4
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_subnet_group_name            = aws_db_subnet_group.postgres.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  parameter_group_name            = aws_db_parameter_group.postgres.name
  publicly_accessible             = false
  multi_az                        = var.multi_az
  username                        = "platform_admin"
  manage_master_user_password     = true # RDS creates and rotates the secret; it never enters TF state
  backup_retention_period         = var.backup_retention_days
  backup_window                   = "20:00-21:00" # UTC: 01:30-02:30 IST
  maintenance_window              = "sun:21:30-sun:22:30"
  copy_tags_to_snapshot           = true
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = !var.deletion_protection
  final_snapshot_identifier       = var.deletion_protection ? "${var.name}-postgres-final" : null
  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  auto_minor_version_upgrade      = true
  apply_immediately               = false
  tags                            = var.tags
}

# ---- DocumentDB (order-service) ---------------------------------------------------------------------
resource "aws_docdb_subnet_group" "this" {
  name       = "${var.name}-docdb"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

resource "aws_docdb_cluster_parameter_group" "this" {
  name   = "${var.name}-docdb5"
  family = "docdb5.0"
  parameter {
    name  = "tls"
    value = "enabled"
  }
  parameter {
    name  = "audit_logs"
    value = "enabled"
  }
  tags = var.tags
}

resource "aws_docdb_cluster" "this" {
  cluster_identifier              = "${var.name}-docdb"
  engine                          = "docdb"
  engine_version                  = "5.0.0"
  master_username                 = "platform_admin"
  manage_master_user_password     = true
  db_subnet_group_name            = aws_docdb_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.this.name
  storage_encrypted               = true
  backup_retention_period         = var.backup_retention_days
  preferred_backup_window         = "20:00-21:00"
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = !var.deletion_protection
  final_snapshot_identifier       = var.deletion_protection ? "${var.name}-docdb-final" : null
  enabled_cloudwatch_logs_exports = ["audit"]
  tags                            = var.tags
}

resource "aws_docdb_cluster_instance" "this" {
  count              = var.docdb_instances
  identifier         = "${var.name}-docdb-${count.index}"
  cluster_identifier = aws_docdb_cluster.this.id
  instance_class     = var.docdb_instance_class
  tags               = var.tags
}

# ---- alarms -----------------------------------------------------------------------------------------
locals {
  postgres_alarms = {
    cpu     = { metric = "CPUUtilization", threshold = 80, op = "GreaterThanThreshold", stat = "Average", desc = "PostgreSQL CPU above 80% for 15 min" }
    storage = { metric = "FreeStorageSpace", threshold = 5 * 1024 * 1024 * 1024, op = "LessThanThreshold", stat = "Minimum", desc = "PostgreSQL free storage below 5 GiB" }
    memory  = { metric = "FreeableMemory", threshold = 256 * 1024 * 1024, op = "LessThanThreshold", stat = "Minimum", desc = "PostgreSQL freeable memory below 256 MiB" }
    conn    = { metric = "DatabaseConnections", threshold = 300, op = "GreaterThanThreshold", stat = "Maximum", desc = "PostgreSQL connections above 300 (pool sizes x tasks)" }
  }
}

resource "aws_cloudwatch_metric_alarm" "postgres" {
  for_each            = local.postgres_alarms
  alarm_name          = "${var.name}-postgres-${each.key}"
  alarm_description   = each.value.desc
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = aws_db_instance.postgres.identifier }
  statistic           = each.value.stat
  period              = 300
  evaluation_periods  = 3
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "docdb_cpu" {
  alarm_name          = "${var.name}-docdb-cpu"
  alarm_description   = "DocumentDB CPU above 80% for 15 min"
  namespace           = "AWS/DocDB"
  metric_name         = "CPUUtilization"
  dimensions          = { DBClusterIdentifier = aws_docdb_cluster.this.cluster_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
  tags                = var.tags
}

output "postgres_endpoint" {
  value = aws_db_instance.postgres.address
}

output "postgres_master_secret_arn" {
  description = "RDS-managed master credentials (for the bootstrap task only)."
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "docdb_endpoint" {
  value = aws_docdb_cluster.this.endpoint
}

output "docdb_master_secret_arn" {
  value = aws_docdb_cluster.this.master_user_secret[0].secret_arn
}
