#!/bin/bash
# Full backup: resets the snapshot file and uploads everything in scope.
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
SNAPSHOT="$SNAPSHOT_DIR/snapshot.snar"
DUMP="$BACKUP_TMPDIR/db_${DATE}.sql"

mkdir -p "$BACKUP_TMPDIR" "$SNAPSHOT_DIR"

cleanup_tmp() {
    rm -f "$BACKUP_TMPDIR"/tar_pipe.* 2>/dev/null || true
    rm -f "$DUMP" 2>/dev/null || true
    rm -f "$BACKUP_TMPDIR"/part_* 2>/dev/null || true
}

on_error() {
    local code=$?
    cleanup_tmp
    notify "full" "$DATE" "0" "FAILED" "exit=$code line=${BASH_LINENO[0]:-?}" || true
    exit "$code"
}
trap on_error ERR

# A full backup starts a new incremental chain.
rm -f "$SNAPSHOT"

dump_postgres "$DUMP"

PARTS=$(stream_tar_split_upload "full" "$DATE" "$SNAPSHOT")

# Keep a local copy of the snapshot so a single corrupted file doesn't break
# the next incremental chain.
cp "$SNAPSHOT" "${SNAPSHOT}.bak"

cleanup_tmp

# Best-effort cleanup of expired old fulls (don't fail the backup if it errors).
"$SCRIPT_DIR/cleanup_old_full.sh" "$DATE" || true

notify "full" "$DATE" "$PARTS" "SUCCESS"
