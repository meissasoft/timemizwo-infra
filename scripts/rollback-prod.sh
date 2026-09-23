#!/usr/bin/env bash
# Roll back PRODUCTION to the previously deployed image tag.
#
#   ./rollback-prod.sh            # uses .image_tag.prev (written by deploy-prod.sh)
#   ./rollback-prod.sh v1.0.0     # roll back to a specific tag
#
# Re-runs deploy-prod.sh with the target tag and --no-build, re-using the
# already-built local image for that tag (no rebuild — source may have moved on).
# Expand-phase migrations are additive and backward-compatible, so the older code
# runs fine against the newer schema; the migrate step is a no-op (already
# applied). This script does NOT down-migrate — schema contraction is a
# deliberate, separate step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$SCRIPT_DIR/../prod"

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  PREV_FILE="$PROD_DIR/.image_tag.prev"
  [ -f "$PREV_FILE" ] || { echo "ERROR: no .image_tag.prev and no tag given"; exit 1; }
  TARGET="$(cat "$PREV_FILE")"
fi

echo "Rolling PRODUCTION back to IMAGE_TAG=$TARGET"
exec "$SCRIPT_DIR/deploy-prod.sh" "$TARGET" --no-build
