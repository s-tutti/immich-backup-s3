#!/bin/bash
# Restore from S3 Glacier Deep Archive backups.
#
# Two phases (Glacier retrieval is async, ~12-48 h):
#   Phase 1: kick off restore-object requests
#   Phase 2 (after retrieval completes): download + extract
#
# Disaster recovery (typical use):
#   restore.sh request               # auto-discover latest full + all newer incrementals
#   # ... wait 12h (Standard) or 48h (Bulk) ...
#   restore.sh extract               # auto-discover same chain, download + extract
#
# Drill / point-in-time recovery (specific generation):
#   restore.sh request <full-ts> [<inc-ts> ...]
#   restore.sh extract <full-ts> [<inc-ts> ...]
#
# Other:
#   restore.sh latest    # show what auto-discovery would pick (no action)
#   restore.sh list      # list everything in the bucket
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
Usage: $0 <command> [<full-ts> [<inc-ts> ...]]

Commands:
  request   - issue restore-object requests (async, ~12-48 h)
              no args: discover latest full + all newer incrementals (DR)
              args   : use given timestamps (drill / PITR)
  extract   - download + extract once retrieval has completed
              same arg pattern as request
  latest    - show what auto-discovery would pick (no action)
  list      - list everything in the bucket

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

# Echo: latest full timestamp on first line, all newer incremental timestamps
# on subsequent lines (chronological). ISO 8601 timestamps sort lexically.
discover_latest_chain() {
    local latest_full
    latest_full=$(aws s3 ls "s3://$S3_BUCKET/full/" --profile "$AWS_PROFILE" \
        | awk '{print $2}' | sed 's|/$||' | grep -v '^$' | sort | tail -1)
    if [[ -z "$latest_full" ]]; then
        echo "ERROR: no full backup found in s3://$S3_BUCKET/full/" >&2
        return 1
    fi
    echo "$latest_full"
    aws s3 ls "s3://$S3_BUCKET/incremental/" --profile "$AWS_PROFILE" \
        | awk '{print $2}' | sed 's|/$||' | grep -v '^$' | sort \
        | awk -v f="$latest_full" '$0 > f'
}

