#!/bin/bash
# Incremental backup: uploads files modified since the last successful backup.
# Always includes a fresh pg_dumpall and config (DB cannot be reliably
# differentiated logically).
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
    rm -f "$BACKUP_TMPDIR"/part_* 2>/dev/null || true
    rm -f "$NEW_MARKER" 2>/dev/null || true
    # NOTE: $DUMP is intentionally NOT removed here. See backup_full.sh.
}

on_error() {
    local code=$?
    cleanup_tmp
    rm -f "$DUMP" 2>/dev/null || true   # current run's partial dump
    notify "incremental" "$DATE" "0" "FAILED" "exit=$code line=${BASH_LINENO[0]:-?}" || true
    exit "$code"
}
trap on_error ERR

if [[ ! -f "$MARKER" ]]; then
    echo "ERROR: marker file missing ($MARKER). Run a full backup first." >&2
    notify "incremental" "$DATE" "0" "FAILED" "marker missing" || true
    exit 1
fi

rm -f "$NEW_MARKER"
touch "$NEW_MARKER"

dump_postgres "$DUMP"

PARTS=$(stream_tar_split_upload "incremental" "$DATE" "$MARKER")

mv -f "$NEW_MARKER" "$MARKER"
cp "$MARKER" "${MARKER}.bak"

cleanup_tmp

# Keep only the 3 most recent db_*.sql in $BACKUP_TMPDIR.
prune_old_db_dumps 3

# || true: a Slack-side blip shouldn't turn a successful backup into a cron
# "failure" (the data is safely on S3 by this point).
notify "incremental" "$DATE" "$PARTS" "SUCCESS" || true
