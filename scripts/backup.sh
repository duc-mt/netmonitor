#!/usr/bin/env bash
# Linux and macOS: back up the LibreNMS database and data volume to ./backups
#
#   scripts/backup.sh              one backup set (librenms-YYYYMMDD-HHMMSS-*)
#   scripts/backup.sh --keep 7     also delete all but the newest 7 sets
#   scripts/backup.sh --verify     then restore the new set into a throw-away database to prove it works
#   scripts/backup.sh --no-offsite skip the upload that BACKUP_REMOTE in .env asks for
#
# Off-site copy: set BACKUP_REMOTE in .env to an rclone destination (for example s3:my-bucket/netmonitor) and
# install rclone on this computer; every set is uploaded after it passed its checks. Old sets there are yours
# to expire (a bucket lifecycle rule), --keep only prunes ./backups.
#
# The dispatcher is paused for the duration so the RRD files are consistent
# (graphs have a short gap) and is restarted afterwards, even if the backup fails.
set -euo pipefail

cd "$(dirname "$0")/.."

KEEP=0
VERIFY=0
OFFSITE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)
      [ $# -ge 2 ] || { echo "error: --keep needs a number" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "error: --keep needs a number" >&2; exit 2 ;; esac
      KEEP=$2; shift ;;
    --verify) VERIFY=1 ;;
    --no-offsite) OFFSITE=0 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# With --verify the old sets are pruned only after the new one proved itself, so the dispatcher is started again
# first (loading a dump takes a while) and the check and the pruning are separate runs.
keep_now=$KEEP
if [ "$VERIFY" -eq 1 ]; then keep_now=0; fi
docker compose run --rm --no-deps -e "BACKUP_NAME=$name" -e "KEEP=$keep_now" tools /scripts/backup.sh
if [ "$VERIFY" -eq 1 ]; then
  resume
  paused=0
  echo "Restore test ..."
  docker compose run --rm --no-deps -e "BACKUP_NAME=$name" tools /scripts/verify.sh ||
    die "the backup was written but did NOT pass the restore test: do not rely on $name (older sets were not pruned)"
  if [ "$KEEP" -gt 0 ]; then docker compose run --rm --no-deps -e "KEEP=$KEEP" tools /scripts/prune.sh; fi
fi
echo "Done. Files are in ./backups (name: $name)"

# Off-site copy, when asked for in .env (and not switched off). The dispatcher is running again by now.
remote=$(grep -m1 '^BACKUP_REMOTE=' .env | cut -d= -f2- | sed "s/^['\"]//;s/['\"]\$//" || true)
remote=${BACKUP_REMOTE:-$remote}
if [ "$OFFSITE" -eq 1 ] && [ -n "$remote" ]; then
  command -v rclone >/dev/null 2>&1 || die "BACKUP_REMOTE is set but rclone is not installed. The backup is in ./backups; install rclone (https://rclone.org) or use --no-offsite."
  echo "Uploading to $remote ..."
  rclone copy --checksum "backups/$name-db.sql.gz" "$remote" || die "the upload of $name-db.sql.gz failed; the backup itself is in ./backups"
  rclone copy --checksum "backups/$name-data.tgz" "$remote" || die "the upload of $name-data.tgz failed; the backup itself is in ./backups"
  echo "Uploaded $name to $remote"
fi
