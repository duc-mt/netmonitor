#!/usr/bin/env bash
# Run every test. None needs Docker; test_compose.py skips itself when `docker compose` is missing.
#   bash tests/all.sh
set -euo pipefail

cd "$(dirname "$0")"
chmod +x fakebin/docker

status=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || status=1
done
if command -v python3 >/dev/null 2>&1; then
  echo "== test_compose.py"
  python3 test_compose.py || status=1
else
  echo "== test_compose.py skipped: python3 not found"
fi

if [ "$status" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit "$status"
