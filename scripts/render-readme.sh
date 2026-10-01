#!/bin/bash
# Renders the friends' guide (Resources/friends-readme.txt) to the given path, filling in {{VERSION}} and
# {{MIN_OS}} from Resources/Info.plist. The same file ships twice: inside the app (opened from the menu)
# and next to the app in the DMG. Its name, "Read This or Hum Forever.txt", is also used by
# GuideWindow (menu › Read This or Hum Forever).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"
PLIST=Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")
sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{MIN_OS}}/${MIN_OS%%.*}/g" Resources/friends-readme.txt > "$OUT"
if LC_ALL=C grep -n '[^ -~]' "$OUT"; then
  echo "the guide must be plain ASCII (lines above)" >&2
  exit 1
fi
