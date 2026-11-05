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
  .\scripts\run.ps1 configure [-DryRun]     # apply the settings in .env to LibreNMS (workers, retention, admin, mail, NetFlow); safe to repeat
  .\scripts\run.ps1 add-device <host> [opts] # add a device (e.g. .\scripts\run.ps1 add-device 192.168.1.1 -v 2c -c public)
  .\scripts\run.ps1 scan <subnet> [options]  # auto-discover devices on subnet (e.g. .\scripts\run.ps1 scan 192.168.1.0/24)
  .\scripts\run.ps1 lnms [args...]          # run LibreNMS CLI commands (e.g. .\scripts\run.ps1 lnms user:add <user> -r admin)
  .\scripts\run.ps1 user-add <user> [-p <password>] [-r <role>] [-e <email>]   # create a user; without -p a password is generated
  .\scripts\run.ps1 oxidized-setup [user] [--force]   # pair Oxidized with LibreNMS: API token into .env, integration on
  .\scripts\run.ps1 poll-device <host>     # poll one device now with full debug output
  .\scripts\run.ps1 snmp-walk <host> [oid]  # walk a device's SNMP tree from the LibreNMS container
  .\scripts\run.ps1 ping-device <host>     # check a device with LibreNMS' own ping check
  .\scripts\run.ps1 sync-inventory         # write the LibreNMS devices as the netops inventory.csv (needs bash)
  .\scripts\run.ps1 update [-NoBackup]      # back up, pull newer images, restart, self-check
  .\scripts\run.ps1 doctor [-Fix] [-Notify|-NotifyAll|-NotifyTest]  # check the setup (Docker, .env, memory, disk, poller, SNMP, clock, ports); -Fix repairs permissions; -Notify sends problems to Telegram

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
$Notify = $false
$NotifyAll = $false
$NotifyTest = $false
$Verify = $false
$NoOffsite = $false
$NoRollback = $false
$ExtraArgs = @()

$rawArgs = @($args)
if ($rawArgs.Count -gt 0 -and $rawArgs[0] -notmatch '^-') {
    $Command = $rawArgs[0]
    $rawArgs = @($rawArgs | Select-Object -Skip 1)
    # These commands hand every argument on untouched and in order: switches like -y, -Fix or -DryRun are
    # meant for the tool behind them, not for this launcher.
    if (@('lnms', 'add-device', 'user-add', 'oxidized-setup', 'poll-device', 'snmp-walk', 'ping-device', 'sync-inventory', 'verify-backup') -contains $Command) {
        $ExtraArgs = @($rawArgs)
        $rawArgs = @()
    }
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
        '^(-Notify|--notify)$' { $Notify = $true }
        '^(-NotifyAll|--notify-all)$' { $NotifyAll = $true }
        '^(-NotifyTest|--notify-test)$' { $NotifyTest = $true }
        '^(-Verify|--verify)$' { $Verify = $true }
        '^(-NoOffsite|--no-offsite)$' { $NoOffsite = $true }
        '^(-NoRollback|--no-rollback)$' { $NoRollback = $true }
        default {
            if (-not $Name -and $Command -in @('restart', 'logs', 'restore', 'add-device', 'scan', 'lnms') -and $arg -notmatch '^-') {
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
        '  .\scripts\run.ps1 configure [-DryRun]     apply the settings in .env to LibreNMS (workers, retention, admin, mail, NetFlow); safe to repeat'
        '  .\scripts\run.ps1 add-device <host> [opts] add a device (e.g. .\scripts\run.ps1 add-device 192.168.1.1 -v 2c -c public)'
        '  .\scripts\run.ps1 scan <subnet> [options]  auto-discover subnet devices via SNMP (e.g. .\scripts\run.ps1 scan 192.168.1.0/24)'
        '  .\scripts\run.ps1 update [-NoBackup]      back up, pull newer images, restart, self-check'
        '  .\scripts\run.ps1 doctor [-Fix] [-Notify]  check setup (Docker, .env, memory, disk, poller, SNMP, clock, ports); -Notify tells Telegram what changed (-NotifyAll: everything, -NotifyTest: a test message)'
        '  .\scripts\run.ps1 lnms [args...]          run LibreNMS CLI commands (e.g. .\scripts\run.ps1 lnms user:add <user> -r admin)'
        '  .\scripts\run.ps1 user-add <user> [-p <password>] [-r <role>] [-e <email>]  create a user (default role admin); without -p a password is generated'
        '  .\scripts\run.ps1 oxidized-setup [user] [--force]  pair Oxidized with LibreNMS: API token into .env, integration on'
        '  .\scripts\run.ps1 poll-device <host>     poll one device now with full debug output'
        '  .\scripts\run.ps1 snmp-walk <host> [oid]  walk a device''s SNMP tree from the LibreNMS container'
        '  .\scripts\run.ps1 ping-device <host>     check a device with LibreNMS'' own ping check'
        '  .\scripts\run.ps1 sync-inventory         write the LibreNMS devices as the netops inventory.csv (needs bash)'
    ) | ForEach-Object { Write-Host $_ }
}

# Run docker with a relaxed error preference (Windows PowerShell 5.1 treats stderr output as an error under 'Stop').
# Returns the exit code; with -Capture also returns stdout lines (-Merge: stdout and stderr).
function Invoke-Docker([string[]]$DockerArgs, [switch]$Capture, [switch]$Merge, [string]$StdIn) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Merge) {
            # stdout and stderr together, as text: for commands whose error message the caller wants to show
            if ($PSBoundParameters.ContainsKey('StdIn')) {
                $lines = @($StdIn | & docker @DockerArgs 2>&1 | ForEach-Object { "$_" })
            }
            else {
                $lines = @(& docker @DockerArgs 2>&1 | ForEach-Object { "$_" })
            }
            return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $lines }
        }
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
function Invoke-Lnms([string[]]$LnmsArgs, [switch]$Capture, [switch]$Merge) {
    if ($DryRun) {
        Write-Host ('lnms ' + ($LnmsArgs -join ' '))
        return [pscustomobject]@{ Code = 0; Output = @() }
    }
    $dockerArgs = @('compose', 'exec', '-T', 'librenms', 'su', '-s', '/bin/sh', 'librenms', '-c', 'php /opt/librenms/lnms "$@"', '--', 'lnms') + $LnmsArgs
    return Invoke-Docker $dockerArgs -Capture:$Capture -Merge:$Merge
}

