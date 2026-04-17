#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="sentry"
BACKUP_DIR="/opt/sentry/backups"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backup.tar.gz>"
  echo ""
  ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "No backups found."
  exit 1
fi

ARCHIVE="$1"
[[ ! -f "$ARCHIVE" ]] && echo "ERROR: not found: $ARCHIVE" && exit 1

echo "Restoring from: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))"
read -rp "This will OVERWRITE the current database. Continue? [y/N] " confirm
[[ "${confirm,,}" != "y" ]] && echo "Aborted." && exit 0

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[1/4] Extracting..."
cd "$TEMP_DIR" && tar -xzf "$ARCHIVE"
EXTRACTED=$(find "$TEMP_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
[[ -z "$EXTRACTED" ]] && echo "ERROR: no directory in archive" && exit 1
[[ ! -f "$EXTRACTED/postgres.sql.gz" ]] && echo "ERROR: postgres.sql.gz missing" && exit 1

echo "[2/4] Scaling down Sentry workers..."
kubectl -n "$NAMESPACE" scale deployment --all --replicas=0 2>/dev/null || true
echo "  Waiting for pods to terminate..."
sleep 10

echo "[3/4] Restoring database..."
PG_POD=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
[[ -z "$PG_POD" ]] && echo "ERROR: PostgreSQL pod not found" && exit 1

for i in {1..30}; do
  kubectl -n "$NAMESPACE" exec "$PG_POD" -- pg_isready -U postgres > /dev/null 2>&1 && break
  sleep 2
done

kubectl -n "$NAMESPACE" exec "$PG_POD" -- psql -U postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='sentry' AND pid<>pg_backend_pid();" 2>/dev/null || true
kubectl -n "$NAMESPACE" exec "$PG_POD" -- psql -U postgres -c "DROP DATABASE IF EXISTS sentry;" 2>/dev/null || true
kubectl -n "$NAMESPACE" exec "$PG_POD" -- psql -U postgres -c "CREATE DATABASE sentry;" 2>/dev/null || true
gunzip -c "$EXTRACTED/postgres.sql.gz" | kubectl -n "$NAMESPACE" exec -i "$PG_POD" -- psql -U postgres --quiet

echo "[4/4] Scaling back up..."
if [[ -f "$EXTRACTED/config/helm-values.yaml" ]]; then
  echo "  Restoring Helm values and upgrading..."
  helm upgrade sentry sentry/sentry -n "$NAMESPACE" -f "$EXTRACTED/config/helm-values.yaml" --timeout 15m --wait || true
else
  kubectl -n "$NAMESPACE" scale deployment --all --replicas=1 2>/dev/null || true
fi

echo "Done. Run 'make status' to verify."
