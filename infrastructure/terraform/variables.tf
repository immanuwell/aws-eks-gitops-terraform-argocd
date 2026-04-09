variable "aws_region" {
  description = "AWS region where all resources will be created"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g. production, staging)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Environment must be one of: production, staging, development."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "eks-gitops"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

# ─── VPC ───────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones. Must have at least 2 for HA."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ). EKS nodes run here."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ). ALBs and NAT GWs."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway instead of one per AZ. Cost-saving for non-prod."
  type        = bool
  default     = false
}

# ─── EKS Node Groups ──────────────────────────────────────────────────────────

variable "system_node_instance_types" {
  description = "Instance types for the system node group (ArgoCD, monitoring, etc.)"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_node_min_size" {
  description = "Minimum number of nodes in the system node group"
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum number of nodes in the system node group"
  type        = number
  default     = 4
}

variable "system_node_desired_size" {
  description = "Desired number of nodes in the system node group"
  type        = number
  default     = 2
}

variable "app_node_instance_types" {
  description = "Instance types for the application node group"
  type        = list(string)
  default     = ["t3.large"]
}

variable "app_node_min_size" {
  description = "Minimum number of nodes in the application node group"
  type        = number
  default     = 2
}

variable "app_node_max_size" {
  description = "Maximum number of nodes in the application node group"
  type        = number
  default     = 10
}

variable "app_node_desired_size" {
  description = "Desired number of nodes in the application node group"
  type        = number
  default     = 3
}

# ─── ArgoCD ───────────────────────────────────────────────────────────────────

variable "argocd_chart_version" {
  description = "Version of the ArgoCD Helm chart"
  type        = string
  default     = "6.7.3"
}

variable "argocd_admin_password_bcrypt" {
  description = "Bcrypt-hashed ArgoCD admin password. Generate with: htpasswd -nbBC 10 '' PASSWORD | tr -d ':\\n'"
  type        = string
  sensitive   = true
  default     = ""
}

variable "gitops_repo_url" {
  description = "URL of this GitOps repository (used by ArgoCD to sync)"
  type        = string
  default     = "https://github.com/immanuwell/aws-eks-gitops-terraform-argocd"
}

variable "gitops_repo_revision" {
  description = "Git branch/tag/commit ArgoCD should track"
  type        = string
  default     = "main"
}

# ─── GitHub Actions OIDC ─────────────────────────────────────────────────────

variable "github_org" {
  description = "GitHub organization or username (for OIDC trust policy)"
  type        = string
  default     = "immanuwell"
}

variable "github_repo" {
  description = "GitHub repository name (for OIDC trust policy)"
  type        = string
  default     = "aws-eks-gitops-terraform-argocd"
}

# ─── ECR ──────────────────────────────────────────────────────────────────────

variable "ecr_repositories" {
  description = "List of ECR repository names to create"
  type        = list(string)
  default     = ["demo-app"]
}

variable "ecr_image_retention_count" {
  description = "Number of images to retain per ECR repository"
  type        = number
  default     = 30
}
