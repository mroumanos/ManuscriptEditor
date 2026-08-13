# 05 — Features & Acceptance Criteria

Each feature lists the intent and concrete, checkable acceptance criteria. "AC"
items are the bar for "done."

## A. Manuscript lifecycle & storage

Intent: a manuscript is a folder the user owns.
- AC: New manuscript prompts a folder picker; `manuscript.json`, `figures/`,
  `data/` are created in the chosen folder.
- AC: Access persists across launches via security-scoped bookmark.
- AC: Window title shows the manuscript name at all times.
- AC: Older saved manuscripts still open (backward-compatible decoding).
- AC: **Overview is the manuscript dashboard**: source statistics (words,
  sections, figures, tables, references) **plus one row per journal cut** —
  head version, its content's word/asset counts, and its live checks verdict
  (`12/14` with the pass/attention color).

## B. Source content authoring

Intent: most time is spent here; it must be excellent and AI-optional.
- Components: Authors, Abstract, Keywords, body Sections (add/reorder/rename/
  delete; custom types allowed), Figures, Tables, Bibliography, Letter to Editor.
- AC: **Authors + institution registry.** "Add Institution" sits next to
  "Add Author" (same pane); institutions are named inline and authors
  affiliate by checking registry references in the editor — **required**:
  an author with no institution reference is flagged (orange warning in the
  row and editor). Deleting an institution strips its references. Authors
  **drag-to-reorder** (offsets applied against the sorted list). Exports
  resolve affiliation lines from the registry (legacy free-text still
  honored).
- AC: Each list view (Authors/Figures/Tables/Bibliography/Data) auto-selects the
  first item; an empty state offers a centered "Add …" action (no broken
  half-empty split).
