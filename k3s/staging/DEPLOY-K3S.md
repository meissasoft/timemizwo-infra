# Timemizwo staging on K3s

Staging copy of `k3s/prod/` (read that runbook first). Replaces the compose
stack on the office server (`221.120.236.55`, `~/timenova-track`).

| Piece | K3s (namespace `timemizwo-staging`) |
|---|---|
| api, client | `timemizwo-api`, `timemizwo-client`, 1 replica each |
| postgres | shared CNPG `shared-postgres`, DB + role `timemizwo_staging` |
| redis | `timemizwo-redis` on db-cloud |
| minio | `timemizwo-minio` on meissasoft-server, 30Gi, **own root** + scoped `app-*` / `publisher-*` users |
| backup | CronJob `timemizwo-pg-backup` 02:30 -> `s3://timemizwo-backups/timemizwo-staging/` |
| hosts | `staging.timemizwo.com`, `s3.staging.timemizwo.com` (Caddy on the master) |

**Status:** live since 2026-10-15. The old compose staging containers and
their volumes are removed (final dump: `D:\LetsTrackAppackups	imemizwo-staging-final-2026-10-15.sql.gz`),
so sections 3 and 5 below are history and `mirror-job.yaml` is gone.

**The old staging MinIO container must keep running**: it also holds the
unrelated `fcproj` bucket (served as `s3.timenova.meissasoft.com`). Only the
old api/worker/client/postgres/redis/nginx containers go away.

## CI/CD

Same as prod, branch `staging` instead of `production`: api/client/db push ->
`ghcr.io/meissasoft/timemizwo-{api,client,db-migrate}` -> `deploy-k3s.yml`
with `environment=staging`. The client's staging image is tagged
`staging-<sha>` (its own NEXT_PUBLIC_* build). CI uses the prod ServiceAccount
`timemizwo-ci`, bound into this namespace by `70-ci-rbac.yaml` - no new
kubeconfig secret.

## 1. Secrets

```powershell
scp -P 8822 meissasoft@221.120.236.55:timenova-track/lets-track-infra/staging/.env.staging $env:TEMP\tmz-stg.env
powershell -ExecutionPolicy Bypass -File k3s\staging\make-secrets.ps1 -EnvFile $env:TEMP\tmz-stg.env
Remove-Item $env:TEMP\tmz-stg.env
```

The backup IAM user (`timemizwo-backup`) needs `s3:PutObject` on
`arn:aws:s3:::timemizwo-backups/timemizwo-staging/*` as well.

## 2. Postgres role + database

```powershell
'[{"op":"add","path":"/spec/managed/roles/-","value":{"name":"timemizwo_staging","login":true,"passwordSecret":{"name":"timemizwo-staging-pg-secret"}}}]' | Set-Content $env:TEMP\role.json
kubectl -n shared-databases patch cluster shared-postgres --type json --patch-file $env:TEMP\role.json
Remove-Item $env:TEMP\role.json
kubectl -n shared-databases exec shared-postgres-1 -c postgres -- psql -U postgres -c "CREATE DATABASE timemizwo_staging OWNER timemizwo_staging"
kubectl -n shared-databases exec shared-postgres-1 -c postgres -- psql -U postgres -d timemizwo_staging -c "SET ROLE timemizwo_staging; CREATE EXTENSION IF NOT EXISTS pgcrypto"
```

## 3. Datastores + data copy

```powershell
kubectl apply -f k3s\staging\00-namespace.yaml -f k3s\staging\10-redis.yaml -f k3s\staging\20-minio.yaml
kubectl -n timemizwo-staging wait --for=condition=complete job/timemizwo-minio-setup --timeout=300s
kubectl apply -f k3s\staging\mirror-job.yaml
```

DB copy (through `cmd` - PowerShell 5.1 pipes corrupt the dump):

```powershell
cmd /c "(echo SET ROLE timemizwo_staging; & ssh -p 8822 meissasoft@221.120.236.55 docker exec letstrack-staging-postgres-1 pg_dump -U letstrack -d letstrack --no-owner --no-acl) | kubectl -n shared-databases exec -i shared-postgres-1 -c postgres -- psql -U postgres -d timemizwo_staging -v ON_ERROR_STOP=1 -q"
```

## 4. App

```powershell
kubectl apply -k k3s\staging
kubectl -n timemizwo-staging set image deployment/timemizwo-api api=ghcr.io/meissasoft/timemizwo-api:<sha>
kubectl -n timemizwo-staging set image deployment/timemizwo-client client=ghcr.io/meissasoft/timemizwo-client:staging-<sha>
```

Test from the master: `curl -s -H "Host: staging.timemizwo.com" http://10.43.164.141/api/health`.

## 5. Cutover

1. Old server: `docker stop letstrack-staging-api-a-1 letstrack-staging-api-b-1 letstrack-staging-worker-1 letstrack-staging-client-1`.
2. Drop + recreate `timemizwo_staging`, re-run the DB copy; re-run the mirror Job.
3. Caddy on the master (backup first, validate, reload):
   `staging.timemizwo.com, s3.staging.timemizwo.com { reverse_proxy 10.43.164.141:80 { header_up Host {host} } }`
4. GoDaddy: `staging` and `s3.staging` A records -> `168.144.32.44`.
5. Afterwards: remove the old staging containers except `letstrack-staging-minio-1`,
   delete `mirror-job.yaml` and `kubectl -n timemizwo-staging delete secret timemizwo-minio-old`.

Rollback: DNS back to `221.120.236.55`, `docker start` the stopped containers.
