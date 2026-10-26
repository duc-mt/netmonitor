#!/usr/bin/env bash
# Linux and macOS: write the LibreNMS device list as the inventory.csv of netops.
#
#   scripts/netops-sync.sh [--output FILE] [--all-types] [--dry-run]
#
# Reads the devices table through the running "db" container (the database login comes from the container's own
# environment, nothing is read from .env). Only network-type devices are exported unless --all-types is given.
# Default target: $NETOPS_DIR/inventory.csv (../netops next to this repository).
# Rows already in an existing file keep their port and credential_group, so site settings you added by hand
# survive a sync. The old file is kept as inventory.csv.bak. Devices that were removed from LibreNMS are removed
# from the file too. Comment lines of the old file are not carried over (see the .bak).
# Devices whose LibreNMS OS has no netops platform are listed on stderr and left out.
#
# Then:  cd ../netops && ./run backup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }

output="${NETOPS_DIR:-${ROOT_DIR}/../netops}/inventory.csv"
all_types=0
dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --output)
      [ $# -ge 2 ] || die "--output needs a file name"
      output="$2"; shift ;;
    --all-types) all_types=1 ;;
    --dry-run) dry=1 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || die "docker not found"

where="disabled = 0"
if [ "$all_types" -eq 0 ]; then
  where="${where} AND type IN ('network','firewall','wireless','loadbalancer')"
fi
sql="SELECT hostname, os FROM devices WHERE ${where} ORDER BY hostname"

# The mariadb client runs inside the db container and logs in with the container's own MARIADB_* variables.
rows=$(docker compose exec -T db sh -c \
  'mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "$1"' sh "$sql") \
  || die "could not query the database (is the stack running? ./run status)"

# LibreNMS OS name -> netops vendor name.
vendor_for() {
  case "$1" in
    ios | iosxe | iosxr | nxos) echo cisco ;;
    ciscosb) echo cisco-sb ;;
    asa | ftd) echo cisco-asa ;;
    junos) echo junos ;;
    vrp) echo huawei ;;
    comware) echo h3c ;;
    fortigate) echo fortios ;;
    eos) echo arista ;;
    vyos) echo vyos ;;
    ruijie) echo ruijie ;;
    arubaos-cx | aos-cx) echo aos-cx ;;
    procurve | arubaos) echo aos-s ;;
    gaia | checkpoint) echo checkpoint ;;
    panos) echo paloalto ;;
    pfsense) echo pfsense ;;
    sfos) echo sophos ;;
    routeros) echo mikrotik ;;
    *) return 1 ;;
  esac
}

# keep FILE HOST COLUMN: the value of a column for HOST in an existing inventory (empty if none).
keep() {
  [ -f "$1" ] || return 0
  awk -F, -v h="$2" -v c="$3" '$1 == h && $1 !~ /^#/ && $1 != "hostname" { print $c; exit }' "$1"
}

# Devices that can be exported: "host<TAB>vendor" lines.
devices=""
exported=0
skipped=0
while IFS=$'\t' read -r host os; do
  [ -n "$host" ] || continue
  # A host name with a comma, quote or space cannot be written safely to the csv.
  case "$host" in
    *[,\"\ ]*) echo "skipped: unusable host name '$host'" >&2; skipped=$((skipped + 1)); continue ;;
  esac
  if vendor=$(vendor_for "$os"); then
    devices+="${host}"$'\t'"${vendor}"$'\n'
    exported=$((exported + 1))
  else
    echo "skipped: ${host} (LibreNMS OS '${os}' has no netops platform)" >&2
    skipped=$((skipped + 1))
  fi
done <<<"$rows"

# build_csv EXISTING_FILE: the csv text for netops (5 columns).
build_csv() {
  local existing=$1 host vendor port group out
  out="hostname,address,port,vendor,credential_group"$'\n'
  while IFS=$'\t' read -r host vendor; do
    [ -n "$host" ] || continue
    port=$(keep "$existing" "$host" 3)
    group=$(keep "$existing" "$host" 5)
    out+="${host},${host},${port},${vendor},${group}"$'\n'
  done <<<"$devices"
  printf '%s' "$out"
}

dir=$(dirname "$output")
[ -d "$dir" ] || die "directory not found: $dir (set NETOPS_DIR or use --output)"

csv=$(build_csv "$output")
if [ "$dry" -eq 1 ]; then
  printf '%s' "$csv"
  echo "dry run: ${exported} device(s) would be written to ${output}, ${skipped} skipped" >&2
  exit 0
fi

[ ! -f "$output" ] || cp -p "$output" "${output}.bak"
tmp="${output}.tmp.$$"
printf '%s' "$csv" >"$tmp"
mv "$tmp" "$output"
echo "wrote ${exported} device(s) to ${output} (${skipped} skipped)"
