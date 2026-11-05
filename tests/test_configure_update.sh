#!/usr/bin/env bash
# ./run configure (settings from .env, safe to repeat) and ./run update (backup first, then pull and restart).
# Needs no Docker (see lib.sh).
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
sandbox

run_code() {
  : > "$FAKE_LOG"
  : > "$FAKE_LOG.stdin"
  code=0
  ./run "$@" >out.txt 2>err.txt || code=$?
}
has_line() { grep -Fxq -- "$1" out.txt; }       # an exact line of the output
present_line() { grep -qF -- "$1" "$FAKE_LOG"; }
logged() { grep -Fxq -- "$1" "$FAKE_LOG"; }     # an exact docker call
LNMS='compose exec -T librenms su -s /bin/sh librenms -c php /opt/librenms/lnms "$@" -- lnms'

echo "configure --dry-run without optional profiles"
printf 'MYSQL_PASSWORD=test\nCOMPOSE_PROFILES=\n' > .env
run_code configure --dry-run
equals "exits 0" 0 "$code"
check "sets the default worker count" has_line 'lnms config:set service_poller_workers 8'
check "skips mail" grep -q "profile 'mail' is not enabled" out.txt
check "skips NetFlow" grep -q "profile 'netflow' is not enabled" out.txt
check "needs no docker at all" test ! -s "$FAKE_LOG"

echo "configure --dry-run with the mail and netflow profiles"
printf "MYSQL_PASSWORD=test\nCOMPOSE_PROFILES=mail,netflow\nDISPATCHER_WORKERS=12\nSMTP_FROM='librenms@example.com'\nTELEGRAM_ENABLED=true\nTELEGRAM_BOT_TOKEN='1234:TOKEN'\nTELEGRAM_CHAT_ID='-100123'\n" > .env
run_code configure --dry-run
check "worker count comes from .env" has_line 'lnms config:set service_poller_workers 12'
check "mail backend" has_line 'lnms config:set email_backend smtp'
check "mail host is the relay" has_line 'lnms config:set email_smtp_host msmtpd'
check "mail port is the relay's" has_line 'lnms config:set email_smtp_port 2500'
check "mail needs no login" has_line 'lnms config:set email_smtp_auth false'
check "sender comes from .env, quotes removed" has_line 'lnms config:set email_from librenms@example.com'
check "NetFlow is enabled" has_line 'lnms config:set nfsen_enable true'
check "split character" has_line 'lnms config:set nfsen_split_char _'
check "RRD folder: live profile" has_line 'lnms config:set nfsen_rrds.+ /netflow/nfsen/profiles-stat/live/'
check "RRD folder: all profiles" has_line 'lnms config:set nfsen_rrds.+ /netflow/nfsen/profiles-stat'
check "NfSen base folder" has_line 'lnms config:set nfsen_base.+ /netflow/nfsen/'
check "Telegram enabled" has_line 'lnms config:set alerts.telegram.enable true'
check "Telegram token" has_line 'lnms config:set alerts.telegram.token 1234:TOKEN'
check "Telegram chat" has_line 'lnms config:set alerts.telegram.chat_id -100123'

echo "where the values come from"
DISPATCHER_WORKERS=3 run_code configure --dry-run
check "the environment beats .env" has_line 'lnms config:set service_poller_workers 3'
printf 'MYSQL_PASSWORD=test\nCOMPOSE_PROFILES=syslog, netflow\n' > .env
run_code configure --dry-run
check "spaces in COMPOSE_PROFILES are ignored" has_line 'lnms config:set nfsen_enable true'
printf 'MYSQL_PASSWORD=test\nDISPATCHER_WORKERS=many\n' > .env
run_code configure --dry-run
equals "a non-numeric worker count exits 1" 1 "$code"
check "and says which setting" grep -q 'DISPATCHER_WORKERS must be a number' err.txt
run_code configure --bogus
equals "an unknown option exits 2" 2 "$code"