# Run a command from /opt/librenms (validate.php, addhost.php, snmp-scan.py) as the librenms user, through the same
# "su -s /bin/sh" as Invoke-Lnms: the exec option that picks the user fails on Docker Desktop, where the host GIDs
# differ from the container's. $Tag only names the shell ($0); the arguments are passed on untouched.
# No double quotes inside the commands that doctor sends: Windows PowerShell 5.1 drops them on the way to docker.exe,
# so those scripts use "IFS=" instead of quoting to keep a value in one piece.
function Invoke-LibrenmsExec([string]$Tag, [string]$Cmd, [string[]]$ExecArgs = @()) {
    $dockerArgs = @('compose', 'exec', '-T', 'librenms', 'su', '-s', '/bin/sh', 'librenms', '-c', ('cd /opt/librenms && ' + $Cmd + ' "$@"'), '--', $Tag) + $ExecArgs
    return Invoke-Docker $dockerArgs
}

# lnms user:add with the password handed over on stdin: the container reads it itself, so it never shows up in the
# command line of a process on the host.
function Invoke-LnmsUserAdd([string]$Password, [string[]]$UserArgs) {
    $dockerArgs = @('compose', 'exec', '-T', 'librenms', 'su', '-s', '/bin/sh', 'librenms', '-c', 'IFS= read -r pw; exec php /opt/librenms/lnms user:add "$@" -p "$pw"', '--', 'lnms') + $UserArgs
    return Invoke-Docker $dockerArgs -Merge -StdIn $Password
}

function Get-FirstLine([object[]]$Lines) {
    return (@($Lines | Where-Object { "$_".Trim() } | Select-Object -First 1) -join '')
}

function Test-UserExistsMessage([string]$Text) {
    return ($Text -match '(?i)taken|already|exists|unique')
}

# A random password of 24 characters from A-Z a-z 0-9 and !#%*+=, with at least one of each kind.
function New-Password {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#%*+='
    $limit = 256 - (256 % $chars.Length)   # bytes at or above this are skipped, so every character is equally likely
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        while ($true) {
            $pw = ''
            $buf = New-Object byte[] 64
            while ($pw.Length -lt 24) {
                $rng.GetBytes($buf)
                foreach ($b in $buf) {
                    if ($b -lt $limit -and $pw.Length -lt 24) { $pw += $chars[$b % $chars.Length] }
                }
            }
            if (($pw -cmatch '[A-Z]') -and ($pw -cmatch '[a-z]') -and ($pw -cmatch '[0-9]') -and ($pw -cmatch '[!#%*+=]')) { return $pw }
        }
    }
    finally { $rng.Dispose() }
}

# Set KEY=value in .env: replace the first KEY= line, or add one. Written as UTF-8 without a BOM, with LF line ends.
function Set-EnvValue([string]$Key, [string]$Value) {
    $path = Join-Path $Root '.env'
    $lines = @(Get-Content -LiteralPath $path)
    $done = $false
    for ($n = 0; $n -lt $lines.Count; $n++) {
        if (-not $done -and $lines[$n].StartsWith("$Key=")) { $lines[$n] = "$Key=$Value"; $done = $true }
    }
    if (-not $done) { $lines += "$Key=$Value" }
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# add-device. addhost.php was deprecated and is gone from LibreNMS 25.12 and later, so it is used only while the
# image still has it; otherwise the same arguments go to "lnms device:add" ("-v 2c" becomes "--v2c").
function Test-Addhost { return ((Invoke-Docker @('compose', 'exec', '-T', 'librenms', 'test', '-f', '/opt/librenms/addhost.php') -Capture).Code -eq 0) }

function Add-OneDevice([bool]$Legacy, [string]$HostName, [string]$Ver, [string]$Comm) {
    if ($Legacy) { return (Invoke-LibrenmsExec 'add-device' 'php addhost.php' @($HostName, $Comm, "v$Ver")).Code }
    return (Invoke-Lnms @('device:add', $HostName, "--v$Ver", '-c', $Comm)).Code
}

# add-device --csv <file>: one device per line, "hostname[,snmp version[,community]]". Version defaults to 2c, the
# community to LIBRENMS_SNMP_COMMUNITY. Blank lines, lines starting with # and a "hostname" header are skipped.
function Invoke-AddDevicesCsv([bool]$Legacy, [string]$File) {
    if (-not $File) { Fail 'usage: .\scripts\run.ps1 add-device --csv <file>   (lines: hostname[,version[,community]])' }
    if (-not (Test-Path -LiteralPath $File)) { Fail "file not found: $File" }
    $added = 0; $failed = 0; $first = $true
    foreach ($line in @(Get-Content -LiteralPath $File)) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        $cols = @($line -split ',')
        $hostName = $cols[0].Trim()
        $ver = ''; if ($cols.Count -ge 2) { $ver = $cols[1].Trim() }
        $comm = ''; if ($cols.Count -ge 3) { $comm = $cols[2].Trim() }
        if ($first) { $first = $false; if ($hostName -match '^(?i)host(name)?$') { continue } }
        if (-not $hostName) { continue }
        if ($ver.StartsWith('v')) { $ver = $ver.Substring(1) }
        if (-not $ver) { $ver = '2c' }
        if (-not $comm) { $comm = Get-Setting 'LIBRENMS_SNMP_COMMUNITY' }
        if ($ver -eq '3') { Write-Warning "skipped ${hostName}: SNMPv3 needs credentials, add it with .\scripts\run.ps1 add-device $hostName --v3 -u <user> ..."; $failed++; continue }
        if (@('1', '2c') -notcontains $ver) { Write-Warning "skipped ${hostName}: unknown SNMP version '$ver' (use 1 or 2c)"; $failed++; continue }
        if (-not $comm) { Write-Warning "skipped ${hostName}: no community in the file and LIBRENMS_SNMP_COMMUNITY is empty"; $failed++; continue }
        Write-Host "Adding $hostName (SNMP $ver)"
        if ((Add-OneDevice $Legacy $hostName $ver $comm) -eq 0) { $added++ } else { Write-Warning "failed: $hostName"; $failed++ }
    }
    Write-Host "Done: $added added, $failed failed or skipped."
    if ($failed -gt 0) { return 1 }
    return 0
}

