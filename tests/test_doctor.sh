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
BASE=$'MYSQL_PASSWORD=secret\nLIBRENMS_SNMP_COMMUNITY=comm'

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

echo "options and environment"
./run doctor --bogus >out.txt 2>err.txt || code=$?
equals "doctor takes no options (exit 2)" 2 "$code"
doctor_with "$BASE"
MYSQL_PASSWORD='' ./run doctor >out.txt 2>&1 || true
check "the environment beats .env (an empty value is ignored, .env wins)" said "MYSQL_PASSWORD is set"

finish
