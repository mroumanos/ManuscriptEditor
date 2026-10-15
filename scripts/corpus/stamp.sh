#!/bin/bash
# stamp.sh — writes checksum.txt (and export.json where missing) into every
# bundled profile folder, as the app computes them.  Needs a Debug build.
#
#   scripts/corpus/stamp.sh
set -euo pipefail
cd "$(dirname "$0")"
DD="$(xcodebuild -project ../../ManuscriptEditor/ManuscriptEditor.xcodeproj -scheme ManuscriptEditor \
      -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP="$DD/ManuscriptEditor.app/Contents/MacOS"
WORK="$(mktemp -d /tmp/me-stamp-XXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -target arm64-apple-macos26.5 -I "$DD" "$APP/ManuscriptEditor.debug.dylib" \
  -Xlinker -rpath -Xlinker "$APP" -o "$WORK/stamp" stamp.swift
MANUSCRIPT_EDITOR_NO_SIGNING=1 "$WORK/stamp" "$(cd ../../ManuscriptEditor/JournalProfiles && pwd)"
