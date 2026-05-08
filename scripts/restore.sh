#!/bin/bash
# Restore template. Glacier Deep Archive retrieval is asynchronous (12 h+),
# so this runs in two phases:
#
#   Phase 1: kick off restore-object requests
#       restore.sh request <full-date> [<inc-date> ...]
#
#   Phase 2 (after retrieval completes, hours later): download + extract
#       restore.sh extract <full-date> [<inc-date> ...]
#
# Both phases take the same arguments. Run them in chronological order
# (full first, then each incremental in increasing date order).
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"

: "${S3_BUCKET:?}" "${AWS_PROFILE:?}"

RESTORE_DIR=${RESTORE_DIR:-/tmp/immich_restore}
TARGET_DIR=${TARGET_DIR:-/mnt/hdd1_restored}
RETRIEVAL_TIER=${RETRIEVAL_TIER:-Standard}    # Standard (12h, $0.02/GB) or Bulk (48h, $0.0025/GB)
RETRIEVAL_DAYS=${RETRIEVAL_DAYS:-7}            # how long the restored copy stays available

usage() {
    cat <<EOF
Usage: $0 <command> <full-date> [<inc-date> ...]
Commands:
  request   - issue restore-object requests for each part (async)
  extract   - download + extract once retrieval has completed
  list      - show available backups

Available backups:
EOF
    aws s3 ls "s3://${S3_BUCKET}/full/" --profile "$AWS_PROFILE" 2>/dev/null || true
    aws s3 ls "s3://${S3_BUCKET}/incremental/" --profile "$AWS_PROFILE" 2>/dev/null || true
    exit 1
}

[[ $# -lt 1 ]] && usage
CMD=$1; shift

list_keys_under() {
    local prefix=$1
    aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET" --prefix "$prefix" \
        --query 'Contents[].Key' --output text \
        --profile "$AWS_PROFILE" | tr '\t' '\n' | grep -v '^$' || true
}

cmd_list() {
    aws s3 ls "s3://${S3_BUCKET}/full/" --profile "$AWS_PROFILE" || true
    aws s3 ls "s3://${S3_BUCKET}/incremental/" --profile "$AWS_PROFILE" || true
}

cmd_request() {
    [[ $# -lt 1 ]] && usage
    local full=$1; shift
    local incs=("$@")

    local prefixes=("full/$full")
    for d in "${incs[@]}"; do prefixes+=("incremental/$d"); done

    for p in "${prefixes[@]}"; do
        echo "Requesting retrieval under: $p ($RETRIEVAL_TIER)"
        list_keys_under "$p/" | while read -r key; do
            aws s3api restore-object \
                --bucket "$S3_BUCKET" \
                --key "$key" \
                --restore-request "{\"Days\":$RETRIEVAL_DAYS,\"GlacierJobParameters\":{\"Tier\":\"$RETRIEVAL_TIER\"}}" \
                --profile "$AWS_PROFILE" || true
        done
    done
    echo
    echo "Retrieval initiated. With Tier=$RETRIEVAL_TIER, expect ~12h (Standard) or ~48h (Bulk)."
    echo "Re-run with: $0 extract $full ${incs[*]}"
}

cmd_extract() {
    [[ $# -lt 1 ]] && usage
    local full=$1; shift
    local incs=("$@")

    mkdir -p "$RESTORE_DIR" "$TARGET_DIR"

    echo "==> Download: full/$full"
    aws s3 cp "s3://${S3_BUCKET}/full/${full}/" "${RESTORE_DIR}/full_${full}/" \
        --recursive --profile "$AWS_PROFILE"

    for inc in "${incs[@]}"; do
        echo "==> Download: incremental/$inc"
        aws s3 cp "s3://${S3_BUCKET}/incremental/${inc}/" "${RESTORE_DIR}/inc_${inc}/" \
            --recursive --profile "$AWS_PROFILE"
    done

    # The backup writer concatenates two tar archives per backup (media + db/config),
    # so we need -i (--ignore-zeros) to read past the inter-archive zero blocks.
    echo "==> Extract full"
    cat "${RESTORE_DIR}/full_${full}"/part_* \
        | tar -ixvf - -C "$TARGET_DIR"

    for inc in "${incs[@]}"; do
        echo "==> Extract incremental $inc"
        cat "${RESTORE_DIR}/inc_${inc}"/part_* \
            | tar -ixvf - -C "$TARGET_DIR"
    done

    echo
    echo "Filesystem restored to: $TARGET_DIR"
    echo
    echo "Now restore PostgreSQL (the latest dump from the most recent backup):"
    LATEST_DUMP=$(ls -1 "$TARGET_DIR"/db_*.sql 2>/dev/null | sort | tail -n1 || true)
    if [[ -n "$LATEST_DUMP" ]]; then
        echo "  docker exec -i $PG_CONTAINER psql -U $PG_USER -d postgres < $LATEST_DUMP"
    else
        echo "  (no db_*.sql found in $TARGET_DIR — check the extraction)"
    fi
    echo
    echo "Then start Immich and re-run the thumbnail and transcoding jobs."
}

case "$CMD" in
    request) cmd_request "$@" ;;
    extract) cmd_extract "$@" ;;
    list)    cmd_list ;;
    *)       usage ;;
esac
