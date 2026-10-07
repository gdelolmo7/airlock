#!/bin/zsh
# Build Airlock.app + DMG from the SwiftPM package.
#
#   zsh scripts/package-app.sh
#
# The product is **Airlock**; the bundle identifier is still com.airlock.app
# and the CLIs are still airlock-hook/-setup. That is deliberate, not
# leftover. A bundle ID is an identity, not a name: changing it resets every TCC
# grant the app has earned — Accessibility, Microphone, Automation, Calendar —
# so dictation, typing, terminal jump-back, media control and the audio tap all
# stop until each is approved again. The CLI names are worse still: they are
# written into ~/.claude/settings.json and ~/.codex/config.toml as absolute
# paths, so renaming them silently breaks every installed hook until setup runs
# again. Both renames want a migration, and neither buys the user anything.
#
# Signing identity, in order of preference:
#   1. $AIRLOCK_SIGN_IDENTITY (e.g. "Developer ID Application: …")
#   2. the "agentic-notch-dev" self-signed cert (create: scripts/setup-dev-signing.sh)
#   3. ad-hoc ("-") — works, but macOS Automation/Accessibility grants are
#      invalidated on every rebuild; fine for a quick look, wrong for daily use.
#
# Optional notarization (Developer ID only):
#   AIRLOCK_NOTARY_PROFILE=<notarytool keychain profile> zsh scripts/package-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${AIRLOCK_VERSION:-1.0.18}"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="${AIRLOCK_BUNDLE_ID:-com.airlock.app}"

IDENTITY="${AIRLOCK_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "agentic-notch-dev"; then
  IDENTITY="agentic-notch-dev"
fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"

BIN=.build/release
OUT=output/package
APP="$OUT/Airlock.app"

