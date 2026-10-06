#!/bin/zsh
# Wrap an .app in a DMG with an /Applications shortcut.
#
#   zsh scripts/make-dmg.sh <path-to-.app> <version>
#
# Its own script because the DMG has to be built TWICE in a release: once is
# useless, since the app inside must already carry its notarization ticket. See
# scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"
VERSION="$2"
OUT="$(dirname "$APP")"
STAGE="$OUT/dmg-stage"

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Airlock" -srcfolder "$STAGE" -ov -format UDZO \
  "$OUT/Airlock-${VERSION}.dmg" > /dev/null
rm -rf "$STAGE"
