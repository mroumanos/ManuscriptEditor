# Glossary

Precise definitions of every domain term. Use these names consistently in code,
UI, and docs. (Updated for the Journal/Version/Lineage model — see
[`02-domain-model.md`](02-domain-model.md).)

- **Manuscript** — the whole project the user opens; lives in a chosen folder.
  Holds the journals, the lineage, the shared Data repository, notes, and
  settings.
- **Journal** — the unit of adaptation and side-by-side comparison; what a copy is
  made *for*. Every journal has required **requirements** and a **view**; targets
  also have submission config. Includes the root **Source** journal.
- **Source** — the *root journal*: the primary content everything else derives
  from. Uses default (empty) requirements and a default view. A normal, closable
  comparison tab.
- **Cut** — the act of creating a new target journal from a parent journal version
  (user-facing verb: "add a cut" / "add journal").
- **Version** — a *save point within one journal* (`v1, v2, …`). **Save** updates
  the journal's working content; **Save new version** snapshots it. You can
  **roll back/forward** through a journal's versions.
- **Lineage** — directed **edges between journal versions** (`Source@v2 →
  NEJM@v1`) recording derivation. Unlimited depth; editing a journal forward
  doesn't alter existing edges.
- **Sync** — a git-style fast-forward of **one** lineage edge: re-derive a child
  from the parent's newer version, stamping a new child version and a new edge.
  Individual, never recursive.
- **Rollback** — undo a sync/derivation by restoring the prior edge and deleting
  the newer versions it produced.
- **View (ViewConfig)** — the *output format/structure only* (documents,
  per-section font/spacing/title, line numbering, export format). Not content
  rules; not the user's editor preferences. Each journal has one (Source's is a
  default); users can also create views.
- **Submission profile / article type** — a named variant a journal accepts
  (Original Article, Review, Case Report, Custom). Bundles that type's **checks**
  (requirements) and **export outline** (a view). A journal has one or more;
  Checks and Export both use the active one.
- **Export outline** — the ordered specification of which components go in which
  document, in what order and format, across all components (not just body
  sections). Part of a profile.
- **Export / submission package** — the folder Export produces: the main
  document (DOCX/RTF/HTML/plain) plus any separate figures document and copied
  figure images — everything needed to submit online.
- **Zotero connector** — an integration with a locally-running Zotero (local HTTP
  API) to browse/import/manage bibliography references. Phase II.
- **Requirements (JournalRequirements)** — a journal's *content* constraints:
  word/abstract/figure/table/reference limits, citation style, required sections,
  free-text custom rules. Drives **Checks**.
- **Editor preferences** — the user's global reading/editing comfort (font, size,
  spacing, theme). Global; not a view; not per-journal.
- **Note** — first-class feedback anchored to a content element or a highlighted
  text range, for oneself or collaborators.
- **Data repository / Data asset** — the manuscript's central store of imported
  data. A **DataAsset** is a CSV (stored as SQLite) or an image. Referenced by
  figures/tables; never duplicated.
- **SQL binding** — a figure/table's reference to a data asset (`dataAssetID`) plus
  a SQL query (and chart type for figures). The only thing a cut "converts."
- **Content item** — a version-comparable component: Authors, Abstract, Keywords,
  a body Section, Figures, Tables, Bibliography, Letter to Editor.
- **Section (ManuscriptSection)** — one body section (Introduction, Methods, …),
  with a `SectionType`, title, and `RichText` content.
- **RichText** — prose storage: `plain` (mirror for word count/search) + `rtf`
  (styled archive) + `refs` (ordered reference-token list, so numbering never
  decodes RTF).
- **Reference token** — an in-text reference inserted by the `/` autocomplete:
  a citation of a bibliography entry (rendered in a **citation style**) or a
  figure/table cross-reference ("Figure 2"). Identity lives in a
  `cite://`/`figref://`/`tabref://` link attribute; the visible text is
  re-rendered automatically when numbering or the target changes (see
  `RefEngine`, 05-features P).
- **Citation style** — a token's academic rendering convention, chosen per
  token by clicking it: `[1]`, `(1)`, superscript `¹`,
  `(Smith et al., 2024)`, or narrative `Smith et al. (2024)`. Distinct from a
  journal's requirements-level "citation style" check.
- **Comparison tab** — a top-of-detail tab representing an active `VersionRef`
  (Source or a cut), color-coded; Content items render one editable pane per tab.
- **VersionRef** — `source` or `version(UUID)`; routes reads/edits to the right
  version's content.
- **Backend** — a user-configured cloud storage service (GitHub, Google Docs,
  GitLab, Office 365, Dropbox); one is "active" per manuscript. **Phase II** =
  save-and-share (push on Save / Save new version, fetch/restore); **Phase III** =
  active collaboration/concurrency.
- **AI service** — a user-configured LLM provider (Claude, ChatGPT, Gemini,
  Ollama) for adaptation/revision (**Phase II**). Not needed in Phase I; cuts are
  manual then.
- **Checks** — the deterministic checklist comparing content to the active
  view/journal requirements.
- **Account-free** — the app has no accounts of its own; all persistence/AI is
  optional, user-supplied third-party integration.
- **ManuscriptStore / AppStore** — the per-manuscript and global `@Observable`
  state stores.
