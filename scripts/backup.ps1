<#
.SYNOPSIS
  Windows: back up the LibreNMS database and data volume to .\backups
  Works on Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
  scripts\backup.ps1               # one backup set (librenms-YYYYMMDD-HHMMSS-*)
  scripts\backup.ps1 -Keep 7       # also delete all but the newest 7 sets

.NOTES
  The dispatcher is paused while the backup runs, so the RRD files are consistent
  (graphs get a short gap). It is restarted afterwards, even if the backup fails.
#>
[CmdletBinding()]
param([int]$Keep = 0)

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
        $result = Invoke-Docker @('compose', 'run', '--rm', '--no-deps', '-e', "BACKUP_NAME=$name", '-e', "KEEP=$Keep", 'tools', '/scripts/backup.sh')
        if ($result.Code -ne 0) { Fail 'backup failed (see the messages above)' }
    }
    finally {
        if ($paused) { [void](Invoke-Docker @('compose', 'start', 'dispatcher')) }
    }
    Write-Host "Done. Files are in .\backups (name: $name)"
}
finally { Pop-Location }
