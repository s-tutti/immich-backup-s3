#!/bin/bash
# Configure ~/.aws/config so the AWS CLI gets short-lived credentials
# from aws_signing_helper (IAM Roles Anywhere).
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"

: "${TRUST_ANCHOR_ARN:?}"
: "${PROFILE_ARN:?}"
: "${ROLE_ARN:?}"
: "${AWS_REGION:?}"
: "${AWS_PROFILE:?}"
: "${CERT_PATH:?}"
: "${KEY_PATH:?}"

[[ -r "$CERT_PATH" ]] || { echo "Cert not readable: $CERT_PATH" >&2; exit 1; }
[[ -r "$KEY_PATH"  ]] || { echo "Key not readable: $KEY_PATH"   >&2; exit 1; }

CRED_PROCESS="/usr/local/bin/aws_signing_helper credential-process \
--certificate $CERT_PATH \
--private-key $KEY_PATH \
--trust-anchor-arn $TRUST_ANCHOR_ARN \
--profile-arn $PROFILE_ARN \
--role-arn $ROLE_ARN"

aws configure set --profile "$AWS_PROFILE" region "$AWS_REGION"
aws configure set --profile "$AWS_PROFILE" credential_process "$CRED_PROCESS"

# 100 GB chunk objects need ≥ 10 MB parts to stay under the 10,000-part cap.
# 100 MB chunks → 1,000 parts per chunk. Comfortable headroom + low PUT count.
aws configure set --profile "$AWS_PROFILE" s3.multipart_chunksize "100MB"
aws configure set --profile "$AWS_PROFILE" s3.multipart_threshold "100MB"

echo "✓ Configured profile [$AWS_PROFILE]."
echo "Smoke test:"
echo "  aws s3 ls s3://\$S3_BUCKET --profile $AWS_PROFILE"
