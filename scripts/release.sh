#!/bin/zsh
# Build a notarized, stapled Airlock.dmg that opens on someone else's Mac.
#
#   zsh scripts/release.sh
#
# ONE-TIME SETUP (both steps need your Apple ID, so neither is automated here):
#
#   1. A "Developer ID Application" certificate. This is NOT the same as the
#      "Apple Development" certificate Xcode creates for you — that one signs
#      builds for your own machines and cannot be notarized. Developer ID
#      requires paid Apple Developer Program membership.
#      Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application
#
#   2. A notarytool credential profile, so this script never sees a password:
#      xcrun notarytool store-credentials airlock \
#        --apple-id you@example.com --team-id <TEAMID> --password <app-specific-password>
#      The app-specific password comes from appleid.apple.com › Sign-In and
#      Security › App-Specific Passwords. Your real Apple ID password never
#      works here and should never be typed into a terminal.
#
# WHY THE DANCE BELOW. Notarizing only the DMG is the common shortcut and it is
# subtly wrong: the .app *inside* the image never receives a ticket, so anyone
# who drags it out and runs it offline gets a Gatekeeper prompt. The app has to
# be notarized and stapled FIRST, and only then wrapped — which is why the DMG
# is built after, from the stapled bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

# THE THREE VARIABLES A RELEASE NEEDS, recorded here because they have lived
# only in one line of somebody's shell history since launch:
#
#   export AIRLOCK_LICENSE_API_URL=https://useairlock.app/api \
#          AIRLOCK_APPCAST_URL=https://useairlock.app/appcast.xml \
#          AIRLOCK_DOWNLOAD_PREFIX=https://useairlock.app/downloads/
#
# Run this from YOUR OWN Terminal, not through a coding agent's shell.
# Notarization failed three times that way with `completedParts: []` — it
# authenticates, opens the multipart upload, and transfers nothing — and worked
# first time from Terminal.app.
VERSION="${AIRLOCK_VERSION:-1.0.18}"
PROFILE="${AIRLOCK_NOTARY_PROFILE:-airlock}"
OUT=output/package
APP="$OUT/Airlock.app"
DMG="$OUT/Airlock-${VERSION}.dmg"

fail() { print -u2 "\n✗ $1"; exit 1 }

# ── Preconditions, checked loudly. A release that gets halfway and then asks for
#    a certificate has already thrown away four minutes of notarization.
IDENTITY="${AIRLOCK_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # `|| true` is load-bearing. With `set -e -o pipefail`, a grep that matches
  # nothing fails the whole pipeline and kills the script HERE — before the
  # check below can explain what is missing. The symptom is a release that
  # exits 1 in silence, which is the least helpful failure available.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.*)"/\1/' || true)"
fi
# **This is the line a company switch would touch, and the only one.**
#
# Airlock ships under a personal Apple Developer ID (decided 2026-08-24). Moving
# to a company means a new membership, a new Team ID and a new certificate —
# which this script would pick up automatically, because it DISCOVERS the
# identity rather than naming one. The code cost is zero. The cost is elsewhere,
# and it grows the moment anything ships:
#
#   1. TCC grants are keyed to the code signature, so a new Team resets every
#      accessibility / microphone / calendar / automation permission the user
#      granted. After launch that is every customer re-onboarding.
#   2. Sparkle validates the signing identity on updates; a Team change can make
#      an update refuse to install and strand people on an old build.
#   3. Licence keys belong to a Lemon Squeezy store, and `LS_STORE_ID` refuses
#      keys from any other. A new account means every existing key is rejected.
#
# So the switch is cheap only while nothing has shipped. Read this before
# assuming it is a certificate swap.
[[ -n "$IDENTITY" ]] || fail "No \"Developer ID Application\" certificate found.
  An \"Apple Development\" certificate is NOT enough — it cannot be notarized.
  Create one in Xcode › Settings › Accounts › Manage Certificates › + ›
  Developer ID Application (needs paid Apple Developer Program membership),
  then re-run. Override with \$AIRLOCK_SIGN_IDENTITY if you have several."

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "No notarytool credentials stored under profile \"$PROFILE\".
  Create them once (this script never sees the password):
    xcrun notarytool store-credentials $PROFILE \\
      --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
  App-specific passwords: appleid.apple.com › Sign-In and Security."

