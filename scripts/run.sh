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
#   ./run configure           apply the settings in .env to LibreNMS (workers, mail, NetFlow); safe to repeat (--dry-run: only show)
#   ./run update              back up, pull newer images, restart, self-check (--no-backup skips the backup)
#   ./run doctor              check the setup (Docker, .env, profiles, memory) before or after the first start
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }

cmd=${1:-help}
[ $# -eq 0 ] || shift

case "$cmd" in
  help|-h|--help) usage; exit 0 ;;
  up|down|restart|logs|status|backup|restore|validate|configure|update|doctor) ;;
  *) echo "error: unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac

dry=0
no_backup=0
need_docker=1
case "$cmd" in
  doctor)
    # It reports Docker problems itself instead of stopping at the first one.
    [ $# -eq 0 ] || { echo "error: doctor takes no options" >&2; exit 2; }
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
        *) echo "error: update: unknown option: $arg" >&2; exit 2 ;;
      esac
    done ;;
esac

[ -f .env ] || die "no .env found. Run scripts/setup.sh first."
if [ "$need_docker" -eq 1 ]; then
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is not available."
  docker info >/dev/null 2>&1 || die "The Docker daemon is not running."
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
    docker compose exec -T --user librenms librenms lnms "$@"
  fi
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

configure() {
  local workers from running
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

  echo "Done. If the worker count changed, restart the dispatcher: ./run restart dispatcher"
}

update() {
  local note
  mkdir -p backups
  note=backups/update-$(date +%Y%m%d-%H%M%S).txt
  echo "==> Images before the update (also saved to $note)"
  docker compose images | tee "$note"
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
    echo "To go back: put the previous tags from $note into .env and run ./run up;" >&2
    echo "if the database was upgraded, also restore the backup: ./run restore latest" >&2
    exit 1
  fi
  echo "==> LibreNMS self-check"
  if ! docker compose exec -T --user librenms -w /opt/librenms librenms php validate.php; then
    echo "warning: validate.php reported problems (see above). Nothing was rolled back." >&2
  fi
  echo "==> Done. Previous images are listed in $note"
}

# Look for the mistakes that otherwise show up later as a container that never starts or a port that is
# never published. Prints ok / info / WARN / ERROR lines; exits 1 if there is any ERROR.
doctor() {
  local errors=0 warnings=0 have_docker=0 mem mem_mb pool pool_mb pool_n pool_unit cfg running missing svc
  local profiles known p var latest first last range_ok sources seen_names seen_ports count bad src commas
  local name rest port type iface
  d_ok() { printf '  ok    %s\n' "$*"; }
  d_info() { printf '  info  %s\n' "$*"; }
  d_warn() { printf '  WARN  %s\n' "$*"; warnings=$((warnings + 1)); }
  d_err() { printf '  ERROR %s\n' "$*"; errors=$((errors + 1)); }

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
        d_warn ".env can be read by every user of this computer and it holds secrets: chmod 600 .env"
      else
        d_ok ".env is private to you"
      fi ;;
  esac

  echo "Profiles"
  profiles=$(env_get COMPOSE_PROFILES | tr -d ' ')
  known=" syslog traps ntopng mail netflow tools "
  if [ -z "$profiles" ]; then
    d_info "no optional profile is enabled (COMPOSE_PROFILES is empty)"
  else
    d_ok "enabled: $profiles"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case $known in
        *" $p "*) ;;
        *) d_warn "unknown profile '$p' in COMPOSE_PROFILES (known: syslog, traps, ntopng, mail, netflow, tools)" ;;
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
  fi

  echo
  echo "$errors error(s), $warnings warning(s)"
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
  validate) docker compose exec -T --user librenms -w /opt/librenms librenms php validate.php ;;
  configure) configure ;;
  update) update ;;
  doctor) doctor ;;
esac
