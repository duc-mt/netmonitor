#!/usr/bin/env bash
# ./run doctor: finds the mistakes that otherwise show up later, and stays quiet when all is well.
# Needs no Docker (see lib.sh).
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
sandbox

# doctor_with <.env text>: write .env, run doctor, keep the output in out.txt and the exit code in $code
doctor_with() {
  printf '%s\n' "$1" > .env
  chmod 600 .env
  : > "$FAKE_LOG"
  code=0
  ./run doctor >out.txt 2>err.txt || code=$?
}
said() { grep -Fq -- "$1" out.txt; }
# A port nothing listens on, so that the port check does not depend on what runs on the machine.
FREE=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])' 2>/dev/null || echo 38999)
BASE=$'MYSQL_PASSWORD=secret\nLIBRENMS_SNMP_COMMUNITY=comm\nLIBRENMS_PORT='$FREE

echo "a healthy default setup"
doctor_with "$BASE"
equals "exits 0" 0 "$code"
check "reports no errors and no warnings" said "0 error(s), 0 warning(s)"
check "sees Docker Compose" said "Docker Compose version v2.fake"
check "sees that the stack is running" said "all services are running"
check "the secrets are set" said "MYSQL_PASSWORD is set"

echo "secrets and file permissions"
doctor_with 'MYSQL_PASSWORD=
LIBRENMS_SNMP_COMMUNITY='
equals "empty secrets exit 1" 1 "$code"
check "names MYSQL_PASSWORD" said "MYSQL_PASSWORD is empty"
check "names the SNMP community" said "LIBRENMS_SNMP_COMMUNITY is empty"
case $(uname -s) in
  Linux|Darwin)
    doctor_with "$BASE"
    chmod 644 .env
    ./run doctor >out.txt 2>&1 || true
    check "a world-readable .env is a warning" said "can be read by every user"
    ./run doctor --fix >out.txt 2>&1 || true
    check "doctor --fix repairs .env permissions" said "permissions fixed to 600"
    chmod 600 .env
    ./run doctor >out.txt 2>&1 || true
    if said "can be read by every user"; then fail "a private .env gives no warning"; else pass "a private .env gives no warning"; fi ;;
esac

echo "Docker problems are reported, not fatal to doctor itself"
FAKE_INFO_EXIT=1 doctor_with "$BASE"
equals "a stopped daemon exits 1" 1 "$code"
check "says so" said "the Docker daemon is not running"
FAKE_FAIL_MATCH='compose config' doctor_with "$BASE"
equals "an invalid compose file exits 1" 1 "$code"
check "says compose rejects it" said "docker compose rejects the configuration"
FAKE_RUNNING='' doctor_with "$BASE"
equals "a stopped stack is not an error" 0 "$code"
check "but it is mentioned" said "the stack is not running"
FAKE_RUNNING='librenms' doctor_with "$BASE"
check "services that are down are listed" said "not running: db redis dispatcher"

echo "memory"
FAKE_MEMTOTAL=1073741824 doctor_with "$BASE"
check "1 GB of Docker memory is a warning" said "Docker has 1024 MB of memory"
FAKE_MEMTOTAL=3221225472 doctor_with "$BASE
MARIADB_BUFFER_POOL_SIZE=2G"
check "a buffer pool over half of the memory is a warning" said "more than half"
FAKE_MEMTOTAL=8589934592 doctor_with "$BASE
MARIADB_BUFFER_POOL_SIZE=2G"
check "the same pool is fine with 8 GB" said "MARIADB_BUFFER_POOL_SIZE=2G fits in memory"
doctor_with "$BASE
MARIADB_BUFFER_POOL_SIZE=lots"
check "a malformed pool size is a warning" said "should look like 512M or 2G"

