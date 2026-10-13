#!/bin/bash
# remote_status.sh — Overview offers Create only for a repository absent from
# the account's own namespace; nothing else ever gets Create.  Needs a Debug build; runs with signing off (no Keychain).
#
#   scripts/harness/remote_status.sh
set -euo pipefail
cd "$(dirname "$0")"
DD="$(xcodebuild -project ../../ManuscriptEditor/ManuscriptEditor.xcodeproj -scheme ManuscriptEditor \
      -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP="$DD/ManuscriptEditor.app/Contents/MacOS"
WORK="$(mktemp -d /tmp/me-remote-files-XXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -target arm64-apple-macos26.5 -I "$DD" "$APP/ManuscriptEditor.debug.dylib" \
  -Xlinker -rpath -Xlinker "$APP" -o "$WORK/remote_status" remote_status.swift
MANUSCRIPT_EDITOR_NO_SIGNING=1 "$WORK/remote_status"
