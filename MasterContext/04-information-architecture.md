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
- Log      ← the activity history: every banner (success/error), manual
             save, stamp, rollback, sync, journal add/delete — full messages,
             never truncated.  (Replaced the Sync pane, Aug 2026: journals &
             lineage moved to Overview, save buttons to the Overview summary.)
             Sync between journals lives on the Overview lineage rows
             (a drifted upstream first raises
             its own stamp prompt — declining cancels — and the sync prompt
             states whether a connected AI may modify the copy), and Add Journal (from = Source/journal; to = a profile
             from the app-settings journal library)
- Backend  ← THIS manuscript's storage: local folder, active account, remote
             repository (create one here for local-first projects, with a link
             to it once created)
- AI       ← THIS manuscript's AI service selection (Phase II)

**Journal** (the per-journal hub — sits above Content)
- Checks   ← **comparable**: one live pane per tab, each checking its own
             tab's journal; hosts Edit Requirements… and Save to Journal
             Library… (Source shows an explanatory state)
- Export   ← **comparable**: one pane per tab — that journal's export outline
             editor + package build + Save to Journal Library…
- Versions (N)   ← **comparable**: one pane per tab — that journal's
             **horizontal version table** (Version · Stamped · From→To · By)
             with Stamp Version and Roll Back…

The Checks/Export/Versions panes **represent the journal of their tab**
(starting with Source): open a NEJM tab and you see NEJM's side of the
environment beside Source's. There is never a journal dropdown inside these
panes.

**Content** (version-comparable items — these render side-by-side per open tab)

Split in two by a **soft rule** — a hairline, not a header, so the division is
felt rather than announced. Above it, the parts every manuscript has, in a
fixed order; below it, the sections the author actually shapes.

*Fixed* — cannot be reordered, deactivated, or removed (a manuscript without a
title or a bibliography isn't a manuscript). Renaming a pane is still allowed:
that changes the label, not whether the part exists.
- Title
- Authors (N)
- Abstract
- Keywords (N)
- Figures (N)
- Tables (N)
- Bibliography (N)
- Letter to Editor

— soft rule —

*Configurable* — the body **sections** in order (Introduction, Methods, …, each
shows its word count badge). **Drag to reorder**, **deactivate per journal**
(dimmed with an orange `eye.slash`; the text is preserved, and Checks/Export
filter on the flag, never on emptiness), rename, delete. These are exactly what
a journal's `structure.json` describes.
- "Add Section" closes the list.

Every content pane carries a slim header (word count, activation, gear,
preview, notes) and, when a check covering that pane is failing, a **red bar**
directly beneath it naming the problem — first failure, circled count, full
list on click. It is derived, so it disappears when the content passes.

**The Content section is always available** — tabs load automatically, so at
least the Source tab always exists.

**Bottom utility bar** (pinned, does not scroll with the list)
- A **gear** icon → opens the app **Preferences** window (⌘,). App-wide
  settings (Editor / Accounts / Journals library / User identity) live there;
  manuscript-scoped Backend/AI live in the sidebar's Manuscript section.
- An **appearance** toggle (System / Light / Dark).
- "Add Section" (＋) lives in the sidebar toolbar at top.

## The journal tab bar (top of the detail area)

Tabs **load automatically** — Source plus every journal, in manuscript order —
and are never opened/closed by hand (adding a journal in Overview adds its tab).
Tab identity is the **journal**, always resolving to its current working head.

- **Browser-style chips**: icon + journal name; the shown tab(s) sit on a
  lighter raised surface with an accent underline. No color coding — active
  state is the only signal.
- A segmented **Active | Compare** toggle replaces the old ＋ button:
  - **Active**: exactly one journal renders; click a tab to switch, or cycle
    with **⌘⇧← / ⌘⇧→** (View menu).
  - **Compare**: each chip gains **＋** (include) / **✕** (remove); included
    tabs render side-by-side, split evenly by default. The last included tab
    can't be removed (falls back to Source).
- **Side-by-side for comparable items.** Comparable = the **Content** items
  **plus Checks, Versions, and Export**. When a comparable item is selected AND
  ≥1 tab is open, the detail splits into one pane per open journal. For the
  remaining manuscript-level items (Overview/Data/Log) the tabs are
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


## Where each capability lives (so it's never re-litigated)

| Capability | Location |
|---|---|
| App-wide theme | Sidebar bottom toggle **and** Preferences → Editor |
| External accounts (GitHub/GitLab/Claude/OpenAI…) + Test Connection | **Preferences → Accounts** (tokens/keys in Keychain) |
| Journal library (search, details, requirements) | **Preferences → Journals** |
| User identity (name + signing key) | **Preferences → User** |
| Editor font / size / line spacing | Preferences → Editor |
| This manuscript's backend account / local folder / remote repo (create + link) | **Manuscript → Backend** sidebar item |
| This manuscript's AI service | **Manuscript → AI** sidebar item |
| Save (Local) ⌘S / Save (Remote) ⇧⌘S | **File menu** + the **Overview** summary buttons (loading an existing remote = New Manuscript (Remote)… — no separate Load command) |
| Add journals (from → to); sync between journals; lineage tree | **Manuscript → Overview** (Journals & Lineage card) |
| Stamp Version / Roll Back; per-journal version table | **Journal → Versions** pane (per tab) |
| Journal requirements editing; save profile to library | **Journal → Checks** pane (per tab) |
| Notes & feedback on content | notes button in pane headers (signed) |
| Import CSV/images; SQL; charts | **Data** sidebar item |
| New (app data) ⌘N / Open (Local)… ⌘O in-place / Open (Remote)… clone / Export Project zip ⌘E | **File menu** (all warn about unsynced work first) |

## Lineage (Overview — Journals & Lineage card)

The lineage renders as a **contiguous nested tree**: Source at the root, each
journal's card attached directly beneath its upstream — tabbed on the left,
right edges aligned. Each card carries the edge badge it hangs from (upstream
version), its "vN / latest" position, a drift status that never overstates
freshness, and its per-edge **Sync** button (relabeled **Stamp & Sync** when
the upstream's latest has unstamped changes — lineage always hangs from frozen
versions). Source maintains its own version chain exactly like the journals
(stamp it in its Versions pane).



> Aug 2026: the Backend and AI sidebar tabs were removed — their controls
> (local folder, backend account, repo/branch, AI service) live in Overview's
> "Saving & Backend" card alongside the save buttons.
