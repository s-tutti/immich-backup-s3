#!/bin/bash
# Renew the IAM Roles Anywhere client certificate before it expires.
#
# Runs from root cron (needs read access to /etc/aws/ca-key.pem, 0600 root).
# Re-signs cert.pem using the existing local CA — Trust Anchor stays valid.
#
# Behavior:
#   - cert > RENEW_THRESHOLD_DAYS days from expiry → silent OK (log only)
#   - cert ≤ RENEW_THRESHOLD_DAYS days from expiry → renew + Slack :sparkles:
#   - any failure                                  → Slack :rotating_light:
#
# Override defaults via env:
#   RENEW_DAYS=730              # new cert validity (default 2 years)
#   RENEW_THRESHOLD_DAYS=60     # renew when this many days or fewer remain
#   FORCE=1                     # renew unconditionally (for manual testing)
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
[[ -f "$PROJECT_ROOT/.env" ]] && source "$PROJECT_ROOT/.env"

: "${CERT_PATH:?CERT_PATH not set in .env}"
: "${KEY_PATH:?KEY_PATH not set in .env}"
: "${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL not set in .env}"

CA_CERT="${CA_CERT_INTERNAL:-/etc/aws/ca-cert.pem}"
CA_KEY="${CA_KEY_INTERNAL:-/etc/aws/ca-key.pem}"
RENEW_DAYS="${RENEW_DAYS:-730}"
RENEW_THRESHOLD_DAYS="${RENEW_THRESHOLD_DAYS:-60}"
HOST_CN="${HOST_CN:-$(hostname)}"
HOST=$(hostname)

post_slack() {
    local text=$1
    curl -fsS --max-time 10 \
        -X POST -H "Content-Type: application/json" \
        --data "$(jq -n --arg t "$text" '{text:$t}')" \
        "$SLACK_WEBHOOK_URL" >/dev/null || true
}

on_error() {
    local code=$?
    post_slack ":rotating_light: *Immich cert renewal: FAILED* on \`${HOST}\` (exit=${code} line=${BASH_LINENO[0]:-?})"
    exit "$code"
}
trap on_error ERR

[[ -r "$CERT_PATH" ]] || { echo "ERROR: cannot read $CERT_PATH (need root?)" >&2; exit 2; }
[[ -r "$CA_CERT"   ]] || { echo "ERROR: cannot read $CA_CERT" >&2; exit 2; }
[[ -r "$CA_KEY"    ]] || { echo "ERROR: cannot read $CA_KEY (need root)" >&2; exit 2; }

END=$(openssl x509 -in "$CERT_PATH" -noout -enddate | cut -d= -f2)
END_EPOCH=$(date -u -d "$END" +%s)
NOW_EPOCH=$(date -u +%s)
DAYS_LEFT=$(( (END_EPOCH - NOW_EPOCH) / 86400 ))

if [[ "${FORCE:-0}" != "1" ]] && (( DAYS_LEFT > RENEW_THRESHOLD_DAYS )); then
    echo "[cert-renew] $(date -u +%FT%TZ) cert OK: ${DAYS_LEFT}d remaining (threshold=${RENEW_THRESHOLD_DAYS}d)"
    exit 0
fi

echo "[cert-renew] $(date -u +%FT%TZ) renewing cert (${DAYS_LEFT}d remaining, threshold=${RENEW_THRESHOLD_DAYS}d)"

WORK=$(mktemp -d)
# Override trap so $WORK is cleaned up on error too
trap 'rm -rf "$WORK"; on_error' ERR

NEW_KEY="$WORK/key.pem"
NEW_CSR="$WORK/csr.pem"
NEW_CERT="$WORK/cert.pem"
EXT="$WORK/ext.cnf"

openssl req -newkey rsa:4096 \
    -keyout "$NEW_KEY" -out "$NEW_CSR" \
    -nodes -subj "/CN=${HOST_CN}"

cat > "$EXT" <<'EXTEOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EXTEOF

openssl x509 -req \
    -in "$NEW_CSR" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$NEW_CERT" \
    -days "$RENEW_DAYS" \
    -extfile "$EXT"

# Keep old cert/key as .bak in case the new pair has trouble in practice.
# (The next backup attempt will surface any issue via Slack :rotating_light:.)
cp -p "$CERT_PATH" "${CERT_PATH}.bak"
cp -p "$KEY_PATH"  "${KEY_PATH}.bak"

# Install with the same ownership/permissions as 02_generate_certs.sh produced
# and README "B. 権限の整備" expects:
#   cert.pem  0644 root:root  (world-readable public cert)
#   key.pem   0640 root:immich (immich needs read access for aws_signing_helper)
install -m 0644 -o root -g root   "$NEW_CERT" "$CERT_PATH"
install -m 0640 -o root -g immich "$NEW_KEY"  "$KEY_PATH"

rm -rf "$WORK"
trap on_error ERR

NEW_END=$(openssl x509 -in "$CERT_PATH" -noout -enddate | cut -d= -f2)

post_slack ":sparkles: *Immich client cert renewed* on \`${HOST}\`
• Previous remaining: \`${DAYS_LEFT}d\`
• New expiry: \`${NEW_END}\` (~${RENEW_DAYS}d validity)
• Old cert/key saved as \`${CERT_PATH}.bak\` / \`${KEY_PATH}.bak\`"

echo "[cert-renew] $(date -u +%FT%TZ) renewed; new expiry: $NEW_END"