function Invoke-AddDevice([string[]]$DevArgs) {
    $legacy = Test-Addhost
    if ($DevArgs.Count -ge 1 -and $DevArgs[0] -eq '--csv') {
        $csvFile = ''; if ($DevArgs.Count -ge 2) { $csvFile = $DevArgs[1] }
        return (Invoke-AddDevicesCsv $legacy $csvFile)
    }
    if ($DevArgs.Count -lt 1) { Fail 'usage: .\scripts\run.ps1 add-device <hostname-or-ip> [options]   or   add-device --csv <file>' }
    if ($legacy) { return (Invoke-LibrenmsExec 'add-device' 'php addhost.php' $DevArgs).Code }
    $out = @()
    $n = 0
    while ($n -lt $DevArgs.Count) {
        if ($DevArgs[$n] -eq '-v') {
            if ($n + 1 -ge $DevArgs.Count) { Fail 'add-device: -v needs a version (1, 2c or 3)' }
            $n++
            $ver = $DevArgs[$n]
            if ($ver.StartsWith('v')) { $ver = $ver.Substring(1) }
            $out += "--v$ver"
        }
        else { $out += $DevArgs[$n] }
        $n++
    }
    return (Invoke-Lnms (@('device:add') + $out)).Code
}

function Invoke-UserAdd([string[]]$UserArgs) {
    $user = ''; $password = ''; $role = 'admin'; $email = ''; $fromStdin = $false
    $n = 0
    while ($n -lt $UserArgs.Count) {
        $a = $UserArgs[$n]
        if (@('-p', '--password', '-r', '--role', '-e', '--email') -contains $a) {
            if ($n + 1 -ge $UserArgs.Count) { Write-Host "error: user-add: $a needs a value" -ForegroundColor Red; exit 2 }
            $n++
            if (@('-p', '--password') -contains $a) { $password = $UserArgs[$n] }
            elseif (@('-r', '--role') -contains $a) { $role = $UserArgs[$n] }
            else { $email = $UserArgs[$n] }
        }
        elseif ($a -eq '--password-stdin') { $fromStdin = $true }
        elseif ($a -match '^-') { Write-Host "error: user-add: unknown option: $a" -ForegroundColor Red; exit 2 }
        elseif ($user) { Write-Host "error: user-add: only one username, got '$user' and '$a'" -ForegroundColor Red; exit 2 }
        else { $user = $a }
        $n++
    }
    if (-not $user) { Fail 'usage: .\scripts\run.ps1 user-add <username> [-p <password>] [-r admin|global-read|user] [-e <email>]' }
    if (@('admin', 'global-read', 'user') -cnotcontains $role) { Fail "user-add: the role must be admin, global-read or user, not '$role'" }
    if ($fromStdin) {
        if ($password) { Write-Host 'error: user-add: use either -p or --password-stdin' -ForegroundColor Red; exit 2 }
        $password = [Console]::In.ReadLine()
        if (-not $password) { Fail 'user-add: --password-stdin read an empty password' }
    }
    $generated = $false
    if (-not $password) { $password = New-Password; $generated = $true }
    $lnmsArgs = @($user, '-r', $role)
    if ($email) { $lnmsArgs += @('-e', $email) }
    $result = Invoke-LnmsUserAdd $password $lnmsArgs
    if ($result.Code -ne 0) {
        if (Test-UserExistsMessage ($result.Output -join "`n")) { Fail "user '$user' already exists (or the name is taken)" }
        Fail "could not create user '$user': $(Get-FirstLine $result.Output)"
    }
    Write-Host "User '$user' created (role: $role)."
    if ($generated) {
        Write-Host "Generated secure password for ${user}: $password"
        Write-Host 'Save it now: it is not stored anywhere.'
    }
}

