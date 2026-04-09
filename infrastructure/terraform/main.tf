locals {
  name = var.cluster_name

  # Common tags applied to all resources via provider default_tags
  tags = {
    Project     = "eks-gitops"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ─── VPC ───────────────────────────────────────────────────────────────────────

module "vpc" {
  source = "./modules/vpc"

  name               = local.name
  region             = var.aws_region
  cidr               = var.vpc_cidr
  azs                = var.availability_zones
  private_subnets    = var.private_subnet_cidrs
  public_subnets     = var.public_subnet_cidrs
  single_nat_gateway = var.single_nat_gateway
  tags               = local.tags
}

# ─── EKS Cluster ─────────────────────────────────────────────────────────────

module "eks" {
  source = "./modules/eks"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids

  system_node_instance_types = var.system_node_instance_types
  system_node_min_size       = var.system_node_min_size
  system_node_max_size       = var.system_node_max_size
  system_node_desired_size   = var.system_node_desired_size

  app_node_instance_types = var.app_node_instance_types
  app_node_min_size       = var.app_node_min_size
  app_node_max_size       = var.app_node_max_size
  app_node_desired_size   = var.app_node_desired_size

  tags = local.tags
}

# ─── IRSA (IAM Roles for Service Accounts) ────────────────────────────────────

module "irsa" {
  source = "./modules/irsa"

  cluster_name            = module.eks.cluster_name
  oidc_provider_arn       = module.eks.oidc_provider_arn
  oidc_provider_url       = module.eks.cluster_oidc_issuer_url
  aws_region              = var.aws_region
  aws_account_id          = data.aws_caller_identity.current.account_id

  tags = local.tags
}

# ─── ECR Repositories ─────────────────────────────────────────────────────────

resource "aws_ecr_repository" "apps" {
  for_each = toset(var.ecr_repositories)

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "apps" {
  for_each   = aws_ecr_repository.apps
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.ecr_image_retention_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_image_retention_count
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ─── GitHub Actions OIDC Provider ────────────────────────────────────────────
# Enables keyless authentication from GitHub Actions to AWS — no static credentials.

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# IAM role for GitHub Actions CI/CD — can push to ECR and update EKS
resource "aws_iam_role" "github_actions_cicd" {
  name = "${local.name}-github-actions-cicd"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_actions_cicd" {
  name = "${local.name}-github-actions-cicd"
  role = aws_iam_role.github_actions_cicd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
        ]
        Resource = [for repo in aws_ecr_repository.apps : repo.arn]
      },
      {
        Sid    = "EKSDescribe"
        Effect = "Allow"
        Action = ["eks:DescribeCluster"]
        Resource = module.eks.cluster_arn
      }
    ]
  })
}

# ─── Data Sources ─────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
