#!/bin/zsh
# One-time: create a self-signed "agentic-notch-dev" code-signing certificate.
#
# Why: macOS keys TCC grants (Automation for terminal jump-back, Accessibility
# later) to the app's code-signing identity. Ad-hoc-signed builds get a new
# cdhash every rebuild, silently invalidating those grants. Signing every dev
# build with this one stable identity means you grant permissions once.
#
# Expect up to two GUI prompts:
#   - trusting the new certificate (add-trusted-cert)
#   - first codesign use of the key (click "Always Allow")
# If auto-trust fails, open Keychain Access → My Certificates →
# agentic-notch-dev → Trust → Code Signing: Always Trust.
set -euo pipefail

NAME="agentic-notch-dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ '$NAME' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/dev.p12" -passout pass:agentic-notch -name "$NAME"

security import "$TMP/dev.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P agentic-notch -T /usr/bin/codesign

if ! security add-trusted-cert -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"; then
  echo "⚠ Could not auto-trust the certificate. Open Keychain Access and set"
  echo "  '$NAME' → Trust → Code Signing to 'Always Trust', then re-run packaging."
fi

echo ""
echo "✓ Created '$NAME'. Package with it:"
echo "    zsh scripts/package-app.sh          # picks it up automatically"
