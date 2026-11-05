#!/usr/bin/env bash
# Linux and macOS: one entry point for the everyday commands
#
#   ./run up                  start the stack
#   ./run down                stop it (the data volumes are kept)
#   ./run restart [service]   restart everything, or one service
#   ./run logs [service]      follow the logs (Ctrl-C to stop)
#   ./run status              show the containers (docker compose ps)
#   ./run backup [--keep N]   back up the database and data to ./backups
#   ./run restore <target>    restore from ./backups: 'latest', a name or a file path (--yes skips the question)
#   ./run validate            run LibreNMS' own self-check (validate.php)
#   ./run configure           apply settings in .env (workers, retention, admin, mail, NetFlow, Telegram); safe to repeat (--dry-run: only show)
#   ./run add-device <host>   add a device (options: -v [2c|3], -c <community>, -u <user>, -a <pass>, -x <priv>)
#   ./run scan <subnet>       auto-discover devices on a subnet using snmp-scan.py (e.g. 192.168.1.0/24)
#   ./run update              back up, pull newer images, restart, self-check; goes back to the old images if the new ones do not start (--no-backup, --no-rollback)
#   ./run doctor [--fix]      check setup (Docker, .env, memory, disk, poller, SNMP, clock, ports); --fix repairs .env permissions; --notify tells Telegram what changed (--notify-all: everything; --notify-test: a test message)
#   ./run verify-backup [name]  restore a backup (default: the newest) into a throw-away database to prove it works
#   ./run lnms [args...]      run LibreNMS CLI commands (e.g. ./run lnms user:add <user> -r admin)
#   ./run user-add <user>     create a user (-r <role> default admin, -e <email>); the password is generated, or -p <pw> / --password-stdin
#   ./run oxidized-setup      pair Oxidized with LibreNMS: create an API token, save it in .env, enable the integration ([user], --force)
#   ./run poll-device <host>  poll one device now with full debug output (host name, IP or device id)
#   ./run snmp-walk <host> [oid]  walk a device's SNMP tree from the LibreNMS container
#   ./run ping-device <host>  check a device with LibreNMS' own ping check
#   ./run sync-inventory      write the LibreNMS devices as the netops inventory.csv (options of scripts/netops-sync.sh)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }

cmd=${1:-help}
[ $# -eq 0 ] || shift

case "$cmd" in
  help|-h|--help) usage; exit 0 ;;
  up|down|restart|logs|status|backup|restore|validate|configure|update|doctor|add-device|scan|lnms|user-add|oxidized-setup|poll-device|snmp-walk|ping-device|sync-inventory|verify-backup) ;;
  *) echo "error: unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac

dry=0
no_backup=0
rollback=1
doctor_fix=0
doctor_notify=0
doctor_notify_test=0
need_docker=1
case "$cmd" in
  doctor)
    # It reports Docker problems itself instead of stopping at the first one.
    for arg in "$@"; do
      case "$arg" in
        --fix) doctor_fix=1 ;;
        --notify) doctor_notify=1 ;;
        --notify-all) doctor_notify=2 ;;
        --notify-test) doctor_notify_test=1 ;;
        *) echo "error: doctor: unknown option: $arg" >&2; exit 2 ;;
      esac
    done
    need_docker=0 ;;
  configure)
    for arg in "$@"; do
      case "$arg" in
        --dry-run) dry=1; need_docker=0 ;;
        *) echo "error: configure: unknown option: $arg" >&2; exit 2 ;;
      esac
    done ;;
  update)
    for arg in "$@"; do
      case "$arg" in
        --no-backup) no_backup=1 ;;
        --no-rollback) rollback=0 ;;
        *) echo "error: update: unknown option: $arg" >&2; exit 2 ;;
      esac
    done ;;
esac

[ -f .env ] || die "no .env found. Run scripts/setup.sh first."
if [ "$need_docker" -eq 1 ]; then
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is not available."
  if ! docker info >/dev/null 2>&1; then
    # If Docker failed due to permissions on Linux and we are not root, attempt auto-elevation via sudo
    if [ "${EUID:-$(id -u)}" -ne 0 ] && [ -z "${NETMONITOR_SUDO_TRIED:-}" ]; then
      case "$(uname -s 2>/dev/null)" in
        Linux)
          docker_err=$(docker info 2>&1 || true)
          if echo "$docker_err" | grep -iqE "permission denied|docker\.sock"; then
            echo "[!] Docker socket requires root privileges (sudo)." >&2
            echo "    Re-running with sudo..." >&2
            export NETMONITOR_SUDO_TRIED=1
            exec sudo "$0" "$cmd" "$@"
          fi
          ;;
      esac
    fi
    die "The Docker daemon is not running."
  fi
fi

# A setting's value: the environment wins, then .env (surrounding quotes removed), then the default.
# This is the order Docker Compose itself uses.
env_get() {
  local key=$1 default=${2:-} value
  value=$(printenv "$key" || true)
  if [ -z "$value" ]; then
    value=$(grep -m1 "^$key=" .env | cut -d= -f2- || true)
    case $value in
      \'*\') value=${value#\'}; value=${value%\'} ;;
      \"*\") value=${value#\"}; value=${value%\"} ;;
    esac
  fi
  printf '%s\n' "${value:-$default}"
}

has_profile() {
  local profiles
  profiles=$(env_get COMPOSE_PROFILES | tr -d ' ')
  case ",$profiles," in *",$1,"*) return 0 ;; esac
  return 1
}

# Run lnms inside the LibreNMS container (with --dry-run: only print what would run).
lnms_run() {
  if [ "$dry" -eq 1 ]; then
    echo "lnms $*"
  else
    docker compose exec -T librenms su -s /bin/sh librenms -c 'php /opt/librenms/lnms "$@"' -- lnms "$@"
  fi
}

# Run a command from /opt/librenms (validate.php, addhost.php, snmp-scan.py) as the librenms user, through the same
# "su -s /bin/sh" as lnms_run: the exec option that picks the user fails on Docker Desktop (macOS), where the host
# GIDs differ from the container's. The first argument only names the shell ($0); the rest are passed on untouched.
librenms_run() {
  local tag=$1 cmd=$2
  shift 2
  docker compose exec -T librenms su -s /bin/sh librenms -c "cd /opt/librenms && $cmd \"\$@\"" -- "$tag" "$@"
}

# add-device. addhost.php was deprecated and is gone from LibreNMS 25.12 and later, so it is used only while the
# image still has it; otherwise the same arguments go to "lnms device:add" ("-v 2c" becomes "--v2c").
has_addhost() { docker compose exec -T librenms test -f /opt/librenms/addhost.php >/dev/null 2>&1; }

