#!/usr/bin/env bash
# The scripts that run inside the "tools" container: prune.sh (keeps the newest sets) and verify.sh (restores a set
# into a throw-away MariaDB). Each part skips itself when the tool it needs (GNU head, mariadbd) is missing.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "prune.sh"
if ! (printf '1\n2\n' | head -n -1) >/dev/null 2>&1; then
  echo "  skip  needs GNU head (the script runs inside a Linux container)"
else
  mkdir "$work/prune"
  for n in 20260101-000001 20260101-000002 20260101-000003 20260101-000004; do
    : > "$work/prune/librenms-$n-db.sql.gz"; : > "$work/prune/librenms-$n-data.tgz"
  done
  : > "$work/prune/update-20260101-000000.txt"
  BACKUP_DIR=$work/prune KEEP=0 bash "$REPO_DIR/scripts/container/prune.sh" >/dev/null
  equals "KEEP=0 keeps everything" 8 "$(find "$work/prune" -name 'librenms-*' | wc -l | tr -d ' ')"
  BACKUP_DIR=$work/prune KEEP=2 bash "$REPO_DIR/scripts/container/prune.sh" >/dev/null
  equals "KEEP=2 leaves two sets (four files)" 4 "$(find "$work/prune" -name 'librenms-*' | wc -l | tr -d ' ')"
  check "the newest set stays" test -f "$work/prune/librenms-20260101-000004-db.sql.gz"
  check "and its data archive" test -f "$work/prune/librenms-20260101-000004-data.tgz"
  check "the oldest is gone" test ! -f "$work/prune/librenms-20260101-000001-db.sql.gz"
  check "update notes are not touched" test -f "$work/prune/update-20260101-000000.txt"
fi

echo "verify.sh"
PATH="$PATH:/usr/sbin:/sbin"   # mariadbd lives in sbin on Debian and Ubuntu
if ! command -v mariadbd >/dev/null 2>&1 || ! command -v mariadb-install-db >/dev/null 2>&1; then
  echo "  skip  mariadbd is not installed"
else
  bk=$work/bk
  mkdir -p "$bk" "$work/data/rrd" "$work/data/config"
  echo x > "$work/data/rrd/a.rrd"; echo y > "$work/data/config/c.php"
  tar czf "$bk/librenms-good-data.tgz" -C "$work/data" .
  cat > "$work/good.sql" <<'SQL'
CREATE TABLE devices (device_id int primary key auto_increment, hostname varchar(100)) ENGINE=InnoDB;
CREATE TABLE ports (port_id int primary key auto_increment, device_id int) ENGINE=InnoDB;
CREATE TABLE users (user_id int primary key auto_increment, username varchar(60)) ENGINE=InnoDB;
INSERT INTO devices (hostname) VALUES ('sw1'), ('sw2');
INSERT INTO ports (device_id) VALUES (1), (1), (2);
INSERT INTO users (username) VALUES ('admin');
SQL
  gzip -c "$work/good.sql" > "$bk/librenms-good-db.sql.gz"
  verify() { code=0; BACKUP_DIR=$bk BACKUP_NAME=$1 VERIFY_DIR=$work/v bash "$REPO_DIR/scripts/container/verify.sh" >"$work/out.txt" 2>"$work/err.txt" || code=$?; }

  verify librenms-good
  equals "a good set passes" 0 "$code"
  check "and reports what it found" grep -q 'Verified librenms-good: 3 tables, 2 devices, 3 ports, 1 users' "$work/out.txt"
  check "the temporary server is cleaned up" test ! -e "$work/v"

  echo "CREATE TABLE foo (a int);" | gzip -c > "$bk/librenms-notnms-db.sql.gz"; cp "$bk/librenms-good-data.tgz" "$bk/librenms-notnms-data.tgz"
  verify librenms-notnms
  equals "a dump that is not LibreNMS fails" 1 "$code"
  check "and says which table is missing" grep -q "no 'devices' table" "$work/err.txt"

  printf 'garbage' > "$bk/librenms-corrupt-db.sql.gz"; cp "$bk/librenms-good-data.tgz" "$bk/librenms-corrupt-data.tgz"
  verify librenms-corrupt
  equals "a corrupt dump fails" 1 "$code"

  (cat "$work/good.sql"; echo "INSERT INTO nope VALUES (1);") | gzip -c > "$bk/librenms-sqlerr-db.sql.gz"; cp "$bk/librenms-good-data.tgz" "$bk/librenms-sqlerr-data.tgz"
  verify librenms-sqlerr
  equals "a dump with an SQL error fails" 1 "$code"

  gzip -c "$work/good.sql" > "$bk/librenms-badtar-db.sql.gz"; printf 'not a tar' > "$bk/librenms-badtar-data.tgz"
  verify librenms-badtar
  equals "an unreadable data archive fails" 1 "$code"

  verify librenms-missing
  equals "a missing set fails" 1 "$code"
fi

finish
