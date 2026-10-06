#!/usr/bin/env bash
# Invoked over SSH by Bitbucket Cloud Pipelines on merge to `production`.
# Thin wrapper — deploy-prod.sh --sync does the git sync (to origin/production,
# NOT origin/main) AND the build/migrate/roll, all inside ONE flock, so a
# concurrent trigger (e.g. two repos' pipelines firing near-simultaneously)
# can never git-reset a checkout that another run's build is mid-read of.
#
#   ci-deploy-prod.sh <image-tag>
#
# Path-independent: it locates deploy-prod.sh from its OWN location
# (<BASE>/lets-track-infra/scripts/ci-deploy-prod.sh). Runs AS the deploy user
# (must own the repos + be in the docker group + have non-interactive git
# creds for Bitbucket).
set -euo pipefail

TAG="${1:?usage: ci-deploy-prod.sh <image-tag>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec bash "$SCRIPT_DIR/deploy-prod.sh" --sync "$TAG"
