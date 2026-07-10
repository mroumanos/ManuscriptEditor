# 04 — Information Architecture

## Window shape

`NavigationSplitView`: a left **sidebar** and a right **detail** area. The window
**title always shows the manuscript name** (set once on the sidebar; detail views
must NOT set their own navigation titles). Unified title bar.

## Sidebar

Two sections, plus a bottom utility bar:

**Manuscript** (manuscript-level, single-pane)
- Overview
- Data (N)
- Settings

**Journal** (the per-journal hub — sits above Content)
- Sync     ← lineage management as a **nested tree** (each journal indented
             under its upstream) with a per-edge fast-forward + overwrite warning
- Checks   ← **comparable**: one live pane per open tab, each checking its own
             tab's journal (Source shows an explanatory state — no picker)
- Export   ← **comparable**: one pane per open tab — that journal's export
             outline editor + submission package build (no picker)
- Versions (N)   ← **comparable**: one pane per open tab — that journal's linear
             history + the full lineage diagram with the journal highlighted
             (no picker)

The Checks/Export/Versions panes **represent the journal of their tab**
(starting with Source): open a NEJM tab and you see NEJM's side of the
environment beside Source's. There is never a journal dropdown inside these
panes.

**Content** (version-comparable items — these render side-by-side per open tab)
- Authors (N)
- Abstract
- Keywords (N)
- the body **sections** in order (Introduction, Methods, …, each shows its word
  count badge)
- Figures (N)
- Tables (N)
- Bibliography (N)
- Letter to Editor

**The Content section is shown only when at least one version tab is open.** With
no tabs open it disappears, and selecting it is impossible; selection falls back
to Overview.

**Bottom utility bar** (pinned, does not scroll with the list)
- A **gear** icon → opens the app **Preferences** window (⌘,). Global settings
  (Backend / Views / AI / Editor) live there, NOT inline in the sidebar.
- An **appearance** toggle (System / Light / Dark).
- "Add Section" (＋) lives in the sidebar toolbar at top.

## The journal comparison tabs (top of the detail area)

A horizontal **tab bar** lists the **active journals** to compare (each shown at
its current working version unless a history version is explicitly selected).

- Each tab is a journal: **Source** or a target. Tabs are **color-coded** by
  position (Source blue, then orange, green, …); the tab chip and its pane share
  the color.
- **Source is a normal tab** — it has an ✕ and can be closed like any other.
- **Tabs are titled by journal + per-journal ordinal** ("Nature v2"), with older
  (non-head) versions marked "(older)". The free-text version label (e.g.
  "Synced from NEJM v2") appears only as secondary context in the picker — it
  names the upstream, not the journal, so it cannot be the tab identity.
- A **＋** opens a picker of journals not currently open, offering **working
  heads only** — opening "Nature" always means its current head; older versions
  are history, browsed in Versions, never tab candidates. Journals are created
  in the **Journals** panel, not here.
- **Side-by-side for comparable items.** Comparable = the **Content** items
  **plus Checks, Versions, and Export**. When a comparable item is selected AND
  ≥1 tab is open, the detail splits into one pane per open journal. For the
  remaining manuscript-level items (Overview/Data/Sync/Settings) the tabs are
  irrelevant and a single pane renders against Source.
- **Checks renders per-journal and live.** With Source + NEJM open and **Checks**
  selected, each pane shows that journal's requirement checklist evaluated against
  that journal's current content — updating **instantly** as you edit. So you can
  bring up Checks side-by-side exactly like Abstract.
- **Synced navigation.** One shared sidebar selection: click "Methods" and every
  open pane shows Methods; click "Introduction" and they all switch together.
- **Pane headers are slim** — word count, per-journal section activation (eye),
  and notes, aligned past the editor gutter. The selected item's name is NOT
  repeated per pane (the sidebar selection already names it; the former colored
  title capsule is gone). Which journal a pane shows is carried by the tab
  chips above, in the same left-to-right order. Body sections are renamed via
  the sidebar's **context menu → Rename Section…** (shared structure — applies
  to every journal).
- A per-pane **version control** (e.g. a `v3 ▾` menu with Save / Save new version
  / roll back-forward) lets the user move through that journal's history without
  affecting other journals.

## Where each capability lives (so it's never re-litigated)

| Capability | Location |
|---|---|
| App-wide theme | Sidebar bottom toggle **and** Preferences → Editor |
| Backends / AI services / global Views | **Preferences (⌘,)** tabs |
| Editor font / size / line spacing | Preferences → Editor |
| Per-manuscript active backend / source view / AI | **Settings** sidebar item |
| Create journals (cuts); lineage tree; sync/rollback; per-journal version history | **Journals** sidebar item |
| Journal requirements & checklist (per journal) | inside a journal's detail in **Journals** |
| Save / save new version / roll back-forward | per-pane version control + **Journals** detail |
| Notes & feedback on content | inline on content items / highlight-to-comment in prose |
| Import CSV/images; SQL; charts | **Data** sidebar item |
| Requirement pass/fail for active view | **Checks** sidebar item |
| Save to Remote / Load from Remote (GitHub backend) | **Manuscript menu** (⇧⌘S / Load from Remote…); repo+token in Preferences → Backend; active backend in **Settings** |
| New manuscript (folder picker) | ＋ in window toolbar / ⌘N |

## Journal hub (implemented) & profiles (planned)

The per-journal concerns are grouped in a **Journal** sidebar section (above
Content): **Sync**, **Checks**, **Export**, **Versions**. This consolidates "what this
journal needs, tracks, and outputs" in one place.

Planned extension: make each of these **profile-aware** (per article type — D2 in
[`05-features.md`](05-features.md)) so Checks and Export follow the selected
submission profile, and add a per-profile export-outline editor under Export.

## Journals panel (journals + lineage + version history)

- Left: the **lineage tree** — **Source** root, then journals indented by depth
  with box-drawing connectors. "Add Journal" lives in the section. Each journal
  row exposes its version history and **Sync** / **Rollback** affordances along
  the relevant edge.
- Right: selecting **Source** shows the full lineage visualization; selecting a
  journal shows its detail — **Requirements** and **Checklist** tabs, the chosen
  **View**, version history (Save / Save new version / roll back-forward), the
  `Source@vX → … → this@vY` lineage breadcrumb, and (targets only) submission
  config/status.
- **Add Journal** sheet: name + **cut-from parent journal** (Source or any
  journal, at its current version) + **requirements & view** (from a preset, which
  supplies both, or custom). Creates the journal at `v1` with a lineage edge from
  the parent version.
- **Sync** (per edge): re-derive a child from its parent's newer version — stamps
  a new child version and a new edge. Individual, never recursive. A **sync icon**
  on an edge signals a fast-forward is available.
- **Rollback** (per edge): restore the prior edge and **soft-archive** the newer
  versions it produced (recoverable, not deleted).

The lineage has a **compressed** default view (journal nodes labeled with their
current version, edges labeled with the parent version) and a **detailed**
drill-down (click an edge to see the history between two journals). See the
diagrams in [`02-domain-model.md`](02-domain-model.md#lineage-visualization-how-the-tree-reads).

![Compressed lineage](examples/lineage-management.png)
