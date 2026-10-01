#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Overlyric.app and packs it into dist/Overlyric-<version>.dmg,
# the one file to send to friends. Command Line Tools are enough; no Xcode needed.
#
#   ./scripts/release.sh                                    # ad-hoc signed (no Apple account needed)
#   OVERLYRIC_SIGN_ID="Developer ID Application: Name (TEAMID)" ./scripts/release.sh
#   OVERLYRIC_SIGN_ID="Developer ID Application: ..." NOTARY_PROFILE=overlyric ./scripts/release.sh
#       NOTARY_PROFILE is a keychain profile created once with
#       `xcrun notarytool store-credentials overlyric --apple-id ... --team-id ... --password <app-specific>`.
#       The notarization block is UNTESTED (needs a paid Developer ID).
#
# The version comes from CFBundleShortVersionString in Resources/Info.plist; bump it there first.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=Overlyric
BUNDLE_ID=com.harsh.overlyric
PLIST=Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")
SIGN_ID="${OVERLYRIC_SIGN_ID:--}"
ARCHS=(arm64 x86_64)

OUT=build/release
APP="$OUT/$NAME.app"
STAGE="$OUT/dmg"
DIST=dist
DMG="$DIST/$NAME-$VERSION.dmg"
LOG=$(mktemp -t overlyric-release)
trap 'rm -f "$LOG"' EXIT
die() { echo "✗ $*" >&2; exit 1; }

echo "▸ Overlyric $VERSION (macOS $MIN_OS+), signing identity: $SIGN_ID"

# 1. One build per architecture. `swift build --arch arm64 --arch x86_64` needs Xcode's XCBuild, which the
#    Command Line Tools don't ship, so build each triple into its own scratch dir and lipo them together.
SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "▸ swift build release ($arch)"
  args=(-c release --product "$NAME" --triple "$arch-apple-macosx$MIN_OS" --scratch-path ".build/release-$arch")
  if ! swift build "${args[@]}" >"$LOG" 2>&1; then
    tail -30 "$LOG"
    die "build failed ($arch)"
  fi
  grep -E "warning:" "$LOG" | sort -u | tail -5 || true
  bin="$(swift build "${args[@]}" --show-bin-path)/$NAME"
  [ -x "$bin" ] || die "missing $bin"
  SLICES+=("$bin")
done

mkdir -p "$OUT"
UNIVERSAL="$OUT/$NAME"
lipo -create "${SLICES[@]}" -output "$UNIVERSAL"
lipo "$UNIVERSAL" -verify_arch "${ARCHS[@]}" || die "universal binary is missing an architecture"
echo "✓ $(lipo -info "$UNIVERSAL")"

# The linker records the Command Line Tools' Swift back-deploy folder as an rpath. Nothing loads from it
# (no @rpath dependencies), it just doesn't exist on friends' Macs, so drop it — but only if that stays true.
deps=$(otool -L "$UNIVERSAL")
if ! grep -q "@rpath/" <<<"$deps"; then
  for rp in $(otool -l "$UNIVERSAL" | awk '/cmd LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | sort -u); do
    case "$rp" in /Library/Developer/*|/Applications/Xcode*)
      install_name_tool -delete_rpath "$rp" "$UNIVERSAL" 2>/dev/null || echo "  (kept rpath $rp)" ;;
    esac
  done
fi

# 2. Assemble the bundle exactly like scripts/build-app.sh.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$UNIVERSAL" "$APP/Contents/MacOS/$NAME"
cp "$PLIST" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
README_NAME="Read This or Hum Forever.txt"
./scripts/render-readme.sh "$APP/Contents/Resources/$README_NAME"   # opened from the app's menu
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod -R u+rwX,go+rX "$APP"   # Gatekeeper must be able to read the signature as any user

# 3. Sign. Ad-hoc ("-") needs no certificate; a Developer ID also gets the hardened runtime + secure
#    timestamp that notarization requires (the entitlements already allow Apple Events to Spotify).
SIGN_ARGS=(--force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" --entitlements Resources/Overlyric.entitlements)
if [ "$SIGN_ID" = "-" ]; then
  # Ad-hoc: name only the bundle id in the designated requirement. macOS keys permissions on it; the
  # default ad-hoc requirement is the build's hash, so every update would silently lose the grants.
  SIGN_ARGS+=(-r="designated => identifier \"$BUNDLE_ID\"")
else
  SIGN_ARGS+=(--options runtime --timestamp)
fi
echo "▸ codesign ($SIGN_ID)"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP" || die "signature does not verify"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Format|Signature|TeamIdentifier)=" | sed 's/^/  /'

# 4. Disk image: the app, an Applications shortcut to drag it onto, and a short read-me.
#    The read-me stays plain ASCII so every editor (and Quick Look) shows it cleanly.
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/$README_NAME" "$STAGE/$README_NAME"   # the same guide, next to the app

rm -f "$DMG"
echo "▸ hdiutil create $DMG"
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify -quiet "$DMG" || die "dmg failed verification"

# 5. Optional notarization (Developer ID + NOTARY_PROFILE only). UNTESTED.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ "$SIGN_ID" != "-" ] || die "NOTARY_PROFILE needs OVERLYRIC_SIGN_ID set to a Developer ID Application identity"
  echo "▸ notarizing (profile $NOTARY_PROFILE)"
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$LOG"
  status=$(plutil -extract status raw -o - "$LOG" 2>/dev/null || echo unknown)
  [ "$status" = "Accepted" ] || { cat "$LOG"; die "notarization status: $status (see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"; }
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

rm -rf "$STAGE" "$UNIVERSAL"
echo "✓ $DMG  ($(du -h "$DMG" | cut -f1 | tr -d ' '), sha256 $(shasum -a 256 "$DMG" | cut -c1-16)...)"
