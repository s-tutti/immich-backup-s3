#!/bin/bash
# One-time: generate a private CA + a client certificate for this server.
# Outputs:
#   /etc/aws/ca-cert.pem   - register this with IAM Roles Anywhere as the trust anchor
#   /etc/aws/ca-key.pem    - CA private key (KEEP SECURE; not used at runtime)
#   /etc/aws/cert.pem      - server's client cert
#   /etc/aws/key.pem       - server's private key (used by aws_signing_helper)
#
# If you later add a second server, sign a new cert with the same CA so the same
# trust anchor keeps working.
set -euo pipefail

OUT_DIR="${OUT_DIR:-/etc/aws}"
CA_DAYS="${CA_DAYS:-3650}"
CERT_DAYS="${CERT_DAYS:-365}"
HOST_CN="${HOST_CN:-$(hostname)}"

sudo mkdir -p "$OUT_DIR"
sudo chmod 700 "$OUT_DIR"

# === CA ===
# IAM Roles Anywhere requires the trust anchor cert to have:
#   basicConstraints=critical,CA:TRUE
#   keyUsage=keyCertSign,cRLSign
# Without these the create-trust-anchor call returns
# "Incorrect basic constraints for CA certificate".
if [[ ! -f "$OUT_DIR/ca-cert.pem" ]]; then
    echo "Generating CA (days=$CA_DAYS)"
    sudo openssl req -x509 -newkey rsa:4096 \
        -keyout "$OUT_DIR/ca-key.pem" -out "$OUT_DIR/ca-cert.pem" \
        -days "$CA_DAYS" -nodes \
        -subj "/CN=ImmichBackupCA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash"
else
    echo "CA already exists at $OUT_DIR/ca-cert.pem (skipping)."
fi

# === Client cert ===
# IAM Roles Anywhere wants leaf certs with extendedKeyUsage=clientAuth and
# basicConstraints=CA:FALSE.
if [[ ! -f "$OUT_DIR/cert.pem" ]]; then
    echo "Generating client cert for CN=$HOST_CN (days=$CERT_DAYS)"
    sudo openssl req -newkey rsa:4096 \
        -keyout "$OUT_DIR/key.pem" -out "$OUT_DIR/csr.pem" \
        -nodes -subj "/CN=$HOST_CN"

    EXT=$(mktemp)
    cat > "$EXT" <<'EXTEOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EXTEOF

    sudo openssl x509 -req \
        -in "$OUT_DIR/csr.pem" \
        -CA "$OUT_DIR/ca-cert.pem" -CAkey "$OUT_DIR/ca-key.pem" \
        -CAcreateserial \
        -out "$OUT_DIR/cert.pem" \
        -days "$CERT_DAYS" \
        -extfile "$EXT"

    rm -f "$EXT"
    sudo rm -f "$OUT_DIR/csr.pem"
fi

sudo chown root:root "$OUT_DIR"/*.pem
# Private keys: root-only.
sudo chmod 600 "$OUT_DIR/ca-key.pem" "$OUT_DIR/key.pem"
# Public certs: world-readable. ca-cert.pem in particular needs to be portable
# (copy to the admin machine to register as the IAM Roles Anywhere trust anchor).
# cert.pem also needs read access for the operational user — see README "B. 権限の整備".
sudo chmod 644 "$OUT_DIR/ca-cert.pem" "$OUT_DIR/cert.pem"

echo ""
echo "✓ Certs ready:"
ls -l "$OUT_DIR"
echo ""
echo "Next: register the CA cert as the IAM Roles Anywhere Trust Anchor:"
echo "  CA_CERT_PATH=$OUT_DIR/ca-cert.pem ./aws-setup/04_setup_roles_anywhere.sh"
