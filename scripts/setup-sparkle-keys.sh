#!/bin/zsh
# One-time: create the EdDSA key pair that signs every Airlock update.
#
#   zsh scripts/setup-sparkle-keys.sh
#
# NOT run automatically, for the same reason as setup-dev-signing.sh: it writes
# a private key into your login keychain, and that is not something a build
# script should do behind your back.
#
# WHAT THIS KEY IS. Sparkle verifies every downloaded update against the public
# half, which is compiled into the app bundle. The signature is the trust, not
# the download — so whoever hosts the appcast and the DMG can be compromised
# entirely and users are still safe, because an attacker cannot produce a
# signature without the private half.
#
# WHICH MEANS: back up the private key. Losing it does not break installed
# copies, but it means you can never ship them another update — every existing
# user would have to download a new build by hand. Keeping it somewhere only you
# can reach matters just as much: anyone holding it can push code to every
# Airlock install in the world.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOL=".build/artifacts/sparkle/Sparkle/bin/generate_keys"
PUBLIC_KEY_FILE="Configuration/sparkle-public-key.txt"

if [[ ! -x "$TOOL" ]]; then
  echo "▸ resolving Sparkle first"
  swift package resolve > /dev/null
fi
[[ -x "$TOOL" ]] || { print -u2 "✗ $TOOL not found. Run: swift package resolve"; exit 1 }

echo "▸ generating (or reading) the EdDSA key pair"
# generate_keys is idempotent: with a key already in the keychain it prints the
# existing public half rather than replacing it, so re-running is safe and does
# not orphan installed copies.
"$TOOL"

echo ""
echo "Paste the public key above into $PUBLIC_KEY_FILE — one line, no quotes."
echo "It is PUBLIC and belongs in git: packaging reads it into SUPublicEDKey,"
echo "and an app whose key is not committed cannot verify its own updates."
