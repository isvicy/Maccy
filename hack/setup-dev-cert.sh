#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing certificate so Maccy-dev's
# bundle signature stays stable across rebuilds. macOS's TCC (Privacy &
# Security) keys Accessibility / Input Monitoring grants on bundle id +
# signing identity. With ad-hoc signing every build produces a different
# code-directory hash, silently invalidating prior grants. Signing with a
# stable identity makes grants persist across rebuilds.
#
# Run once:
#   ./hack/setup-dev-cert.sh
#
# After this, ./hack/build-dev.sh will sign with the new identity.
# You will be prompted for your login keychain password twice (once on
# import, once when allowing codesign to use the key).
#
# After the next build + install + launch, re-grant Accessibility once.
# All subsequent rebuilds preserve the grant.

set -euo pipefail

CERT_NAME="Maccy Dev Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "Identity '$CERT_NAME' already exists in login keychain. Nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $CERT_NAME
O = Personal
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "Generating 2048-bit RSA key + self-signed cert (10-year validity)…"
openssl req -x509 -newkey rsa:2048 \
  -keyout "$TMP/key.pem" \
  -out "$TMP/cert.pem" \
  -days 3650 -nodes \
  -config "$TMP/cert.cnf" \
  -extensions v3 \
  >/dev/null 2>&1

openssl pkcs12 -export -legacy \
  -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" \
  -name "$CERT_NAME" \
  -password pass:

echo ""
echo "Importing into login keychain. You may be prompted for your login password."
security import "$TMP/cert.p12" \
  -k "$KEYCHAIN" \
  -P "" \
  -T /usr/bin/codesign

echo ""
echo "Allowing codesign to use the key without per-launch prompt."
echo "You will be prompted for your login password once more."
security set-key-partition-list \
  -S "apple-tool:,apple:,codesign:" \
  -s -k "" \
  "$KEYCHAIN" \
  >/dev/null 2>&1 || \
  security set-key-partition-list \
  -S "apple-tool:,apple:,codesign:" \
  -s \
  "$KEYCHAIN"

echo ""
echo "Done. Verifying:"
security find-identity -p codesigning -v "$KEYCHAIN" | grep "$CERT_NAME" || {
  echo "WARNING: identity not found after import." >&2
  exit 1
}

echo ""
echo "Next: ./hack/build-dev.sh --install"
echo "Then re-grant Accessibility once for the new signature; future rebuilds preserve it."
