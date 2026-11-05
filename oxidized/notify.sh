#!/bin/sh
# Oxidized "exec" hook for the post_store event (see render-config.sh): runs when a device's configuration was
# stored. Oxidized hands over the event in OX_* variables. Two optional jobs, both set up in .env:
#   OXIDIZED_NOTIFY_TELEGRAM=true  tell the Telegram chat (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID) what changed:
#                                  device, time, commit, changed files, a link to its Config tab (NOTIFY_BASE_URL)
#   OXIDIZED_NOTIFY_DIFF=true      also the changed lines (up to 20), secrets filtered out as far as they can be
#   OXIDIZED_GIT_REMOTE=<url>      push the configuration repository to that remote (an https URL with a token in
#                                  it, or any URL the container can reach without a password prompt)
# Failures are written to stderr (./run logs oxidized) and never stop Oxidized.
set -u

# Only a stored change has a commit; "nothing changed" runs are not worth a message.
[ -n "${OX_REPO_COMMITREF:-}" ] || exit 0

repo=${OXIDIZED_REPO:-/data/configs.git}
short=$(printf '%s' "$OX_REPO_COMMITREF" | cut -c1-8)

if [ "${OXIDIZED_NOTIFY_TELEGRAM:-false}" = true ]; then
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "oxidized hook: OXIDIZED_NOTIFY_TELEGRAM is true but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty" >&2
  else
    text="$(printf '\360\237\223\235') Config changed: ${OX_NODE_NAME:-?} (${OX_NODE_IP:-?}, ${OX_NODE_MODEL:-?})
$(date '+%Y-%m-%d %H:%M %Z')  commit $short"
    if command -v git >/dev/null 2>&1; then
      stat=$(git --git-dir="$repo" diff-tree --no-commit-id --stat -r "$OX_REPO_COMMITREF" 2>/dev/null | tail -n 5 || true)
      if [ -n "$stat" ]; then text="$text
$stat"; fi
      # The changed lines themselves, only when asked for: a configuration holds secrets and this goes to a third
      # party. Lines that look like they hold one are replaced, but that is a filter, not a guarantee.
      if [ "${OXIDIZED_NOTIFY_DIFF:-false}" = true ]; then
        diff=$(git --git-dir="$repo" diff-tree -p --no-commit-id -U0 -r "$OX_REPO_COMMITREF" 2>/dev/null |
          grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | head -n 20 | cut -c1-160 |
          awk '{ if (tolower($0) ~ /pass|secret|community|key|token|crypt|hash|cred|snmp-server|tacacs|radius|auth|psk|cipher/) print substr($0, 1, 1) " <line hidden: may hold a secret>"; else print }' || true)
        if [ -n "$diff" ]; then text="$text

$diff"; fi
      fi
    fi
    if [ -n "${NOTIFY_BASE_URL:-}" ]; then
      text="$text

Config tab: ${NOTIFY_BASE_URL%/}/device/device=${OX_NODE_NAME:-}/tab=showconfig"
    fi
    ruby -rnet/http -ruri -e '
      uri = URI("https://api.telegram.org/bot#{ENV["TELEGRAM_BOT_TOKEN"]}/sendMessage")
      res = Net::HTTP.post_form(uri, "chat_id" => ENV["TELEGRAM_CHAT_ID"], "text" => ARGV[0][0, 3800])
      abort "oxidized hook: Telegram answered HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    ' "$text" || echo "oxidized hook: the Telegram message could not be sent" >&2
  fi
fi

if [ -n "${OXIDIZED_GIT_REMOTE:-}" ]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "oxidized hook: OXIDIZED_GIT_REMOTE is set but git is not in the image" >&2
  elif ! GIT_TERMINAL_PROMPT=0 git --git-dir="$repo" push --quiet "$OXIDIZED_GIT_REMOTE" --all >/dev/null 2>&1; then
    echo "oxidized hook: pushing $repo to the remote failed (check OXIDIZED_GIT_REMOTE and its credentials)" >&2
  fi
fi
exit 0
