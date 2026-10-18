<#
.SYNOPSIS
  Windows: create .env with random secrets, then start LibreNMS.
  Works on Windows PowerShell 5.1 and on PowerShell 7 (any OS).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

.EXAMPLE
  scripts\setup.ps1 -NoStart      # only create .env, no Docker needed
#>
[CmdletBinding()]
param([switch]$NoStart)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

function Info([string]$Message) { Write-Host "==> $Message" }

# Letters and digits only, so the value is safe in .env and in URLs.
function New-Secret([int]$Length) {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $sb = New-Object System.Text.StringBuilder
        $buffer = New-Object byte[] 48
        while ($sb.Length -lt $Length) {
            $rng.GetBytes($buffer)
            [void]$sb.Append(([Convert]::ToBase64String($buffer) -replace '[^A-Za-z0-9]', ''))
        }
        return $sb.ToString().Substring(0, $Length)
    }
    finally { $rng.Dispose() }
}

# Docker wants IANA names (Asia/Ho_Chi_Minh); Windows uses its own ids.
function Get-HostTimeZone {
    if ($env:TZ) { return $env:TZ }
    $id = [System.TimeZoneInfo]::Local.Id
    if ($id -eq 'UTC') { return 'UTC' }
    if ($id -match '^[A-Za-z0-9_+-]+/[A-Za-z0-9_+/-]+$') { return $id }   # already IANA (PowerShell 7 on Linux or macOS)
    if ($PSVersionTable.PSEdition -eq 'Core') {                            # PowerShell 7 on Windows can convert
        $iana = $null
        if ([System.TimeZoneInfo]::TryConvertWindowsIdToIanaId($id, [ref]$iana)) { return $iana }
    }
    $map = @{
        'SE Asia Standard Time'         = 'Asia/Ho_Chi_Minh'
        'Singapore Standard Time'       = 'Asia/Singapore'
        'China Standard Time'           = 'Asia/Shanghai'
        'Tokyo Standard Time'           = 'Asia/Tokyo'
        'Korea Standard Time'           = 'Asia/Seoul'
        'Taipei Standard Time'          = 'Asia/Taipei'
        'India Standard Time'           = 'Asia/Kolkata'
        'AUS Eastern Standard Time'     = 'Australia/Sydney'
        'GMT Standard Time'             = 'Europe/London'
        'W. Europe Standard Time'       = 'Europe/Berlin'
        'Romance Standard Time'         = 'Europe/Paris'
        'Central Europe Standard Time'  = 'Europe/Budapest'
        'Russian Standard Time'         = 'Europe/Moscow'
        'Eastern Standard Time'         = 'America/New_York'
        'Central Standard Time'         = 'America/Chicago'
        'Mountain Standard Time'        = 'America/Denver'
        'Pacific Standard Time'         = 'America/Los_Angeles'
    }
    if ($map.ContainsKey($id)) { return $map[$id] }
    Write-Host "note: could not map the Windows time zone '$id' to an IANA name, using UTC. Edit TZ in .env if you want another." -ForegroundColor Yellow
    return 'UTC'
}

# Run a native command quietly and report only whether it succeeded.
# (Windows PowerShell 5.1 turns any stderr output into an error under 'Stop'.)
function Test-Native([string]$Exe, [string[]]$CmdArgs) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @CmdArgs *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
    finally { $ErrorActionPreference = $old }
}

function Get-EnvValue([string]$Key) {
    $match = Select-String -Path (Join-Path $Root '.env') -Pattern "^$Key=(.*)$" | Select-Object -First 1
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return ''
}

$envFile = Join-Path $Root '.env'
$example = Join-Path $Root '.env.example'
if (-not (Test-Path $example)) { Fail '.env.example not found. Run this script from a full checkout of the repository.' }

if (Test-Path $envFile) {
    foreach ($key in 'MYSQL_PASSWORD', 'LIBRENMS_SNMP_COMMUNITY') {
        if (-not (Get-EnvValue $key)) { Fail ".env exists but $key is empty. Fill it in, or delete .env and run this script again." }
    }
    Info 'Keeping the existing .env'
}
else {
    $tz = Get-HostTimeZone
    $values = @{
        TZ                      = $tz
        PUID                    = '1000'
        PGID                    = '1000'
        MYSQL_PASSWORD          = (New-Secret 32)
        LIBRENMS_SNMP_COMMUNITY = (New-Secret 24)
    }
    # PowerShell 7 on Linux or macOS: use the real user id, like setup.sh does.
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        $uid = (& id -u).Trim(); $gid = (& id -g).Trim()
        if ($uid -ne '0') { $values['PUID'] = $uid }
        if ($gid -ne '0') { $values['PGID'] = $gid }
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [System.IO.File]::ReadAllLines($example)) {
        $m = [regex]::Match($line, '^([A-Z_]+)=')
        if ($m.Success -and $values.ContainsKey($m.Groups[1].Value)) {
            $lines.Add(('{0}={1}' -f $m.Groups[1].Value, $values[$m.Groups[1].Value]))
        }
        else { $lines.Add($line) }
    }
    # LF line endings and UTF-8 without a BOM: a BOM would corrupt the first variable name.
    [System.IO.File]::WriteAllText($envFile, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Info "Created .env (timezone $tz, random database password and SNMP community)"
}

if ($NoStart) {
    Info 'Done (-NoStart). Start LibreNMS with: docker compose up -d --wait'
    exit 0
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail 'Docker is not installed. Install Docker Desktop for Windows (WSL 2 backend): https://docs.docker.com/desktop/setup/install/windows-install/'
}
if (-not (Test-Native 'docker' @('compose', 'version'))) {
    Fail 'Docker Compose v2 is missing. Update Docker Desktop.'
}
if (-not (Test-Native 'docker' @('info'))) {
    Fail 'The Docker daemon is not running. Start Docker Desktop, wait until it says "running", then run this script again.'
}

Push-Location $Root
try {
    Info 'Starting LibreNMS. The first start downloads the images and runs the database migrations, so it can take several minutes.'
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker compose up -d --wait
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }

    if ($code -ne 0) {
        $ErrorActionPreference = 'Continue'
        & docker compose ps
        & docker compose logs --tail 40 librenms
        Fail 'LibreNMS did not become healthy. See the log above, or run: docker compose logs -f'
    }

    $port = Get-EnvValue 'LIBRENMS_PORT'; if (-not $port) { $port = '8000' }
    $bind = Get-EnvValue 'LIBRENMS_BIND'; if (-not $bind) { $bind = '127.0.0.1' }
    if ($bind -eq '127.0.0.1') { $url = "http://localhost:$port" } else { $url = "http://<this-machine-address>:$port" }
    Write-Host ''
    Info "LibreNMS is running: $url"
    Write-Host '    1. Open the address above. The first visit asks you to create the admin account.'
    Write-Host '    2. Add your first device: Devices > Add Device (SNMPv3 is recommended).'
    Write-Host '    3. Back up regularly: scripts\backup.ps1'
}
finally { Pop-Location }
