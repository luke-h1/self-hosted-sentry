#!/usr/bin/env bash
# Health check for Sentry on K3s.
# Usage: ./monitor.sh [--webhook]
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="sentry"
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
HTTP=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 15 http://127.0.0.1/_health/ 2>/dev/null || echo "000")
[[ "$HTTP" == "200" ]] && pass "Sentry (HTTP $HTTP)" || fail "Sentry (HTTP $HTTP)"

# K3s node
NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
[[ "$NODE_STATUS" == "True" ]] && pass "K3s node Ready" || fail "K3s node not Ready ($NODE_STATUS)"

# Pods
NOT_RUNNING=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | grep -cvE "Running|Completed" || echo "0")
TOTAL_PODS=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | wc -l | xargs)
[[ "$NOT_RUNNING" -gt 0 ]] && fail "$NOT_RUNNING of $TOTAL_PODS pods not running" || pass "$TOTAL_PODS pods running"

# CrashLoopBackOff check
CRASH_PODS=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | grep -c "CrashLoopBackOff" || echo "0")
[[ "$CRASH_PODS" -gt 0 ]] && fail "$CRASH_PODS pod(s) in CrashLoopBackOff"

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

# PostgreSQL
PG_POD=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$PG_POD" ]]; then
  PG=$(kubectl -n "$NAMESPACE" exec "$PG_POD" -- pg_isready -U postgres 2>/dev/null && echo "ok" || echo "fail")
  [[ "$PG" == *"ok"* ]] && pass "PostgreSQL" || fail "PostgreSQL"
else
  fail "PostgreSQL pod not found"
fi

# Redis
REDIS_POD=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$REDIS_POD" ]]; then
  REDIS=$(kubectl -n "$NAMESPACE" exec "$REDIS_POD" -- redis-cli ping 2>/dev/null || echo "fail")
  [[ "$REDIS" == *"PONG"* ]] && pass "Redis" || fail "Redis"
else
  fail "Redis pod not found"
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
