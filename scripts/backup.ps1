<#
.SYNOPSIS
  Windows: back up the LibreNMS database and data volume to .\backups
  Works on Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
  scripts\backup.ps1               # one backup set (librenms-YYYYMMDD-HHMMSS-*)
  scripts\backup.ps1 -Keep 7       # also delete all but the newest 7 sets
  scripts\backup.ps1 -Verify       # then restore the new set into a throw-away database to prove it works
  scripts\backup.ps1 -NoOffsite    # skip the upload that BACKUP_REMOTE in .env asks for

.NOTES
  The dispatcher is paused while the backup runs, so the RRD files are consistent
  (graphs get a short gap). It is restarted afterwards, even if the backup fails.

  Off-site copy: set BACKUP_REMOTE in .env to an rclone destination (for example s3:my-bucket/netmonitor) and
  install rclone; every set is uploaded after it passed its checks. Old sets there are yours to expire (a bucket
  lifecycle rule), -Keep only prunes .\backups.
#>
[CmdletBinding()]
param([int]$Keep = 0, [switch]$Verify, [switch]$NoOffsite)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

# Run docker with a relaxed error preference (Windows PowerShell 5.1 treats stderr output as an error under 'Stop').
# Returns the exit code; with -Capture also returns stdout lines.
function Invoke-Docker([string[]]$DockerArgs, [switch]$Capture) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Capture) {
            $lines = @(& docker @DockerArgs 2>$null)
            return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $lines }
        }
        & docker @DockerArgs | Out-Host
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = @() }
    }
    finally { $ErrorActionPreference = $old }
}

if ($Keep -lt 0) { Fail '-Keep cannot be negative' }
if (-not (Test-Path (Join-Path $Root '.env'))) { Fail 'no .env found. Run scripts\setup.ps1 first.' }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail 'Docker is not installed.' }

Push-Location $Root
try {
    if ((Invoke-Docker @('info') -Capture).Code -ne 0) { Fail 'The Docker daemon is not running. Start Docker Desktop.' }

    $name = 'librenms-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Force -Path 'backups' | Out-Null

    if ((Invoke-Docker @('compose', 'up', '-d', '--wait', 'db')).Code -ne 0) { Fail 'could not start the database container' }

    $running = (Invoke-Docker @('compose', 'ps', '--status', 'running', '--services') -Capture).Output
    $paused = $running -contains 'dispatcher'
    if ($paused) { [void](Invoke-Docker @('compose', 'stop', 'dispatcher')) }
    try {
        # With -Verify the old sets are pruned only after the new one proved itself (separate runs below).
        $keepNow = $Keep
        if ($Verify) { $keepNow = 0 }
        $result = Invoke-Docker @('compose', 'run', '--rm', '--no-deps', '-e', "BACKUP_NAME=$name", '-e', "KEEP=$keepNow", 'tools', '/scripts/backup.sh')
        if ($result.Code -ne 0) { Fail 'backup failed (see the messages above)' }
    }
    finally {
        if ($paused) { [void](Invoke-Docker @('compose', 'start', 'dispatcher')) }
    }
    if ($Verify) {
        Write-Host 'Restore test ...'
        $check = Invoke-Docker @('compose', 'run', '--rm', '--no-deps', '-e', "BACKUP_NAME=$name", 'tools', '/scripts/verify.sh')
        if ($check.Code -ne 0) { Fail "the backup was written but did NOT pass the restore test: do not rely on $name (older sets were not pruned)" }
        if ($Keep -gt 0) { [void](Invoke-Docker @('compose', 'run', '--rm', '--no-deps', '-e', "KEEP=$Keep", 'tools', '/scripts/prune.sh')) }
    }
    Write-Host "Done. Files are in .\backups (name: $name)"

    # Off-site copy, when asked for in .env (and not switched off).
    $remote = $env:BACKUP_REMOTE
    if (-not $remote) {
        $line = Get-Content -LiteralPath (Join-Path $Root '.env') | Where-Object { $_ -like 'BACKUP_REMOTE=*' } | Select-Object -First 1
        if ($line) { $remote = ($line.Substring('BACKUP_REMOTE='.Length)).Trim().Trim('"').Trim("'") }
    }
    if ($remote -and -not $NoOffsite) {
        if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) { Fail 'BACKUP_REMOTE is set but rclone is not installed. The backup is in .\backups; install rclone (https://rclone.org) or use -NoOffsite.' }
        Write-Host "Uploading to $remote ..."
        foreach ($file in @("backups/$name-db.sql.gz", "backups/$name-data.tgz")) {
            & rclone copy --checksum $file $remote
            if ($LASTEXITCODE -ne 0) { Fail "the upload of $file failed; the backup itself is in .\backups" }
        }
        Write-Host "Uploaded $name to $remote"
    }
}
finally { Pop-Location }
