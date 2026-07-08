# LetsTrack — Deployment Handoff (staging)

> **Read this first.** This is the single source of truth for **deploying** LetsTrack to
> the office/staging server. It is a *deployment* handoff — the application code lives in
> sibling repos and must **not** be modified here (flag bugs, don't fix them unless the
> user explicitly asks). No secrets are stored in this file — only variable **names**.

_Last updated: 2026-07-08._

---

## 1. What this is

LetsTrack is a Hubstaff-style SaaS time-tracker (web app + desktop agent). This document
covers the **staging deployment** on the office server for internal testing.

**Public URL:** https://timenova.meissasoft.com
**S3/downloads:** https://s3.timenova.meissasoft.com

---

## 2. Server

| | |
|---|---|
| Host | `timenova.meissasoft.com` / `221.120.236.55` (Ubuntu, Karachi TZ) |
| SSH | `ssh -p 8822 meissasoft@221.120.236.55` (normal user access) |
| Deploy path | `~/timenova-track/` — holds all 4 repos side by side |
| Docker | 27.x, Compose v2.x, 31Gi RAM |
| Host web layer | **Apache + certbot** (NOT in compose). Terminates TLS, reverse-proxies to the stack. |

**Host Apache vhosts (already configured, Let's Encrypt):**
- `timenova.meissasoft.com` → `127.0.0.1:9001` (nginx in compose → client + api)
- `s3.timenova.meissasoft.com` → `127.0.0.1:9002` (MinIO S3 API). **`ProxyPreserveHost On`** is
  mandatory here — MinIO SigV4 signs the Host header, presigned URLs break without it.

> The server hosts **other apps too** — never assume it's ours-only. Check before touching
> host Apache, ports, or certbot. Our published ports are locked to **9001–9004**.

---

## 3. The four repos (all deploy from `main`)

| Repo | Role | Notes |
|---|---|---|
| `lets-track-api` | NestJS 10 API + BullMQ worker | Node 20, pnpm 9, Drizzle ORM. **Do not** recreate its Dockerfile. |
| `lets-track-client` | Next.js 15 web app | `output: 'standalone'`. |
| `lets-track-db` | node-pg-migrate SQL migrations | Plain SQL in `migrations/`. Dev compose here is **dev-only, don't touch**. |
| `lets-track-infra` | **THIS repo** — compose, nginx, deploy scripts | All orchestration lives here. |

The server pulls each repo to `origin/main` on every deploy (`git fetch` + `reset --hard`).

---

## 4. How deployment works

Everything is **build-on-server** (no image registry). Layout on server:
`~/timenova-track/{lets-track-api,lets-track-client,lets-track-db,lets-track-infra}`

### Compose
`staging/docker-compose.yml` (project name `letstrack-staging`, network `letstrack-staging_letstrack`):
- `nginx` (`127.0.0.1:9001:80`) — internal LB/reverse proxy (upstreams: api rest least_conn, api socket ip_hash sticky, client)
- `api-a`, `api-b` — 2 API replicas (rolling, `stop_grace 30s`)
- `worker` — BullMQ processors (`stop_grace 45s`, drains jobs)
- `client` — Next.js standalone
- `postgres`, `redis`, `minio`, `minio-setup` (one-shot: buckets + policies)
- `migrate` — profile-gated one-shot (node-pg-migrate)

**Env injection:** the `x-api` anchor uses **`env_file: .env.staging`**, so *every* var in
`.env.staging` is injected into api-a/api-b/worker automatically. Composite values
(`DATABASE_URL`, `REDIS_URL`, `S3_ENDPOINT`) are built in `environment:` so `${...}` expands.
→ **Adding a new backend env var = just add it to `.env.staging`; no compose change needed.**

### Deploy scripts (`scripts/`)
- **`deploy-staging.sh`** — the actual rolling deploy, run **on the server**. Flow:
  build → backing services up → expand-phase migrations → roll api-a (wait healthy) →
  roll api-b → roll worker → client → nginx → prune. Has a **`flock`** so concurrent/retried
  deploys serialize (no "container name already in use"). `--no-build` skips build (rollback).
  Records previous tag to `.image_tag.prev`.
- **`ci-deploy.sh`** — syncs all 4 repos to `origin/main`, then calls `deploy-staging.sh`.
  Self-locating via `$SCRIPT_DIR/../..`. This is what runs on the server per deploy.
- **`manual-deploy.sh`** — run from **your machine** (git-bash). SSHes to server and runs
  `ci-deploy.sh`. **This is the primary deploy path right now** (pipelines paused).

### CI/CD (currently PAUSED)
Bitbucket **Cloud** pipelines exist in all 4 repos (`bitbucket-pipelines.yml`) — cloud runner
SSHes into the server and runs `ci-deploy.sh`. **They are paused** (were burning the 50 free
min/mo; 4 repos deploying the same thing 4×). Re-enable per repo: Repo → Settings → Pipelines →
Settings → toggle ON. There is **no self-hosted Bitbucket runner** on the server (deliberate).

---

## 5. Deploy — the commands you'll actually run

**On merge to `main`, to deploy:**
```bash
# From your machine, in lets-track-infra:
git push                              # push your infra changes first
bash scripts/manual-deploy.sh         # → SSH → sync all repos to main → build → migrate → roll
bash scripts/manual-deploy.sh v0.3.0  # explicit tag (nice for rollbacks)
```
> The server syncs to **Bitbucket `main`**, so push your app changes to `main` FIRST.

**Env-only or on-server tweaks:**
```bash
ssh -p 8822 meissasoft@221.120.236.55
cd ~/timenova-track/lets-track-infra/staging
nano .env.staging                     # edit secrets (gitignored, server-only)
bash ../scripts/deploy-staging.sh     # rebuild + roll
```

**Verify:**
```bash
curl -I https://timenova.meissasoft.com/api/health
docker compose --env-file .env.staging ps
docker compose --env-file .env.staging logs api-a --tail 40 | grep -iE 'error|successfully started'
```

---

## 6. Environment file

- **`staging/.env.staging`** — real secrets, **gitignored, lives only on the server.**
- **`staging/.env.staging.example`** — committed template. Documents every var; real
  redirect URIs pre-filled, secrets blank. **Keep this in sync when adding vars.**

Validation: `lets-track-api/src/config/validation.schema.ts` uses Joi with **`allowUnknown: true`**,
so unknown vars won't crash boot. Most vars are `optional`/`allow('')`. **Known required-when traps:**
- `EMAIL_SMTP_HOST` must be **non-empty** even for `EMAIL_PROVIDER=mock` (Joi default only applies
  when *undefined*, not empty). Set to `localhost` for mock.
- `ANTHROPIC_API_KEY` is **required** only when `AI_PROVIDER=anthropic` or `AI_DEFAULT_PROVIDER=anthropic`.

---

## 7. Status — what's DONE ✅

- Full infra scaffold, build-on-server, HTTPS live (host Apache + certbot).
- All images build (api/client/migrate). `pnpm --ignore-workspace run build` needed (workspace
  manifest has no `packages` field → "packages field missing or empty" otherwise).
- Migrations run (incl. `030_billing_final.sql` and the integrations migration).
- **Signup / auth** working.
- **Email** — SMTP configured (Brevo), working.
- **Screenshots** — agent PUTs to presigned URLs at `s3.timenova.meissasoft.com` (MinIO exposed
  on 9002, Apache proxy `ProxyPreserveHost On`, `S3_ENDPOINT=https://s3.timenova.meissasoft.com`). Working.
- **Agent downloads bucket** — `letstrack-downloads`, `agent/` prefix anonymous public-read
  (`mc anonymous set download`). URL: `https://s3.timenova.meissasoft.com/letstrack-downloads/agent/<path>`.
  Verified `200 OK`. `minio-setup` service creates it on deploy.
- **Integrations module env** (ClickUp/Trello/Jira/Linear) — documented in `.env.staging.example`,
  redirect URIs mapped to staging domain. See §9.
- **AI chatbot 2-model routing env** — documented. See §9.
- **`manual-deploy.sh`** on-demand deploy path (pipelines paused).

---

## 8. Status — PENDING / deferred ⏳

Priority order:
1. **Stripe products setup** — paid checkout returns `BILLING_NOT_READY` because `plans.stripe_price_id_*`
   are NULL. Run `lets-track-api/scripts/setup-stripe-products.mjs` (needs a **`sk_test_`** key +
   `DATABASE_URL`). `dotenv` is a **dev** dep so it's absent from the pruned prod image — run in a
   plain `node:20-alpine` container joined to the letstrack network, `npm i --no-save stripe pg dotenv`.
   Command scaffold is in the chat history / see §10.
2. **Nightly DB backup cron → off-site** — `scripts/backup.sh` exists; no cron wired yet.
3. **`@socket.io/redis-adapter`** — needed for realtime/WS across the 2 API replicas
   (dev-session change in api repo, not yet done). Until then WS uses ip_hash sticky in nginx.
4. Optional: `STRIPE_WEBHOOK_SECRET` for full billing webhook flow; branch protection (user-managed).

---

## 9. New env added recently (fill on server, then deploy)

All optional for boot. Append to `~/timenova-track/lets-track-infra/staging/.env.staging`, fill
keys via `nano` (never paste secrets in chat), then `bash ../scripts/deploy-staging.sh`.

**Integrations** (redirect URI = FRONTEND `APP_URL`; webhook = API `APP_URL/api`). **Register the
same redirect URI in each provider's OAuth console** or callbacks 400:
```
INTEGRATION_ENCRYPTION_KEY=        # 32 bytes: `openssl rand -base64 32`. Changing it orphans stored tokens.
CLICKUP_CLIENT_ID= / CLICKUP_CLIENT_SECRET=
CLICKUP_REDIRECT_URI=https://timenova.meissasoft.com/integrations/clickup/callback
CLICKUP_WEBHOOK_CALLBACK_URL=https://timenova.meissasoft.com/api/integrations/webhooks/clickup
TRELLO_API_KEY= / TRELLO_API_SECRET=
TRELLO_REDIRECT_URI=https://timenova.meissasoft.com/integrations/trello/callback
JIRA_CLIENT_ID= / JIRA_CLIENT_SECRET=
JIRA_REDIRECT_URI=https://timenova.meissasoft.com/integrations/jira/callback
LINEAR_CLIENT_ID= / LINEAR_CLIENT_SECRET=
LINEAR_REDIRECT_URI=https://timenova.meissasoft.com/integrations/linear/callback
```

**AI chatbot (2-model routing, default ON)** — fill the two keys for a working bot; blank + `AI_PROVIDER=mock`
= canned replies:
```
AI_ROUTER_PROVIDER=openai-compatible          # cheap classifier
AI_ROUTER_MODEL=gemini-2.5-flash-lite
AI_ROUTER_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
AI_ROUTER_API_KEY=                            # Google AI Studio (Gemini)
AI_COMPLEX_PROVIDER=openai-compatible         # tool-capable
AI_COMPLEX_MODEL=openai/gpt-4o-mini
AI_COMPLEX_BASE_URL=https://openrouter.ai/api/v1
AI_COMPLEX_API_KEY=                           # OpenRouter
AI_PROVIDER=mock                              # fallback only; anthropic ⇒ ANTHROPIC_API_KEY required
```
Config source of truth: `lets-track-api/src/config/{ai,integrations}.config.ts`.

---

## 10. Gotchas / fixes already applied (don't re-hit these)

- **`pnpm build` fails "packages field missing"** → use `pnpm --ignore-workspace run build`
  (Dockerfiles already patched).
- **`minio/mc` image entrypoint is `mc`** → for shell use `docker run --entrypoint sh minio/mc:latest -c '...'`.
  Don't `apt install mc` on the host — that's Midnight Commander, wrong tool.
- **502 on boot** → almost always a config-validation crash (see §6 traps). Check `logs api-a`.
- **Signup 500 `42703 column does not exist`** → a migration wasn't committed/pushed. Migrations must
  be on `main` and re-run.
- **Container name conflict** → concurrent deploys; `flock` in `deploy-staging.sh` now serializes.
  Recovery: `docker compose down` → `docker rm -f` leftovers → redeploy.
- **`LimitRequestBody takes one argument`** (Apache) → no inline `#` comments on that directive.
- Deploy scripts must stay executable (`100755`) — `git update-index --chmod=+x` if they revert to 644.

---

## 11. Working rules (persistent constraints)

- **No AI/Claude attribution** in commits or PRs (no `Co-Authored-By: Claude`, no "Generated with" footer).
- **Never commit** `.env`, `.env.staging`, `.env.production` — only `*.example` templates. `.vscode/` stays untracked.
- **Never log** Stripe secret keys or webhook payloads with card data.
- **Stripe TEST keys only** until real launch (`sk_test_`, never `sk_live_`).
- **Don't ask the user to paste** SSH keys, passwords, PATs, or Stripe/API secrets into chat — give
  commands to run locally / on the server instead.
- Don't modify `lets-track-db/docker/docker-compose.yml` (dev-only) or recreate `lets-track-api/Dockerfile`.
- User communicates in Roman Urdu/Hindi — respond in the same style.

---

## 12. Quick reference

```bash
# Deploy (from your machine, infra repo)
bash scripts/manual-deploy.sh [tag]

# On server
ssh -p 8822 meissasoft@221.120.236.55
cd ~/timenova-track/lets-track-infra/staging
docker compose --env-file .env.staging ps
docker compose --env-file .env.staging logs <svc> --tail 50
bash ../scripts/deploy-staging.sh [tag] [--no-build]

# Health
curl -I https://timenova.meissasoft.com/api/health
curl -I https://s3.timenova.meissasoft.com/letstrack-downloads/agent/<file>
```
