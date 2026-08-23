#!/bin/bash
# release.sh — one-shot Manuscript Editor release.
#
#   scripts/release.sh <version> [notes-file]
#
# Steps: bump version → Release build (Developer ID, hardened runtime) →
# DMG with volume icon → notarize + staple (keychain profile "notary") →
# commit/tag/push → GitHub release with generated notes → Slack announce.
#
# Release notes: [notes-file] if given, else generated from the commit
# subjects since the previous release tag.
#
# Slack: reads the incoming-webhook URL from the Keychain item
# "ManuscriptEditor-slack-webhook" (add once with:
#   security add-generic-password -s ManuscriptEditor-slack-webhook -a slack -w '<url>'
# ); skipped with a notice when absent.

set -euo pipefail

VERSION="${1:?usage: release.sh <version> [notes-file]}"
NOTES_FILE="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$REPO_ROOT/ManuscriptEditor"
PBX="$PROJ/ManuscriptEditor.xcodeproj/project.pbxproj"
IDENTITY="Developer ID Application: Michael Roumanos (M72QBAW2TT)"
WORK="$(mktemp -d /tmp/me-release-XXXX)"
DMG="$WORK/ManuscriptEditor-$VERSION.dmg"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

step "Preflight"
cd "$REPO_ROOT"
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean"; exit 1; }
[ "$(git branch --show-current)" = "main" ] || { echo "not on main"; exit 1; }
git fetch --tags --quiet   # gh-created release tags live remotely
PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"
echo "previous tag: ${PREV_TAG:-none}"

step "Bump version to $VERSION"
CUR_BUILD=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PBX" | grep -o '[0-9]*')
NEW_BUILD=$((CUR_BUILD + 1))
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PBX"
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBX"
echo "version $VERSION (build $NEW_BUILD)"

step "Release build (signed, hardened runtime)"
xcodebuild -project "$PROJ/ManuscriptEditor.xcodeproj" -scheme ManuscriptEditor \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$WORK/dd" \
  CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER= \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build | grep -E '\*\* BUILD' || { echo "build failed"; exit 1; }
APP="$WORK/dd/Build/Products/Release/ManuscriptEditor.app"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow \
  && { echo "get-task-allow present — notarization would fail"; exit 1; } || true

step "DMG (with volume icon)"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Manuscript Editor" -srcfolder "$STAGE" -ov -format UDRW "$WORK/rw.dmg" >/dev/null
MP=$(hdiutil attach "$WORK/rw.dmg" -nobrowse | awk -F'\t' '/Volumes/{print $NF}')
SetFile -a C "$MP"
hdiutil detach "$MP" >/dev/null
hdiutil convert "$WORK/rw.dmg" -format UDZO -o "$DMG" >/dev/null
codesign --timestamp -s "$IDENTITY" "$DMG"

step "Notarize + staple"
xcrun notarytool submit "$DMG" --keychain-profile notary --wait | tee "$WORK/notary.log"
grep -q 'status: Accepted' "$WORK/notary.log" || { echo "notarization rejected"; exit 1; }
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature "$DMG" || { echo "gatekeeper check failed"; exit 1; }

step "Release notes"
NOTES="$WORK/notes.md"
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
  cp "$NOTES_FILE" "$NOTES"
else
  {
    echo "## Changes since ${PREV_TAG:-the beginning}"
    echo
    if [ -n "$PREV_TAG" ]; then RANGE="$PREV_TAG..HEAD"; else RANGE="HEAD"; fi
    git log --no-merges --pretty='- %s' "$RANGE"
    echo
    echo "Signed with a Developer ID certificate and notarized by Apple — opens cleanly on download."
  } > "$NOTES"
fi
sed -n '1,12p' "$NOTES"

step "Commit, tag, push, GitHub release"
git add -A
git commit -m "Release $VERSION (build $NEW_BUILD)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git tag "v$VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "$DMG" --title "Manuscript Editor $VERSION" --notes-file "$NOTES"
RELEASE_URL="$(gh release view "v$VERSION" --json url --template '{{.url}}')"
echo "$RELEASE_URL"

step "Slack announcement"
WEBHOOK="$(security find-generic-password -s ManuscriptEditor-slack-webhook -w 2>/dev/null || true)"
if [ -n "$WEBHOOK" ]; then
  HIGHLIGHTS="$(git log --no-merges --pretty='• %s' "${PREV_TAG:+$PREV_TAG..}HEAD" | head -12)"
  python3 - "$WEBHOOK" "$VERSION" "$RELEASE_URL" "$HIGHLIGHTS" <<'PYEOF'
import json, sys, urllib.request
webhook, version, url, highlights = sys.argv[1:5]
text = (f":package: *Manuscript Editor {version}* is out!\n"
        f"Download: {url}\n\nWhat's new:\n{highlights}")
req = urllib.request.Request(webhook, json.dumps({"text": text}).encode(),
                             {"Content-Type": "application/json"})
print(urllib.request.urlopen(req).status)
PYEOF
  echo "announced on Slack"
else
  echo "no Slack webhook stored — add one with:"
  echo "  security add-generic-password -s ManuscriptEditor-slack-webhook -a slack -w '<url>'"
fi

step "Done — $VERSION shipped"
