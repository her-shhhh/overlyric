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
./scripts/render-readme.sh "$APP/Contents/Resources/Read This or Hum Forever.txt"   # menu › Read This or Hum Forever
./scripts/build-adapter.sh "$APP/Contents/Resources" "$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)"   # Now Playing
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature (no certificates, no keychain) with an explicit designated requirement that names
# only the bundle identifier. macOS keys permissions (Automation, Screen Recording) on the designated
# requirement; the default ad-hoc one is the build's hash, which changes every build and silently
# invalidates the user's grants. This one stays the same across builds, so a permission is granted once.
# For a release signed with a paid Apple Developer ID: OVERLYRIC_SIGN_ID="Developer ID Application: …"
SIGN_ID="${OVERLYRIC_SIGN_ID:--}"
echo "▸ codesign ($SIGN_ID)"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - --identifier com.harsh.overlyric \
    -r='designated => identifier "com.harsh.overlyric"' \
    --entitlements Resources/Overlyric.entitlements "$APP"
else
  codesign --force --sign "$SIGN_ID" --identifier com.harsh.overlyric --options runtime \
    --entitlements Resources/Overlyric.entitlements "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "✓ built $APP"
