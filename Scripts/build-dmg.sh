#!/bin/bash
# Builds FanBar.app (unless present) and packages it into a drag-to-Applications DMG.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$PKG/.." && pwd)"
APP="$ROOT/build/FanBar.app"
DIST="$PKG/dist"
DMG="$DIST/FanBar.dmg"

if [ "${FANBAR_REBUILD:-1}" = "1" ]; then
    bash "$SCRIPT_DIR/build-app.sh"
fi
[ -d "$APP" ] || { echo "Missing $APP"; exit 1; }

STAGE="$(mktemp -d -t fanbar-dmg)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/FanBar.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "FanBar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo "Built: $DMG"
