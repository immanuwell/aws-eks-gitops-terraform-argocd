.PHONY: help bootstrap-state tf-init tf-plan tf-apply tf-destroy \
        kubeconfig argocd-bootstrap argocd-password lint-tf lint-k8s \
        trivy-scan update-kubeconfig rollout-status

REGION       ?= us-east-1
CLUSTER_NAME ?= eks-gitops
TF_DIR       := infrastructure/terraform

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

## ─── Infrastructure ──────────────────────────────────────────────────────────

bootstrap-state: ## Create S3 bucket + DynamoDB table for Terraform remote state
	@echo "Creating Terraform state backend in $(REGION)..."
	aws s3api create-bucket \
		--bucket eks-gitops-tfstate-$(shell aws sts get-caller-identity --query Account --output text) \
		--region $(REGION) \
		$(if $(filter-out us-east-1,$(REGION)),--create-bucket-configuration LocationConstraint=$(REGION),)
	aws s3api put-bucket-versioning \
		--bucket eks-gitops-tfstate-$(shell aws sts get-caller-identity --query Account --output text) \
		--versioning-configuration Status=Enabled
	aws s3api put-bucket-encryption \
		--bucket eks-gitops-tfstate-$(shell aws sts get-caller-identity --query Account --output text) \
		--server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
	aws dynamodb create-table \
		--table-name terraform-state-lock \
		--attribute-definitions AttributeName=LockID,AttributeType=S \
		--key-schema AttributeName=LockID,KeyType=HASH \
		--billing-mode PAY_PER_REQUEST \
		--region $(REGION)
	@echo "Done. Update backend.tf with your bucket name."

tf-init: ## Initialize Terraform
	cd $(TF_DIR) && terraform init

tf-plan: ## Run Terraform plan
	cd $(TF_DIR) && terraform plan -out=tfplan

tf-apply: ## Apply Terraform plan
	cd $(TF_DIR) && terraform apply tfplan

tf-destroy: ## Destroy all infrastructure (DESTRUCTIVE)
	@echo "WARNING: This will destroy all infrastructure!"
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ]
	cd $(TF_DIR) && terraform destroy

tf-validate: ## Validate Terraform configuration
	cd $(TF_DIR) && terraform validate

tf-fmt: ## Format Terraform files
	cd $(TF_DIR) && terraform fmt -recursive

## ─── Cluster ─────────────────────────────────────────────────────────────────

kubeconfig: ## Update kubeconfig for the EKS cluster
	aws eks update-kubeconfig \
		--region $(REGION) \
		--name $(CLUSTER_NAME)

## ─── ArgoCD ──────────────────────────────────────────────────────────────────

argocd-bootstrap: ## Apply root App-of-Apps to bootstrap ArgoCD
	kubectl apply -f apps/argocd/app-of-apps.yaml

argocd-password: ## Get ArgoCD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath="{.data.password}" | base64 -d && echo

argocd-sync: ## Force sync all ArgoCD applications
	argocd app sync --all

argocd-ui: ## Port-forward ArgoCD UI to localhost:8080
	kubectl port-forward svc/argocd-server -n argocd 8080:443

## ─── Observability ───────────────────────────────────────────────────────────

grafana-ui: ## Port-forward Grafana to localhost:3000
	kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80

grafana-password: ## Get Grafana admin password
	@kubectl -n monitoring get secret kube-prometheus-stack-grafana \
		-o jsonpath="{.data.admin-password}" | base64 -d && echo

## ─── Deployments ─────────────────────────────────────────────────────────────

rollout-status: ## Check Argo Rollouts status for demo-app
	kubectl argo rollouts get rollout demo-app -n demo-app --watch

rollout-promote: ## Promote blue-green rollout
	kubectl argo rollouts promote demo-app -n demo-app

rollout-abort: ## Abort rollout and rollback
	kubectl argo rollouts abort demo-app -n demo-app

## ─── Security / Linting ──────────────────────────────────────────────────────

lint-tf: ## Lint Terraform with tflint
	cd $(TF_DIR) && tflint --recursive

lint-k8s: ## Lint Kubernetes manifests with kubeval
	find apps/ -name "*.yaml" -not -path "*/Chart.yaml" | \
		xargs kubeval --strict --ignore-missing-schemas

trivy-iac: ## Scan IaC for misconfigurations
	trivy config infrastructure/

trivy-image: ## Scan demo-app Docker image
	trivy image $(REGISTRY)/demo-app:latest

kyverno-test: ## Run Kyverno policy tests
	kyverno test apps/security/kyverno/

## ─── Utility ─────────────────────────────────────────────────────────────────

cluster-info: ## Show cluster info and key workloads
	@echo "=== Nodes ==="
	kubectl get nodes -o wide
	@echo "\n=== ArgoCD Applications ==="
	kubectl get applications -n argocd
	@echo "\n=== HPA ==="
	kubectl get hpa -A
	@echo "\n=== Ingresses ==="
	kubectl get ingress -A
