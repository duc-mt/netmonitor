#!/usr/bin/env bash
# caddy/Caddyfile: the optional HTTP Basic Auth for the Oxidized and Smokeping names. The static checks need
# nothing; with a caddy binary in PATH the file is also validated and the auth is tried out for real.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

CF="$REPO_DIR/caddy/Caddyfile"

echo "static checks"
for who in OXIDIZED SMOKEPING; do
  check "$who: auth is gated on the user being set" grep -q "{\$${who}_AUTH_USER:}\" != \"\"" "$CF"
  check "$who: the user and hash come from .env" grep -q "{\$${who}_AUTH_USER:nobody} {\$${who}_AUTH_HASH:" "$CF"
  check "compose.yaml passes ${who}_AUTH_USER to caddy" grep -q "${who}_AUTH_USER: \${${who}_AUTH_USER:-}" "$REPO_DIR/compose.yaml"
  check "compose.yaml passes ${who}_AUTH_HASH to caddy" grep -q "${who}_AUTH_HASH: \${${who}_AUTH_HASH:-}" "$REPO_DIR/compose.yaml"
  check ".env.example lists ${who}_AUTH_USER" grep -q "^${who}_AUTH_USER=\$" "$REPO_DIR/.env.example"
  check ".env.example lists ${who}_AUTH_HASH" grep -q "^${who}_AUTH_HASH=\$" "$REPO_DIR/.env.example"
done

echo "with a caddy binary"
if ! command -v caddy >/dev/null 2>&1; then
  echo "  skip  caddy is not installed"
  finish
  exit 0
fi
check "the Caddyfile is valid" bash -c 'caddy validate --config "$1" --adapter caddyfile >/dev/null 2>&1' _ "$CF"
hash=$(caddy hash-password --plaintext pw-ok 2>/dev/null)
export CADDY_LIBRENMS_HOST=http://localhost:18080 CADDY_GRAFANA_HOST=http://localhost:18081
export CADDY_OXIDIZED_HOST=http://localhost:18082 CADDY_SMOKEPING_HOST=http://localhost:18083
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }  # 502: past the proxy rules, the upstream is not there

caddy run --config "$CF" --adapter caddyfile >/dev/null 2>&1 &
pid=$!
sleep 3
equals "auth off: Oxidized is reachable" 502 "$(status localhost:18082/)"
kill "$pid"; wait "$pid" 2>/dev/null || true

OXIDIZED_AUTH_USER=ops OXIDIZED_AUTH_HASH=$hash caddy run --config "$CF" --adapter caddyfile >/dev/null 2>&1 &
pid=$!
sleep 3
equals "auth on: no login is refused" 401 "$(status localhost:18082/)"
equals "auth on: a wrong password is refused" 401 "$(status -u ops:nope localhost:18082/)"
equals "auth on: the right password passes" 502 "$(status -u ops:pw-ok localhost:18082/)"
equals "auth on for Oxidized only: Smokeping stays open" 502 "$(status localhost:18083/)"
kill "$pid"; wait "$pid" 2>/dev/null || true

finish
