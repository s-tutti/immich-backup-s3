#!/bin/bash
# Incremental backup: uses the existing snapshot file as the baseline.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"
source "$SCRIPT_DIR/backup_common.sh"

: "${S3_BUCKET:?}" "${UPLOAD_LOCATION:?}" "${COMPOSE_DIR:?}"
: "${TMPDIR:?}" "${SNAPSHOT_DIR:?}" "${AWS_PROFILE:?}"
: "${PARALLEL:?}" "${CHUNK_SIZE_MB:?}"
: "${PG_CONTAINER:?}" "${PG_USER:?}"

DATE=$(date -u +%Y%m%dT%H%M%SZ)
SNAPSHOT="$SNAPSHOT_DIR/snapshot.snar"
DUMP="$TMPDIR/db_${DATE}.sql"

mkdir -p "$TMPDIR" "$SNAPSHOT_DIR"

cleanup_tmp() {
    rm -f "$TMPDIR"/tar_pipe.* 2>/dev/null || true
    rm -f "$DUMP" 2>/dev/null || true
    rm -f "$TMPDIR"/part_* 2>/dev/null || true
}

on_error() {
    local code=$?
    cleanup_tmp
    notify "incremental" "$DATE" "0" "FAILED" "exit=$code line=${BASH_LINENO[0]:-?}" || true
    exit "$code"
}
trap on_error ERR

if [[ ! -f "$SNAPSHOT" ]]; then
    echo "ERROR: snapshot file missing ($SNAPSHOT). Run a full backup first." >&2
    notify "incremental" "$DATE" "0" "FAILED" "snapshot missing" || true
    exit 1
fi

dump_postgres "$DUMP"

PARTS=$(stream_tar_split_upload "incremental" "$DATE" "$SNAPSHOT")

cp "$SNAPSHOT" "${SNAPSHOT}.bak"

cleanup_tmp

notify "incremental" "$DATE" "$PARTS" "SUCCESS"