echo "configure against the (fake) container"
printf 'MYSQL_PASSWORD=test\nCOMPOSE_PROFILES=netflow\n' > .env
run_code configure
equals "exits 0" 0 "$code"
check "worker count is applied" logged "$LNMS config:set service_poller_workers 8"
check "NetFlow is enabled" logged "$LNMS config:set nfsen_enable true"
check "both RRD folders are added to an empty list" logged "$LNMS config:set nfsen_rrds.+ /netflow/nfsen/profiles-stat/live/"
check "second RRD folder" logged "$LNMS config:set nfsen_rrds.+ /netflow/nfsen/profiles-stat"

echo "configure twice adds nothing twice (whole-entry matching)"
FAKE_CONFIG_GET='["/netflow/nfsen/profiles-stat/live/"]' run_code configure
check "an existing live/ entry is left alone" test "$(grep -cFx "$LNMS config:set nfsen_rrds.+ /netflow/nfsen/profiles-stat/live/" "$FAKE_LOG" || true)" = 0
check "but the shorter folder is still added (it is a different entry)" logged "$LNMS config:set nfsen_rrds.+ /netflow/nfsen/profiles-stat"
FAKE_CONFIG_GET='["/netflow/nfsen/profiles-stat/live/","/netflow/nfsen/profiles-stat","/netflow/nfsen/"]' run_code configure
equals "everything present: no list is touched" 0 "$(grep -c '\.+' "$FAKE_LOG" || true)"
FAKE_CONFIG_GET=$'[\n    "/netflow/nfsen/profiles-stat/live/",\n    "/netflow/nfsen/profiles-stat",\n    "/netflow/nfsen/"\n]' run_code configure
equals "same with pretty-printed output" 0 "$(grep -c '\.+' "$FAKE_LOG" || true)"
FAKE_CONFIG_GET='Array ( [0] => /netflow/nfsen/profiles-stat/live/ [1] => /netflow/nfsen/profiles-stat [2] => /netflow/nfsen/ )' run_code configure
equals "same with PHP-style output" 0 "$(grep -c '\.+' "$FAKE_LOG" || true)"

echo "configure when things go wrong"
FAKE_RUNNING=db run_code configure
equals "LibreNMS not running exits 1" 1 "$code"
check "and says how to start it" grep -E -q '(run|run\.sh) up' err.txt
FAKE_FAIL_MATCH='nfsen_base.+' run_code configure
equals "a rejected nfsen_base is only a warning" 0 "$code"
check "and the warning says so" grep -q 'rejected nfsen_base' err.txt
FAKE_FAIL_MATCH='nfsen_enable' run_code configure
equals "any other rejected setting is fatal" 1 "$code"

echo "data retention"
printf 'MYSQL_PASSWORD=test\nCOMPOSE_PROFILES=\n' > .env
run_code configure --dry-run
check "default syslog retention" has_line 'lnms config:set syslog_purge 30'
check "default event log retention" has_line 'lnms config:set eventlog_purge 90'
printf 'MYSQL_PASSWORD=test\nSYSLOG_PURGE_DAYS=7\nEVENTLOG_PURGE_DAYS=14\n' > .env
run_code configure --dry-run
check "syslog retention comes from .env" has_line 'lnms config:set syslog_purge 7'
check "event log retention comes from .env" has_line 'lnms config:set eventlog_purge 14'
printf 'MYSQL_PASSWORD=test\nSYSLOG_PURGE_DAYS=soon\n' > .env
run_code configure --dry-run
equals "a non-numeric retention exits 1" 1 "$code"
check "and names the setting" grep -q 'SYSLOG_PURGE_DAYS' err.txt

