#!/bin/bash
# Builds the vendored MediaRemote Adapter (Vendor/MediaRemoteAdapter) into <Resources>/MediaRemoteAdapter:
# its perl script and MediaRemoteAdapter.framework (universal, signed). NowPlayingMonitor reads Now Playing
# through it.   ./scripts/build-adapter.sh <app Resources dir> [min macOS]
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$1/MediaRemoteAdapter"
MIN_OS="${2:-14.0}"
SRC=Vendor/MediaRemoteAdapter
FW="$DEST/MediaRemoteAdapter.framework"
rm -rf "$DEST"
mkdir -p "$FW"
# The script loads <framework>/<name>, so a flat framework with just the library is all it needs.
clang -dynamiclib -fobjc-arc -fvisibility=default -O2 -arch arm64 -arch x86_64 -mmacosx-version-min="$MIN_OS" \
  -I"$SRC/include" -I"$SRC/src" "$SRC"/src/adapter/*.m "$SRC"/src/private/*.m "$SRC"/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter -o "$FW/MediaRemoteAdapter"
cp "$SRC/bin/mediaremote-adapter.pl" "$SRC/LICENSE" "$DEST/"   # BSD 3-Clause: its notice ships with it
SIGN_ID="${OVERLYRIC_SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - "$FW/MediaRemoteAdapter"
else
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$FW/MediaRemoteAdapter"
fi
echo "✓ MediaRemote Adapter → $DEST"
