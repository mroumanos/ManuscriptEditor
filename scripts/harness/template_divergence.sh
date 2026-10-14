#!/bin/bash
# template_divergence.sh — a journal's parts are editable in a manuscript,
# travel with it, and read as diverged from the template and from the shared
# repository's copy; a library keeps one template per name and type.
# Needs a Debug build; runs with signing off (no Keychain) and the library
# pointed at a scratch folder (nobody's templates are touched).
#
#   scripts/harness/template_divergence.sh
set -euo pipefail
cd "$(dirname "$0")"
DD="$(xcodebuild -project ../../ManuscriptEditor/ManuscriptEditor.xcodeproj -scheme ManuscriptEditor \
      -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP="$DD/ManuscriptEditor.app/Contents/MacOS"
WORK="$(mktemp -d /tmp/me-divergence-XXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -target arm64-apple-macos26.5 -I "$DD" "$APP/ManuscriptEditor.debug.dylib" \
  -Xlinker -rpath -Xlinker "$APP" -o "$WORK/template_divergence" template_divergence.swift
MANUSCRIPT_EDITOR_NO_SIGNING=1 MANUSCRIPT_EDITOR_LIBRARY_ROOT="$WORK/library" "$WORK/template_divergence"
