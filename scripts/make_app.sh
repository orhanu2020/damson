#!/bin/bash
# Builds Damson and wraps it in a proper .app bundle (needed for microphone and speech permissions).
# Usage: scripts/make_app.sh [debug|release]
# Optional: DAMSON_SIGN_ID="Apple Development: Your Name (TEAMID)" for a stable signature, so macOS
# remembers the microphone permission between builds. Default is an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Damson.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Damson" "$APP/Contents/MacOS/Damson"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
codesign --force --deep --sign "${DAMSON_SIGN_ID:--}" "$APP"

echo "Built $APP"
echo "Run it with:  open $APP"
