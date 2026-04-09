# Architecture Decision Record (ADR) — EKS GitOps Platform

## Overview

This document explains the key architectural decisions made in this platform and the trade-offs considered.

---

## ADR-001: GitOps with ArgoCD App-of-Apps

**Status:** Accepted

**Context:** We need a way to manage multiple applications across a Kubernetes cluster declaratively, with the ability to add new applications without touching cluster state manually.

**Decision:** Use the ArgoCD App-of-Apps pattern where a single "root" Application monitors a Git directory (`apps/argocd/applications/`). Any YAML file added to that directory automatically creates a new ArgoCD-managed application.

**Consequences:**
- ✅ Onboarding a new service = create one YAML file in Git
- ✅ Complete platform state visible in Git history
- ✅ Drift detection — ArgoCD alerts if cluster state diverges from Git
- ⚠️ Bootstrap chicken-and-egg: ArgoCD itself must be installed before it can manage anything. Terraform handles this.

---

## ADR-002: Terraform for Platform Bootstrap, ArgoCD for Apps

**Status:** Accepted

**Context:** Should Terraform manage everything, or should ArgoCD manage everything?

**Decision:** Terraform manages the layer that must exist before ArgoCD can run:
- VPC, EKS cluster, node groups
- IAM/IRSA roles
- ArgoCD itself (via Helm)
- AWS Load Balancer Controller (needed for any Ingress)

ArgoCD manages all application-layer concerns:
- Sock-shop, demo-app
- Prometheus/Grafana
- Kyverno, ESO
- Argo Rollouts

**Consequences:**
- ✅ Clear boundary of responsibility
- ✅ Infrastructure changes go through Terraform's plan/apply cycle
- ✅ Application changes go through ArgoCD's sync cycle
- ⚠️ Two systems to learn; team must understand which layer to touch

---

## ADR-003: IRSA over Node IAM Roles

**Status:** Accepted

**Context:** Kubernetes pods running on EKS nodes sometimes need AWS API access (e.g., reading from Secrets Manager, managing load balancers).

**Decision:** Use IAM Roles for Service Accounts (IRSA) — every workload that needs AWS access gets its own dedicated IAM role, bound to its Kubernetes service account via OIDC federation.

**Alternatives considered:**
- **Node IAM role**: Simple, but all pods on a node share the same permissions. Violates least-privilege.
- **kube2iam/kiam**: Works but adds complexity and latency. IRSA is the AWS-native solution.

**Consequences:**
- ✅ Per-pod AWS permissions (least privilege)
- ✅ No credentials stored anywhere — temporary tokens via STS
- ✅ Audit trail per service account
- ⚠️ Each new service needing AWS access requires an IRSA module configuration

---

## ADR-004: GitHub Actions OIDC for CI/CD Auth

**Status:** Accepted

**Context:** The CI/CD pipeline needs to push images to ECR and read cluster info. How should it authenticate to AWS?

**Decision:** Use GitHub Actions OIDC — GitHub generates a short-lived token that AWS STS exchanges for temporary credentials. No static AWS credentials are stored in GitHub Secrets.

**Consequences:**
- ✅ No long-lived credentials to rotate or leak
- ✅ Token is scoped to specific repo and branch (`repo:ORG/REPO:ref:refs/heads/main`)
- ✅ Credential breach impact limited (tokens expire in 15 minutes)
- ⚠️ Requires AWS IAM OIDC provider for `token.actions.githubusercontent.com` (managed by Terraform)

---

## ADR-005: Kyverno over OPA Gatekeeper

**Status:** Accepted

**Context:** We need admission control policies to enforce security standards across the cluster.

**Decision:** Use Kyverno instead of OPA/Gatekeeper.

**Comparison:**

| Feature | Kyverno | OPA Gatekeeper |
|---------|---------|----------------|
| Policy language | YAML (Kubernetes-native) | Rego (specialized) |
| Learning curve | Low | High |
| Generate rules | Yes | No |
| Mutate rules | Yes | No |
| Audit mode | Yes | Yes |
| Background scan | Yes | Yes |

