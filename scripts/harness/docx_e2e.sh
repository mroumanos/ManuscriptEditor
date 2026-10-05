#!/bin/bash
# docx_e2e.sh — export a manuscript with a table, a logo letterhead and line
# numbering to Word through the app's real export path, then open the files
# and check what is in them.
#
#   scripts/harness/docx_e2e.sh
#
# Needs a Debug build (xcodebuild … build).  Runs with signing off, so
# nothing touches the Keychain.  Exits non-zero when a check fails.
set -euo pipefail
cd "$(dirname "$0")"
DD="$(xcodebuild -project ../../ManuscriptEditor/ManuscriptEditor.xcodeproj -scheme ManuscriptEditor \
      -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP="$DD/ManuscriptEditor.app/Contents/MacOS"
WORK="$(mktemp -d /tmp/me-docx-e2e-XXXX)"
swiftc -target arm64-apple-macos26.5 -I "$DD" "$APP/ManuscriptEditor.debug.dylib" \
  -Xlinker -rpath -Xlinker "$APP" -o "$WORK/docx_e2e" docx_e2e.swift
( cd "$WORK" && MANUSCRIPT_EDITOR_NO_SIGNING=1 ./docx_e2e >/dev/null )
python3 - "$WORK/out/Probe Submission" <<'PY'
import sys, zipfile, re, xml.dom.minidom, os
folder = sys.argv[1]; failures = 0
def check(label, ok, detail=""):
    global failures
    print(("PASS  " if ok else "FAIL  ") + label + ("" if ok else "  " + str(detail)))
    failures += 0 if ok else 1
def doc(name):
    z = zipfile.ZipFile(os.path.join(folder, name))
    check(f"{name}: the archive is intact", z.testzip() is None)
    for part in z.namelist():
        if part.endswith((".xml", ".rels")): xml.dom.minidom.parseString(z.read(part))
    check(f"{name}: every XML part is well-formed", True)
    return z, z.read("word/document.xml").decode()

z, x = doc("Manuscript.docx")
check("a table is a table: one w:tbl, a merged title row, a header, two data rows",
      x.count("<w:tbl>") == 1 and x.count("<w:tr>") == 4 and "<w:gridSpan w:val=\"3\"/>" in x, (x.count("<w:tbl>"), x.count("<w:tr>")))
check("the table states its width and its columns in twips",
      re.search(r'<w:tblW w:w="7488" w:type="dxa"/>', x) and len(re.findall(r"<w:gridCol ", x)) == 3)
check("the TABLE is centred, not its cells' text", re.search(r"<w:tblPr><w:tblW[^>]*/><w:jc w:val=\"center\"/>", x) is not None)
check("the font travels", set(re.findall(r'w:ascii="([^"]+)"', x)) == {"Times New Roman"}, set(re.findall(r'w:ascii="([^"]+)"', x)))
check("double spacing travels", 'w:line="480" w:lineRule="auto"' in x)
check("line numbering travels, continuous across sections", x.count('<w:lnNumType w:countBy="1" w:restart="continuous"/>') == x.count("<w:sectPr>") == 3)
check("each outline section is a Word section with its margins", x.count('<w:pgMar w:top="1440"') == 3)
check("page numbers are a footer field", "word/footer1.xml" in z.namelist() and " PAGE " in z.read("word/footer1.xml").decode())

z, x = doc("Letter to the Editor.docx")
check("the letterhead is one row of three cells", x.count("<w:tbl>") == 1 and x.count("<w:tr>") == 1 and x.count("<w:tc>") == 3)
check("and its logo is in the file", x.count("<w:drawing>") == 1 and "word/media/image1.png" in z.namelist()
      and z.read("word/media/image1.png")[:4] == b"\x89PNG")
check("with the address beside it, right-aligned", "Shuo Jim Huang" in x and '<w:jc w:val="right"/>' in x)
print("ALL PASS" if failures == 0 else f"{failures} FAILURE(S)")
sys.exit(1 if failures else 0)
PY
rm -rf "$WORK"