- AC: Each added item has a clear inline delete affordance.
- AC: Prose editors are rich text (see §G). Word counts update live.
- AC: Letter to Editor has a three-slot letterhead (left / center / right —
  each an optional uploaded image plus freeform text, laid out like a real
  letterhead in editor, preview, and exports), body, and a **drawn-only
  signature** (drawable pad with Reset — no typed signature box), with a
  preview toggle. Slot images accept PNG/JPEG/TIFF/HEIC/**SVG** (SVG bytes
  are kept as vectors).
- AC: The letter body's "/" offers **Date** and **Signature** as live
  **references** — ⟦Date⟧/⟦Signature⟧ marker tokens (letter:// links in the
  editor) that resolve in preview and every export: today's date at render
  time, and the drawn signature image. With no ⟦Signature⟧ placed, the
  drawing still closes the letter; LaTeX resolves the date and drops the
  signature marker (source-only output).
- AC: **Title pane** — first item in Content; edits the journal-facing
  **article title** (+ running title) per cut, so it can differ journal to
  journal. Exports print it, falling back to the **project name**
  (`Manuscript.title`), which names the folder/Welcome entry.
- AC: **The app always launches on the Welcome screen** (the project
  manager) — nothing auto-opens. Rows open on **double-click or the pencil
  button**; the orange **⊖ removes the entry from recent memory** (files
  stay); the red **trash deletes** (folder → Trash, confirmed); right-click
  adds Rename…/Reveal in Finder. **File → Manage Manuscripts…** saves +
  closes the current manuscript and returns to Welcome — so the project
  you're loaded on can never be trashed.
- AC: The fixed Figures/Tables/Bibliography/Letter panes support right-click
  **Rename…** and **Remove from Sidebar** (restore from the dimmed "Show …"
  rows at the bottom of the Content list).
- AC: **Custom sections with per-journal activation.** Add sections from an
  inline "＋ Add Section" row at the **bottom of the section list** (not a toolbar
  button); titles are kept **unique**. A new section is **created for every
  journal** (shared structure). Each journal can **deactivate** a section it
  doesn't use via the eye toggle in that section's pane header — deactivated ⇒
  **uneditable and excluded from Checks and Export, with content preserved**
  (e.g. keep a Disclosure section active only for NEJM); reactivating restores
  the text exactly as it was. Renaming, reordering, and deleting
  apply everywhere; content is per-journal. A section absent from an older cut
  shows a clean "Not included in this version" state (no broken rendering).

## C. Data repository + SQL binding

Intent: data lives once; figures/tables reference it; cuts convert only SQL.
- AC: Import CSV → stored as SQLite in `data/`; import images → copied to `data/`.
- AC: A CSV asset has a SQL editor; results show in a grid; errors show inline.
- AC: **Result grids use the native SwiftUI `Table`** (shared `QueryResultTable`
  component): resizable columns, alternating rows, single-line truncation with
  the full value on hover — never a hand-rolled per-cell-border grid. Results
  cap at 500 rendered rows with an honest "showing first N" footer.
- AC: Figures can reference a CSV (chart: line/bar/histogram via SQL) **or** an
  image; tables can reference a CSV (SQL → table). Reference = `dataAssetID` + SQL.
- AC: **Data-linked figures render live in the figure editor**: the chart
  (bar/line, or a real binned histogram) redraws as the SQL or chart type
  changes (SQL debounced ~0.4 s). Column mapping: first SELECT column = X,
  second = Y.
- AC: **Data-linked tables preview live**: when a table has a data source, the
  editor's content pane shows the query's result grid (same component as Data)
  instead of the Markdown editor, updating as the SQL changes.
- AC: **Figure image adjustments are non-destructive**: crop, resize (10–100%),
  and **black & white** each apply to the figure's rendering (previews,
  thumbnails, export) only — the original image in Data never changes.
- AC: Changing journals/cuts never alters underlying data — only the SQL/format.
- AC: Each data asset has a delete affordance.

## D. Journals, views, and requirements

Intent: a journal is what you adapt *for*; it bundles content **requirements** and
an output-format **view** (both required). The Source is the root journal.
- AC: Add a journal from a **preset** (supplies requirements + view) or custom.
  Every journal has `JournalRequirements` **and** a `ViewConfig`.
- AC: The **Source** journal exists from creation with **default (empty)
  requirements** and a **default view**.
- AC: A journal's default view is derived from its requirements
  (`ViewConfig.from(requirements:)`): sections, export format, separate-figures
  doc. Users can also create/manage **custom views** (Preferences → Views).
- AC: **View = output format only** (documents, per-section title/font/spacing,
  line numbering, export format). It is NOT content requirements and NOT the
  user's global editor preferences. Keep these three separate everywhere.
- AC: Target journals carry submission config; Source does not submit.

### D2. Submission profiles (article types)

Intent: one journal accepts different **article types** (Original Article, Review,
Case Report, …), each with its own rules and layout.
- AC: A journal has **one or more submission profiles**. A profile bundles, for a
  named article type: its **checks** (`JournalRequirements`) **and** its **export
  outline** (a view — sections, order, per-section format; see M). Checks and
  export travel together per profile.
- AC: A journal may include a **Custom** profile the user defines.
- AC: The active profile is selectable per version; Checks and Export both use the
  **active profile** so what's verified matches what's exported.
- MODEL: `Journal.profiles: [SubmissionProfile]` where
  `SubmissionProfile { articleType, requirements, outlineViewConfigID }`. This
  supersedes the single requirements + view per journal and ties into the pending
  migration (see [`09-roadmap.md`](09-roadmap.md)). The Source journal has one
  default profile with empty requirements + a default outline.

## E. Versioning (stamping — Source and journals alike)

Intent: every journal **and the Source** has its own save-point history; the
working state is always "latest", and **stamping** freezes it as a numbered
version.
- AC: The Versions pane is per-tab and renders a **horizontal table**, newest
  first: Version ("latest" for the working row — never a number) · Stamped
  (date/time) · From → To · By (signer, with the signature badge).
- AC: **Stamp Version** freezes the current content as `vN` and moves "latest"
  to a new row; disabled when nothing changed since the last stamp. Stamps are
  signed with the user's identity key (`stampedByKey`/`stampSignature`).
- AC: **Roll Back…** on a selected prior version restores it and **drops the
  versions after it** (confirmed with the concrete count; refused with an
  explanation when another journal's cut hangs from a dropped version).
- AC: **Source stamps** (`sourceStamp == true`) chain the live manuscript:
  rolling Source back restores content fields from the stamp and keeps
  journals/notes/data intact.
- AC: When a journal has unsaved edits, show a prominent **unsaved-changes
  banner** that triggers Save when clicked.

## F. Lineage, cuts, sync & rollback

Intent: derivation is tracked as edges between journal *versions*; updates
propagate by explicit, individual fast-forwards.
- AC: The **Journals** panel shows a lineage tree rooted at **Source** (unlimited
  depth).
- AC: Creating a journal from a parent journal's current version makes the child
  at `v1` and an edge `parent@vX → child@v1`.
- AC: Editing a parent forward (new versions) does **not** alter existing edges.
- AC: **Sync** re-derives one child from its parent's newest **stamped**
  version. Every edge A→B is **checksum-verified** first (SHA-256 over the
  content with volatile metadata zeroed): identical A/B latest contents
  short-circuit to a green "already in sync" banner (no version churn), and
  an upstream whose latest differs from its own last stamp **refuses to
  sync** with a red banner directing the user to stamp A in its Versions tab
  first — lineage edges always hang from frozen versions. **Never recursive.**
- AC: Journal rows show **"Last synced X · Last edited Y"** (Source: last
  edited only) instead of persistent "up to date" badges; the blue "upstream
  has moved — fast-forward available" hint remains. The lineage renders as
  **one connected container** — children as indented, same-height rows under
  their parent (dropdown style), each prefixed with **curved branch arrows
  (↳), one per nesting level** — and each journal shows its **icon** (an SF
  Symbol configured in the app-settings Journals library; "?" when unset).
- AC: **Title-bar chrome.** The center of the window toolbar is a reusable
  **notification banner** slot (`ManuscriptStore.showBanner` — green success
  / red failure, auto-dismissing): all sync messages, save confirmations,
  and remote push/pull results surface there (no inline banners in the Sync
  pane; no blocking remote-error alert). The top-right shows the **save
  status**: last local save time and last remote push ("N/A" when no backend
  is configured). **Save (Local)** always writes to disk and banners;
  **Save (Remote)** banners its async result.
  Example: `Source@v2 → NEJM@v1`; Source edited to `v3`; Sync NEJM ⇒ `NEJM@v2` and
  edge `Source@v3 → NEJM@v2`.
- AC: **Rollback** restores the prior edge and **soft-archives** the newer
  versions it produced (hidden but recoverable — not hard-deleted). Example:
  `Source@v3 → NEJM@v2` with prior `Source@v2 → NEJM@v1` ⇒ rollback re-activates
  `Source@v2 → NEJM@v1` and archives `Source@v3`, `NEJM@v2`.
- AC: **Phase I** — cut/sync creates the journal version and lineage edge and
  **seeds the child from the parent snapshot**; the user reconciles content
  **manually**. **Phase II** — the configured **AI service** auto-derives the
  child content toward the child's requirements.
- AC (implemented): **Sync pane** — under the Manuscript section — carries the
  three flow functions: **Saving** (Save Local / Save Remote / Load from
  Remote with last-saved/last-synced timestamps), **Syncing** (plain per-edge Sync buttons — checksum-prechecked as above,
  and the confirmation states whether a connected AI may modify the copy —
  on a **contiguous** nested lineage tree — child
  cards attached beneath their upstream, tabbed left, right edges aligned),
  and **Add Journal** (from = Source or any journal; to = a profile from the
  global journal library or a custom name; creates v1 "Created" + the edge,
  and the journal's tab appears automatically). Syncing shows a
  **warning dialog** ("overwrites what currently exists in the journal's
  working head; previous versions remain in history") before creating the new
  version + edge via `ManuscriptStore.syncJournal`.
  Because syncs are one edge and never recursive, the status must not
  overstate freshness for chains through another journal: when the upstream
  journal is itself behind *its* upstream, the card warns "sync it first"
  (orange) instead of a green "up to date"; when up to date through a journal
  whose root is the live Source, the card dates the content the upstream
  carries and the warning dialog names the exact snapshot that will be copied
  ("Nature does not pull from Source directly — sync NEJM first, then
  Nature").
- AC (implemented): **Versions pane is per-tab** — like Checks, it renders one
  pane per open comparison tab, each scoped to **that tab's journal** with no
  journal dropdown (the Source tab's pane covers custom cuts and explains that
  Source itself is always live). Each pane shows the journal's **linear**
  history (v1 → v2 …, newest = working head, leaf-only delete) and the
  **entire lineage diagram** — Source root plus every journal's chain, with
  the pane's journal **highlighted** and arrows connecting the exact versions
  (`LineageDiagram`, modeled on examples/lineage-detailed.png) — plus the
  selected version's details. Version numbers in these views are **per-journal
  ordinals** (`journalOrdinal`). The Versions pane no longer embeds
  requirements/checklists — the live checklist lives in **Checks** (§J);
  requirements editing lives in the Journals settings.
- NOTE: Two open design questions remain in [`02-domain-model.md`](02-domain-model.md)
  (multi-edge endpoints on one version; which version the tabs show by default) —
  resolve before implementing, don't guess.

### Lineage visualization (two views)

**Compressed view** — the default tree. Each journal node shows its **current
version** (e.g. NEJM v2, PLOS v1, Nature v1); the edge into it is labeled with the
**parent version** it derived from (Source v2, v3, …). The Source node needs no
version label because the edges carry it. A **sync icon** on an edge means a
fast-forward is available (the parent has advanced past the edge).

![Compressed lineage with sync indicators](examples/lineage-management.png)

![Compressed lineage tree](examples/lineage-compressed.png)

**Detailed view** — opened by clicking an edge between two journals; shows the
**historical and most-recent edges** between just those two journals (e.g.
`Source v1→NEJM v1`, then `Source v2→NEJM v2`), so the derivation history is
legible.

![Detailed lineage between two journals](examples/lineage-detailed.png)

## G. Side-by-side comparison & editing

Intent: compare/edit journals together.
- AC: Tabs **load automatically** (Source + every journal; identity = the
  journal, resolving to its working head) and are never opened/closed by hand.
  Chips are **browser-style** (icon + name, shown tabs highlighted lighter
  with an accent underline; no color coding).
- AC: An **Active | Compare** toggle governs the panes. Active = one journal,
  switched by clicking chips or **⌘⇧←/→**; Compare = chips gain ＋/✕ to
  include/remove panes, side-by-side split evenly by default.
- AC: Selecting a comparable item renders one **editable** pane per displayed
  tab; sidebar navigation moves all panes together. **Checks, Versions, and
  Export are comparable the same way** — one pane per tab, no journal
  dropdowns.
- AC: **Pane headers are slim**: word count, per-journal section activation
  (eye), and notes only. The selected item's name is NOT repeated in the pane —
  the sidebar selection already names it (body sections rename via the
  sidebar's context menu). Which journal a pane shows is carried by the tab
  chips above, in the same left-to-right order.
- AC: Editing a pane writes to that journal's working content, not other journals.
- AC: With zero tabs open, the Content section disappears and selection falls back
  to Overview.

## H. Notes & feedback (first-class)

Intent: leave feedback for oneself or collaborators, anchored to content.
- AC: A note can be attached to a content element (figure, table, author,
  section, …) via a "notes" affordance, or to a **highlighted text range** in
  prose. Selecting text shows a small action popover (edit / **add comment** /
  react); choosing add-comment anchors a note to that range.
- AC: Notes show author + timestamp and can be marked resolved, displayed in a
  panel beside the content.
- AC: Notes are visible while comparing journals side-by-side.

![Highlight selection → add-comment popover](examples/text-highlight-add-notes.png)
![Note anchored to a highlight, with author + timestamp](examples/text-highlight-with-notes.png)

## I. Rich text editing

Intent: clean, modern, capable prose editing.
- AC: Editor backed by `NSTextView` (TextKit 1) storing `RichText` (plain + RTF).
- AC: **Inline toolbar** (not a popover) at the top: bold, italic, underline,
  strikethrough, superscript, subscript | align left/center/right/justify |
  bulleted list. Aligned to the text column.
- AC: **Paste strips source formatting.** The editor keeps one base style
  (final typography is chosen per export outline); ⌘V re-sets pasted text in
  the editor's default format, preserving only inline emphasis (bold, italic,
  underline, strikethrough, super/subscript), reference tokens when pasting
  from another section, and dropping images/attachments.
- AC: **Line-number gutter** numbering visual (wrapped) lines, vertically aligned
  to each line, reflowing when wrap width changes.
- AC: **Width ruler** with a draggable handle setting the wrap column (page-like
  layout); persisted (`editorWrapWidth`).
- AC: Typography (font family/size/line-spacing) is user-configurable and shared
  across editors.
- AC: **Undo is two-tier** (details in
  [`03-architecture.md`](03-architecture.md#undo-two-tiers-split-by-entry-lifetime)).
  Typing undo is scoped to each text surface. **Document undo** covers model
  mutations: an accidentally deleted section, figure, table, reference, or
  journal — and a deactivation — is recovered with ⌘Z, with a named Edit-menu
  entry ("Undo Delete Table"), for at least 50 steps within the session.
  Undo never performs network operations.
- Visual references (the formatting bar shown is the longer-term target — see
  [`06-design-system.md`](06-design-system.md#visual-references) for which controls
  are Phase I vs later):

  ![Formatting bar target](examples/text-editing-bar.png)
  ![Width ruler](examples/text-width-ruler.png)
  ![Line numbering](examples/line-numbering.png)

## J. Checks (live, per-journal, comparable)

> **Implemented shape:** the Checks pane is the live submission checklist
> (green ✓ / red ✗ with a summary banner) **plus** the journal's requirement
> editing (Edit Requirements… sheet: limits + custom rules) and **Save to
> Journal Library…** (store the profile — requirements + export outline — as
> a reusable global entry, new or overwriting). A journal pane checks its own
> journal; the Source pane shows an explanatory state — no journal picker.

Intent: deterministic requirement verification that is **always current** and
viewable **side-by-side per journal**, like any Content item.
- AC: Checks evaluates a journal's content against **that journal's**
  `JournalRequirements` (word/abstract limits, required sections present &
  non-empty, figure/table/reference counts, custom rules) and renders a pass/fail
  checklist with a ready/attention summary.
- AC: **Live.** Results recompute immediately as content changes — edit a journal
  over its word count and that check flips to a red ✗ without any manual refresh;
  bring it back under and it returns to a green ✓.
- AC: **Comparable.** With multiple journal tabs open and **Checks** selected, the
  detail shows one checklist pane per open journal (e.g. Source ✓ all green, NEJM
  ✗ over word count), each evaluated against its own journal's requirements and
  content. Selectable and navigable exactly like the Abstract page.
- AC: Checks are **derived, not stored** — computed on demand from content +
  requirements (so they can never go stale).
- Implementation note: because content edits flow through the store and the
  stores are `@Observable`, a checks pane that reads `ChecklistService.run(...)`
  in its `body` recomputes automatically on every edit. Keep it that way.

## K. Global integrations (account-free)

Intent: a **backend** (cloud storage) and an **AI service** (LLM) are different
things; neither is needed for Phase I (manual, local) editing.
- AC: **Preferences → Accounts** manages every external account in one panel —
  storage (GitHub, GitLab, Office 365, …) and AI (Claude, OpenAI, Gemini,
  Ollama). Credentials live in the **Keychain**; every account offers **Test
  Connection** (GitHub/GitLab `/user`, Anthropic/OpenAI `/models`, local
  Ollama). One storage account is the manuscript's "active" backend
  (Manuscript → Backend). **Phase II** = save-and-share. **Active
  collaboration/concurrency is Phase III (stub only).**
- AC: The remote repository binding is **per-manuscript**
  (`ManuscriptSettings.remoteRepository`/`remoteBranch`): Manuscript → Backend
  shows the local folder, lets a local-first manuscript **create** its (private)
  repository on the active account — linking to it once created — and shows
  last-synced.
- AC: **File → New Manuscript (File)… / (Remote)…** — both warn about the
  current manuscript's unsynced work first. Remote asks for account + repository
  link; a repository that already holds a manuscript is pulled, an empty one
  receives the fresh manuscript; a local copy always exists.
- AC: Saving lives under **File**: Save (Local) ⌘S and Save (Remote) ⇧⌘S (mirrored in the
  Sync pane). Loading an existing remote manuscript IS New Manuscript
  (Remote)… — there is no separate Load command.
- AC (implemented — GitHub first): **Save to Remote / Load from Remote**
  (Manuscript menu; ⇧⌘S for save). A GitHub backend account carries a
  repository ("owner/name") + branch (default `main`); its **personal access
  token lives in the Keychain** (`KeychainService`, keyed by account id) —
  never in app.json. *Save* pushes the manuscript folder (manuscript.json,
  figures/, data/) as **one commit** via the Git Data API on top of the branch
  head, leaving unrelated repo files (README, LICENSE) untouched; *Load* pulls
  those managed paths back after a **destructive-action confirmation**,
  replacing local content but keeping the local manuscript id/folder mapping.
  Success shows quietly in the sidebar subtitle; failures alert with an
  actionable message (bad token / missing repo / unconfigured backend). Other
  providers remain honest stubs.
- AC: Preferences → AI: add/remove Claude/ChatGPT/Gemini/Ollama services used for
  content **adaptation/revision** (**Phase II**; needs Keychain for keys). In
  Phase I, cuts are created and edited **manually** without any AI. Never conflate
  AI with the storage backend.

## L. Theming & professionalism

Intent: the product must look professional.
- AC: System/Light/Dark applies app-wide (main + Preferences windows).
- AC: Lists are left-aligned and fill their pane (no floating "glass" cards, no
  centered shrunken content); detail fills available space.
- AC: Spacing, color, and typography follow [`06-design-system.md`](06-design-system.md).

## M. Export — the submission package (Phase I — build now)

Intent: for a given journal (and active **profile**/article type), **export
produces everything needed to submit online** — correctly formatted, in the right
document types, laid out to the journal's outline. It is a complete package, not
just a rendered blob.
- AC: Export targets a **version** (Source or a cut) using its journal's **active
  profile** — the profile's **export outline** decides *what sections go in what
  order and in what format*, across **all components** (title, authors, abstract,
  keywords, body sections, journal-specific sections, figures, tables,
  bibliography, letter to editor), not just body sections.
