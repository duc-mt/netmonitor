#!/usr/bin/env bash
# oxidized/render-config.sh (the optional hook block) and oxidized/notify.sh (what the hook does).
# Runs the real scripts with fake oxidized, ruby and git programs. Needs no Docker.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/oxidized" <<'SH'
#!/bin/sh
echo started >> "$FAKE_OX_LOG"
SH
cat > "$work/bin/ruby" <<'SH'
#!/bin/sh
echo "ruby message: $(printf '%s' "$*" | tail -c 1500)" >> "$FAKE_OX_LOG"
exit "${FAKE_RUBY_EXIT:-0}"
SH
cat > "$work/bin/git" <<'SH'
#!/bin/sh
echo "git $*" >> "$FAKE_OX_LOG"
case "$*" in
  *--stat*) echo " router.cfg | 2 +-" ;;
  *" -p "*) printf '%s\n' '--- a/router.cfg' '+++ b/router.cfg' '-interface Vlan10' '+interface Vlan20' '+snmp-server community s3cr3t RO' '-enable secret 5 $1$abc' ;;
esac
exit "${FAKE_GIT_EXIT:-0}"
SH
chmod +x "$work/bin/"*
export FAKE_OX_LOG=$work/log
PATH="$work/bin:$PATH"

render() {  # render [VAR=value ...]: run render-config.sh with a clean environment
  : > "$FAKE_OX_LOG"
  rm -rf "${work:?}/home"
  env -i PATH="$PATH" FAKE_OX_LOG="$FAKE_OX_LOG" OXIDIZED_HOME="$work/home" OXIDIZED_TEMPLATE="$REPO_DIR/oxidized/config.tmpl" \
    OXIDIZED_LIBRENMS_TOKEN=tok OXIDIZED_USERNAME=u OXIDIZED_PASSWORD=p "$@" sh "$REPO_DIR/oxidized/render-config.sh" >/dev/null 2>&1
}

echo "render-config.sh"
render
check "starts oxidized" grep -q started "$FAKE_OX_LOG"
check "fills in the token" grep -q "X-Auth-Token: 'tok'" "$work/home/config"
check "no hooks by default" test -z "$(grep '^hooks:' "$work/home/config")"
render OXIDIZED_NOTIFY_TELEGRAM=true
check "Telegram notification adds the hook" grep -q '^hooks:' "$work/home/config"
check "on the post_store event" grep -q 'events: \[post_store\]' "$work/home/config"
check "running notify.sh" grep -q "cmd: '/oxidized/notify.sh'" "$work/home/config"
render OXIDIZED_GIT_REMOTE=https://example.com/r.git
check "a git remote adds the hook too" grep -q '^hooks:' "$work/home/config"
render OXIDIZED_NOTIFY_TELEGRAM=false
check "false means no hook" test -z "$(grep '^hooks:' "$work/home/config")"
check "the config stays private (600)" test "$(stat -c %a "$work/home/config" 2>/dev/null || stat -f %Lp "$work/home/config")" = 600

echo "notify.sh"
hook() {  # hook [VAR=value ...]
  : > "$FAKE_OX_LOG"
  code=0
  env -i PATH="$PATH" FAKE_OX_LOG="$FAKE_OX_LOG" OX_NODE_NAME=router1 OX_NODE_IP=10.0.0.1 OX_NODE_MODEL=ios \
    OX_REPO_COMMITREF=0123456789abcdef "$@" sh "$REPO_DIR/oxidized/notify.sh" >"$work/out" 2>"$work/err" || code=$?
}
logged() { grep -q -- "$1" "$FAKE_OX_LOG"; }
hook OXIDIZED_NOTIFY_TELEGRAM=true TELEGRAM_BOT_TOKEN=1:abc TELEGRAM_CHAT_ID=42
equals "exits 0" 0 "$code"
check "sends a Telegram message" logged "ruby message"
check "naming the device" logged "Config changed: router1 (10.0.0.1, ios)"
check "with the time and the commit" grep -Eq "20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9:]+.*commit 01234567" "$FAKE_OX_LOG"
check "no link without NOTIFY_BASE_URL" test -z "$(grep Config.tab "$FAKE_OX_LOG")"
check "no changed lines unless asked for" test -z "$(grep interface "$FAKE_OX_LOG")"
check "with the diffstat" logged "router.cfg"
hook OXIDIZED_NOTIFY_TELEGRAM=true TELEGRAM_BOT_TOKEN=1:abc TELEGRAM_CHAT_ID=42 NOTIFY_BASE_URL=https://nms.example.com/
check "a link to the Config tab of the device" logged "Config tab: https://nms.example.com/device/device=router1/tab=showconfig"
hook OXIDIZED_NOTIFY_TELEGRAM=true TELEGRAM_BOT_TOKEN=1:abc TELEGRAM_CHAT_ID=42 OXIDIZED_NOTIFY_DIFF=true
check "with OXIDIZED_NOTIFY_DIFF the changed lines are sent" logged "+interface Vlan20"
check "removed lines too" logged "-interface Vlan10"
check "file headers are left out" test -z "$(grep -F -- '+++ b/router.cfg' "$FAKE_OX_LOG")"
check "a community line is hidden" test -z "$(grep s3cr3t "$FAKE_OX_LOG")"
check "and so is a secret line" test -z "$(grep 'enable secret' "$FAKE_OX_LOG")"
check "hidden lines say so" logged "<line hidden: may hold a secret>"
hook OXIDIZED_NOTIFY_TELEGRAM=true TELEGRAM_BOT_TOKEN=1:abc TELEGRAM_CHAT_ID=42 OX_REPO_COMMITREF=
check "without a commit (nothing changed) nothing is sent" test ! -s "$FAKE_OX_LOG"
hook OXIDIZED_NOTIFY_TELEGRAM=true
equals "a missing token does not fail Oxidized" 0 "$code"
check "and is explained" grep -q 'TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty' "$work/err"
hook OXIDIZED_NOTIFY_TELEGRAM=true TELEGRAM_BOT_TOKEN=1:abc TELEGRAM_CHAT_ID=42 FAKE_RUBY_EXIT=1
equals "a failed send does not fail Oxidized" 0 "$code"
check "and is reported" grep -q 'could not be sent' "$work/err"
hook OXIDIZED_GIT_REMOTE=https://example.com/r.git
check "pushes all branches to the remote" logged "git --git-dir=/data/configs.git push --quiet https://example.com/r.git --all"
check "without sending Telegram" test -z "$(grep 'ruby' "$FAKE_OX_LOG")"
hook OXIDIZED_GIT_REMOTE=https://example.com/r.git FAKE_GIT_EXIT=1
equals "a failed push does not fail Oxidized" 0 "$code"
check "and is reported" grep -q 'pushing /data/configs.git to the remote failed' "$work/err"
check "the remote URL (it may hold a token) is not in the error" test -z "$(grep 'example.com' "$work/err")"
hook
check "nothing configured: nothing happens" test ! -s "$FAKE_OX_LOG"

finish
