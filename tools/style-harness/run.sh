#!/bin/zsh
# Offscreen visual QA for every lyric style: renders frame strips with the real renderer code through
# CARenderer (no windows, no app launch, no permissions). Output: PNG strips per style × scenario.
#   ./tools/style-harness/run.sh [output-dir]      (default: /tmp/overlyric-style-frames)
set -euo pipefail
HERE=${0:A:h}
REPO=${HERE:h:h}
OUT=${1:-/tmp/overlyric-style-frames}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"
# The renderers + the two Core files they use, without the module import (compiled as one unit here).
for f in $REPO/Sources/Overlyric/Styles/*.swift $REPO/Sources/OverlyricCore/SyncedLyrics.swift $REPO/Sources/OverlyricCore/LRCParser.swift; do
  sed '/^import OverlyricCore/d' "$f" > "$WORK/src/${f:t}"
done
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" "$WORK"/src/*.swift "$HERE/common.swift" "$HERE/entry/main.swift" -o "$WORK/render-styles"
rm -rf "$OUT"
"$WORK/render-styles" "$OUT"
echo "frames: $OUT"
