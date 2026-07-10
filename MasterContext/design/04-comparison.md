# 04 — Side-by-Side Comparison Design

> The signature surface: multiple journals rendered as parallel, *editable*
> panes. This is comparison-by-juxtaposition (not a textual diff view — none is
> planned; don't design hooks for one). Acceptance criteria:
> [`05-features.md §G`](../05-features.md#g-side-by-side-comparison--editing).

## 1. What comparison is here

Selecting any **Content** item (or **Checks**) with ≥1 journal tab open splits
the detail into one pane per open journal — Source and cuts as **comparable
peers** sharing the same component set, so panes line up item-for-item. Each
pane is a full editor for its journal, not a preview.

## 2. Pane identity (the user always knows which is which)

- Every pane carries its journal's **color** on the title capsule, matching its
  tab chip. Colors key to the `VersionRef`, never tab position, so closing one
  tab never recolors the rest.
- The capsule names the content item; the per-pane version control shows the
  version (`v3 ▾`) and its Save / Save new version / roll back-forward actions,
  scoped strictly to that pane's journal.
- Older (non-head) versions are visibly marked "(older)" in the tab; a pane
  showing an older version must read as an archive view, not the working head.

## 3. Layout rules

- Panes split the width **evenly** with a `minWidth` (~360). Beyond the width
  budget, horizontal scrolling of panes beats shrinking any pane below its
  comfortable measure (00 §3.1).
- Panes are visually parallel: identical stack order (capsule → toolbar → ruler
  → gutter → text), identical editor typography (it's a global preference), so
  the eye can jump horizontally between the same element in each pane.
- Word counts sit in the same place in every capsule — cross-pane word-count
  comparison ("Abstract: 214 vs 148") is a primary use, so make the numbers
  scannable at a glance.

## 4. Synced navigation, independent editing

- **Navigation is shared**: one sidebar selection drives all panes ("click
  Methods, every pane shows Methods"). No per-pane navigation state.
- **Editing is isolated**: typing in a pane writes only to that journal's
  working head. Scroll positions and carets are per-pane.
- **Checks compares like content**: with Checks selected, each pane shows its
  own journal's live checklist — the "is my cut compliant while the Source
  isn't?" view is a first-class comparison, laid out exactly like Abstract.

## 5. Performance & stability

- Side-by-side multiplies every cost by the pane count: an edit in one pane
  must not re-render the others beyond what actually changed
  ([`10-performance-plan.md`](../10-performance-plan.md) P1 observation
  granularity).
- Token renumbering triggered in one pane updates sibling panes asynchronously
  — never stalling the pane being typed in (02 §4).
- Opening/closing a tab animates the split calmly; surviving panes keep their
  scroll positions, carets, and colors.
