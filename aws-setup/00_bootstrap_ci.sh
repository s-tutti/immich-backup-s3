#!/bin/bash
# One-time setup: register GitHub Actions as an OIDC identity provider in AWS,
# then create the IAM role that the deploy workflow assumes.
#
# Trust is scoped to:  repo:<GITHUB_REPO>:ref:refs/heads/main
# i.e. only main-branch pushes to your repo can assume this role.
#
# Run this from a shell with admin AWS credentials. Run once.
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

: "${S3_BUCKET:?S3_BUCKET not set}"
: "${AWS_REGION:?AWS_REGION not set}"
: "${GITHUB_REPO:?GITHUB_REPO not set in .env (e.g. s-tutti/immich-backup-s3)}"

OIDC_HOST="token.actions.githubusercontent.com"
OIDC_AUD="sts.amazonaws.com"
# GitHub's OIDC certificate thumbprints (DigiCert). AWS no longer verifies these
# strictly for the well-known GitHub provider, but the API still requires one.
OIDC_THUMBPRINTS=(
    "6938fd4d98bab03faadb97b34396831e3780aea1"
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
)
ROLE_NAME="ImmichBackupCIDeployRole"
POLICY_NAME="ImmichBackupCIDeployPolicy"

# 1) OIDC provider (idempotent)
EXISTING=$(aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_HOST')].Arn" \
    --output text)
if [[ -z "$EXISTING" ]]; then
    echo "Creating OIDC provider for $OIDC_HOST"
    aws iam create-open-id-connect-provider \
        --url "https://$OIDC_HOST" \
        --client-id-list "$OIDC_AUD" \
        --thumbprint-list "${OIDC_THUMBPRINTS[@]}"
    OIDC_ARN=$(aws iam list-open-id-connect-providers \
        --query "OpenIDConnectProviderList[?contains(Arn, '$OIDC_HOST')].Arn" \
        --output text)
else
    OIDC_ARN="$EXISTING"
    echo "OIDC provider already exists: $OIDC_ARN"
fi

# 2) Trust policy (only the main branch of this specific repo)
TRUST=$(mktemp)
cat > "$TRUST" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Federated": "$OIDC_ARN"},
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
            "StringEquals": {
                "$OIDC_HOST:aud": "$OIDC_AUD"
            },
            "StringLike": {
                "$OIDC_HOST:sub": "repo:$GITHUB_REPO:ref:refs/heads/main"
            }
        }
    }]
}
EOF

# 3) Permissions policy (substitute bucket name)
PERMS=$(mktemp)
sed "s/BUCKET_NAME/$S3_BUCKET/g" "$SCRIPT_DIR/00_ci_deploy_policy.json" > "$PERMS"

# 4) Create or update role
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "Role $ROLE_NAME exists; updating trust policy."
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
        --policy-document "file://$TRUST"
else
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$TRUST" \
        --description "Assumed by GitHub Actions deploy workflow via OIDC"
fi
aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$PERMS"

rm -f "$TRUST" "$PERMS"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
echo ""
echo "✓ CI deploy role: $ROLE_ARN"
echo ""
echo "Add these GitHub repository secrets at:"
echo "  https://github.com/$GITHUB_REPO/settings/secrets/actions"
echo ""
echo "  AWS_DEPLOY_ROLE_ARN  = $ROLE_ARN"
echo "  AWS_REGION           = $AWS_REGION"
echo "  S3_BUCKET            = $S3_BUCKET"
echo "  SLACK_WEBHOOK_URL    = (your Slack incoming webhook URL)"
