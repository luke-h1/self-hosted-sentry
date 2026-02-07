#!/usr/bin/env bash
# Deploy Prometheus + Grafana alongside Sentry.
# Grafana accessible at https://SENTRY_DOMAIN/grafana/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root"; exit 1
fi

GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-admin}"
if [[ "$GRAFANA_PASS" == "admin" ]]; then
  echo "WARNING: default Grafana password. Set GRAFANA_ADMIN_PASSWORD in .env."
fi

echo "[1/4] Configuring Nginx stub_status..."
cat > /etc/nginx/conf.d/stub-status.conf <<'EOF'
server {
    listen 127.0.0.1:9000;
    server_name _;
    location /stub_status {
        stub_status;
        allow 127.0.0.1;
        allow 172.16.0.0/12;
        deny all;
    }
}
EOF

echo "[2/4] Adding Grafana proxy to Nginx..."
if ! grep -q "location /grafana/" /etc/nginx/sites-available/sentry 2>/dev/null; then
  sed -i '/location ~ \/\./i\
    location /grafana/ {\
        proxy_pass http://127.0.0.1:3000/grafana/;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\
        proxy_set_header X-Forwarded-Proto $scheme;\
        proxy_http_version 1.1;\
        proxy_set_header Upgrade $http_upgrade;\
        proxy_set_header Connection $connection_upgrade;\
    }\
' /etc/nginx/sites-available/sentry
fi
nginx -t && systemctl reload nginx

echo "[3/4] Starting monitoring containers..."
cd "$PROJECT_DIR"
export SENTRY_DOMAIN="${SENTRY_DOMAIN:-localhost}"
export GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
docker compose -f monitoring/docker-compose.yml up -d
sleep 10

echo "[4/4] Verifying..."
PROM=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:9090/-/healthy 2>/dev/null || echo "000")
GRAF=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/grafana/api/health 2>/dev/null || echo "000")

[[ "$PROM" == "200" ]] && echo "  Prometheus: OK" || echo "  Prometheus: FAIL (HTTP $PROM)"
[[ "$GRAF" == "200" ]] && echo "  Grafana: OK" || echo "  Grafana: FAIL (HTTP $GRAF)"

echo ""
echo "Grafana: https://${SENTRY_DOMAIN}/grafana/"
echo "Login:   ${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD}"