- AC (implemented): **Per-journal export outline, editable visually.** Every
  journal (and Source) has a pre-configured `ExportConfig` shown in the Export
  pane as a **stacked list of document cards**. The user can add/remove
  documents, add components (title block, abstract, keywords, body sections by
  name, figures, tables, references, cover letter) and **page breaks** inside a
  document, **drag items to reorder** (three-line grab handle per row). The
  card header holds the **file type** and the page geometry (**margins**,
  **single vs two-column (IEEE-style)**) — all typography lives in the per-item
  columns (no document-level format row). The outline persists on the journal
  (`Journal.exportConfig` / `Manuscript.sourceExportConfig`) once edited; until
  then the standard outline is derived live (the pane snapshots it into state
  so ids stay stable while editing).
- AC (implemented): **Per-item overrides, shown as columns.** The item list has
  aligned columns — **Font · Size · Spacing · Lines** — with inline controls on
  every row showing the item's *effective* format; changing any value creates
  that item's override (`ExportItem.format`; right-click → "Reset Formatting to
  Document"). Click the **item name to rename its exported heading**
  (export-level `customTitle`; empty reverts). Each row's **"H" toggle
  shows/hides the printed heading** (`ExportItem.showTitle`; content always
  exports — only the title toggles). Default: every kind prints its heading
  **except the cover letter**, which exports as a real letter with no
  "Cover Letter" label (Jul 2026 beta feedback). Margins/columns remain
  document-level (page geometry). PDF line numbering follows the per-item
  effective format (attribute-driven); LaTeX emits
  `\linenumbers`/`\nolinenumbers` transitions.