# The licence server is a precondition too, and it was the one that only warned.
#
# `package-app.sh` prints "no licence server (only hand-issued keys will work)"
# and carries on — correct for a dev build, catastrophic for a release. A fresh
# shell on launch day produces a fully notarized DMG in which every paying
# customer's key is refused, and the app blames the key: "a single wrong
# character is enough to fail." The DMG is signed, stapled and public by then.
if [[ -z "${AIRLOCK_LICENSE_API_URL:-}" && -z "${AIRLOCK_ALLOW_NO_LICENSE_SERVER:-}" ]]; then
  fail "\$AIRLOCK_LICENSE_API_URL is not set.
  A release built without it can only accept hand-issued keys — every real
  purchase would be refused, and the app would blame the customer's key.
  Set it to the deployed Worker route, e.g.
    export AIRLOCK_LICENSE_API_URL=https://useairlock.app/api
  If you genuinely mean to ship a build with no licence server, say so:
    AIRLOCK_ALLOW_NO_LICENSE_SERVER=1 zsh scripts/release.sh"
fi

# The same shape of check as the licence server above, and the failure it
# prevents is worse because it is ONE-WAY.
#
# `package-app.sh` omits the updater when this is unset, and says so — but
# `generate_appcast` below does NOT depend on it, so a release built without it
# publishes an appcast advertising a build that cannot check for updates.
# Everyone on the previous version is offered it, installs it, and is stranded
# there permanently: the app they just installed has no feed to ask. Nothing
# about the DMG looks wrong, and the damage only becomes visible one release
# later, when nobody upgrades.
if [[ -z "${AIRLOCK_APPCAST_URL:-}" && -z "${AIRLOCK_ALLOW_NO_UPDATER:-}" ]]; then
  fail "\$AIRLOCK_APPCAST_URL is not set.
  The app would ship with no updater while the appcast still advertises it —
  so everyone on the current version updates to a build that can never update
  again. Set it to the published feed:
    export AIRLOCK_APPCAST_URL=https://useairlock.app/appcast.xml
  If you genuinely mean to ship a build nobody can update from, say so:
    AIRLOCK_ALLOW_NO_UPDATER=1 zsh scripts/release.sh"
fi

echo "▸ identity: $IDENTITY"
echo "▸ notary profile: $PROFILE"
echo "▸ licence server: ${AIRLOCK_LICENSE_API_URL:-none (explicitly allowed)}"
echo "▸ appcast feed: ${AIRLOCK_APPCAST_URL:-none (explicitly allowed)}"

# Refuse a version that is already published BEFORE notarizing, not after. The
# precise byte-comparison guard at the staging step still runs, but it runs
# after two round trips to Apple — and "you meant to bump the version" is the
# wrong thing to learn at that point. Same escape hatch, same purge advice.
if [[ -z "${AIRLOCK_FORCE_REPLACE:-}" \
      && -f "${AIRLOCK_SITE_DIR:-../website}/downloads/Airlock-$VERSION.dmg" ]]; then
  fail "Airlock-$VERSION.dmg is already published. Bump AIRLOCK_VERSION (default is
  now $VERSION in this script), or set AIRLOCK_FORCE_REPLACE=1 to overwrite it
  and then purge both download URLs from Cloudflare's cache."
fi

# ── 1. Build and sign the app, stopping before the DMG.
#
#    `AIRLOCK_VERSION` is passed EXPLICITLY. Both scripts carry their own
#    default, and nothing made them agree: bumping one and not the other builds
#    `Airlock-1.0.4.dmg` around a bundle that still calls itself 1.0.3, so
#    Sparkle offers an update that installs and then reports the old version —
#    and offers it again, forever.
AIRLOCK_VERSION="$VERSION" AIRLOCK_SIGN_IDENTITY="$IDENTITY" \
  AIRLOCK_SKIP_DMG=1 zsh scripts/package-app.sh

# ── 2. Notarize the app itself. Submitted as a zip because notarytool takes
#    archives, not bundles — ditto rather than `zip`, which loses symlinks and
#    extended attributes that the signature covers.
echo "▸ submitting the app for notarization (this takes a few minutes)"
ZIP="$OUT/Airlock-app.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"

