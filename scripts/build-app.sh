#!/bin/bash
# Builds Overlyric.app into ./build (release), ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "▸ swift build (release)"
swift build -c release 2>&1 | grep -E "error|warning|Build complete" | tail -8
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "✗ build failed"; exit 1; }
BIN=.build/release/Overlyric
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

APP=build/Overlyric.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Overlyric"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc by default. Set OVERLYRIC_SIGN_ID to a self-signed code-signing identity for a signature that
# stays stable across rebuilds (ad-hoc = cdhash-based, so every rebuild re-asks the Automation permission).
SIGN_ID="${OVERLYRIC_SIGN_ID:--}"
echo "▸ codesign ($SIGN_ID)"
codesign --force --sign "$SIGN_ID" --identifier com.harsh.overlyric \
  --entitlements Resources/Overlyric.entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ built $APP"
