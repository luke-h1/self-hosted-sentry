#!/usr/bin/env bash
# Verified PostgreSQL backup with config files and integrity check.
set -euo pipefail

SENTRY_DIR="/opt/sentry/self-hosted"

if [[ -f /etc/sentry/data_dir ]]; then
  SENTRY_DATA_DIR=$(cat /etc/sentry/data_dir)
elif mountpoint -q /mnt/sentry-data 2>/dev/null; then
  SENTRY_DATA_DIR="/mnt/sentry-data"
else
  SENTRY_DATA_DIR="/opt/sentry/data"
fi

BACKUP_DIR="$SENTRY_DATA_DIR/backups"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP"
START_TIME=$(date +%s)

echo "[$(date -Iseconds)] Starting backup..."
mkdir -p "$BACKUP_PATH"

cd "$SENTRY_DIR"
docker compose exec -T postgres pg_isready -U postgres > /dev/null 2>&1 || { echo "ERROR: Postgres not ready"; rm -rf "$BACKUP_PATH"; exit 1; }

echo "  [1/5] PostgreSQL..."
docker compose exec -T postgres pg_dumpall -U postgres | gzip > "$BACKUP_PATH/postgres.sql.gz"
PG_SIZE=$(stat -c %s "$BACKUP_PATH/postgres.sql.gz" 2>/dev/null || stat -f %z "$BACKUP_PATH/postgres.sql.gz")
[[ $PG_SIZE -lt 1000 ]] && echo "ERROR: dump too small (${PG_SIZE}B)" && rm -rf "$BACKUP_PATH" && exit 1

echo "  [2/5] Config files..."
mkdir -p "$BACKUP_PATH/config"
for f in sentry/sentry.conf.py sentry/config.yml .env docker-compose.override.yml; do
  cp "$SENTRY_DIR/$f" "$BACKUP_PATH/config/" 2>/dev/null || true
done
[[ -f /etc/nginx/sites-available/sentry ]] && cp /etc/nginx/sites-available/sentry "$BACKUP_PATH/config/nginx.conf"

echo "  [3/5] ClickHouse metadata..."
docker compose exec -T clickhouse clickhouse-client --query "SHOW DATABASES" > "$BACKUP_PATH/clickhouse-databases.txt" 2>/dev/null || true

echo "  [4/5] Creating archive..."
cd "$BACKUP_DIR"
tar -czf "${TIMESTAMP}.tar.gz" "$TIMESTAMP"
tar -tzf "${TIMESTAMP}.tar.gz" > /dev/null 2>&1 || { echo "ERROR: archive corrupt"; rm -f "${TIMESTAMP}.tar.gz"; rm -rf "$BACKUP_PATH"; exit 1; }
rm -rf "$BACKUP_PATH"

echo "  [5/5] Cleaning up old backups..."
DELETED=0
for old in $(find "$BACKUP_DIR" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" 2>/dev/null); do
  rm -f "$old" "${old%.tar.gz}.meta"
  DELETED=$((DELETED + 1))
done
[[ $DELETED -gt 0 ]] && echo "  removed $DELETED old backup(s)"

DURATION=$(( $(date +%s) - START_TIME ))
echo "[$(date -Iseconds)] Done: ${TIMESTAMP}.tar.gz ($(du -sh "$BACKUP_DIR/${TIMESTAMP}.tar.gz" | cut -f1), ${DURATION}s)"
