#!/bin/zsh
# Builds a Release distribution of Manuscript Editor into dist/ as a .dmg
# (the standard drag-to-Applications disk image).
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

# Stage the dmg contents: the app plus an /Applications symlink, so the
# mounted image is the familiar "drag the app onto Applications" window.
STAGE="$DIST/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/ManuscriptEditor-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Manuscript Editor $VERSION" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"

echo "Release artifact: $DMG"
echo "Publish with: gh release create v$VERSION \"$DMG\" --title \"Manuscript Editor $VERSION\""
