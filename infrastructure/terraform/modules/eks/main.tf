module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Endpoint access — public for kubectl, private for node-to-control-plane traffic
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  # Restrict public access to known CIDRs in production
  cluster_endpoint_public_access_cidrs = var.allowed_cidr_blocks

  # Enable IRSA (OIDC provider for service accounts)
  enable_irsa = true

  # Cluster addons — use most_recent to get latest patch versions
  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        replicaCount = 2
        resources = {
          requests = { cpu = "100m", memory = "70Mi" }
          limits   = { cpu = "200m", memory = "170Mi" }
        }
      })
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true  # Must be installed before nodes join
      configuration_values = jsonencode({
        env = {
          # Enable prefix delegation for increased pod density
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  # ─── Node Groups ──────────────────────────────────────────────────────────

  eks_managed_node_groups = {
    # System node group — dedicated to platform components (ArgoCD, monitoring, etc.)
    # Tainted so only tolerating pods land here.
    system = {
      name = "${var.cluster_name}-system"

      instance_types = var.system_node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.system_node_min_size
      max_size     = var.system_node_max_size
      desired_size = var.system_node_desired_size

      # Use custom launch template for additional node configuration
      use_custom_launch_template = true
      disk_size                  = 50

      labels = {
        role                     = "system"
        "node.kubernetes.io/role" = "system"
      }

      taints = [
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      ]

      update_config = {
        max_unavailable_percentage = 50
      }

      tags = merge(var.tags, {
        "k8s.io/cluster-autoscaler/enabled"               = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"   = "owned"
      })
    }

    # Application node group — runs workloads (sock-shop, demo-app, etc.)
    application = {
      name = "${var.cluster_name}-application"

      instance_types = var.app_node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.app_node_min_size
      max_size     = var.app_node_max_size
      desired_size = var.app_node_desired_size

      use_custom_launch_template = true
      disk_size                  = 100

      labels = {
        role                     = "application"
        "node.kubernetes.io/role" = "application"
      }

      update_config = {
        max_unavailable_percentage = 33
      }

      tags = merge(var.tags, {
        "k8s.io/cluster-autoscaler/enabled"               = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"   = "owned"
      })
    }
  }

  # ─── Access Entries (replaces aws-auth ConfigMap) ─────────────────────────

  # Using access entries API (EKS v1.29+ best practice over aws-auth ConfigMap)
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    # Add any additional IAM roles/users here
    # Example for a separate admin role:
    # admin = {
    #   principal_arn = "arn:aws:iam::ACCOUNT_ID:role/eks-admin"
    #   policy_associations = {
    #     admin = {
    #       policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    #       access_scope = { type = "cluster" }
    #     }
    #   }
    # }
  }

  # ─── Security Groups ──────────────────────────────────────────────────────

  # Allow all egress from nodes (required for pulling images, AWS API calls)
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  tags = var.tags
}

# ─── EBS CSI IRSA ─────────────────────────────────────────────────────────────

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi-controller"
  attach_ebs_csi_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = var.tags
}

# ─── StorageClass ─────────────────────────────────────────────────────────────

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    # 3000 IOPS and 125 MiB/s throughput by default (gp3 baseline)
  }
}

# Remove default gp2 storage class
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [module.eks]
}
