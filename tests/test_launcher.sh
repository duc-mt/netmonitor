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
  : > "$FAKE_LOG.stdin"
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
expect_call "compose exec -T librenms su -s /bin/sh librenms -c cd /opt/librenms && php validate.php \"\$@\" -- validate" validate
expect_call "compose exec -T librenms su -s /bin/sh librenms -c cd /opt/librenms && php addhost.php \"\$@\" -- add-device 192.168.1.1 -v 2c -c public" add-device 192.168.1.1 -v 2c -c public
expect_call "compose exec -T librenms su -s /bin/sh librenms -c cd /opt/librenms && python3 snmp-scan.py \"\$@\" -- scan 192.168.1.0/24" scan 192.168.1.0/24
expect_call "compose exec -T librenms su -s /bin/sh librenms -c php /opt/librenms/lnms \"\$@\" -- lnms --version" lnms --version
LNMS='compose exec -T librenms su -s /bin/sh librenms -c php /opt/librenms/lnms "$@" -- lnms'
expect_call "$LNMS device:poll core-sw1 -vvv" poll-device core-sw1
expect_call "$LNMS snmp:walk core-sw1 1.3.6.1.2.1.1" snmp-walk core-sw1 1.3.6.1.2.1.1
expect_call "$LNMS device:ping core-sw1" ping-device core-sw1
UA='compose exec -T librenms su -s /bin/sh librenms -c IFS= read -r pw; exec php /opt/librenms/lnms user:add "$@" -p "$pw" -- lnms'
expect_call "$UA bob -r global-read -e bob@example.com" user-add bob -p s3cret -r global-read -e bob@example.com
equals "the password goes in on stdin" "s3cret" "$(stdin_log)"

echo "no container command uses --user librenms (it fails on Docker Desktop)"
check "run.sh" test -z "$(grep -nE -e "exec .*--user|'--user'" scripts/run.sh || true)"
check "run.ps1" test -z "$(grep -nE -e "exec .*--user|'--user'" scripts/run.ps1 || true)"

echo "diagnostic verbs need an argument"
for verb in poll-device snmp-walk ping-device user-add; do
  run_code "$verb"
  equals "$verb without an argument exits 1" 1 "$code"
  equals "$verb without an argument calls nothing" "" "$(calls)"
done

echo "user-add"
run_code user-add bob
equals "exits 0" 0 "$code"
pw=$(sed -n 's/^Generated secure password for bob: //p' out.txt)
equals "generates a 24-character password" 24 "${#pw}"
check "with upper case, lower case, a digit and a symbol" bash -c '[[ $1 == *[A-Z]* && $1 == *[a-z]* && $1 == *[0-9]* && $1 == *[\!\#%*+=]* ]]' _ "$pw"
equals "the generated password is the one given to lnms on stdin" "$pw" "$(stdin_log)"
absent "the generated password is on no command line" "$pw"
run_code user-add alice
pw2=$(sed -n 's/^Generated secure password for alice: //p' out.txt)
check "two generated passwords differ" test "$pw" != "$pw2"
run_code user-add carol -p Given-Pass-1
equals "an explicit password is used (on stdin)" "Given-Pass-1" "$(stdin_log)"
present "and the user is passed as an argument" "lnms carol -r admin"
check "an explicit password is not printed back" test -z "$(grep -i 'generated' out.txt)"
run_code user-add dave -r superuser
equals "a bad role exits 1" 1 "$code"
equals "a bad role calls nothing" "" "$(calls)"
FAKE_USER_ADD_ERR='The username has already been taken.' run_code user-add bob
equals "an existing user exits 1" 1 "$code"
check "and says so" grep -q 'already exists' err.txt
check "and prints no password" test -z "$(grep -i 'password' out.txt)"
FAKE_USER_ADD_ERR='SQLSTATE[HY000] boom' run_code user-add bob
equals "any other failure exits 1" 1 "$code"
check "and shows the reason" grep -q 'boom' err.txt
: > "$FAKE_LOG.stdin"; : > "$FAKE_LOG"
code=0; printf 'piped-pass\n' | ./run user-add erin --password-stdin >out.txt 2>err.txt || code=$?
equals "--password-stdin exits 0" 0 "$code"
equals "--password-stdin passes the piped password on" "piped-pass" "$(stdin_log)"
check "--password-stdin prints no password" test -z "$(grep -i 'generated' out.txt)"
code=0; printf '' | ./run user-add erin --password-stdin >out.txt 2>err.txt || code=$?
equals "--password-stdin with nothing piped exits 1" 1 "$code"
run_code user-add bob --nope
equals "an unknown option exits 2" 2 "$code"

echo "add-device on images without addhost.php (LibreNMS 25.12 and later)"
export FAKE_NO_ADDHOST=1
DA='compose exec -T librenms su -s /bin/sh librenms -c php /opt/librenms/lnms "$@" -- lnms device:add'
expect_call "$DA 192.168.1.1 --v2c -c public" add-device 192.168.1.1 -v 2c -c public
expect_call "$DA 192.168.1.1 --v3 -u snmpuser" add-device 192.168.1.1 --v3 -u snmpuser
expect_call "$DA 10.0.0.1 --v1 -c old" add-device 10.0.0.1 -v v1 -c old
run_code add-device
equals "add-device without a host exits 1" 1 "$code"
run_code add-device 10.0.0.1 -v
equals "-v without a version exits 1" 1 "$code"
unset FAKE_NO_ADDHOST

echo "add-device --csv"
cat > devices.csv <<'CSV'
# a comment
hostname,version,community
core-sw1,2c,secret1
core-sw2
 edge-1 , v1 , old-comm
bad-v3,3,whatever
bad-ver,9,x
CSV
printf 'LIBRENMS_SNMP_COMMUNITY=fallback\n' >> .env
export FAKE_NO_ADDHOST=1
run_code add-device --csv devices.csv
equals "a skipped or failed row makes it exit 1" 1 "$code"
present "row 1 is added" "device:add core-sw1 --v2c -c secret1"
present "a missing version and community use the defaults" "device:add core-sw2 --v2c -c fallback"
present "spaces and a leading v are tolerated" "device:add edge-1 --v1 -c old-comm"
absent "SNMPv3 rows are not guessed" "bad-v3"
absent "unknown versions are skipped" "bad-ver"
check "the summary counts them" grep -q 'Done: 3 added, 2 failed or skipped' out.txt
check "v3 rows say how to add them" grep -q 'SNMPv3 needs credentials' err.txt
unset FAKE_NO_ADDHOST
run_code add-device --csv devices.csv
present "with addhost.php: host, community, version" "php addhost.php \"\$@\" -- add-device core-sw1 secret1 v2c"
run_code add-device --csv missing.csv
equals "a missing file exits 1" 1 "$code"
run_code add-device --csv
equals "no file exits 1" 1 "$code"

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
