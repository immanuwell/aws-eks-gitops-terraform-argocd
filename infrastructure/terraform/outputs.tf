output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.eks.cluster_arn
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = module.eks.cluster_version
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS nodes)"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT)"
  value       = module.vpc.public_subnet_ids
}

output "ecr_repository_urls" {
  description = "ECR repository URLs by name"
  value       = { for name, repo in aws_ecr_repository.apps : name => repo.repository_url }
}

output "github_actions_role_arn" {
  description = "IAM Role ARN for GitHub Actions OIDC — use this in GitHub Actions secrets as AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions_cicd.arn
}

output "alb_controller_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller (IRSA)"
  value       = module.irsa.alb_controller_role_arn
}

output "external_secrets_role_arn" {
  description = "IAM Role ARN for External Secrets Operator (IRSA)"
  value       = module.irsa.external_secrets_role_arn
}

output "argocd_server_url" {
  description = "ArgoCD server URL (via ALB after bootstrap)"
  value       = "https://argocd.${var.cluster_name}.example.com"
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}
