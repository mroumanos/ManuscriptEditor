#!/bin/bash
# corpus_profiles.sh — every bundled journal profile decodes whole, under the
# GUID its slug derives.  Needs a Debug build (the profiles are copied into
# the app bundle); runs with signing off (no Keychain).
#
#   scripts/harness/corpus_profiles.sh
set -euo pipefail
cd "$(dirname "$0")"
DD="$(xcodebuild -project ../../ManuscriptEditor/ManuscriptEditor.xcodeproj -scheme ManuscriptEditor \
      -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP="$DD/ManuscriptEditor.app/Contents/MacOS"
WORK="$(mktemp -d /tmp/me-corpus-XXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -target arm64-apple-macos26.5 -I "$DD" "$APP/ManuscriptEditor.debug.dylib" \
  -Xlinker -rpath -Xlinker "$APP" -o "$WORK/corpus_profiles" corpus_profiles.swift
MANUSCRIPT_EDITOR_NO_SIGNING=1 "$WORK/corpus_profiles"
