#!/bin/bash
# Create the S3 bucket with public-access block + default SSE-S3 encryption.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"

: "${S3_BUCKET:?S3_BUCKET not set in .env}"
: "${AWS_REGION:?AWS_REGION not set in .env}"

echo "Creating bucket: $S3_BUCKET in $AWS_REGION"

if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
        --bucket "$S3_BUCKET" \
        --region "$AWS_REGION"
else
    aws s3api create-bucket \
        --bucket "$S3_BUCKET" \
        --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi

# Block all public access
aws s3api put-public-access-block \
    --bucket "$S3_BUCKET" \
    --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Default SSE-S3 (AWS-managed key)
aws s3api put-bucket-encryption \
    --bucket "$S3_BUCKET" \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
            "BucketKeyEnabled": false
        }]
    }'

echo "✓ Bucket created with public-access block + SSE-S3."
