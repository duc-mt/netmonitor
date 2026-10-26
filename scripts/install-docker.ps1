<#
.SYNOPSIS
  Windows: automated installation and detection of Docker Desktop and WSL 2 backend.
  Works on Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\install-docker.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Info([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Warn([string]$Message) { Write-Host "WARN: $Message" -ForegroundColor Yellow }
function Fail([string]$Message) { Write-Host "ERROR: $Message" -ForegroundColor Red; exit 1 }

Info "Detecting Docker environment on Windows..."

# Check if Docker CLI is already present in PATH
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerCmd) {
    $version = (& docker --version)
    Info "Docker is already installed: $version"
    $composeVersion = (& docker compose version 2>$null)
    if ($composeVersion) {
        Info "Docker Compose is ready: $composeVersion"
        exit 0
    }
}

# Check if running with Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Fail "Administrative privileges are required to install Docker Desktop on Windows. Please re-run this script in an elevated PowerShell window (Run as Administrator)."
}

# Check winget / choco
if (Get-Command winget -ErrorAction SilentlyContinue) {
    Info "Installing Docker Desktop using Windows Package Manager (winget)..."
    & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
}
elseif (Get-Command choco -ErrorAction SilentlyContinue) {
    Info "Installing Docker Desktop using Chocolatey..."
    & choco install docker-desktop -y
}
else {
    Info "No package manager found. Downloading official Docker Desktop installer..."
    $installerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    $installerPath = Join-Path $env:TEMP "DockerDesktopInstaller.exe"
    
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    Info "Running Docker Desktop installer..."
    Start-Process -FilePath $installerPath -ArgumentList "install", "--quiet", "--accept-license" -Wait
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
}

Info "Docker Desktop installation finished."
Info "Please launch Docker Desktop from the Start Menu to initialize the WSL2/Hyper-V engine."
