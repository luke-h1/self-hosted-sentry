#!/usr/bin/env bash
# Verified PostgreSQL backup with Helm values and integrity check.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="sentry"
BACKUP_DIR="/opt/sentry/backups"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP"
START_TIME=$(date +%s)

echo "[$(date -Iseconds)] Starting backup..."
mkdir -p "$BACKUP_PATH"

# Check Postgres is ready
PG_POD=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$PG_POD" ]] && echo "ERROR: PostgreSQL pod not found" && rm -rf "$BACKUP_PATH" && exit 1
kubectl -n "$NAMESPACE" exec "$PG_POD" -- pg_isready -U postgres > /dev/null 2>&1 || { echo "ERROR: Postgres not ready"; rm -rf "$BACKUP_PATH"; exit 1; }

echo "  [1/5] PostgreSQL..."
kubectl -n "$NAMESPACE" exec "$PG_POD" -- pg_dumpall -U postgres | gzip > "$BACKUP_PATH/postgres.sql.gz"
PG_SIZE=$(stat -c %s "$BACKUP_PATH/postgres.sql.gz" 2>/dev/null || stat -f %z "$BACKUP_PATH/postgres.sql.gz")
[[ $PG_SIZE -lt 1000 ]] && echo "ERROR: dump too small (${PG_SIZE}B)" && rm -rf "$BACKUP_PATH" && exit 1

echo "  [2/5] Helm values..."
mkdir -p "$BACKUP_PATH/config"
helm -n "$NAMESPACE" get values sentry -o yaml > "$BACKUP_PATH/config/helm-values.yaml" 2>/dev/null || true

echo "  [3/5] ClickHouse metadata..."
CH_POD=$(kubectl -n "$NAMESPACE" get pods -l app=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$CH_POD" ]]; then
  kubectl -n "$NAMESPACE" exec "$CH_POD" -- clickhouse-client --query "SHOW DATABASES" > "$BACKUP_PATH/clickhouse-databases.txt" 2>/dev/null || true
fi

echo "  [4/5] Creating archive..."
cd "$BACKUP_DIR"
tar -czf "${TIMESTAMP}.tar.gz" "$TIMESTAMP"
tar -tzf "${TIMESTAMP}.tar.gz" > /dev/null 2>&1 || { echo "ERROR: archive corrupt"; rm -f "${TIMESTAMP}.tar.gz"; rm -rf "$BACKUP_PATH"; exit 1; }
rm -rf "$BACKUP_PATH"

echo "  [5/5] Cleaning up old backups..."
DELETED=0
for old in $(find "$BACKUP_DIR" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" 2>/dev/null); do
  rm -f "$old"
  DELETED=$((DELETED + 1))
done
[[ $DELETED -gt 0 ]] && echo "  removed $DELETED old backup(s)"

DURATION=$(( $(date +%s) - START_TIME ))
echo "[$(date -Iseconds)] Done: ${TIMESTAMP}.tar.gz ($(du -sh "$BACKUP_DIR/${TIMESTAMP}.tar.gz" | cut -f1), ${DURATION}s)"