# add_one <host> <1|2c> <community>: one v1/v2c device, by whichever tool the image has
add_one() {
  if [ "$ADDHOST_LEGACY" -eq 1 ]; then
    librenms_run add-device 'php addhost.php' "$1" "$3" "v$2"
  else
    lnms_run device:add "$1" "--v$2" -c "$3"
  fi
}

# verify-backup [latest|name]: restore a backup set into a throw-away database to prove that it works. Nothing
# running is touched.
verify_backup() {
  local target=${1:-latest} newest
  target=${target##*/}
  target=${target%-db.sql.gz}
  target=${target%-data.tgz}
  if [ "$target" = latest ]; then
    # shellcheck disable=SC2012  # file names are generated by these scripts (letters, digits, dashes)
    newest=$(ls -1 backups/librenms-*-db.sql.gz 2>/dev/null | sort | tail -n 1 || true)
    [ -n "$newest" ] || die "no backups found in ./backups"
    target=${newest##*/}
    target=${target%-db.sql.gz}
  fi
  case $target in librenms-*) ;; *) target="librenms-$target" ;; esac
  if [ ! -f "backups/$target-db.sql.gz" ] || [ ! -f "backups/$target-data.tgz" ]; then
    die "backups/$target-db.sql.gz and backups/$target-data.tgz must both exist"
  fi
  docker compose run --rm --no-deps -e "BACKUP_NAME=$target" tools /scripts/verify.sh
}

add_device() {
  ADDHOST_LEGACY=0
  if has_addhost; then ADDHOST_LEGACY=1; fi
  if [ "${1:-}" = "--csv" ]; then
    shift
    add_devices_csv "$@"
    return
  fi
  [ $# -ge 1 ] || die "usage: ./run add-device <hostname-or-ip> [options]   or   ./run add-device --csv <file>"
  if [ "$ADDHOST_LEGACY" -eq 1 ]; then
    librenms_run add-device 'php addhost.php' "$@"
    return
  fi
  local n=$# a v
  while [ "$n" -gt 0 ]; do
    a=$1
    shift
    n=$((n - 1))
    case $a in
      -v)
        [ "$n" -gt 0 ] || die "add-device: -v needs a version (1, 2c or 3)"
        v=${1#v}
        shift
        n=$((n - 1))
        set -- "$@" "--v$v" ;;
      *) set -- "$@" "$a" ;;
    esac
  done
  lnms_run device:add "$@"
}

# add-device --csv <file>: one device per line, "hostname[,snmp version[,community]]". Version defaults to 2c,
# the community to LIBRENMS_SNMP_COMMUNITY. Blank lines, lines starting with # and a "hostname" header are skipped.
add_devices_csv() {
  local file=${1:-} line host ver comm added=0 failed=0 first=1
  [ -n "$file" ] || die "usage: ./run add-device --csv <file>   (lines: hostname[,version[,community]])"
  [ -f "$file" ] || die "file not found: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in ''|'#'*) continue ;; esac
    IFS=, read -r host ver comm _ <<<"$line"
    host=$(printf '%s' "$host" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ver=$(printf '%s' "${ver:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    comm=$(printf '%s' "${comm:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ "$first" -eq 1 ]; then
      first=0
      case $host in [Hh]ostname|[Hh]ost) continue ;; esac
    fi
    [ -n "$host" ] || continue
    ver=${ver#v}
    [ -n "$ver" ] || ver=2c
    [ -n "$comm" ] || comm=$(env_get LIBRENMS_SNMP_COMMUNITY)
    case $ver in
      1|2c) ;;
      3) echo "  skipped $host: SNMPv3 needs credentials, add it with ./run add-device $host --v3 -u <user> ..." >&2; failed=$((failed + 1)); continue ;;
      *) echo "  skipped $host: unknown SNMP version '$ver' (use 1 or 2c)" >&2; failed=$((failed + 1)); continue ;;
    esac
    if [ -z "$comm" ]; then
      echo "  skipped $host: no community in the file and LIBRENMS_SNMP_COMMUNITY is empty" >&2
      failed=$((failed + 1))
      continue
    fi
    echo "Adding $host (SNMP $ver)"
    if add_one "$host" "$ver" "$comm"; then added=$((added + 1)); else echo "  failed: $host" >&2; failed=$((failed + 1)); fi
  done < "$file"
  echo "Done: $added added, $failed failed or skipped."
  [ "$failed" -eq 0 ]
}

# Add a value to a list setting unless the list already has it. Entries are compared whole, so
# ".../profiles-stat/live/" does not hide ".../profiles-stat". Repeating the command adds nothing.
list_add() {
  local key=$1 value=$2 optional=${3:-} current=""
  if [ "$dry" -eq 0 ]; then
    current=$(lnms_run config:get "$key" 2>/dev/null || true)
  fi
  if printf '%s\n' "$current" | tr -s '[]",'\''\t ' '\n' | grep -Fx -- "$value" >/dev/null; then
    echo "  $key: $value is already there"
    return 0
  fi
  if lnms_run config:set "$key.+" "$value"; then
    echo "  $key: added $value"
  elif [ -n "$optional" ]; then
    echo "  warning: this LibreNMS version rejected $key.+ (the Netflow graphs do not need it)" >&2
  else
    die "could not set $key"
  fi
}

# A random password of 24 characters from A-Z a-z 0-9 and !#%*+=, with at least one of each kind.
# "|| true": head closes the pipe early and tr then ends with SIGPIPE, which pipefail would turn into a failure.
gen_password() {
  local pw=""
  while :; do
    pw=$( (LC_ALL=C tr -dc 'A-Za-z0-9!#%*+=' </dev/urandom | head -c 24) 2>/dev/null || true)
    [ "${#pw}" -eq 24 ] || continue
    case $pw in *[A-Z]*) ;; *) continue ;; esac
    case $pw in *[a-z]*) ;; *) continue ;; esac
    case $pw in *[0-9]*) ;; *) continue ;; esac
    case $pw in *[\!\#%*+=]*) ;; *) continue ;; esac
    break
  done
  printf '%s' "$pw"
}

# Set KEY=value in .env: replace the first KEY= line, or append one. The file is rewritten in place, so its
# permissions stay as they are. The value goes through the environment so awk never interprets it.
set_env() {
  local key=$1 value=$2 tmp
  tmp=$(mktemp .env.XXXXXX)
  NM_KEY=$key NM_VALUE=$value awk '
    BEGIN { k = ENVIRON["NM_KEY"]; v = ENVIRON["NM_VALUE"]; done = 0 }
    !done && index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' .env > "$tmp"
  cat "$tmp" > .env
  rm -f "$tmp"
}

# The first non-empty line of some command output, for a one-line error message.
first_line() { printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | head -n 1 || true; }

