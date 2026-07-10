# 07 — Wireframes

ASCII layouts of the major screens. These define structure and placement, not
pixel values; defer to [`06-design-system.md`](06-design-system.md) for styling.
Drop annotated screenshots/mockups in [`assets/`](assets/) and link them here.

## Main window — Content item, side-by-side (Source + a cut)

```
┌───────────────────────────── Manuscript Title (window title) ──────────────────────┐
│ SIDEBAR                    │ ┌ [📄 Source ✕] [⌥ NEJM ✕]                    [＋] ┐    │
│ Manuscript                 │ │  (comparison tabs — color-coded; Source closable) │  │
│   Overview                 │ ├───────────────────────┬───────────────────────────┤ │
│   Checks                   │ │           14 words 👁 │             6 words 👁    │ │  ← slim header
│   Data (3)                 │ │ B I U S x² x₂ ▤▤▤▤ •  │ B I U S x² x₂ ▤▤▤▤ •      │ │    (no title) +
│   Journals (4)             │ │ ┌── width ruler ▼──┐  │ ┌── width ruler ▼──┐      │ │    toolbar
│   Settings                 │ │ 1 │ Lorem ipsum…    │  │ 1 │ Adapted text…   │      │ │  + ruler
│ Content                    │ │ 2 │ …               │  │ 2 │ …               │      │ │  + gutter
│   Authors (2)              │ │ 3 │                 │  │   │                 │      │ │
│   Abstract        ◀ sel    │ │   │ (Source pane,  │  │   │ (NEJM pane,     │      │ │
│   Keywords (0)             │ │   │  editable)      │  │   │  editable)      │      │ │
│   Introduction      6w     │ │                       │                           │ │
│   Methods           2w     │ └───────────────────────┴───────────────────────────┘ │
│   … Results/Discussion …   │                                                        │
│   Figures (1)              │                                                        │
│   Tables (0)               │                                                        │
│   Bibliography (1)         │                                                        │
│   Letter to Editor         │                                                        │
│                            │                                                        │
│ [⚙]  [◐ theme]             │                                                        │
└────────────────────────────┴────────────────────────────────────────────────────────┘
```

## Main window — manuscript-level item (single pane, tabs irrelevant)

```
│ … Journals ◀ sel │ ┌ [📄 Source ✕] [⌥ NEJM ✕]                        [＋] ┐        │
│                   │ ├──────────────────────────────────────────────────────┤       │
│                   │ │  JOURNALS (lineage)        │  Source lineage / detail │       │
│                   │ │  📄 Source                 │  Version Lineage         │       │
│                   │ │  └─ ⌥ NEJM v1        ✕     │  Source                  │       │
│                   │ │     └─ ⌥ Science v1  ✕     │  ├─ NEJM v1              │       │
│                   │ │  └─ ⌥ BMJ v1         ✕     │  │  └─ Science v1        │       │
│                   │ │  [＋ Add Journal]          │  └─ BMJ v1               │       │
└───────────────────┴────────────────────────────────────────────────────────────────┘
```

## Empty state (lists with no items)

```
┌───────────────────────────────────────────────┐
│                                                │
│                   (icon)                       │
│                No Authors Yet                  │
│            Add authors to get started.         │
│                [ ＋ Add Author ]               │
│                                                │
└───────────────────────────────────────────────┘
```

## Add Journal sheet

```
┌──────────────── Add Journal ────────────────┐
│ Label:  [ Nature v1                       ]  │
│ Cut from:  ( Source ▾ )                      │
│ Basis:   ( • Journal ) ( ◦ Custom View )     │
│ ┌─ Journal ───────────────────────────────┐ │
│ │ This Manuscript:  Nature, NEJM           │ │
│ │ Presets:          Cell, BMJ, PLOS ONE…   │ │
│ └──────────────────────────────────────────┘ │
│                         [ Cancel ] [ Add ]   │
└──────────────────────────────────────────────┘
```

## Data → CSV asset

```
│ DATA              │  (asset name)                 [ Table | Chart ]        │
│ Tabular Data      │  SQL: [ SELECT * FROM data                 ] [Run]    │
│   sales.csv  ✕    │  ┌───────────────────────────────────────────────┐    │
│ Images            │  │ col1 │ col2 │ col3 │ …                         │    │
│   plot.png   ✕    │  │  …   │  …   │  …   │                            │    │
│ [Import CSV][Img] │  └───────────────────────────────────────────────┘    │
```

## Preferences (⌘,)

```
┌ Editor │ Backend │ Views │ AI │ Export ┐
│ Appearance:  ( System | Light | Dark ) │
│ Editor font: ( Serif | Sans | Mono )   │
│ Font size:   [────●────] 17 pt         │
│ Line spacing:[──●──────] 1.50×         │
│ Preview:     The quick brown fox…      │
└────────────────────────────────────────┘
```
