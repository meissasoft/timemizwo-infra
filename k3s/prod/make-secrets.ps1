# Creates every Kubernetes Secret Timemizwo production needs, from the old
# server's .env.production. Prints no secret values. Safe to re-run (apply).
#
#   scp -P 8822 meissasoft@221.120.236.55:timenova-track-prod/lets-track-infra/prod/.env.production $env:TEMP\tmz.env
#   powershell -ExecutionPolicy Bypass -File k3s\prod\make-secrets.ps1 -EnvFile $env:TEMP\tmz.env
#   Remove-Item $env:TEMP\tmz.env
#
# Creates:
#   shared-databases/timemizwo-pg-secret  - CNPG role password (NEW, generated once)
#   timemizwo-prod/timemizwo-redis-secret - Redis password + REDIS_URL (NEW)
#   timemizwo-prod/timemizwo-minio-secret - MinIO root = old S3_ACCESS_KEY/S3_SECRET_KEY
#   timemizwo-prod/timemizwo-runtime      - the API's env (old file minus compose-only
#                                           keys, plus DATABASE_URL for the shared CNPG)
param([Parameter(Mandatory)] [string] $EnvFile)
$ErrorActionPreference = 'Stop'

function New-Password { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) }
function Get-SecretValue($ns, $name, $key) {
  $b64 = kubectl -n $ns get secret $name -o jsonpath="{.data.$key}" 2>$null
  if ($b64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
}
function Apply-Secret($ns, $name, [hashtable] $data) {
  $args_ = @('-n', $ns, 'create', 'secret', 'generic', $name)
  foreach ($k in $data.Keys) { $args_ += "--from-literal=$k=$($data[$k])" }
  kubectl @args_ --dry-run=client -o yaml | kubectl apply -f -
}

# --- parse the old env file: strip comments + surrounding quotes -------------
# (kubectl keeps both literally, docker compose does not)
$envs = [ordered]@{}
foreach ($line in Get-Content $EnvFile) {
  if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
  if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
  $k = $Matches[1]; $v = $Matches[2]
  if ($v -match '^"(.*)"\s*(#.*)?$' -or $v -match "^'(.*)'\s*(#.*)?$") { $v = $Matches[1] }
  else { $v = ($v -replace '\s+#.*$', '').Trim() }
  $envs[$k] = $v
}
foreach ($required in 'S3_ACCESS_KEY', 'S3_SECRET_KEY', 'JWT_SECRET', 'INTEGRATION_ENCRYPTION_KEY') {
  if (-not $envs[$required]) { throw "$required missing in $EnvFile" }
}

kubectl apply -f "$PSScriptRoot\00-namespace.yaml"

# --- Postgres role password (reuse if it already exists) --------------------
$pgPw = Get-SecretValue 'shared-databases' 'timemizwo-pg-secret' 'password'
if (-not $pgPw) { $pgPw = New-Password }
Apply-Secret 'shared-databases' 'timemizwo-pg-secret' @{ username = 'timemizwo'; password = $pgPw }
kubectl -n shared-databases label secret timemizwo-pg-secret cnpg.io/reload=true --overwrite | Out-Null

# --- Redis ---------------------------------------------------------------------
$redisPw = Get-SecretValue 'timemizwo-prod' 'timemizwo-redis-secret' 'redis-password'
if (-not $redisPw) { $redisPw = New-Password }
Apply-Secret 'timemizwo-prod' 'timemizwo-redis-secret' @{
  'redis-password' = $redisPw
  'redis-url'      = "redis://:$redisPw@timemizwo-redis:6379"
}

# --- MinIO: same root keys as the old server, so the app's S3 keys keep working
Apply-Secret 'timemizwo-prod' 'timemizwo-minio-secret' @{
  'root-user' = $envs['S3_ACCESS_KEY']; 'root-password' = $envs['S3_SECRET_KEY']
}

# --- API runtime env -----------------------------------------------------------
$composeOnly = 'IMAGE_TAG', 'PUBLIC_PORT', 'POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_DB',
  'REDIS_PASSWORD', 'REDIS_URL', 'DOWNLOADS_BUCKET', 'BACKUP_DIR', 'BACKUP_RETENTION_DAYS', 'BACKUP_REMOTE',
  'NODE_ENV', 'PORT', 'API_PREFIX'
$runtime = @{}
foreach ($k in $envs.Keys) {
  if ($composeOnly -contains $k -or $k -like 'NEXT_PUBLIC_*') { continue }
  $runtime[$k] = $envs[$k]
}
$runtime['DATABASE_URL'] = "postgresql://timemizwo:$pgPw@shared-postgres-rw.shared-databases.svc.cluster.local:5432/timemizwo"
$runtime['S3_ENDPOINT'] = 'https://s3.timemizwo.com'

$tmp = New-TemporaryFile
try {
  # UTF-8 without BOM: a BOM would become part of the first key's name
  $lines = $runtime.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }
  [IO.File]::WriteAllLines($tmp, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
  kubectl -n timemizwo-prod create secret generic timemizwo-runtime --from-env-file=$tmp --dry-run=client -o yaml |
    kubectl apply -f -
} finally { Remove-Item $tmp -Force }

Write-Host "`nSecrets applied. runtime keys: $($runtime.Count)" -ForegroundColor Green
