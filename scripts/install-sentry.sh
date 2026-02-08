#!/usr/bin/env bash
# Install Sentry via Helm on K3s.
# Tuned for CX33 (8GB RAM). Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/var/log/sentry-install.log"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
else
  echo "ERROR: .env not found. Copy .env.example to .env and configure it."; exit 1
fi

# Validate
for var in SENTRY_DOMAIN SENTRY_ADMIN_EMAIL SENTRY_ADMIN_PASSWORD; do
  [[ -z "${!var:-}" ]] && echo "ERROR: $var not set in .env" && exit 1
done
[[ "${SENTRY_ADMIN_PASSWORD}" == "CHANGE_ME_TO_A_STRONG_PASSWORD" ]] && echo "ERROR: change the default password" && exit 1
[[ ${#SENTRY_ADMIN_PASSWORD} -lt 12 ]] && echo "ERROR: password must be >= 12 chars" && exit 1

echo "Installing Sentry via Helm on K3s"
exec > >(tee -a "$LOG_FILE") 2>&1

# Pre-flight
echo "[0/4] Pre-flight checks..."
TOTAL_MEM_GB=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024))
TOTAL_SWAP_GB=$(($(grep SwapTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024))
AVAIL_DISK=$(df -BG /opt | tail -1 | awk '{print $4}' | tr -d 'G')

[[ $TOTAL_MEM_GB -lt 3 ]] && echo "ERROR: need >= 4GB RAM" && exit 1
[[ $AVAIL_DISK -lt 15 ]] && echo "ERROR: need >= 15GB free disk" && exit 1
command -v kubectl &>/dev/null || { echo "ERROR: kubectl not found (is K3s installed?)"; exit 1; }
command -v helm &>/dev/null || { echo "ERROR: Helm not found"; exit 1; }
kubectl get nodes &>/dev/null || { echo "ERROR: K3s not ready"; exit 1; }
echo "  ${TOTAL_MEM_GB}GB RAM + ${TOTAL_SWAP_GB}GB swap, ${AVAIL_DISK}GB disk free"

# Namespace
echo "[1/4] Creating namespace..."
kubectl create namespace sentry --dry-run=client -o yaml | kubectl apply -f -

# ClickHouse
echo "[2/4] Deploying ClickHouse..."
kubectl apply -f "$PROJECT_DIR/k8s/clickhouse.yaml"
echo "  Waiting for ClickHouse to be ready..."
kubectl -n sentry rollout status statefulset/clickhouse --timeout=300s || true

# Helm install/upgrade
echo "[3/4] Installing Sentry via Helm (this may take 15-30 min)..."
helm repo add sentry https://sentry-kubernetes.github.io/charts 2>/dev/null || true
helm repo update

MAIL_FROM="${SENTRY_MAIL_FROM:-noreply@${SENTRY_DOMAIN}}"
MAIL_HOST="${SENTRY_MAIL_HOST:-localhost}"
MAIL_PORT="${SENTRY_MAIL_PORT:-587}"
MAIL_USER="${SENTRY_MAIL_USERNAME:-}"
MAIL_PASS="${SENTRY_MAIL_PASSWORD:-}"

# Build common Helm --set args
HELM_SETS=(
  --set "system.url=https://${SENTRY_DOMAIN}"
  --set "user.email=${SENTRY_ADMIN_EMAIL}"
  --set "user.password=${SENTRY_ADMIN_PASSWORD}"
  --set "mail.from=${MAIL_FROM}"
  --set "mail.host=${MAIL_HOST}"
  --set "mail.port=${MAIL_PORT}"
  --set "mail.username=${MAIL_USER}"
  --set "mail.password=${MAIL_PASS}"
  --set "ingress.hostname=${SENTRY_DOMAIN}"
  --set "config.configYml.system\\.url-prefix=https://${SENTRY_DOMAIN}"
  --set "sentry.web.env[4].name=SENTRY_CSRF_TRUSTED_ORIGIN"
  --set "sentry.web.env[4].value=https://${SENTRY_DOMAIN}"
  --set "sentry.web.env[5].name=SENTRY_ADMIN_EMAIL"
  --set "sentry.web.env[5].value=${SENTRY_ADMIN_EMAIL}"
)

# GitHub OAuth (optional)
if [[ -n "${GITHUB_APP_ID:-}" ]]; then
  HELM_SETS+=(
    --set "github.appId=${GITHUB_APP_ID}"
    --set "github.appName=${GITHUB_APP_NAME:-}"
    --set "github.secret=${GITHUB_APP_SECRET:-}"
    --set "github.webhookSecret=${GITHUB_WEBHOOK_SECRET:-}"
    --set "github.clientId=${GITHUB_CLIENT_ID:-}"
    --set "github.clientSecret=${GITHUB_CLIENT_SECRET:-}"
  )
  # privateKey needs --set-file
  if [[ -f "${GITHUB_PRIVATE_KEY_PATH:-}" ]]; then
    HELM_SETS+=(--set-file "github.privateKey=${GITHUB_PRIVATE_KEY_PATH}")
  fi
fi

if helm status sentry -n sentry &>/dev/null; then
  echo "  Upgrading existing release..."
  helm upgrade sentry sentry/sentry -n sentry \
    -f "$PROJECT_DIR/k8s/sentry-values.yaml" \
    "${HELM_SETS[@]}" \
    --timeout 30m --wait
else
  echo "  Fresh install..."
  helm install sentry sentry/sentry -n sentry \
    -f "$PROJECT_DIR/k8s/sentry-values.yaml" \
    "${HELM_SETS[@]}" \
    --timeout 30m --wait
fi

echo "[4/5] Seeding database options..."
# The Helm chart's sentry.conf.py sets mail options in SENTRY_OPTIONS, making
# them immutable via the admin UI. Our sentryConfPy deletes them so Sentry reads
# from the database instead. Seed the DB with the correct values here.
echo "  Waiting for web pod to be ready..."
kubectl -n sentry rollout status deploy/sentry-web --timeout=300s || true

kubectl -n sentry exec deploy/sentry-web -- sentry django shell -c "
from sentry.models.options.option import Option
from django.utils import timezone
import json, os

options = {
    'mail.from': os.getenv('SENTRY_EMAIL_FROM', ''),
    'mail.host': os.getenv('SENTRY_EMAIL_HOST', ''),
    'mail.port': int(os.getenv('SENTRY_EMAIL_PORT', '25')),
    'mail.username': os.getenv('SENTRY_EMAIL_USERNAME', ''),
    'mail.password': os.getenv('SENTRY_EMAIL_PASSWORD', ''),
    'mail.use-tls': os.getenv('SENTRY_EMAIL_USE_TLS', 'false').lower() in ('true', '1', 'yes'),
    'mail.use-ssl': os.getenv('SENTRY_EMAIL_USE_SSL', 'false').lower() in ('true', '1', 'yes'),
    'mail.backend': 'smtp',
    'auth.allow-registration': False,
    'beacon.anonymous': True,
    'system.admin-email': os.getenv('SENTRY_ADMIN_EMAIL', ''),
}

for key, value in options.items():
    Option.objects.update_or_create(
        key=key,
        defaults={'value': json.dumps(value), 'last_updated': timezone.now()}
    )
print('Database options seeded successfully')
" 2>/dev/null && echo "  Done" || echo "  WARNING: could not seed options (non-fatal)"

echo "[5/5] Verifying..."
kubectl -n sentry get pods
echo ""

HTTP=$(curl -sf -o /dev/null -w "%{http_code}" -H "Host: ${SENTRY_DOMAIN}" --max-time 15 http://127.0.0.1/_health/ 2>/dev/null || echo "000")
if [[ "$HTTP" == "200" ]]; then
  echo "Sentry is healthy (HTTP 200)"
else
  echo "WARNING: Sentry returned HTTP $HTTP (may still be starting up)"
fi

echo ""
echo "Done. URL: https://${SENTRY_DOMAIN}"
echo "Pods: kubectl -n sentry get pods"
