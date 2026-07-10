# 09 — Roadmap & Current Status

## Phasing

**Scope to build now: Phase I and Phase II. Phase III is stubbed only.**

### Phase I — Individual & manual editing, end to end (incl. export)
Everything one person needs to produce and ship a manuscript edition **manually**,
with **no cloud and no AI**. This includes export/rendering.
- Folder-based manuscript storage; account-free.
- Full content (authors, abstract, keywords, sections, figures, tables,
  bibliography, letter to editor) with rich text editing.
- Central **Data** repository: CSV→SQLite, images, SQL-bound figures/tables/charts.
- **Journals** (root Source + targets), each with required **requirements** + a
  **view**; user-created views.
- **Versioning** per journal (Save / Save new version / roll back-forward);
  **lineage** edges; **sync/rollback** performed **manually** (the structure and
  edges exist; content reconciliation is by hand — no AI yet).
- **Side-by-side** comparison and editing across journals.
- **Checks** against the journal's requirements.
- **Notes & feedback** anchored to content.
- **Export & rendering** through a view to DOCX/PDF/LaTeX (LaTeX is an export
  backend; the frontend stays non-technical). *This is Phase I, not later.*
- Theming (system/light/dark) and a professional UI.

### Phase II — Automation: AI + cloud sharing
Do the same work individually but more automatically.
- **AI integrations** (requires a configured AI service + **Keychain** for keys):
  AI-driven cut generation and sync content derivation (adapt parent → child
  toward requirements), and opt-in AI revision while editing.
- **Cloud backend for sharing (not live collaboration)**: on every **Save** and
  **Save new version**, push the project to the configured backend
  (GitHub/Office365/Dropbox/Google Docs/GitLab); fetch/restore from it. This is
  store-and-share only — **no concurrent multi-user editing** here.
- Optional plugins: **Zotero** for references.

### Phase III — Submissions & collaboration (STUB ONLY for now)
- **Automated submission/publishing** via the journal's web interface, with
  trackable status; manual, editable status otherwise (journals left as "None").
- **Active collaboration**: real-time/concurrent multi-user editing and conflict
  handling over a backend.

Phase III features are **stubbed honestly** — visible, disabled controls with a
clear "coming later" affordance — never faked.

## Current build status (update as it changes)

Implemented so far (Phase I):
- Folder picker + security-scoped bookmark storage; backward-compatible decoding.
- Source content editors; rich text (`RichText`/RTF) via TextKit-1 `NSTextView`
  with inline formatting toolbar, line-number gutter, draggable width ruler.
- Data repository (CSV→SQLite, images), SQL execution, chart/table data binding.
- Journals + `JournalRequirements`; `ViewConfig.from(journal:)` auto-views;
  global custom views.
- `ManuscriptVersion` lineage (`parentID`), Versions panel with tree + Add Version
  (parent + journal/custom-view basis); leaf-only delete.
- Comparison tabs (color-coded, Source closable); side-by-side comparison,
  synced navigation, per-pane editable views with colored title capsules.
- **Live, per-journal comparable Checks**: Checks renders one pane per open
  journal, evaluated against that journal's view + content, updating on every edit.
- **Element-level Notes**: add/resolve/delete notes anchored to a content item
  within a version, via a note-count button in each pane header.
- **Export — submission package** (File → Export Submission Package…, ⌘E):
  `ExportService` writes DOCX/RTF/HTML/plain via `NSAttributedString`, assembling
  title→authors→abstract→keywords→sections→figures/tables→references→cover letter,
  splits a separate figures document when the journal requires it, and copies
  figure images into the package. Dependency-free.
- **Custom sections (shared) with per-journal activation**: add via the inline
  "＋ Add Section" row at the bottom of the section list; unique titles; the
  section is created for every journal; each journal can deactivate it (eye toggle)
  making it empty, uneditable, and excluded from Checks/Export; rename/reorder/
  delete apply everywhere; clean states for deactivated / not-included sections.
- **Add Reference menu** (Manual / From Zotero… / From URL…). Zotero-imported
  references are **read-only** (managed in Zotero, `zoteroKey` linkage); manual and
  URL entries are editable. `ZoteroService` uses the local HTTP API on :23119
  (search, multi-select, dedup, graceful failure); enabled by
  `ENABLE_OUTGOING_NETWORK_CONNECTIONS`.
- **Journal sidebar hub** (above Content): **Checks**, **Export**, **Versions**.
  `ExportView` pane mirrors File → Export (⌘E).
- **Version metadata**: each version shows **v-number, timestamp, author, and
  lineage** in the Versions list and detail (`ManuscriptVersion.number` + `author`,
  backward-compatible).
