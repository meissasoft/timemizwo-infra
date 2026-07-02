# LetsTrack — Infra / Staging Deployment Notes

Deployment-only work. App code (api/client/db repos) is **not** modified here;
any bug found is flagged, not fixed.

## Target
- Server: `timenova.meissasoft.com` (221.120.236.55, office LAN, Karachi).
  Ubuntu, Docker + Compose v2 already installed.
- Fronted by the server's **existing Apache/Nginx** (many apps already hosted).
  It terminates TLS and forwards the domain to our stack on `127.0.0.1:9001`.
- Public HTTPS: **certbot on the host proxy** (not in our compose).

## Port map (host-published)
| Service       | Host                         | Container |
|---------------|------------------------------|-----------|
| our nginx     | 127.0.0.1:9001               | 80        |
| postgres      | internal (opt 127.0.0.1:9004)| 5432      |
| minio console | internal (opt 127.0.0.1:9003)| 9001      |

Local dev ports left untouched (client 3173, etc.).

## Verified facts from source (not assumed)
- **Health:** `GET /api/health` (Dockerfile HEALTHCHECK). `API_PREFIX=api`, `PORT=3000`.
- **Env var names:** confirmed against `lets-track-api/src/config/validation.schema.ts`
  and `.env.example`. `DATABASE_URL` / `REDIS_URL` are built by compose from
  parts (env_file can't expand nested `${VARS}`). `APP_URL` is used in email links.
- **ORM/migrations:** Drizzle for queries; migrations are **node-pg-migrate**
  (plain SQL) in `lets-track-db/migrations`, run via `tsx scripts/migrate-up.ts`.
  Not in the API image → separate `lets-track-db-migrate` image built from the db
  repo via `staging/migrate/Dockerfile` (db repo stays unmodified).
- **Worker:** no worker-only mode — BullMQ processors are Nest providers in the
  main app. The `worker` container is just another `node dist/main.js`. Safe
  because cron scheduling uses BullMQ `upsertJobScheduler` (idempotent across
  instances) — no duplicate cron fires. `enableShutdownHooks()` + `stop_grace_period`
  gives graceful drain.
- **Socket.IO:** gateway is `namespace: '/ws'` on the **default path** →
  realtime traffic is on `/socket.io/` (NOT `/api/agent-sync/` as first planned).
  nginx routes `/socket.io/` with `ip_hash` stickiness.

## ⚠️ BLOCKER for the CLIENT build (Step 4/9)
`lets-track-client/next.config.ts` needs **`output: 'standalone'`** (one line)
for the standalone Dockerfile to work — it produces `.next/standalone/server.js`.
This is a dev-session source change (I don't edit client source). Without it the
client image build fails at the `COPY .next/standalone` step. `NEXT_PUBLIC_*`
are baked at build time and are passed as compose build args from `.env.staging`.

## ⚠️ BLOCKER for Step 9 (first deploy)
Multi-replica realtime needs **`@socket.io/redis-adapter`**. It is not in the app
yet. `GatewayService.emit` uses `server.to(room).emit` on the local node only;
with 2 replicas, cross-node broadcasts drop. **Dev session must add the Redis
adapter** (Redis-backed `IoAdapter` using `REDIS_URL`) before we run 2 replicas.
Infra is already built for it.

## Decisions
- HTTPS: certbot on the host proxy (existing Apache/Nginx).
- Realtime: 2 replicas + Redis adapter (pending dev change).
- Ports: server uses the 900x range; only `127.0.0.1:9001` published.
- **Build location: ON THE SERVER** (no registry/GHCR). Compose has `build:`
  contexts + local image tags (`letstrack/api|client|db-migrate:<tag>`). All 4
  repos must sit under `/srv/lets-track/` side-by-side. Step 4 (GHCR push) is
  dropped; deploy-staging.sh builds. rollback.sh reuses the old local image
  (`--no-build`).

## Progress
- [x] Step 1 — infra scaffold created (compose, nginx, host-proxy snippets,
      migrate Dockerfile, .env template, scripts, README).
- [x] Step 2 — `lets-track-client/Dockerfile` + `.dockerignore` (Next.js
      standalone); compose client `build.args` for NEXT_PUBLIC_*; env template
      updated. Needs dev to add `output: 'standalone'` to next.config.ts.
- [ ] Step 3 — verify `lets-track-api/Dockerfile` builds locally.
- [ ] Step 4 — (dropped: no GHCR; images build on server via deploy-staging.sh).
- [ ] Step 5 — verify Docker/Compose on server.
- [ ] Step 6 — get all 4 repos onto server under `/srv/lets-track/`.
- [ ] Step 7 — create `.env.staging` on server (real secrets).
- [ ] Step 8 — wire host proxy vhost + certbot.
- [ ] Step 9 — first deploy (needs Redis adapter merged).
- [ ] Step 10 — run migrations.
- [ ] Step 11 — smoke test via public URL.
- [ ] Step 12 — nightly backup cron.