echo "profiles"
doctor_with "$BASE
COMPOSE_PROFILES=syslog,bogus"
check "an unknown profile is a warning" said "unknown profile 'bogus'"
doctor_with "$BASE
COMPOSE_PROFILES=mail"
equals "mail without SMTP_HOST exits 1" 1 "$code"
check "says what is missing" said "SMTP_HOST is empty"
doctor_with "$BASE
COMPOSE_PROFILES=mail
SMTP_HOST=smtp.example.com"
equals "mail with SMTP_HOST is fine" 0 "$code"
if [ "$(uname -s)" = Linux ]; then
  doctor_with "$BASE
COMPOSE_PROFILES=ntopng
NTOPNG_INTERFACE=nope0"
  equals "ntopng on a missing interface exits 1" 1 "$code"
  check "names the interface" said "NTOPNG_INTERFACE 'nope0' does not exist"
else
  doctor_with "$BASE
COMPOSE_PROFILES=ntopng"
  check "ntopng off Linux is a warning" said "only works on a Linux host"
fi

echo "NetFlow sources"
NF="$BASE
COMPOSE_PROFILES=netflow"
doctor_with "$NF
NFSEN_SOURCES='core_rtr,2055,#0000ff,netflow:edge_fw,2056,#ff0000,netflow:lab_sw,2057,#00aa00,sflow'"
equals "three valid sources exit 0" 0 "$code"
check "counts them" said "3 source(s), names and ports are valid"
doctor_with "$NF
NFSEN_SOURCES='old_rtr,0,#0000ff,netflow'"
equals "port 0 (retired device) is allowed" 0 "$code"
doctor_with "$NF
NFSEN_SOURCES='core_rtr,6343,#0000ff,sflow'"
equals "a port outside the published range exits 1" 1 "$code"
check "explains that Docker never publishes it" said "outside the published range 2055-2064"
doctor_with "$NF
NFSEN_FLOW_PORT_FIRST=6343
NFSEN_FLOW_PORT_LAST=6350
NFSEN_SOURCES='core_rtr,6343,#0000ff,sflow'"
equals "a custom range is honoured" 0 "$code"
doctor_with "$NF
NFSEN_SOURCES='a,2055,#0000ff,netflow:b,2055,#ff0000,netflow'"
equals "two sources on one port exit 1" 1 "$code"
check "says one port per device" said "needs one port per device"
doctor_with "$NF
NFSEN_SOURCES='a,2055,#0000ff,netflow:a,2056,#ff0000,netflow'"
equals "a repeated name exits 1" 1 "$code"
check "says which name" said "source name 'a' is used twice"
doctor_with "$NF
NFSEN_SOURCES='core-rtr,2055,#0000ff,netflow'"
equals "a hyphen in a name exits 1" 1 "$code"
check "says what is allowed" said "letters, digits and underscores"
doctor_with "$NF
NFSEN_SOURCES='this_name_is_far_too_long,2055,#0000ff,netflow'"
equals "a name over 19 characters exits 1" 1 "$code"
doctor_with "$NF
NFSEN_SOURCES='core_rtr,2055'"
equals "an entry with missing fields exits 1" 1 "$code"
check "says the format" said "must be written name,port,colour,type"
doctor_with "$NF
NFSEN_SOURCES='core_rtr,2055,#0000ff,pcap'"
check "an unknown type is a warning" said "is not netflow or sflow"
doctor_with "$NF
NFSEN_SOURCES=''"
equals "an empty source list exits 1" 1 "$code"
doctor_with "$NF
NFSEN_FLOW_PORT_FIRST=2070
NFSEN_FLOW_PORT_LAST=2060
NFSEN_SOURCES='a,2065,#0000ff,netflow'"
equals "a reversed range exits 1" 1 "$code"

