# One-shot migration runner for node-pg-migrate (plain-SQL migrations).
#
# The BUILD CONTEXT is the lets-track-db repo — this Dockerfile lives in infra
# so the db repo stays unmodified. Build it (from d:\LetsTrackApp) with:
#
#   docker build -f lets-track-infra/prod/migrate/Dockerfile \
#     -t ghcr.io/meissasoft/lets-track-db-migrate:v0.1.0 lets-track-db
#
# Runtime: applies every pending migration in /db/migrations against
# $DATABASE_URL, then exits. Compose runs it as the `migrate` profile service.
FROM node:20-slim

WORKDIR /db

# Exact runtime deps the db repo's migrate-up.ts needs. Pinned to the repo's
# package.json ranges. --no-save keeps the layer deterministic and lean.
RUN npm install --no-save --no-audit --no-fund --loglevel=error \
      node-pg-migrate@7 pg@8 dotenv@16 tsx@4

# Only the pieces migration needs — not the whole repo.
COPY migrations ./migrations
COPY scripts/migrate-up.ts scripts/migrate-down.ts ./scripts/

ENV NODE_ENV=production

# migrate-up.ts reads DATABASE_URL from the environment (dotenv/config is a
# no-op when no .env file is present).
ENTRYPOINT ["npx", "tsx", "scripts/migrate-up.ts"]