# Did lnms user:add refuse because the user is already there?
user_exists_msg() { printf '%s\n' "$1" | grep -qiE 'taken|already|exists|unique'; }

# lnms user:add with the password handed over on stdin: the container reads it itself, so it never shows up in
# the command line of a process on the host (ps, /proc, shell history).
lnms_user_add() {  # lnms_user_add <password> <user> [lnms options...]
  local pw=$1
  shift
  printf '%s\n' "$pw" | docker compose exec -T librenms su -s /bin/sh librenms -c 'IFS= read -r pw; exec php /opt/librenms/lnms user:add "$@" -p "$pw"' -- lnms "$@"
}

user_add() {
  local user="" password="" role=admin email="" generated=0 out rc=0 from_stdin=0
  while [ $# -gt 0 ]; do
    case $1 in
      -p|--password) [ $# -ge 2 ] || { echo "error: user-add: $1 needs a value" >&2; exit 2; }; password=$2; shift ;;
      --password-stdin) from_stdin=1 ;;
      -r|--role) [ $# -ge 2 ] || { echo "error: user-add: $1 needs a value" >&2; exit 2; }; role=$2; shift ;;
      -e|--email) [ $# -ge 2 ] || { echo "error: user-add: $1 needs a value" >&2; exit 2; }; email=$2; shift ;;
      -*) echo "error: user-add: unknown option: $1" >&2; exit 2 ;;
      *) [ -z "$user" ] || { echo "error: user-add: only one username, got '$user' and '$1'" >&2; exit 2; }; user=$1 ;;
    esac
    shift
  done
  [ -n "$user" ] || die "usage: ./run user-add <username> [-p <password>] [-r admin|global-read|user] [-e <email>]"
  case $role in
    admin|global-read|user) ;;
    *) die "user-add: the role must be admin, global-read or user, not '$role'" ;;
  esac
  if [ "$from_stdin" -eq 1 ]; then
    [ -z "$password" ] || { echo "error: user-add: use either -p or --password-stdin" >&2; exit 2; }
    IFS= read -r password || true
    [ -n "$password" ] || die "user-add: --password-stdin read an empty password"
  fi
  if [ -z "$password" ]; then
    password=$(gen_password)
    generated=1
  fi
  if [ -n "$email" ]; then
    out=$(lnms_user_add "$password" "$user" -r "$role" -e "$email" 2>&1) || rc=$?
  else
    out=$(lnms_user_add "$password" "$user" -r "$role" 2>&1) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if user_exists_msg "$out"; then
      die "user '$user' already exists (or the name is taken)"
    fi
    die "could not create user '$user': $(first_line "$out")"
  fi
  echo "User '$user' created (role: $role)."
  if [ "$generated" -eq 1 ]; then
    echo "Generated secure password for $user: $password"
    echo "Save it now: it is not stored anywhere."
  fi
}

# Create an API token for Oxidized, keep it in .env and switch the LibreNMS side on.
oxidized_setup() {
  local user="" force=0 out rc=0 token arg
  for arg in "$@"; do
    case $arg in
      --force) force=1 ;;
      -*) echo "error: oxidized-setup: unknown option: $arg" >&2; exit 2 ;;
      *) user=$arg ;;
    esac
  done
  has_profile oxidized || die "profile 'oxidized' is not enabled. Add it to COMPOSE_PROFILES in .env first, then run ./run up and ./run oxidized-setup"
  [ -n "$user" ] || user=$(env_get LIBRENMS_ADMIN_USER librenms)
  if [ -n "$(env_get OXIDIZED_LIBRENMS_TOKEN)" ] && [ "$force" -eq 0 ]; then
    echo "OXIDIZED_LIBRENMS_TOKEN is already set in .env (--force creates a new token)."
  else
    echo "Creating the API token 'oxidized' for LibreNMS user '$user'"
    out=$(lnms_run api:token-create --name=oxidized "$user" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      die "could not create the API token for '$user': $(first_line "$out") (name an existing LibreNMS user: ./run oxidized-setup <username>)"
    fi
    token=$(printf '%s\n' "$out" | grep -Eo '[0-9]+\|[A-Za-z0-9]{32,}' | tail -n 1 || true)
    if [ -z "$token" ]; then
      token=$(printf '%s\n' "$out" | grep -E '^[A-Za-z0-9]{32,}$' | tail -n 1 || true)
    fi
    [ -n "$token" ] || die "no token found in the output of api:token-create"
    set_env OXIDIZED_LIBRENMS_TOKEN "$token"
    echo "  Saved OXIDIZED_LIBRENMS_TOKEN in .env"
  fi
  lnms_run config:set oxidized.enabled true
  lnms_run config:set oxidized.url http://oxidized:8888
  echo "Done. Restart Oxidized so that it reads the token: ./run restart oxidized"
}