echo "exposure"
doctor_with "$BASE
LIBRENMS_BIND=0.0.0.0"
check "a web UI on every interface is a warning" said "LIBRENMS_BIND=0.0.0.0 serves every network"
doctor_with "$BASE
NFSEN_BIND=0.0.0.0"
if said "NFSEN_BIND"; then fail "NFSEN_BIND is ignored without the netflow profile"; else pass "NFSEN_BIND is ignored without the netflow profile"; fi
doctor_with "$NF
NFSEN_BIND=0.0.0.0
NFSEN_SOURCES='a,2055,#0000ff,netflow'"
check "NFSEN_BIND counts once the profile is on" said "NFSEN_BIND=0.0.0.0 serves every network"
check "flow ports get a firewall reminder" said "open to every sender"

echo "storage"
doctor_with "$BASE"
check "a healthy volume is reported" said "volume db: 1 GB, disk 10% full"
check "the data volume is measured too" said "volume data: 1 GB, disk 10% full"
if said "nfsen"; then fail "nfsen is only measured with the netflow profile"; else pass "nfsen is only measured with the netflow profile"; fi
doctor_with "$BASE
COMPOSE_PROFILES=netflow
NFSEN_SOURCES='a,2055,#0000ff,netflow'"
check "nfsen is measured with the netflow profile" said "volume nfsen:"
doctor_with "$BASE"
FAKE_DF='overlay 100000000 91000000 9000000 91% /var/lib/mysql\n1048576\n' ./run doctor >out.txt 2>err.txt || true
check "a disk over 80% full is a warning" said "the disk holding it is 91% full (limit 80%)"
doctor_with "$BASE
DOCTOR_DISK_WARN_PCT=95"
FAKE_DF='overlay 100000000 91000000 9000000 91% /x\n1048576\n' ./run doctor >out.txt 2>err.txt || true
if said "is 91% full"; then fail "the disk limit can be raised"; else pass "the disk limit can be raised"; fi
doctor_with "$BASE"
FAKE_DF='overlay 900000000 10000000 890000000 2% /x\n62914560\n' ./run doctor >out.txt 2>err.txt || true
check "a volume over 50 GB is a warning" said "60 GB is more than the 50 GB limit"
doctor_with "$BASE
DOCTOR_VOLUME_WARN_GB=100"
FAKE_DF='overlay 900000000 10000000 890000000 2% /x\n62914560\n' ./run doctor >out.txt 2>err.txt || true
if said "more than the"; then fail "the volume limit can be raised"; else pass "the volume limit can be raised"; fi
doctor_with "$BASE"
FAKE_DF='garbage' ./run doctor >out.txt 2>err.txt || true
check "unreadable disk usage is only info" said "could not read its disk usage"
FAKE_RUNNING='librenms' ./run doctor >out.txt 2>err.txt || true
check "a volume whose service is stopped is not measured" said "volume db: not measured (db is not running)"

echo "poller backlog"
doctor_with "$BASE"
check "no data from the database is only info" said "could not read the device poll times"
FAKE_DB_ROWS='0\t0\n' ./run doctor >out.txt 2>err.txt || true
check "an up-to-date poller is ok" said "every up device was polled within the last 15 minutes"
FAKE_DB_ROWS='3\t0\n' ./run doctor >out.txt 2>err.txt || true
check "late devices are a backlog warning" said "3 device(s) not polled for over 15 minutes (backlog)"
check "the warning names the knobs" said "raise DISPATCHER_WORKERS (now 8)"
FAKE_DB_ROWS='0\t2\n' ./run doctor >out.txt 2>err.txt || true
check "slow devices are a warning" said "2 device(s) took longer than 300 s"
FAKE_RUNNING='db redis librenms' ./run doctor >out.txt 2>err.txt || true
check "a stopped dispatcher is a warning" said "the dispatcher is not running, so no device is polled"
FAKE_RUNNING='' ./run doctor >out.txt 2>err.txt || true
if said "Storage"; then fail "a stopped stack has no storage or poller section"; else pass "a stopped stack has no storage or poller section"; fi

