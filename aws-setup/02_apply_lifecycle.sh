#!/bin/bash
# Apply lifecycle rules: incremental 180-day expiry + abort incomplete multipart.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"

: "${S3_BUCKET:?}"

aws s3api put-bucket-lifecycle-configuration \
    --bucket "$S3_BUCKET" \
    --lifecycle-configuration "file://$SCRIPT_DIR/02_lifecycle_policy.json"

echo "✓ Lifecycle policy applied to $S3_BUCKET"
aws s3api get-bucket-lifecycle-configuration --bucket "$S3_BUCKET"
