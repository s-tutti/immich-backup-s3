#!/bin/bash
# Apply lifecycle rules: incremental 180-day expiry + abort incomplete multipart.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
# Bootstrap scripts need admin AWS credentials. The runtime AWS_PROFILE in
# .env (immich-backup, used by cron) only has minimal permissions, so we ignore
# whatever .env sets for AWS_PROFILE. Anything the user exported BEFORE running
# this script is preserved (so "AWS_PROFILE=admin ./00_bootstrap_ci.sh" works).
PRE_AWS_PROFILE="${AWS_PROFILE:-}"
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"
if [[ -n "$PRE_AWS_PROFILE" ]]; then
    export AWS_PROFILE="$PRE_AWS_PROFILE"
else
    unset AWS_PROFILE
fi

: "${S3_BUCKET:?}"

aws s3api put-bucket-lifecycle-configuration \
    --bucket "$S3_BUCKET" \
    --lifecycle-configuration "file://$SCRIPT_DIR/02_lifecycle_policy.json"

echo "✓ Lifecycle policy applied to $S3_BUCKET"
aws s3api get-bucket-lifecycle-configuration --bucket "$S3_BUCKET"
