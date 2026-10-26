#!/usr/bin/env bash
# scripts/install-docker.sh
# Universal Docker installation and detection script for Linux and macOS.
# Detects OS distribution/package manager and installs Docker Engine or Docker Desktop.

set -euo pipefail

info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

check_existing_docker() {
    if command -v docker >/dev/null 2>&1; then
        info "Docker CLI is already installed: $(docker --version)"
        if docker compose version >/dev/null 2>&1; then
            info "Docker Compose is ready: $(docker compose version)"
            exit 0
        else
            warn "Docker is installed but Compose v2 plugin was not detected."
        fi
    fi
}

install_macos() {
    info "Detected platform: macOS ($(uname -m))"
    if [ -d "/Applications/Docker.app" ]; then
        info "Docker.app is present in /Applications."
    elif command -v brew >/dev/null 2>&1; then
        info "Installing Docker Desktop via Homebrew Cask..."
        brew install --cask docker-desktop
    else
        die "Homebrew is required to install Docker Desktop on macOS. Install Homebrew (https://brew.sh) or download Docker Desktop from https://www.docker.com/products/docker-desktop"
    fi

    info "Launching Docker Desktop to initialize daemon..."
    open -a Docker || true
    echo ""
    info "Docker Desktop has been launched. Please wait a few moments for the engine to initialize."
}

install_linux() {
    info "Detected platform: Linux ($(uname -m))"
    
    # Check if running in WSL
    if grep -qi microsoft /proc/version 2>/dev/null; then
        info "WSL environment detected."
    fi

    # Require root/sudo privileges on Linux
    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            die "Root privileges or sudo are required to install Docker on Linux."
        fi
    fi

    if command -v apt-get >/dev/null 2>&1; then
        info "Using APT package manager (Debian/Ubuntu/Raspbian)..."
        if command -v fuser >/dev/null 2>&1; then
            for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
                while $SUDO fuser "$lock" >/dev/null 2>&1; do
                    info "Waiting for background package manager/updates to release $lock..."
                    sleep 3
                done
            done
        fi
        $SUDO apt-get update -y
        $SUDO apt-get install -y ca-certificates curl gnupg
        
        info "Installing Docker using official get.docker.com script..."
        curl -fsSL https://get.docker.com | $SUDO sh
    elif command -v dnf >/dev/null 2>&1; then
        info "Using DNF package manager (RHEL/CentOS/Fedora/Rocky/Alma)..."
        curl -fsSL https://get.docker.com | $SUDO sh
    elif command -v yum >/dev/null 2>&1; then
        info "Using YUM package manager..."
        curl -fsSL https://get.docker.com | $SUDO sh
    elif command -v pacman >/dev/null 2>&1; then
        info "Using Pacman (Arch Linux)..."
        $SUDO pacman -Sy --noconfirm docker docker-compose
    else
        die "Unsupported Linux distribution. Please install Docker manually: https://docs.docker.com/engine/install/"
    fi

    # Enable and start Docker service on systemd-based hosts
    if command -v systemctl >/dev/null 2>&1; then
        info "Enabling and starting docker service..."
        $SUDO systemctl enable --now docker
    fi

    # Add the invoking user (or current user) to docker group so sudo is not needed
    TARGET_USER="${SUDO_USER:-${USER:-}}"
    if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
        info "Adding $TARGET_USER to docker group..."
        $SUDO usermod -aG docker "$TARGET_USER" || true
        info "Note: You may need to run 'newgrp docker' or log out and back in for docker group changes to apply."
    fi
}

main() {
    check_existing_docker

    case "$(uname -s)" in
        Darwin)
            install_macos
            ;;
        Linux)
            install_linux
            ;;
        CYGWIN*|MINGW*|MSYS*)
            die "Windows Bash detected. Please run the Windows installer via PowerShell: powershell -ExecutionPolicy Bypass -File scripts\\install-docker.ps1"
            ;;
        *)
            die "Unsupported operating system: $(uname -s)"
            ;;
    esac

    echo ""
    info "Docker installation complete. Verifying status..."
    if command -v docker >/dev/null 2>&1; then
        echo "Docker: $(docker --version)"
    fi
    if docker compose version >/dev/null 2>&1; then
        echo "Compose: $(docker compose version)"
    fi
}

main "$@"