**Consequences:**
- ✅ Policies are readable YAML — no Rego expertise needed
- ✅ Can generate resources (e.g., auto-create NetworkPolicies)
- ✅ Can mutate resources (e.g., auto-inject labels)
- ⚠️ Kyverno is less battle-tested in very large clusters vs. Gatekeeper

---

## ADR-006: Argo Rollouts for Blue-Green Deployments

**Status:** Accepted

**Context:** Standard Kubernetes rolling updates provide no traffic control during rollout. We want to deploy a new version, validate it with a small traffic slice or manually, then promote.

**Decision:** Use Argo Rollouts with the blue-green strategy:
1. New version (green) is deployed but receives no traffic
2. Preview service points to green for testing
3. Active service continues serving traffic from blue
4. Manual promotion switches active service to green
5. Blue is scaled down after configurable delay

**Consequences:**
- ✅ Zero-downtime deployments guaranteed
- ✅ Instant rollback (point active service back to blue)
- ✅ Pre-promotion analysis hooks for automated validation
- ⚠️ Temporarily runs 2x the pods during rollout (cost consideration)
- ⚠️ Requires Argo Rollouts CRDs and controller

---

## ADR-007: gp3 as Default StorageClass

**Status:** Accepted

**Context:** AWS EKS clusters default to gp2 EBS volumes. gp3 offers better performance at lower cost.

**Decision:** Create a gp3 StorageClass and mark it as default. Remove the default annotation from gp2.

**Performance comparison:**

| Feature | gp2 | gp3 |
|---------|-----|-----|
| Baseline IOPS | 3 IOPS/GB | 3000 IOPS (fixed) |
| Baseline throughput | 128 MiB/s | 125 MiB/s |
| Max IOPS | 16,000 | 16,000 |
| Cost | Higher | ~20% lower |

**Consequences:**
- ✅ Better baseline performance for small volumes (< 1000 GB)
- ✅ Lower cost
- ⚠️ gp3 requires EBS CSI driver (managed via EKS addon)

---

## Network Architecture

```
Internet
    │
    ▼
[AWS ALB]  ← Managed by AWS Load Balancer Controller
    │        ← TLS terminated here
    │
    ▼
[EKS Nodes - Private Subnets]
    │
    ├── System Node Group (2x t3.medium)
    │   ├── ArgoCD
    │   ├── Kyverno
    │   ├── External Secrets Operator
    │   └── Prometheus/Grafana
    │
    └── Application Node Group (2-10x t3.large)
        ├── Sock Shop services
        ├── Demo App (Argo Rollout)
        └── Argo Rollouts controller
```

**Subnet design:**
- Public subnets: NAT Gateways, Application Load Balancers
- Private subnets: All EKS nodes (no direct internet access)
- NAT Gateways: One per AZ (3x) for HA egress

---

## Security Layers

```
Layer 1: AWS IAM
  ├── IRSA: pod-level AWS permissions
  ├── GitHub OIDC: CI/CD without stored credentials
  └── EKS Access Entries: cluster access control

Layer 2: Kubernetes RBAC
  └── Minimal permissions per service account

Layer 3: Kyverno Admission Control
  ├── Block privileged containers
  ├── Require resource limits
  ├── Require labels
  └── Disallow latest image tags

Layer 4: Network Policies
  ├── Default deny all ingress/egress
  └── Explicit allow rules per service

Layer 5: Pod Security
  ├── Non-root containers
  ├── Read-only root filesystem
  ├── Dropped capabilities
  └── Seccomp RuntimeDefault

Layer 6: Secret Management
  └── External Secrets Operator → AWS Secrets Manager
      (no secrets in Git, no secrets in etcd long-term)

Layer 7: Image Security
  ├── Trivy scan in CI (block on CRITICAL/HIGH)
  ├── ECR image scanning on push
  └── Distroless base images (demo-app)
```
