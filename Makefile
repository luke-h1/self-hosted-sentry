# ──────────────────────────────────────────────
# Self-Hosted Sentry - Operations
# Budget deployment (~$4/mo on Hetzner CX22)
# ──────────────────────────────────────────────
SENTRY_DIR ?= /opt/sentry/self-hosted
DEPLOY_DIR := $(shell pwd)

# Determine data directory
SENTRY_DATA_DIR := $(shell cat /etc/sentry/data_dir 2>/dev/null || (mountpoint -q /mnt/sentry-data 2>/dev/null && echo /mnt/sentry-data) || echo /opt/sentry/data)

.PHONY: help preflight setup install nginx start stop restart status logs backup restore \
        upgrade deploy health monitor disk cleanup create-user shell-web shell-postgres \
        tf-init tf-plan tf-apply tf-destroy tf-output cron-setup \
        monitoring-up monitoring-down monitoring-restart monitoring-logs monitoring-status

help: ## Show this help
	@echo ""
	@echo "Self-Hosted Sentry (~$$4/mo budget)"
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
	@command -v docker >/dev/null 2>&1 && echo "[PASS] Docker installed" || echo "[INFO] Docker not installed (install on server)"
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

setup: ## [Server] Initial setup (Docker, firewall, 8GB swap)
	sudo bash scripts/setup-server.sh

install: ## [Server] Install Sentry (~15-30 min on CX22)
	sudo bash scripts/install-sentry.sh

nginx: ## [Server] Configure Nginx + Cloudflare SSL
	sudo bash scripts/setup-nginx.sh

monitoring-setup: ## [Server] Install Prometheus + Grafana monitoring
	sudo bash scripts/setup-monitoring.sh

deploy: preflight setup install nginx start monitoring-setup ## [Server] Full deployment (Sentry + monitoring)
	@echo ""
	@echo "========================================="
	@echo "  Deployment complete!"
	@echo "  Sentry:  https://$$(grep SENTRY_DOMAIN .env | cut -d= -f2)"
	@echo "  Grafana: https://$$(grep SENTRY_DOMAIN .env | cut -d= -f2)/grafana/"
	@echo "========================================="

# ── Service Operations ──────────────────────

start: ## Start Sentry
	@if systemctl is-active --quiet sentry 2>/dev/null; then \
		echo "Sentry is already running"; \
	else \
		sudo systemctl start sentry; \
		echo "Sentry is starting up (may take a minute on CX22)..."; \
		echo "Check status: make status"; \
	fi

stop: ## Stop Sentry
	sudo systemctl stop sentry

restart: ## Restart Sentry
	sudo systemctl restart sentry

status: ## Show service status
	@echo "── Systemd ──"
	@sudo systemctl status sentry --no-pager 2>/dev/null || true
	@echo ""
	@echo "── Sentry Containers ──"
	@cd $(SENTRY_DIR) && docker compose ps 2>/dev/null || true
	@echo ""
	@echo "── Monitoring Containers ──"
	@docker compose -f $(DEPLOY_DIR)/monitoring/docker-compose.yml ps 2>/dev/null || echo "  Not running"

logs: ## Tail all Sentry logs
	cd $(SENTRY_DIR) && docker compose logs -f --tail=50

logs-web: ## Tail web logs
	cd $(SENTRY_DIR) && docker compose logs -f --tail=50 web

logs-worker: ## Tail worker logs
	cd $(SENTRY_DIR) && docker compose logs -f --tail=50 worker

logs-nginx: ## Tail Nginx logs
	sudo tail -f /var/log/nginx/sentry-access.log /var/log/nginx/sentry-error.log

logs-postgres: ## Tail PostgreSQL logs
	cd $(SENTRY_DIR) && docker compose logs -f --tail=50 postgres

# ── Monitoring ──────────────────────────────

monitoring-up: ## Start Prometheus + Grafana
	cd $(DEPLOY_DIR) && docker compose -f monitoring/docker-compose.yml up -d
	@echo "Grafana: https://$$(grep SENTRY_DOMAIN .env 2>/dev/null | cut -d= -f2)/grafana/"

monitoring-down: ## Stop Prometheus + Grafana
	cd $(DEPLOY_DIR) && docker compose -f monitoring/docker-compose.yml down

monitoring-restart: ## Restart monitoring stack
	cd $(DEPLOY_DIR) && docker compose -f monitoring/docker-compose.yml restart

monitoring-logs: ## Tail monitoring stack logs
	cd $(DEPLOY_DIR) && docker compose -f monitoring/docker-compose.yml logs -f --tail=50

