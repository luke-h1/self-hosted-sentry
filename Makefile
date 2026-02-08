# ──────────────────────────────────────────────
# Self-Hosted Sentry on K3s - Operations
# Budget deployment (~$7/mo on Hetzner CX33)
# ──────────────────────────────────────────────
DEPLOY_DIR := $(shell pwd)
NAMESPACE  := sentry
KUBECONFIG ?= /etc/rancher/k3s/k3s.yaml
BACKUP_DIR := /opt/sentry/backups

export KUBECONFIG

.PHONY: help preflight setup install start stop restart status pods events top \
        logs logs-web logs-worker logs-postgres \
        backup restore upgrade deploy health monitor disk cleanup \
        create-user shell-web shell-postgres ssh \
        helm-status helm-diff helm-values \
        tf-init tf-plan tf-apply tf-destroy tf-output cron-setup \
        monitoring-setup monitoring-status monitoring-logs \
        version

help: ## Show this help
	@echo ""
	@echo "Self-Hosted Sentry on K3s (~$$7/mo budget)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ── Pre-flight ──────────────────────────────

preflight: ## Run pre-deployment checks
	@echo "── Pre-flight Checks ──"
	@echo ""
	@test -f .env && echo "[PASS] .env exists" || (echo "[FAIL] .env not found" && exit 1)
	@grep -q "CHANGE_ME" .env && echo "[FAIL] Default password still in .env" && exit 1 || echo "[PASS] Password changed"
	@test -f terraform/terraform.tfvars && echo "[PASS] terraform.tfvars exists" || echo "[WARN] terraform.tfvars not found"
	@command -v kubectl >/dev/null 2>&1 && echo "[PASS] kubectl available" || echo "[INFO] kubectl not available (install on server)"
	@command -v helm >/dev/null 2>&1 && echo "[PASS] Helm installed" || echo "[INFO] Helm not installed (install on server)"
	@command -v terraform >/dev/null 2>&1 && echo "[PASS] Terraform installed" || echo "[WARN] Terraform not installed"
	@echo ""

# ── Infrastructure ──────────────────────────

tf-init: ## Initialize Terraform
	cd terraform && terraform init

tf-plan: ## Plan Terraform changes
	cd terraform && terraform plan

tf-apply: ## Apply Terraform (provision server + DNS)
	cd terraform && terraform apply

tf-destroy: ## Destroy ALL infrastructure (DANGEROUS)
	@echo "WARNING: This will destroy the server and DNS records!"
	@read -p "Type 'destroy' to confirm: " confirm && [ "$$confirm" = "destroy" ] || exit 1
	cd terraform && terraform destroy

tf-output: ## Show Terraform outputs (IP, URL, etc.)
	cd terraform && terraform output

# ── Deployment ──────────────────────────────

setup: ## [Server] Initial setup (K3s, Helm, firewall, swap)
	sudo bash scripts/setup-server.sh

install: ## [Server] Install Sentry via Helm (~15-30 min)
	sudo bash scripts/install-sentry.sh

monitoring-setup: ## [Server] Install Prometheus + Grafana
	sudo bash scripts/setup-monitoring.sh

deploy: preflight setup install monitoring-setup ## [Server] Full deployment (K3s + Sentry + monitoring)
	@echo ""
	@echo "========================================="
	@echo "  Deployment complete!"
	@echo "  Sentry: https://$$(grep SENTRY_DOMAIN .env | cut -d= -f2)"
	@echo "========================================="

# ── Service Operations ──────────────────────

start: ## Scale up all Sentry deployments
	kubectl -n $(NAMESPACE) scale deployment --all --replicas=1
	@echo "Sentry is scaling up..."

stop: ## Scale down all Sentry deployments
	kubectl -n $(NAMESPACE) scale deployment --all --replicas=0
	@echo "Sentry is scaled down"

restart: ## Rolling restart all Sentry deployments
	kubectl -n $(NAMESPACE) rollout restart deployment
	@echo "Rolling restart initiated"

status: ## Show pod and service status
	@echo "── K3s Node ──"
	@kubectl get nodes -o wide 2>/dev/null || true
	@echo ""
	@echo "── Sentry Pods ──"
	@kubectl -n $(NAMESPACE) get pods 2>/dev/null || true
	@echo ""
	@echo "── Monitoring Pods ──"
	@kubectl -n monitoring get pods 2>/dev/null || echo "  Not deployed"

pods: ## Show all pods in sentry namespace
	kubectl -n $(NAMESPACE) get pods -o wide

events: ## Show recent K8s events in sentry namespace
	kubectl -n $(NAMESPACE) get events --sort-by='.lastTimestamp' | tail -30

top: ## Show resource usage for sentry pods
	kubectl -n $(NAMESPACE) top pods 2>/dev/null || echo "Metrics server not available"

# ── Logs ────────────────────────────────────

logs: ## Tail all Sentry web logs
	kubectl -n $(NAMESPACE) logs -f -l app.kubernetes.io/name=sentry --tail=50 --max-log-requests=10

logs-web: ## Tail web pod logs
	kubectl -n $(NAMESPACE) logs -f -l app.kubernetes.io/component=web --tail=50

logs-worker: ## Tail worker pod logs
	kubectl -n $(NAMESPACE) logs -f -l app.kubernetes.io/component=worker --tail=50

logs-postgres: ## Tail PostgreSQL pod logs
	kubectl -n $(NAMESPACE) logs -f -l app.kubernetes.io/name=postgresql --tail=50

