#!/usr/bin/env bash
# Disaster-recovery RESTORE / restore test — PRODUCTION.
#
#   ./restore-prod.sh <backup.sql.gz>                 # -> scratch DB letstrack_restore_test
#   ./restore-prod.sh <backup.sql.gz> --into mydb     # -> named scratch DB
#   ./restore-prod.sh <backup.sql.gz> --force-live    # -> the LIVE DB (destructive!)
#
# By default it restores into a throwaway database and prints table counts, so
# you can prove a backup is good WITHOUT risking live data. Restoring over the
# live DB requires the explicit --force-live flag.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$SCRIPT_DIR/../prod"
cd "$PROD_DIR"

ENV_FILE=".env.production"
[ -f "$ENV_FILE" ] || { echo "ERROR: $PROD_DIR/$ENV_FILE not found"; exit 1; }
getenv() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

DUMP="${1:-}"
[ -n "$DUMP" ] && [ -f "$DUMP" ] || { echo "Usage: restore-prod.sh <backup.sql.gz> [--into <db> | --force-live]"; exit 1; }
shift

POSTGRES_USER="$(getenv POSTGRES_USER)"
LIVE_DB="$(getenv POSTGRES_DB)"
TARGET_DB="letstrack_restore_test"
FORCE_LIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --into)       TARGET_DB="$2"; shift 2 ;;
    --force-live) FORCE_LIVE=1; TARGET_DB="$LIVE_DB"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

dc() { docker compose --env-file "$ENV_FILE" "$@"; }
psql_c() { dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$@"; }

if [ "$FORCE_LIVE" = "1" ]; then
  echo "!! About to OVERWRITE the LIVE PRODUCTION database '$LIVE_DB'. Ctrl-C within 5s to abort."
  sleep 5
else
  echo "==> Restoring into scratch DB '$TARGET_DB' (live DB '$LIVE_DB' untouched)"
  psql_c -d postgres -c "DROP DATABASE IF EXISTS \"$TARGET_DB\";"
  psql_c -d postgres -c "CREATE DATABASE \"$TARGET_DB\" OWNER \"$POSTGRES_USER\";"
fi

echo "==> Loading dump: $DUMP"
gunzip -c "$DUMP" | dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$TARGET_DB"

echo "==> Table row counts in '$TARGET_DB':"
psql_c -d "$TARGET_DB" -c "
  SELECT relname AS table, n_live_tup AS rows
  FROM pg_stat_user_tables
  ORDER BY n_live_tup DESC
  LIMIT 25;"

if [ "$FORCE_LIVE" != "1" ]; then
  echo
  echo "Restore test OK. Drop the scratch DB when done:"
  echo "  docker compose --env-file $ENV_FILE exec -T postgres psql -U $POSTGRES_USER -d postgres -c 'DROP DATABASE \"$TARGET_DB\";'"
fi
