#!/bin/zsh
# One-time: create the Ed25519 key pair that signs every Airlock licence.
#
#   zsh scripts/setup-license-key.sh
#
# NOT run automatically, for the same reason as setup-dev-signing.sh and
# setup-sparkle-keys.sh: it writes a private key into your login keychain, and
# that is not something a build script should do behind your back.
#
# WHAT THIS KEY IS. Every Airlock licence is a small JSON payload signed with
# the private half. The app carries only the public half, compiled into the
# bundle, and checks the signature on this Mac with nothing sent anywhere. That
# asymmetry is what lets a paid app keep saying "local-first, no telemetry".
#
# WHICH MEANS: back it up somewhere only you can reach.
#   - Lose it and every licence already issued keeps working — they were signed
#     before it went — but you can never issue or renew another one. Every
#     customer eventually lands on `overdue`.
#   - Leak it and anyone can mint their own licences, and there is no revoking
#     what is already signed.
#
# THE PRIVATE HALF IS NEVER PRINTED by this script. It goes keychain → clipboard
# and nowhere else, so it cannot end up in a terminal scrollback, a screen
# share, or a transcript.
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE="airlock-license-signing"
PUBLIC_KEY_FILE="Configuration/license-public-key.txt"

existing="$(security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null || true)"

if [[ -n "$existing" ]]; then
  # Idempotent on purpose. Replacing a live signing key would orphan every
  # licence ever issued, so a second run reads the existing one and re-derives
  # the public half rather than generating anything.
  echo "▸ a signing key already exists in your login keychain — reusing it"
  public="$(AIRLOCK_LICENSE_KEY="$existing" swift run -q LicenseTool pubkey)"
  private="$existing"
else
  echo "▸ generating a new Ed25519 signing key pair"
  generated="$(swift run -q LicenseTool new-key)"
  # Positional extraction, and never an echo: the private half must not reach
  # stdout at any point in this script.
  public="$(printf '%s\n' "$generated" | sed -n '2p')"
  private="$(printf '%s\n' "$generated" | sed -n '5p')"

  [[ -n "$public" && -n "$private" ]] || { print -u2 "✗ could not read the generated key pair"; exit 1 }

  security add-generic-password -a "$USER" -s "$SERVICE" -w "$private" \
    -D "Airlock licence signing key" \
    -j "Signs Airlock licences. Losing it means no new licences; leaking it means anyone can mint them."
  echo "  stored in your login keychain as \"$SERVICE\""
fi

mkdir -p "$(dirname "$PUBLIC_KEY_FILE")"
printf '%s\n' "$public" > "$PUBLIC_KEY_FILE"
echo "  public half written to $PUBLIC_KEY_FILE (commit it — it is public)"

printf '%s' "$private" | pbcopy
echo ""
echo "The PRIVATE half is now on your clipboard, and has not been displayed."
echo "Paste it into your password manager NOW, then copy something else."
echo ""
echo "It is needed in exactly two more places:"
echo ""
echo "  # the licence server"
echo "  cd worker && wrangler secret put LICENSE_PRIVATE_KEY"
echo ""
echo "  # issuing a licence by hand, e.g. for yourself"
echo "  AIRLOCK_LICENSE_KEY=\$(security find-generic-password -a \"\$USER\" -s $SERVICE -w) \\"
echo "    swift run LicenseTool issue you@example.com yearly"
