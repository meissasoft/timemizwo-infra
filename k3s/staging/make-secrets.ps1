# Creates every Kubernetes Secret Timemizwo staging needs, from the old
# server's .env.staging. Prints no secret values. First-time bootstrap only:
# refuses to run once timemizwo-staging/timemizwo-runtime exists.
#
#   scp -P 8822 meissasoft@221.120.236.55:timenova-track/lets-track-infra/staging/.env.staging $env:TEMP\tmz-stg.env
#   powershell -ExecutionPolicy Bypass -File k3s\staging\make-secrets.ps1 -EnvFile $env:TEMP\tmz-stg.env
#   Remove-Item $env:TEMP\tmz-stg.env
#
# Creates:
#   shared-databases/timemizwo-staging-pg-secret - CNPG role timemizwo_staging (generated)
#   timemizwo-staging/timemizwo-redis-secret     - Redis password + REDIS_URL (generated)
#   timemizwo-staging/timemizwo-minio-secret     - NEW MinIO root (generated; the old
#                                                  staging root also owns fcproj)
#   timemizwo-staging/timemizwo-minio-users      - scoped app-* / publisher-* keys (generated)
#   timemizwo-staging/timemizwo-minio-old        - old staging S3 keys, only for mirror-job.yaml
#   timemizwo-staging/timemizwo-runtime          - the API's env (old file minus compose-only
#                                                  keys, plus DATABASE_URL and the app-* S3 key)
#   timemizwo-staging/timemizwo-ghcr-pull, timemizwo-backup-s3 - copied from timemizwo-prod
param([Parameter(Mandatory)] [string] $EnvFile)
$ErrorActionPreference = 'Stop'
$ns = 'timemizwo-staging'

function New-Password([int] $n = 32) { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count $n | ForEach-Object { [char]$_ }) }
function Apply-Secret($ns, $name, [hashtable] $data) {
  $args_ = @('-n', $ns, 'create', 'secret', 'generic', $name)
  foreach ($k in $data.Keys) { $args_ += "--from-literal=$k=$($data[$k])" }
  kubectl @args_ --dry-run=client -o yaml | kubectl apply -f -
}
function Copy-Secret($name) {
  # whole object minus server-side metadata; values never touch stdout
  $s = kubectl -n timemizwo-prod get secret $name -o json | ConvertFrom-Json
  $copy = [ordered]@{ apiVersion = 'v1'; kind = 'Secret'; type = $s.type
    metadata = @{ name = $name; namespace = $ns }; data = $s.data }
  $copy | ConvertTo-Json -Depth 5 | kubectl apply -f -
}

if (kubectl -n $ns get secret --field-selector metadata.name=timemizwo-runtime -o name 2>$null) {
  Write-Host 'timemizwo-staging/timemizwo-runtime already exists - refusing to overwrite it. Patch single keys instead.' -ForegroundColor Red
  exit 1
}

# --- parse the old env file: strip comments + surrounding quotes -------------
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
if ($envs['APP_URL'] -ne 'https://staging.timemizwo.com') { throw "APP_URL is not staging - wrong env file?" }

kubectl apply -f "$PSScriptRoot\00-namespace.yaml"

# --- Postgres role -------------------------------------------------------------
$pgPw = New-Password
Apply-Secret 'shared-databases' 'timemizwo-staging-pg-secret' @{ username = 'timemizwo_staging'; password = $pgPw }
kubectl -n shared-databases label secret timemizwo-staging-pg-secret cnpg.io/reload=true --overwrite | Out-Null

# --- Redis ---------------------------------------------------------------------
$redisPw = New-Password
Apply-Secret $ns 'timemizwo-redis-secret' @{
  'redis-password' = $redisPw
  'redis-url'      = "redis://:$redisPw@timemizwo-redis:6379"
}

# --- MinIO: fresh root + scoped users; old keys kept only for the mirror Job ----
Apply-Secret $ns 'timemizwo-minio-secret' @{ 'root-user' = "root-$(New-Password 12)"; 'root-password' = New-Password 40 }
$appKey = "app-$(New-Password 16)"; $appSecret = New-Password 40
Apply-Secret $ns 'timemizwo-minio-users' @{
  'app-access-key' = $appKey; 'app-secret-key' = $appSecret
  'publisher-access-key' = "publisher-$(New-Password 16)"; 'publisher-secret-key' = New-Password 40
}
Apply-Secret $ns 'timemizwo-minio-old' @{ 'access-key' = $envs['S3_ACCESS_KEY']; 'secret-key' = $envs['S3_SECRET_KEY'] }

# --- shared with prod ----------------------------------------------------------
Copy-Secret 'timemizwo-ghcr-pull'
Copy-Secret 'timemizwo-backup-s3'

# --- API runtime env -----------------------------------------------------------
$composeOnly = 'IMAGE_TAG', 'PUBLIC_PORT', 'POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_DB',
  'REDIS_PASSWORD', 'REDIS_URL', 'DOWNLOADS_BUCKET', 'BACKUP_DIR', 'BACKUP_RETENTION_DAYS', 'BACKUP_REMOTE',
  'NODE_ENV', 'PORT', 'API_PREFIX'
$runtime = @{}
foreach ($k in $envs.Keys) {
  if ($composeOnly -contains $k -or $k -like 'NEXT_PUBLIC_*') { continue }
  $runtime[$k] = $envs[$k]
}
$runtime['DATABASE_URL'] = "postgresql://timemizwo_staging:$pgPw@shared-postgres-rw.shared-databases.svc.cluster.local:5432/timemizwo_staging"
$runtime['S3_ENDPOINT'] = 'https://s3.staging.timemizwo.com'
$runtime['S3_BUCKET'] = 'timemizwo-screenshots'
$runtime['S3_ACCESS_KEY'] = $appKey
$runtime['S3_SECRET_KEY'] = $appSecret

$tmp = New-TemporaryFile
try {
  # UTF-8 without BOM: a BOM would become part of the first key's name
  $lines = $runtime.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }
  [IO.File]::WriteAllLines($tmp, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
  kubectl -n $ns create secret generic timemizwo-runtime --from-env-file=$tmp --dry-run=client -o yaml |
    kubectl apply -f -
} finally { Remove-Item $tmp -Force }

Write-Host "`nSecrets applied. runtime keys: $($runtime.Count)" -ForegroundColor Green
