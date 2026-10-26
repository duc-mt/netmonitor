<#
.SYNOPSIS
  Windows: one entry point for the everyday commands.
  Works on Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
  .\scripts\run.ps1 up                       # start the stack
  .\scripts\run.ps1 down                     # stop it (the data volumes are kept)
  .\scripts\run.ps1 restart [service]        # restart everything, or one service
  .\scripts\run.ps1 logs [service]           # follow the logs (Ctrl-C to stop)
  .\scripts\run.ps1 status                   # show the containers (docker compose ps)
  .\scripts\run.ps1 backup [-Keep 7]         # back up the database and data to .\backups
  .\scripts\run.ps1 restore latest [-Yes]    # restore from .\backups: 'latest', a name or a file path
  .\scripts\run.ps1 validate                 # run LibreNMS' own self-check (validate.php)
  .\scripts\run.ps1 configure [-DryRun]     # apply the settings in .env to LibreNMS (workers, mail, NetFlow); safe to repeat
  .\scripts\run.ps1 add-device <host> [opts] # add a device (e.g. .\scripts\run.ps1 add-device 192.168.1.1 -v 2c -c public)
  .\scripts\run.ps1 scan <subnet> [options]  # auto-discover devices on subnet (e.g. .\scripts\run.ps1 scan 192.168.1.0/24)
  .\scripts\run.ps1 update [-NoBackup]      # back up, pull newer images, restart, self-check
  .\scripts\run.ps1 doctor [-Fix]           # check the setup (Docker, .env, profiles, memory); -Fix repairs permissions

.NOTES
  If scripts are blocked:  powershell -ExecutionPolicy Bypass -File scripts\run.ps1 up
#>
$Command = 'help'
$Name = ''
$Keep = 0
$Yes = $false
$DryRun = $false
$NoBackup = $false
$Fix = $false
$ExtraArgs = @()

$rawArgs = @($args)
if ($rawArgs.Count -gt 0 -and $rawArgs[0] -notmatch '^-') {
    $Command = $rawArgs[0]
    $rawArgs = @($rawArgs | Select-Object -Skip 1)
}