configure() {
  local workers from running syslog_days eventlog_days admin_user admin_pw out rc pair extra_var extra_key extra_days
  if [ "$dry" -eq 0 ]; then
    running=$(docker compose ps --status running --services)
    case $'\n'"$running"$'\n' in
      *$'\nlibrenms\n'*) ;;
      *) die "LibreNMS is not running. Start it first: ./run up" ;;
    esac
  fi

  workers=$(env_get DISPATCHER_WORKERS 8)
  case $workers in ''|*[!0-9]*) die "DISPATCHER_WORKERS must be a number, not '$workers'" ;; esac
  echo "Poller workers: $workers"
  lnms_run config:set service_poller_workers "$workers"

  syslog_days=$(env_get SYSLOG_PURGE_DAYS 30)
  eventlog_days=$(env_get EVENTLOG_PURGE_DAYS 90)
  case $syslog_days in ''|*[!0-9]*) die "SYSLOG_PURGE_DAYS must be a number of days, not '$syslog_days'" ;; esac
  case $eventlog_days in ''|*[!0-9]*) die "EVENTLOG_PURGE_DAYS must be a number of days, not '$eventlog_days'" ;; esac
  echo "Data retention: syslog $syslog_days days, event log $eventlog_days days"
  lnms_run config:set syslog_purge "$syslog_days"
  lnms_run config:set eventlog_purge "$eventlog_days"
  # Optional extras: nothing is changed in LibreNMS while the variable is empty.
  for pair in AUTHLOG_PURGE_DAYS:authlog_purge ALERTLOG_PURGE_DAYS:alert_log_purge RRD_PURGE_DAYS:rrd_purge; do
    extra_var=${pair%%:*}
    extra_key=${pair#*:}
    extra_days=$(env_get "$extra_var")
    [ -n "$extra_days" ] || continue
    case $extra_days in *[!0-9]*) die "$extra_var must be a number of days, not '$extra_days'" ;; esac
    echo "  $extra_key: $extra_days days"
    lnms_run config:set "$extra_key" "$extra_days"
  done

  admin_user=$(env_get LIBRENMS_ADMIN_USER)
  admin_pw=$(env_get LIBRENMS_ADMIN_PASSWORD)
  if [ -n "$admin_user" ] && [ -n "$admin_pw" ]; then
    echo "Initial admin account:"
    if [ "$dry" -eq 1 ]; then
      echo "lnms user:add $admin_user -p ******** -r admin"
    else
      rc=0
      out=$(lnms_user_add "$admin_pw" "$admin_user" -r admin 2>&1) || rc=$?
      if [ "$rc" -eq 0 ] || user_exists_msg "$out"; then
        echo "  Admin account '$admin_user' is ready."
      else
        echo "  warning: could not create the admin account '$admin_user': $(first_line "$out")" >&2
      fi
    fi
  elif [ -n "$admin_user" ] || [ -n "$admin_pw" ]; then
    echo "warning: LIBRENMS_ADMIN_USER and LIBRENMS_ADMIN_PASSWORD must both be set, admin account skipped." >&2
  else
    echo "Initial admin account: LIBRENMS_ADMIN_USER is not set, skipped."
  fi

  if has_profile mail; then
    echo "Mail relay (profile mail):"
    lnms_run config:set email_backend smtp
    lnms_run config:set email_smtp_host msmtpd
    lnms_run config:set email_smtp_port 2500
    lnms_run config:set email_smtp_auth false
    from=$(env_get SMTP_FROM)
    if [ -n "$from" ]; then lnms_run config:set email_from "$from"; fi
  else
    echo "Mail relay: profile 'mail' is not enabled, skipped."
  fi

  if has_profile netflow; then
    echo "NetFlow (profile netflow):"
    lnms_run config:set nfsen_enable true
    lnms_run config:set nfsen_split_char _
    list_add nfsen_rrds /netflow/nfsen/profiles-stat/live/
    list_add nfsen_rrds /netflow/nfsen/profiles-stat
    list_add nfsen_base /netflow/nfsen/ optional
  else
    echo "NetFlow: profile 'netflow' is not enabled, skipped."
  fi

  # Telegram Alerting
  telegram_on=$(env_get TELEGRAM_ENABLED false)
  if [ "$telegram_on" = "true" ] || [ "$telegram_on" = "1" ]; then
    tg_token=$(env_get TELEGRAM_BOT_TOKEN)
    tg_chat=$(env_get TELEGRAM_CHAT_ID)
    if [ -n "$tg_token" ] && [ -n "$tg_chat" ]; then
      echo "Telegram alerting:"
      lnms_run config:set alerts.telegram.enable true
      lnms_run config:set alerts.telegram.token "$tg_token"
      lnms_run config:set alerts.telegram.chat_id "$tg_chat"
      echo "  Telegram alerts configured for chat ID $tg_chat"
    else
      echo "warning: TELEGRAM_ENABLED is true but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty." >&2
    fi
  else
    echo "Telegram alerting: disabled in .env (TELEGRAM_ENABLED is not true), skipped."
  fi

  echo "Done. If the worker count changed, restart the dispatcher: ./run restart dispatcher"
}

update() {
  local note images_out snapshot repo tag id
  mkdir -p backups
  note=backups/update-$(date +%Y%m%d-%H%M%S).txt
  echo "==> Images before the update (also saved to $note)"
  images_out=$(docker compose images 2>&1 || true)
  printf '%s\n' "$images_out" | tee "$note"
  # repository, tag and image id of every container, for going back: "latest" is overwritten by the pull, but the
  # old image is still on this computer under its id until it is pruned.
  snapshot=$(printf '%s\n' "$images_out" | awk 'NR > 1 && NF >= 4 && $2 != "<none>" && $3 != "<none>" {print $2 " " $3 " " $4}' | sort -u || true)
  if [ "$no_backup" -eq 0 ]; then
    echo "==> Backing up first"
    bash scripts/backup.sh
  else
    echo "==> Skipping the backup (--no-backup)"
  fi
  echo "==> Pulling newer images"
  docker compose pull --ignore-pull-failures
  echo "==> Restarting with the new images"
  if ! docker compose up -d --wait; then
    echo "error: the stack did not become healthy. See: ./run logs" >&2
    if [ "$rollback" -eq 1 ] && [ -n "$snapshot" ]; then
      echo "==> Going back to the previous images" >&2
      while read -r repo tag id; do
        docker tag "$id" "$repo:$tag" >/dev/null 2>&1 || echo "  could not restore $repo:$tag (image $id is gone)" >&2
      done <<<"$snapshot"
      if docker compose up -d --wait; then
        echo "The previous version is running again; the update did not take effect. Try again later with ./run update," >&2
        echo "or pin LIBRENMS_VERSION in .env to a version that works." >&2
      else
        echo "The previous images did not start either (the database may have been upgraded)." >&2
        echo "Restore the backup: ./run restore latest. The old image list is in $note" >&2
      fi
    else
      echo "To go back: put the previous tags from $note into .env and run ./run up;" >&2
      echo "if the database was upgraded, also restore the backup: ./run restore latest" >&2
    fi
    exit 1
  fi
  echo "==> LibreNMS self-check"
  if ! librenms_run validate 'php validate.php'; then
    echo "warning: validate.php reported problems (see above). Nothing was rolled back." >&2
  fi
  echo "==> Done. Previous images are listed in $note"
}

# Look for the mistakes that otherwise show up later as a container that never starts or a port that is
# never published. Prints ok / info / WARN / ERROR lines; exits 1 if there is any ERROR.
# The address people open LibreNMS at, for links in messages: NOTIFY_BASE_URL, else the proxy name, else this host
# and LIBRENMS_PORT. Empty when it cannot be known.
base_url() {
  local url host
  url=$(env_get NOTIFY_BASE_URL)
  if [ -z "$url" ] && has_profile proxy; then
    host=$(env_get CADDY_LIBRENMS_HOST)
    case $host in ''|http://*|*.localhost) ;; *) url="https://$host" ;; esac
  fi
  if [ -z "$url" ]; then url="http://$(hostname):$(env_get LIBRENMS_PORT 8000)"; fi
  printf '%s' "${url%/}"
}
base_url_line() { printf 'LibreNMS: %s' "$(base_url)"; }

