#!/bin/bash
# Consistent backup of the database, uploaded files and encryption keys.
#   backup.sh schedule  - run daily at $BACKUP_TIME (HH:MM, container TZ)
#   backup.sh now       - run once and exit
set -euo pipefail

: "${BACKUP_TIME:=03:15}"
: "${BACKUP_KEEP_DAYS:=14}"
: "${DB_HOST:=db}"
: "${DB_NAME:=limesurvey}"
: "${DB_USER:=limesurvey}"

log() { printf '[backup] %s %s\n' "$(date '+%F %T')" "$*"; }

run_backup() {
  umask 077
  stamp=$(date +%Y%m%d-%H%M%S)
  dir="/backups/$stamp"
  work="/backups/.$stamp.partial"
  mkdir -p "$work"
  trap 'rm -rf "$work"' EXIT

  log "Dumping database to $dir"
  MYSQL_PWD=$(cat "$DB_PASSWORD_FILE") mariadb-dump \
    -h "$DB_HOST" -u "$DB_USER" \
    --single-transaction --quick --skip-lock-tables \
    --default-character-set=utf8mb4 --hex-blob \
    "$DB_NAME" | gzip -6 > "$work/database.sql.gz"
  gzip -t "$work/database.sql.gz"

  log 'Archiving uploaded files'
  tar -C /data -czf "$work/upload.tar.gz" upload

  # security.php holds the data-encryption keys: without it encrypted
  # responses/participants cannot be decrypted after a restore.
  log 'Archiving encryption keys'
  tar -C /data/state -czf "$work/keys.tar.gz" security.php

  (cd "$work" && sha256sum database.sql.gz upload.tar.gz keys.tar.gz > SHA256SUMS)
  mv "$work" "$dir"
  trap - EXIT
  log "Done: $(du -sh "$dir" | cut -f1)"

  find /backups -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$BACKUP_KEEP_DAYS" \
    -exec rm -rf {} + -exec printf '[backup] pruned %s\n' {} \;
}

seconds_until() {
  now=$(date +%s)
  target=$(date -d "$(date +%F) $1" +%s)
  [ "$target" -le "$now" ] && target=$((target + 86400))
  echo $((target - now))
}

case "${1:-schedule}" in
  now) run_backup ;;
  schedule)
    log "Scheduler started: daily at $BACKUP_TIME, keeping $BACKUP_KEEP_DAYS days"
    while :; do
      sleep "$(seconds_until "$BACKUP_TIME")"
      # Separate process so errexit/pipefail stay in force inside the run.
      bash "$0" now || log 'ERROR: backup failed, see messages above'
      sleep 60
    done
    ;;
  *) echo "usage: backup.sh [schedule|now]" >&2; exit 2 ;;
esac
