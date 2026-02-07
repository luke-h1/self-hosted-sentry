#!/usr/bin/env bash
# Health check for self-hosted Sentry.
# Usage: ./monitor.sh [--webhook]
set -euo pipefail

SENTRY_DIR="/opt/sentry/self-hosted"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

WEBHOOK_URL="${MONITOR_WEBHOOK_URL:-}"
SEND_WEBHOOK=false
EXIT_CODE=0
ISSUES=()

[[ "${1:-}" == "--webhook" ]] && SEND_WEBHOOK=true

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; ISSUES+=("$1"); EXIT_CODE=1; }
warn() { echo "  [WARN] $1"; }

echo "Health check - $(date -Iseconds)"

# Sentry HTTP
HTTP=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 15 http://127.0.0.1:9000/_health/ 2>/dev/null || echo "000")
[[ "$HTTP" == "200" ]] && pass "Sentry (HTTP $HTTP)" || fail "Sentry (HTTP $HTTP)"

# Containers
cd "$SENTRY_DIR"
UNHEALTHY=(); STOPPED=()
while IFS= read -r line; do
  NAME=$(echo "$line" | awk '{print $1}')
  STATUS=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
  [[ "$STATUS" == *"unhealthy"* ]] && UNHEALTHY+=("$NAME")
  [[ "$STATUS" == *"Exit"* || "$STATUS" == *"exited"* ]] && STOPPED+=("$NAME")
done < <(docker compose ps --format "{{.Name}} {{.Status}}" 2>/dev/null)

RUNNING=$(docker compose ps --status running -q 2>/dev/null | wc -l)
[[ ${#UNHEALTHY[@]} -gt 0 ]] && fail "Unhealthy: ${UNHEALTHY[*]}" || pass "No unhealthy containers"
[[ ${#STOPPED[@]} -gt 0 ]] && fail "Stopped: ${STOPPED[*]}" || pass "$RUNNING containers running"

# Disk
ROOT_PCT=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
ROOT_FREE=$(df -h / | tail -1 | awk '{print $4}')
[[ $ROOT_PCT -gt 90 ]] && fail "Disk ${ROOT_PCT}% ($ROOT_FREE free)" || [[ $ROOT_PCT -gt 80 ]] && warn "Disk ${ROOT_PCT}%" || pass "Disk ${ROOT_PCT}% ($ROOT_FREE free)"

# Memory
MEM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
MEM_USED=$(free -m | awk '/^Mem:/ {print $3}')
pass "RAM: $((MEM_USED * 100 / MEM_TOTAL))% (${MEM_USED}M/${MEM_TOTAL}M)"

SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')
SWAP_USED=$(free -m | awk '/^Swap:/ {print $3}')
[[ $SWAP_TOTAL -gt 0 ]] && { PCT=$((SWAP_USED * 100 / SWAP_TOTAL)); [[ $PCT -gt 80 ]] && warn "Swap: ${PCT}%" || pass "Swap: ${PCT}%"; }

# Postgres & Redis
PG=$(docker compose exec -T postgres pg_isready -U postgres 2>/dev/null && echo "ok" || echo "fail")
[[ "$PG" == *"ok"* ]] && pass "PostgreSQL" || fail "PostgreSQL"
REDIS=$(docker compose exec -T redis redis-cli ping 2>/dev/null || echo "fail")
[[ "$REDIS" == *"PONG"* ]] && pass "Redis" || fail "Redis"

# SSL cert
if [[ -f /etc/nginx/ssl/cloudflare-origin.pem ]]; then
  EXPIRY=$(openssl x509 -enddate -noout -in /etc/nginx/ssl/cloudflare-origin.pem 2>/dev/null | cut -d= -f2)
  DAYS=$(( ($(date -d "$EXPIRY" +%s 2>/dev/null || echo 0) - $(date +%s)) / 86400 ))
  [[ $DAYS -lt 30 ]] && fail "SSL expires in $DAYS days" || [[ $DAYS -lt 90 ]] && warn "SSL expires in $DAYS days" || pass "SSL valid ($DAYS days)"
fi

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
else
  echo "${#ISSUES[@]} ISSUE(S):"
  printf "  - %s\n" "${ISSUES[@]}"
fi

if [[ "$SEND_WEBHOOK" == "true" && -n "$WEBHOOK_URL" && $EXIT_CODE -ne 0 ]]; then
  curl -sf -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"Sentry alert on $(hostname): $(printf '%s, ' "${ISSUES[@]}")\"}" \
    "$WEBHOOK_URL" > /dev/null 2>&1 || true
fi

exit $EXIT_CODE
