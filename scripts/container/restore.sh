#!/usr/bin/env bash
# Runs INSIDE the "tools" container (see compose.yaml). Do not run it on the host.
# Replaces the LibreNMS database and /data with the contents of a backup.
set -euo pipefail

: "${BACKUP_NAME:?BACKUP_NAME is required}"
DATA_DIR=${DATA_DIR:-/data}
BACKUP_DIR=${BACKUP_DIR:-/backups}
db_file="$BACKUP_DIR/$BACKUP_NAME-db.sql.gz"
data_file="$BACKUP_DIR/$BACKUP_NAME-data.tgz"

[ -f "$db_file" ]   || { echo "error: $db_file not found" >&2; exit 2; }
[ -f "$data_file" ] || { echo "error: $data_file not found" >&2; exit 2; }

# Verify both archives BEFORE deleting anything: a corrupt backup must not destroy a working system.
echo "Verifying backup ..."
gzip -t "$db_file"
tar tzf "$data_file" > /dev/null

export MYSQL_PWD="${DB_PASSWORD:?DB_PASSWORD is required}"
db=${DB_NAME:-librenms}
client=(-h "${DB_HOST:-db}" -u "${DB_USER:-librenms}")

echo "Restoring database $db ..."
mariadb "${client[@]}" -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
gunzip -c "$db_file" | mariadb "${client[@]}" "$db"

echo "Restoring $DATA_DIR ..."
find "$DATA_DIR" -mindepth 1 -delete
tar xzf "$data_file" -C "$DATA_DIR"
chown -R "${PUID:-1000}:${PGID:-1000}" "$DATA_DIR" 2>/dev/null || true

echo "Restore complete."
