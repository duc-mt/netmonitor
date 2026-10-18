#!/usr/bin/env bash
# The tar command of scripts/container/backup.sh leaves out logs and cache and keeps everything else.
# The command is read from the script itself, so this test cannot drift from it.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

version=$(tar --version 2>/dev/null || true)
case $version in
  *"GNU tar"*) ;;
  *) echo "  skip  needs GNU tar (the backup runs it inside a Linux container)"; exit 0 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/data/rrd/host1" "$work/data/config" "$work/data/logs/sub" "$work/data/cache/views" \
         "$work/data/plugins" "$work/data/logsold" "$work/out"
echo rrd > "$work/data/rrd/host1/port-1.rrd"
echo cfg > "$work/data/config/config.php"
echo log > "$work/data/logs/librenms.log"
echo log > "$work/data/logs/sub/deep.log"
echo tmp > "$work/data/cache/views/v.php"
echo plg > "$work/data/plugins/p.php"
echo old > "$work/data/logsold/keep.txt"
echo hid > "$work/data/.hidden"

line=$(grep '^tar czf' "$REPO_DIR/scripts/container/backup.sh")
DATA_DIR=$work/data
data_file=$work/out/data
export DATA_DIR data_file
eval "$line"

members=$(tar tzf "$work/out/data.partial")
for want in ./rrd/host1/port-1.rrd ./config/config.php ./plugins/p.php ./logsold/keep.txt ./.hidden ./logs/ ./cache/; do
  check "kept $want" grep -Fxq -- "$want" <<<"$members"
done
for gone in ./logs/librenms.log ./logs/sub/deep.log ./cache/views/v.php; do
  if grep -Fxq -- "$gone" <<<"$members"; then fail "left out $gone"; else pass "left out $gone"; fi
done

finish
