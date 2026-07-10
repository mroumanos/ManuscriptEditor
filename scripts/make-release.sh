#!/bin/zsh
# Builds a Release distribution of Manuscript Editor into dist/.
# Usage: ./scripts/make-release.sh <version>   e.g. ./scripts/make-release.sh 0.1.0
set -euo pipefail

VERSION="${1:?usage: make-release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
BUILD="$DIST/build"

mkdir -p "$DIST"
rm -rf "$BUILD"

xcodebuild -project "$ROOT/ManuscriptEditor/ManuscriptEditor.xcodeproj" \
  -scheme ManuscriptEditor \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD" \
  build

APP="$BUILD/Build/Products/Release/ManuscriptEditor.app"
[ -d "$APP" ] || { echo "error: build product not found at $APP" >&2; exit 1; }

ZIP="$DIST/ManuscriptEditor-$VERSION.zip"
rm -f "$ZIP"
# ditto preserves the app bundle's structure, symlinks, and extended attributes.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Release artifact: $ZIP"
echo "Publish with: gh release create v$VERSION \"$ZIP\" --title \"Manuscript Editor $VERSION\""