echo "optional retention"
printf 'MYSQL_PASSWORD=test\n' > .env
run_code configure --dry-run
absent_out() { if grep -q -- "$1" out.txt; then fail "$2"; else pass "$2"; fi; }
absent_out 'authlog_purge' "empty extras change nothing in LibreNMS"
printf 'MYSQL_PASSWORD=test\nAUTHLOG_PURGE_DAYS=14\nALERTLOG_PURGE_DAYS=180\nRRD_PURGE_DAYS=400\n' > .env
run_code configure --dry-run
check "login history retention" has_line 'lnms config:set authlog_purge 14'
check "alert history retention" has_line 'lnms config:set alert_log_purge 180'
check "RRD retention" has_line 'lnms config:set rrd_purge 400'
printf 'MYSQL_PASSWORD=test\nRRD_PURGE_DAYS=x\n' > .env
run_code configure --dry-run
equals "a non-numeric extra exits 1" 1 "$code"
check "and names it" grep -q 'RRD_PURGE_DAYS' err.txt

echo "headless admin account"
printf 'MYSQL_PASSWORD=test\n' > .env
run_code configure --dry-run
check "no admin settings: skipped" grep -q 'LIBRENMS_ADMIN_USER is not set, skipped' out.txt
printf 'MYSQL_PASSWORD=test\nLIBRENMS_ADMIN_USER=root1\nLIBRENMS_ADMIN_PASSWORD='"'"'S3cret!pass'"'"'\n' > .env
run_code configure --dry-run
check "dry run shows the user add" has_line 'lnms user:add root1 -p ******** -r admin'
check "dry run does not print the password" test -z "$(grep 'S3cret' out.txt)"
run_code configure
equals "creates the admin account" 0 "$code"
check "user:add is called for the admin" present_line "-- lnms root1 -r admin"
equals "the password from .env goes in on stdin" "S3cret!pass" "$(stdin_log)"
absent "and is on no command line" "S3cret"
check "says the account is ready" grep -q "Admin account 'root1' is ready" out.txt
FAKE_USER_ADD_ERR='The username has already been taken.' run_code configure
equals "an existing admin is not an error" 0 "$code"
check "and is reported as ready" grep -q "Admin account 'root1' is ready" out.txt
FAKE_USER_ADD_ERR='Password too weak' run_code configure
equals "another failure is only a warning" 0 "$code"
check "and shows the reason" grep -q 'Password too weak' err.txt
printf 'MYSQL_PASSWORD=test\nLIBRENMS_ADMIN_USER=root1\n' > .env
run_code configure --dry-run
check "a user without a password is refused with a warning" grep -q 'must both be set' err.txt

echo "oxidized-setup"
printf 'MYSQL_PASSWORD=test\nCOMPOSE_PROFILES=\n' > .env
run_code oxidized-setup
equals "without the oxidized profile exits 1" 1 "$code"
check "and says how to enable it" grep -q "profile 'oxidized' is not enabled" err.txt
equals "and calls nothing" "" "$(calls)"
printf 'MYSQL_PASSWORD=test\nCOMPOSE_PROFILES=oxidized\nOXIDIZED_LIBRENMS_TOKEN=\nOTHER=keep\n' > .env
run_code oxidized-setup
equals "exits 0" 0 "$code"
check "creates the token for the default user" logged "$LNMS api:token-create --name=oxidized librenms"
check "saves the token in .env" grep -Fxq 'OXIDIZED_LIBRENMS_TOKEN=7|abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN' .env
check "keeps the other settings" grep -Fxq 'OTHER=keep' .env
equals "the token is in .env once" 1 "$(grep -c '^OXIDIZED_LIBRENMS_TOKEN=' .env)"
check "enables the integration" logged "$LNMS config:set oxidized.enabled true"
check "sets the Oxidized URL" logged "$LNMS config:set oxidized.url http://oxidized:8888"
check "tells you to restart Oxidized" grep -q './run restart oxidized' out.txt
run_code oxidized-setup
absent "a second run keeps the token" "api:token-create"
check "and says how to replace it" grep -q -- '--force' out.txt
FAKE_API_TOKEN='9|ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvutsrqponm' run_code oxidized-setup --force admin2
check "--force and a user name create a new token" logged "$LNMS api:token-create --name=oxidized admin2"
check "and replace the old one" grep -Fxq 'OXIDIZED_LIBRENMS_TOKEN=9|ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvutsrqponm' .env
FAKE_FAIL_MATCH='api:token-create' run_code oxidized-setup --force ghost
equals "a failing token command exits 1" 1 "$code"
check "and suggests naming an existing user" grep -q 'oxidized-setup <username>' err.txt
check "and leaves the old token alone" grep -Fxq 'OXIDIZED_LIBRENMS_TOKEN=9|ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvutsrqponm' .env

