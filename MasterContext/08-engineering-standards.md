# 08 — Engineering Standards

## Code structure

- One responsibility per type; small, well-named types over large catch-alls.
- **Models** (`Models/`): plain `Codable`, `Sendable`, `Identifiable` value types.
  No UI, no store references.
- **Stores** (`Store/`): `@MainActor @Observable`. All mutation funnels through a
  single `touch`-style helper that stamps `updatedAt` and saves. Public mutators
  take `ref: VersionRef = .source`.
- **Services** (`Services/`): stateless utilities (caseless enums or structs).
  Pure logic, easy to test.
- **Views** (`Views/`, `Theme/`): SwiftUI; read stores via `@Environment`. Keep
  AppKit interop isolated in dedicated files (`Theme/RichTextEditor.swift`).

### Core vs journal content is one question, answered in one place

`Models/ContentClass.swift` says which side every piece of content is on
(see [`02-domain-model.md`](02-domain-model.md), "Core content and journal
content"). A feature that treats the two differently — and most do: adding a
journal, sync, Assist, templates, checks, the outline, both sidebars — asks
`isCore` / `isJournalContent`, `StructureSection.subject`,
`JournalStructure.journalEntries` / `sectionEntries` / `abstractEntry`,
`ExportItem.Kind.coreKinds`, `SidebarItem.contentClass`. It does **not** test
`sectionKind == .letter` or `key == "abstract"` to decide ownership: every
site that did got the next exception wrong. Testing `.letter` to render a
letterhead is fine — that is about what a letter is, not whose it is.

## Documentation (match the existing density)

- Every file opens with a header comment: what it is and the key design intent.
- Every type and every non-obvious method/property gets a doc comment explaining
  **why**, not just what. Call out invariants and platform quirks inline.
- When a decision is non-obvious (e.g. "TextKit 1 required on macOS 26"), leave a
  comment so the next person/LLM doesn't "fix" it back into a bug.

## Persistence & compatibility

- New model fields use `decodeIfPresent` (+ sensible default) so older
  `manuscript.json` files keep opening.
- Save atomically; never partially write the model.
- Treat the user's chosen folder as the source of truth; access it through the
  security-scoped bookmark.

## Testing

- The brief requires the app be "thoroughly documented and tested." Prioritize
  unit tests on pure logic that the data-integrity promise rests on:
  `DataService` (CSV parse RFC-4180 edge cases, SQL execution + errors),
  `WordCountService`, `ChecklistService`, `ViewConfig.from(journal:)`, and
  `Manuscript`/`RichText` Codable round-trips including legacy decode.
- UI is verified by building and running (see below); logic is verified by tests.

## Build & verify (do this every change)

```
cd ManuscriptEditor
xcodebuild -scheme ManuscriptEditor -destination 'platform=macOS' build
```

- A green build is necessary, **not sufficient**. For UI/behavior changes, run the
  app and look before claiming success. Launch:
  `open "$(xcodebuild -scheme ManuscriptEditor -destination 'platform=macOS' \
   -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2}/ FULL_PRODUCT_NAME /{n=$2}END{print d"/"n}')"`
- Report failures honestly with the actual output. If you can't verify (e.g. no
  screen access), say so rather than asserting it works.

## Known platform gotchas (hard-won — do not regress)

1. **TextKit 1 is required for the editor on macOS 26.** A default `NSTextView`
   uses TextKit 2, where the TextKit-1 `layoutManager` is `nil` and the line-number
   gutter silently draws nothing. Build an explicit stack: `NSTextStorage` →
   `NSLayoutManager` → `NSTextContainer`, then `NSTextView(frame:textContainer:)`.
2. **Don't override `NSRulerView.draw(_:)` without calling `super`.** It blanks
   the scroll view. To restyle, call `super` then overpaint, or avoid overriding.
3. **Height-pin horizontal `ScrollView`s** (e.g. the formatting toolbar). Unpinned
   they grow vertically and the AppKit text view can overlap the SwiftUI chrome.
4. **macOS top safe area is the title bar.** Don't pin the comparison tab bar with
   `.safeAreaInset(edge: .top)`; place it first in a `VStack`.
5. **`onChange(of:)` needs `Equatable`.** Model arrays whose element isn't
   `Equatable` → observe `array.map(\.id)`.
6. **Detail views must not set `.navigationTitle`** — only the manuscript name
   should appear as the window title.