# Create an API token for Oxidized, keep it in .env and switch the LibreNMS side on.
function Invoke-OxidizedSetup([string[]]$SetupArgs) {
    $user = ''; $force = $false
    foreach ($a in $SetupArgs) {
        if ($a -eq '--force' -or $a -eq '-Force') { $force = $true }
        elseif ($a -match '^-') { Write-Host "error: oxidized-setup: unknown option: $a" -ForegroundColor Red; exit 2 }
        else { $user = $a }
    }
    if (-not (Test-Profile 'oxidized')) { Fail "profile 'oxidized' is not enabled. Add it to COMPOSE_PROFILES in .env first, then run .\scripts\run.ps1 up and .\scripts\run.ps1 oxidized-setup" }
    if (-not $user) { $user = Get-Setting 'LIBRENMS_ADMIN_USER' 'librenms' }
    if ((Get-Setting 'OXIDIZED_LIBRENMS_TOKEN') -and -not $force) {
        Write-Host 'OXIDIZED_LIBRENMS_TOKEN is already set in .env (--force creates a new token).'
    }
    else {
        Write-Host "Creating the API token 'oxidized' for LibreNMS user '$user'"
        $result = Invoke-Lnms @('api:token-create', '--name=oxidized', $user) -Capture -Merge
        if ($result.Code -ne 0) {
            Fail "could not create the API token for '$user': $(Get-FirstLine $result.Output) (name an existing LibreNMS user: .\scripts\run.ps1 oxidized-setup <username>)"
        }
        $found = @([regex]::Matches(($result.Output -join "`n"), '\d+\|[A-Za-z0-9]{32,}') | ForEach-Object { $_.Value })
        if ($found.Count -eq 0) { $found = @($result.Output | Where-Object { $_ -match '^[A-Za-z0-9]{32,}$' }) }
        if ($found.Count -eq 0) { Fail 'no token found in the output of api:token-create' }
        Set-EnvValue 'OXIDIZED_LIBRENMS_TOKEN' $found[-1]
        Write-Host '  Saved OXIDIZED_LIBRENMS_TOKEN in .env'
    }
    Set-Lnms @('config:set', 'oxidized.enabled', 'true')
    Set-Lnms @('config:set', 'oxidized.url', 'http://oxidized:8888')
    Write-Host 'Done. Restart Oxidized so that it reads the token: .\scripts\run.ps1 restart oxidized'
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

    $syslogDays = Get-Setting 'SYSLOG_PURGE_DAYS' '30'
    $eventlogDays = Get-Setting 'EVENTLOG_PURGE_DAYS' '90'
    if ($syslogDays -notmatch '^\d+$') { Fail "SYSLOG_PURGE_DAYS must be a number of days, not '$syslogDays'" }
    if ($eventlogDays -notmatch '^\d+$') { Fail "EVENTLOG_PURGE_DAYS must be a number of days, not '$eventlogDays'" }
    Write-Host "Data retention: syslog $syslogDays days, event log $eventlogDays days"
    Set-Lnms @('config:set', 'syslog_purge', $syslogDays)
    Set-Lnms @('config:set', 'eventlog_purge', $eventlogDays)
    # Optional extras: nothing is changed in LibreNMS while the variable is empty.
    foreach ($pair in @(@('AUTHLOG_PURGE_DAYS', 'authlog_purge'), @('ALERTLOG_PURGE_DAYS', 'alert_log_purge'), @('RRD_PURGE_DAYS', 'rrd_purge'))) {
        $extraDays = Get-Setting $pair[0]
        if (-not $extraDays) { continue }
        if ($extraDays -notmatch '^\d+$') { Fail "$($pair[0]) must be a number of days, not '$extraDays'" }
        Write-Host "  $($pair[1]): $extraDays days"
        Set-Lnms @('config:set', $pair[1], $extraDays)
    }

    $adminUser = Get-Setting 'LIBRENMS_ADMIN_USER'
    $adminPw = Get-Setting 'LIBRENMS_ADMIN_PASSWORD'
    if ($adminUser -and $adminPw) {
        Write-Host 'Initial admin account:'
        if ($DryRun) {
            Write-Host "lnms user:add $adminUser -p ******** -r admin"
        }
        else {
            $added = Invoke-LnmsUserAdd $adminPw @($adminUser, '-r', 'admin')
            if ($added.Code -eq 0 -or (Test-UserExistsMessage ($added.Output -join "`n"))) {
                Write-Host "  Admin account '$adminUser' is ready."
            }
            else {
                Write-Warning "could not create the admin account '$adminUser': $(Get-FirstLine $added.Output)"
            }
        }
    }
    elseif ($adminUser -or $adminPw) {
        Write-Warning 'LIBRENMS_ADMIN_USER and LIBRENMS_ADMIN_PASSWORD must both be set, admin account skipped.'
    }
    else {
        Write-Host 'Initial admin account: LIBRENMS_ADMIN_USER is not set, skipped.'
    }

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

# verify-backup [latest|name]: restore a backup set into a throw-away database to prove that it works. Nothing
# running is touched.
function Invoke-VerifyBackup([string[]]$VbArgs) {
    $target = 'latest'
    if ($VbArgs.Count -ge 1) { $target = $VbArgs[0] }
    $target = Split-Path -Leaf $target
    $target = $target -replace '-db\.sql\.gz$', '' -replace '-data\.tgz$', ''
    if ($target -eq 'latest') {
        $newest = Get-ChildItem -LiteralPath (Join-Path $Root 'backups') -Filter 'librenms-*-db.sql.gz' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if (-not $newest) { Fail 'no backups found in .\backups' }
        $target = $newest.Name -replace '-db\.sql\.gz$', ''
    }
    if (-not $target.StartsWith('librenms-')) { $target = "librenms-$target" }
    foreach ($suffix in @('-db.sql.gz', '-data.tgz')) {
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $Root 'backups') "$target$suffix"))) { Fail "backups\$target-db.sql.gz and backups\$target-data.tgz must both exist" }
    }
    return (Invoke-Docker @('compose', 'run', '--rm', '--no-deps', '-e', "BACKUP_NAME=$target", 'tools', '/scripts/verify.sh')).Code
}

