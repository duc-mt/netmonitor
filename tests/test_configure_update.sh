#!/usr/bin/env bash
# ./run configure (settings from .env, safe to repeat) and ./run update (backup first, then pull and restart).
# Needs no Docker (see lib.sh).
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
sandbox

run_code() {
  : > "$FAKE_LOG"
  code=0
  ./run "$@" >out.txt 2>err.txt || code=$?
}
has_line() { grep -Fxq -- "$1" out.txt; }       # an exact line of the output
logged() { grep -Fxq -- "$1" "$FAKE_LOG"; }     # an exact docker call
LNMS='compose exec -T --user librenms librenms lnms'

echo "configure --dry-run without optional profiles"
printf 'MYSQL_PASSWORD=test\nCOMPOSE_PROFILES=\n' > .env
run_code configure --dry-run
equals "exits 0" 0 "$code"
check "sets the default worker count" has_line 'lnms config:set service_poller_workers 8'
check "skips mail" grep -q "profile 'mail' is not enabled" out.txt
check "skips NetFlow" grep -q "profile 'netflow' is not enabled" out.txt
check "needs no docker at all" test ! -s "$FAKE_LOG"

echo "configure --dry-run with the mail and netflow profiles"
printf "MYSQL_PASSWORD=test\nCOMPOSE_PROFILES=mail,netflow\nDISPATCHER_WORKERS=12\nSMTP_FROM='librenms@example.com'\n" > .env
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
check "and explains how to go back" grep -q 'To go back' err.txt
absent "and does not run the self-check" 'php validate.php'
run_code update --bogus
equals "an unknown option exits 2" 2 "$code"

finish
