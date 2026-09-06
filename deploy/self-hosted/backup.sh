#!/usr/bin/env bash
# Nightly Postgres backup for the self-hosted VPS. Run via cron.
# Currently local-only (see README Step 7) — add an offsite sync (rclone to
# Backblaze B2/S3) once a target is chosen; local backups don't protect
# against losing the VPS itself.
set -euo pipefail

BACKUP_DIR="$HOME/backups"
RETENTION_DAYS=14
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILE="$BACKUP_DIR/nafil_db_${TIMESTAMP}.sql.gz"
LOG="$BACKUP_DIR/backup.log"

mkdir -p "$BACKUP_DIR"

if docker exec supabase-db pg_dump -U postgres -d postgres | gzip > "$FILE"; then
  echo "$(date -Iseconds) OK ${FILE} ($(du -h "$FILE" | cut -f1))" >> "$LOG"
else
  echo "$(date -Iseconds) FAILED" >> "$LOG"
  rm -f "$FILE"
  exit 1
fi

find "$BACKUP_DIR" -name "nafil_db_*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
