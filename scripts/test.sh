#!/bin/bash
# Runs the unit tests. Command Line Tools ship Swift Testing but SwiftPM needs the framework path spelled out.
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$F" ]; then
  exec swift test -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
else
  exec swift test "$@"
fi
