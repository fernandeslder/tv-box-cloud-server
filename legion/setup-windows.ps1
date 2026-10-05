<#
.SYNOPSIS
  One-command GPU worker setup for the Legion 7 on Windows 11. Idempotent: safe to re-run.

.DESCRIPTION
  Tailscale (hostname legion-win) -> Ollama (native) -> Docker Desktop (WSL2) ->
  machine env vars -> firewall (tailnet + LAN only) -> models -> docker compose
  profiles photos + audio -> health table.
  Double-click legion\setup-windows.bat, or run this script; it relaunches itself elevated (UAC).
  Docs: docs/10-legion-ai-server.md

.PARAMETER NoModels
  Skip the ~10GB Ollama model pulls.

.PARAMETER TsAuthKey
  Optional Tailscale auth key for unattended login (default: $env:TS_AUTHKEY).

.PARAMETER ImmichVersion
  Immich version for the remote ML image. MUST equal the TV box (default: $env:IMMICH_VERSION, else v3.2.4).

.EXAMPLE
  .\legion\setup-windows.ps1 -NoModels
#>
[CmdletBinding()]
param(
  [switch]$NoModels,
  [string]$TsAuthKey = $env:TS_AUTHKEY,
  [string]$ImmichVersion = $env:IMMICH_VERSION
)

$ErrorActionPreference = 'Stop'
$HostnameTs   = 'legion-win'
$Ports        = @(11434, 3003, 9000)
$Models       = @('qwen2.5:3b-instruct', 'qwen2.5:7b-instruct', 'moondream')
$FwRuleName   = 'Legion AI worker (tailnet + LAN)'
$ImmichDefault = 'v3.2.4'

$RepoDir     = Split-Path -Parent $PSScriptRoot
$ComposeDir  = Join-Path $RepoDir 'docker\ml-laptop'
$ComposeFile = Join-Path $ComposeDir 'compose.yml'

function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!!] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[XX] $m" -ForegroundColor Red }
function Step($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }

# Run a native command quietly and return its exit code (stderr output must not abort the script).
function Quiet-Exit {
  $ErrorActionPreference = 'Continue'
  & $args[0] $args[1..($args.Count - 1)] *> $null
  return $LASTEXITCODE
}

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Find-Exe($name, $fallbacks) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($f in $fallbacks) { if (Test-Path $f) { return $f } }
  return $null
}

function Install-Winget($id, $label) {
  if ((Quiet-Exit winget list --id $id -e --accept-source-agreements) -eq 0) { Ok "$label already installed"; return }
  Write-Host "... installing $label"
  & winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) { Fail "winget install $id failed (exit $LASTEXITCODE)"; return }
  Ok "$label installed"
  Refresh-Path
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Warn 'Not running as Administrator: relaunching elevated (accept the UAC prompt)'
  $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
  if ($NoModels) { $relaunch += '-NoModels' }
  if ($TsAuthKey) { $relaunch += @('-TsAuthKey', "`"$TsAuthKey`"") }
  if ($ImmichVersion) { $relaunch += @('-ImmichVersion', "`"$ImmichVersion`"") }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunch
  exit 0
}
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Fail 'winget not found. Update "App Installer" from the Microsoft Store and re-run.'
  exit 1
}
if (-not (Test-Path $ComposeFile)) { Fail "compose file not found: $ComposeFile"; exit 1 }
Ok "repo: $RepoDir"

# ---------------------------------------------------------------- Tailscale
Step 'Tailscale'
Install-Winget 'Tailscale.Tailscale' 'Tailscale'
$ts = Find-Exe 'tailscale' @("$env:ProgramFiles\Tailscale\tailscale.exe")
if (-not $ts) { Fail 'tailscale.exe not found'; exit 1 }
$running = $false
try {
  $st = (& $ts status --json 2>$null | Out-String) | ConvertFrom-Json
  $running = ($st.BackendState -eq 'Running')
} catch { $running = $false }
if ($running) {
  Quiet-Exit $ts set "--hostname=$HostnameTs" | Out-Null
  Ok "Tailscale already up; hostname ensured: $HostnameTs"
} else {
  if ($TsAuthKey) {
    & $ts up --hostname=$HostnameTs --auth-key=$TsAuthKey
  } else {
    Warn 'no TS_AUTHKEY set: approve the login in the browser window / URL below'
    & $ts up --hostname=$HostnameTs
  }
  if ($LASTEXITCODE -eq 0) { Ok "Tailscale up as $HostnameTs" } else { Fail "tailscale up failed (exit $LASTEXITCODE)" }
}

# ------------------------------------------------------------------- Ollama
Step 'Ollama (native)'
Install-Winget 'Ollama.Ollama' 'Ollama'
$ollama = Find-Exe 'ollama' @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe", "$env:ProgramFiles\Ollama\ollama.exe")
if (-not $ollama) { Fail 'ollama.exe not found (log out/in or re-run)'; exit 1 }

$want = @{ OLLAMA_HOST = '0.0.0.0'; OLLAMA_MAX_LOADED_MODELS = '1'; OLLAMA_KEEP_ALIVE = '5m' }
$envChanged = $false
foreach ($k in $want.Keys) {
  if ([Environment]::GetEnvironmentVariable($k, 'Machine') -ne $want[$k]) {
    [Environment]::SetEnvironmentVariable($k, $want[$k], 'Machine')
    $envChanged = $true
  }
  Set-Item -Path "Env:$k" -Value $want[$k]
}
$ollamaUp = $false
try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 'http://localhost:11434/api/tags' | Out-Null; $ollamaUp = $true } catch {}
if ($envChanged -or -not $ollamaUp) {
  Get-Process -Name 'ollama app', 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
  $app = Join-Path (Split-Path $ollama) 'ollama app.exe'
  if (Test-Path $app) { Start-Process $app } else { Start-Process $ollama -ArgumentList 'serve' -WindowStyle Hidden }
  Ok 'Ollama (re)started with the new environment'
}
Ok 'system env: OLLAMA_HOST=0.0.0.0, OLLAMA_MAX_LOADED_MODELS=1, OLLAMA_KEEP_ALIVE=5m'

