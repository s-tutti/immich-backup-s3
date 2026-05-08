#!/bin/bash
# Create an EventBridge Scheduler rule that invokes the monitor Lambda daily.
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

: "${AWS_REGION:?}"

LAMBDA_NAME="ImmichBackupMonitor"
SCHEDULE_NAME="ImmichBackupDailyMonitor"
SCHEDULER_ROLE_NAME="ImmichBackupSchedulerRole"
SCHED_EXPR="cron(0 4 * * ? *)"   # 04:00 UTC every day (= 13:00 JST)

LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" \
    --region "$AWS_REGION" --query 'Configuration.FunctionArn' --output text)

# 1) Scheduler role
TRUST=$(mktemp)
cat > "$TRUST" <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "scheduler.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }]
}
EOF

if aws iam get-role --role-name "$SCHEDULER_ROLE_NAME" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$SCHEDULER_ROLE_NAME" \
        --policy-document "file://$TRUST"
else
    aws iam create-role --role-name "$SCHEDULER_ROLE_NAME" \
        --assume-role-policy-document "file://$TRUST"
fi
rm -f "$TRUST"

aws iam put-role-policy \
    --role-name "$SCHEDULER_ROLE_NAME" \
    --policy-name "InvokeMonitorLambda" \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
            \"Effect\": \"Allow\",
            \"Action\": \"lambda:InvokeFunction\",
            \"Resource\": \"$LAMBDA_ARN\"
        }]
    }"

sleep 10
SCHEDULER_ROLE_ARN=$(aws iam get-role --role-name "$SCHEDULER_ROLE_NAME" --query 'Role.Arn' --output text)

# 2) Schedule
TARGET="{\"Arn\":\"$LAMBDA_ARN\",\"RoleArn\":\"$SCHEDULER_ROLE_ARN\"}"

if aws scheduler get-schedule --name "$SCHEDULE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    aws scheduler update-schedule \
        --name "$SCHEDULE_NAME" \
        --schedule-expression "$SCHED_EXPR" \
        --schedule-expression-timezone "UTC" \
        --flexible-time-window "Mode=OFF" \
        --target "$TARGET" \
        --region "$AWS_REGION"
else
    aws scheduler create-schedule \
        --name "$SCHEDULE_NAME" \
        --schedule-expression "$SCHED_EXPR" \
        --schedule-expression-timezone "UTC" \
        --flexible-time-window "Mode=OFF" \
        --target "$TARGET" \
        --region "$AWS_REGION"
fi

echo "✓ Schedule '$SCHEDULE_NAME' is firing $SCHED_EXPR (UTC)."