- AC (implemented): **Headings in output** get a blank line before and after,
  and are **capitalized by default** (first letter; applies to renamed/custom
  titles too, in attributed output and LaTeX alike).
- AC (implemented): **Document types.** **PDF** (custom dependency-free CoreText
  paginator honoring margins, page breaks, columns, and continuous line
  numbers), **DOCX**, **RTF** (attributed writers with margins; page breaks as
  form feeds), and **LaTeX** source (`article` class; `twocolumn`, `geometry`
  margins, `setspace`, `lineno`; body as escaped plain text in v1). HTML/plain
  remain in the legacy ⌘E sheet.
- AC: **Package, not one file.** Export writes a folder containing every
  outline document; figure image files are copied in whenever a document
  includes the figures block, so the package is self-contained.
- AC: Figures/tables render from their data binding (source + SQL) or uploaded
  image. The PDF paginator draws **NSTextAttachment images itself** (CoreText
  ignores attachments — CTRunDelegates reserve their bounds and a post-frame
  pass paints them at 3×), so charts/letterheads/signatures appear in PDF.
- AC: **Tables export as real tables** — boundaries that wrap the contained
  values. PDF gets a measured **drawn grid** (wrapped cells, page-height-aware
  chunks with the header repeated); DOCX/RTF get a native **NSTextTable**.
  Sources: the SQL result for data-linked tables, else parsed Markdown pipe
  rows. Per-table formatting (Tables editor → Export Formatting): **open
  sides** (horizontal rules only, journal style) vs a fully boxed grid, and
  **alternate row shading**; `footnotes` print as a "Note." paragraph beneath.
