#!/bin/bash
# remote_files.sh — what a save to the remote sends must be what a load from
# it takes.  Needs a Debug build; runs with signing off (no Keychain).
#
#   scripts/harness/remote_files.sh
set -euo pipefail
cd "$(dirname "$0")"
DD="$(xcodebuild -project ../../ManuscriptEditor/ManuscriptEditor.xcodeproj -scheme ManuscriptEditor \
      -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP="$DD/ManuscriptEditor.app/Contents/MacOS"
WORK="$(mktemp -d /tmp/me-remote-files-XXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -target arm64-apple-macos26.5 -I "$DD" "$APP/ManuscriptEditor.debug.dylib" \
  -Xlinker -rpath -Xlinker "$APP" -o "$WORK/remote_files" remote_files.swift
MANUSCRIPT_EDITOR_NO_SIGNING=1 "$WORK/remote_files"
