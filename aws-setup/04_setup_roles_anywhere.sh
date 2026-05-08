#!/bin/bash
# Create the Trust Anchor (registers your CA) and Profile (binds the role).
# Then tighten the role's trust policy to only this Trust Anchor.
#
# Prerequisites:
#   - $CA_CERT_PATH points to a PEM-encoded CA certificate
#   - 03_create_iam_role.sh has been run and ROLE_ARN is set in .env
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

: "${ROLE_ARN:?ROLE_ARN not set (run 03_create_iam_role.sh first)}"
: "${CA_CERT_PATH:?CA_CERT_PATH not set in .env}"
: "${AWS_REGION:?}"

[[ -f "$CA_CERT_PATH" ]] || { echo "CA cert not found: $CA_CERT_PATH" >&2; exit 1; }

echo "1) Creating Trust Anchor from CA cert: $CA_CERT_PATH"
TA_ARN=$(aws rolesanywhere create-trust-anchor \
    --name "ImmichBackupTrustAnchor" \
    --source "{\"sourceType\":\"CERTIFICATE_BUNDLE\",\"sourceData\":{\"x509CertificateData\":\"$(awk 'NF {sub(/\r/, ""); printf "%s\\n", $0}' "$CA_CERT_PATH")\"}}" \
    --enabled \
    --region "$AWS_REGION" \
    --query 'trustAnchor.trustAnchorArn' --output text)
echo "   TA_ARN=$TA_ARN"

echo "2) Creating Profile bound to role: $ROLE_ARN"
PROFILE_ARN_OUT=$(aws rolesanywhere create-profile \
    --name "ImmichBackupProfile" \
    --role-arns "$ROLE_ARN" \
    --enabled \
    --duration-seconds 3600 \
    --region "$AWS_REGION" \
    --query 'profile.profileArn' --output text)
echo "   PROFILE_ARN=$PROFILE_ARN_OUT"

echo "3) Tightening role trust policy to require this Trust Anchor."
SCOPED=$(mktemp)
cat > "$SCOPED" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "rolesanywhere.amazonaws.com"},
        "Action": ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"],
        "Condition": {
            "ArnEquals": {"aws:SourceArn": "$TA_ARN"}
        }
    }]
}
EOF
aws iam update-assume-role-policy \
    --role-name "ImmichBackupRole" \
    --policy-document "file://$SCOPED"
rm -f "$SCOPED"

echo ""
echo "✓ Roles Anywhere is set up."
echo "Add these to .env:"
echo "  export TRUST_ANCHOR_ARN=\"$TA_ARN\""
echo "  export PROFILE_ARN=\"$PROFILE_ARN_OUT\""
