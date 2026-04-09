output "alb_controller_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = module.alb_controller_irsa.iam_role_arn
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = module.external_secrets_irsa.iam_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for Cluster Autoscaler"
  value       = module.cluster_autoscaler_irsa.iam_role_arn
}

output "velero_role_arn" {
  description = "IAM role ARN for Velero backup"
  value       = module.velero_irsa.iam_role_arn
}

output "velero_backup_bucket" {
  description = "S3 bucket name for Velero backups"
  value       = aws_s3_bucket.velero_backups.bucket
}
