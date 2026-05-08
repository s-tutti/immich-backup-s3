#!/bin/bash
# Install a GitHub Actions self-hosted runner as a systemd service, owned by
# a dedicated 'gh-runner' system user, and prepare /opt/immich-backup-s3 as
# the deploy target.
#
# Get a registration token at:
#   https://github.com/<owner>/<repo>/settings/actions/runners/new
# (token is valid for 1 hour)
#
# Usage:
#   GITHUB_RUNNER_TOKEN=AAAA... ./server-setup/04_install_github_runner.sh
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"

: "${GITHUB_REPO:?GITHUB_REPO not set in .env}"
: "${GITHUB_RUNNER_TOKEN:?GITHUB_RUNNER_TOKEN not set (one-shot, get it from repo Settings → Actions → Runners → New)}"

# Default to the existing 'immich' user (also runs the cron backup jobs).
# /usr/sbin/nologin is fine — systemd / sudo -u don't need a login shell.
RUNNER_USER="${RUNNER_USER:-immich}"
DEPLOY_TARGET="${DEPLOY_TARGET:-/opt/immich-backup-s3}"

# Resolve the user's home dynamically so we don't override an existing user's home.
if id "$RUNNER_USER" >/dev/null 2>&1; then
    USER_HOME=$(getent passwd "$RUNNER_USER" | cut -d: -f6)
else
    USER_HOME="/home/$RUNNER_USER"
fi
RUNNER_HOME="${RUNNER_HOME:-$USER_HOME/actions-runner}"

# 1) Resolve latest runner version (or pin via env)
if [[ -z "${RUNNER_VERSION:-}" ]]; then
    RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | jq -r '.tag_name' | sed 's/^v//')
fi
echo "Runner version: $RUNNER_VERSION"

# 2) Runner user. If $RUNNER_USER doesn't exist, create as a system account.
#    If it exists (e.g. 'immich'), reuse it as-is — don't touch its home or shell.
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
    sudo useradd --system --create-home --home-dir "$USER_HOME" \
        --shell /bin/bash --comment "Self-hosted runner" "$RUNNER_USER"
fi

# 3) Runner install dir (under the user's home so SSH/awscli config naturally
#    co-locates).
sudo install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0750 "$RUNNER_HOME"

# 4) Deploy target. Same user as the runner = same user as cron, so 0750 is enough.
sudo install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0750 "$DEPLOY_TARGET"

# 5) Install dependencies the runner uses
sudo apt-get update -qq
sudo apt-get install -y rsync curl jq unzip libicu-dev

# 6) Download + configure runner (skip if already configured)
sudo -u "$RUNNER_USER" -H bash <<EOSCRIPT
set -euo pipefail
cd "$RUNNER_HOME"
if [[ ! -x ./config.sh ]]; then
    curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    tar xzf runner.tar.gz
    rm runner.tar.gz
fi
if [[ ! -f .runner ]]; then
    ./config.sh \
        --url "https://github.com/${GITHUB_REPO}" \
        --token "${GITHUB_RUNNER_TOKEN}" \
        --name "$(hostname)" \
        --labels "self-hosted,linux,x64,immich-backup" \
        --work "_work" \
        --unattended \
        --replace
else
    echo "Runner already configured ($(cat .runner | jq -r '.agentName'))."
fi
EOSCRIPT

# 7) systemd service (svc.sh writes /etc/systemd/system/actions.runner.*)
cd "$RUNNER_HOME"
if ! systemctl list-unit-files | grep -q "^actions.runner\."; then
    sudo ./svc.sh install "$RUNNER_USER"
fi
sudo ./svc.sh start

SVC_NAME=$(systemctl list-unit-files | awk '/^actions\.runner\./ {print $1; exit}')

echo ""
echo "✓ Self-hosted runner installed."
echo "  User:          $RUNNER_USER"
echo "  Runner home:   $RUNNER_HOME"
echo "  Deploy target: $DEPLOY_TARGET (owned by $RUNNER_USER)"
echo "  Service:       $SVC_NAME"
echo ""
echo "Status:        sudo systemctl status $SVC_NAME"
echo "Logs:          sudo journalctl -u $SVC_NAME -f"
echo ""
echo "Next:"
echo "  1. After the first deploy run, place secrets in:"
echo "       $DEPLOY_TARGET/.env  (owner: $RUNNER_USER, mode 0600)"
echo "     This file is excluded from rsync, so it survives subsequent deploys."
echo "  2. Install the cron entries as the same user:"
echo "       sudo crontab -u $RUNNER_USER $DEPLOY_TARGET/cron/immich-backup.crontab"
