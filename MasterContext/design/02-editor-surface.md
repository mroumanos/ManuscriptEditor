# 02 — Editor Surface Design

> The prose editor is where users spend most of their time; it gets the strictest
> quality bar. Feature acceptance criteria live in
> [`05-features.md §I`](../05-features.md#i-rich-text-editing) (rich text) and
> [`§P`](../05-features.md#p-in-text-references-implemented) (reference tokens);
> platform gotchas (TextKit 1) in
> [`08-engineering-standards.md`](../08-engineering-standards.md).

## 1. The editor stack (top to bottom, inside each pane)

1. **Slim pane header**: live word count on the right, plus the per-journal
   section-activation eye and notes. No item title — the sidebar selection
   names it; sections rename via the sidebar context menu.
2. **Inline formatting toolbar** (`.bar` background), aligned to the text column:
   B / I / U / S / superscript / subscript │ align L/C/R/justify │ bulleted list.
   Fixed height (~36 pt). The longer-term control target is the reference image
   in [`06-design-system.md`](../06-design-system.md#visual-references) — treat it
   as a visual target, not a Phase I checklist.
3. **Width ruler**: tick marks + draggable handle setting the wrap column; its
   origin aligns with the first text glyph. Drag tracks locally and commits on
   release — never relayouts every open editor per mouse-move.
4. **Text area**: fixed-width wrap column (page-like) on a `.textBackgroundColor`
   surface, with a **line-number gutter** numbering visual (wrapped) lines,
   vertically aligned to each row; blank lines numbered too.

All four align to one shared constant set (`EditorLayout`: gutter width, text
inset, derived `leftInset`). Misalignment between gutter, ruler, toolbar, and
header is a bug.

## 2. Typography is the user's, format is the journal's

- Editor typography (family Sans/Serif/Mono, size 13–22 pt default 17, line
  spacing 1.0–2.5× default 1.5×) is a **global reading preference**
  (`EditorTypography`), shared by every editor pane, never stored in content.
- Final output typography comes from the journal's **export outline**
  ([06-export.md](06-export.md)). The editor is for *writing comfort*; the
  package is for *journal fidelity*. Never conflate the two, and never offer a
  control that writes presentation into the document that export can't
  reproduce.
- **Paste strips source formatting**: pasted text is re-set in the editor's
  default format, preserving only inline emphasis (B/I/U/S, super/subscript) and
  reference tokens from sibling sections; images/attachments are dropped.

## 3. Reference tokens are objects, not text

- Typing **`/`** at a word boundary opens the reference autocomplete
  (bibliography entries, figures, tables; filter-as-you-type). `/` mid-word
  ("and/or", DOIs) must not trigger; no matches → no dropdown.
- An accepted token is an **atom** carrying identity in its link attribute
  (`cite://` / `figref://` / `tabref://`); the visible text (`[1]`, "Figure 2")
  re-renders automatically when numbering or the target changes. Tokens are
  never character-editable.
- **Hover** shows a details card (~0.25 s); **click** opens the token menu
  (details, citation-style choice per token, Remove).
- Broken bindings render **`[?]`** — a stale number must never pose as live, and
  the failure is visible in place, never silent.

## 4. Typing experience — hard requirements

- < 8 ms main-thread work per keystroke at the reference scale (00 §3.6); the
  keystroke path is O(edit), not O(document) — no full-document re-archiving,
  re-encoding, or re-tokenizing per keystroke
  ([`10-performance-plan.md`](../10-performance-plan.md) is the enforcement
  plan).
- Background work (persistence, checks recompute, token renumbering in other
  panes, thumbnails) may never steal focus, move the caret, scroll the viewport,
  or reflow the block being typed in.
- Renumbering elsewhere in the document is fine; the paragraph under the caret
  is sacred mid-keystroke.
- Never show a modal during typing; save problems surface in the banner, not a
  dialog.

## 5. Notes (highlight-to-comment)

- Selecting prose surfaces a small action popover (edit / **add comment** /
  react). Adding a comment anchors a **note** to the range and opens the notes
  panel beside the content, showing author + timestamp.
- Notes are feedback, not edits: they never alter text, have their own
  resolve/reopen lifecycle, and stay visible while comparing journals
  side-by-side. Resolved notes hide by default, recoverable via filter.
- Note anchors in the margin/gutter stay subtle — small marks, not highlights
  that fight the text for attention.

## 6. What the editor must never do

- Never autocorrect content words or rewrite grammar (AI revision is an explicit
  opt-in flow, Phase II — never ambient in the editor).
- Never let one pane's edits leak into another journal's content — a pane writes
  only to its own journal's working head.
- Never lose selection or caret position because of a background process.
- Never grow the toolbar into overlapping the text (height-pin horizontal
  scrollers) or let the gutter show stray borders / misaligned numbers.
- Never block a keystroke on disk I/O.
