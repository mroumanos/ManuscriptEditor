#!/bin/zsh
# Builds a Release distribution of Manuscript Editor into dist/ as a .dmg
# (the standard drag-to-Applications disk image), signed with Developer ID
# and — when a notary profile is provided — notarized and stapled.
#
# Usage:
#   ./scripts/make-release.sh <version>
#   NOTARY_PROFILE=ManuscriptEditor ./scripts/make-release.sh <version>
#
# One-time notarization setup (Apple ID app-specific password from
# appleid.apple.com → Sign-In and Security → App-Specific Passwords):
#   xcrun notarytool store-credentials ManuscriptEditor \
#     --apple-id <your appleid email> --team-id M72QBAW2TT
set -euo pipefail

VERSION="${1:?usage: make-release.sh <version>}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Michael Roumanos (M72QBAW2TT)}"
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

# Developer ID signature with hardened runtime + secure timestamp —
# both required for notarization.
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

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
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# Notarize + staple when a keychain profile is provided; downloads then
# open with no Gatekeeper friction at all.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "Notarizing (waits for Apple)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Notarized and stapled."
else
  echo "note: not notarized (set NOTARY_PROFILE=<profile> to notarize) —"
  echo "      downloaders must approve the first launch in System Settings."
fi

echo "Release artifact: $DMG"
echo "Publish with: gh release create v$VERSION \"$DMG\" --title \"Manuscript Editor $VERSION\""
