#!/usr/bin/env bash
# Invoked over SSH by Bitbucket Cloud Pipelines on merge to main.
# Syncs all four repos to origin/main, then runs the health-gated rolling deploy.
#
#   ci-deploy.sh <image-tag>
#
# Path-independent: it locates the repo base from its OWN location
# (<BASE>/lets-track-infra/scripts/ci-deploy.sh), so it works no matter where the
# repos are cloned (e.g. ~/timenova-track or /srv/lets-track). Runs AS the deploy
# user (must own the repos + be in the docker group + have non-interactive git
# creds for Bitbucket).
set -euo pipefail

TAG="${1:?usage: ci-deploy.sh <image-tag>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"          # parent dir holding all four repos

for r in lets-track-api lets-track-client lets-track-db lets-track-infra; do
  echo "== sync $r =="
  git -C "$BASE/$r" fetch --quiet origin main
  git -C "$BASE/$r" reset --hard origin/main
done

cd "$BASE/lets-track-infra/staging"
exec bash ../scripts/deploy-staging.sh "$TAG"
