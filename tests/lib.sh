# shellcheck shell=bash
# Helpers shared by the tests. Source it; it runs nothing by itself.
# Each test works on a throw-away copy of the project with a fake "docker" first in PATH that records
# its calls, so no test needs Docker.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$TESTS_DIR")
fails=0

pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# check "label" command...      passes when the command succeeds
check() {
  local label=$1
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

# equals "label" expected actual
equals() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1"
    printf '        expected: %s\n        actual:   %s\n' "$2" "$3"
  fi
}

# present "label" text / absent "label" text      is the text in the log of docker calls?
present() { if grep -qF -- "$2" "$FAKE_LOG"; then pass "$1"; else fail "$1"; fi; }
absent() { if grep -qF -- "$2" "$FAKE_LOG"; then fail "$1"; else pass "$1"; fi; }

# The docker calls the script under test made, without the two start-up checks.
calls() { grep -v -x -e 'compose version' -e 'info' "$FAKE_LOG" || true; }

# Copy the project to a temp folder, create a minimal .env, put the fake docker first in PATH, go there.
sandbox() {
  chmod +x "$TESTS_DIR/fakebin/docker"
  SANDBOX=$(mktemp -d)
  trap 'rm -rf "$SANDBOX"' EXIT
  (cd "$REPO_DIR" && tar cf - --exclude=.git --exclude=backups .) | (cd "$SANDBOX" && tar xf -)
  printf 'MYSQL_PASSWORD=test\n' > "$SANDBOX/.env"
  FAKE_LOG="$SANDBOX/docker.log"
  : > "$FAKE_LOG"
  export FAKE_LOG
  PATH="$TESTS_DIR/fakebin:$PATH"
  export PATH
  cd "$SANDBOX" || exit 1
}

finish() {
  if [ "$fails" -eq 0 ]; then
    echo "PASSED"
  else
    echo "$fails FAILED"
    exit 1
  fi
}