echo "update"
printf 'MYSQL_PASSWORD=test\n' > .env
run_code update
equals "exits 0" 0 "$code"
first() { grep -n -m1 -- "$1" "$FAKE_LOG" | cut -d: -f1 || true; }
lastn() { grep -n -- "$1" "$FAKE_LOG" | tail -n 1 | cut -d: -f1 || true; }
n_images=$(first '^compose images$')
n_backup=$(first '/scripts/backup.sh')
n_pull=$(first '^compose pull --ignore-pull-failures$')
n_up=$(lastn '^compose up -d --wait$')
n_validate=$(first 'php validate.php')
if [ -n "$n_images" ] && [ -n "$n_backup" ] && [ -n "$n_pull" ] && [ -n "$n_up" ] && [ -n "$n_validate" ] \
   && [ "$n_images" -lt "$n_backup" ] && [ "$n_backup" -lt "$n_pull" ] && [ "$n_pull" -lt "$n_up" ] && [ "$n_up" -lt "$n_validate" ]; then
  pass "order: list images, back up, pull, restart, self-check"
else
  fail "order: list images, back up, pull, restart, self-check"
  cat "$FAKE_LOG"
fi
found=0
for f in backups/update-*.txt; do
  if [ -e "$f" ] && grep -q REPOSITORY "$f"; then found=1; fi
done
equals "the previous images are saved for a rollback" 1 "$found"

run_code update --no-backup
equals "--no-backup exits 0" 0 "$code"
absent "--no-backup makes no backup" '/scripts/backup.sh'
present "--no-backup still pulls" 'compose pull --ignore-pull-failures'

FAKE_UP_EXIT=1 run_code update --no-backup
equals "an unhealthy restart exits 1" 1 "$code"
check "and explains how to go back" grep -q 'Restore the backup: ./run restore latest' err.txt
absent "and does not run the self-check" 'php validate.php'
echo "update goes back to the old images when the new ones do not start"
rm -f "$FAKE_LOG.upfailed"
FAKE_UP_FAIL_ONCE=1 run_code update --no-backup
equals "the update still fails (exit 1)" 1 "$code"
check "the old image of librenms is tagged again" logged "tag abc123def456 librenms/librenms:latest"
check "the old image of the database is tagged again" logged "tag fed654cba321 mariadb:10.11"
check "the stack is started a second time" test "$(grep -c '^compose up -d --wait$' "$FAKE_LOG")" -eq 2
check "it says the previous version runs again" grep -q 'previous version is running again' err.txt
check "and does not run the self-check" test -z "$(grep 'php validate.php' "$FAKE_LOG")"
FAKE_UP_EXIT=1 run_code update --no-backup
equals "old images that do not start either: exit 1" 1 "$code"
check "then the backup is suggested" grep -q 'Restore the backup: ./run restore latest' err.txt
FAKE_UP_EXIT=1 run_code update --no-backup --no-rollback
absent "--no-rollback does not tag anything" "compose tag"
check "--no-rollback keeps the manual instructions" grep -q 'put the previous tags' err.txt

run_code update --bogus
equals "an unknown option exits 2" 2 "$code"

finish
