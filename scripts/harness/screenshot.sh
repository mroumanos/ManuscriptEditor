#!/bin/bash
# screenshot.sh — launches the app on a scratch project, one pane at a time,
# and captures its window (by window id — never the desktop).  For looking
# at a change before claiming it works; the app has no accessibility
# scripting here, so each pane is a launch.
#
#   scripts/harness/screenshot.sh <out dir> [pane …]
#   panes: overview · summary · checks · export · section:<title> · template
#
# The app's own defaults are left as they were: the scratch project is
# forgotten again when the capture is done.  Needs a Debug build; runs
# with signing off (no Keychain) and the library pointed at a scratch
# folder for the project builder (the app itself uses your library).
set -euo pipefail
OUT="${1:?out dir}"; shift
PANES=("${@:-summary}")
cd "$(dirname "$0")"
DD="$(xcodebuild -project ../../ManuscriptEditor/ManuscriptEditor.xcodeproj -scheme ManuscriptEditor \
      -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP="$DD/ManuscriptEditor.app/Contents/MacOS"
WORK="$(mktemp -d /tmp/me-shot-XXXX)"
mkdir -p "$OUT"
swiftc -target arm64-apple-macos26.5 -I "$DD" "$APP/ManuscriptEditor.debug.dylib" \
  -Xlinker -rpath -Xlinker "$APP" -o "$WORK/build" screenshot.swift
ID="$(MANUSCRIPT_EDITOR_NO_SIGNING=1 MANUSCRIPT_EDITOR_LIBRARY_ROOT="$WORK/library" "$WORK/build" "$WORK/project" | tail -1)"
echo "scratch project $ID in $WORK/project"

cat > "$WORK/winid.swift" <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "ManuscriptEditor" {
    let b = w["kCGWindowBounds"] as! [String: Any]
    if (b["Height"] as! Double) > 300 { print(w["kCGWindowNumber"] as! Int); break }
}
SWIFT
cat > "$WORK/forget.swift" <<'SWIFT'
import Foundation
// Drops the scratch project from the app's own list, so Welcome never shows it.
let id = CommandLine.arguments[1]
let d = UserDefaults(suiteName: "knktech.ManuscriptEditor")!
var ids = (d.array(forKey: "allManuscriptIDs") as? [String]) ?? []
ids.removeAll { $0 == id }
d.set(ids, forKey: "allManuscriptIDs")
for key in ["manuscriptFolder_\(id)", "manuscriptOpenedAt_\(id)"] { d.removeObject(forKey: key) }
if d.string(forKey: "lastOpenedManuscriptID") == id { d.removeObject(forKey: "lastOpenedManuscriptID") }
d.synchronize()
SWIFT
cleanup() {
  pkill -x ManuscriptEditor || true
  swift "$WORK/forget.swift" "$ID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for pane in "${PANES[@]}"; do
  pkill -x ManuscriptEditor || true; sleep 1
  MANUSCRIPT_EDITOR_NO_SIGNING=1 MANUSCRIPT_EDITOR_OPEN="$WORK/project|$pane" \
    nohup "$APP/ManuscriptEditor" >/dev/null 2>&1 &
  sleep 7
  WID="$(swift "$WORK/winid.swift" 2>/dev/null | head -1)"
  name="${pane//:/-}"
  if [ -n "$WID" ]; then
    screencapture -x -o -l"$WID" "$OUT/$name.png" && echo "captured $OUT/$name.png"
  else
    echo "no window for $pane"
  fi
done
