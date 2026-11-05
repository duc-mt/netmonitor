#!/usr/bin/env bash
# Runs INSIDE the "tools" container (see compose.yaml). Do not run it on the host.
# Proves that one backup set can be restored: the archives are read through, then the database dump is loaded
# into a throw-away MariaDB server that exists only in /tmp (the real database is never touched) and checked for
# the tables LibreNMS cannot run without.
#   BACKUP_NAME   the set to check, e.g. librenms-20260101-120000
set -euo pipefail

: "${BACKUP_NAME:?BACKUP_NAME is required}"
BACKUP_DIR=${BACKUP_DIR:-/backups}
db_file="$BACKUP_DIR/$BACKUP_NAME-db.sql.gz"
data_file="$BACKUP_DIR/$BACKUP_NAME-data.tgz"
work=${VERIFY_DIR:-/tmp/verify-$$}
sock="$work/sock"
pid=""

fail() { echo "VERIFY FAILED: $*" >&2; exit 1; }

[ -f "$db_file" ] || fail "$db_file does not exist"
[ -f "$data_file" ] || fail "$data_file does not exist"

cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

echo "Verifying $BACKUP_NAME ..."
gzip -t "$db_file" || fail "the database dump is not a valid gzip file"
members=$(tar tzf "$data_file") || fail "the data archive cannot be read"
[ -n "$members" ] || fail "the data archive is empty"
files=$(printf '%s\n' "$members" | grep -vc '/$' || true)
if ! printf '%s\n' "$members" | grep -q '^\./rrd/'; then
  echo "  note: the data archive has no ./rrd folder (a new install without devices has none yet)"
fi

# In the container this runs as root, which MariaDB must be told is fine; as anybody else (tests) it needs no option.
user_opt=""
if [ "$(id -u)" -eq 0 ]; then user_opt="--user=root"; fi
mkdir -p "$work/data"
mariadb-install-db --no-defaults $user_opt --datadir="$work/data" --auth-root-authentication-method=normal \
  --skip-test-db >"$work/install.log" 2>&1 || { cat "$work/install.log" >&2; fail "could not prepare the temporary database server"; }
mariadbd --no-defaults $user_opt --datadir="$work/data" --socket="$sock" --pid-file="$work/pid" --skip-networking \
  --skip-log-bin --innodb-buffer-pool-size=128M --max-allowed-packet=256M --log-error="$work/server.log" 2>>"$work/server.log" &
pid=$!
ready=0
for _ in $(seq 1 90); do
  if mariadb-admin --no-defaults -S "$sock" -u root ping >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
[ "$ready" -eq 1 ] || { tail -n 20 "$work/server.log" >&2 || true; fail "the temporary database server did not start"; }

sql() { mariadb --no-defaults -S "$sock" -u root -N -B "$@"; }
sql -e "CREATE DATABASE verify DEFAULT CHARACTER SET utf8mb4"
echo "Loading the dump into the temporary server ..."
gzip -dc "$db_file" | sql verify || fail "the database dump could not be loaded (see the error above)"

tables=$(sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'verify'")
[ "$tables" -gt 0 ] || fail "the dump contains no tables"
for t in devices ports users; do
  found=$(sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'verify' AND table_name = '$t'")
  [ "$found" -eq 1 ] || fail "the dump has no '$t' table, so this is not a LibreNMS database"
done
devices=$(sql -e "SELECT COUNT(*) FROM verify.devices")
ports=$(sql -e "SELECT COUNT(*) FROM verify.ports")
users=$(sql -e "SELECT COUNT(*) FROM verify.users")
echo "Verified $BACKUP_NAME: $tables tables, $devices devices, $ports ports, $users users; $files files in the data archive."
