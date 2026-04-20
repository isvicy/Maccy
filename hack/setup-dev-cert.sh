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

# No `-v`: self-signed identities are always untrusted; codesign accepts them anyway.
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "Identity '$CERT_NAME' already exists in login keychain. Nothing to do."
  exit 0
fi

# Clean up orphan cert entries from prior failed runs (same label, no
# matching private key — would prevent the new identity from being usable).
# `delete-certificate -c name` silently no-ops in some macOS versions; use
# explicit SHA-1 hash deletion instead.
HASHES=$(security find-certificate -a -c "$CERT_NAME" -Z "$KEYCHAIN" 2>/dev/null \
  | awk '/SHA-1 hash:/ {print $NF}')
if [[ -n "$HASHES" ]]; then
  for H in $HASHES; do
    echo "Removing orphan cert $H"
    security delete-certificate -Z "$H" "$KEYCHAIN" >/dev/null 2>&1
  done
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

P12_PASS="maccydev"
openssl pkcs12 -export -legacy \
  -macalg sha1 \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES \
  -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" \
  -name "$CERT_NAME" \
  -password "pass:$P12_PASS"

echo ""
echo "Importing into login keychain. You may be prompted for your login password."
security import "$TMP/cert.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASS" \
  -T /usr/bin/codesign

echo ""
echo "Allowing codesign to use the key without per-launch prompt."
echo "Enter your LOGIN keychain password when prompted (this is your Mac login password)."
security set-key-partition-list \
  -S "apple-tool:,apple:,codesign:" \
  -s \
  "$KEYCHAIN"

echo ""
echo "Done. Verifying (self-signed → expect CSSMERR_TP_NOT_TRUSTED — that's fine for codesign):"
security find-identity -p codesigning "$KEYCHAIN" | grep "$CERT_NAME" || {
  echo "WARNING: identity not found after import." >&2
  exit 1
}

echo ""
echo "Next: ./hack/build-dev.sh --install"
echo "Then re-grant Accessibility once for the new signature; future rebuilds preserve it."
