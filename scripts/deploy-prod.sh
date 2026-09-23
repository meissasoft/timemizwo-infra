#!/usr/bin/env bash
# Rolling, (near) zero-downtime PRODUCTION deploy — BUILDS images on the server.
#
#   ./deploy-prod.sh [IMAGE_TAG] [--no-build]
#
# With a tag arg: records the current tag to .image_tag.prev (for rollback),
# updates IMAGE_TAG in .env.production, then deploys. Without: uses the tag in
# .env.production. --no-build skips building (used by rollback, which re-uses
# the already-built images for the older tag).
#
# Flow: build (unless --no-build) -> backing services -> expand-phase migrations
# (additive) -> replace api-a, wait healthy -> replace api-b, wait healthy ->
# replace worker (drains) -> client, nginx. The second API replica keeps serving
# while the first is swapped.
#
# Requires the source repos beside infra on the server:
#   ~/timenova-track/{lets-track-api,lets-track-client,lets-track-db,lets-track-infra}
# Run from lets-track-infra/prod (scripts cd there automatically).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$SCRIPT_DIR/../prod"
cd "$PROD_DIR"

ENV_FILE=".env.production"
[ -f "$ENV_FILE" ] || { echo "ERROR: $PROD_DIR/$ENV_FILE not found"; exit 1; }

# Serialize deploys: a concurrent trigger or a retry waits here, so two
# `docker compose up` passes never collide with "container name already in
# use". Separate lock file from staging's — the two stacks deploy independently.
exec 9>"${TMPDIR:-/tmp}/letstrack-prod-deploy.lock"
if ! flock -w 900 9; then
  echo "Another prod deploy is in progress (waited 15m) — aborting."
  exit 1
fi

dc() { docker compose --env-file "$ENV_FILE" "$@"; }
getenv() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

TAG=""; BUILD=1
for a in "$@"; do
  case "$a" in
    --no-build) BUILD=0 ;;
    -*) echo "Unknown flag: $a"; exit 1 ;;
    *)  TAG="$a" ;;
  esac
done

if [ -n "$TAG" ]; then
  CUR="$(getenv IMAGE_TAG || true)"
  if [ -n "$CUR" ] && [ "$CUR" != "$TAG" ]; then
    echo "$CUR" > .image_tag.prev
  fi
  if grep -qE '^IMAGE_TAG=' "$ENV_FILE"; then
    sed -i.bak "s|^IMAGE_TAG=.*|IMAGE_TAG=$TAG|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  else
    echo "IMAGE_TAG=$TAG" >> "$ENV_FILE"
  fi
  echo "IMAGE_TAG: ${CUR:-<none>} -> $TAG   (prev saved to .image_tag.prev)"
else
  echo "Using IMAGE_TAG=$(getenv IMAGE_TAG) from $ENV_FILE"
fi

wait_healthy() {
  local svc="$1" timeout="${2:-180}" waited=0 cid status
  cid="$(dc ps -q "$svc")"
  [ -n "$cid" ] || { echo "  ! $svc has no container"; return 1; }
  while :; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
    case "$status" in
      healthy) echo "  ok  $svc healthy"; return 0 ;;
      none)    echo "  ok  $svc up (no healthcheck defined)"; return 0 ;;
    esac
    if [ "$waited" -ge "$timeout" ]; then
      echo "  FAIL $svc not healthy after ${timeout}s (status=$status)"
      dc logs --tail 40 "$svc" || true
      return 1
    fi
    sleep 3; waited=$((waited + 3))
  done
}

roll() {
  local svc="$1"
  echo "==> Rolling $svc"
  dc up -d --no-deps "$svc"
  wait_healthy "$svc"
}

if [ "$BUILD" = "1" ]; then
  echo "==> Building application images (tag $(getenv IMAGE_TAG))"
  dc build api-a client
  dc --profile migrate build migrate
fi

echo "==> Ensuring backing services are up (postgres, redis, minio)"
dc up -d postgres redis minio minio-setup

echo "==> Expand-phase migrations (additive only, safe before code swap)"
dc --profile migrate run --rm migrate

# Replace one API replica at a time so the other keeps serving traffic.
roll api-a
roll api-b

# Worker last. SIGTERM + stop_grace_period(45s) drains in-flight BullMQ jobs.
echo "==> Rolling worker"
dc up -d --no-deps worker

echo "==> Updating client + nginx"
dc up -d --no-deps client
dc up -d --no-deps nginx

echo "==> Pruning dangling images"
docker image prune -f >/dev/null 2>&1 || true

echo
echo "Deploy complete. Current state:"
dc ps