- **Sections**: shared across journals, unique titles, per-journal deactivate
  toggle, **deletable** (swipe + context menu), added from a "＋ Add Section" row
  at the bottom of Content.
- **In-text references** (`RefEngine`): "/" autocomplete over bibliography /
  figures / tables; formatted, auto-numbered citation tokens with five academic
  styles switchable per token (click menu); automatic renumbering on text
  reorder; bibliography auto-ordered by first citation with number badges and
  per-field "Cited In" details; export re-renders tokens and strips app chrome.
  See [`05-features.md`](05-features.md) §P.
- **Per-journal export outlines** (`ExportConfig` + Export pane): stacked
  document cards (add/remove documents, components, page breaks; reorder), per-
  document format (font/size/spacing/margins/line numbers/columns) and file
  type — **PDF** (CoreText paginator), DOCX, RTF, **LaTeX**. See §M.
- **Per-journal Versions pane**: journal picker, linear history (working head),
  upstream/downstream **lineage diagram** with version-to-version arrows;
  requirements editing moved to Checks. Per-journal version ordinals.
- **Sync pane** (sidebar): per-journal fast-forward of one lineage edge with
  drift status and an overwrite warning dialog (`syncJournal`).
- Window title shows the **manuscript title** (not the app name).
- Preferences (Editor/Backend/Views/AI/Export); theme toggle.

Not yet built:
- **Phase I, still to build:** **submission profiles / article types** (bundle
  checks + export outline; multiple outlines per journal);
  **figure-type** journal-specific sections (text shipped); **rollback**
  (soft-archive) of a sync; styled LaTeX body (bold/italic; v1 exports plain
  text); **prose text-range notes (highlight-to-comment)**; the
  Journal/Version/Lineage migration.
- **Phase II, to build after Phase I:** AI cut generation/derivation/revision;
  cloud backend save-and-share; deeper Zotero (citation styles / re-sync);
  Keychain.
- **Phase III, stub only:** automated submission/publishing; active collaboration.

## Pending model migration (Journal / Version / Lineage)

The clarified model in [`02-domain-model.md`](02-domain-model.md) **supersedes**
the shape currently in code. The code today treats a "cut" as a
`ManuscriptVersion` with a `parentID` tree, and `Manuscript` is the Source
content. The target model is:

- **Journals** are the cuts (Source is the root journal); each has required
  requirements + view (+ submission config for targets).
- **Versioning** is a per-journal save-point history (Save / Save new version /
  roll back-forward).
- **Lineage** is edges between *journal versions*; **Sync** fast-forwards one
  edge; **Rollback** restores a prior edge and deletes the versions it produced.
- Content snapshots live per journal version; Data assets stay central/shared.

This is a **significant data-model + UI refactor** (rename "Versions" → "Journals",
add per-journal version history, lineage edges, sync/rollback, and Notes). It must
preserve backward-compatible decoding and resolve the open design questions in
`02-domain-model.md` first. Treat it as a planned **Phase I** workstream, not a
drive-by change.

New Phase I scope added by the clarifications:
- Per-journal version history (Save / Save new version / rollback-forward).
- Lineage edges between journal versions; **Sync** and **Rollback** (structure +
  manual content reconciliation; AI assistance is Phase II).
- **Notes & feedback** anchored to content elements and prose text ranges.
- **Export & rendering** to DOCX/PDF/LaTeX through a view.
- Keep **View** (output format), **Requirements** (content rules), and **editor
  preferences** (global font/size/theme) as three separate concepts.
- **Backend** (cloud storage) is distinct from **AI service** (adaptation). Both
  are Phase II; collaboration over a backend is Phase III.

## Decisions locked (don't re-open without explicit change)

- Native macOS, no third-party dependencies, account-free, local-folder storage.
- "Cuts" are **Journals**; the Source is the root journal. Every journal has
  required requirements + a view; the journal's default view derives from its
  requirements.
- **Versioning** is per-journal save points; **lineage** is edges between journal
  versions; **sync** is an individual (non-recursive) fast-forward; **rollback**
  restores a prior edge and deletes the versions it produced. Unlimited depth.
- Data referenced by SQL, never duplicated/mutated across cuts; images allow
  uploading a finished graphic when a generated chart is insufficient.
- View = output format; Requirements = content rules; editor preferences = global
  user comfort. Three separate things.
- Backend = cloud storage/collaboration; AI service = LLM adaptation. Separate.
- Notes/feedback is a first-class, content-anchored feature.
- Rich prose stored as plain + RTF; editor uses TextKit 1.
- Default editor font is clean system sans; theming is system/light/dark.
