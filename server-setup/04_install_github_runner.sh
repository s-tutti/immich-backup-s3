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

RUNNER_USER="${RUNNER_USER:-gh-runner}"
RUNNER_HOME="${RUNNER_HOME:-/opt/actions-runner}"
DEPLOY_TARGET="${DEPLOY_TARGET:-/opt/immich-backup-s3}"

# 1) Resolve latest runner version (or pin via env)
if [[ -z "${RUNNER_VERSION:-}" ]]; then
    RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | jq -r '.tag_name' | sed 's/^v//')
fi
echo "Runner version: $RUNNER_VERSION"

# 2) Runner user (system account, no shell login)
if ! id "$RUNNER_USER" >/dev/null 2>&1; then
    sudo useradd --system --create-home --home-dir "$RUNNER_HOME" \
        --shell /bin/bash --comment "GitHub Actions runner" "$RUNNER_USER"
fi

# 3) Deploy target (writable by runner)
sudo mkdir -p "$DEPLOY_TARGET"
sudo chown "$RUNNER_USER:$RUNNER_USER" "$DEPLOY_TARGET"
# Other users (e.g. the cron user) need read+execute to run scripts from here.
sudo chmod 0755 "$DEPLOY_TARGET"

# 4) Install dependencies the runner uses
sudo apt-get update -qq
sudo apt-get install -y rsync curl jq unzip libicu-dev

# 5) Download + configure runner (skip if already configured)
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

# 6) systemd service (svc.sh writes /etc/systemd/system/actions.runner.*)
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
echo "       $DEPLOY_TARGET/.env"
echo "     This file is excluded from rsync, so it survives subsequent deploys."
echo "  2. If a different user (e.g. immich-backup) will run the cron jobs,"
echo "     ensure it can read $DEPLOY_TARGET (chmod 0755 already covers that)"
echo "     and read $DEPLOY_TARGET/.env (chown to that user, mode 0600)."