$i = 0
while ($i -lt $rawArgs.Count) {
    $arg = $rawArgs[$i]
    switch -Regex ($arg) {
        '^(-Command|--command)$' {
            $i++
            if ($i -lt $rawArgs.Count) { $Command = $rawArgs[$i] }
        }
        '^(-Command:)(.+)$' {
            $Command = $Matches[2]
        }
        '^(-Keep|--keep)$' {
            $i++
            if ($i -lt $rawArgs.Count) { $Keep = [int]$rawArgs[$i] }
        }
        '^(-Keep:)(\d+)$' {
            $Keep = [int]$Matches[2]
        }
        '^(-Yes|--yes|-y)$' { $Yes = $true }
        '^(-DryRun|--dry-run)$' { $DryRun = $true }
        '^(-NoBackup|--no-backup)$' { $NoBackup = $true }
        '^(-Fix|--fix)$' { $Fix = $true }
        default {
            if (-not $Name -and $Command -in @('restart', 'logs', 'restore', 'add-device', 'scan') -and $arg -notmatch '^-') {
                $Name = $arg
            }
            else {
                $ExtraArgs += $arg
            }
        }
    }
    $i++
}

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Fail([string]$Message) {
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

function Show-Usage {
    @(
        'Usage: .\scripts\run.ps1 <command> [options]'
        ''
        '  .\scripts\run.ps1 up                       start the stack'
        '  .\scripts\run.ps1 down                     stop it (the data volumes are kept)'
        '  .\scripts\run.ps1 restart [service]        restart everything, or one service'
        '  .\scripts\run.ps1 logs [service]           follow the logs (Ctrl-C to stop)'
        '  .\scripts\run.ps1 status                   show the containers (docker compose ps)'
        '  .\scripts\run.ps1 backup [-Keep 7]         back up the database and data to .\backups'
        '  .\scripts\run.ps1 restore latest [-Yes]    restore from .\backups: ''latest'', a name or a file path'
        '  .\scripts\run.ps1 validate                 run LibreNMS'' own self-check (validate.php)'
        '  .\scripts\run.ps1 configure [-DryRun]     apply the settings in .env to LibreNMS (workers, mail, NetFlow); safe to repeat'
        '  .\scripts\run.ps1 add-device <host> [opts] add a device (e.g. .\scripts\run.ps1 add-device 192.168.1.1 -v 2c -c public)'
        '  .\scripts\run.ps1 scan <subnet> [options]  auto-discover subnet devices via SNMP (e.g. .\scripts\run.ps1 scan 192.168.1.0/24)'
        '  .\scripts\run.ps1 update [-NoBackup]      back up, pull newer images, restart, self-check'
        '  .\scripts\run.ps1 doctor [-Fix]           check setup (Docker, .env, profiles, memory); -Fix repairs .env permissions'
    ) | ForEach-Object { Write-Host $_ }
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

# A setting's value: the environment wins, then .env (surrounding quotes removed), then the default.
# This is the order Docker Compose itself uses.
function Get-Setting([string]$Key, [string]$Default = '') {
    $fromEnv = [Environment]::GetEnvironmentVariable($Key)
    if ($fromEnv) { return $fromEnv }
    foreach ($line in Get-Content -LiteralPath (Join-Path $Root '.env')) {
        if ($line.StartsWith("$Key=")) {
            $value = $line.Substring($Key.Length + 1)
            if ($value.Length -ge 2) {
                $first = $value.Substring(0, 1)
                $last = $value.Substring($value.Length - 1)
                if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
            }
            if ($value) { return $value }
            break
        }
    }
    return $Default
}

function Test-Profile([string]$Name) {
    $profiles = (Get-Setting 'COMPOSE_PROFILES') -replace '\s', ''
    return (@($profiles -split ',') -contains $Name)
}

# Run lnms inside the LibreNMS container (with -DryRun: only print what would run).
function Invoke-Lnms([string[]]$LnmsArgs, [switch]$Capture) {
    if ($DryRun) {
        Write-Host ('lnms ' + ($LnmsArgs -join ' '))
        return [pscustomobject]@{ Code = 0; Output = @() }
    }
    $dockerArgs = @('compose', 'exec', '-T', '--user', 'librenms', 'librenms', 'lnms') + $LnmsArgs
    return Invoke-Docker $dockerArgs -Capture:$Capture
}

function Set-Lnms([string[]]$LnmsArgs) {
    $result = Invoke-Lnms $LnmsArgs
    if ($result.Code -ne 0) { Fail ('lnms ' + ($LnmsArgs -join ' ') + ' failed') }
}

# Add a value to a list setting unless the list already has it. Entries are compared whole, so
# ".../profiles-stat/live/" does not hide ".../profiles-stat". Repeating the command adds nothing.
function Add-ToList([string]$Key, [string]$Value, [switch]$Optional) {
    $current = ''
    if (-not $DryRun) {
        $got = Invoke-Lnms @('config:get', $Key) -Capture
        if ($got.Code -eq 0) { $current = ($got.Output -join "`n") }
    }
    $entries = $current -split '[\[\],"''\s]+'
    if ($entries -contains $Value) {
        Write-Host "  ${Key}: $Value is already there"
        return
    }
    $result = Invoke-Lnms @('config:set', "$Key.+", $Value)
    if ($result.Code -eq 0) {
        Write-Host "  ${Key}: added $Value"
    }
    elseif ($Optional) {
        Write-Host "  warning: this LibreNMS version rejected $Key.+ (the Netflow graphs do not need it)" -ForegroundColor Yellow
    }
    else {
        Fail "could not set $Key"
    }
}

function Invoke-Configure {
    if (-not $DryRun) {
        $running = (Invoke-Docker @('compose', 'ps', '--status', 'running', '--services') -Capture).Output
        if (@($running) -notcontains 'librenms') { Fail 'LibreNMS is not running. Start it first: .\run.ps1 up' }
    }

    $workers = Get-Setting 'DISPATCHER_WORKERS' '8'
    if ($workers -notmatch '^\d+$') { Fail "DISPATCHER_WORKERS must be a number, not '$workers'" }
    Write-Host "Poller workers: $workers"
    Set-Lnms @('config:set', 'service_poller_workers', $workers)

    if (Test-Profile 'mail') {
        Write-Host 'Mail relay (profile mail):'
        Set-Lnms @('config:set', 'email_backend', 'smtp')
        Set-Lnms @('config:set', 'email_smtp_host', 'msmtpd')
        Set-Lnms @('config:set', 'email_smtp_port', '2500')
        Set-Lnms @('config:set', 'email_smtp_auth', 'false')
        $from = Get-Setting 'SMTP_FROM'
        if ($from) { Set-Lnms @('config:set', 'email_from', $from) }
    }
    else {
        Write-Host "Mail relay: profile 'mail' is not enabled, skipped."
    }

    if (Test-Profile 'netflow') {
        Write-Host 'NetFlow (profile netflow):'
        Set-Lnms @('config:set', 'nfsen_enable', 'true')
        Set-Lnms @('config:set', 'nfsen_split_char', '_')
        Add-ToList 'nfsen_rrds' '/netflow/nfsen/profiles-stat/live/'
        Add-ToList 'nfsen_rrds' '/netflow/nfsen/profiles-stat'
        Add-ToList 'nfsen_base' '/netflow/nfsen/' -Optional
    }
    else {
        Write-Host "NetFlow: profile 'netflow' is not enabled, skipped."
    }

    $tgEnabled = Get-Setting 'TELEGRAM_ENABLED' 'false'
    if ($tgEnabled -eq 'true' -or $tgEnabled -eq '1') {
        $tgToken = Get-Setting 'TELEGRAM_BOT_TOKEN'
        $tgChat = Get-Setting 'TELEGRAM_CHAT_ID'
        if ($tgToken -and $tgChat) {
            Write-Host 'Telegram alerting:'
            Set-Lnms @('config:set', 'alerts.telegram.enable', 'true')
            Set-Lnms @('config:set', 'alerts.telegram.token', $tgToken)
            Set-Lnms @('config:set', 'alerts.telegram.chat_id', $tgChat)
            Write-Host "  Telegram alerts configured for chat ID $tgChat"
        } else {
            Write-Warning 'TELEGRAM_ENABLED is true but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty.'
        }
    } else {
        Write-Host "Telegram alerting: disabled in .env (TELEGRAM_ENABLED is not true), skipped."
    }

    Write-Host 'Done. If the worker count changed, restart the dispatcher: .\run.ps1 restart dispatcher'
}

function Invoke-Update {
    $backups = Join-Path $Root 'backups'
    if (-not (Test-Path $backups)) { New-Item -ItemType Directory -Path $backups | Out-Null }
    $note = Join-Path $backups ('update-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    Write-Host "==> Images before the update (also saved to $note)"
    $images = Invoke-Docker @('compose', 'images') -Capture
    $images.Output | Set-Content -LiteralPath $note -Encoding ASCII
    $images.Output | ForEach-Object { Write-Host $_ }

    if ($NoBackup) {
        Write-Host '==> Skipping the backup (-NoBackup)'
    }
    else {
        Write-Host '==> Backing up first'
        $global:LASTEXITCODE = 0
        & (Join-Path (Join-Path $Root 'scripts') 'backup.ps1')
        if ($LASTEXITCODE -ne 0) { Fail 'the backup failed, so nothing was updated' }
    }

    Write-Host '==> Pulling newer images'
    if ((Invoke-Docker @('compose', 'pull', '--ignore-pull-failures')).Code -ne 0) { Fail 'docker compose pull failed' }
    Write-Host '==> Restarting with the new images'
    if ((Invoke-Docker @('compose', 'up', '-d', '--wait')).Code -ne 0) {
        Write-Host 'error: the stack did not become healthy. See: .\run.ps1 logs' -ForegroundColor Red
        Write-Host "To go back: put the previous tags from $note into .env and run .\run.ps1 up;"
        Write-Host 'if the database was upgraded, also restore the backup: .\run.ps1 restore latest'
        exit 1
    }
    Write-Host '==> LibreNMS self-check'
    $check = Invoke-Docker @('compose', 'exec', '-T', '--user', 'librenms', '-w', '/opt/librenms', 'librenms', 'php', 'validate.php')
    if ($check.Code -ne 0) {
        Write-Host 'warning: validate.php reported problems (see above). Nothing was rolled back.' -ForegroundColor Yellow
    }
    Write-Host "==> Done. Previous images are listed in $note"
}

function Write-Check([string]$Level, [string]$Message) {
    switch ($Level) {
        'ok'   { Write-Host "  ok    $Message" }
        'info' { Write-Host "  info  $Message" }
        'warn' { Write-Host "  WARN  $Message" -ForegroundColor Yellow; $script:DoctorWarnings++ }
        'err'  { Write-Host "  ERROR $Message" -ForegroundColor Red; $script:DoctorErrors++ }
    }
}

# Look for the mistakes that otherwise show up later as a container that never starts or a port that is
# never published. Prints ok / info / WARN / ERROR lines; exits 1 if there is any ERROR.
function Invoke-Doctor {
    $script:DoctorErrors = 0
    $script:DoctorWarnings = 0
    $haveDocker = $false
    $onLinux = [bool](Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue)

    Write-Host 'Docker'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Check 'err' 'docker is not installed'
    }
    elseif ((Invoke-Docker @('compose', 'version') -Capture).Code -ne 0) {
        Write-Check 'err' "Docker Compose v2 is not available ('docker compose version' fails)"
    }
    elseif ((Invoke-Docker @('info') -Capture).Code -ne 0) {
        Write-Check 'err' 'the Docker daemon is not running'
    }
    else {
        $haveDocker = $true
        $version = (Invoke-Docker @('compose', 'version') -Capture).Output | Select-Object -First 1
        Write-Check 'ok' "$version"
    }

    Write-Host 'Settings (.env)'
    if (-not (Get-Setting 'MYSQL_PASSWORD')) { Write-Check 'err' 'MYSQL_PASSWORD is empty: run scripts\setup.ps1' }
    else { Write-Check 'ok' 'MYSQL_PASSWORD is set' }
    if (-not (Get-Setting 'LIBRENMS_SNMP_COMMUNITY')) { Write-Check 'err' 'LIBRENMS_SNMP_COMMUNITY is empty: run scripts\setup.ps1' }
    else { Write-Check 'ok' 'LIBRENMS_SNMP_COMMUNITY is set' }
    $onLinuxOrMac = $onLinux -or [bool](Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue)
    if ($onLinuxOrMac -and (Test-Path -LiteralPath (Join-Path $Root '.env'))) {
        $envPath = Join-Path $Root '.env'
        $permCheck = & find $envPath -perm -004 -print 2>$null
        if ($permCheck) {
            if ($Fix) {
                & chmod 600 $envPath 2>$null
                Write-Check 'ok' '.env permissions fixed to 600 (-Fix)'
            }
            else {
                Write-Check 'warn' '.env can be read by every user of this computer and it holds secrets: chmod 600 .env (or run .\scripts\run.ps1 doctor -Fix)'
            }
        }
        else {
            Write-Check 'ok' '.env is private to you'
        }
    }

    Write-Host 'Profiles'
    $profileList = @((((Get-Setting 'COMPOSE_PROFILES') -replace '\s', '') -split ',') | Where-Object { $_ })
    $known = @('syslog', 'traps', 'ntopng', 'mail', 'netflow', 'tools')
    if ($profileList.Count -eq 0) {
        Write-Check 'info' 'no optional profile is enabled (COMPOSE_PROFILES is empty)'
    }
    else {
        Write-Check 'ok' ('enabled: ' + ($profileList -join ','))
        foreach ($p in $profileList) {
            if ($known -cnotcontains $p) {
                Write-Check 'warn' "unknown profile '$p' in COMPOSE_PROFILES (known: syslog, traps, ntopng, mail, netflow, tools)"
            }
        }
    }
    if (Test-Profile 'mail') {
        if (-not (Get-Setting 'SMTP_HOST')) { Write-Check 'err' 'profile mail is on but SMTP_HOST is empty' }
        else { Write-Check 'ok' 'mail relay: SMTP_HOST is set' }
    }
    if (Test-Profile 'ntopng') {
        if (-not $onLinux) {
            Write-Check 'warn' 'profile ntopng needs host networking, which only works on a Linux host (not Docker Desktop)'
        }
        else {
            $iface = Get-Setting 'NTOPNG_INTERFACE' 'eth0'
            if (Test-Path -LiteralPath "/sys/class/net/$iface") { Write-Check 'ok' "ntopng captures on $iface" }
            else { Write-Check 'err' "NTOPNG_INTERFACE '$iface' does not exist on this host (list them with: ip -br link)" }
        }
    }
    if (Test-Profile 'netflow') {
        $first = Get-Setting 'NFSEN_FLOW_PORT_FIRST' '2055'
        $last = Get-Setting 'NFSEN_FLOW_PORT_LAST' '2064'
        $rangeOk = $false
        if (($first -notmatch '^\d+$') -or ($last -notmatch '^\d+$')) {
            Write-Check 'err' 'NFSEN_FLOW_PORT_FIRST and NFSEN_FLOW_PORT_LAST must be port numbers'
        }
        elseif ([int]$first -gt [int]$last) {
            Write-Check 'err' "NFSEN_FLOW_PORT_FIRST ($first) is above NFSEN_FLOW_PORT_LAST ($last)"
        }
        else {
            $rangeOk = $true
        }
        $sources = Get-Setting 'NFSEN_SOURCES'
        if (-not $sources) {
            Write-Check 'err' 'profile netflow is on but NFSEN_SOURCES is empty'
        }
        else {
            $seenNames = @()
            $seenPorts = @()
            $count = 0
            $bad = $false
            foreach ($src in ($sources -split ':')) {
                if (-not $src) { continue }
                $count++
                $parts = @($src -split ',')
                if ($parts.Count -lt 4) {
                    Write-Check 'err' "NFSEN_SOURCES entry '$src' must be written name,port,colour,type"
                    $bad = $true
                    continue
                }
                $name = $parts[0]
                $port = $parts[1]
                $type = $parts[3]
                if ($name -notmatch '^[A-Za-z0-9_]+$') {
                    Write-Check 'err' "source name '$name' may only contain letters, digits and underscores"
                    $bad = $true
                }
                if ($name.Length -gt 19) { Write-Check 'err' "source name '$name' is longer than 19 characters"; $bad = $true }
                if ($seenNames -ccontains $name) { Write-Check 'err' "source name '$name' is used twice"; $bad = $true }
                $seenNames += $name
                if ($port -notmatch '^\d+$') {
                    Write-Check 'err' "source '$name': port '$port' is not a number"
                    $bad = $true
                }
                elseif ([int]$port -ne 0) {
                    if ($rangeOk -and (([int]$port -lt [int]$first) -or ([int]$port -gt [int]$last))) {
                        Write-Check 'err' "source '$name': port $port is outside the published range $first-$last, so Docker never publishes it"
                        $bad = $true
                    }
                    if ($seenPorts -contains $port) {
                        Write-Check 'err' "port $port is used by two sources: NfSen needs one port per device"
                        $bad = $true
                    }
                    $seenPorts += $port
                }
                if (@('netflow', 'sflow') -cnotcontains $type) {
                    Write-Check 'warn' "source '$name': type '$type' is not netflow or sflow"
                }
            }
            if (-not $bad) { Write-Check 'ok' "NFSEN_SOURCES: $count source(s), names and ports are valid" }
        }
    }

    Write-Host 'Exposure'
    $binds = @('LIBRENMS_BIND')
    if (Test-Profile 'netflow') { $binds += 'NFSEN_BIND' }
    if (Test-Profile 'ntopng') { $binds += 'NTOPNG_BIND' }
    foreach ($var in $binds) {
        if ((Get-Setting $var) -eq '0.0.0.0') {
            Write-Check 'warn' "$var=0.0.0.0 serves every network without TLS (see README, HTTPS)"
        }
    }
    if ((Test-Profile 'syslog') -or (Test-Profile 'traps') -or (Test-Profile 'netflow')) {
        Write-Check 'info' 'syslog, trap and flow ports are open to every sender: restrict them (see README, Firewall)'
    }
    $latest = @()
    if ((Get-Setting 'LIBRENMS_VERSION' 'latest') -eq 'latest') { $latest += 'librenms' }
    if ((Test-Profile 'mail') -and ((Get-Setting 'MSMTPD_VERSION' 'latest') -eq 'latest')) { $latest += 'msmtpd' }
    if ((Test-Profile 'netflow') -and ((Get-Setting 'NFSEN_VERSION' 'latest') -eq 'latest')) { $latest += 'nfsen' }
    if ($latest.Count -gt 0) {
        Write-Check 'info' ('images that follow upstream (tag latest): ' + ($latest -join ' ') + '; pin them once things work (README, Updating)')
    }

    if ($haveDocker) {
        Write-Host 'Memory'
        $mem = (Invoke-Docker @('info', '--format', '{{.MemTotal}}') -Capture).Output | Select-Object -First 1
        if ("$mem" -notmatch '^\d+$') {
            Write-Check 'info' 'could not read how much memory Docker has'
        }
        else {
            $memMb = [int][math]::Floor([long]$mem / 1MB)
            if ($memMb -lt 3800) { Write-Check 'warn' "Docker has $memMb MB of memory; about 4 GB is recommended" }
            else { Write-Check 'ok' "Docker has $memMb MB of memory" }
            $pool = Get-Setting 'MARIADB_BUFFER_POOL_SIZE' '512M'
            if ($pool -match '^(\d+)([GgMm])$') {
                $poolMb = [int]$Matches[1]
                if ($Matches[2] -match '[Gg]') { $poolMb = $poolMb * 1024 }
                if (($poolMb * 2) -gt $memMb) { Write-Check 'warn' "MARIADB_BUFFER_POOL_SIZE=$pool is more than half of the $memMb MB Docker has" }
                else { Write-Check 'ok' "MARIADB_BUFFER_POOL_SIZE=$pool fits in memory" }
            }
            else {
                Write-Check 'warn' "MARIADB_BUFFER_POOL_SIZE '$pool' should look like 512M or 2G"
            }
        }

        Write-Host 'Stack'
        $cfg = Invoke-Docker @('compose', 'config', '--services') -Capture
        if ($cfg.Code -eq 0) {
            Write-Check 'ok' 'docker compose accepts the configuration'
            $running = @((Invoke-Docker @('compose', 'ps', '--status', 'running', '--services') -Capture).Output)
            $missing = @($cfg.Output | Where-Object { $_ -and ($_ -ne 'tools') -and ($running -notcontains $_) })
            if ($running.Count -eq 0) { Write-Check 'info' 'the stack is not running (start it with .\run.ps1 up)' }
            elseif ($missing.Count -gt 0) { Write-Check 'warn' ('not running: ' + ($missing -join ' ')) }
            else { Write-Check 'ok' 'all services are running' }
        }
        else {
            Write-Check 'err' 'docker compose rejects the configuration (run: docker compose config)'
        }
    }

    Write-Host ''
    Write-Host "$($script:DoctorErrors) error(s), $($script:DoctorWarnings) warning(s)"
    if ($script:DoctorErrors -gt 0) { exit 1 }
}

if (@('help', '--help', '-h', '/?') -contains $Command) { Show-Usage; exit 0 }
if (@('up', 'down', 'restart', 'logs', 'status', 'backup', 'restore', 'validate', 'configure', 'update', 'doctor', 'add-device', 'scan') -notcontains $Command) {
    Write-Host "error: unknown command: $Command" -ForegroundColor Red
    Show-Usage
    exit 2
}

if (-not (Test-Path (Join-Path $Root '.env'))) { Fail 'no .env found. Run scripts\setup.ps1 first.' }
# doctor reports Docker problems itself instead of stopping at the first one.
$needsDocker = -not (($Command -eq 'doctor') -or ($Command -eq 'configure' -and $DryRun))
if ($needsDocker -and -not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail 'Docker is not installed.' }

Push-Location $Root
try {
    if ($needsDocker -and (Invoke-Docker @('info') -Capture).Code -ne 0) { Fail 'The Docker daemon is not running. Start Docker Desktop.' }

    $code = 0
    switch ($Command) {
        'up'      { $code = (Invoke-Docker @('compose', 'up', '-d')).Code }
        'down' {
            if ($Name -or $ExtraArgs.Count -gt 0) { Fail 'down takes no options: it never deletes the data volumes (run ''docker compose down -v'' yourself if you really want that)' }
            $code = (Invoke-Docker @('compose', 'down')).Code
        }
        'status'  { $code = (Invoke-Docker @('compose', 'ps')).Code }
        'restart' {
            $dockerArgs = @('compose', 'restart')
            if ($Name) { $dockerArgs += $Name }
            $code = (Invoke-Docker $dockerArgs).Code
        }
        'logs' {
            $dockerArgs = @('compose', 'logs', '-f', '--tail=100')
            if ($Name) { $dockerArgs += $Name }
            $code = (Invoke-Docker $dockerArgs).Code
        }
        'backup' {
            & (Join-Path (Join-Path $Root 'scripts') 'backup.ps1') -Keep $Keep
            $code = $LASTEXITCODE
        }
        'restore' {
            if (-not $Name) { Fail "restore needs a target: 'latest', a backup name or a file path (see .\run.ps1 help)" }
            & (Join-Path (Join-Path $Root 'scripts') 'restore.ps1') -Backup $Name -Yes:$Yes
            $code = $LASTEXITCODE
        }
        'configure' { Invoke-Configure }
        'update'    { Invoke-Update }
        'doctor'    { Invoke-Doctor }
        'validate' {
            $code = (Invoke-Docker @('compose', 'exec', '-T', '--user', 'librenms', '-w', '/opt/librenms', 'librenms', 'php', 'validate.php')).Code
        }
        'add-device' {
            if (-not $Name) { Fail 'usage: .\scripts\run.ps1 add-device <hostname-or-ip> [options]' }
            $argsList = @('compose', 'exec', '-T', '--user', 'librenms', '-w', '/opt/librenms', 'librenms', 'php', 'addhost.php', $Name)
            if ($ExtraArgs) { $argsList += $ExtraArgs }
            $code = (Invoke-Docker $argsList).Code
        }
        'scan' {
            if (-not $Name) { Fail 'usage: .\scripts\run.ps1 scan <subnet> [options] (e.g. .\scripts\run.ps1 scan 192.168.1.0/24)' }
            $argsList = @('compose', 'exec', '-T', '--user', 'librenms', '-w', '/opt/librenms', 'librenms', 'python3', 'snmp-scan.py', $Name)
            if ($ExtraArgs) { $argsList += $ExtraArgs }
            $code = (Invoke-Docker $argsList).Code
        }
    }
    exit $code
}
finally { Pop-Location }
