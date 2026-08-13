# 03 — Architecture

## Platform & stack

- **Native macOS** app, target **macOS 26 (Tahoe)**. SwiftUI primary, AppKit
  interop where SwiftUI is insufficient (rich text editor).
- State via the Swift **`@Observable`** macro. No external dependencies — every
  capability is native (this is a deliberate, standing constraint; adding a
  package requires explicit approval).
- Xcode project uses `PBXFileSystemSynchronizedRootGroup`: files added to the
  source tree are auto-included. `OTHER_LDFLAGS = -lsqlite3` links system SQLite.
  App Sandbox with `ENABLE_USER_SELECTED_FILES = readwrite`.

## Stores (the two `@Observable` sources of truth)

- **`ManuscriptStore`** — the one open manuscript: content, data, journals,
  versions, settings. All mutations funnel through a private `touch(_ ref:_:)`
  that edits the manuscript backing a `VersionRef` (Source or a version's
  snapshot), stamps `updatedAt`, and saves. Public mutators take
  `ref: VersionRef = .source`, so the same array logic edits whichever version a
  pane represents.
- **`AppStore`** — global, cross-manuscript: `backends`, `aiServices`, `views`
  (including auto-generated journal views). Persisted to `app.json`.

Both are created in `ManuscriptEditorApp` and injected with `.environment`, read
via `@Environment(ManuscriptStore.self)` / `@Environment(AppStore.self)`.

## Persistence & file layout

A manuscript is a **folder the user chooses** (NSOpenPanel) on first creation. The
app keeps a **security-scoped bookmark** (`folderBookmark`) to retain write access
across launches (sandbox-compliant).

```
{chosen folder}/
  manuscript.json        ← the whole Manuscript, JSON (pretty, ISO-8601 dates)
  figures/
    {figureID}.{ext}     ← imported figure images
  data/
    {assetID}.sqlite     ← imported CSVs as SQLite (table "data")
    {assetID}.{ext}      ← imported images
```

Fallback when no folder is chosen: `~/Library/Application Support/ManuscriptEditor/
manuscripts/{id}/`. The UUID→folder mapping and known-manuscript index live in
`UserDefaults`. `app.json` (global store) lives in the App Support root.

**Backward compatibility:** `Manuscript.init(from:)` uses `decodeIfPresent` for
fields added over time. Newer fields (e.g. `RichText`, `versions`) must always
decode from older files. Note: once a build writes RTF/`versions`, older builds
can't read those files (forward-incompatible) — that's accepted.

## Services (stateless helpers)

- **`PersistenceService`** — folder resolution, security-scoped bookmarks,
  atomic JSON save/load, figure import, `data/` directory.
- **`DataService`** — CSV parse (RFC-4180), CSV→SQLite import, SQL execution
  (read-only) returning `QueryResult{columns, rows, error}`, image import.
- **`ChecklistService`** — runs deterministic requirement checks
  (`ChecklistResult{rule, passed, details}`) for the active view/journal.
- **`WordCountService`** — `count` and `countStripped` (Markdown-aware).
- **`JournalPresets`** — shipped journal definitions (name, publisher,
  requirements) seeding the Add-Version picker.
- **`ExportService`** — assembles a version's content through the active profile's
  outline into `NSAttributedString` document(s) and writes the submission package
  (DOCX/RTF/HTML/plain via `NSAttributedString.data(from:documentAttributes:)`;
  copies figure images into the package). Dependency-free.
- **`ZoteroService`** (Phase II) — talks to a locally-running Zotero over its local
  HTTP API (`http://localhost:23119`) to browse/import references. Requires the
  `com.apple.security.network.client` entitlement; degrades gracefully when Zotero
  is not running.

## AppKit interop: the rich text editor

Prose (`abstract`, section `content`, letter `body`) is `RichText` (plain + RTF)
edited by `RichEditor` → `RichTextRepresentable` wrapping `NSTextView`.
**Critical:** build an explicit **TextKit 1** stack (`NSTextStorage` →
`NSLayoutManager` → `NSTextContainer`, then `NSTextView(frame:textContainer:)`).
A default `NSTextView` on macOS 26 is TextKit 2, whose TextKit-1 `layoutManager`
is `nil`, which silently breaks the line-number gutter. See
[`08-engineering-standards.md`](08-engineering-standards.md#known-platform-gotchas).

## Undo (two tiers, split by entry lifetime)

The rule: an undo entry may only reference things that outlive it.

- **Document tier** — `ManuscriptStore.touch()` snapshots the pre-mutation
  `Manuscript` (a COW value type, so snapshots cost only the delta) and
  registers a restore with the key window's undo manager
  (`store.activeUndoManager`, wired in `ContentView`). Entries target the
  store, never a view. This makes structural/destructive operations —
  deleted sections, figures, tables, references, journals, deactivation —
  undoable via ⌘Z, with named Edit-menu entries. Per-keystroke draft commits
  coalesce (~1.5 s window); rich-editor content commits register nothing
  (`undoable: false`) because their undo lives in the editor tier. History
  resets whenever `manuscript` is replaced wholesale (open/new/close), and
  `restoreSnapshot` refuses cross-manuscript-id restores. Undo never performs
  external effects (no network); a restored journal's remote branch is simply
  recreated on the next remote save.
- **Editor tier** — every text surface (`RichTextRepresentable`,
  `PlainTextEditor`) owns a scoped `UndoManager` via `undoManager(for:)`,
  cleared on dismantle and on programmatic reloads. Typing undo dies with its
  view — that containment is what fixed the issue-#8 ⌘Z crash. AppKit
  coalesces an unbroken typing run into one undo entry, so both editors call
  `breakUndoCoalescing()` after a ~1 s pause — each typing burst is its own
  ⌘Z step instead of "undo everything I wrote". Never use raw
  SwiftUI `TextEditor` (gotcha #10 in
  [`08-engineering-standards.md`](08-engineering-standards.md#known-platform-gotchas)).

## Phase boundaries

Build **Phase I and Phase II**; stub **Phase III**. Full detail in
[`09-roadmap.md`](09-roadmap.md).

- **Phase I (individual + manual, incl. export):** local authoring, data
  repository + SQL, journals (requirements + views), per-journal versioning,
  lineage + manual sync/rollback, side-by-side editing, checks, notes, **export &
  rendering (DOCX/PDF/LaTeX)**, theming, rich text. No cloud, no AI.
- **Phase II (automation):** AI-driven cut generation/derivation/revision
  (+ Keychain for keys); **cloud backend save-and-share** (push on Save / Save new
  version; fetch/restore) — *not* live collaboration.
- **Phase III (stub only):** automated submission/publishing; active multi-user
  collaboration + concurrency. Stub honestly with disabled controls.