# Tell Telegram what CHANGED since the last report, not the whole list every time: new problems, problems that are
# gone, and how many are still open. The last report is kept in backups/.doctor-notify-state (one line per problem:
# the text without digits, a tab, the text), so a number that moves (91 % full, then 92 %) is not a new problem.
# notify_changes <report> <errors> <warnings> <all: 1 sends everything>
# The state is updated only after a successful send (or when nothing needed sending), so a failed send is retried.
notify_changes() {
  local report=$1 errors=$2 warnings=$3 all=$4 state=backups/.doctor-notify-state
  local line key new="" resolved="" cur_keys="" prev_keys="" still=0 total=0 icon text old_key old_text tab
  local red yellow green
  red=$(printf '\xf0\x9f\x94\xb4') yellow=$(printf '\xf0\x9f\x9f\xa1') green=$(printf '\xe2\x9c\x85')
  tab=$(printf '\t')
  mkdir -p backups
  [ -f "$state" ] && prev_keys=$(cut -f1 "$state")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    key=$(printf '%s' "$line" | tr -d '0-9')
    cur_keys="$cur_keys$key"$'\n'
    if [ "$all" -ne 1 ] && printf '%s\n' "$prev_keys" | grep -Fxq -- "$key"; then
      still=$((still + 1))
    else
      case $line in
        "- ERROR "*) icon=$red; line=${line#- ERROR } ;;
        *) icon=$yellow; line=${line#- WARN } ;;
      esac
      new="$new$icon $line"$'\n'
    fi
  done <<<"$report"
  if [ "$all" -ne 1 ] && [ -f "$state" ]; then
    while IFS="$tab" read -r old_key old_text; do
      [ -n "$old_key" ] || continue
      if ! printf '%s' "$cur_keys" | grep -Fxq -- "$old_key"; then
        old_text=${old_text#- }
        old_text=${old_text#ERROR }
        old_text=${old_text#WARN }
        resolved="$resolved$green $old_text"$'\n'
      fi
    done < "$state"
  fi
  if [ -n "$new" ] || [ -n "$resolved" ]; then
    if [ "$errors" -gt 0 ]; then icon=$red; elif [ "$warnings" -gt 0 ]; then icon=$yellow; else icon=$green; fi
    text="$icon netmonitor on $(hostname): $(date '+%Y-%m-%d %H:%M %Z')"$'\n'"$errors error(s), $warnings warning(s) now"$'\n'
    if [ -n "$new" ]; then text="$text"$'\n'"NEW"$'\n'"$new"; fi
    if [ -n "$resolved" ]; then text="$text"$'\n'"RESOLVED"$'\n'"$resolved"; fi
    if [ "$still" -gt 0 ]; then text="$text"$'\n'"STILL OPEN: $still (reported before, unchanged)"$'\n'; fi
    text="$text"$'\n'"$(base_url_line)"
    notify_telegram "$text" || return 1
  fi
  : > "$state"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\t%s\n' "$(printf '%s' "$line" | tr -d '0-9')" "$line" >> "$state"
  done <<<"$report"
}

# Send a text with the Telegram bot of .env. The bot token goes to curl on stdin, as a config line, so it is on
# no command line.
notify_telegram() {
  local token chat text=$1
  token=$(env_get TELEGRAM_BOT_TOKEN)
  chat=$(env_get TELEGRAM_CHAT_ID)
  if [ -z "$token" ] || [ -z "$chat" ]; then
    echo "warning: --notify needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env" >&2
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "warning: --notify needs curl" >&2
    return 1
  fi
  text=${text:0:3800}   # Telegram refuses messages over 4096 characters
  if ! printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" |
      curl -fsS -m 20 --retry 2 --retry-delay 2 -K - --data-urlencode "chat_id=$chat" --data-urlencode "text=$text" >/dev/null; then
    echo "warning: the Telegram message could not be sent" >&2
    return 1
  fi
  echo "Telegram: the report was sent."
}

# Is something listening on this TCP port of the host? (bash's /dev/tcp: no extra tool needed)
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

doctor() {
  local errors=0 warnings=0 have_docker=0 mem mem_mb pool pool_mb pool_n pool_unit cfg running missing svc
  local profiles known p var latest first last range_ok sources seen_names seen_ports count bad src commas
  local name rest port type iface sql rows
  running=""
  local report=""
  d_ok() { printf '  ok    %s\n' "$*"; }
  d_info() { printf '  info  %s\n' "$*"; }
  d_warn() { printf '  WARN  %s\n' "$*"; warnings=$((warnings + 1)); report="$report- WARN $*"$'\n'; }
  d_err() { printf '  ERROR %s\n' "$*"; errors=$((errors + 1)); report="$report- ERROR $*"$'\n'; }
  # is_running <service>: is it in the list of running services?
  is_running() { case $'\n'"$running"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; *) return 1 ;; esac; }

  echo "Docker"
  if ! command -v docker >/dev/null 2>&1; then
    d_err "docker is not installed"
  elif ! docker compose version >/dev/null 2>&1; then
    d_err "Docker Compose v2 is not available ('docker compose version' fails)"
  elif ! docker info >/dev/null 2>&1; then
    d_err "the Docker daemon is not running"
  else
    have_docker=1
    d_ok "$(docker compose version | head -n 1)"
  fi

  echo "Settings (.env)"
  if [ -z "$(env_get MYSQL_PASSWORD)" ]; then d_err "MYSQL_PASSWORD is empty: run scripts/setup.sh"; else d_ok "MYSQL_PASSWORD is set"; fi
  if [ -z "$(env_get LIBRENMS_SNMP_COMMUNITY)" ]; then d_err "LIBRENMS_SNMP_COMMUNITY is empty: run scripts/setup.sh"; else d_ok "LIBRENMS_SNMP_COMMUNITY is set"; fi
  case $(uname -s) in
    Linux|Darwin)
      if [ -n "$(find .env -perm -004 -print)" ]; then
        if [ "$doctor_fix" -eq 1 ]; then
          chmod 600 .env 2>/dev/null || true
          d_ok ".env permissions fixed to 600 (--fix)"
        else
          d_warn ".env can be read by every user of this computer and it holds secrets: chmod 600 .env (or run ./run doctor --fix)"
        fi
      else
        d_ok ".env is private to you"
      fi ;;
  esac

  echo "Profiles"
  profiles=$(env_get COMPOSE_PROFILES | tr -d ' ')
  known=" syslog traps ntopng mail netflow grafana oxidized smokeping proxy tools "
  if [ -z "$profiles" ]; then
    d_info "no optional profile is enabled (COMPOSE_PROFILES is empty)"
  else
    d_ok "enabled: $profiles"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case $known in
        *" $p "*) ;;
        *) d_warn "unknown profile '$p' in COMPOSE_PROFILES (known: syslog, traps, ntopng, mail, netflow, grafana, oxidized, smokeping, proxy, tools)" ;;
      esac
    done <<<"$(printf '%s\n' "$profiles" | tr ',' '\n')"
  fi
  if has_profile mail; then
    if [ -z "$(env_get SMTP_HOST)" ]; then d_err "profile mail is on but SMTP_HOST is empty"; else d_ok "mail relay: SMTP_HOST is set"; fi
  fi
  if has_profile ntopng; then
    if [ "$(uname -s)" != Linux ]; then
      d_warn "profile ntopng needs host networking, which only works on a Linux host (not Docker Desktop)"
    else
      iface=$(env_get NTOPNG_INTERFACE eth0)
      if [ -d "/sys/class/net/$iface" ]; then
        d_ok "ntopng captures on $iface"
      else
        d_err "NTOPNG_INTERFACE '$iface' does not exist on this host (list them with: ip -br link)"
      fi
    fi
  fi
  if has_profile netflow; then
    first=$(env_get NFSEN_FLOW_PORT_FIRST 2055)
    last=$(env_get NFSEN_FLOW_PORT_LAST 2064)
    range_ok=0
    case $first$last in
      ''|*[!0-9]*) d_err "NFSEN_FLOW_PORT_FIRST and NFSEN_FLOW_PORT_LAST must be port numbers" ;;
      *)
        if [ "$first" -gt "$last" ]; then
          d_err "NFSEN_FLOW_PORT_FIRST ($first) is above NFSEN_FLOW_PORT_LAST ($last)"
        else
          range_ok=1
        fi ;;
    esac
    sources=$(env_get NFSEN_SOURCES)
    if [ -z "$sources" ]; then
      d_err "profile netflow is on but NFSEN_SOURCES is empty"
    else
      seen_names=" "
      seen_ports=" "
      count=0
      bad=0
      while IFS= read -r src; do
        [ -n "$src" ] || continue
        count=$((count + 1))
        commas=$(printf '%s' "$src" | tr -cd ',' | wc -c | tr -d ' ')
        if [ "$commas" -lt 3 ]; then
          d_err "NFSEN_SOURCES entry '$src' must be written name,port,colour,type"
          bad=1
          continue
        fi
        name=${src%%,*}
        rest=${src#*,}
        port=${rest%%,*}
        rest=${rest#*,}
        rest=${rest#*,}
        type=${rest%%,*}
        case $name in
          ''|*[!A-Za-z0-9_]*) d_err "source name '$name' may only contain letters, digits and underscores"; bad=1 ;;
        esac
        if [ "${#name}" -gt 19 ]; then d_err "source name '$name' is longer than 19 characters"; bad=1; fi
        case $seen_names in
          *" $name "*) d_err "source name '$name' is used twice"; bad=1 ;;
        esac
        seen_names="$seen_names$name "
        case $port in
          ''|*[!0-9]*) d_err "source '$name': port '$port' is not a number"; bad=1 ;;
          0) ;;
          *)
            if [ "$range_ok" -eq 1 ] && { [ "$port" -lt "$first" ] || [ "$port" -gt "$last" ]; }; then
              d_err "source '$name': port $port is outside the published range $first-$last, so Docker never publishes it"
              bad=1
            fi
            case $seen_ports in
              *" $port "*) d_err "port $port is used by two sources: NfSen needs one port per device"; bad=1 ;;
            esac
            seen_ports="$seen_ports$port " ;;
        esac
        case $type in
          netflow|sflow) ;;
          *) d_warn "source '$name': type '$type' is not netflow or sflow" ;;
        esac
      done <<<"$(printf '%s\n' "$sources" | tr ':' '\n')"
      if [ "$bad" -eq 0 ]; then d_ok "NFSEN_SOURCES: $count source(s), names and ports are valid"; fi
    fi
  fi

  echo "Exposure"
  for var in LIBRENMS_BIND NFSEN_BIND NTOPNG_BIND; do
    case $var in
      NFSEN_BIND) has_profile netflow || continue ;;
      NTOPNG_BIND) has_profile ntopng || continue ;;
    esac
    if [ "$(env_get "$var")" = 0.0.0.0 ]; then
      d_warn "$var=0.0.0.0 serves every network without TLS (see README, HTTPS)"
    fi
  done
  if has_profile syslog || has_profile traps || has_profile netflow; then
    d_info "syslog, trap and flow ports are open to every sender: restrict them (see README, Firewall)"
  fi
  if has_profile oxidized && [ "$(env_get OXIDIZED_NOTIFY_TELEGRAM false)" = true ]; then
    if [ -z "$(env_get TELEGRAM_BOT_TOKEN)" ] || [ -z "$(env_get TELEGRAM_CHAT_ID)" ]; then
      d_warn "OXIDIZED_NOTIFY_TELEGRAM is true but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty: no config-change messages will be sent"
    else
      d_ok "oxidized: config changes are sent to Telegram"
    fi
  fi
  if has_profile proxy; then
    local who auth_user auth_hash
    for who in OXIDIZED SMOKEPING; do
      auth_user=$(env_get "${who}_AUTH_USER")
      auth_hash=$(env_get "${who}_AUTH_HASH")
      if [ -z "$auth_user" ]; then
        continue
      elif [ -z "$auth_hash" ]; then
        d_warn "${who}_AUTH_USER is set but ${who}_AUTH_HASH is empty: nobody can log in to the ${who} name (README, Oxidized)"
      else
        case $auth_hash in
          '$2'[aby]'$'??'$'*) d_ok "${who}: HTTP Basic Auth is on for user $auth_user" ;;
          *) d_warn "${who}_AUTH_HASH does not look like a bcrypt hash (\$2a\$...): make it with caddy hash-password and put it in single quotes in .env" ;;
        esac
      fi
    done
  fi
  latest=""
  [ "$(env_get LIBRENMS_VERSION latest)" != latest ] || latest="$latest librenms"
  if has_profile mail && [ "$(env_get MSMTPD_VERSION latest)" = latest ]; then latest="$latest msmtpd"; fi
  if has_profile netflow && [ "$(env_get NFSEN_VERSION latest)" = latest ]; then latest="$latest nfsen"; fi
  if [ -n "$latest" ]; then d_info "images that follow upstream (tag latest):$latest; pin them once things work (README, Updating)"; fi

  if [ "$have_docker" -eq 1 ]; then
    echo "Memory"
    mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)
    case $mem in
      ''|*[!0-9]*) d_info "could not read how much memory Docker has" ;;
      *)
        mem_mb=$((mem / 1048576))
        if [ "$mem_mb" -lt 3800 ]; then
          d_warn "Docker has $mem_mb MB of memory; about 4 GB is recommended"
        else
          d_ok "Docker has $mem_mb MB of memory"
        fi
        pool=$(env_get MARIADB_BUFFER_POOL_SIZE 512M)
        pool_unit=1
        case $pool in
          *[Gg]) pool_n=${pool%[Gg]}; pool_unit=1024 ;;
          *[Mm]) pool_n=${pool%[Mm]} ;;
          *) pool_n="" ;;
        esac
        case $pool_n in
          ''|*[!0-9]*) d_warn "MARIADB_BUFFER_POOL_SIZE '$pool' should look like 512M or 2G" ;;
          *)
            pool_mb=$((pool_n * pool_unit))
            if [ $((pool_mb * 2)) -gt "$mem_mb" ]; then
              d_warn "MARIADB_BUFFER_POOL_SIZE=$pool is more than half of the $mem_mb MB Docker has"
            else
              d_ok "MARIADB_BUFFER_POOL_SIZE=$pool fits in memory"
            fi ;;
        esac ;;
    esac

    echo "Stack"
    if cfg=$(docker compose config --services 2>&1); then
      d_ok "docker compose accepts the configuration"
      running=$(docker compose ps --status running --services 2>/dev/null || true)
      missing=""
      while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        [ "$svc" != tools ] || continue
        case $'\n'"$running"$'\n' in
          *$'\n'"$svc"$'\n'*) ;;
          *) missing="$missing $svc" ;;
        esac
      done <<<"$cfg"
      if [ -z "$running" ]; then
        d_info "the stack is not running (start it with ./run up)"
      elif [ -n "$missing" ]; then
        d_warn "not running:$missing"
      else
        d_ok "all services are running"
      fi
    else
      d_err "docker compose rejects the configuration: $(printf '%s\n' "$cfg" | head -n 1)"
    fi

    if [ -n "$running" ]; then
      echo "Storage"
      local warn_pct warn_gb sql rows late slow
      warn_pct=$(env_get DOCTOR_DISK_WARN_PCT 80)
      warn_gb=$(env_get DOCTOR_VOLUME_WARN_GB 50)
      case $warn_pct in ''|*[!0-9]*) d_warn "DOCTOR_DISK_WARN_PCT '$warn_pct' is not a number, using 80"; warn_pct=80 ;; esac
      case $warn_gb in ''|*[!0-9]*) d_warn "DOCTOR_VOLUME_WARN_GB '$warn_gb' is not a number, using 50"; warn_gb=50 ;; esac
      # storage_check <volume> <service that mounts it> <path inside that service>
      storage_check() {
        local vol=$1 svc=$2 path=$3 out pct kb gb size
        case $'\n'"$running"$'\n' in
          *$'\n'"$svc"$'\n'*) ;;
          *) d_info "volume $vol: not measured ($svc is not running)"; return 0 ;;
        esac
        out=$(docker compose exec -T "$svc" sh -c 'df -Pk "$1" | tail -n 1; du -sk "$1" 2>/dev/null | cut -f1' sh "$path" 2>/dev/null || true)
        pct=$(printf '%s\n' "$out" | sed -n '1p' | awk '{print $5}' | tr -d '%')
        kb=$(printf '%s\n' "$out" | sed -n '2p' | tr -d ' ')
        case $pct in ''|*[!0-9]*) d_info "volume $vol: could not read its disk usage"; return 0 ;; esac
        case $kb in ''|*[!0-9]*) kb=0 ;; esac
        gb=$((kb / 1048576))
        if [ "$gb" -ge 1 ]; then size="$gb GB"; else size="$((kb / 1024)) MB"; fi
        if [ "$pct" -gt "$warn_pct" ]; then
          d_warn "volume $vol: the disk holding it is $pct% full (limit $warn_pct%): free space, lower the retention days or move Docker's data folder"
        elif [ "$kb" -gt $((warn_gb * 1048576)) ]; then
          d_warn "volume $vol: $size is more than the $warn_gb GB limit (README, Tuning: retention, RRD and flow data)"
        else
          d_ok "volume $vol: $size, disk $pct% full"
        fi
      }
      storage_check data librenms /data
      storage_check db db /var/lib/mysql
      if has_profile netflow; then storage_check nfsen librenms /netflow; fi

      echo "Poller"
      case $'\n'"$running"$'\n' in
        *$'\n'dispatcher$'\n'*)
          sql="SELECT COALESCE(SUM(last_polled IS NULL OR last_polled < NOW() - INTERVAL 15 MINUTE), 0), COALESCE(SUM(last_polled_timetaken > 300), 0) FROM devices WHERE disabled = 0 AND status = 1"
          rows=$(docker compose exec -T db sh -c 'mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "$1"' sh "$sql" 2>/dev/null || true)
          late="" slow=""
          read -r late slow <<<"$rows" || true
          case $late$slow in
            ''|*[!0-9]*) d_info "poller: could not read the device poll times from the database" ;;
            *)
              if [ "$late" -eq 0 ] && [ "$slow" -eq 0 ]; then
                d_ok "poller: every up device was polled within the last 15 minutes"
              fi
              if [ "$late" -gt 0 ]; then
                d_warn "poller: $late device(s) not polled for over 15 minutes (backlog): raise DISPATCHER_WORKERS (now $(env_get DISPATCHER_WORKERS 8)) or MARIADB_BUFFER_POOL_SIZE (now $(env_get MARIADB_BUFFER_POOL_SIZE 512M)); see ./run logs dispatcher"
              fi
              if [ "$slow" -gt 0 ]; then
                d_warn "poller: $slow device(s) took longer than 300 s to poll, more than the 5-minute cycle: raise DISPATCHER_WORKERS or MARIADB_BUFFER_POOL_SIZE, or look at the slowest devices"
              fi ;;
          esac ;;
        *) d_warn "poller: the dispatcher is not running, so no device is polled (start it with ./run up)" ;;
      esac
    fi
  fi

  echo "SNMP"
  local community weak plain
  community=$(env_get LIBRENMS_SNMP_COMMUNITY)
  case $community in
    public|private) d_warn "LIBRENMS_SNMP_COMMUNITY is '$community', the best-known SNMP community: use a secret one, or SNMPv3" ;;
  esac
  if is_running db; then
    sql="SELECT COALESCE(SUM(snmpver IN ('v1','v2c') AND community IN ('public','private')), 0), COALESCE(SUM(snmpver IN ('v1','v2c')), 0) FROM devices WHERE disabled = 0 AND snmp_disable = 0"
    rows=$(docker compose exec -T db sh -c 'mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "$1"' sh "$sql" 2>/dev/null || true)
    weak="" plain=""
    read -r weak plain <<<"$rows" || true
    case $weak$plain in
      ''|*[!0-9]*) d_info "SNMP: could not read the device SNMP versions from the database" ;;
      *)
        if [ "$weak" -gt 0 ]; then
          d_warn "SNMP: $weak device(s) use the community 'public' or 'private': change it on the device and in LibreNMS, or move to SNMPv3"
        fi
        if [ "$plain" -gt 0 ]; then
          d_info "SNMP: $plain device(s) use SNMP v1/v2c, whose community strings are not encrypted; SNMPv3 authPriv is safer"
        else
          d_ok "SNMP: no device uses SNMP v1 or v2c"
        fi ;;
    esac
  fi

  echo "Clock"
  local host_t cont_t skew ntp
  if [ -n "$running" ] && is_running librenms; then
    host_t=$(date +%s)
    cont_t=$(docker compose exec -T librenms date +%s 2>/dev/null | tr -d '\r' || true)
    case $cont_t in
      ''|*[!0-9]*) d_info "clock: could not read the time in the LibreNMS container" ;;
      *)
        skew=$((cont_t - host_t))
        if [ "$skew" -lt 0 ]; then skew=$((0 - skew)); fi
        if [ "$skew" -gt 60 ]; then
          d_warn "clock: the LibreNMS container is $skew s away from this host: graphs, alerts and SNMP timestamps drift (Docker Desktop: restart it; Linux: enable NTP)"
        else
          d_ok "clock: the container and this host agree (within 60 s)"
        fi ;;
    esac
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    if [ "$ntp" = no ]; then d_warn "clock: this host's clock is not synchronized with a time server (timedatectl)"; fi
  fi

  if [ "$have_docker" -eq 1 ]; then
    echo "Host ports"
    local portrow pnum
    # <service>:<profile or ->:<BIND variable or ->:<PORT variable>:<default port>
    for portrow in librenms:-:LIBRENMS_BIND:LIBRENMS_PORT:8000 grafana:grafana:GRAFANA_BIND:GRAFANA_PORT:3001 \
        oxidized:oxidized:OXIDIZED_BIND:OXIDIZED_PORT:8888 smokeping:smokeping:SMOKEPING_BIND:SMOKEPING_PORT:8085 \
        nfsen:netflow:NFSEN_BIND:NFSEN_WEB_PORT:8080 caddy:proxy:-:CADDY_HTTP_PORT:80 caddy:proxy:-:CADDY_HTTPS_PORT:443; do
      IFS=: read -r svc p _ var pnum <<<"$portrow"
      if [ "$p" != "-" ] && ! has_profile "$p"; then continue; fi
      if is_running "$svc"; then continue; fi
      port=$(env_get "$var" "$pnum")
      if port_in_use "$port"; then
        d_warn "port $port ($var) is already used by something else on this host, and $svc is not running: change $var in .env"
      fi
    done
    if ! printf '%s' "$report" | grep -q 'is already used'; then d_ok "no port of a stopped service is taken by another program"; fi
  fi

  if has_profile proxy && is_running caddy && command -v openssl >/dev/null 2>&1; then
    echo "Certificates"
    local cert_host cert_var cert_checked=0
    for cert_var in CADDY_LIBRENMS_HOST CADDY_GRAFANA_HOST CADDY_OXIDIZED_HOST CADDY_SMOKEPING_HOST; do
      cert_host=$(env_get "$cert_var")
      case $cert_host in ''|http://*|*.localhost) continue ;; esac
      cert_checked=1
      if echo | openssl s_client -connect "127.0.0.1:$(env_get CADDY_HTTPS_PORT 443)" -servername "$cert_host" 2>/dev/null |
          openssl x509 -noout -checkend 1209600 >/dev/null 2>&1; then
        d_ok "certificate for $cert_host is valid for at least 14 more days"
      else
        d_warn "certificate for $cert_host could not be read or expires within 14 days (is ./run logs caddy renewing it?)"
      fi
    done
    if [ "$cert_checked" -eq 0 ]; then d_info "certificates: only .localhost names, which Caddy's own CA renews; nothing to check"; fi
  fi

  echo
  echo "$errors error(s), $warnings warning(s)"
  if [ "$doctor_notify" -ge 1 ]; then
    if [ "$doctor_notify" -eq 2 ]; then
      if [ "$((errors + warnings))" -gt 0 ]; then notify_changes "$report" "$errors" "$warnings" 1 || true; fi
    else
      notify_changes "$report" "$errors" "$warnings" 0 || true
    fi
  fi
  if [ "$errors" -gt 0 ]; then exit 1; fi
}

