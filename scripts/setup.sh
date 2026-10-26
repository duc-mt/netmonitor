#!/usr/bin/env bash
# Linux and macOS (also Git Bash or WSL on Windows).
# Creates .env with random secrets, then starts LibreNMS.
#
#   scripts/setup.sh              create .env if it is missing, then start LibreNMS
#   scripts/setup.sh --no-start   only create .env (no Docker needed)
#
# Written for bash 3.2, the version macOS ships: no associative arrays, no mapfile.
set -euo pipefail

cd "$(dirname "$0")/.."

NO_START=0
for arg in "$@"; do
  case "$arg" in
    --no-start) NO_START=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option: $arg" >&2; exit 2 ;;
  esac
done

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# random_secret LENGTH: letters and digits only, so it is safe in .env and in URLs
random_secret() {
  head -c 48 /dev/urandom | base64 | tr -d '=+/\n' | cut -c1-"$1"
}

# The host timezone as an IANA name (Asia/Ho_Chi_Minh), or UTC when it cannot be found.
host_tz() {
  local tz=""
  if [ -n "${TZ:-}" ]; then
    tz=$TZ
  elif command -v timedatectl >/dev/null 2>&1; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  fi
  if [ -z "$tz" ] && [ -L /etc/localtime ]; then   # macOS and many Linux distributions
    tz=$(readlink /etc/localtime)
    tz=${tz#*zoneinfo/}
  fi
  if [ -z "$tz" ] && [ -r /etc/timezone ]; then
    tz=$(head -n 1 /etc/timezone)
  fi
  case "$tz" in
    ""|*[!A-Za-z0-9_+/-]*) tz=UTC ;;
  esac
  echo "$tz"
}

read_env() {  # read_env KEY: value of KEY in .env (empty if missing)
  local val
  val=$(grep -E "^$1=" .env | head -n 1 | cut -d= -f2- || true)
  case $val in
    \'*\') val=${val#\'}; val=${val%\'} ;;
    \"*\") val=${val#\"}; val=${val%\"} ;;
  esac
  printf '%s\n' "$val"
}

create_env() {
  local tz uid gid tmp line key
  tz=$(host_tz)
  uid=$(id -u); gid=$(id -g)
  if [ "$uid" -eq 0 ]; then uid=1000; fi   # the image refuses to run LibreNMS as root
  if [ "$gid" -eq 0 ]; then gid=1000; fi
  TZ_VALUE=$tz; UID_VALUE=$uid; GID_VALUE=$gid
  DB_PASSWORD_VALUE=$(random_secret 32)
  COMMUNITY_VALUE=$(random_secret 24)

  tmp=".env.tmp.$$"
  ( umask 077; : > "$tmp" )                # private from the first byte
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    case "$line" in
      TZ=*)                      printf 'TZ=%s\n' "$TZ_VALUE" ;;
      PUID=*)                    printf 'PUID=%s\n' "$UID_VALUE" ;;
      PGID=*)                    printf 'PGID=%s\n' "$GID_VALUE" ;;
      MYSQL_PASSWORD=*)          printf 'MYSQL_PASSWORD=%s\n' "$DB_PASSWORD_VALUE" ;;
      LIBRENMS_SNMP_COMMUNITY=*) printf 'LIBRENMS_SNMP_COMMUNITY=%s\n' "$COMMUNITY_VALUE" ;;
      *)                         printf '%s\n' "$line" ;;
    esac
  done < .env.example >> "$tmp"
  mv "$tmp" .env
  chmod 600 .env
  info "Created .env (timezone $tz, random database password and SNMP community)"
}

check_env() {
  local key val
  for key in MYSQL_PASSWORD LIBRENMS_SNMP_COMMUNITY; do
    val=$(read_env "$key")
    [ -n "$val" ] || die ".env exists but $key is empty. Fill it in, or delete .env and run this script again."
  done
  info "Keeping the existing .env"
}

[ -f .env.example ] || die ".env.example not found. Run this script from a full checkout of the repository."

if [ -f .env ]; then
  check_env
else
  create_env
fi

if [ "$NO_START" -eq 1 ]; then
  info "Done (--no-start). Start LibreNMS with: docker compose up -d --wait"
  exit 0
fi

command -v docker >/dev/null 2>&1 \
  || die "Docker is not installed. Install Docker Desktop (macOS) or Docker Engine (Linux): https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 \
  || die "Docker Compose v2 is missing. Update Docker Desktop, or install the docker-compose-plugin package on Linux."
if ! docker info >/dev/null 2>&1; then
  # On Linux, try auto-starting docker service if systemctl is available
  if command -v systemctl >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
    info "Attempting to start Docker service via systemctl..."
    if [ "$(id -u)" -eq 0 ]; then
      systemctl start docker || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo systemctl start docker || true
    fi
  fi
fi

# Determine if docker requires sudo wrapper in current session
DOCKER_CMD="docker"
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER_CMD="sudo docker"
  else
    die "The Docker daemon is not running or accessible. Start Docker Desktop (macOS) or run: sudo systemctl start docker (Linux)."
  fi
fi

info "Starting LibreNMS. The first start downloads the images and runs the database migrations, so it can take several minutes."
if ! $DOCKER_CMD compose up -d --wait; then
  echo >&2
  $DOCKER_CMD compose ps >&2 || true
  $DOCKER_CMD compose logs --tail 40 librenms >&2 || true
  die "LibreNMS did not become healthy. See the log above, or run: docker compose logs -f"
fi

port=$(read_env LIBRENMS_PORT); port=${port:-8000}
bind=$(read_env LIBRENMS_BIND); bind=${bind:-127.0.0.1}
if [ "$bind" = "127.0.0.1" ]; then
  url="http://localhost:$port"
else
  url="http://<this-machine-address>:$port"
fi
echo
info "LibreNMS is running: $url"
echo "    1. Open the address above. The first visit asks you to create the admin account."
echo "    2. Add your first device: Devices > Add Device (SNMPv3 is recommended)."
echo "    3. Back up regularly: scripts/backup.sh"
