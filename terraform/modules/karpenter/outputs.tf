output "karpenter_controller_role_arn" {
  description = "IAM role ARN assumed by the Karpenter controller pod"
  value       = aws_iam_role.karpenter_controller.arn
}

output "interruption_queue_url" {
  description = "SQS queue URL for EC2 Spot interruption events"
  value       = aws_sqs_queue.interruption.url
}