monitoring-status: ## Show monitoring container status
	@echo "── Monitoring ──"
	@cd $(DEPLOY_DIR) && docker compose -f monitoring/docker-compose.yml ps
	@echo ""
	@echo "── Prometheus targets ──"
	@curl -sf http://127.0.0.1:9090/api/v1/targets 2>/dev/null | jq -r '.data.activeTargets[] | "\(.labels.job): \(.health)"' 2>/dev/null || echo "  Prometheus not reachable"

health: ## Health check (HTTP, containers, disk, RAM, swap)
	@bash scripts/monitor.sh

monitor: ## Health check + webhook alert on failure
	@bash scripts/monitor.sh --webhook

# ── Maintenance ─────────────────────────────

backup: ## Create verified backup
	sudo bash scripts/backup.sh

restore: ## Restore from backup (interactive)
	@echo "Available backups:"
	@ls -lh $(SENTRY_DATA_DIR)/backups/*.tar.gz 2>/dev/null || echo "  No backups found"
	@echo ""
	@read -p "Backup file path: " backup_file && sudo bash scripts/restore.sh "$$backup_file"

cleanup: ## Clean up Docker (reclaim disk space)
	cd $(SENTRY_DIR) && docker compose down --remove-orphans
	docker system prune -f
	docker image prune -a -f --filter "until=72h"
	@echo "Cleanup complete"
	@df -h / | tail -1 | awk '{printf "  Disk: %s free\n", $$4}'

upgrade: ## Upgrade Sentry (backs up first)
	@echo "Step 1/4: Backup..."
	@sudo bash scripts/backup.sh
	@echo "Step 2/4: Pull latest..."
	cd $(SENTRY_DIR) && git fetch --tags
	cd $(SENTRY_DIR) && git checkout $$(git describe --tags $$(git rev-list --tags --max-count=1))
	@echo "Step 3/4: Reinstall..."
	cd $(SENTRY_DIR) && ./install.sh --skip-user-creation --no-report-self-hosted-issues
	@echo "Step 4/4: Restart..."
	cd $(SENTRY_DIR) && docker compose up -d
	@echo "Upgrade complete! Run 'make health' to verify."

# ── Cron Jobs ───────────────────────────────

cron-setup: ## Install backup + monitoring cron jobs
	@(crontab -l 2>/dev/null; \
	  echo "# Sentry backup - daily at 3:00 AM"; \
	  echo "0 3 * * * $(DEPLOY_DIR)/scripts/backup.sh >> /var/log/sentry-backup.log 2>&1"; \
	  echo "# Sentry health monitor - every 5 minutes"; \
	  echo "*/5 * * * * $(DEPLOY_DIR)/scripts/monitor.sh --webhook >> /var/log/sentry-monitor.log 2>&1"; \
	  echo "# Docker cleanup - weekly on Sunday at 4:00 AM"; \
	  echo "0 4 * * 0 docker system prune -f >> /var/log/sentry-cleanup.log 2>&1"; \
	) | sort -u | sudo crontab -
	@echo "Cron jobs installed:"
	@echo "  - Backup:  daily at 3:00 AM"
	@echo "  - Monitor: every 5 minutes"
	@echo "  - Cleanup: weekly (Sunday 4:00 AM)"

# ── Utilities ───────────────────────────────

shell-web: ## Shell into web container
	cd $(SENTRY_DIR) && docker compose exec web bash

shell-postgres: ## Open psql
	cd $(SENTRY_DIR) && docker compose exec postgres psql -U postgres

create-user: ## Create new Sentry user
	cd $(SENTRY_DIR) && docker compose run --rm web createuser

disk: ## Show disk usage
	@echo "── System ──"
	@df -h / | tail -1 | awk '{printf "  Root: %s used of %s (%s free)\n", $$3, $$2, $$4}'
	@free -h | awk '/^Mem:/ {printf "  RAM:  %s used of %s\n", $$3, $$2}'
	@free -h | awk '/^Swap:/ {printf "  Swap: %s used of %s\n", $$3, $$2}'
	@echo ""
	@echo "── Docker ──"
	@docker system df 2>/dev/null || true
	@echo ""
	@echo "── Backups ──"
	@ls $(SENTRY_DATA_DIR)/backups/*.tar.gz 2>/dev/null | wc -l | xargs -I{} echo "  Count: {} backup(s)"
	@du -sh $(SENTRY_DATA_DIR)/backups 2>/dev/null | awk '{printf "  Size:  %s\n", $$1}' || echo "  No backups"

version: ## Show Sentry version
	@cd $(SENTRY_DIR) && git describe --tags 2>/dev/null || echo "unknown"