7. **Lists: kill stray glass.** `.scrollContentBackground(.hidden)` + a solid
   semantic background, and `frame(maxHeight: .infinity)`, or the pane renders as
   a floating translucent card.
8. **Side-by-side panes** are the same content views parameterized by
   `versionRef`; give each pane `.id(ref)` so SwiftUI keeps their state distinct.
9. **`"\r\n"` is a single Swift `Character`.** Iterating a `String` (or
   `Array(text)`) yields grapheme clusters, so a CRLF never matches a `"\r"` or
   `"\n"` case — a character-level parser silently swallows every Windows/Excel
   line break (the CSV importer once globbed whole files into one giant row this
   way). Normalize `\r\n` → `\n` before parsing, or iterate unicode scalars.
10. **Text-view undo must be scoped to the view's lifetime.** `NSUndoManager`
    holds action targets *unretained*; an `NSTextView` (including the one
    backing SwiftUI's `TextEditor`) registers typing operations into the
    window's long-lived undo manager, and when the view is destroyed (row
    deleted, pane switched, identity churn) ⌘Z dispatches
    `_undoRedoTextOperation:` into freed memory (the issue-#8 crash). Every
    text surface must use a manager owned by its coordinator (delegate
    `undoManager(for:)`), cleared on `dismantleNSView` and on programmatic
    content reloads. **Never use raw SwiftUI `TextEditor`** — use
    `PlainTextEditor` (Theme/), which exists precisely for this.
11. **The app runs UNSANDBOXED** (`ENABLE_APP_SANDBOX = NO`) — deliberately.
    The sandbox blocked two must-haves: reading `/opt/homebrew` (so `gpg` was
    unreachable for the local-keyring dropdown) and reading `~/.gnupg` (grants
    don't inherit to child processes). Do not re-enable it casually: sandboxed
    and unsandboxed builds use **different data homes** (container vs real
    `~/Library`) and **different Keychain partitions** (items written by one
    are invisible to the other). `SandboxMigration.runIfNeeded()` (called
    before the stores load) does the one-time container → real-`~/Library`
    migration; `KeychainService.setSecret` recovers slots blocked by an
    inaccessible other-partition item (delete-then-add on
    `errSecDuplicateItem`). Sandbox-era Keychain secrets are unrecoverable —
    users re-enter them once.
12. **One `alert(item:)` per view *branch*, ancestors included.** Two alert
    modifiers on the same node: only the last fires (killed the Sync button,
    the ⏪⏩ sync buttons, and the Load buttons — three separate times). But
    the rule is broader: an `alert(item:)` on an **ancestor** suppresses one
    on a descendant the same way (the delete alert on JournalLineageCard's
    outer VStack silently ate the sync confirmations on `lineageTree`
    inside it). Attach each alert to its own node on **sibling branches** —
    never stack them, never nest them.

13. **AppKit's `officeOpenXML` writer drops tables AND images.** Verified
    with minimal, textbook AppKit code (no app involvement): an
    `NSTextTable` written to `.docx` produces **zero** `<w:tbl>` elements —
    just one paragraph per cell — and an `NSTextAttachment` image produces
    no `word/media/` entry and no `<w:drawing>`. Plain `.rtf` DOES emit
    real tables (`\trowd`) but also drops attachment images (only `.rtfd`
    packages them, and that's a bundle Word can't read). So the DOCX path
    is text + character formatting only; **real Word tables/figures need a
    hand-written WordprocessingML writer** (document.xml + rels +
    `[Content_Types].xml` in a zip container), not a tweak to the AppKit
    call. PDF is unaffected — it's our own paginator.

14. **A preceding paragraph strands from what follows it.** Neither
    CoreText nor NSTextTable has "keep with next", so a table title
    written as its own paragraph stays behind when the table reflows to
    the next page. Fix per writer: PDF draws the title INTO the first
    chunk image (one unbreakable attachment); attributed writers make it
    the table's own full-width, borderless first row.

15. **A spreadsheet grid belongs in AppKit, not SwiftUI.** SwiftUI's
    mapping between where scrolling content DRAWS and where it HIT-TESTS
    goes stale after a structural change to that content (resizing a
    column, deleting a row or column). The symptom is a CONSTANT offset —
    clicks landing two rows below the cursor — that heals on scroll or
    when the view is recreated, and only reproduces on content wide
    enough to scroll. Five variants of the pointer math all drifted the
    same way (container-local, named space, global minus a captured
    origin, and finally per-cell reporting), because the defect was never
    in our arithmetic. `SpreadsheetGrid` is now an `NSScrollView` +
    custom `NSView`: `convert(_:from: nil)` is computed from the live
    hierarchy at event time and cannot be stale, and only visible rows
    draw. **The frozen header and row rail are DRAWN by the grid
    view itself**, at the current scroll offset. Two attempts to make them
    separate views both failed to composite: `addFloatingSubview(_:for:)`
    installs a full-size `_NSScrollViewFloatingSubviewsContainerView` over
    the clip view and the document view vanished entirely, and a sibling
    header stacked above the scroll view rendered blank inside its
    container (both verified by rendering the same view standalone — it
    painted every row — and in the composite, where it didn't). One view
    means one coordinate space, one hit test, and nothing to composite.
    The superseded rule, kept because it still applies to any grid-like
    SwiftUI view: **don't hit-test a scrolling grid from its container.** Any pointer
    math that converts a point into a container's space — `.local`,
    `.named`, or `.global` minus a captured origin — drifts when that
    container's content size changes mid-interaction (dragging a column
    divider inside a horizontally scrolled `ScrollView` does exactly
    that). The symptom is a CONSTANT offset ("clicks land two rows
    below") that heals on scroll or when the view is recreated, because
    both force a fresh layout — and it only reproduces on content wide
    enough to scroll. Fix: let each **cell** own its input and report its
    own `(row, column)` plus points in ITS OWN space; the container does
    arithmetic on those, never a conversion. Deltas (a resize drag) are
    safe in `.global`, where they are pure pointer travel.

16. **Look up bundled resources in the bundle that holds the CODE, not
    `Bundle.main`.** The target uses a
    `PBXFileSystemSynchronizedRootGroup`, so a folder dropped into the app
    directory ships automatically — but its resources are FLATTENED into
    `Contents/Resources`, so `urls(forResourcesWithExtension:subdirectory:)`
    with the folder name finds nothing. **Nested folders are worse than
    flattened: they COLLIDE.** Seventeen journal profiles each holding a
    `requirements.json` fail the build outright with "Multiple commands
    produce …/Resources/requirements.json". The fix is a real **folder
    reference** — `JournalProfiles/` sits beside the .xcodeproj (outside
    the synchronized group), added as a `PBXFileReference` with
    `lastKnownFileType = folder` in the Resources phase; directory
    structure and duplicate file names then survive into
    `Contents/Resources/JournalProfiles/<slug>/`, and the code reads it
    with `Bundle.url(forResource:withExtension: nil)`.
    And `Bundle.main` is whatever executable is running: in
    the swiftc verification harness that is the harness, which carries no
    resources, so a lookup that works in the app silently returns nothing
    under test — the seeding of journal profiles appeared broken for
    exactly this reason. `Bundle.containingCode` (`Bundle(for:)` on a
    private marker class) resolves to the app bundle in both.

17. **An attachment taller than the page silently eats the rest of the
    section.** In the PDF paginator a figure, chart, or drawn table chunk is
    an `NSTextAttachment` on its own line fragment, and CoreText will not
    split a line: if it doesn't fit, `CTFrameGetVisibleStringRange` returns
    zero and the old loop treated that as "section finished", discarding the
    image AND everything after it. Verified with a 400×4000 image: the
    figure's own caption vanished from the PDF while a 300pt control kept it.
    Two defences, keep both: **clamp attachment height** to the content box
    (`attachmentBlock` fits to whichever of width/height binds — letterhead
    and signature were already capped at 40/48pt), and in the paginator, when
    a whole page places nothing, **step over that one character** rather than
    abandoning the section. Pages are also laid out BEFORE `beginPDFPage`, so
    a page that would hold nothing is never opened.
    Related: a table's chunks are cut to a page MINUS ~50pt, because each
    chunk is followed by a newline that has to fit on the same page — without
    that slack a chunk that just fits pushes its own terminator onto a blank
    sheet.

18. **A store must never write state it never read.** `AppStore.save()`
    serialises whatever is in memory; every array starts empty, so a save from
    an instance that never called `load()` writes those empties over a
    populated `app.json` and takes the user's accounts with it. This is not
    hypothetical — a view hosted outside the normal hierarchy (so the
    `onAppear` that calls `load()` never ran) plus one button press wiped
    stored backends, and only the Keychain secrets, which are keyed by account
    id, made recovery possible. `save()` now refuses before `load()`:
    `assertionFailure` in debug so it is found, a silent return in release so a
    user is never harmed. Any new store with the same load/save shape needs the
    same guard.

## Releasing

`scripts/release.sh <version> [notes-file]` runs the whole pipeline: bump
(MARKETING_VERSION + build number) → signed Release build (Developer ID,
hardened runtime, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` — a plain build
injects get-task-allow, which Apple rejects) → DMG with volume icon →
notarize + staple (keychain profile "notary") → commit/tag/push → GitHub
release (notes from the given file, else commit subjects since the last
tag) → Slack announcement (incoming webhook from the Keychain item
`ManuscriptEditor-slack-webhook`; skipped with instructions when absent).
Requires: clean tree on main, the Developer ID cert, `gh` auth.

## Working style for LLM contributors

- Start from this Master Context; don't infer requirements from a single recent
  message.
- Make the smallest change that satisfies the acceptance criteria; match
  surrounding patterns.
- Don't introduce dependencies. Build Phase I and Phase II per
  [`09-roadmap.md`](09-roadmap.md); **Phase III (automated submission, active
  collaboration) is stub-only** — don't build it.
- Update the relevant Master Context doc in the same change when a requirement
  shifts.

19. **A verification harness must not be able to prompt for the Keychain.**
    A harness links the app's code, and creating a version signs it, which
    reads the app's own signing key. From a different binary macOS asks the
    user for permission — so a test run on someone's machine produces a
    Keychain prompt that looks, reasonably, like the tool reading their
    passwords. Harnesses set `MANUSCRIPT_EDITOR_NO_SIGNING=1`
    (`SigningService.signingDisabled`) and the versions they make are simply
    unsigned. Nothing a verification run does should ever ask the user for
    anything.

20. **"Nothing stored" and "couldn't read it" are different facts.**
    `KeychainService.secret` returned nil for both, and `SigningService` read
    nil as "first run" — so a denied Keychain prompt, or a rebuilt app whose
    signature no longer matched the item's ACL, minted a NEW signing key and
    wrote it over the old one. One real manuscript ended up with three keys
    under one author's name. An identity that regenerates itself on a failed
    read is not an identity. `KeychainService.read` returns
    `found/notFound/unreadable`, and only `notFound` may create anything.

21. **The journal corpus in the repo is the source of truth, not the user's
    library.** `JournalProfileLibrary.load()` re-seeds any bundled profile the
    library no longer holds — so a correction made only in
    `~/Library/Application Support/.../JournalLibrary/` is restored to the
    stale version the moment its folder goes missing. Twice. Fix
    `ManuscriptEditor/JournalProfiles/<slug>/` (version-controlled, reviewable)
    and let the library re-seed; only touch a library copy to clear one that
    predates the fix.

22. **A model persisted through a separate `Doc` type loses every field the
    `Doc` doesn't have.** `JournalStructure` carried `coreFormats` and
    `documentFormat` in memory, but `structure.json` is written from
    `StructureDoc`, which had neither — so a template's typography survived
    inside a manuscript (where the whole struct is encoded) and vanished the
    moment it was saved to the library or travelled with a manuscript. No
    error, no warning: half the file simply wasn't there. Adding a field to a
    model that has a document type means adding it in three places — the
    model, the `Doc`, and `read`. Gotcha 12 is the same failure one layer
    down; between them they have now cost four bugs.

23. **A value's identity must not be something the user can type.**
    `StructureSection.id` was the lowercased title, which was fine while
    sections were a list you typed once — and broke the moment one could be
    edited in place: every keystroke made it a *different* section, so the
    editor you were typing in vanished. Sections carry a `uid` now, written as
    `id` (which `ProfileFingerprint` strips, so no existing template's
    checksum moved) and **derived from the title** when a file has none, so
    every install reads the same id for the same shipped section. Title
    matching still exists — it is how a template maps onto a manuscript — but
    it lives in `key`, not in `id`.

24. **A pane in a `NavigationSplitView` detail hands its IDEAL size to the
    split view.** A pane built as a header over a `ScrollView` reports the
    whole scrollable content as its ideal height; the split view grows to it,
    the window can't, and the result is that everything — the sidebar
    included — is laid out past the window's edge and the window looks
    **empty**. Measured: a 700-point window whose split view was 1271 points
    tall, offset -284. A long unwrapped `Text` does the same to width (an ideal
    of 1489 points), which squeezes the sidebar instead.
    Two defences, both in use: cap the content width
    (`TemplateLayout.contentWidth`) so a pane's ideal width is a reading
    measure rather than a sentence's length, and wrap the pane in a container
    with **no intrinsic size** — a `GeometryReader` — so it fills the column
    instead of telling the column how big to be (`PaneContainment` in
    `TemplateEditor.swift`). The regression test is mechanical: host the pane
    in a split view and assert the split view's frame equals the window's
    (`fitcheck` harness).

25. **AppKit views don't clip their subviews; a ruler paints wherever it
    likes.** `NSView.clipsToBounds` has defaulted to `false` since macOS 14,
    and the editor's line-number `NSRulerView` drew its separator hairline
    far outside its scroll view — a vertical line from the window's tab bar
    to its bottom edge, straight through any pane header above the editor,
    at exactly the gutter's x. It survived an opaque header (it was drawn on
    top) and showed up in no view-hierarchy dump (it is a stroke, not a
    view). Hunting it took a red-background experiment and a pixel crop.
    Both the scroll view and the ruler set `clipsToBounds = true` now. If a
    line appears somewhere no view is, suspect an unclipped draw.

26. **A grouped `Form` puts any row holding a labeled text field in its
    trailing column.** The connector panes' path and server-URL rows were a
    narrow, right-aligned field at the far right with nothing beside it —
    however the row around the field was framed (`HStack`, `maxWidth:
    .infinity`, `alignment: .leading`, none of it mattered). The Form keys
    on the field's *label*: a `TextField` with a title, even an empty one,
    is label + value, and the value goes right. `.labelsHidden()` on the
    field (plus `.multilineTextAlignment(.leading)`) takes the row out of
    that treatment, and it then spans the width like a caption row. The
    `pathRow` in `ConnectorDetailView` is the pattern: value on the left,
    copy + change on the right.

27. **An outline (or any optional override) that equals its derived
    baseline must be stored as `nil`.** `JournalTemplate.export` and
    `Journal.exportConfig` are `nil` until someone changes something; the
    pane shows the standard outline derived from the sections meanwhile.
    Committing whatever the pane holds back into the model stored a
    materialized copy of that same outline — with its own fresh item ids —
    so adding a document and deleting it again read as an edit and marked
    the part as differing from the library. `TemplateWorkspace.setExport`
    and `ManuscriptStore.updateExportConfig` compare the committed outline
    to the baseline by `ProfileFingerprint` (which strips `id` keys) and
    store `nil` when they match. Apply the same rule to any future
    "override or inherit" field.

28. **Template text becomes manuscript text only through
    `PartEngine.richText`.** A `[[title]]` token is nothing but its marker
    plus a `part://` link in the RTF; `RichText(plain:)` keeps the marker
    and loses the link, so boilerplate written that way arrived as literal
    `[[title]]` that clicked like prose and never resolved on export — three
    times, in three places (the template editor, adding a journal, the
    fast-forward) — and a fourth on the way back from a model, where
    `AIRefMarkers.restore` appended a returned `[[title]]` as text. Any new
    place a template's text lands in a section goes through `richText`
    (`restore` uses `tokenized` for the same reason), and the harness checks
    the link is there.

29. **The adaptation is the last write.** `syncJournal` once applied the
    model's rewrite and then re-applied the template's content over it — so
    every adapted section came back as its boilerplate while the banner and
    the log both reported the rewrite (the changes are measured before the
    write). The prompt log's *applied, 7 changes* was true and useless. When
    a write path has several contributors, the one the user asked for goes
    last, and the harness asserts what lands, not what was measured.

30. **Never join rich text as strings.** `RichText(plain: a + "\n\n" + b)`
    was how an Append-mode sync combined a cut's text with the incoming copy.
    It kept the words and lost the RTF — and a citation is a link attribute
    in the RTF, nothing else — so one Append flattened every section it
    touched; Source went from 18 citation links to none between two stamps,
    and the next assisted run had nothing to mark. `RefEngine.joined` is the
    only way two `RichText`s become one. The tell in the data: every section
    exactly N characters longer, with `rtf` gone.
