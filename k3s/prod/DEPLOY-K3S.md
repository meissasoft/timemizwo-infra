# Timemizwo production on K3s

Replaces the docker-compose stack on the office server (`221.120.236.55`,
`~/timenova-track-prod`). Same cluster pattern as toyshutch-inventory and
Finova. Staging comes later as `k3s/staging/` (own namespace, own DB
`timemizwo_staging` in the same shared CNPG, own client build).

| Piece | Old (compose) | K3s |
|---|---|---|
| api-a, api-b, worker | 3 containers, same image | `timemizwo-api`, 1 replica (does REST + Socket.IO + BullMQ) |
| client | container | `timemizwo-client`, 1 replica |
| nginx | path router | Traefik Ingress `timemizwo-web` |
| postgres 16 | own container | shared CNPG `shared-postgres`, DB + role `timemizwo` |
| redis 7 | own container | `timemizwo-redis` on db-cloud, `noeviction` |
| minio | own container | `timemizwo-minio` on meissasoft-server, 100Gi |
| migrate | compose profile | Job per deploy (`migrate-job.yaml`, run by CI) |
| backup | `backup-prod.sh` (never ran - no rclone) | CronJob `timemizwo-pg-backup` -> AWS S3 |
| TLS | host Apache + certbot | Caddy on the master |

Hostnames stay the same (`timemizwo.com`, `www`, `s3.timemizwo.com`, GoDaddy
DNS), so OAuth redirect URIs, Stripe webhook and installed agents keep working.

## CI/CD

```
api/client/db repo, push to `production`
  -> build image -> ghcr.io/meissasoft/timemizwo-{api,client,db-migrate}:<sha>
  -> workflow_dispatch -> timemizwo-infra `deploy-k3s.yml` (owner-only)
       -> db/api: run migrate Job, wait for success
       -> api/client: kubectl set image + rollout status
```

Secrets:
- **timemizwo-infra** (owner only): `TS_AUTHKEY`, `KUBECONFIG_PROD_B64`.
- **api, client, db**: `DEPLOY_DISPATCH_PAT` only. A fine-grained PAT, resource
  owner `meissasoft` (org), repository `timemizwo-infra` only, permission
  **Actions: Read and write** and nothing else. Don't use a Contents-write
  token here: Contents-write can push a workflow that prints the infra secrets.

## 1. Postgres (shared CNPG)

```powershell
# from the timemizwo-infra repo root (main branch)
scp -P 8822 meissasoft@221.120.236.55:timenova-track-prod/lets-track-infra/prod/.env.production $env:TEMP\tmz.env
powershell -ExecutionPolicy Bypass -File k3s\prod\make-secrets.ps1 -EnvFile $env:TEMP\tmz.env
Remove-Item $env:TEMP\tmz.env
```

Add the role (appends; other apps' roles untouched):

```powershell
'[{"op":"add","path":"/spec/managed/roles/-","value":{"name":"timemizwo","login":true,"passwordSecret":{"name":"timemizwo-pg-secret"}}}]' | Set-Content $env:TEMP\role.json
kubectl -n shared-databases patch cluster shared-postgres --type json --patch-file $env:TEMP\role.json
Remove-Item $env:TEMP\role.json
```

CNPG 1.24 has no `Database` object, so create the DB with psql (superuser over
the pod socket). pgcrypto is a trusted extension, so it is created *as
`timemizwo`*: the role then owns it and the restored dump's
`COMMENT ON EXTENSION` doesn't fail.

```powershell
kubectl -n shared-databases exec shared-postgres-1 -c postgres -- psql -U postgres -c "CREATE DATABASE timemizwo OWNER timemizwo"
kubectl -n shared-databases exec shared-postgres-1 -c postgres -- psql -U postgres -d timemizwo -c "SET ROLE timemizwo; CREATE EXTENSION IF NOT EXISTS pgcrypto"
```

## 2. Remaining secrets

```powershell
# GHCR pull - classic PAT, read:packages only
kubectl -n timemizwo-prod create secret docker-registry timemizwo-ghcr-pull `
  --docker-server=ghcr.io --docker-username=ubaid-meissasoft `
  --docker-password=<classic PAT read:packages> --dry-run=client -o yaml | kubectl apply -f -

# Backup target (AWS S3)
kubectl -n timemizwo-prod create secret generic timemizwo-backup-s3 `
  --from-literal=bucket=<bucket> --from-literal=region=<region> `
  --from-literal=aws-access-key-id=<id> --from-literal=aws-secret-access-key=<key> `
  --dry-run=client -o yaml | kubectl apply -f -
```

## 3. Datastores + first data copy (rehearsal)

```powershell
kubectl apply -f k3s\prod\10-redis.yaml -f k3s\prod\20-minio.yaml
kubectl -n timemizwo-prod wait --for=condition=complete job/timemizwo-minio-setup --timeout=300s
```

Copy the DB (11 MB) - restore runs as the `timemizwo` role so it owns everything:

Run through `cmd`, not PowerShell pipes/redirects (PowerShell 5.1 re-encodes
the stream as UTF-16 and corrupts the dump):

```powershell
cmd /c "(echo SET ROLE timemizwo; & ssh -p 8822 meissasoft@221.120.236.55 docker exec letstrack-prod-postgres-1 pg_dump -U letstrack -d letstrack --no-owner --no-acl) | kubectl -n shared-databases exec -i shared-postgres-1 -c postgres -- psql -U postgres -d timemizwo -v ON_ERROR_STOP=1 -q"
```

Then compare row counts of a few tables (`users`, `organizations`,
`time_entries`) between old and new.

Copy MinIO (only `timemizwo-downloads` has data today; screenshots is empty):
run `mc mirror` from the old server into a port-forward, or from a pod - see
section 6.

## 4. App

CI must have pushed images first (section 5), then:

```powershell
kubectl apply -k k3s\prod
kubectl -n timemizwo-prod set image deployment/timemizwo-api api=ghcr.io/meissasoft/timemizwo-api:<sha>
kubectl -n timemizwo-prod set image deployment/timemizwo-client client=ghcr.io/meissasoft/timemizwo-client:<sha>
```

Test through Traefik from the master before touching DNS:

```bash
curl -s -H "Host: timemizwo.com" http://10.43.164.141/api/health; echo
curl -sI -H "Host: timemizwo.com" http://10.43.164.141/ | head -1
curl -sI -H "Host: s3.timemizwo.com" http://10.43.164.141/timemizwo-downloads/agent/latest/manifest.json | head -1
```

## 5. CI secrets

`KUBECONFIG_PROD_B64` - same recipe as Finova, namespace `timemizwo-prod`,
token from secret `timemizwo-ci-token`. `TS_AUTHKEY` - the saved `tag:ci` key.

## 6. Cutover (planned, ~10-15 min downtime)

1. Stop writes on the old stack: `docker compose --env-file .env.production stop api-a api-b worker client`
   (keep postgres/minio running).
2. Re-run the DB copy from section 3 (drop + recreate `timemizwo` first) and
   `mc mirror --overwrite` the buckets.
3. Append Caddy blocks (backup first, validate, reload):
   `timemizwo.com, www.timemizwo.com, s3.timemizwo.com { reverse_proxy 10.43.164.141:80 { header_up Host {host} } }`
4. GoDaddy: lower TTL beforehand; `@`, `www`, `s3` A records -> `168.144.32.44`.
5. Verify login, agent check-in (Socket.IO), screenshot upload (presigned PUT
   to s3), agent update manifest, Stripe webhook (Stripe dashboard -> resend).

Rollback: GoDaddy records back to `221.120.236.55`, `docker compose ... start`
on the old server.
