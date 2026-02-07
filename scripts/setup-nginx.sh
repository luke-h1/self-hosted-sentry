#!/usr/bin/env bash
# Configure Nginx as reverse proxy with Cloudflare Origin Certificate.
# Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
else
  echo "ERROR: .env not found"; exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root"; exit 1
fi

echo "[1/7] Setting up SSL directory..."
mkdir -p /etc/nginx/ssl && chmod 700 /etc/nginx/ssl

echo "[2/7] Checking SSL certificates..."
if [[ ! -f /etc/nginx/ssl/cloudflare-origin.pem ]] || [[ ! -f /etc/nginx/ssl/cloudflare-origin-key.pem ]]; then
  echo ""
  echo "  Cloudflare Origin Certificate not found."
  echo "  1. Cloudflare Dashboard > SSL/TLS > Origin Server > Create Certificate"
  echo "  2. Save to /etc/nginx/ssl/cloudflare-origin.pem and cloudflare-origin-key.pem"
  echo "  3. Re-run this script."
  echo ""
  exit 1
fi
chmod 600 /etc/nginx/ssl/cloudflare-origin-key.pem

if ! openssl x509 -noout -in /etc/nginx/ssl/cloudflare-origin.pem 2>/dev/null; then
  echo "ERROR: certificate is invalid"; exit 1
fi
echo "  expires: $(openssl x509 -enddate -noout -in /etc/nginx/ssl/cloudflare-origin.pem | cut -d= -f2)"

echo "[3/7] Setting up Authenticated Origin Pulls..."
CF_AOP_CA="/etc/nginx/ssl/cloudflare-authenticated-origin-pull-ca.pem"
if [[ ! -f "$CF_AOP_CA" ]]; then
  curl -sf -o "$CF_AOP_CA" \
    "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem" || {
    echo "  Could not download CA. Skipping."
  }
fi

echo "[4/7] Applying Nginx performance config..."
cat > /etc/nginx/conf.d/performance.conf <<'EOF'
keepalive_timeout 65;
keepalive_requests 1000;
proxy_temp_path /var/cache/nginx/proxy_temp;
proxy_cache_path /var/cache/nginx/proxy_cache levels=1:2 keys_zone=sentry_cache:10m max_size=100m inactive=60m;
EOF
mkdir -p /var/cache/nginx/{proxy_temp,proxy_cache}

echo "[5/7] Installing Nginx config..."
cp "$PROJECT_DIR/nginx/sentry.conf" /etc/nginx/sites-available/sentry
sed -i "s/SENTRY_DOMAIN/${SENTRY_DOMAIN}/g" /etc/nginx/sites-available/sentry

if [[ -f "$CF_AOP_CA" ]]; then
  sed -i 's|# ssl_client_certificate|ssl_client_certificate|' /etc/nginx/sites-available/sentry
  sed -i 's|# ssl_verify_client|ssl_verify_client|' /etc/nginx/sites-available/sentry
  echo "  Authenticated Origin Pulls: enabled"
fi

ln -sf /etc/nginx/sites-available/sentry /etc/nginx/sites-enabled/sentry
rm -f /etc/nginx/sites-enabled/default

echo "[6/7] Testing config..."
nginx -t || { echo "ERROR: config test failed"; exit 1; }

echo "[7/7] Reloading Nginx..."
systemctl reload nginx && systemctl enable nginx

echo ""
echo "Proxying https://${SENTRY_DOMAIN} -> localhost:9000"
