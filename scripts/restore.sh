#!/bin/sh
# Restore a backup made by the backup service into this stack.
#   sudo ./scripts/restore.sh backups/20261117-031500
# Replaces the current database, uploaded files and encryption keys.
set -eu

cd "$(dirname "$0")/.."
src=${1:?usage: restore.sh <backup-directory>}
[ -d "$src" ] || { echo "No such directory: $src" >&2; exit 1; }
src=$(cd "$src" && pwd)

(cd "$src" && sha256sum -c SHA256SUMS) || { echo 'Checksum mismatch, aborting.' >&2; exit 1; }

# RESTORE_CONFIRMED=1 is set by the install.sh menu after its own confirmation.
if [ "${RESTORE_CONFIRMED:-}" != 1 ]; then
  printf 'This REPLACES the current database, uploads and keys with %s.\nType "restore" to continue: ' "$src"
  read -r answer
  [ "$answer" = restore ] || { echo 'Aborted.'; exit 1; }
fi

dc() { docker compose "$@"; }

echo '[restore] Stopping LimeSurvey'
dc stop limesurvey backup

echo '[restore] Restoring database'
dc up -d --wait db
gzip -dc "$src/database.sql.gz" | dc exec -T db sh -c '
  export MYSQL_PWD="$(cat /run/secrets/db_root_password)"
  mariadb -uroot -e "DROP DATABASE IF EXISTS limesurvey; CREATE DATABASE limesurvey CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL ON limesurvey.* TO \"limesurvey\"@\"%\";"
  exec mariadb -uroot limesurvey'

echo '[restore] Restoring uploads and encryption keys'
dc run --rm --no-deps -T --user 0:0 --entrypoint sh \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  -v "$src:/restore:ro" limesurvey -c '
    set -e
    find /var/www/html/upload -mindepth 1 -delete
    tar -C /var/www/html -xzf /restore/upload.tar.gz
    chown -R 33:33 /var/www/html/upload
    tar -C /var/lib/limesurvey -xzf /restore/keys.tar.gz
    chown 33:33 /var/lib/limesurvey/security.php
    chmod 600 /var/lib/limesurvey/security.php'

echo '[restore] Starting LimeSurvey (schema is migrated automatically if older)'
dc up -d --wait limesurvey backup
echo '[restore] Done.'