echo "proxy basic auth"
PX="$BASE
COMPOSE_PROFILES=proxy"
doctor_with "$PX"
if said "Basic Auth"; then fail "no auth settings: nothing to report"; else pass "no auth settings: nothing to report"; fi
doctor_with "$PX
OXIDIZED_AUTH_USER=ops
OXIDIZED_AUTH_HASH='\$2a\$14\$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ0123456'"
check "a bcrypt hash turns auth on" said "OXIDIZED: HTTP Basic Auth is on for user ops"
doctor_with "$PX
SMOKEPING_AUTH_USER=ops"
check "a user without a hash is a warning" said "SMOKEPING_AUTH_USER is set but SMOKEPING_AUTH_HASH is empty"
doctor_with "$PX
OXIDIZED_AUTH_USER=ops
OXIDIZED_AUTH_HASH=plaintext"
check "a hash that is not bcrypt is a warning" said "OXIDIZED_AUTH_HASH does not look like a bcrypt hash"
doctor_with "$BASE
OXIDIZED_AUTH_USER=ops"
if said "OXIDIZED_AUTH"; then fail "auth settings are ignored without the proxy profile"; else pass "auth settings are ignored without the proxy profile"; fi

echo "SNMP posture"
doctor_with "$BASE"
check "no data from the database is only info" said "could not read the device SNMP versions"
FAKE_SNMP_ROWS='0\t0\n' ./run doctor >out.txt 2>err.txt || true
check "no v1/v2c device is ok" said "no device uses SNMP v1 or v2c"
FAKE_SNMP_ROWS='2\t5\n' ./run doctor >out.txt 2>err.txt || true
check "default communities on devices are a warning" said "2 device(s) use the community 'public' or 'private'"
check "v1/v2c devices are reported" said "5 device(s) use SNMP v1/v2c"
doctor_with "MYSQL_PASSWORD=secret
LIBRENMS_SNMP_COMMUNITY=public
LIBRENMS_PORT=$FREE"
check "a 'public' community in .env is a warning" said "LIBRENMS_SNMP_COMMUNITY is 'public'"

echo "clock"
doctor_with "$BASE"
check "matching clocks are ok" said "the container and this host agree"
FAKE_CONTAINER_TIME=$(( $(date +%s) + 300 )) ./run doctor >out.txt 2>err.txt || true
check "a skewed container clock is a warning" said "s away from this host"
FAKE_NTP=no ./run doctor >out.txt 2>err.txt || true
check "an unsynchronized host clock is a warning" said "not synchronized with a time server"
FAKE_CONTAINER_TIME=x ./run doctor >out.txt 2>err.txt || true
check "an unreadable container clock is only info" said "could not read the time in the LibreNMS container"

echo "host ports"
doctor_with "$BASE"
check "a quiet host has no port conflict" said "no port of a stopped service is taken"
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import socket, time; s = socket.socket(); s.bind(('127.0.0.1', $FREE)); s.listen(1); time.sleep(20)" &
  listener=$!
  sleep 1
  FAKE_RUNNING='' ./run doctor >out.txt 2>err.txt || true
  check "a taken port of a stopped service is a warning" said "port $FREE (LIBRENMS_PORT) is already used"
  ./run doctor >out.txt 2>err.txt || true
  if said "is already used"; then fail "a running service's own port is fine"; else pass "a running service's own port is fine"; fi
  kill "$listener" 2>/dev/null || true
  wait "$listener" 2>/dev/null || true
else
  echo "  skip  python3 is not installed"
fi

echo "certificates"
CERT="$BASE
COMPOSE_PROFILES=proxy
CADDY_LIBRENMS_HOST=nms.example.com"
doctor_with "$CERT"
FAKE_RUNNING='db redis librenms dispatcher caddy' ./run doctor >out.txt 2>err.txt || true
check "a valid certificate is ok" said "certificate for nms.example.com is valid"
FAKE_CERT_EXIT=1 FAKE_RUNNING='db redis librenms dispatcher caddy' ./run doctor >out.txt 2>err.txt || true
check "an expiring or unreadable certificate is a warning" said "certificate for nms.example.com could not be read or expires within 14 days"
doctor_with "$BASE
COMPOSE_PROFILES=proxy"
FAKE_RUNNING='db redis librenms dispatcher caddy' ./run doctor >out.txt 2>err.txt || true
check ".localhost names need no check" said "only .localhost names"

