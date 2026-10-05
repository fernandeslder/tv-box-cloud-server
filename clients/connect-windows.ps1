<#
.SYNOPSIS
  Connect this PC to the home server: maps U: (Uploads) and Z: (Cloud).
.PARAMETER Server
  Server name or LAN IP. Default: $env:TVBOX_HOST, else tries tvbox then tvbox.local.
.PARAMETER Domain
  Your server domain (default: $env:TVBOX_DOMAIN). Needed only for -InstallCert.
.PARAMETER InstallCert
  Download https://setup.<Domain>/root.crt and trust it for the current user.
#>
param(
  [string]$Server = $env:TVBOX_HOST,
  [string]$Domain = $env:TVBOX_DOMAIN,
  [string]$Username,
  [switch]$InstallCert
)

$ErrorActionPreference = 'Stop'
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!]  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[X]  $m" -ForegroundColor Red }

function Test-Smb([string]$name) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect($name, 445, $null, $null)
    $good = $iar.AsyncWaitHandle.WaitOne(3000) -and $c.Connected
    $c.Close()
    return $good
  } catch { return $false }
}

# Pick the server
if (-not $Server) {
  foreach ($cand in 'tvbox', 'tvbox.local') { if (Test-Smb $cand) { $Server = $cand; break } }
}
if (-not $Server -or -not (Test-Smb $Server)) {
  Warn "Cannot reach the server by name."
  $Server = Read-Host "Type the server's LAN IP (e.g. 192.168.1.50)"
  if (-not (Test-Smb $Server)) { Fail "Still cannot reach $Server on port 445. Check you are on the home network."; exit 1 }
}
Ok "Found server: $Server"

# Credentials (password stays a SecureString; never printed or written to disk)
if ($Username) {
  $cred = Get-Credential -UserName $Username -Message "SMB password for $Server"
} else {
  $cred = Get-Credential -Message "Home server username and SMB password"
}
if (-not $cred) { Fail "Cancelled."; exit 1 }
$user = $cred.UserName
$plain = $cred.GetNetworkCredential().Password

$maps = @(
  @{ Letter = 'U:'; Share = 'Uploads'; Note = 'drop files here, they auto-sort' },
  @{ Letter = 'Z:'; Share = 'Cloud';   Note = 'your sorted library' }
)
foreach ($m in $maps) {
  $unc = "\\$Server\$($m.Share)"
  try {
    if (Get-SmbMapping -LocalPath $m.Letter -ErrorAction SilentlyContinue) {
      Remove-SmbMapping -LocalPath $m.Letter -Force -UpdateProfile -ErrorAction SilentlyContinue
    }
    # Same effect as `net use /persistent:yes`, but the password is passed in-process, not on a command line.
    New-SmbMapping -LocalPath $m.Letter -RemotePath $unc -UserName $user -Password $plain -Persistent $true | Out-Null
    Ok "$($m.Letter) -> $unc  ($($m.Note))"
  } catch {
    Fail "Could not map $($m.Letter) to $unc : $($_.Exception.Message)"
    Warn "Wrong password, or Windows already has a different login for this server (run: net use * /delete)."
  }
}
$plain = $null

if ($InstallCert) {
  if (-not $Domain) { $Domain = Read-Host "Server domain (e.g. home.example.org)" }
  $tmp = Join-Path $env:TEMP 'tvbox-root.crt'
  try {
    # -k only for this bootstrap download: we cannot trust the CA before we have it.
    & curl.exe -fsSk -o $tmp "https://setup.$Domain/root.crt"
    if ($LASTEXITCODE -ne 0) { throw "download failed" }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $tmp
    Warn "Certificate: $($cert.Subject)  SHA1: $($cert.Thumbprint)"
    Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    Ok "Root certificate trusted for this user (confirm the Windows prompt if shown). Restart your browser."
  } catch {
    Fail "Could not install the certificate from https://setup.$Domain/root.crt : $($_.Exception.Message)"
  } finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
  }
}

Ok "Done. Open This PC to see U: and Z:."