- AC: Export uses the journal's **working head** (its latest version; Source
  exports the live manuscript). The user picks the destination folder; on
  completion, reveal the package in Finder.
- IMPLEMENTATION: `ExportService.exportPackage(config:…)` assembles attributed
  segments per document via `OutlineBuilder` (re-setting prose in the document
  font while preserving bold/italic, re-rendering citation tokens via
  `RefEngine`), paginates PDF with `PDFPaginator`, and emits LaTeX directly. No
  third-party dependencies.
- Follow-ups: submission profiles (multiple outlines per journal by article
  type); styled LaTeX body; true DOCX section breaks/columns.

## N. Publishing & submission (Phase III — stub only)

- Submit via the journal's web interface where possible, with submission status
  tracking; manual, editable status otherwise. Journals with no integration stay
  "None" with an editable manual status. **Stub honestly** (disabled controls)
  until Phase III.

## O. Bibliography — Zotero connector

Intent: manage the bibliography from the user's **locally-running Zotero** rather
than re-entering references by hand.
- AC: Preferences → Backend/Integrations (or Bibliography) can connect to a local
  Zotero over its **local HTTP API** (`http://localhost:23119`) — no account, no
  cloud round-trip. Requires the app's `com.apple.security.network.client`
  entitlement.
- AC: Browse/search the local Zotero library and **import selected references** as
  `BibEntry`s; optionally keep them linked (by Zotero item key) so they can be
  re-synced.
