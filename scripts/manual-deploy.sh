#!/usr/bin/env bash
# One-shot MANUAL deploy — run from YOUR machine (git-bash) to deploy the current
# `main` of all four repos to staging, WITHOUT using Bitbucket pipeline minutes.
#
# It just SSHes into the server and runs ci-deploy.sh (sync all repos → build →
# migrate → health-gated rolling deploy). Same result as the CI pipeline, but
# triggered by hand.
#
# Prereq:
#   - Your changes are pushed to Bitbucket `main` (the server pulls origin/main).
#   - You can SSH to the server (the normal access you already use).
#
# Usage (from the lets-track-infra folder):
#   bash scripts/manual-deploy.sh            # auto timestamp tag
#   bash scripts/manual-deploy.sh v0.2.0     # explicit tag (nice for rollbacks)
#
# Override connection details via env vars if they ever change:
#   DEPLOY_HOST / DEPLOY_PORT / DEPLOY_USER / DEPLOY_PATH
set -euo pipefail

DEPLOY_HOST="${DEPLOY_HOST:-221.120.236.55}"
DEPLOY_PORT="${DEPLOY_PORT:-8822}"
DEPLOY_USER="${DEPLOY_USER:-meissasoft}"
DEPLOY_PATH="${DEPLOY_PATH:-/home/meissasoft/timenova-track}"
TAG="${1:-manual-$(date +%Y%m%d-%H%M%S)}"

echo "==> Deploying tag '$TAG' to $DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PORT"
echo "    (make sure your changes are pushed to Bitbucket main first)"
ssh -p "$DEPLOY_PORT" "$DEPLOY_USER@$DEPLOY_HOST" \
  "bash '$DEPLOY_PATH/lets-track-infra/scripts/ci-deploy.sh' '$TAG'"
echo "==> Done."