# ── 3. Staple the ticket INTO the bundle, so it verifies with no network.
echo "▸ stapling the app"
xcrun stapler staple "$APP"

# ── 4. Only now wrap it. The DMG built by package-app.sh (had we let it) would
#    have contained the unstapled bundle.
echo "▸ building DMG around the stapled app"
zsh scripts/make-dmg.sh "$APP" "$VERSION"

# ── 5. And notarize the DMG too, so the download itself is trusted before the
#    user has opened anything.
# Sign the DMG BEFORE notarising it. The omission is invisible: stapling an
# unsigned image succeeds, `stapler validate` reports success, and the app
# inside is a perfectly good Notarized Developer ID — while Gatekeeper's own
# question about the container answers
#     rejected   source=no usable signature
# which is what a customer meets on double-clicking the download. 1.0.0 shipped
# exactly like that, and every check in this script stayed green, because the
# verify step below asked `spctl` about the APP and only `stapler` about the DMG.
echo "▸ signing the DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "▸ submitting the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# ── 6. Verify what actually shipped rather than trusting that it worked.
#    `spctl` is the question Gatekeeper itself asks.
echo ""
echo "▸ verifying"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
xcrun stapler validate "$APP"  | sed 's/^/  app: /'
xcrun stapler validate "$DMG"  | sed 's/^/  dmg: /'
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/  gatekeeper app: /'
# The assessment macOS makes when somebody opens a downloaded disk image, as
# opposed to launching an app. Asking only the latter is how 1.0.0 shipped.
spctl --assess -t open --context context:primary-signature --verbose=2 "$DMG" 2>&1 \
  | sed 's/^/  gatekeeper dmg: /'

# ── 7. The appcast: the XML Sparkle fetches to learn a new version exists, with
#    the EdDSA signature of this DMG in it. Generated from the output directory,
#    so the file and the signature can never disagree.
#
#    Skipped when Sparkle is not configured yet — a release without an updater is
#    a perfectly good release, and it is what every build before today was.
APPCAST_TOOL=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ -f Configuration/sparkle-public-key.txt && -x "$APPCAST_TOOL" ]]; then
  echo "▸ generating appcast"
  # What's new, for Sparkle's update window: the SAME notes the app shows in
  # its own card after updating (WhatsNew in AirlockCore), read back out of
  # the build being shipped, so the two can never say different things.
  # generate_appcast embeds a fragment it finds beside the DMG under the same
  # name. A version without notes prints nothing and gets no file, and the
  # update window then shows only the version, as every release before did.
  NOTES_HTML="$OUT/Airlock-${VERSION}.html"
  rm -f "$NOTES_HTML"
  NOTES="$("$APP/Contents/MacOS/Airlock" --whats-new-html "$VERSION")"
  if [[ -n "$NOTES" ]]; then
    print -r -- "$NOTES" > "$NOTES_HTML"
    echo "  ✓ release notes for $VERSION"
  else
    echo "  (no release notes for $VERSION — add them to WhatsNew.catalog)"
  fi
  # An ARRAY, because this script runs under zsh and zsh does not word-split an
  # unquoted parameter expansion the way bash does. Written as
  # `${VAR:+--download-url-prefix "$VAR"}` it arrived as ONE argument with a
  # space in it, and generate_appcast reported:
  #   Unknown option '--download-url-prefix https://useairlock.app/downloads/'
  # It failed AFTER notarization — two accepted submissions and a stapled DMG —
  # which is the most expensive place in this script to fall over.
  local -a prefix_args=()
  [[ -n "${AIRLOCK_DOWNLOAD_PREFIX:-}" ]] \
    && prefix_args=(--download-url-prefix "$AIRLOCK_DOWNLOAD_PREFIX")
  # Reads the private key from the keychain; it is never on disk or in argv.
  "$APPCAST_TOOL" "$OUT" "${prefix_args[@]}"
  echo "  ✓ $OUT/appcast.xml"
  echo "    Upload the DMG and appcast.xml together. Sparkle checks the"
  echo "    signature in the appcast against the key in the app, so the host"
  echo "    being compromised is survivable — a wrong key is not."