function Invoke-Update {
    $backups = Join-Path $Root 'backups'
    if (-not (Test-Path $backups)) { New-Item -ItemType Directory -Path $backups | Out-Null }
    $note = Join-Path $backups ('update-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    Write-Host "==> Images before the update (also saved to $note)"
    $images = Invoke-Docker @('compose', 'images') -Capture
    $images.Output | Set-Content -LiteralPath $note -Encoding ASCII
    $images.Output | ForEach-Object { Write-Host $_ }
    # repository, tag and image id of every container, for going back: "latest" is overwritten by the pull, but the
    # old image is still on this computer under its id until it is pruned.
    $snapshot = @()
    foreach ($row in @($images.Output | Select-Object -Skip 1)) {
        $f = @("$row".Trim() -split '\s+')
        if ($f.Count -ge 4 -and $f[1] -ne '<none>' -and $f[2] -ne '<none>') { $snapshot += "$($f[1]) $($f[2]) $($f[3])" }
    }
    $snapshot = @($snapshot | Sort-Object -Unique)

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
        if (-not $NoRollback -and $snapshot.Count -gt 0) {
            Write-Host '==> Going back to the previous images'
            foreach ($entry in $snapshot) {
                $e = $entry -split ' '
                if ((Invoke-Docker @('tag', $e[2], "$($e[0]):$($e[1])") -Capture).Code -ne 0) { Write-Warning "could not restore $($e[0]):$($e[1]) (image $($e[2]) is gone)" }
            }
            if ((Invoke-Docker @('compose', 'up', '-d', '--wait')).Code -eq 0) {
                Write-Host 'The previous version is running again; the update did not take effect. Try again later with .\run.ps1 update,'
                Write-Host 'or pin LIBRENMS_VERSION in .env to a version that works.'
            }
            else {
                Write-Host 'The previous images did not start either (the database may have been upgraded).'
                Write-Host "Restore the backup: .\run.ps1 restore latest. The old image list is in $note"
            }
        }
        else {
            Write-Host "To go back: put the previous tags from $note into .env and run .\run.ps1 up;"
            Write-Host 'if the database was upgraded, also restore the backup: .\run.ps1 restore latest'
        }
        exit 1
    }
    Write-Host '==> LibreNMS self-check'
    $check = Invoke-LibrenmsExec 'validate' 'php validate.php'
    if ($check.Code -ne 0) {
        Write-Host 'warning: validate.php reported problems (see above). Nothing was rolled back.' -ForegroundColor Yellow
    }
    Write-Host "==> Done. Previous images are listed in $note"
}

function Write-Check([string]$Level, [string]$Message) {
    switch ($Level) {
        'ok'   { Write-Host "  ok    $Message" }
        'info' { Write-Host "  info  $Message" }
        'warn' { Write-Host "  WARN  $Message" -ForegroundColor Yellow; $script:DoctorWarnings++; $script:DoctorReport += "- WARN $Message`n" }
        'err'  { Write-Host "  ERROR $Message" -ForegroundColor Red; $script:DoctorErrors++; $script:DoctorReport += "- ERROR $Message`n" }
    }
}

function Get-HostLabel { if ($env:COMPUTERNAME) { return $env:COMPUTERNAME } return [System.Net.Dns]::GetHostName() }

# The address people open LibreNMS at, for links in messages: NOTIFY_BASE_URL, else the proxy name, else this host
# and LIBRENMS_PORT.
function Get-BaseUrlLine {
    $url = Get-Setting 'NOTIFY_BASE_URL'
    if (-not $url -and (Test-Profile 'proxy')) {
        $proxyHost = Get-Setting 'CADDY_LIBRENMS_HOST'
        if ($proxyHost -and $proxyHost -notmatch '^http://' -and $proxyHost -notmatch '\.localhost$') { $url = "https://$proxyHost" }
    }
    if (-not $url) { $url = "http://$(Get-HostLabel):$(Get-Setting 'LIBRENMS_PORT' '8000')" }
    return "LibreNMS: $($url.TrimEnd('/'))"
}

