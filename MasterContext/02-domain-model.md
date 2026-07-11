# 02 — Domain Model

This is the canonical schema. New fields must decode from older files
(`decodeIfPresent`).

> **Terminology revision (supersedes the earlier "version/cut" framing).** A
> "cut" is now a **Journal**. The **Source** is the *root journal*. *Versioning*
> is a separate axis: every journal (including Source) has its own ordered
> **version history** you can save into and roll back/forward through.
> **Lineage** connects specific *versions across journals*. The current code
> still uses the older `ManuscriptVersion`-as-cut shape and **needs migration to
> this model** — see [`09-roadmap.md`](09-roadmap.md). This document describes the
> target.

## The three axes (read this first)

1. **Journals** — what you're adapting *for*. The Source is the root journal;
   each target (NEJM, Cell, …) is another journal. Journals are the things you
   compare side-by-side.
2. **Versions** — *save points within a single journal*. Each journal has its own
   `v1, v2, …` history. "Save" updates the working content; "Save new version"
   stamps a snapshot. You can roll back/forward within a journal.
3. **Lineage** — directed **edges between journal versions** that record "this
   child version was derived from that parent version," e.g. `Source@v2 →
   NEJM@v1`. Editing Source to `v3` does not disturb that edge.

## Entity overview

```
Manuscript (the project)
├─ journals: [Journal]            ← journals[0] is Source (root); others are targets
├─ lineage:  [LineageEdge]        ← edges between specific journal versions
├─ dataAssets: [DataAsset]        ← central Data repository (shared by all journals)
├─ notes:    [Note]               ← feedback anchored to content (first-class)
├─ settings: ManuscriptSettings   ← active backend / AI / editor-independent prefs
└─ folderBookmark, createdAt, updatedAt

Journal
├─ id, name, role (.source | .target)
├─ requirements: JournalRequirements   ← REQUIRED (Source defaults to empty)
├─ viewConfigID: UUID                   ← REQUIRED output-format view (Source has a default)
├─ submission: SubmissionConfig?        ← target journals only (credentials, status)
├─ working: ManuscriptContent           ← the live, editable content ("Save" target)
└─ versions: [JournalVersion]           ← ordered save points ("Save new version")

JournalVersion
├─ id, number (v1, v2, …), label?, createdAt, notes
└─ content: ManuscriptContent           ← full component snapshot at save time

LineageEdge
├─ parent: JournalVersionID  (e.g. Source@v2)
└─ child:  JournalVersionID  (e.g. NEJM@v1)

ManuscriptContent (the component set — one per working head and per saved version)
├─ title, runningTitle, keywords[], authors[]
├─ abstract(RichText), sections[ManuscriptSection]
├─ figures[Figure], tables[ManuscriptTable]
├─ bibliography[BibEntry], letterToEditor

