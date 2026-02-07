#!/usr/bin/env bash
# Restore Sentry from a backup archive.
set -euo pipefail

SENTRY_DIR="/opt/sentry/self-hosted"

if [[ -f /etc/sentry/data_dir ]]; then
  SENTRY_DATA_DIR=$(cat /etc/sentry/data_dir)
elif mountpoint -q /mnt/sentry-data 2>/dev/null; then
  SENTRY_DATA_DIR="/mnt/sentry-data"
else
  SENTRY_DATA_DIR="/opt/sentry/data"
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backup.tar.gz>"
  echo ""
  ls -lh "$SENTRY_DATA_DIR/backups"/*.tar.gz 2>/dev/null || echo "No backups found."
  exit 1
fi

ARCHIVE="$1"
[[ ! -f "$ARCHIVE" ]] && echo "ERROR: not found: $ARCHIVE" && exit 1

echo "Restoring from: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))"
read -rp "This will OVERWRITE the current database. Continue? [y/N] " confirm
[[ "${confirm,,}" != "y" ]] && echo "Aborted." && exit 0

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[1/5] Extracting..."
cd "$TEMP_DIR" && tar -xzf "$ARCHIVE"
EXTRACTED=$(find "$TEMP_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
[[ -z "$EXTRACTED" ]] && echo "ERROR: no directory in archive" && exit 1
[[ ! -f "$EXTRACTED/postgres.sql.gz" ]] && echo "ERROR: postgres.sql.gz missing" && exit 1

echo "[2/5] Stopping Sentry..."
cd "$SENTRY_DIR" && docker compose down || true

echo "[3/5] Starting Postgres..."
docker compose up -d postgres
for i in {1..30}; do
  docker compose exec -T postgres pg_isready -U postgres > /dev/null 2>&1 && break
  sleep 2
done

echo "[4/5] Restoring database..."
docker compose exec -T postgres psql -U postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='sentry' AND pid<>pg_backend_pid();" 2>/dev/null || true
docker compose exec -T postgres psql -U postgres -c "DROP DATABASE IF EXISTS sentry;" 2>/dev/null || true
docker compose exec -T postgres psql -U postgres -c "CREATE DATABASE sentry;" 2>/dev/null || true
gunzip -c "$EXTRACTED/postgres.sql.gz" | docker compose exec -T postgres psql -U postgres --quiet

echo "[5/5] Restoring config..."
if [[ -d "$EXTRACTED/config" ]]; then
  for f in sentry.conf.py config.yml; do
    [[ -f "$EXTRACTED/config/$f" ]] && cp "$EXTRACTED/config/$f" "$SENTRY_DIR/sentry/$f" && echo "  restored $f"
  done
fi

echo "Starting Sentry..."
docker compose up -d
echo "Done. Run 'make status' to verify."