echo "doctor --notify"
WEAK="MYSQL_PASSWORD=secret
LIBRENMS_SNMP_COMMUNITY=public
LIBRENMS_PORT=$FREE"
TG="TELEGRAM_BOT_TOKEN=123:SECRETTOKEN
TELEGRAM_CHAT_ID=-100555"
notify() {  # notify <.env text> [VAR=value ...]: run doctor --notify, keep the docker/curl log fresh
  printf '%s\n' "$1" > .env; chmod 600 .env
  shift
  : > "$FAKE_LOG"; code=0
  env "$@" ./run doctor --notify >out.txt 2>err.txt || code=$?
}
sent() { grep -c '^curl ' "$FAKE_LOG" || true; }
rm -f backups/.doctor-notify-state

notify "$WEAK
$TG" X=1
equals "a warning does not change the exit code" 0 "$code"
check "the first report is sent" test "$(sent)" -eq 1
check "with the host and a time" grep -Eq 'text=.* netmonitor on .*: 20[0-9]{2}-[0-9]{2}-[0-9]{2} ' "$FAKE_LOG"
check "with the counts" grep -q '0 error(s), 1 warning(s) now' "$FAKE_LOG"
check "the problem is listed as NEW with a yellow mark" grep -q "NEW" "$FAKE_LOG"
check "and names it" grep -q 'LIBRENMS_SNMP_COMMUNITY is' "$FAKE_LOG"
check "with a link to LibreNMS" grep -q "LibreNMS: http://.*:$FREE" "$FAKE_LOG"
check "to the configured chat" grep -q 'chat_id=-100555' "$FAKE_LOG"
check "the bot token is only in the stdin config" grep -q 'bot123:SECRETTOKEN/sendMessage' "$FAKE_LOG.curl"
absent "the bot token is on no command line" "SECRETTOKEN"
check "it says so" said "Telegram: the report was sent"
check "the state is kept" test -s backups/.doctor-notify-state

notify "$WEAK
$TG" X=1
check "the same problem again sends nothing" test "$(sent)" -eq 0

notify "$WEAK
$TG
NOTIFY_BASE_URL=https://nms.example.com/" X=1
check "an unchanged problem still sends nothing (the link does not matter)" test "$(sent)" -eq 0

notify "$WEAK
$TG
DOCTOR_VOLUME_WARN_GB=x" X=1
check "a new problem is sent as NEW" grep -q 'DOCTOR_VOLUME_WARN_GB' "$FAKE_LOG"
check "and the old one is counted as still open" grep -q 'STILL OPEN: 1' "$FAKE_LOG"
check "with the configured link" test "$(sent)" -eq 1

notify "MYSQL_PASSWORD=secret
LIBRENMS_SNMP_COMMUNITY=comm
LIBRENMS_PORT=$FREE
NOTIFY_BASE_URL=https://nms.example.com/
$TG" X=1
check "solved problems are reported as RESOLVED" grep -q 'RESOLVED' "$FAKE_LOG"
check "with their text" grep -q 'LIBRENMS_SNMP_COMMUNITY is' "$FAKE_LOG"
check "and a green mark instead of a severity word" test -z "$(grep -E 'RESOLVED' -A3 "$FAKE_LOG" | grep -E ' (WARN|ERROR) ')"
check "the link uses NOTIFY_BASE_URL without a double slash" grep -q 'LibreNMS: https://nms.example.com$' "$FAKE_LOG"
check "no problems are left" grep -q '0 error(s), 0 warning(s) now' "$FAKE_LOG"
notify "MYSQL_PASSWORD=secret
LIBRENMS_SNMP_COMMUNITY=comm
LIBRENMS_PORT=$FREE
$TG" X=1
check "a healthy setup that was healthy sends nothing" test "$(sent)" -eq 0