- AC: Insert citations that reference imported entries; the journal's citation
  style governs rendering (Phase II for full CSL styling).
- AC: Degrade gracefully when Zotero isn't running (clear, non-blocking message).
- PHASE: This is an external **integration → Phase II** per the phasing, but is a
  high priority within it. Implement behind the same "bring-your-own service"
  model as other integrations; never block Phase I bibliography editing on it.

## P. In-text references (implemented)

Intent: reference bibliography entries, figures, and tables from any prose
editor as **live, formatted, auto-numbered tokens**, and keep the bibliography
ordered by use. `RefEngine` (Services/) is the single home for this logic.

**Trigger & insertion**
- AC: Typing **`/`** at a word boundary in any rich text box (abstract,
  sections, letter) opens the **reference picker panel** (`ReferencePicker`,
  Theme/) under the caret: a **search box on top, focused automatically** —
  typing (spaces included) lands there, not in the prose — over an
  **icon-tagged list** of every referencable thing: bibliography entries
  (books icon; keyless entries appear by title), figures, tables, and a
  **Zotero section** ("z" icon) of library items not yet in the bibliography.
  The search filters across every source's text fields (key, title, authors,
  journal, caption). `/` mid-word ("and/or", DOIs, URLs) does not trigger.
- AC: **↑/↓ navigate** the list without leaving the search box; **Tab,
  Return, or a click accepts** the selected row. Accepting replaces just the
  "/" with the token (figures/tables then offer Reference vs Placement at the
  caret).
