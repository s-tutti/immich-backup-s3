#!/bin/bash
# Delete old full backups from S3 once they're past RETENTION_DAYS.
# Usage: cleanup_old_full.sh [<new-full-date>]
#   The optional argument is the date string of the just-uploaded full,
#   which is excluded from deletion as a safety belt.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"

: "${S3_BUCKET:?}" "${AWS_PROFILE:?}" "${RETENTION_DAYS:?}"

NEW_DATE=${1:-}
NOW_EPOCH=$(date -u +%s)

# Iterate every manifest.json under full/. The manifest's LastModified is a
# proxy for the upload time of that full backup.
aws s3api list-objects-v2 \
    --bucket "$S3_BUCKET" \
    --prefix "full/" \
    --query "Contents[?ends_with(Key, 'manifest.json')].[Key,LastModified]" \
    --output text \
    --profile "$AWS_PROFILE" \
| while IFS=$'\t' read -r KEY LAST_MOD; do
    [[ -z "${KEY:-}" ]] && continue
    if [[ -n "$NEW_DATE" && "$KEY" == *"$NEW_DATE"* ]]; then
        continue
    fi

    UPLOAD_EPOCH=$(date -u -d "$LAST_MOD" +%s)
    AGE_DAYS=$(( (NOW_EPOCH - UPLOAD_EPOCH) / 86400 ))
    PREFIX=$(dirname "$KEY")

    if (( AGE_DAYS >= RETENTION_DAYS )); then
        echo "Deleting old full: $PREFIX (age=${AGE_DAYS}d ≥ ${RETENTION_DAYS}d)"
        aws s3 rm "s3://${S3_BUCKET}/${PREFIX}/" \
            --recursive \
            --profile "$AWS_PROFILE"
    else
        echo "Keeping: $PREFIX (age=${AGE_DAYS}d < ${RETENTION_DAYS}d)"
    fi
done
