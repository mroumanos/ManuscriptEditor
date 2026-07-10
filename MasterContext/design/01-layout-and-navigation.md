# 01 — Layout & Navigation Design

> Design rules for the window anatomy defined in
> [`04-information-architecture.md`](../04-information-architecture.md) (which
> owns *what lives where*; this doc owns *how it should look and behave*).
> Wireframes: [`07-wireframes.md`](../07-wireframes.md).

## 1. Window anatomy

One main window per manuscript (`NavigationSplitView`): **sidebar** left,
**detail** right, **comparison tabs** across the top of the detail area.

```
┌──────────────────── Manuscript name (window title) ─────────────────────┐
│ SIDEBAR          │ [📄 Source ✕] [⌥ NEJM ✕]                       [＋]  │
│  Manuscript      ├───────────────────┬──────────────────────────────────┤
│  Journal         │  pane (Source)    │  pane (NEJM)                     │
│  Content         │  header·toolbar   │  header·toolbar                  │
│  ─ bottom bar ─  │  ruler·gutter·text│  ruler·gutter·text               │
└──────────────────┴───────────────────┴──────────────────────────────────┘
```

- **Window title = manuscript name, always.** Detail views never set their own
  navigation titles. Unified title bar.
- **Sidebar** answers *where am I*: Manuscript (Overview, Data, Settings),
  Journal (Sync, Checks, Export, Versions), Content (Authors, Abstract,
  Keywords, body sections, Figures, Tables, Bibliography, Letter to Editor).
  User-resizable; selection uses the accent highlight; word-count badges on
  sections and counts in parentheses (`Data (3)`).
- **Bottom utility bar** is pinned (never scrolls with the list): gear →
  Preferences (⌘,), appearance toggle (System/Light/Dark).
- **Detail fills its pane.** No floating translucent cards, no centered shrunken
  content (00 §3.1). Master–detail splits use a sensible `minWidth` (~360 for
  comparison panes).

## 2. The comparison tab bar (state made visible)

The tab bar is the app's most important state indicator (00 §3.3):

- Each chip = one active journal (**Source is a normal, closable tab**), titled
  `Journal vN` with per-journal ordinals; non-head versions marked **"(older)"**.
- Chips are **color-coded by the journal** (Source blue, then orange, green,
  purple, pink, teal); panes render below the chips in the same left-to-right
  order, so the chip carries each pane's identity. Key colors to the
  `VersionRef`, never the tab index, so closing a tab never recolors the
  survivors.
- **＋** opens a picker of journals not currently open, offering **working
  heads only** — older versions are history (Versions pane), never tabs.
  Journals are *created* in the Journals panel, never here.
- The "Source" tab sits first and never shifts position.

## 3. One selection, many panes

- **Synced navigation:** the sidebar holds a single shared selection. Click
  "Methods" and every open pane shows Methods; there is no per-pane navigation.
- **Comparable items** (Content + Checks) render one pane per open tab.
  Manuscript-level items (Overview, Data, Journals/Sync/Export/Versions,
  Settings) render a single pane; the tabs are irrelevant there and must not
  imply otherwise.
- With zero tabs open the Content section disappears and selection falls back to
  Overview — never a dead selection pointing at nothing.
- Each pane carries a **slim header** (word count, section-activation eye,
  notes — never a repeat of the selected item's name; the sidebar names it) and
  a **per-pane version control** (`v3 ▾`: Save / Save new version / roll
  back-forward) scoped to that journal only. Body sections rename via the
  sidebar context menu.

## 4. Panels, popovers, and sheets

- Inspectors and secondary surfaces (note panels, pickers, the add-journal
  sheet) act on the manuscript; they never become primary editing surfaces.
- Popovers trap focus while open; `Esc` / outside-click closes and restores
  focus to what had it before.
- Sheets are reserved for flows that need commitment (Add Journal, export
  destination); informational content never blocks in a modal
  ([07 §7](07-interaction-patterns.md)).

## 5. Navigation invariants

- Navigation from anywhere behaves identically: selecting a sidebar item, a
  check result, or a note anchor brings the relevant content into view without
  opening dialogs or stealing typing focus (07 §2).
- Layout state (sidebar width, open tabs, pane sizes, selected item) persists
  per manuscript across launches. Reopening a manuscript should feel like
  returning to a desk, not setting one up.
- `Esc` de-escalates one level per press: close popover → close panel/sheet →
  clear transient state. It never discards unsaved edits.
- Every user action is reachable from the menu bar (and therefore from macOS
  Help search); hover-only or gesture-only affordances must have a menu
  equivalent.
