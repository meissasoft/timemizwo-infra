#!/usr/bin/env bash
# One-shot MANUAL deploy — run from YOUR machine (git-bash) to deploy the
# current `main` of all four repos to PRODUCTION.
#
# It SSHes into the server and runs ci-deploy-prod.sh (sync all repos ->
# build -> migrate -> health-gated rolling deploy).
#
# IMPORTANT: production uses its OWN checkout of the four repos, separate from
# staging's (~/timenova-track). This is deliberate — staging auto-deploys on
# every merge to main (Bitbucket Pipelines); if prod shared that checkout, a
# staging deploy could `git reset --hard` the very tree a concurrent prod
# build is reading from. Keeping the checkouts apart makes the two stacks
# fully independent, at the cost of one extra clone of each repo on the box.
#
# One-time server setup (run once, before the first prod deploy):
#   mkdir -p ~/timenova-track-prod && cd ~/timenova-track-prod
#   git clone <bitbucket-url>/lets-track-api.git
#   git clone <bitbucket-url>/lets-track-client.git
#   git clone <bitbucket-url>/lets-track-db.git
#   git clone <bitbucket-url>/lets-track-infra.git
#   cp lets-track-infra/prod/.env.production.example lets-track-infra/prod/.env.production
#   nano lets-track-infra/prod/.env.production   # fill every REQUIRED value
#
# Prereq for every deploy after that:
#   - Your changes are pushed to Bitbucket `main` (the server pulls origin/main).
#   - You can SSH to the server (the normal access you already use).
#
# Usage (from the lets-track-infra folder, on your machine):
#   bash scripts/manual-deploy-prod.sh            # auto timestamp tag
#   bash scripts/manual-deploy-prod.sh v1.0.0     # explicit tag (nice for rollbacks)
#
# Override connection details via env vars if they ever change:
#   DEPLOY_HOST / DEPLOY_PORT / DEPLOY_USER / DEPLOY_PATH
set -euo pipefail

DEPLOY_HOST="${DEPLOY_HOST:-221.120.236.55}"
DEPLOY_PORT="${DEPLOY_PORT:-8822}"
DEPLOY_USER="${DEPLOY_USER:-meissasoft}"
DEPLOY_PATH="${DEPLOY_PATH:-/home/meissasoft/timenova-track-prod}"
TAG="${1:-manual-$(date +%Y%m%d-%H%M%S)}"

echo "==> Deploying tag '$TAG' to PRODUCTION ($DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PORT)"
echo "    (make sure your changes are pushed to Bitbucket main first)"
ssh -p "$DEPLOY_PORT" "$DEPLOY_USER@$DEPLOY_HOST" \
  "bash '$DEPLOY_PATH/lets-track-infra/scripts/ci-deploy-prod.sh' '$TAG'"
echo "==> Done."