# Resolve args: 0 args → discover latest chain; otherwise args as-is.
# Outputs: full on first line, incs on subsequent lines.
resolve_chain() {
    if [[ $# -eq 0 ]]; then
        discover_latest_chain
    else
        for arg in "$@"; do echo "$arg"; done
    fi
}

print_chain_summary() {
    local full=$1; shift
    local incs=("$@")
    echo "Restore chain:"
    echo "  full/$full"
    for d in "${incs[@]}"; do
        [[ -n "$d" ]] && echo "  incremental/$d"
    done
    echo
    echo "Total: 1 full + ${#incs[@]} incremental"
}

cmd_latest() {
    local chain
    chain=$(discover_latest_chain) || exit 1
    local full
    full=$(echo "$chain" | head -1)
    local incs
    readarray -t incs < <(echo "$chain" | tail -n +2 | grep -v '^$')

    print_chain_summary "$full" "${incs[@]}"
    echo
    echo "Disaster recovery:"
    echo "  $0 request          # kick off Glacier retrieval"
    echo "  $0 extract          # after 12-48h, download + extract"
}

cmd_request() {
    local chain
    chain=$(resolve_chain "$@") || exit 1
    local full
    full=$(echo "$chain" | head -1)
    local incs
    readarray -t incs < <(echo "$chain" | tail -n +2 | grep -v '^$')

    print_chain_summary "$full" "${incs[@]}"
    echo "Tier: $RETRIEVAL_TIER ($([[ "$RETRIEVAL_TIER" == "Bulk" ]] && echo "~48h, \$0.0025/GB" || echo "~12h, \$0.02/GB"))"
    echo "Days: $RETRIEVAL_DAYS (how long the thawed copy stays accessible)"
    echo

    local prefixes=("full/$full")
    for d in "${incs[@]}"; do
        [[ -n "$d" ]] && prefixes+=("incremental/$d")
    done

    for p in "${prefixes[@]}"; do
        echo "Requesting retrieval under: $p"
        # Skip manifest.json: it's stored as STANDARD (intentionally, so we
        # can read it without thawing) and would error InvalidObjectState
        # if we tried to restore-object it.
        list_keys_under "$p/" | grep -v '/manifest\.json$' | while read -r key; do
            aws s3api restore-object \
                --bucket "$S3_BUCKET" \
                --key "$key" \
                --restore-request "{\"Days\":$RETRIEVAL_DAYS,\"GlacierJobParameters\":{\"Tier\":\"$RETRIEVAL_TIER\"}}" \
                --profile "$AWS_PROFILE" || true
        done
    done
    echo
    echo "Retrieval initiated. Verify with:"
    echo "  aws s3api head-object --bucket $S3_BUCKET --key full/$full/part_000 --query Restore --profile $AWS_PROFILE"
    echo "Then re-run: $0 extract$([[ $# -gt 0 ]] && echo " ${@}")"
}

cmd_extract() {
    local chain
    chain=$(resolve_chain "$@") || exit 1
    local full
    full=$(echo "$chain" | head -1)
    local incs
    readarray -t incs < <(echo "$chain" | tail -n +2 | grep -v '^$')

    print_chain_summary "$full" "${incs[@]}"
    echo "Restore staging: $RESTORE_DIR"
    echo "Restore target:  $TARGET_DIR"
    echo

    mkdir -p "$RESTORE_DIR" "$TARGET_DIR"

    # --force-glacier-transfer: AWS CLI は DEEP_ARCHIVE / GLACIER 系の
    # オブジェクトを (restore-object で thawed 済でも) デフォルトでスキップ
    # するため、明示的に許可する必要がある。restored 期間中は実体は
    # standard-class 相当でアクセスできるが、メタデータ上の storage class
    # は GLACIER のまま。
    echo "==> Download: full/$full"
    aws s3 cp "s3://${S3_BUCKET}/full/${full}/" "${RESTORE_DIR}/full_${full}/" \
        --recursive --force-glacier-transfer --profile "$AWS_PROFILE"

    for inc in "${incs[@]}"; do
        [[ -z "$inc" ]] && continue
        echo "==> Download: incremental/$inc"
        aws s3 cp "s3://${S3_BUCKET}/incremental/${inc}/" "${RESTORE_DIR}/inc_${inc}/" \
            --recursive --force-glacier-transfer --profile "$AWS_PROFILE"
    done

    # The backup writer concatenates two tar archives per backup (media + db/config),
    # so we need -i (--ignore-zeros) to read past the inter-archive zero blocks.
    echo "==> Extract full"
    cat "${RESTORE_DIR}/full_${full}"/part_* \
        | tar -ixvf - -C "$TARGET_DIR"

    for inc in "${incs[@]}"; do
        [[ -z "$inc" ]] && continue
        echo "==> Extract incremental $inc"
        cat "${RESTORE_DIR}/inc_${inc}"/part_* \
            | tar -ixvf - -C "$TARGET_DIR"
    done

    echo
    echo "Filesystem restored to: $TARGET_DIR"
    echo
    echo "Restore PostgreSQL with the most recent dump:"
    LATEST_DUMP=$(ls -1 "$TARGET_DIR"/db_*.sql 2>/dev/null | sort | tail -n1 || true)
    if [[ -n "$LATEST_DUMP" ]]; then
        echo "  docker exec -i ${PG_CONTAINER:-immich_postgres} psql -U ${PG_USER:-postgres} -d postgres < $LATEST_DUMP"
    else
        echo "  (no db_*.sql found in $TARGET_DIR — check the extraction)"
    fi
    echo
    echo "Then start Immich and re-run the thumbnail / transcoding jobs."
}

case "$CMD" in
    request) cmd_request "$@" ;;
    extract) cmd_extract "$@" ;;
    latest)  cmd_latest ;;
    list)    cmd_list ;;
    *)       usage ;;
esac
