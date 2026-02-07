#!/usr/bin/env bash
# Clone official self-hosted Sentry, configure, and install.
# Tuned for CX22 (4GB RAM). Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SENTRY_INSTALL_DIR="/opt/sentry/self-hosted"
LOG_FILE="/var/log/sentry-install.log"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
else
  echo "ERROR: .env not found. Copy .env.example to .env and configure it."; exit 1
fi

# Data directory: mounted volume if available, otherwise local disk
if mountpoint -q /mnt/sentry-data 2>/dev/null; then
  SENTRY_DATA_DIR="/mnt/sentry-data"
else
  SENTRY_DATA_DIR="/opt/sentry/data"
fi

# Validate
for var in SENTRY_DOMAIN SENTRY_ADMIN_EMAIL SENTRY_ADMIN_PASSWORD; do
  [[ -z "${!var:-}" ]] && echo "ERROR: $var not set in .env" && exit 1
done
[[ "${SENTRY_ADMIN_PASSWORD}" == "CHANGE_ME_TO_A_STRONG_PASSWORD" ]] && echo "ERROR: change the default password" && exit 1
[[ ${#SENTRY_ADMIN_PASSWORD} -lt 12 ]] && echo "ERROR: password must be >= 12 chars" && exit 1

echo "Installing Sentry -> ${SENTRY_INSTALL_DIR} (data: ${SENTRY_DATA_DIR})"
exec > >(tee -a "$LOG_FILE") 2>&1

# Pre-flight
echo "[0/8] Pre-flight checks..."
TOTAL_MEM_GB=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024))
TOTAL_SWAP_GB=$(($(grep SwapTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024))
AVAIL_DISK=$(df -BG /opt | tail -1 | awk '{print $4}' | tr -d 'G')

[[ $TOTAL_MEM_GB -lt 3 ]] && echo "ERROR: need >= 4GB RAM" && exit 1
[[ $TOTAL_MEM_GB -lt 7 ]] && [[ $TOTAL_SWAP_GB -lt 4 ]] && echo "WARNING: low RAM + swap. Run setup-server.sh first."
[[ $AVAIL_DISK -lt 15 ]] && echo "ERROR: need >= 15GB free disk" && exit 1
command -v docker &>/dev/null || { echo "ERROR: Docker not installed"; exit 1; }
docker compose version &>/dev/null || { echo "ERROR: Docker Compose not found"; exit 1; }
echo "  ${TOTAL_MEM_GB}GB RAM + ${TOTAL_SWAP_GB}GB swap, ${AVAIL_DISK}GB disk free"

# Clone
echo "[1/8] Cloning self-hosted Sentry..."
if [[ -d "$SENTRY_INSTALL_DIR" ]]; then
  cd "$SENTRY_INSTALL_DIR" && git fetch --tags
else
  mkdir -p "$(dirname "$SENTRY_INSTALL_DIR")"
  git clone https://github.com/getsentry/self-hosted.git "$SENTRY_INSTALL_DIR"
  cd "$SENTRY_INSTALL_DIR"
fi
LATEST_TAG=$(git describe --tags "$(git rev-list --tags --max-count=1)")
git checkout "$LATEST_TAG"
echo "  version: $LATEST_TAG"

# Data dirs
echo "[2/8] Setting up data directories..."
mkdir -p "$SENTRY_DATA_DIR"/{postgres,clickhouse,kafka,symbolicator,redis,zookeeper,filestore,backups}
if [[ "$SENTRY_DATA_DIR" != "$SENTRY_INSTALL_DIR/volumes" ]]; then
  for dir in postgres clickhouse kafka redis zookeeper; do
    target="$SENTRY_INSTALL_DIR/volumes/$dir"
    [[ -L "$target" ]] && continue
    [[ -d "$target" ]] && cp -a "$target/." "$SENTRY_DATA_DIR/$dir/" 2>/dev/null || true && rm -rf "$target"
    ln -sf "$SENTRY_DATA_DIR/$dir" "$target"
  done
fi

# Secret key
echo "[3/8] Secret key..."
SECRET_KEY_FILE="$SENTRY_DATA_DIR/.secret-key"
if [[ ! -f "$SECRET_KEY_FILE" ]]; then
  python3 -c "import secrets; print(secrets.token_hex(32))" > "$SECRET_KEY_FILE"
  chmod 600 "$SECRET_KEY_FILE"
fi
SENTRY_SECRET_KEY=$(cat "$SECRET_KEY_FILE")

# Config
echo "[4/8] Writing configuration..."
cat > "$SENTRY_INSTALL_DIR/sentry/sentry.conf.py" <<PYCONF
from sentry.conf.server import *  # noqa

SENTRY_OPTIONS["system.url-prefix"] = "https://${SENTRY_DOMAIN}"
SENTRY_OPTIONS["system.admin-email"] = "${SENTRY_ADMIN_EMAIL}"
SENTRY_OPTIONS["system.secret-key"] = "${SENTRY_SECRET_KEY}"
SENTRY_OPTIONS["mail.from"] = "${SENTRY_MAIL_FROM:-noreply@${SENTRY_DOMAIN}}"
SENTRY_OPTIONS["mail.host"] = "${SENTRY_MAIL_HOST:-localhost}"
SENTRY_OPTIONS["mail.port"] = ${SENTRY_MAIL_PORT:-587}
SENTRY_OPTIONS["mail.username"] = "${SENTRY_MAIL_USERNAME:-}"
SENTRY_OPTIONS["mail.password"] = "${SENTRY_MAIL_PASSWORD:-}"
SENTRY_OPTIONS["mail.use-tls"] = ${SENTRY_MAIL_USE_TLS:-True}
SENTRY_OPTIONS["mail.use-ssl"] = False
SENTRY_OPTIONS["store.transactions-sample-rate"] = 0.5

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True
SESSION_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Lax"
CSRF_COOKIE_SECURE = True
CSRF_COOKIE_HTTPONLY = True
CSRF_TRUSTED_ORIGINS = ["https://${SENTRY_DOMAIN}"]
SOCIAL_AUTH_REDIRECT_IS_HTTPS = True
SENTRY_RATELIMITER_OPTIONS = {}
PYCONF

cat > "$SENTRY_INSTALL_DIR/sentry/config.yml" <<YAMLCONF
system.url-prefix: 'https://${SENTRY_DOMAIN}'
system.admin-email: '${SENTRY_ADMIN_EMAIL}'
system.internal-url-prefix: 'http://web:9000'
system.secret-key: '${SENTRY_SECRET_KEY}'

auth.allow-registration: false
auth.ip-rate-limit: 10
auth.user-rate-limit: 5

mail.from: '${SENTRY_MAIL_FROM:-noreply@${SENTRY_DOMAIN}}'
mail.host: '${SENTRY_MAIL_HOST:-localhost}'
mail.port: ${SENTRY_MAIL_PORT:-587}
mail.username: '${SENTRY_MAIL_USERNAME:-}'
mail.password: '${SENTRY_MAIL_PASSWORD:-}'
mail.use-tls: true
mail.use-ssl: false

beacon.anonymous: true

filestore.backend: 'filesystem'
filestore.options:
  location: '/data/files'
YAMLCONF

echo "[5/8] Writing .env..."
cat > "$SENTRY_INSTALL_DIR/.env" <<ENVFILE
SENTRY_EVENT_RETENTION_DAYS=${SENTRY_EVENT_RETENTION_DAYS:-30}
SENTRY_BIND=9000
SENTRY_MAIL_HOST=${SENTRY_MAIL_HOST:-localhost}
SENTRY_SECRET_KEY=${SENTRY_SECRET_KEY}
COMPOSE_PROFILES=
ENVFILE

echo "[6/8] Copying docker-compose override..."
[[ -f "$PROJECT_DIR/docker-compose.override.yml" ]] && cp "$PROJECT_DIR/docker-compose.override.yml" "$SENTRY_INSTALL_DIR/"

echo "[7/8] Running installer (15-30 min on CX22)..."
cd "$SENTRY_INSTALL_DIR"
./install.sh --skip-user-creation --no-report-self-hosted-issues

echo "[8/8] Creating admin user..."
docker compose run --rm web createuser \
  --email "${SENTRY_ADMIN_EMAIL}" \
  --password "${SENTRY_ADMIN_PASSWORD}" \
  --superuser --no-input 2>/dev/null || echo "  (may already exist)"

# Systemd service
cat > /etc/systemd/system/sentry.service <<SYSTEMD
[Unit]
Description=Self-Hosted Sentry
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${SENTRY_INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=600
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
SYSTEMD
systemctl daemon-reload && systemctl enable sentry.service

mkdir -p /etc/sentry
echo "${SENTRY_DATA_DIR}" > /etc/sentry/data_dir

echo ""
echo "Done. Version: $LATEST_TAG"
echo "Next: ./scripts/setup-nginx.sh"