case "$cmd" in
  up) docker compose up -d "$@" ;;
  down)
    [ $# -eq 0 ] || die "down takes no options: it never deletes the data volumes (run 'docker compose down -v' yourself if you really want that)"
    docker compose down ;;
  restart) docker compose restart "$@" ;;
  logs) docker compose logs -f --tail=100 "$@" ;;
  status) docker compose ps "$@" ;;
  backup) exec bash scripts/backup.sh "$@" ;;
  restore) exec bash scripts/restore.sh "$@" ;;
  verify-backup) verify_backup "$@" ;;
  validate) librenms_run validate 'php validate.php' "$@" ;;
  add-device) add_device "$@" ;;
  scan)
    [ $# -ge 1 ] || die "usage: ./run scan <subnet> [options] (e.g. ./run scan 192.168.1.0/24)"
    librenms_run scan 'python3 snmp-scan.py' "$@" ;;
  configure) configure ;;
  update) update ;;
  doctor)
    if [ "$doctor_notify_test" -eq 1 ]; then
      notify_telegram "$(printf '\xe2\x9c\x85') netmonitor on $(hostname): test message, $(date '+%Y-%m-%d %H:%M %Z')"$'\n'"Telegram notifications from ./run doctor --notify work."$'\n'"$(base_url_line)" || exit 1
    else
      doctor
    fi ;;
  lnms)
    [ $# -ge 1 ] || die "usage: ./run lnms <command> [options] (e.g. ./run lnms user:add <user> -r admin)"
    docker compose exec -T librenms su -s /bin/sh librenms -c 'php /opt/librenms/lnms "$@"' -- lnms "$@" ;;
  user-add) user_add "$@" ;;
  oxidized-setup) oxidized_setup "$@" ;;
  poll-device)
    [ $# -ge 1 ] || die "usage: ./run poll-device <hostname-ip-or-device-id>"
    lnms_run device:poll "$@" -vvv ;;
  snmp-walk)
    [ $# -ge 1 ] || die "usage: ./run snmp-walk <host> [oid]"
    lnms_run snmp:walk "$@" ;;
  ping-device)
    [ $# -ge 1 ] || die "usage: ./run ping-device <hostname-or-ip>"
    lnms_run device:ping "$@" ;;
  sync-inventory) exec bash scripts/netops-sync.sh "$@" ;;
esac
