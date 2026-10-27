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

35. **Word documents are written by the app (`Services/DocxWriter.swift`),
    not by Cocoa.** `NSAttributedString.data(…officeOpenXML)` was measured on
    macOS 26 with a probe (a table, an image, a double-spaced paragraph,
    read back as XML): it emits **no tables** — every `NSTextTable` cell is
    a paragraph of its own, a table as one column of values — **no images**
    (attachments are dropped: figures, a letterhead's logo) and **empty
    paragraph properties** (line spacing lost), and an attributed string
    cannot express sections, columns, page numbers or line numbering at
    all. Only the font survived. `DocxWriter` takes the same
    `PageSection`s the PDF paginator does, so geometry means one thing in
    both outputs, and writes WordprocessingML by hand: a Word section per
    outline section (margins, columns, `w:lnNumType`, a `PAGE` footer),
    paragraph spacing and alignment, runs with a real `w:vertAlign`, `w:tbl`
    from consecutive paragraphs sharing an `NSTextTable` (spans, borders,
    shading, padding, **absolute** widths — readers disagree about
    percentages), inline PNGs, and a store-only ZIP. Element order inside
    `pPr`/`rPr`/`tcPr`/`sectPr` follows the schema; Word is not forgiving
    about it. RTF still goes through Cocoa's writer (tables yes, images no).

36. **A table's alignment on the page is a table property, not its
    paragraphs'.** It was applied by centring every paragraph in the table
    block — right for the PDF, where the table is one drawn image on a line,
    and wrong for a native table, where it centres each cell's text. For
    Word the alignment rides on the cells as `ExportAttr.tableAlign` and
    becomes `w:tblPr/w:jc`.

37. **Verification harnesses live in `scripts/harness/`, not in a temp
    directory.** Every harness from Sep 2026 lived in a session scratchpad
    and was gone after a reboot — 160-odd assertions with it.
    `scripts/harness/docx_e2e.sh` is the pattern: compile against the Debug
    dylib, run with `MANUSCRIPT_EDITOR_NO_SIGNING=1`, check real output,
    exit non-zero on failure.

38. **The remote's save and load read ONE list of folders
    (`GitHubBackendService.managedFolders`).** They were two. The save grew
    `attachments/`, `context/`, `ai/` and `journals/` as each feature
    arrived; the load went on taking `manuscript.json`, `figures/` and
    `data/`. Nothing failed: a collaborator loaded the manuscript, the export
    outline named an uploaded file, and the pane said "File missing" for a
    file that was on GitHub the whole time. A new folder in the manuscript
    directory goes in that list and nowhere else — the save walks it to any
    depth, the load filters by it. `scripts/harness/remote_files.sh` checks
    that everything a save sends, a load takes.

39. **Create is for a repository that does not exist; it never writes into
    one that does.** The Overview probe used to mark `.missing` on any
    failure — a rejected token, a rate limit, an empty repository's 409, a
    GitHub hiccup — and show **Create** over a repository that existed;
    Create, finding the name taken, then pushed into it. Now the probe asks
    for the repository itself, only a 404 under the account's own login is
    `.missing`, everything else is `.unreachable(reason)` with Save|Load
    kept, and `createRemoteRepository` checks the bound repository's state
    before the first blob and refuses `.present`. The decision is a pure
    function (`ManuscriptStore.remoteStatus`) so
    `scripts/harness/remote_status.sh` can hold it to its word.

40. **A template proposal never merges, and a check that can't reach
    GitHub never warns.** `TemplatePublishing.propose` writes to a branch
    (or a fork) and opens a pull request — the corpus every install seeds
    from changes only by review. The published-copy check compares the
    manuscript's own copy by slug, then GUID, then part; a network failure
    is `.unknown` and shows nothing, because a false "not published" on
    every page would teach people to ignore the icon. Reads send no token
    (public repository); only a proposal reads the chosen account's token.
    Harness: `scripts/harness/template_divergence.sh`.

41. **A template's name and type are unique in a library.** The shared
    repository files templates by slug (name + type), so two templates under
    one label would be two sets of rules nobody could tell apart.
    `JournalProfileLibrary.save` refuses a taken name; copies are
    "<name> - copy", "- copy 2"…  A harness points the library at a scratch
    folder with `MANUSCRIPT_EDITOR_LIBRARY_ROOT`.

42. **Two kinds of section, named apart: a `manuscriptSection` is a
    component of the paper; a document section is a run of pages in an
    export with its own margin, line numbers, page numbers and columns.**
    In the code: `ExportItem.ItemType.manuscriptSection` (file value
    "section"), `ExportService.DocumentSection`, `StructureSection.type`,
    `ExportItem.type`. In the files: `export.json` is `TemplateOutline` —
    documents of a `type`, document `sections` with geometry, items of
    `type: component` by `title`, no ids — converted to and from the app's
    `ExportConfig` on read and write (`Models/TemplateOutline.swift`); a
    manuscript section's typography is written with its structure entry,
    never with an item, and a document carries none. A check scope's
    `kind` is `type` too (`CheckScope.ScopeType`). A template's files carry
    no ids and no identity but requirements.json's: rules and conditions
    leave their ids out under `CodingUserInfoKey.profileFile` and a reader
    derives the same ids every time; a manuscript keeps its own. `kind`,
    `sample`, a top-level `documentFormat`, rule ids and the app-shaped
    export.json are all still read. **Old checksums survive the renames**:
    `ProfileFingerprint.legacy(of:)` hashes the old spelling, and
    `JournalProfile.migrateChecksums()` replaces a stored checksum that
    matches it with the current one on read, so nothing reads as edited for
    a rename it never saw. The one `kind` left is `ManuscriptSection.kind`
    in manuscript.json, because `ManuscriptSection.type` is its legacy
    section type.

43. **A cut's active sections are its structure; the manuscript's sections
    are the union.** `templatedContent` deactivates, in a new cut, every
    section its template doesn't name; `setSectionActive(true)` and
    `addSection(ref:)` from a journal's tab give the structure an entry
    (`ensureStructureEntry`); `addSection` from Source leaves the section
    deactivated in every cut. `ExportConfig.standard`,
    `FastForwardIntent.payloads` and `syncJournal` follow `active` alone,
    and `SidebarView` greys deactivated sections and nothing else. Nothing
    joins a structure by being written to (an earlier version added an
    entry when a cut wrote to a section, and it confused more than it
    helped), and adding a journal must never touch another journal's
    structure or export — that was the "edited template" flag on every
    mismatched add. Clear (`clearSection`) is always offered;
    Delete only while no other journal has the section active
    (`journalsWithSection`), and `sectionUsers` names who still has text
    in it. Every sync, plain or adapted, starts from `syncBaseContent`:
    the upstream's text with THIS cut's activation — never the
    upstream's — and `applyAdaptation` writes active sections only.

46. **A cut never writes into a template; a changed name is a new
    template.** The cut's Details → Save opens the template editor with
    the journal's copy as the draft (`TemplateWorkspace.open(_:seedFrom:
    export:)`, the journal in `seededJournal`); `templateExport(for:)`
    points the cut's outline at the structure's uids on the way in. Save
    with the stored name and type overwrites (and the journal adopts the
    saved copy); with either changed, `savesAsNew` makes a new template
    (`saveAsNew` replaces the tab) and the seeded journal is re-pointed
    with `linkToTemplate` — the dialog must say so, because a moved link is
    invisible. The library's name-and-type uniqueness still gates both.

47. **Looking at the app is a harness too.** `scripts/harness/screenshot.sh
    <out dir> [pane …]` builds a scratch project against a bundle-seeded
    scratch library, launches the app once per pane with the harness-only
    hook `MANUSCRIPT_EDITOR_OPEN="<folder>|<pane>"` (`ContentView.
    openForHarness`; panes `overview · summary · checks · export ·
    section:<title> · template`, the journal panes in the first journal's
    tab), captures the window by id (`screencapture -l<id>`, never the
    desktop), and forgets the project from the app's defaults afterwards.
    There is no accessibility scripting on this machine, so one launch per
    pane is the only way onto a page; a harness never opens a person's
    manuscript.

48. **A List's move offsets are into the list it shows.** The sidebar lists
    the journal sections past the rule; the letter has a fixed row above
    it. `moveSections` moves the listed sections and writes the result
    back into the full order (the letter keeps its slot), then every
    version takes the order by section id. Moving the full array by the
    list's offsets was the "the neighbours moved, not my row" bug.

49. **Never decode an image in `body`, and never save on every keystroke.**
    `ImageDataCache.image(for:)` decodes once per bytes and rasterizes a
    vector once (an SVG-backed NSImage re-rasterizes on every draw: ~100 ms
    for a logo wrapping a raster); `FigureImageCache` does the same per
    figure file, and keeps each processed (crop, grayscale) result, so a
    thumbnail or a crop drag never runs `FigureImaging.processed` twice
    for the same settings. `touch` schedules a save half a second
    after the last edit, and the save encodes and writes a snapshot on a
    serial background queue; `trySave` / `flushPendingSave` drain that
    queue first, so writes land in order — they run before a manuscript is
    replaced and at quit, and a harness that reads the folder after an
    edit calls `flushPendingSave` first. `writeProfile` skips a journal
    whose rules' checksum it already wrote.

50. **Custom Codable witnesses in the models are `nonisolated`.** The
    module's default isolation is MainActor, so a hand-written
    `init(from:)` or `encode(to:)` makes that type's conformance
    main-actor-isolated, and every type containing it inherits that — the
    whole `Manuscript` could then only be encoded on the main thread (the
    compiler warns "main actor-isolated conformance … cannot be used in
    nonisolated context", an error in Swift 6 mode). Synthesized
    conformances infer nonisolated on their own; a new custom one must say
    `nonisolated`, or the background save stops compiling.

51. **A pane that keeps a local copy reloads it on an external change.**
    `SectionEditorView`, `AbstractView` and `QuestionSeriesView` hold the
    text in `@State` so typing does not round-trip the store; each has an
    `onChange` on the store's copy that reloads the local one when they
    differ, and skips its own write-back when they match.  Without it, a
    smart refresh wrote 353 words into the cut, the pane kept showing the
    old 171, and the next keystroke wrote those back.  `LetterSectionView`
    had this from the start; copy its pattern for any new pane.  **And the
    write-back is guarded by the section the copy was loaded for**
    (`loadedFor` / `draftFor`): the pane is reused across sections, and its
    editor branch is absent while a deactivated section shows, so the last
    section's text sat in the local copy and was written into whichever
    section was activated or opened next — that is how four AJPH sections
    became one Discussion.  The section switch is observed on the pane
    itself, never only on the editor branch.

44. **`checksum.txt` is the app's checksum, so only the app writes it.**
    `JournalProfile.write(to:)` writes it beside the four files, and
    `scripts/corpus/stamp.sh` (Swift, against the Debug build) writes it
    into the bundled corpus; Python cannot reproduce the fingerprint, so
    `build_corpus.py` is followed by `stamp.sh`, and the corpus harness
    fails on a stale one. A library copy records `publishedChecksum` — what
    it last took or matched — and is overwritten by a newer published or
    bundled copy only while `checksum == publishedChecksum`; a saved edit
    breaks that equality, and the copy is the user's from then on.

45. **A CLI agent gets no tools and a bounded effort.** `claude -p` and
    `codex exec` are agents: given tools and full effort, one fast-forward
    produced 204,466 output tokens in 23 minutes for a 3,000-token answer.
    `AIConnectorRunner` passes `--tools ""` and `--effort` (Claude Code) and
    `-c model_reasoning_effort=…` (Codex) from the connector's `effort`
    setting, and the prompt says the answer is the reply itself. Check
    `~/.claude/projects/…/<sessionID>.jsonl` (the app records the session
    id) when a run is slow: output tokens and tool uses say where it went.

## Generated journal profiles

- The JAMA Network and Health Affairs Scholar profiles
  (`ManuscriptEditor/JournalProfiles/jama-*`, `health-affairs-scholar-*`)
  are **generated** from `scripts/corpus/<network>/*.json` by
  `scripts/corpus/build_corpus.py`, whose `NETWORKS` table holds what a
  publisher's journals share. Change the spec, run the script, commit
  both; never hand-edit a generated folder. `build_corpus.py --check`
  reports a stale one.
- A spec states only what the journal's page states: every number is backed
  by the page's own sentence in `quotes`, and an unstated value is `null`,
  which the generator turns into no test — not a guessed one.
- `scripts/harness/corpus_profiles.sh` runs against the Debug build and
  fails if a bundled profile decodes with fewer rules or sections than its
  file holds, or under a GUID other than `bundledID(slug)`.

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

31. **A citation belongs to a claim, not to a position.** The first
    fast-forward protocol sent each citation run as an opaque marker that
    had to come back verbatim; a model halving a paper dropped them with the
    sentences and most sections were refused. Citations go to a model by
    **key** against a legend of the manuscript's references (`AIRefMarkers
    .Legend`), with rules on how they travel with claims, and come back as
    links; only an invented key, a section that lost every citation, or a
    lost field token refuses a section. Don't reintroduce per-occurrence
    markers or a "must keep" list for citations — the reference list is the
    context.

32. **`Manuscript.abstract` is a computed property over the abstract
    section, and `CodingKeys` is declared by hand.** The abstract became a
    section (Sep 2026); the property stayed so its readers didn't move. Two
    consequences: a manuscript with no abstract section reads empty and
    drops writes (check `abstractSection` before offering an editor), and
    the legacy `abstract` field is `legacyAbstract` — decoded under the old
    key, migrated on load, never encoded. Declaring `CodingKeys` was the
    price of that key mapping: **every stored property must be listed**, or
    it silently stops being saved. `Manuscript.new()` and the migration both
    give the abstract section its place at order 0.

33. **The citation raise belongs to the token, never to the next word.** A
    citation is drawn raised as a smaller font plus a baseline offset (not
    `.superscript`, which grows the line box). Text typed right after a
    token inherited both, the load-time typography pass then re-applied the
    raise to *every* lifted run and kept any smaller-than-body font as an
    "intentionally scaled run", and the superscript button toggled a
    different attribute — so a paragraph came out at citation size, raised,
    with nothing that could take it off. Now `carriesTokenStyle` resets
    typing attributes that carry a link, a lift, or a citation-sized font;
    `normalizeRaise` (load, font change, and script-off) keeps the raise only
    on token runs and returns everything else to the body font; a user's own
    `.superscript` is left alone. A saved file with the leftovers heals on its
    next open. The harness builds the exact storage the bug produced.

34. **The editor has one base format, and `normalizeTypography` is where
    it is enforced.** Every run comes out in the editing face and size —
    the app setting — keeping only what the toolbar can set: bold, italic,
    underline, strikethrough, a header level, a script; every paragraph gets
    the one line height and keeps only its alignment. Three things it
    replaced: sizes were preserved *relative to the dominant size* (any
    pasted or drifted size survived as an "intentional scale"; now a size
    snaps to the nearest of body / H1 / H2 / H3, never smaller than body),
    a single paragraph style was written over the whole text on every load
    (which threw away every centred title), and a user's super/subscript
    was drawn by TextKit at full size, which grows the line box — the
    uneven spacing. Scripts are now drawn like citations (shrunk, lifted or
    dropped) with the `.superscript` attribute kept for the RTF and for
    export, which materializes it itself. A script run that spans a
    paragraph break or runs past `scriptRunLimit` (80 characters) is not a
    script but the attribute left on prose — a paragraph toggled while it
    wore a citation's leftovers came back as a *subscript paragraph*, small
    and drawn low, with its citations lifted out of every line — and is
    read as body. If spacing or size looks uneven in the editor, it is a
    run this pass is not covering. **Every operation that writes a font
    over a range must leave tokens and scripts to `normalizeRaise`**: the
    Body/H1–H3 menu wrote the font over the whole paragraph, citations
    included, which put a raised citation at full size and grew every line
    it sat on — and it took its base size from the caret's font, so "Body"
    on a header kept the header's size (`applyHeadingLevel`).
