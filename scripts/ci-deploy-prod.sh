#!/usr/bin/env bash
# Syncs all four repos to origin/main, then runs the health-gated PRODUCTION
# rolling deploy. Unlike ci-deploy.sh (staging, triggered automatically by
# Bitbucket Pipelines on every merge to main), this is meant to be triggered
# ONLY by hand via manual-deploy-prod.sh — production does not auto-deploy on
# push. Promote to prod deliberately, once staging looks good.
#
#   ci-deploy-prod.sh <image-tag>
#
# Path-independent: it locates the repo base from its OWN location
# (<BASE>/lets-track-infra/scripts/ci-deploy-prod.sh), so it works no matter
# where the repos are cloned. Runs AS the deploy user (must own the repos + be
# in the docker group + have non-interactive git creds for Bitbucket).
set -euo pipefail

TAG="${1:?usage: ci-deploy-prod.sh <image-tag>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"          # parent dir holding all four repos

for r in lets-track-api lets-track-client lets-track-db lets-track-infra; do
  echo "== sync $r =="
  git -C "$BASE/$r" fetch --quiet origin main
  git -C "$BASE/$r" reset --hard origin/main
done

cd "$BASE/lets-track-infra/prod"
exec bash ../scripts/deploy-prod.sh "$TAG"
