<#
.SYNOPSIS
  Windows: restore the database and data volume from .\backups
  Works on Windows PowerShell 5.1 and PowerShell 7.

.DESCRIPTION
  This REPLACES the current database and data. LibreNMS is stopped while it runs.

.EXAMPLE
  scripts\restore.ps1 latest                      # newest backup
  scripts\restore.ps1 librenms-20260101-120000    # a specific one (or just 20260101-120000)
  scripts\restore.ps1 .\backups\20260101-120000   # a path or a file name from .\backups also works
  scripts\restore.ps1 latest -Yes                 # skip the confirmation question
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)][string]$Backup,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

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

if (-not (Test-Path (Join-Path $Root '.env'))) { Fail 'no .env found. Run scripts\setup.ps1 first.' }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail 'Docker is not installed.' }

Push-Location $Root
try {
    if ((Invoke-Docker @('info') -Capture).Code -ne 0) { Fail 'The Docker daemon is not running. Start Docker Desktop.' }

    $target = $Backup
    # Accept what tab-completion produces: a path and/or the file name with its suffix, for example
    # .\backups\librenms-20260101-120000-db.sql.gz or ./backups/20260101-120000
    $target = $target -replace '^.*[\\/]', ''
    $target = $target -replace '(-db\.sql\.gz|-data\.tgz)$', ''
    if (-not $target) { Fail "say which backup to restore: 'latest' or a name from .\backups" }
    if ($target -eq 'latest') {
        $newest = Get-ChildItem -Path 'backups' -Filter 'librenms-*-db.sql.gz' -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -Last 1
        if (-not $newest) { Fail 'no backups found in .\backups' }
        $target = $newest.Name -replace '-db\.sql\.gz$', ''
    }
    if (-not $target.StartsWith('librenms-')) { $target = "librenms-$target" }

    $dbFile = Join-Path 'backups' "$target-db.sql.gz"
    $dataFile = Join-Path 'backups' "$target-data.tgz"
    if (-not ((Test-Path $dbFile) -and (Test-Path $dataFile))) {
        Fail "$dbFile and $dataFile must both exist"
    }

    Write-Host "About to restore '$target'. The current LibreNMS database and data will be REPLACED."
    if (-not $Yes) {
        $answer = Read-Host "Type 'yes' to continue"
        if ($answer -ne 'yes') { Fail 'cancelled' }
    }

    [void](Invoke-Docker @('compose', 'stop'))
    if ((Invoke-Docker @('compose', 'up', '-d', '--wait', 'db')).Code -ne 0) { Fail 'could not start the database container' }
    if ((Invoke-Docker @('compose', 'run', '--rm', '--no-deps', '-e', "BACKUP_NAME=$target", 'tools', '/scripts/restore.sh')).Code -ne 0) {
        Fail 'restore failed (see the messages above). LibreNMS stays stopped; fix the problem and run the restore again.'
    }
    if ((Invoke-Docker @('compose', 'up', '-d', '--wait')).Code -ne 0) { Fail 'restored, but LibreNMS did not become healthy: docker compose logs -f' }
    Write-Host "Restored from $target."
}
finally { Pop-Location }