# Send a text with the Telegram bot of .env (the token is in the URL of an in-process request, on no command line).
# Returns $true when it was sent.
function Send-Telegram([string]$Text) {
    $token = Get-Setting 'TELEGRAM_BOT_TOKEN'
    $chat = Get-Setting 'TELEGRAM_CHAT_ID'
    if (-not $token -or -not $chat) { Write-Warning '-Notify needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env'; return $false }
    if ($Text.Length -gt 3800) { $Text = $Text.Substring(0, 3800) }   # Telegram refuses messages over 4096 characters
    foreach ($attempt in 1..3) {
        try {
            [void](Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$token/sendMessage" -Body @{ chat_id = $chat; text = $Text } -TimeoutSec 20)
            Write-Host 'Telegram: the report was sent.'
            return $true
        }
        catch { if ($attempt -lt 3) { Start-Sleep -Seconds 2 } }
    }
    Write-Warning 'the Telegram message could not be sent'
    return $false
}

# Tell Telegram what CHANGED since the last report: new problems, problems that are gone, and how many are still open.
# The last report is kept in backups\.doctor-notify-state (one line per problem: the text without digits, a tab, the
# text), so a number that moves (91 % full, then 92 %) is not a new problem. The state is updated only after a
# successful send (or when nothing needed sending), so a failed send is retried. -All sends everything.
function Send-DoctorChanges([string[]]$Lines, [int]$Errors, [int]$Warnings, [bool]$All) {
    $red = [char]::ConvertFromUtf32(0x1F534); $yellow = [char]::ConvertFromUtf32(0x1F7E1); $green = [char]::ConvertFromUtf32(0x2705)
    $backups = Join-Path $Root 'backups'
    if (-not (Test-Path $backups)) { New-Item -ItemType Directory -Path $backups | Out-Null }
    $state = Join-Path $backups '.doctor-notify-state'
    $prev = @()
    if (Test-Path -LiteralPath $state) { $prev = @(Get-Content -LiteralPath $state) }
    $prevKeys = @($prev | ForEach-Object { ($_ -split "`t", 2)[0] })
    $curKeys = @(); $new = ''; $resolved = ''; $still = 0
    foreach ($line in $Lines) {
        if (-not $line) { continue }
        $key = $line -replace '\d', ''
        $curKeys += $key
        if (-not $All -and $prevKeys -contains $key) { $still++; continue }
        if ($line.StartsWith('- ERROR ')) { $new += "$red $($line.Substring(8))`n" } else { $new += "$yellow $($line -replace '^- WARN ', '')`n" }
    }
    if (-not $All) {
        foreach ($entry in $prev) {
            $parts = $entry -split "`t", 2
            if ($parts.Count -lt 2 -or $curKeys -contains $parts[0]) { continue }
            $resolved += "$green $($parts[1] -replace '^- (ERROR|WARN) ', '')`n"
        }
    }
    if ($new -or $resolved) {
        if ($Errors -gt 0) { $icon = $red } elseif ($Warnings -gt 0) { $icon = $yellow } else { $icon = $green }
        $text = "$icon netmonitor on $(Get-HostLabel): $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n$Errors error(s), $Warnings warning(s) now`n"
        if ($new) { $text += "`nNEW`n$new" }
        if ($resolved) { $text += "`nRESOLVED`n$resolved" }
        if ($still -gt 0) { $text += "`nSTILL OPEN: $still (reported before, unchanged)`n" }
        $text += "`n$(Get-BaseUrlLine)"
        if (-not (Send-Telegram $text)) { return }
    }
    $stateLines = @($Lines | Where-Object { $_ } | ForEach-Object { "$($_ -replace '\d', '')`t$_" })
    [System.IO.File]::WriteAllText($state, ((($stateLines) -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# Is something listening on this TCP port of the host?
function Test-PortInUse([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(500) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Close() }
}

# Look for the mistakes that otherwise show up later as a container that never starts or a port that is
# never published. Prints ok / info / WARN / ERROR lines; exits 1 if there is any ERROR.
function Invoke-Doctor {
    $script:DoctorReport = ''
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
    $known = @('syslog', 'traps', 'ntopng', 'mail', 'netflow', 'grafana', 'oxidized', 'smokeping', 'proxy', 'tools')
    if ($profileList.Count -eq 0) {
        Write-Check 'info' 'no optional profile is enabled (COMPOSE_PROFILES is empty)'
    }
    else {
        Write-Check 'ok' ('enabled: ' + ($profileList -join ','))
        foreach ($p in $profileList) {
            if ($known -cnotcontains $p) {
                Write-Check 'warn' "unknown profile '$p' in COMPOSE_PROFILES (known: syslog, traps, ntopng, mail, netflow, grafana, oxidized, smokeping, proxy, tools)"
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
    if ((Test-Profile 'oxidized') -and (Get-Setting 'OXIDIZED_NOTIFY_TELEGRAM' 'false') -eq 'true') {
        if (-not (Get-Setting 'TELEGRAM_BOT_TOKEN') -or -not (Get-Setting 'TELEGRAM_CHAT_ID')) {
            Write-Check 'warn' 'OXIDIZED_NOTIFY_TELEGRAM is true but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty: no config-change messages will be sent'
        }
        else { Write-Check 'ok' 'oxidized: config changes are sent to Telegram' }
    }
    if (Test-Profile 'proxy') {
        foreach ($who in @('OXIDIZED', 'SMOKEPING')) {
            $authUser = Get-Setting "${who}_AUTH_USER"
            $authHash = Get-Setting "${who}_AUTH_HASH"
            if (-not $authUser) { continue }
            if (-not $authHash) {
                Write-Check 'warn' "${who}_AUTH_USER is set but ${who}_AUTH_HASH is empty: nobody can log in to the $who name (README, Oxidized)"
            }
            elseif ($authHash -match '^\$2[aby]\$..\$') {
                Write-Check 'ok' "${who}: HTTP Basic Auth is on for user $authUser"
            }
            else {
                Write-Check 'warn' "${who}_AUTH_HASH does not look like a bcrypt hash (`$2a`$...): make it with caddy hash-password and put it in single quotes in .env"
            }
        }
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
        $running = @()
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

        if ($running.Count -gt 0) {
            Write-Host 'Storage'
            $warnPct = Get-Setting 'DOCTOR_DISK_WARN_PCT' '80'
            $warnGb = Get-Setting 'DOCTOR_VOLUME_WARN_GB' '50'
            if ($warnPct -notmatch '^\d+$') { Write-Check 'warn' "DOCTOR_DISK_WARN_PCT '$warnPct' is not a number, using 80"; $warnPct = '80' }
            if ($warnGb -notmatch '^\d+$') { Write-Check 'warn' "DOCTOR_VOLUME_WARN_GB '$warnGb' is not a number, using 50"; $warnGb = '50' }
            $volumes = @(
                @{ Name = 'data'; Service = 'librenms'; Path = '/data' },
                @{ Name = 'db'; Service = 'db'; Path = '/var/lib/mysql' }
            )
            if (Test-Profile 'netflow') { $volumes += @{ Name = 'nfsen'; Service = 'librenms'; Path = '/netflow' } }
            foreach ($v in $volumes) {
                if ($running -notcontains $v.Service) { Write-Check 'info' "volume $($v.Name): not measured ($($v.Service) is not running)"; continue }
                $probe = 'df -Pk $1 | tail -n 1; du -sk $1 2>/dev/null | cut -f1'
                $out = @((Invoke-Docker @('compose', 'exec', '-T', $v.Service, 'sh', '-c', $probe, 'sh', $v.Path) -Capture).Output)
                $dfFields = @("$($out | Select-Object -First 1)".Trim() -split '\s+')
                $pct = ''
                if ($dfFields.Count -ge 5) { $pct = $dfFields[4] -replace '%', '' }
                if ($pct -notmatch '^\d+$') { Write-Check 'info' "volume $($v.Name): could not read its disk usage"; continue }
                $kb = [long]0
                if ($out.Count -ge 2 -and "$($out[1])".Trim() -match '^\d+$') { $kb = [long]"$($out[1])".Trim() }
                $gb = [math]::Floor($kb / 1048576)
                if ($gb -ge 1) { $size = "$gb GB" } else { $size = "$([math]::Floor($kb / 1024)) MB" }
                if ([int]$pct -gt [int]$warnPct) {
                    Write-Check 'warn' "volume $($v.Name): the disk holding it is $pct% full (limit $warnPct%): free space, lower the retention days or move Docker's data folder"
                }
                elseif ($kb -gt ([long]$warnGb * 1048576)) {
                    Write-Check 'warn' "volume $($v.Name): $size is more than the $warnGb GB limit (README, Tuning: retention, RRD and flow data)"
                }
                else { Write-Check 'ok' "volume $($v.Name): $size, disk $pct% full" }
            }

            Write-Host 'Poller'
            if ($running -contains 'dispatcher') {
                $sql = 'SELECT COALESCE(SUM(last_polled IS NULL OR last_polled < NOW() - INTERVAL 15 MINUTE), 0), COALESCE(SUM(last_polled_timetaken > 300), 0) FROM devices WHERE disabled = 0 AND status = 1'
                $mysqlCmd = 'IFS=; set -f; mariadb -N -B -u$MARIADB_USER -p$MARIADB_PASSWORD $MARIADB_DATABASE -e $1'
                $rows = "$((Invoke-Docker @('compose', 'exec', '-T', 'db', 'sh', '-c', $mysqlCmd, 'sh', $sql) -Capture).Output | Select-Object -First 1)".Trim()
                $parts = @($rows -split '\s+')
                if ($parts.Count -lt 2 -or $parts[0] -notmatch '^\d+$' -or $parts[1] -notmatch '^\d+$') {
                    Write-Check 'info' 'poller: could not read the device poll times from the database'
                }
                else {
                    $late = [int]$parts[0]; $slow = [int]$parts[1]
                    if ($late -eq 0 -and $slow -eq 0) { Write-Check 'ok' 'poller: every up device was polled within the last 15 minutes' }
                    if ($late -gt 0) {
                        Write-Check 'warn' "poller: $late device(s) not polled for over 15 minutes (backlog): raise DISPATCHER_WORKERS (now $(Get-Setting 'DISPATCHER_WORKERS' '8')) or MARIADB_BUFFER_POOL_SIZE (now $(Get-Setting 'MARIADB_BUFFER_POOL_SIZE' '512M')); see .\scripts\run.ps1 logs dispatcher"
                    }
                    if ($slow -gt 0) {
                        Write-Check 'warn' "poller: $slow device(s) took longer than 300 s to poll, more than the 5-minute cycle: raise DISPATCHER_WORKERS or MARIADB_BUFFER_POOL_SIZE, or look at the slowest devices"
                    }
                }
            }
            else {
                Write-Check 'warn' 'poller: the dispatcher is not running, so no device is polled (start it with .\scripts\run.ps1 up)'
            }
        }
    }

    Write-Host 'SNMP'
    $community = Get-Setting 'LIBRENMS_SNMP_COMMUNITY'
    if (@('public', 'private') -contains $community) {
        Write-Check 'warn' "LIBRENMS_SNMP_COMMUNITY is '$community', the best-known SNMP community: use a secret one, or SNMPv3"
    }
    if ($running -contains 'db') {
        $snmpSql = "SELECT COALESCE(SUM(snmpver IN ('v1','v2c') AND community IN ('public','private')), 0), COALESCE(SUM(snmpver IN ('v1','v2c')), 0) FROM devices WHERE disabled = 0 AND snmp_disable = 0"
        $snmpCmd = 'IFS=; set -f; mariadb -N -B -u$MARIADB_USER -p$MARIADB_PASSWORD $MARIADB_DATABASE -e $1'
        $snmpRows = "$((Invoke-Docker @('compose', 'exec', '-T', 'db', 'sh', '-c', $snmpCmd, 'sh', $snmpSql) -Capture).Output | Select-Object -First 1)".Trim()
        $sp = @($snmpRows -split '\s+')
        if ($sp.Count -lt 2 -or $sp[0] -notmatch '^\d+$' -or $sp[1] -notmatch '^\d+$') {
            Write-Check 'info' 'SNMP: could not read the device SNMP versions from the database'
        }
        else {
            if ([int]$sp[0] -gt 0) { Write-Check 'warn' "SNMP: $($sp[0]) device(s) use the community 'public' or 'private': change it on the device and in LibreNMS, or move to SNMPv3" }
            if ([int]$sp[1] -gt 0) { Write-Check 'info' "SNMP: $($sp[1]) device(s) use SNMP v1/v2c, whose community strings are not encrypted; SNMPv3 authPriv is safer" }
            else { Write-Check 'ok' 'SNMP: no device uses SNMP v1 or v2c' }
        }
    }

    Write-Host 'Clock'
    if ($running -contains 'librenms') {
        $containerTime = "$((Invoke-Docker @('compose', 'exec', '-T', 'librenms', 'date', '+%s') -Capture).Output | Select-Object -First 1)".Trim()
        if ($containerTime -notmatch '^\d+$') { Write-Check 'info' 'clock: could not read the time in the LibreNMS container' }
        else {
            $skew = [math]::Abs([long]$containerTime - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
            if ($skew -gt 60) { Write-Check 'warn' "clock: the LibreNMS container is $skew s away from this host: graphs, alerts and SNMP timestamps drift (restart Docker Desktop)" }
            else { Write-Check 'ok' 'clock: the container and this host agree (within 60 s)' }
        }
    }

    Write-Host 'Host ports'
    $portsTaken = $false
    foreach ($row in @(
            @('librenms', '', 'LIBRENMS_PORT', '8000'), @('grafana', 'grafana', 'GRAFANA_PORT', '3001'),
            @('oxidized', 'oxidized', 'OXIDIZED_PORT', '8888'), @('smokeping', 'smokeping', 'SMOKEPING_PORT', '8085'),
            @('nfsen', 'netflow', 'NFSEN_WEB_PORT', '8080'), @('caddy', 'proxy', 'CADDY_HTTP_PORT', '80'),
            @('caddy', 'proxy', 'CADDY_HTTPS_PORT', '443'))) {
        if ($row[1] -and -not (Test-Profile $row[1])) { continue }
        if ($running -contains $row[0]) { continue }
        $portNumber = Get-Setting $row[2] $row[3]
        if ($portNumber -match '^\d+$' -and (Test-PortInUse ([int]$portNumber))) {
            Write-Check 'warn' "port $portNumber ($($row[2])) is already used by something else on this host, and $($row[0]) is not running: change $($row[2]) in .env"
            $portsTaken = $true
        }
    }
    if (-not $portsTaken) { Write-Check 'ok' 'no port of a stopped service is taken by another program' }

    Write-Host ''
    Write-Host "$($script:DoctorErrors) error(s), $($script:DoctorWarnings) warning(s)"
    if ($Notify -or $NotifyAll) {
        $reportLines = @($script:DoctorReport -split "`n" | Where-Object { $_ })
        if ($NotifyAll) {
            if (($script:DoctorErrors + $script:DoctorWarnings) -gt 0) { Send-DoctorChanges $reportLines $script:DoctorErrors $script:DoctorWarnings $true }
        }
        else { Send-DoctorChanges $reportLines $script:DoctorErrors $script:DoctorWarnings $false }
    }
    if ($script:DoctorErrors -gt 0) { exit 1 }
}

if (@('help', '--help', '-h', '/?') -contains $Command) { Show-Usage; exit 0 }
if (@('up', 'down', 'restart', 'logs', 'status', 'backup', 'restore', 'validate', 'configure', 'update', 'doctor', 'add-device', 'scan', 'lnms', 'user-add', 'oxidized-setup', 'poll-device', 'snmp-walk', 'ping-device', 'sync-inventory', 'verify-backup') -notcontains $Command) {
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
            & (Join-Path (Join-Path $Root 'scripts') 'backup.ps1') -Keep $Keep -Verify:$Verify -NoOffsite:$NoOffsite
            $code = $LASTEXITCODE
        }
        'restore' {
            if (-not $Name) { Fail "restore needs a target: 'latest', a backup name or a file path (see .\run.ps1 help)" }
            & (Join-Path (Join-Path $Root 'scripts') 'restore.ps1') -Backup $Name -Yes:$Yes
            $code = $LASTEXITCODE
        }
        'configure' { Invoke-Configure }
        'update'    { Invoke-Update }
        'doctor'    {
            if ($NotifyTest) {
                $ok = Send-Telegram "$([char]::ConvertFromUtf32(0x2705)) netmonitor on $(Get-HostLabel): test message, $(Get-Date -Format 'yyyy-MM-dd HH:mm')`nTelegram notifications from doctor -Notify work.`n$(Get-BaseUrlLine)"
                if (-not $ok) { exit 1 }
            }
            else { Invoke-Doctor }
        }
        'validate' {
            $code = (Invoke-LibrenmsExec 'validate' 'php validate.php' $ExtraArgs).Code
        }
        'add-device' { $code = Invoke-AddDevice $ExtraArgs }
        'lnms' {
            $cmdArgs = @()
            if ($ExtraArgs) { $cmdArgs += $ExtraArgs }
            if ($cmdArgs.Count -eq 0) { Fail 'usage: .\scripts\run.ps1 lnms <command> [options] (e.g. .\scripts\run.ps1 lnms user:add <user> -r admin)' }
            $dockerArgs = @('compose', 'exec', '-T', 'librenms', 'su', '-s', '/bin/sh', 'librenms', '-c', 'php /opt/librenms/lnms "$@"', '--', 'lnms') + $cmdArgs
            $code = (Invoke-Docker $dockerArgs).Code
        }
        'scan' {
            if (-not $Name) { Fail 'usage: .\scripts\run.ps1 scan <subnet> [options] (e.g. .\scripts\run.ps1 scan 192.168.1.0/24)' }
            $argsList = @($Name)
            if ($ExtraArgs) { $argsList += $ExtraArgs }
            $code = (Invoke-LibrenmsExec 'scan' 'python3 snmp-scan.py' $argsList).Code
        }
        'verify-backup'  { $code = Invoke-VerifyBackup $ExtraArgs }
        'user-add'       { Invoke-UserAdd $ExtraArgs }
        'oxidized-setup' { Invoke-OxidizedSetup $ExtraArgs }
        'poll-device' {
            if ($ExtraArgs.Count -lt 1) { Fail 'usage: .\scripts\run.ps1 poll-device <hostname-ip-or-device-id>' }
            $code = (Invoke-Lnms (@('device:poll') + $ExtraArgs + @('-vvv'))).Code
        }
        'snmp-walk' {
            if ($ExtraArgs.Count -lt 1) { Fail 'usage: .\scripts\run.ps1 snmp-walk <host> [oid]' }
            $code = (Invoke-Lnms (@('snmp:walk') + $ExtraArgs)).Code
        }
        'ping-device' {
            if ($ExtraArgs.Count -lt 1) { Fail 'usage: .\scripts\run.ps1 ping-device <hostname-or-ip>' }
            $code = (Invoke-Lnms (@('device:ping') + $ExtraArgs)).Code
        }
        'sync-inventory' {
            if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { Fail 'sync-inventory runs scripts/netops-sync.sh and needs bash (Git for Windows or WSL) in the PATH' }
            & bash 'scripts/netops-sync.sh' @ExtraArgs
            $code = $LASTEXITCODE
        }
    }
    exit $code
}
finally { Pop-Location }
