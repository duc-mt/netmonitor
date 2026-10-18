#!/usr/bin/env bash
# Linux and macOS: back up the LibreNMS database and data volume to ./backups
#
#   scripts/backup.sh              one backup set (librenms-YYYYMMDD-HHMMSS-*)
#   scripts/backup.sh --keep 7     also delete all but the newest 7 sets
#
# The dispatcher is paused for the duration so the RRD files are consistent
# (graphs have a short gap) and is restarted afterwards, even if the backup fails.
set -euo pipefail

cd "$(dirname "$0")/.."

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)
      [ $# -ge 2 ] || { echo "error: --keep needs a number" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "error: --keep needs a number" >&2; exit 2 ;; esac
      KEEP=$2; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "error: $*" >&2; exit 1; }
[ -f .env ] || die "no .env found. Run scripts/setup.sh first."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is not available."
docker info >/dev/null 2>&1 || die "The Docker daemon is not running."

name="librenms-$(date +%Y%m%d-%H%M%S)"
mkdir -p backups

docker compose up -d --wait db

paused=0
if docker compose ps --status running --services 2>/dev/null | grep -qx dispatcher; then
  docker compose stop dispatcher
  paused=1
fi
resume() {
  if [ "$paused" -eq 1 ]; then docker compose start dispatcher >/dev/null || true; fi
}
trap resume EXIT

docker compose run --rm --no-deps -e "BACKUP_NAME=$name" -e "KEEP=$KEEP" tools /scripts/backup.sh
echo "Done. Files are in ./backups (name: $name)"
