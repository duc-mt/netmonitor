#!/bin/sh
# Renders /oxidized/config.tmpl into $OXIDIZED_HOME/config, then starts Oxidized.
# Values are inserted literally (no sed escaping problems); a single quote in a value is doubled for YAML.
set -eu

: "${OXIDIZED_HOME:?}"
mkdir -p "$OXIDIZED_HOME"

awk '
function quote(v) { gsub(/\047/, "\047\047", v); return v }
function rep(s, m, v,   i) {
  while ((i = index(s, m)) > 0) s = substr(s, 1, i - 1) quote(v) substr(s, i + length(m))
  return s
}
{
  $0 = rep($0, "@OXIDIZED_LIBRENMS_TOKEN@", ENVIRON["OXIDIZED_LIBRENMS_TOKEN"])
  $0 = rep($0, "@OXIDIZED_USERNAME@", ENVIRON["OXIDIZED_USERNAME"])
  $0 = rep($0, "@OXIDIZED_PASSWORD@", ENVIRON["OXIDIZED_PASSWORD"])
  print
}' /oxidized/config.tmpl > "$OXIDIZED_HOME/config"
chmod 600 "$OXIDIZED_HOME/config"

if [ -z "${OXIDIZED_LIBRENMS_TOKEN:-}" ]; then
  echo "oxidized: OXIDIZED_LIBRENMS_TOKEN is empty, the device list cannot be fetched (README, Oxidized)" >&2
fi
exec oxidized