AppStore (global, cross-manuscript)
├─ backends[BackendAccount]     ← WHERE the project is stored in the cloud
├─ aiServices[AIServiceAccount] ← LLMs for adaptation/revision (distinct from backends)
└─ views[ViewConfig]            ← output-format templates (incl. journal-derived)
```

## Journals, versions, lineage

### Journal
The unit of adaptation and comparison. The Source is the root journal.
- `role`: `.source` (exactly one, the root) or `.target`.
- **Requirements and a View are required parts of every journal.** The Source
  journal uses **default (empty) requirements** and a **default view**.
- Target journals also carry a `SubmissionConfig?` (credentials + status); Source
  does not submit.
- Holds the live **working** content plus an ordered **version history**.

### SubmissionProfile (article types) — refinement
A journal accepts one or more **article types** (Original Article, Review, Case
Report, Custom). Model target: `Journal.profiles: [SubmissionProfile]`, each =
`{ articleType: String, requirements: JournalRequirements, outline: ViewConfig }`.
A profile bundles **checks + export outline** so verification matches export. The
active profile is chosen per version; **Checks and Export both use it**. This
supersedes the single `requirements`+`viewConfigID` on `Journal` and lands with
the migration. Source has one default profile (empty requirements + default
outline).

### Export outline
The **outline** (a `ViewConfig`) specifies, per document, **which components go in
what order and in what format** — across *all* components (title, authors,
abstract, keywords, body + journal-specific sections, figures, tables,
bibliography, letter), not just body sections. `requiresSeparateFigures` splits
figures/tables into their own document. Export renders through the active
profile's outline (see [`05-features.md`](05-features.md) M).

### Versioning (within one journal)
- **Save** — persist edits to the journal's working content.
- **Save new version** — snapshot the working content as the next `JournalVersion`.
- **Roll back / forward** — move the working content to a different saved version
  in this journal's history. (Independent of lineage and of other journals.)

### Lineage (between journals)
- An edge links a **parent journal version** to a **child journal version**
  (`Source@v2 → NEJM@v1`). Created when a journal is cut from a parent version,
  and when a **sync** runs.
- The tree has **no depth limit** (Source → A → B → …).
- Editing one journal forward (new versions) does **not** alter existing edges.

### Creating a journal (a "cut")
Pick a **parent journal** (its current version), set name + requirements + view.
Create the new target journal with `v1` and an edge `parent@vX → child@v1`. In
**Phase I** the child is **seeded from the parent snapshot** and reconciled
**manually**; in **Phase II** the child's content is AI-adapted from the parent
toward the child's requirements.

### Sync (git fast-forward, one edge at a time)
Re-derive a child from its parent's newer version. Given edge `Source@v2 →
NEJM@v1`, after Source advances to `v3`, choosing **Sync NEJM** stamps a new
child version and a new edge:
- Source stays at `v3`, **NEJM gets `v2`**, and an edge `Source@v3 → NEJM@v2` is
  created. (Phase I: manual reconciliation. Phase II: the new child version is
  AI-adapted from `Source@v3`.)
- **Syncs are individual, never recursive** — you sync one edge at a time to
  avoid cascading changes.

### Rollback (undo a sync/derivation)
Restore the previous edge and discard the newer versions it produced. Given
`Source@v3 → NEJM@v2` with a prior edge `Source@v2 → NEJM@v1`, rolling back
**re-activates `Source@v2 → NEJM@v1`** and **soft-archives `Source@v3` and
`NEJM@v2`** (see locked decision below).

### Lineage visualization (how the tree reads)

**Compressed view** (default): each journal node shows its **current version**
(NEJM v2, PLOS v1, Nature v1); the edge into a journal is labeled with the
**parent version** it was derived from. The Source node carries no version label
because the edges encode it. A **sync icon** on an edge means a fast-forward is
available (the parent advanced past that edge).

![Compressed lineage with current-version nodes + sync icons](examples/lineage-management.png)

![Compressed lineage tree](examples/lineage-compressed.png)

**Detailed view** (drill-down, opened by clicking an edge between two journals):
shows the historical and most-recent edges between just those two journals — e.g.
`Source v1 → NEJM v1` then `Source v2 → NEJM v2`.

![Detailed lineage between two journals](examples/lineage-detailed.png)

> **Resolved decisions (locked):**
> - **Rollback = soft archive.** Undone versions are marked archived (hidden but
>   recoverable), and the prior edge becomes the active one again — nothing is
>   hard-deleted.
> - **The latest version IS the working head.** Editing always edits the latest
>   version in place; **Save new version** forks a new latest version. There is no
>   separate mutable head distinct from the latest version.
>
> **Still open (don't guess — confirm before implementing):** what happens to an
> edge's endpoints when a journal has *other* edges off the same version; how the
> comparison tabs pick which version to show (assume the latest/active version
> unless an archived history version is explicitly selected).

## Requirements vs. View vs. editor preferences (keep these distinct)

- **JournalRequirements** — *content* constraints to satisfy: `maxBodyWords,
  maxAbstractWords, maxFigures, maxTables, maxReferences (Int?, nil = none)`,
  `requiredSections`, `citationStyle`, `customRules[]`. Drives **Checks**.
- **ViewConfig (the "view")** — the *output format/structure* of the document
  (documents, per-section font/spacing/title, line numbering, export format,
  separate-figures doc). It is **not** content rules and **not** the user's
  editing preferences. (Name `ViewConfig` is fine; the concept = output format.)
  - `ViewDocument`: `name, sections[ViewSectionConfig], lineNumbering, exportFormat, order`
  - `ViewSectionConfig`: `sectionRef, customTitle?, fontStyle, wordLimit?, lineSpacing, order`
  - `SectionRef`: `byType(SectionType)` or `byID(UUID)`
  - `ViewConfig.from(requirements:)` derives a journal's default view.
- **Editor preferences** — the *user's* global reading/editing comfort (font
  family/size, line spacing, theme). Global app settings, **not** a view, and not
  per-journal. See [`06-design-system.md`](06-design-system.md).

## Data repository (shared, referenced by SQL)

- A **DataAsset** is tabular data imported into **SQLite** (`type .csv`) or an
  imported **image** (`type .image`), stored once in the manuscript's `data/`
  folder and shared across all journals.
- A figure/table **references** an asset by `dataAssetID` + a **SQL query** (plus
  `chartType` for figure charts). A cut may change the **source + SQL** binding,
  but **never the underlying data**.
- **Images exist so a researcher can upload a finished graphic** when a generated
  chart (source + SQL) is insufficient for a journal — figures accept either.

## Notes & feedback (first-class)

Notes are a first-class way to leave feedback for oneself or collaborators,
**anchored to content**:
- A note targets a content element (a figure, table, author, section, …) **or** a
  **highlighted text range** within prose.
- Suggested shape: `Note { id, target: NoteAnchor, body, author, createdAt,
  resolved }`, where `NoteAnchor` identifies the element and an optional text
  range. UI: a "notes" affordance on items, and highlight-to-comment in prose.
- Open question: are notes attached to a journal/version's content or shared
  across the manuscript? (Lean: anchored within a journal's content, but visible
  while comparing.)

## Content components (within `ManuscriptContent`)

- `Author`: name parts, email, ORCID, isCorresponding, order, and
  `institutionIDs[]` — references into the manuscript-level
  `institutions: [Institution]` registry (id + name, managed in the Authors
  pane). **Every author must reference at least one institution** (rows and
  the editor flag violations). Legacy free-text `affiliations[]` still decode
  and display until registry references replace them.
- `ManuscriptSection`: `id, type(SectionType), title, content(RichText), order,
  active(Bool)`; `wordCount` from `content.plain`. `SectionType`: introduction,
  methods, results, discussion, conclusion, acknowledgments, supplementary, custom.
  **Sections are shared structure**: a section (id/title/order) exists in **every
  version**. What differs per version is its **content** and its **`active`**
  flag. Adding/deleting/reordering/renaming applies everywhere (titles kept
  unique); a version can **deactivate** a section (e.g. a journal that doesn't
  want a Disclosure) — deactivated ⇒ empty, uneditable, and **excluded from
  Checks and Export**. New sections are added from an inline row at the bottom of
  the section list.
- `Figure`: `number, title, caption, altText, fileName?` + optional binding
  `dataAssetID?, chartType?(.line/.bar/.histogram), chartQuery?`.
- `ManuscriptTable`: `number, title, caption, footnotes, content(Markdown)` +
  optional `dataAssetID?, dataQuery?` + export formatting `openSides?`
  (horizontal rules only) and `alternateShading?`; `footnotes` export as a
  "Note." paragraph beneath the table.
- `Manuscript` additions: `articleTitle?` (journal-facing title, versioned per
  cut — the project name stays in `title`), `paneTitles?`/`hiddenPanes?`
  (sidebar rename/hide of the fixed Figures/Tables/Bibliography/Letter panes).
- `Journal.icon?`: SF Symbol shown in the sync lineage ("?" when unset),
  configured in the app-settings Journals library.
- **Data is global**: every journal (Source included) reads the one Data
  repository; only the *view* on it — SQL + formatting on figures/tables — is
  versioned content. `dataAssets` are excluded from sync content checksums.
- `BibEntry`: key, type, authors[], title, year, journal/volume/issue/pages, doi,
  url, note; `authorsFormatted`. **Zotero linkage (refinement):** an optional
  `zoteroKey` links an entry to a local Zotero item so it can be re-synced
  (see [`05-features.md`](05-features.md) O).
- `LetterToEditor`: three letterhead slots `headerLeft/headerCenter/headerRight`
  (each a `LetterHeaderSlot`: `text` + optional embedded `imageData`),
  `body(RichText)`, `signature`, optional `signatureImageData` (hand-drawn PNG).
  Legacy `headerTitle`/`headerSubtitle` decode into the center slot.
- `RichText`: `plain` (mirror for word count/search) + `rtf?` (styled archive);
  decodes a legacy bare `String` as unstyled.

## Global accounts

- **BackendAccount** — *where the project is stored in the cloud* for remote fetch
  /store and collaboration: GitHub, Office 365, Dropbox, Google Docs, GitLab.
  One backend is active per manuscript. **Phase II** = save-and-share (push on
  Save / Save new version; fetch/restore). **Phase III** = active collaboration
  with **concurrency**.
- **AIServiceAccount** — an LLM provider (Claude, ChatGPT, Gemini, Ollama) used to
  **adapt/revise** content (**Phase II**). **Distinct from a backend.** Not needed
  in Phase I — cuts are created and edited manually then.


## Stamping, Source versions & identity (July 2026 revision)

- **Stamping** is the version verb: the working state is always **"latest"**;
  *Stamp Version* freezes it as `vN` and opens a fresh working head.
  `ManuscriptVersion.sourceStamp == true` marks a **Source stamp** — Source
  maintains its own chain exactly like the journals (its "latest" is the live
  manuscript). Legacy custom cuts remain `journalID == nil` without the flag.
- **Lineage hangs from frozen versions**: sync and add-journal stamp the
  upstream first when its latest has unstamped changes ("Stamp & Sync").
  Rollback restores a prior version and drops the versions after it (refused
  when a dropped version has cross-journal children).
- **Identity**: the app keeps a local P-256 keypair (private key in the
  Keychain — never in manuscript files; `SigningService`). Identities have a
  **type** — local (freeform name; unverifiable, warned), or GitHub / GitLab /
  OpenPGP (a GPG public key checked against the handle's publicly registered
  keys; "Test" + how-to link in Preferences → User). Stamps and notes carry
  the signer's public key + signature; `Author.signatureInfos` (rich) /
  `Author.publicKeys` (legacy=local) tie keys to authors. Badge rules
  (`SignatureBadge`): **✓ green** = signature verifies AND the tie is a
  verified remote identity; **? orange** = verifies but only a local identity
  vouches (or untied); **! red** = signature fails. Badges check keys across
  the Source AND every version snapshot.
- **Journal library**: `AppStore.journalLibrary: [Journal]` — global, reusable
  journal profiles (name, country, requirements, export outline), seeded from
  presets, grown via "Save to Journal Library". Adding a journal to a
  manuscript instantiates a copy with fresh identity.
- **Remote binding is per-manuscript**: `ManuscriptSettings.remoteRepository`
  / `remoteBranch` + `Manuscript.lastSyncedAt`; accounts (Preferences →
  Accounts) hold only credentials.

### Round-5 revisions (Jul 2026)

- **Editors are decoupled from authors**: no key ties on `Author`. Stamps and
  notes carry `stampedByKey/stampSignature/stampedByType` (and note
  equivalents); the badge judges each artifact alone — ✓ when signed under a
  remote-verified identity (GitHub/GitLab/OpenPGP GPG check), ? for local,
  ! on signature mismatch.
- **Remote repository layout is git-branch shaped** (app-managed, REST Git
  Data API): `main` = README only (identity + do-not-edit-by-hand warning),
  `source` = authoritative content, `journal-*` = per-journal head snapshots
  (diffable against source). FLAGGED DESIGN NOTE: in-app sync is
  content-taking, not a git fast-forward (impossible once a journal branch
  has its own commits); true merge-parent recording is a refinement.
- **Export**: data-linked figures render their chart (ImageRenderer over the
  same DataChartView the editor shows); data-linked tables render their SQL
  rows as a centered, tab-aligned grid (doc font, min column widths); blank
  lines count in margin line numbering.