- AC: **Accepting a Zotero row cites-while-you-write**: the item is added to
  this version's bibliography (deduped by `zoteroKey`) and cited in place as a
  normal token. Zotero results load async (debounced, cached per query, 30 s
  backoff when Zotero isn't running — the panel silently shows local rows only).
- AC: **Only Escape makes the "/" plain text.** The trigger is the "/"
  *keystroke*, not text state — so a dismissed slash can never re-arm, not
  even by backspacing back to it; it must be retyped. Clicking away also
  closes the panel and leaves the slash as typed.
- AC: Accepting (Return/Tab, or click) inserts a **formatted token** —
  default **`[1]`** numeric for citations, "Figure 2"/"Table 1" for
  cross-references — **in the editor's default format (no bolding, italics, or
  font change)**; the token's identity lives in its link attribute
  (`cite://<id>?f=<style>`, `figref://<id>`, `tabref://<id>`), not in styling.
  The list does not preview into the text while arrowing; dismissing leaves
  exactly what was typed.
- AC: **Hovering a token** shows a details card after ~0.25s: key + "cited as
  [n]" and the full reference (or figure/table title + caption). The `.toolTip`
  attribute remains as fallback.
- AC: **Clicking a token** opens a menu headed by those same details, then (for
  citations) a "Citation Format" section and Remove.