# ── Helm ────────────────────────────────────

helm-status: ## Show Helm release status
	helm -n $(NAMESPACE) status sentry

helm-diff: ## Show what would change in a Helm upgrade
	helm -n $(NAMESPACE) diff upgrade sentry sentry/sentry -f k8s/sentry-values.yaml 2>/dev/null || echo "Install helm-diff plugin: helm plugin install https://github.com/databus23/helm-diff"

helm-values: ## Show current Helm values
	helm -n $(NAMESPACE) get values sentry

# ── Monitoring ──────────────────────────────

monitoring-status: ## Show monitoring pod status
	@echo "── Monitoring Pods ──"
	@kubectl -n monitoring get pods 2>/dev/null || echo "  Not deployed"

monitoring-logs: ## Tail monitoring logs
	kubectl -n monitoring logs -f -l app=prometheus --tail=50

health: ## Health check (HTTP, pods, disk, RAM, swap)
	@bash scripts/monitor.sh

monitor: ## Health check + webhook alert on failure
	@bash scripts/monitor.sh --webhook

# ── Maintenance ─────────────────────────────

backup: ## Create verified backup
	sudo bash scripts/backup.sh

restore: ## Restore from backup (interactive)
	@echo "Available backups:"
	@ls -lh $(BACKUP_DIR)/*.tar.gz 2>/dev/null || echo "  No backups found"
	@echo ""
	@read -p "Backup file path: " backup_file && sudo bash scripts/restore.sh "$$backup_file"

cleanup: ## Clean up unused K3s images (reclaim disk space)
	sudo k3s crictl rmi --prune 2>/dev/null || true
	@echo "Cleanup complete"
	@df -h / | tail -1 | awk '{printf "  Disk: %s free\n", $$4}'

upgrade: ## Upgrade Sentry via Helm (backs up first)
	@echo "Step 1/3: Backup..."
	@sudo bash scripts/backup.sh
	@echo "Step 2/3: Helm upgrade..."
	helm repo update
	helm upgrade sentry sentry/sentry -n $(NAMESPACE) \
		-f k8s/sentry-values.yaml --reuse-values --timeout 30m --wait
	@echo "Step 3/3: Verify..."
	kubectl -n $(NAMESPACE) get pods
	@echo "Upgrade complete! Run 'make health' to verify."

# ── Cron Jobs ───────────────────────────────

cron-setup: ## Install backup + monitoring cron jobs
	@(crontab -l 2>/dev/null; \
	  echo "# Sentry backup - daily at 3:00 AM"; \
	  echo "0 3 * * * KUBECONFIG=/etc/rancher/k3s/k3s.yaml $(DEPLOY_DIR)/scripts/backup.sh >> /var/log/sentry-backup.log 2>&1"; \
	  echo "# Sentry health monitor - every 5 minutes"; \
	  echo "*/5 * * * * KUBECONFIG=/etc/rancher/k3s/k3s.yaml $(DEPLOY_DIR)/scripts/monitor.sh --webhook >> /var/log/sentry-monitor.log 2>&1"; \
	  echo "# K3s image cleanup - weekly on Sunday at 4:00 AM"; \
	  echo "0 4 * * 0 k3s crictl rmi --prune >> /var/log/sentry-cleanup.log 2>&1"; \
	) | sort -u | sudo crontab -
	@echo "Cron jobs installed:"
	@echo "  - Backup:  daily at 3:00 AM"
	@echo "  - Monitor: every 5 minutes"
	@echo "  - Cleanup: weekly (Sunday 4:00 AM)"

# ── Utilities ───────────────────────────────

shell-web: ## Shell into Sentry web pod
	kubectl -n $(NAMESPACE) exec -it $$(kubectl -n $(NAMESPACE) get pods -l app.kubernetes.io/component=web -o jsonpath='{.items[0].metadata.name}') -- bash

shell-postgres: ## Open psql in PostgreSQL pod
	kubectl -n $(NAMESPACE) exec -it $$(kubectl -n $(NAMESPACE) get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') -- psql -U postgres

ssh: ## SSH into the Sentry server
	$$(cd terraform && terraform output -raw ssh_command)

create-user: ## Create new Sentry user
	kubectl -n $(NAMESPACE) exec -it $$(kubectl -n $(NAMESPACE) get pods -l app.kubernetes.io/component=web -o jsonpath='{.items[0].metadata.name}') -- sentry createuser

disk: ## Show disk usage
	@echo "── System ──"
	@df -h / | tail -1 | awk '{printf "  Root: %s used of %s (%s free)\n", $$3, $$2, $$4}'
	@free -h | awk '/^Mem:/ {printf "  RAM:  %s used of %s\n", $$3, $$2}' 2>/dev/null || true
	@free -h | awk '/^Swap:/ {printf "  Swap: %s used of %s\n", $$3, $$2}' 2>/dev/null || true
	@echo ""
	@echo "── K8s PVCs ──"
	@kubectl -n $(NAMESPACE) get pvc 2>/dev/null || true
	@echo ""
	@echo "── Backups ──"
	@ls $(BACKUP_DIR)/*.tar.gz 2>/dev/null | wc -l | xargs -I{} echo "  Count: {} backup(s)"
	@du -sh $(BACKUP_DIR) 2>/dev/null | awk '{printf "  Size:  %s\n", $$1}' || echo "  No backups"

version: ## Show Sentry Helm release version
	@helm -n $(NAMESPACE) list 2>/dev/null || echo "Helm not available"