# ── Refuse to destroy a DIFFERENT app that is sitting here.
#
#    $OUT is wiped on every run, and it is also where a packaged Airlock lives
#    and is launched from — so a build with different settings silently deletes
#    the app you are actually using. That happened: packaging a test build under
#    another bundle id removed a RUNNING, notarized, Developer ID 1.0.3, and the
#    way back was to download it again, because rebuilding it here with the dev
#    cert would have re-pinned its TCC grants to a certificate the shipped app
#    does not carry (see CLAUDE.md, "the dev cert has a second edge").
#
#    Rebuilding the SAME app over itself is the everyday loop and stays silent.
#    Only a clobber is refused, and only in the direction that loses something:
#    a different bundle id, or trading a Developer ID build for one that cannot
#    be notarized. Dev → Developer ID is an upgrade and passes, which is what
#    release.sh does every time.
#
#    Checked BEFORE `swift build`, so it fails in a second rather than after a
#    release build has already run.
if [[ -d "$APP" ]]; then
  PREV_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
  PREV_AUTH="$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

  CLOBBER=()
  [[ -n "$PREV_ID" && "$PREV_ID" != "$BUNDLE_ID" ]] && \
    CLOBBER+=("bundle id:  $PREV_ID → $BUNDLE_ID")
  [[ "$PREV_AUTH" == "Developer ID Application:"* && \
     "$IDENTITY" != "Developer ID Application:"* ]] && \
    CLOBBER+=("signed by:  $PREV_AUTH → $IDENTITY")

  # Named separately from the check: a running app makes the same clobber worse
  # (the binary is replaced under a live process), and the pid is what someone
  # needs to go and quit.
  #    `exe`, never `path`: in zsh `$path` is the array tied to $PATH, so
  #    `read -r pid path` silently replaces the shell's search path with
  #    whatever ps printed last — and the next line fails with
  #    "command not found: swift". Cost twenty minutes to find, once.
  RUNNING=()
  while read -r pid exe; do
    [[ "$exe" == "$PWD/$APP/"* ]] && RUNNING+=("$pid")
  done <<< "$(ps -Ao pid=,comm=)"

  if (( ${#CLOBBER} )) && [[ -z "${AIRLOCK_FORCE_REPLACE:-}" ]]; then
    echo "✗ $APP holds a different app, and this run would delete it."
    for line in "${CLOBBER[@]}"; do echo "    $line"; done
    (( ${#RUNNING} )) && echo "    running:    pid ${RUNNING[*]} — quit it first"
    echo ""
    echo "  Move it somewhere safe, or build elsewhere:"
    echo "    ditto \"$APP\" ~/Applications/Airlock.app"
    echo ""
    echo "  A Developer ID build cannot be recreated by this script — it needs"
    echo "  notarization (scripts/release.sh), and rebuilding it dev-signed"
    echo "  re-pins its TCC grants to a certificate the shipped app lacks."
    echo ""
    echo "  Overwrite anyway: AIRLOCK_FORCE_REPLACE=1 zsh scripts/package-app.sh"
    exit 1
  fi
  (( ${#RUNNING} )) && echo "▸ note: replacing a running build (pid ${RUNNING[*]})"
fi

echo "▸ swift build -c release"
swift build -c release > /dev/null

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Executables: the app plus both CLIs as siblings — HookBinaryStager and the
# settings window locate the hook next to the main executable.
cp "$BIN/AirlockApp"     "$APP/Contents/MacOS/Airlock"
cp "$BIN/airlock-hook"  "$APP/Contents/MacOS/airlock-hook"
cp "$BIN/airlock-setup" "$APP/Contents/MacOS/airlock-setup"

# ── Sparkle.framework. UNCONDITIONAL, whatever the keys below say.
#
#    The executable links it whether or not an updater is configured, so an
#    app bundle without it does not launch at all — dyld aborts before main()
#    with "Library not loaded: @rpath/Sparkle.framework". Skipping the copy
#    when the feed is unset was exactly that bug: `swift run` worked (the
#    framework sits beside the binary in .build), the packaged app did not.
#
#    `ditto` rather than `cp -R` so the Versions/Current symlinks survive —
#    a framework whose symlinks were dereferenced fails codesign --strict.
if [ -d "$BIN/Sparkle.framework" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  # SwiftPM builds the executable with @loader_path only, which resolves to
  # Contents/MacOS. Frameworks belong in Contents/Frameworks, so the bundle
  # needs the rpath that points there. Before signing — this edits the binary.
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/Airlock" 2>/dev/null
  echo "  sparkle: framework embedded"
else
  echo "✗ $BIN/Sparkle.framework missing — the app would not launch" >&2
  exit 1
fi

# The icon. Generated by scripts/make-icon.swift and committed, so packaging does
# not depend on re-rendering it. Without this the app shows a blank page icon in
# the Dock during onboarding, in Finder, and in the DMG.
if [ -f Resources/AppIcon.icns ]; then
	cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
	echo "  ! Resources/AppIcon.icns missing — run: swift scripts/make-icon.swift" >&2
fi

# The four sounds (card D1). Flat in Resources, so NSSound(named:) finds them
# by name. SOURCE.md, their origin and licence, stays in the repo.
for sound in Resources/Sounds/*.wav; do
	cp "$sound" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Airlock</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleExecutable</key>
	<string>Airlock</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Airlock</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUM}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<!-- airlock://activate?key=… — how a finished checkout hands the key back.
	     Without it the purchase ends in a copy-and-paste from an email, which
	     is exactly where the hand-off leaks. See ActivationURL. -->
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.airlock.app.activation</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>airlock</string>
			</array>
		</dict>
	</array>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>Airlock moves files from your shelf to your Downloads folder when you drag one onto the Downloads card.</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>Airlock jumps back to the exact terminal tab where your coding agent is running, and controls Spotify or Music for the media widget.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Airlock transcribes what you say into text. Audio is processed on your Mac and never leaves it.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Airlock reads the audio your music player is producing so the wave beside the notch follows the music. Only that player is tapped, nothing is recorded or stored, and this is off unless you turn it on.</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Airlock turns your speech into text on-device, so dictation works offline and nothing is sent anywhere.</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>Airlock shows your next meetings in the notch with one-click join links.</string>
	<key>NSHumanReadableCopyright</key>
	<string>No telemetry. Airlock looks at your screen only when you ask, and keeps no copy of what it saw.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ── Sparkle. Both keys are injected rather than hard-coded: the public key is
#    committed (it is public, and an app without it cannot verify its own
#    updates), and the feed URL varies by where releases are hosted.
#
#    Absent either, the app simply ships without an updater — which is exactly
#    what every build before today did. A half-configured updater that points at
#    nothing would be worse: it would check, fail, and say so, forever.
LICENSE_KEY_FILE="Configuration/license-public-key.txt"
LICENSE_KEY="$([[ -f "$LICENSE_KEY_FILE" ]] && tr -d '[:space:]' < "$LICENSE_KEY_FILE" || true)"
if [[ -n "$LICENSE_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :ALLicensePublicKey string $LICENSE_KEY" "$APP/Contents/Info.plist"
  echo "  licensing: public key embedded"
else
  # No key means nothing verifies, so every copy stays on trial forever. That is
  # the correct failure for a build packaged without one — far better than the
  # alternative of defaulting to licensed.
  echo "  licensing: no public key (every copy will stay on trial)"
fi

# The licence server (worker/): <base>/activate swaps a Lemon Squeezy key for a
# signed token, <base>/refresh renews one. Absent, neither happens — a
# hand-issued token still verifies and works offline forever, and nothing else
# does. Correct for a dev build, and the reason renewsAt/checkBy are baked into
# each token rather than fetched.
#
# https only, and checked here as well as in the app — a licence key posted over
# plain http is one an airport network can read and replay.
# The screen guide is a prototype and not public yet (the owner's call,
# 2026-10-06): only a build asked for with AIRLOCK_GUIDE=1 carries it.
if [[ "${AIRLOCK_GUIDE:-}" == 1 ]]; then
  /usr/libexec/PlistBuddy -c "Add :ALGuide bool true" "$APP/Contents/Info.plist"
  echo "  guide: built in (not for the public download)"
else
  echo "  guide: left out"
fi

if [[ -n "${AIRLOCK_LICENSE_API_URL:-}" ]]; then
  if [[ "$AIRLOCK_LICENSE_API_URL" != https://* ]]; then
    echo "✗ AIRLOCK_LICENSE_API_URL must be https" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Add :ALLicenseAPIURL string $AIRLOCK_LICENSE_API_URL" "$APP/Contents/Info.plist"
  echo "  licensing: activation and renewal via $AIRLOCK_LICENSE_API_URL"
else
  echo "  licensing: no licence server (only hand-issued keys will work)"
fi

SPARKLE_KEY_FILE="Configuration/sparkle-public-key.txt"
SPARKLE_KEY="$([[ -f "$SPARKLE_KEY_FILE" ]] && tr -d '[:space:]' < "$SPARKLE_KEY_FILE" || true)"
FEED_URL="${AIRLOCK_APPCAST_URL:-}"
if [[ -n "$SPARKLE_KEY" && -n "$FEED_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_KEY" "$APP/Contents/Info.plist"
  # SUEnableAutomaticChecks is deliberately ABSENT. Sparkle's documented
  # behaviour for the missing key is to ask, once, on the second launch,
  # whether it may check automatically — and to do nothing if the answer is
  # no. That keeps the consent story honest and still gets a fix to most
  # people. It used to be forced to `false`, which never asks and never
  # checks: every customer who did not find the toggle in Settings was
  # stranded on whatever version they installed, which is the exact outcome
  # the signing key exists to prevent.
  echo "  sparkle: feed $FEED_URL"
else
  echo "  sparkle: not configured (no updater in this build)"
fi

echo "▸ signing as: $IDENTITY"
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/Configuration/airlock.entitlements"
SIGN_FLAGS=(--force --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_FLAGS+=(--options runtime --timestamp)

# ── The hardened runtime turns on LIBRARY VALIDATION, which will only load a
#    framework whose Team ID matches the process's. The self-signed dev cert has
#    no Team ID at all, so Sparkle.framework is refused and the app dies in dyld
#    before main() — signed correctly, verifying correctly, and unable to start.
#
#    So dev builds get the documented exception, and Developer ID builds — the
#    ones that ship — never do. Deliberately the NARROWEST difference available:
#    dropping --options runtime instead would change how entitlements and TCC
#    behave, and a dev build that prompts differently from the release is how
#    you ship a permission bug you have personally never seen.
SIGN_ENTITLEMENTS="$ENTITLEMENTS"
if [[ "$IDENTITY" != "-" && "$IDENTITY" != "Developer ID Application:"* ]]; then
  SIGN_ENTITLEMENTS="$OUT/dev.entitlements"
  cp "$ENTITLEMENTS" "$SIGN_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c \
    "Add :com.apple.security.cs.disable-library-validation bool true" \
    "$SIGN_ENTITLEMENTS" > /dev/null
  echo "  dev cert: library validation disabled (release builds keep it)"
fi
# Inside-out: nested CLIs first (no entitlements — they send no Apple events
# and touch no calendar), then the app bundle WITH entitlements. Under the
# hardened runtime, TCC refuses to even present a prompt (0→0, no dialog)
# unless the requesting app carries the matching entitlement.
#
# Sparkle first, and inside-out within itself: the XPC services and the updater
# app are separate bundles with their own signatures, and a nested bundle signed
# AFTER its container invalidates the container. None of them get the app's
# entitlements — they send no Apple events and read no calendar. Notarization
# rejects the whole submission if any one of them is left with the
# Sparkle project's own signature instead of this Developer ID.
SPARKLE_APP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_APP/XPCServices/Downloader.xpc"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_APP/XPCServices/Installer.xpc"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_APP/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_APP/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"

codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/airlock-hook"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/airlock-setup"
codesign "${SIGN_FLAGS[@]}" --entitlements "$SIGN_ENTITLEMENTS" "$APP"
codesign --verify --strict "$APP"
echo "  codesign verify: OK"
echo "  entitlements: $(codesign -d --entitlements - "$APP" 2>/dev/null | grep -c apple-events) apple-events, $(codesign -d --entitlements - "$APP" 2>/dev/null | grep -c calendars) calendars, $(codesign -d --entitlements - "$APP" 2>/dev/null | grep -c audio-input) audio-input"

# Stop here when the caller is going to notarize the app before wrapping it.
# scripts/release.sh does exactly that: an app has to be stapled BEFORE the DMG
# is built, or the copy inside the image carries no ticket.
if [[ -n "${AIRLOCK_SKIP_DMG:-}" ]]; then
  echo ""
  echo "✓ app: $APP  (DMG skipped)"
  exit 0
fi

echo "▸ building DMG"
"$(dirname "$0")/make-dmg.sh" "$APP" "$VERSION"
DMG="$OUT/Airlock-${VERSION}.dmg"

echo ""
echo "✓ app: $APP"
echo "✓ dmg: $DMG  ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
if [[ "$IDENTITY" == "-" ]]; then
  echo ""
  echo "note: ad-hoc signed. For daily use, run scripts/setup-dev-signing.sh once so"
  echo "      Automation/Accessibility grants survive rebuilds. For distribution,"
  echo "      sign with Developer ID and notarize (unsigned downloads need"
  echo "      right-click → Open, or: xattr -d com.apple.quarantine)."
fi