**Citation styles** (click a token → menu; per-token choice, persisted in the
link URL)
- `[1]` numeric, bracketed — IEEE / Vancouver (default)
- `(1)` numeric, parenthesized — Vancouver variant
- `¹` superscript numeric (Unicode digits) — AMA / Nature / NEJM
- `(Smith et al., 2024)` author–year parenthetical — APA / Harvard / Chicago
- `Smith et al. (2024)` narrative — APA narrative
- Menu also offers **Remove Citation/Reference** (deletes the token text).

**Automatic numbering & ordering**
- AC: Numbers are assigned by **first appearance in document order** (abstract
  → active sections → letter); re-citing an entry **reuses its number**.
  Reordering text (e.g. swapping paragraphs) **renumbers tokens automatically**
  in every open pane, and stale closed-editor text is corrected on open and on
  export.
- AC: The **bibliography array auto-orders** to match: cited entries first, in
  citation order; uncited after, keeping their manual drag order (dragging a
  cited entry snaps back). The manual "Order" button is gone — ordering is an
  invariant, enforced on every store mutation.
- AC: Figure/table tokens re-render when the target's number changes; deleted
  targets render as **`[?]`** so a stale number never poses as live.
- AC: **Figure/table numbering follows reference order**, exactly like
  citations: the first-referenced figure is "Figure 1"; unreferenced figures
  follow after in manual order. Lists, exports, and package file names all use
  these effective numbers.
- AC: **Placement tokens** — the `/` dropdown also offers "Place Figure N here"
  / "Place Table N here". They render as a faint `⟦Figure 2 here⟧` marker in
  the editor (invisible would be undeletable) and expand to the full rendered
  figure (crop/scale/B&W applied) or table + numbered caption at that exact
  spot in exported documents. Placements do not affect reference numbering.
- Mechanism: each `RichText` persists `refs` (ordered token list, extracted by
  the editor on change; back-filled from RTF once for older files), so
  numbering/ordering never decode RTF on the keystroke path. Editors skip the
  rewrite pass unless the rendering context's signature changed.

**Bibliography annotations**
- AC: Cited entries show a blue **`[n]` number badge** and a green quote badge
  with the citation count in the list; the entry details include a **"Cited
  In"** section listing each prose field (Abstract, section title, Letter to
  Editor) with per-field counts — no extra list column.

**Export**
- AC: Export re-renders every token against final numbering, strips the in-app
  link/tooltip/bold chrome, and prints the references list in citation order so
  printed numbers match in-text tokens.
- Known limits (v1): no grouped ranges (`[1–3]` renders as separate tokens);
  letter-to-editor citations share the manuscript numbering; legacy `{Key}`
  tokens from the previous scheme upgrade to `[n]` automatically on open.
