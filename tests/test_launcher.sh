#!/usr/bin/env bash
# ./run: each verb issues the right docker command, mistakes are refused, and restore accepts every way of
# naming a backup. Needs no Docker (see lib.sh).
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
sandbox

# expect_call "<docker call>" <run arguments...>
expect_call() {
  local want=$1
  shift
  : > "$FAKE_LOG"
  ./run "$@" >/dev/null 2>&1 || true
  equals "run $*" "$want" "$(calls)"
}

# run_code <run arguments...>: sets $code, keeps the output in out.txt and err.txt
run_code() {
  : > "$FAKE_LOG"
  code=0
  ./run "$@" >out.txt 2>err.txt || code=$?
}

echo "verbs"
expect_call "compose up -d" up
expect_call "compose down" down
expect_call "compose restart" restart
expect_call "compose restart librenms" restart librenms
expect_call "compose logs -f --tail=100" logs
expect_call "compose logs -f --tail=100 dispatcher" logs dispatcher
expect_call "compose ps" status
expect_call "compose exec -T --user librenms -w /opt/librenms librenms php validate.php" validate
expect_call "compose exec -T --user librenms -w /opt/librenms librenms php addhost.php 192.168.1.1 -v 2c -c public" add-device 192.168.1.1 -v 2c -c public
expect_call "compose exec -T --user librenms -w /opt/librenms librenms python3 snmp-scan.py 192.168.1.0/24" scan 192.168.1.0/24

echo "mistakes and missing prerequisites"
run_code down -v
equals "down -v is refused" 1 "$code"
equals "down -v starts nothing" "" "$(calls)"
run_code bogus
equals "an unknown verb exits 2" 2 "$code"
check "an unknown verb prints the usage" grep -q 'restart \[service\]' err.txt
mv .env .env.off
run_code up
equals "a missing .env exits 1" 1 "$code"
check "a missing .env names the setup script" grep -q 'scripts/setup.sh' err.txt
mv .env.off .env
FAKE_INFO_EXIT=1 run_code up
equals "a stopped Docker daemon exits 1" 1 "$code"
check "a stopped Docker daemon says so" grep -q 'daemon is not running' err.txt

echo "usage text"
last=$(( $(grep -n '^set -euo pipefail' scripts/run.sh | head -n 1 | cut -d: -f1) - 1 ))
expected=$(sed -n "2,${last}p" scripts/run.sh | sed 's/^# \{0,1\}//')
equals "help prints exactly the header comment" "$expected" "$(./run help)"
equals "no arguments prints the same" "$expected" "$(./run)"

echo "restore accepts every way of naming a backup"
mkdir -p backups
: > backups/librenms-20261017-083500-db.sql.gz
: > backups/librenms-20261017-083500-data.tgz
for form in backups/librenms-20261017-083500-db.sql.gz ./backups/librenms-20261017-083500-data.tgz \
            ./backups/20261017-083500 20261017-083500 librenms-20261017-083500 latest; do
  run_code restore "$form" --yes
  if [ "$code" -eq 0 ] && calls | grep -E 'BACKUP_NAME=librenms-20261017-083500( |$)' >/dev/null; then
    pass "restore $form"
  else
    fail "restore $form"
    cat err.txt
  fi
done
run_code restore backups/ --yes
equals "restoring a folder exits 1" 1 "$code"
check "restoring a folder asks for a name" grep -q 'say which backup' err.txt
run_code restore 20990101-000000 --yes
equals "restoring a missing backup exits 1" 1 "$code"
check "restoring a missing backup says so" grep -q 'must both exist' err.txt

echo "backup"
run_code backup --keep 3
equals "backup exits 0" 0 "$code"
present "backup passes --keep to the helper" '-e KEEP=3'
check "backup pauses the dispatcher" grep -qx 'compose stop dispatcher' "$FAKE_LOG"
check "backup resumes the dispatcher" grep -qx 'compose start dispatcher' "$FAKE_LOG"

finish
