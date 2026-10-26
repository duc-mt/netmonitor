#!/usr/bin/env bash
# Linux and macOS: write the LibreNMS device list as the inventory.csv of netops and netlog.
#
#   scripts/netops-sync.sh [--netops-output FILE] [--netlog-output FILE] [--only netops|netlog] [--all-types] [--dry-run]
#
# Reads the devices table through the running "db" container (the database login comes from the container's own
# environment, nothing is read from .env). Only network-type devices are exported unless --all-types is given.
# Default targets: $NETOPS_DIR/inventory.csv and $NETLOG_DIR/inventory.csv (../netops and ../netlog next to this
# repository). A tool whose directory does not exist is skipped; --only limits the run to one tool.
# --output FILE is the older name of --netops-output.
# Rows already in an existing file keep their port, credential_group and (netlog) jump_host, so site settings you
# added by hand survive a sync. The old file is kept as inventory.csv.bak. Devices that were removed from LibreNMS
# are removed from the file too. Comment lines of the old file are not carried over (see the .bak).
# Devices whose LibreNMS OS has no netops platform are listed on stderr and left out.
#
# Then:  (cd ../netops && ./run backup)   and   (cd ../netlog && ./run)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }

netops_out="${NETOPS_DIR:-${ROOT_DIR}/../netops}/inventory.csv"
netlog_out="${NETLOG_DIR:-${ROOT_DIR}/../netlog}/inventory.csv"
only=""
netops_explicit=0
netlog_explicit=0
all_types=0
dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --output | --netops-output)
      [ $# -ge 2 ] || die "$1 needs a file name"
      netops_out="$2"; netops_explicit=1; shift ;;
    --netlog-output)
      [ $# -ge 2 ] || die "$1 needs a file name"
      netlog_out="$2"; netlog_explicit=1; shift ;;
    --only)
      [ $# -ge 2 ] || die "--only needs netops or netlog"
      case "$2" in netops | netlog) only="$2" ;; *) die "--only takes netops or netlog" ;; esac
      shift ;;
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

# LibreNMS OS name -> vendor name. netops and netlog accept the same spellings (each folds - and _ itself).
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
    echo "skipped: ${host} (LibreNMS OS '${os}' has no netops/netlog platform)" >&2
    skipped=$((skipped + 1))
  fi
done <<<"$rows"

# build_csv TOOL EXISTING_FILE: the csv text for netops (5 columns) or netlog (6, with jump_host).
build_csv() {
  local tool=$1 existing=$2 host vendor port group jump out
  if [ "$tool" = netlog ]; then
    out="hostname,address,port,vendor,credential_group,jump_host"$'\n'
  else
    out="hostname,address,port,vendor,credential_group"$'\n'
  fi
  while IFS=$'\t' read -r host vendor; do
    [ -n "$host" ] || continue
    port=$(keep "$existing" "$host" 3)
    group=$(keep "$existing" "$host" 5)
    if [ "$tool" = netlog ]; then
      jump=$(keep "$existing" "$host" 6)
      out+="${host},${host},${port},${vendor},${group},${jump}"$'\n'
    else
      out+="${host},${host},${port},${vendor},${group}"$'\n'
    fi
  done <<<"$devices"
  printf '%s' "$out"
}

# write_target TOOL FILE EXPLICIT: write one inventory, or print it on a dry run.
write_target() {
  local tool=$1 file=$2 explicit=$3 dir csv tmp
  dir=$(dirname "$file")
  if [ ! -d "$dir" ]; then
    if [ "$explicit" -eq 1 ] || [ "$only" = "$tool" ]; then
      die "directory not found: $dir (set $(printf %s "$tool" | tr a-z A-Z)_DIR or use --${tool}-output)"
    fi
    echo "skipped ${tool}: directory not found: $dir" >&2
    return 0
  fi
  csv=$(build_csv "$tool" "$file")$'\n'
  if [ "$dry" -eq 1 ]; then
    echo "# --- ${tool}: ${file}"
    printf '%s' "$csv"
    echo "dry run: ${exported} device(s) would be written to ${file}, ${skipped} skipped" >&2
    return 0
  fi
  [ ! -f "$file" ] || cp -p "$file" "${file}.bak"
  tmp="${file}.tmp.$$"
  printf '%s' "$csv" >"$tmp"
  mv "$tmp" "$file"
  echo "${tool}: wrote ${exported} device(s) to ${file} (${skipped} skipped)"
}

[ "$only" = netlog ] || write_target netops "$netops_out" "$netops_explicit"
[ "$only" = netops ] || write_target netlog "$netlog_out" "$netlog_explicit"
