# SNS/SQS topology for the platform.
# The rationale is in docs/architecture/messaging-topology.md. Keep the two in sync.

locals {
  prefix = "${var.environment}-ecommerce"

  # Event topics: one per producing service.
  topics = toset(["auth-events", "order-events", "inventory-events", "payment-events", "saga-events"])

  # Command queues: exactly one consumer each; producers SendMessage directly.
  command_queues = toset(["inventory-commands", "order-commands", "payment-commands", "notification-commands"])

  # Inbox queues: receive events fanned out from topics.
  inbox_queues = toset(["saga-inbox", "notification-inbox"])

  # Subscriptions: inbox queue <- topic, filtered on the `messageType` message attribute.
  subscriptions = {
    "saga-inbox--inventory-events" = {
      queue = "saga-inbox", topic = "inventory-events"
      types = ["InventoryReserved", "InventoryReservationFailed", "InventoryReservationConfirmed", "InventoryReservationReleased"]
    }
    "saga-inbox--payment-events" = {
      queue = "saga-inbox", topic = "payment-events"
      types = ["PaymentSucceeded", "PaymentFailed", "RefundSucceeded", "RefundFailed"]
    }
    "saga-inbox--order-events" = {
      queue = "saga-inbox", topic = "order-events"
      types = ["OrderConfirmed", "OrderCancelled"]
    }
    "notification-inbox--auth-events" = {
      queue = "notification-inbox", topic = "auth-events"
      types = ["UserRegistered", "UserEmailVerified"]
    }
    "notification-inbox--order-events" = {
      queue = "notification-inbox", topic = "order-events"
      types = ["OrderConfirmed", "OrderCancelled", "OrderStatusChanged"]
    }
    "notification-inbox--payment-events" = {
      queue = "notification-inbox", topic = "payment-events"
      types = ["PaymentFailed", "RefundSucceeded"]
    }
    "notification-inbox--inventory-events" = {
      queue = "notification-inbox", topic = "inventory-events"
      types = ["InventoryLowStock"]
    }
  }

  all_queues = setunion(local.command_queues, local.inbox_queues)

  # Least-privilege access per service (see messaging-topology.md §IAM).
  service_access = {
    "auth-service"         = { publish = ["auth-events"], send = [], consume = [] }
    "order-service"        = { publish = ["order-events"], send = ["notification-commands"], consume = ["order-commands"] }
    "inventory-service"    = { publish = ["inventory-events"], send = [], consume = ["inventory-commands"] }
    "payment-service"      = { publish = ["payment-events"], send = ["notification-commands"], consume = ["payment-commands"] }
    "saga-orchestrator"    = { publish = ["saga-events"], send = ["inventory-commands", "order-commands", "payment-commands", "notification-commands"], consume = ["saga-inbox"] }
    "notification-service" = { publish = [], send = [], consume = ["notification-commands", "notification-inbox"] }
  }
}

resource "aws_sns_topic" "this" {
  for_each          = local.topics
  name              = "${local.prefix}-${each.key}"
  kms_master_key_id = var.kms_key_id != null ? var.kms_key_id : "alias/aws/sns"
  tags              = var.tags
}

resource "aws_sqs_queue" "dlq" {
  for_each                  = local.all_queues
  name                      = "${local.prefix}-${each.key}-dlq"
  message_retention_seconds = var.dlq_retention_seconds
  sqs_managed_sse_enabled   = var.kms_key_id == null ? true : null
  kms_master_key_id         = var.kms_key_id
  tags                      = var.tags
}

resource "aws_sqs_queue" "main" {
  for_each                   = local.all_queues
  name                       = "${local.prefix}-${each.key}"
  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = 20
  message_retention_seconds  = var.message_retention_seconds
  sqs_managed_sse_enabled    = var.kms_key_id == null ? true : null
  kms_master_key_id          = var.kms_key_id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = var.tags
}

# Only the matching main queue may use each DLQ.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each  = local.all_queues
  queue_url = aws_sqs_queue.dlq[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main[each.key].arn]
  })
}

# Allow each inbox queue to receive only from the topics it subscribes to.
data "aws_iam_policy_document" "inbox" {
  for_each = local.inbox_queues

  statement {
    sid       = "AllowSubscribedTopics"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = distinct([for s in local.subscriptions : aws_sns_topic.this[s.topic].arn if s.queue == each.key])
    }
  }
}

resource "aws_sqs_queue_policy" "inbox" {
  for_each  = local.inbox_queues
  queue_url = aws_sqs_queue.main[each.key].id
  policy    = data.aws_iam_policy_document.inbox[each.key].json
}

resource "aws_sns_topic_subscription" "this" {
  for_each             = local.subscriptions
  topic_arn            = aws_sns_topic.this[each.value.topic].arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.main[each.value.queue].arn
  raw_message_delivery = true
  filter_policy_scope  = "MessageAttributes"
  filter_policy        = jsonencode({ messageType = each.value.types })

  depends_on = [aws_sqs_queue_policy.inbox]
}

# Per-service IAM policy documents. Attach them to each service's task role
# (the ECS module, added in Phase 7, does this).
data "aws_iam_policy_document" "service" {
  for_each = local.service_access

  dynamic "statement" {
    for_each = length(each.value.publish) > 0 ? [1] : []
    content {
      sid       = "PublishEvents"
      actions   = ["sns:Publish"]
      resources = [for t in each.value.publish : aws_sns_topic.this[t].arn]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.send) > 0 ? [1] : []
    content {
      sid       = "SendCommands"
      actions   = ["sqs:SendMessage", "sqs:GetQueueUrl"]
      resources = [for q in each.value.send : aws_sqs_queue.main[q].arn]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.consume) > 0 ? [1] : []
    content {
      sid = "ConsumeQueues"
      actions = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      resources = [for q in each.value.consume : aws_sqs_queue.main[q].arn]
    }
  }

  # A policy document needs at least one statement; harmless read-only fallback.
  statement {
    sid       = "ListOwnTopology"
    actions   = ["sns:ListTopics", "sqs:ListQueues"]
    resources = ["*"]
  }
}

# Alarms: anything in a DLQ needs a human; an old message means a stuck consumer.
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each            = var.create_alarms ? local.all_queues : toset([])
  alarm_name          = "${local.prefix}-${each.key}-dlq-not-empty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq[each.key].name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_topic_arns
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "oldest_message_age" {
  for_each            = var.create_alarms ? local.all_queues : toset([])
  alarm_name          = "${local.prefix}-${each.key}-oldest-message-age"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.main[each.key].name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_topic_arns
  tags                = var.tags
}