echo "a moving number is not a new problem"
rm -f backups/.doctor-notify-state
printf '%s\n' "$BASE
$TG" > .env; chmod 600 .env
: > "$FAKE_LOG"
FAKE_DF='overlay 100000000 91000000 9000000 91% /x\n1048576\n' ./run doctor --notify >out.txt 2>err.txt || true
check "the first report is sent" test "$(sent)" -eq 1
: > "$FAKE_LOG"
FAKE_DF='overlay 100000000 93000000 7000000 93% /x\n1048576\n' ./run doctor --notify >out.txt 2>err.txt || true
check "91% becoming 93% is not reported again" test "$(sent)" -eq 0

echo "a failed send is retried"
rm -f backups/.doctor-notify-state
notify "$WEAK
$TG" FAKE_CURL_EXIT=22
check "a failed send is reported" grep -q 'could not be sent' err.txt
check "and the exit code is not changed" test "$code" -eq 0
notify "$WEAK
$TG" X=1
check "the next run sends the report again" test "$(sent)" -eq 1

echo "doctor --notify-all"
notify "$WEAK
$TG" X=1
check "an unchanged problem is not sent by --notify" test "$(sent)" -eq 0
printf '%s\n' "$WEAK
$TG" > .env; : > "$FAKE_LOG"
./run doctor --notify-all >out.txt 2>err.txt || true
check "--notify-all sends everything again" test "$(sent)" -eq 1

echo "doctor --notify-test"
printf '%s\n' "$WEAK
$TG" > .env; : > "$FAKE_LOG"
code=0; ./run doctor --notify-test >out.txt 2>err.txt || code=$?
equals "exits 0" 0 "$code"
check "sends a test message" grep -q 'test message' "$FAKE_LOG"
check "without running the checks" test -z "$(grep 'compose ps' "$FAKE_LOG")"
printf '%s\n' "$WEAK" > .env; : > "$FAKE_LOG"
code=0; ./run doctor --notify-test >out.txt 2>err.txt || code=$?
equals "without a bot it exits 1" 1 "$code"
check "and says what is missing" grep -q 'needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID' err.txt
printf '%s\n' "$WEAK
$TG" > .env; : > "$FAKE_LOG"
code=0; FAKE_CURL_EXIT=22 ./run doctor --notify-test >out.txt 2>err.txt || code=$?
equals "a failed test message exits 1" 1 "$code"
printf '%s\n' "$WEAK" > .env
rm -f backups/.doctor-notify-state
: > "$FAKE_LOG"
./run doctor --notify >out.txt 2>err.txt || true
check "no bot token: --notify says what is missing" grep -q 'needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID' err.txt

echo "oxidized notifications"
doctor_with "$BASE
COMPOSE_PROFILES=oxidized
OXIDIZED_NOTIFY_TELEGRAM=true"
check "notifications without a bot are a warning" said "OXIDIZED_NOTIFY_TELEGRAM is true but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty"
doctor_with "$BASE
COMPOSE_PROFILES=oxidized
OXIDIZED_NOTIFY_TELEGRAM=true
TELEGRAM_BOT_TOKEN=1:a
TELEGRAM_CHAT_ID=5"
check "with a bot it is ok" said "config changes are sent to Telegram"

echo "options and environment"
./run doctor --bogus >out.txt 2>err.txt || code=$?
equals "doctor takes no options (exit 2)" 2 "$code"
doctor_with "$BASE"
MYSQL_PASSWORD='' ./run doctor >out.txt 2>&1 || true
check "the environment beats .env (an empty value is ignored, .env wins)" said "MYSQL_PASSWORD is set"

finish
