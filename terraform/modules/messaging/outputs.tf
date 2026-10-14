output "topic_arns" {
  description = "Map of logical topic name to ARN."
  value       = { for k, t in aws_sns_topic.this : k => t.arn }
}

output "queue_names" {
  description = "Map of logical queue name to physical name (FIFO queues end in .fifo)."
  value       = { for k, q in aws_sqs_queue.main : k => q.name }
}

output "queue_urls" {
  description = "Map of logical queue name to URL."
  value       = { for k, q in aws_sqs_queue.main : k => q.url }
}

output "dlq_urls" {
  value = { for k, q in aws_sqs_queue.dlq : k => q.url }
}

output "service_policy_json" {
  description = "Least-privilege IAM policy document per service, to attach to its task role."
  value       = { for k, d in data.aws_iam_policy_document.service : k => d.json }
}
