#!/bin/bash
# Deploy the daily-monitor Lambda function and its IAM role.
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
: "${SLACK_WEBHOOK_URL:?}"
: "${AWS_REGION:?}"

for cmd in zip aws; do
    command -v "$cmd" >/dev/null 2>&1 \
        || { echo "Missing tool: $cmd  (try: sudo apt install -y $cmd)" >&2; exit 1; }
done

LAMBDA_NAME="ImmichBackupMonitor"
LAMBDA_ROLE_NAME="ImmichBackupMonitorRole"
POLICY_NAME="ImmichBackupMonitorPolicy"

# 1) Lambda execution role
TRUST=$(mktemp)
cat > "$TRUST" <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }]
}
EOF

if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
    echo "Lambda role exists; updating trust policy."
    aws iam update-assume-role-policy --role-name "$LAMBDA_ROLE_NAME" \
        --policy-document "file://$TRUST"
else
    aws iam create-role --role-name "$LAMBDA_ROLE_NAME" \
        --assume-role-policy-document "file://$TRUST"
fi
rm -f "$TRUST"

# Attach permissions policy (with bucket name substituted)
PERMS=$(mktemp)
sed "s/BUCKET_NAME/$S3_BUCKET/g" "$SCRIPT_DIR/05_lambda_role_policy.json" > "$PERMS"
aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$PERMS"
rm -f "$PERMS"

LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)
echo "Lambda role: $LAMBDA_ROLE_ARN"

# IAM role propagation can take ~10 s
sleep 10

# 2) Package and deploy the Lambda
WORK=$(mktemp -d)
cp "$SCRIPT_DIR/05_lambda_function.py" "$WORK/lambda_function.py"
(cd "$WORK" && zip -q function.zip lambda_function.py)

ENV_VARS="Variables={SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL,BUCKET=$S3_BUCKET}"

if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "Updating existing Lambda."
    aws lambda update-function-code \
        --function-name "$LAMBDA_NAME" \
        --zip-file "fileb://$WORK/function.zip" \
        --region "$AWS_REGION" >/dev/null
    # Wait for the code update to settle before pushing config.
    aws lambda wait function-updated --function-name "$LAMBDA_NAME" --region "$AWS_REGION"
    aws lambda update-function-configuration \
        --function-name "$LAMBDA_NAME" \
        --environment "$ENV_VARS" \
        --region "$AWS_REGION" >/dev/null
else
    echo "Creating Lambda."
    aws lambda create-function \
        --function-name "$LAMBDA_NAME" \
        --runtime python3.12 \
        --role "$LAMBDA_ROLE_ARN" \
        --handler lambda_function.lambda_handler \
        --zip-file "fileb://$WORK/function.zip" \
        --timeout 60 \
        --memory-size 128 \
        --environment "$ENV_VARS" \
        --region "$AWS_REGION" >/dev/null
fi

rm -rf "$WORK"

LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" \
    --region "$AWS_REGION" --query 'Configuration.FunctionArn' --output text)
echo "✓ Lambda deployed: $LAMBDA_ARN"
