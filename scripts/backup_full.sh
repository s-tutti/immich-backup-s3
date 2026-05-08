#!/bin/bash
# Full backup: tars everything in scope and uploads as Glacier Deep Archive chunks.
# Records a timestamp marker so subsequent incrementals know what is new.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"
source "$SCRIPT_DIR/backup_common.sh"

: "${S3_BUCKET:?}" "${UPLOAD_LOCATION:?}" "${COMPOSE_DIR:?}"
: "${BACKUP_TMPDIR:?}" "${SNAPSHOT_DIR:?}" "${AWS_PROFILE:?}"
: "${PARALLEL:?}" "${CHUNK_SIZE_MB:?}"
: "${PG_CONTAINER:?}" "${PG_USER:?}"

DATE=$(date -u +%Y%m%dT%H%M%SZ)
MARKER="$SNAPSHOT_DIR/last_backup_time"
NEW_MARKER="$SNAPSHOT_DIR/.last_backup_time.tmp"
DUMP="$BACKUP_TMPDIR/db_${DATE}.sql"

mkdir -p "$BACKUP_TMPDIR" "$SNAPSHOT_DIR"

cleanup_tmp() {
    rm -f "$BACKUP_TMPDIR"/tar_pipe.* 2>/dev/null || true
    rm -f "$DUMP" 2>/dev/null || true
    rm -f "$BACKUP_TMPDIR"/part_* 2>/dev/null || true
    rm -f "$NEW_MARKER" 2>/dev/null || true
}

on_error() {
    local code=$?
    cleanup_tmp
    notify "full" "$DATE" "0" "FAILED" "exit=$code line=${BASH_LINENO[0]:-?}" || true
    exit "$code"
}
trap on_error ERR

# Snapshot the cutoff *before* the backup runs. Anything modified during the
# backup window will be picked up by the next incremental (find -newer).
rm -f "$NEW_MARKER"
touch "$NEW_MARKER"

dump_postgres "$DUMP"

PARTS=$(stream_tar_split_upload "full" "$DATE" "$MARKER")

# Install the new marker on success. Full ignored the old one anyway, but we
# need a baseline for the next incremental.
mv -f "$NEW_MARKER" "$MARKER"
cp "$MARKER" "${MARKER}.bak"

cleanup_tmp

# Best-effort cleanup of expired old fulls (don't fail the backup if it errors).
"$SCRIPT_DIR/cleanup_old_full.sh" "$DATE" || true

notify "full" "$DATE" "$PARTS" "SUCCESS"
