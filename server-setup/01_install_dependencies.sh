#!/bin/bash
# Install AWS CLI v2, the IAM Roles Anywhere signing helper, and jq.
set -euo pipefail

# === AWS CLI v2 ===
if ! command -v aws >/dev/null 2>&1 || ! aws --version 2>/dev/null | grep -q 'aws-cli/2'; then
    cd /tmp
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
    unzip -q -o awscliv2.zip
    sudo ./aws/install --update
    rm -rf awscliv2.zip aws/
fi

# === IAM Roles Anywhere signing helper ===
# Check the latest release at:
#   https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html
SIGNING_HELPER_VERSION="${SIGNING_HELPER_VERSION:-1.1.1}"
if [[ ! -x /usr/local/bin/aws_signing_helper ]] \
   || ! /usr/local/bin/aws_signing_helper version 2>/dev/null \
        | grep -q "$SIGNING_HELPER_VERSION"; then
    sudo curl -fsSL \
        "https://rolesanywhere.amazonaws.com/releases/${SIGNING_HELPER_VERSION}/X86_64/Linux/aws_signing_helper" \
        -o /usr/local/bin/aws_signing_helper
    sudo chmod +x /usr/local/bin/aws_signing_helper
fi

# === Other tools ===
sudo apt-get update -qq
sudo apt-get install -y jq curl unzip openssl

echo "Installed:"
aws --version
/usr/local/bin/aws_signing_helper version 2>/dev/null || \
    /usr/local/bin/aws_signing_helper --version 2>/dev/null || true
jq --version
