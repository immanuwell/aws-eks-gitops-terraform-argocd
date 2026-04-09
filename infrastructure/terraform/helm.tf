# Helm releases managed by Terraform — these are "platform" components that must
# exist before ArgoCD can take over management of everything else.
#
# Bootstrap order:
#   1. AWS Load Balancer Controller  (needed for any Ingress/LoadBalancer)
#   2. ArgoCD                        (takes over GitOps from here)
#
# Everything else (Prometheus, Kyverno, Sock-Shop, etc.) is managed by ArgoCD.

# ─── Namespaces ───────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace" "kube_system_annotations" {
  # kube-system already exists; we just need to ensure our label is present
  # for ALB controller discovery
  metadata {
    name = "kube-system"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

# ─── AWS Load Balancer Controller ────────────────────────────────────────────

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.2"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa.alb_controller_role_arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "replicaCount"
    value = "2"
  }

  # Pod anti-affinity for HA — spread across AZs
  values = [
    yamlencode({
      affinity = {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [
            {
              labelSelector = {
                matchExpressions = [
                  {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["aws-load-balancer-controller"]
                  }
                ]
              }
              topologyKey = "kubernetes.io/hostname"
            }
          ]
        }
      }
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
    })
  ]

  depends_on = [
    module.eks,
    module.irsa,
    kubernetes_namespace.kube_system_annotations,
  ]
}

# ─── ArgoCD ───────────────────────────────────────────────────────────────────

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Wait for ArgoCD to be fully ready before Terraform completes
  wait    = true
  timeout = 600

  values = [
    yamlencode({
      global = {
        domain = "argocd.${var.cluster_name}.example.com"
      }

      configs = {
        params = {
          # Allow HTTP connections from ALB (TLS terminated at ALB)
          "server.insecure" = true
        }

        cm = {
          # Application health check customization
          "timeout.reconciliation" = "180s"
          "resource.customizations.health.argoproj.io_Application" = <<-EOF
            hs = {}
            hs.status = "Progressing"
            hs.message = ""
            if obj.status ~= nil then
              if obj.status.health ~= nil then
                hs.status = obj.status.health.status
                if obj.status.health.message ~= nil then
                  hs.message = obj.status.health.message
                end
              end
            end
            return hs
          EOF
        }

        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv"     = <<-EOF
            p, role:admin, applications, *, */*, allow
            p, role:admin, clusters, get, *, allow
            p, role:admin, repositories, *, *, allow
            g, platform-team, role:admin
          EOF
        }
      }

      server = {
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          annotations = {
            "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
            "alb.ingress.kubernetes.io/target-type" = "ip"
            "alb.ingress.kubernetes.io/listen-ports" = jsonencode([{ HTTPS = 443 }])
          }
        }

        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "256Mi" }
        }
      }

      repoServer = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }

      applicationSet = {
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      # Tolerate system node group taint so ArgoCD runs on dedicated nodes
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
    })
  ]

  # If a password is provided, set it; otherwise ArgoCD generates one
  dynamic "set_sensitive" {
    for_each = var.argocd_admin_password_bcrypt != "" ? [1] : []
    content {
      name  = "configs.secret.argocdServerAdminPassword"
      value = var.argocd_admin_password_bcrypt
    }
  }

  depends_on = [
    kubernetes_namespace.argocd,
    helm_release.aws_load_balancer_controller,
  ]
}

# ─── Argo Rollouts CRDs ────────────────────────────────────────────────────────
# Install just the CRDs here so ArgoCD can manage the Argo Rollouts controller.
# This avoids a chicken-and-egg problem where apps reference CRDs that don't exist yet.

resource "helm_release" "argo_rollouts_crds" {
  name       = "argo-rollouts-crds"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  version    = "2.35.3"
  namespace  = "argo-rollouts"
  create_namespace = true

  # Install only CRDs, not the controller (ArgoCD manages the controller)
  set {
    name  = "controller.enabled"
    value = "false"
  }
  set {
    name  = "dashboard.enabled"
    value = "false"
  }
  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [module.eks]
}
