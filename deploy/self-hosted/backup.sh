#!/usr/bin/env bash
# Nightly Postgres backup for the self-hosted VPS. Run via cron.
# Still local-only (see README Step 7) - add an offsite sync (rclone to
# Backblaze B2/S3) once a target is chosen; local backups don't protect
# against losing the VPS itself, encrypted or not.
#
# The dump is a full Postgres export - auth tables (password hashes),
# resident PII, ID documents' storage paths - so it's encrypted at rest with
# a passphrase read from BACKUP_PASSPHRASE_FILE (never put the passphrase
# directly in this script or in cron's own command line, both of which are
# readable by anyone who can run `ps`/read the crontab). Generate one once:
#   openssl rand -base64 32 > ~/.backup_passphrase && chmod 600 ~/.backup_passphrase
set -euo pipefail

BACKUP_DIR="$HOME/backups"
RETENTION_DAYS=14
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-$HOME/.backup_passphrase}"
FILE="$BACKUP_DIR/nafil_db_${TIMESTAMP}.sql.gz.enc"
LOG="$BACKUP_DIR/backup.log"

if [ ! -s "$PASSPHRASE_FILE" ]; then
  echo "$(date -Iseconds) FAILED: no passphrase at ${PASSPHRASE_FILE}" >> "$BACKUP_DIR/backup.log" 2>/dev/null || true
  echo "Missing backup passphrase file: ${PASSPHRASE_FILE} (see comment above to generate one)" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if docker exec supabase-db pg_dump -U postgres -d postgres \
    | gzip \
    | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$PASSPHRASE_FILE" -out "$FILE"; then
  chmod 600 "$FILE"
  echo "$(date -Iseconds) OK ${FILE} ($(du -h "$FILE" | cut -f1))" >> "$LOG"
else
  echo "$(date -Iseconds) FAILED" >> "$LOG"
  rm -f "$FILE"
  exit 1
fi

find "$BACKUP_DIR" -name "nafil_db_*.sql.gz.enc" -mtime +"$RETENTION_DAYS" -delete
