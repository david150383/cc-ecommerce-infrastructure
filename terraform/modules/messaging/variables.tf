variable "environment" {
  description = "Environment name used as the resource-name prefix (local, dev, staging, prod)."
  type        = string

  validation {
    condition     = contains(["local", "dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: local, dev, staging, prod."
  }
}

variable "kms_key_id" {
  description = "Customer-managed KMS key for SNS/SQS encryption. Null uses AWS-managed keys (SSE-SQS / alias/aws/sns)."
  type        = string
  default     = null
}

variable "visibility_timeout_seconds" {
  type    = number
  default = 60
}

variable "message_retention_seconds" {
  type    = number
  default = 345600 # 4 days
}

variable "dlq_retention_seconds" {
  type    = number
  default = 1209600 # 14 days
}

variable "max_receive_count" {
  description = "Receives before a message moves to the DLQ."
  type        = number
  default     = 5
}

variable "create_alarms" {
  type    = bool
  default = true
}

variable "alarm_topic_arns" {
  description = "SNS topics notified when an alarm fires (e.g. an ops email/Slack topic)."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
