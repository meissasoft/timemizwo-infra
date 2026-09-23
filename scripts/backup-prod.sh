#!/usr/bin/env bash
# Nightly Postgres backup -> gzip -> off-site (rclone remote) — PRODUCTION.
#
# Cron (2:00am daily — offset 30min from staging's backup.sh to avoid both
# pg_dump-ing at once):
#   0 2 * * * /home/meissasoft/timenova-track-prod/lets-track-infra/scripts/backup-prod.sh >> /var/log/letstrack-prod-backup.log 2>&1
#
# Config comes from .env.production: POSTGRES_USER, POSTGRES_DB, BACKUP_DIR,
# BACKUP_RETENTION_DAYS, BACKUP_REMOTE. Unlike staging, BACKUP_REMOTE should
# always be set for prod (off-site DB backup is not optional here).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$SCRIPT_DIR/../prod"
cd "$PROD_DIR"

ENV_FILE=".env.production"
[ -f "$ENV_FILE" ] || { echo "ERROR: $PROD_DIR/$ENV_FILE not found"; exit 1; }

# Read only the specific keys we need (sourcing the file is unsafe — values like
# EMAIL_FROM contain spaces and < > which the shell would try to interpret).
getenv() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

POSTGRES_USER="$(getenv POSTGRES_USER)"
POSTGRES_DB="$(getenv POSTGRES_DB)"
BACKUP_DIR="$(getenv BACKUP_DIR)"; BACKUP_DIR="${BACKUP_DIR:-/home/meissasoft/timenova-track-prod/backups}"
RETENTION_DAYS="$(getenv BACKUP_RETENTION_DAYS)"; RETENTION_DAYS="${RETENTION_DAYS:-30}"
BACKUP_REMOTE="$(getenv BACKUP_REMOTE)"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/letstrack-prod-$STAMP.sql.gz"
mkdir -p "$BACKUP_DIR"

echo "[$(date -Is)] pg_dump $POSTGRES_DB -> $OUT"
docker compose --env-file "$ENV_FILE" exec -T postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --clean --if-exists \
  | gzip -9 > "$OUT"

# Integrity check — fail loudly if the gzip is truncated.
gzip -t "$OUT"
echo "[$(date -Is)] local backup ok ($(du -h "$OUT" | cut -f1))"

# Off-site copy.
if [ -n "${BACKUP_REMOTE:-}" ]; then
  echo "[$(date -Is)] uploading to $BACKUP_REMOTE"
  rclone copy "$OUT" "$BACKUP_REMOTE" --log-level INFO
  echo "[$(date -Is)] off-site upload ok"
else
  echo "[$(date -Is)] WARNING: BACKUP_REMOTE not set — prod DB has NO off-site backup"
fi

# Local retention.
find "$BACKUP_DIR" -name 'letstrack-prod-*.sql.gz' -mtime +"$RETENTION_DAYS" -delete
echo "[$(date -Is)] done (retention: ${RETENTION_DAYS}d)"
