#!/bin/bash
# Create the IAM role that the on-prem server will assume via Roles Anywhere.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"

: "${S3_BUCKET:?}"

ROLE_NAME="ImmichBackupRole"
POLICY_NAME="ImmichBackupPolicy"

# Substitute the bucket name into the permissions policy
PERMS_FILE=$(mktemp)
sed "s/BUCKET_NAME/$S3_BUCKET/g" "$SCRIPT_DIR/03_iam_permissions_policy.json" > "$PERMS_FILE"

# Create or update the role
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "Role $ROLE_NAME already exists, updating trust policy."
    aws iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document "file://$SCRIPT_DIR/03_iam_trust_policy.json"
else
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$SCRIPT_DIR/03_iam_trust_policy.json" \
        --description "Role assumed via IAM Roles Anywhere for Immich backups"
fi

# Attach the inline permissions policy
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$PERMS_FILE"

rm -f "$PERMS_FILE"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

echo "✓ Role ready: $ROLE_ARN"
echo ""
echo "Add this to .env:"
echo "  export ROLE_ARN=\"$ROLE_ARN\""
