# lets-track-infra

Deployment infrastructure for LetsTrack. Application code lives in the sibling
repos (`lets-track-api`, `lets-track-client`, `lets-track-db`) and is **not**
modified here.

```
lets-track-infra/
├── staging/
│   ├── docker-compose.yml       nginx + client + api-a + api-b + worker
│   │                            + postgres + redis + minio (+ one-shot setup/migrate)
│   ├── nginx/nginx.conf         internal reverse proxy + LB (least_conn) + socket.io sticky
│   ├── host-proxy/              vhost snippets for the SERVER's existing Apache/Nginx
│   ├── migrate/Dockerfile       node-pg-migrate runner (built from lets-track-db)
│   └── .env.staging.example     template — copy to .env.staging on the server
├── prod/README.md               AWS/Terraform placeholder
└── scripts/                     deploy-staging / rollback / backup / restore
```

## Topology (staging)

```
Internet
  │  https://timenova.meissasoft.com
  ▼
[ Server's existing Apache/Nginx :443 ]   ← TLS via certbot (host-managed)
  │  proxy_pass 127.0.0.1:9001   (see host-proxy/*.example)
  ▼
[ our nginx :80 (published on 127.0.0.1:9001) ]
  ├── /socket.io/                     → api_socket   (ip_hash sticky, WS upgrade)
  ├── /api/billing/webhook/stripe     → api_rest     (raw body, no buffering)
  ├── /api/                           → api_rest     (least_conn, 20M uploads)
  └── /                               → client:3000  (Next.js standalone)
          │  api_rest = least_conn { api-a:3000, api-b:3000 }
   api-a   api-b   worker(BullMQ)   postgres   redis   minio   (internal network)
```

- TLS is **not** handled here — the server's existing proxy terminates it.
- Only `127.0.0.1:9001` is published. Postgres/Redis/MinIO stay on the internal
  Docker network (optional host ports are commented in the compose file).

## ⚠️ Prerequisite before first deploy (Step 9)

Running **2 API replicas** requires **`@socket.io/redis-adapter`** in the app.
Without it, `GatewayService.emit()` only reaches clients on the same node, so
cross-node broadcasts drop (~50%). This is a **dev-session change** (wire a
Redis-backed `IoAdapter` using `REDIS_URL`). Infra is already built for it
(sticky `ip_hash` + both replicas). See `SESSION_NOTES.md`.

## Server layout (build on the server, no registry)

Images are built **on the server** from source, so all four repos sit
side-by-side and the compose build contexts resolve:

```
/srv/lets-track/
├── lets-track-api/       (source)
├── lets-track-client/    (source)
├── lets-track-db/        (source)
└── lets-track-infra/
    └── staging/          ← run compose + scripts from here
```

## Deploy runbook

Prereqs: the four repos present under `/srv/lets-track/` and a filled-in
`staging/.env.staging`.

```bash
cd /srv/lets-track/lets-track-infra/staging
chmod +x ../scripts/*.sh                       # once

# First deploy (build + migrate + up), all handled by the script:
../scripts/deploy-staging.sh v0.1.0

# ...or manually:
docker compose --env-file .env.staging build
docker compose --env-file .env.staging up -d postgres redis minio minio-setup
docker compose --env-file .env.staging --profile migrate build migrate
docker compose --env-file .env.staging --profile migrate run --rm migrate
docker compose --env-file .env.staging up -d

# Subsequent rolling deploys (build + health-gated, one replica at a time):
git -C /srv/lets-track/lets-track-api pull    # (+client/db as needed)
../scripts/deploy-staging.sh v0.2.0

# Roll back to the previous tag (no rebuild, reuses the older local image):
../scripts/rollback.sh

# Verify
curl -fsS http://127.0.0.1:9001/api/health
docker compose --env-file .env.staging ps
```

Local image tags produced: `letstrack/api:<tag>`, `letstrack/client:<tag>`,
`letstrack/db-migrate:<tag>`. Old tags are kept locally (only dangling images
are pruned), so rollback has an image to fall back to.

## Backups

`scripts/backup.sh` runs `pg_dump | gzip`, verifies integrity, optionally copies
off-site via `rclone` (`BACKUP_REMOTE` in `.env.staging`), and prunes by
`BACKUP_RETENTION_DAYS`. `scripts/restore.sh` restores into a scratch DB for DR
testing (live DB requires `--force-live`).

## Secrets

`.env`, `.env.staging`, `.env.production` are gitignored — only `*.example`
templates are committed. Never commit real secrets, GHCR PATs, or Stripe keys.