# ------------------------------------------------------------------ Firewall
Step 'Windows Firewall (tailnet + LAN only)'
Get-NetFirewallRule -DisplayName $FwRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $FwRuleName -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort $Ports -RemoteAddress @('100.64.0.0/10', 'LocalSubnet') -Profile Any | Out-Null
Ok "inbound TCP $($Ports -join ',') allowed from 100.64.0.0/10 + LocalSubnet only"

# ------------------------------------------------------------------- Models
Step 'Ollama models'
function Wait-Url($url, $tries, $delay) {
  for ($i = 0; $i -lt $tries; $i++) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 $url
      return [int]$r.StatusCode
    } catch { Start-Sleep -Seconds $delay }
  }
  return 0
}
if ($NoModels) {
  Warn '-NoModels: skipping model pulls'
} elseif ((Wait-Url 'http://localhost:11434/api/tags' 30 1) -eq 0) {
  Fail 'Ollama API not answering on :11434; skipping model pulls'
} else {
  $have = @(& $ollama list | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] })
  foreach ($m in $Models) {
    $name = if ($m -match ':') { $m } else { "${m}:latest" }
    if ($have -contains $name) { Ok "model present: $m"; continue }
    Write-Host "... pulling $m"
    & $ollama pull $m
    if ($LASTEXITCODE -eq 0) { Ok "pulled $m" } else { Fail "pull failed: $m" }
  }
}

# ------------------------------------------------------------ Docker Desktop
Step 'Docker Desktop (WSL2)'
$wslOk = $false
try { $wslOk = ((Quiet-Exit wsl --status) -eq 0) } catch {}
if (-not $wslOk) {
  Warn 'WSL2 not ready: installing (a reboot may be required, then re-run this script)'
  & wsl --install --no-distribution
}
Install-Winget 'Docker.DockerDesktop' 'Docker Desktop'
Refresh-Path
$docker = Find-Exe 'docker' @("$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe")
if (-not $docker) {
  Fail 'docker.exe not found: reboot (WSL2/Docker need it on first install) and re-run this script'
  exit 1
}
$dockerReady = $false
if ((Quiet-Exit $docker info) -eq 0) { $dockerReady = $true } else {
  $desktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
  if (Test-Path $desktop) { Start-Process $desktop }
  Write-Host '... waiting for the Docker engine (up to 3 min; accept the Docker license if prompted)'
  for ($i = 0; $i -lt 36 -and -not $dockerReady; $i++) {
    Start-Sleep -Seconds 5
    if ((Quiet-Exit $docker info) -eq 0) { $dockerReady = $true }
  }
}

# ------------------------------------------------------------ Docker compose
Step 'Docker compose (profiles: photos + audio)'
$envFile = Join-Path $ComposeDir '.env'
$envLines = @()
if (Test-Path $envFile) { $envLines = @(Get-Content $envFile) }
$existing = $envLines | Where-Object { $_ -match '^IMMICH_VERSION=.' } | Select-Object -Last 1
if ($ImmichVersion) { $ver = $ImmichVersion }
elseif ($existing) { $ver = ($existing -split '=', 2)[1] }
else { $ver = $ImmichDefault; Warn "IMMICH_VERSION not set: using $ver. It MUST match the TV box (docker/.env)" }
$envLines = @($envLines | Where-Object { $_ -notmatch '^IMMICH_VERSION=' }) + "IMMICH_VERSION=$ver"
Set-Content -Path $envFile -Value $envLines -Encoding ASCII
Ok "IMMICH_VERSION=$ver (saved in docker\ml-laptop\.env)"

if (-not $dockerReady) {
  Fail 'Docker engine not ready: start Docker Desktop, then re-run this script'
} else {
  & $docker compose -f $ComposeFile --profile photos --profile audio up -d
  if ($LASTEXITCODE -eq 0) { Ok 'compose up (immich-machine-learning :3003, whisper :9000)' }
  else { Fail 'compose up failed (NVIDIA driver / WSL2 GPU support ok? image pull ok?)' }
}

# ------------------------------------------------------------- Health table
Step 'Health'
$bad = $false
function Check($name, $url, $tries) {
  $code = Wait-Url $url $tries 5
  if ($code -ge 200 -and $code -lt 400) {
    Write-Host ("  [OK] {0,-12} {1,-40} HTTP {2}" -f $name, $url, $code) -ForegroundColor Green
    return $true
  }
  Write-Host ("  [XX] {0,-12} {1,-40} no answer" -f $name, $url) -ForegroundColor Red
  return $false
}
if (-not (Check 'ollama'    'http://localhost:11434/api/tags' 3))  { $bad = $true }
if (-not (Check 'immich-ml' 'http://localhost:3003/ping'      12)) { $bad = $true }
if (-not (Check 'whisper'   'http://localhost:9000/docs'      12)) { $bad = $true }
Write-Host ''
if ($bad) { Warn 'some services are not answering yet (first start downloads images/models; re-run to re-check)' }
else { Ok 'all services healthy' }

Write-Host @"

NEXT STEP:
  In Immich admin (Administration -> Settings -> Machine Learning) set the URL to
  http://${HostnameTs}:3003   (or set IMMICH_ML_URL=http://${HostnameTs}:3003 on the TV box).
  Immich server on the TV box must run version $ver.
  Check from the TV box:  curl http://${HostnameTs}:11434/api/tags
"@
