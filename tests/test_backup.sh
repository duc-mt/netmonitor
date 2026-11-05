#!/usr/bin/env bash
# scripts/backup.sh --verify / --keep / the off-site upload, and ./run verify-backup. Needs no Docker (see lib.sh).
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
sandbox
chmod +x scripts/*.sh

backup() {
  : > "$FAKE_LOG"
  code=0
  bash scripts/backup.sh "$@" >out.txt 2>err.txt || code=$?
}
BK='compose run --rm --no-deps -e BACKUP_NAME='

echo "a plain backup"
backup
equals "exits 0" 0 "$code"
check "runs the backup container once" test "$(grep -c "tools /scripts/backup.sh" "$FAKE_LOG")" -eq 1
absent "no restore test" "verify.sh"
absent "no upload" "rclone"

echo "backup --keep"
backup --keep 3
present "KEEP is handed to the backup container" "-e KEEP=3 tools /scripts/backup.sh"

echo "backup --verify"
backup --verify --keep 3
equals "exits 0" 0 "$code"
present "the backup runs without pruning" "-e KEEP=0 tools /scripts/backup.sh"
present "then the restore test runs" "tools /scripts/verify.sh"
present "and the pruning runs after it" "-e KEEP=3 tools /scripts/prune.sh"
check "the dispatcher is started before the restore test" bash -c '
  start=$(grep -n "compose start dispatcher" "$1" | head -n 1 | cut -d: -f1)
  verify=$(grep -n "verify.sh" "$1" | head -n 1 | cut -d: -f1)
  [ -n "$start" ] && [ -n "$verify" ] && [ "$start" -lt "$verify" ]' _ "$FAKE_LOG"
FAKE_FAIL_MATCH='verify.sh' backup --verify --keep 3
equals "a failed restore test exits 1" 1 "$code"
check "and says not to rely on the backup" grep -q 'did NOT pass the restore test' err.txt
absent "and nothing is pruned" "prune.sh"
check "the dispatcher is running again anyway" grep -q "compose start dispatcher" "$FAKE_LOG"

echo "off-site upload"
printf 'MYSQL_PASSWORD=test\nBACKUP_REMOTE=s3:bucket/netmonitor\n' > .env
backup
equals "BACKUP_REMOTE without rclone exits 1" 1 "$code"
check "and explains" grep -q 'rclone is not installed' err.txt
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/rclone" <<'EOF'
#!/bin/sh
echo "rclone $*" >> "${FAKE_LOG:?}"
exit "${FAKE_RCLONE_EXIT:-0}"
EOF
chmod +x "$SANDBOX/bin/rclone"
PATH="$SANDBOX/bin:$PATH"
backup
equals "with rclone it exits 0" 0 "$code"
check "the database dump is uploaded" grep -Eq 'rclone copy --checksum backups/librenms-[0-9-]+-db.sql.gz s3:bucket/netmonitor' "$FAKE_LOG"
check "and the data archive" grep -Eq 'rclone copy --checksum backups/librenms-[0-9-]+-data.tgz s3:bucket/netmonitor' "$FAKE_LOG"
backup --no-offsite
absent "--no-offsite skips the upload" "rclone"
FAKE_RCLONE_EXIT=1 backup
equals "a failed upload exits 1" 1 "$code"
check "and says the backup is safe locally" grep -q 'the backup itself is in ./backups' err.txt
FAKE_FAIL_MATCH='verify.sh' backup --verify
absent "a set that failed its restore test is not uploaded" "rclone"
printf "MYSQL_PASSWORD=test\nBACKUP_REMOTE='s3:quoted/path'\n" > .env
backup
present "a quoted BACKUP_REMOTE is read without the quotes" "s3:quoted/path"

echo "./run verify-backup"
printf 'MYSQL_PASSWORD=test\n' > .env
mkdir -p backups
: > backups/librenms-20260101-120000-db.sql.gz; : > backups/librenms-20260101-120000-data.tgz
: > backups/librenms-20260202-120000-db.sql.gz; : > backups/librenms-20260202-120000-data.tgz
vb() { : > "$FAKE_LOG"; code=0; ./run verify-backup "$@" >out.txt 2>err.txt || code=$?; }
vb
present "the newest set is checked by default" "${BK}librenms-20260202-120000 tools /scripts/verify.sh"
vb 20260101-120000
present "a short name works" "${BK}librenms-20260101-120000 tools /scripts/verify.sh"
vb ./backups/librenms-20260101-120000-db.sql.gz
present "a file path works" "${BK}librenms-20260101-120000 tools /scripts/verify.sh"
vb 19990101-000000
equals "an unknown set exits 1" 1 "$code"
absent "and runs nothing" "verify.sh"
rm backups/librenms-20260202-120000-data.tgz
vb librenms-20260202-120000
equals "a set missing one file exits 1" 1 "$code"

finish
