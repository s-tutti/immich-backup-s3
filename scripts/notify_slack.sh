#!/bin/bash
# Post a status line to Slack via incoming webhook.
# Usage: notify_slack.sh <type> <date> <parts> <status> [<detail>]
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"

: "${SLACK_WEBHOOK_URL:?}"

TYPE=${1:?type}
DATE=${2:?date}
PARTS=${3:?parts}
STATUS=${4:?status}
DETAIL=${5:-}

case "$STATUS" in
    SUCCESS) ICON=":white_check_mark:" ;;
    FAILED)  ICON=":rotating_light:"   ;;
    *)       ICON=":information_source:" ;;
esac

HOST=$(hostname)
TEXT="${ICON} *Immich backup ${TYPE}* on \`${HOST}\`
• Date: \`${DATE}\`
• Parts: ${PARTS}
• Status: *${STATUS}*"
[[ -n "$DETAIL" ]] && TEXT+="
• Detail: \`${DETAIL}\`"

PAYLOAD=$(jq -n --arg t "$TEXT" '{text:$t}')

curl -fsS --max-time 10 \
    -X POST -H "Content-Type: application/json" \
    --data "$PAYLOAD" \
    "$SLACK_WEBHOOK_URL" >/dev/null
