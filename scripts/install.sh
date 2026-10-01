#!/bin/bash
# Builds, installs to /Applications (or ~/Applications), relaunches.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
echo "▸ installing to $DEST/Overlyric.app"
pkill -x Overlyric 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/Overlyric.app"
cp -R build/Overlyric.app "$DEST/Overlyric.app"
open "$DEST/Overlyric.app"
echo "✓ Overlyric is running — look for the mic icon in the menu bar"