else
  echo "▸ appcast skipped (Sparkle not configured — see scripts/setup-sparkle-keys.sh)"
fi

# ── 8. Stage everything the website has to serve, in one directory, so that
#    deploying is a single command and the DMG can never be published without
#    the appcast that describes it (or the other way round — which is worse:
#    Sparkle would offer an update that 404s).
# The site moved out of this repo and this script did not follow it.
#
# `site/` here was `app/site/` — the OLD marketing page, deleted in October
# because it still showed the August prices. The page actually served is
# `../website/`, a sibling of the repo. Staging into the wrong one is silent: the release
# succeeds, the deploy succeeds, and the Download button 404s because the DMG
# and the appcast went somewhere nobody publishes. Sparkle's feed goes missing
# in the same stroke, which is worse — an update that 404s.
SITE_DIR="${AIRLOCK_SITE_DIR:-../website}"
[[ -d "$SITE_DIR" ]] || fail "Site directory \"$SITE_DIR\" does not exist.
  This script stages the DMG, the appcast and the download redirect into the
  directory that gets deployed. Point \$AIRLOCK_SITE_DIR at it."
SITE_DOWNLOADS="$SITE_DIR/downloads"
mkdir -p "$SITE_DOWNLOADS"

# The site serves /downloads/* as `immutable, max-age=31536000`, on the premise
# that a versioned filename never changes under its URL. Re-running this script
# for a version that is already published breaks that premise: the deploy
# uploads the new bytes, the appcast advertises them, and every edge node keeps
# handing out the old DMG for up to a year. 1.0.0 shipped twice that way — the
# second build carried a signed container and a rotated licence key, and the
# custom domain served the first build with `cf-cache-status: HIT` regardless.
#
# So: same version, different bytes, is refused unless explicitly forced, and
# forcing it prints the purge that the deploy cannot do for you.
STAGED="$SITE_DOWNLOADS/$(basename "$DMG")"
if [[ -f "$STAGED" ]] && ! cmp -s "$DMG" "$STAGED"; then
  if [[ -z "${AIRLOCK_FORCE_REPLACE:-}" ]]; then
    fail "$(basename "$DMG") is already published with DIFFERENT bytes.
  A versioned URL is cached immutably for a year at the edge, so overwriting
  it does not replace what people download. Either bump AIRLOCK_VERSION so
  the filename changes, or — if nobody can have the old build yet — re-run
  with AIRLOCK_FORCE_REPLACE=1 and then purge both URLs from Cloudflare's
  cache (dashboard → Caching → Configuration → Purge Cache → Custom Purge):
    https://useairlock.app/downloads/$(basename "$DMG")
    https://useairlock.app/downloads/Airlock.dmg"
  fi
  echo "  ⚠ replacing an already-published $(basename "$DMG") — PURGE THE EDGE CACHE after deploying:"
  echo "      https://useairlock.app/downloads/$(basename "$DMG")"
  echo "      https://useairlock.app/downloads/Airlock.dmg"
fi
cp "$DMG" "$SITE_DOWNLOADS/"
[[ -f "$OUT/appcast.xml" ]] && cp "$OUT/appcast.xml" "$SITE_DIR/appcast.xml"

# The marketing page links to a stable /downloads/Airlock.dmg so it never needs
# editing per release; this points it at the version just built. A redirect
# rather than a second copy of the file — 15 MB duplicated per release adds up,
# and two files that are meant to be identical eventually are not.
cat > "$SITE_DIR/_redirects" <<REDIRECTS
# Generated by scripts/release.sh — do not edit, it is rewritten every release.
/downloads/Airlock.dmg  /downloads/$(basename "$DMG")  302
/download               /downloads/$(basename "$DMG")  302
REDIRECTS

echo ""
echo "✓ $DMG  ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "  Notarized and stapled. Opens on any Mac with no right-click → Open,"
echo "  and verifies offline."
echo ""
# deploy.sh rather than a bare `wrangler pages deploy`: that one publishes the
# whole folder, README.md and dotfiles included.
echo "  staged for the website in $SITE_DIR — deploy with:"
echo "    $SITE_DIR/deploy.sh"
