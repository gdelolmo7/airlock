#!/bin/zsh
# One-time: create the X25519 key pair a Free call's locked part is sealed to.
#
#   zsh scripts/setup-call-lock-key.sh
#
# NOT run automatically, for the same reason as setup-license-key.sh: it
# writes a private key into your login keychain.
#
# WHAT THIS KEY IS. On Free, call notes cover the first 30 minutes and the
# rest of the call is locked on the Mac: sealed with a key made for that call,
# which is sealed in turn to the public half of this pair. The app carries the
# public half; only the licence server holds the private half, and it opens a
# call's key only for a paid plan (worker/README.md, "Locked calls").
#
# WHICH MEANS:
#   - Lose it and every call locked so far can never be opened. Run this again
#     and new calls lock to the new pair; the old ones are deleted after their
#     week, as they would have been.
#   - Leak it and anyone with a locked call's file can open it.
#
# THE SERVER GOES FIRST. Put the private half on the Worker and deploy it
# before packaging an app with the public half, or Plus can't open what that
# app locks until you do.
#
# THE PRIVATE HALF IS NEVER PRINTED. It goes keychain → clipboard and nowhere
# else.
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE="airlock-call-lock"
PUBLIC_KEY_FILE="Configuration/call-lock-public-key.txt"

existing="$(security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null || true)"

if [[ -n "$existing" ]]; then
  # Idempotent on purpose: a new pair would leave every locked call unopenable.
  echo "▸ a call lock key already exists in your login keychain — reusing it"
  public="$(AIRLOCK_CALL_LOCK_KEY="$existing" swift run -q LicenseTool call-lock-pubkey)"
  private="$existing"
else
  echo "▸ generating a new X25519 call lock key pair"
  generated="$(swift run -q LicenseTool call-lock-key)"
  # Positional extraction, and never an echo.
  public="$(printf '%s\n' "$generated" | sed -n '2p')"
  private="$(printf '%s\n' "$generated" | sed -n '5p')"

  [[ -n "$public" && -n "$private" ]] || { print -u2 "✗ could not read the generated key pair"; exit 1 }

  security add-generic-password -a "$USER" -s "$SERVICE" -w "$private" \
    -D "Airlock call lock key" \
    -j "Opens the locked part of Free calls, for a paid plan. Losing it leaves locked calls unopenable."
  echo "  stored in your login keychain as \"$SERVICE\""
fi

mkdir -p "$(dirname "$PUBLIC_KEY_FILE")"
printf '%s\n' "$public" > "$PUBLIC_KEY_FILE"
echo "  public half written to $PUBLIC_KEY_FILE (commit it — it is public)"

printf '%s' "$private" | pbcopy
echo ""
echo "The PRIVATE half is now on your clipboard, and has not been displayed."
echo "Paste it into your password manager, then into the licence server:"
echo ""
echo "  cd worker && wrangler secret put CALL_LOCK_PRIVATE_KEY"
echo ""
echo "Deploy the Worker before packaging an app with the public half."
