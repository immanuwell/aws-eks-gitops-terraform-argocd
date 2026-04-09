# Runbook — EKS GitOps Platform Day-2 Operations

## Table of Contents
1. [Cluster Access](#cluster-access)
2. [Deployments & Rollouts](#deployments--rollouts)
3. [Scaling Operations](#scaling-operations)
4. [Incident Response](#incident-response)
5. [ArgoCD Operations](#argocd-operations)
6. [Secret Rotation](#secret-rotation)
7. [Node Operations](#node-operations)
8. [Terraform Operations](#terraform-operations)
9. [Backup & Recovery](#backup--recovery)

---

## Cluster Access

### Update kubeconfig
```bash
aws eks update-kubeconfig --region us-east-1 --name eks-gitops
# Verify access
kubectl get nodes -o wide
```

### Switch between clusters (if you have multiple)
```bash
kubectl config get-contexts
kubectl config use-context arn:aws:eks:us-east-1:ACCOUNT:cluster/eks-gitops
```

### Access ArgoCD UI
```bash
# Port-forward (if no ALB ingress)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
# Login via CLI
argocd login localhost:8080 --username admin --insecure
```

---

## Deployments & Rollouts

### Deploy a new version of demo-app (blue-green)

1. **Push image and trigger CI/CD** — the pipeline builds, scans, and commits the new tag automatically.

2. **Monitor rollout** — ArgoCD detects the new tag and creates the green deployment:
```bash
kubectl argo rollouts get rollout demo-app -n demo-app --watch
```

3. **Verify green version** — test via the preview service:
```bash
kubectl port-forward svc/demo-app-preview -n demo-app 8081:80
curl http://localhost:8081
# Should return {"color": "green", ...}
```

4. **Promote** — switch active service to green:
```bash
kubectl argo rollouts promote demo-app -n demo-app
```

5. **Verify promotion**:
```bash
kubectl argo rollouts status demo-app -n demo-app
```

### Rollback demo-app

```bash
# Abort current rollout (instantly reverts to blue)
kubectl argo rollouts abort demo-app -n demo-app

# Or roll back to a specific revision
kubectl argo rollouts undo demo-app -n demo-app --to-revision=3
```

### Deploy a sock-shop update

Sock-shop is managed by ArgoCD pointing to Git. To update:
1. Edit the image tag in `apps/sock-shop/deployments.yaml`
2. Commit and push to main
3. ArgoCD auto-syncs within ~3 minutes, or trigger immediately:
```bash
argocd app sync sock-shop
```

---

## Scaling Operations

### Manual HPA override (temporary)
```bash
# Scale demo-app to 10 replicas manually
kubectl scale rollout demo-app --replicas=10 -n demo-app

# For a regular deployment
kubectl scale deployment front-end --replicas=5 -n sock-shop

# NOTE: HPA will override this when CPU/memory thresholds trigger.
# For permanent change, update the HPA values in Git.
```

### Update HPA limits via GitOps
Edit `apps/demo-app/values.yaml` or `apps/sock-shop/hpa.yaml` and commit. ArgoCD syncs.

### Check current HPA state
```bash
kubectl get hpa -A
kubectl describe hpa front-end -n sock-shop
```

### Cluster Autoscaler — check scaling events
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler -f
kubectl get events -n kube-system --sort-by=.lastTimestamp | grep -i scale
```

---

## Incident Response

### Pod crash-looping
```bash
# Identify the pod
kubectl get pods -n sock-shop | grep CrashLoop

# Check logs (including previous container)
kubectl logs -n sock-shop payment-xxx --previous
kubectl logs -n sock-shop payment-xxx --tail=100

# Check events
kubectl describe pod payment-xxx -n sock-shop

# Common causes:
#   1. OOMKilled → increase memory limits in values.yaml
#   2. ImagePullBackOff → check ECR permissions, image tag
#   3. CrashLoopBackOff → check application logs for startup errors
```

### Node NotReady
```bash
# Check node status
kubectl get nodes
kubectl describe node NODE_NAME | tail -50

# Check kubelet logs (if you have SSM access to the node)
aws ssm start-session --target INSTANCE_ID
journalctl -u kubelet -f

# Cordon and drain if replacing the node
kubectl cordon NODE_NAME
kubectl drain NODE_NAME --ignore-daemonsets --delete-emptydir-data

# The Cluster Autoscaler or managed node group will replace it
```

### High memory/CPU on a node
```bash
# Top pods by resource usage
kubectl top pods -A --sort-by=memory | head -20
kubectl top pods -A --sort-by=cpu | head -20

# Top nodes
kubectl top nodes

# If a pod is leaking memory:
kubectl delete pod OFFENDING_POD -n NAMESPACE
# The Deployment/Rollout will recreate it
```

### ArgoCD app stuck in Progressing/Degraded
```bash
# Check app status
argocd app get sock-shop

# Check app events
kubectl get events -n argocd --sort-by=.lastTimestamp

# Hard refresh (re-examine Git without waiting for poll interval)
argocd app get sock-shop --hard-refresh

# Force sync
argocd app sync sock-shop --force

# If sync is stuck due to resource deletion:
argocd app sync sock-shop --prune
```

### Network connectivity issues
```bash
# Test DNS resolution from a pod
kubectl run -it --rm debug --image=busybox --restart=Never -n sock-shop \
  -- nslookup catalogue

# Test service connectivity
kubectl run -it --rm debug --image=busybox --restart=Never -n sock-shop \
  -- wget -O- http://catalogue/health

# Check NetworkPolicy is not blocking
kubectl get networkpolicies -n sock-shop
kubectl describe networkpolicy catalogue -n sock-shop
```

### External Secrets not syncing
```bash
# Check ESO logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets -f

# Check ExternalSecret status
kubectl get externalsecret -A
kubectl describe externalsecret catalogue-db-credentials -n sock-shop

# Common causes:
#   1. IRSA role permissions missing → check Terraform IRSA module
#   2. Secret doesn't exist in Secrets Manager → aws secretsmanager get-secret-value
#   3. Wrong secret path in ExternalSecret manifest
```

---

## ArgoCD Operations

### Sync all applications
```bash
argocd app sync --all
# Or just one:
argocd app sync sock-shop
```

### View application diff (what ArgoCD will change)
```bash
argocd app diff demo-app
```

### Pause auto-sync (for manual investigation)
```bash
argocd app set sock-shop --sync-policy none
# Re-enable:
argocd app set sock-shop --sync-policy automated
```

### List all apps and their sync status
```bash
argocd app list
kubectl get applications -n argocd
```

### Refresh ArgoCD's Git cache
```bash
argocd app get platform --hard-refresh
```

---

## Secret Rotation

### Rotate a secret in AWS Secrets Manager
```bash
# Update the secret value in AWS
aws secretsmanager put-secret-value \
  --secret-id eks-gitops/catalogue-db \
  --secret-string '{"username":"root","password":"NEW_PASSWORD"}'

# ESO will pick up the change within the refreshInterval (default: 1h)
# To force immediate refresh:
kubectl annotate externalsecret catalogue-db-credentials -n sock-shop \
  force-sync=$(date +%s) --overwrite
```

### Verify the Kubernetes secret was updated
```bash
kubectl get secret catalogue-db-credentials -n sock-shop \
  -o jsonpath="{.data.password}" | base64 -d
```

---

## Node Operations

### Cordon a node (prevent new pods)
```bash
kubectl cordon NODE_NAME
```

### Drain a node (evict existing pods)
```bash
kubectl drain NODE_NAME \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60
```

### Uncordon a node
```bash
kubectl uncordon NODE_NAME
```

### Force node group rolling update (Terraform)
```bash
# Update the AMI or launch template in Terraform, then apply.
# The managed node group will roll nodes automatically.
cd infrastructure/terraform
terraform apply -target=module.eks.aws_eks_node_group.this
```

---

## Terraform Operations

### Plan changes safely
```bash
cd infrastructure/terraform
terraform plan -out=tfplan
# Review carefully before applying
terraform show tfplan
terraform apply tfplan
```

### Import an existing resource
```bash
terraform import aws_ecr_repository.apps[\"demo-app\"] demo-app
```

### Targeted apply (single resource)
```bash
terraform apply -target=module.eks.aws_eks_addon.this[\"coredns\"]
```

### State operations (use with caution)
```bash
# List state
terraform state list

# Show a resource in state
terraform state show module.eks.module.eks.aws_eks_cluster.this

# Remove from state (does NOT delete the real resource)
terraform state rm aws_ecr_repository.apps[\"demo-app\"]
```

---

## Backup & Recovery

### Backup cluster state with Velero
```bash
# Create an on-demand backup
velero backup create manual-backup-$(date +%Y%m%d) \
  --include-namespaces sock-shop,demo-app,monitoring

# Check backup status
velero backup describe manual-backup-20240101
velero backup logs manual-backup-20240101
```

### Restore from backup
```bash
velero restore create --from-backup manual-backup-20240101 \
  --include-namespaces sock-shop
```

### ArgoCD application backup
ArgoCD Application manifests are in Git — they are already backed up.
To export current state:
```bash
kubectl get applications -n argocd -o yaml > argocd-apps-backup.yaml
```

### Disaster recovery procedure
1. Provision new EKS cluster via Terraform
2. Bootstrap ArgoCD via Helm (already in `helm.tf`)
3. Apply root App-of-Apps: `kubectl apply -f apps/argocd/app-of-apps.yaml`
4. ArgoCD syncs all applications from Git automatically
5. Restore PersistentVolumes from Velero backups
6. Validate services

**Target RTO: ~30 minutes** (most time is EKS cluster provisioning ~12 min)

---

## Useful Commands Reference

```bash
# Get all failing pods
kubectl get pods -A | grep -v Running | grep -v Completed

# Get all recent events (warnings only)
kubectl get events -A --sort-by=.lastTimestamp | grep Warning | tail -20

# Check certificate expiry
kubectl get secrets -A -o json | jq '.items[] | select(.type=="kubernetes.io/tls") | {name: .metadata.name, ns: .metadata.namespace}'

# Watch ArgoCD application sync
watch -n 5 'kubectl get applications -n argocd'

# Get resource usage across namespaces
kubectl top pods -A | sort -k3 -rn | head -20

# Find pods NOT on expected nodes
kubectl get pods -n sock-shop -o wide | grep -v "application"

# Check IRSA is working for a pod
kubectl exec -it PODNAME -n NAMESPACE -- \
  aws sts get-caller-identity
```
