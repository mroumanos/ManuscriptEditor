# 06 — Export Design

> Getting the manuscript out as a complete **submission package** with
> predictable fidelity. Acceptance criteria and implemented shape:
> [`05-features.md §M`](../05-features.md#m-export--the-submission-package-phase-i--build-now).
> Export is Phase I; auto-submission is Phase III (stub only).

## 1. The mental model

Export targets **one journal at its working head** (Source exports the live
manuscript) and produces a **folder, not a file**: every document in the
journal's export outline, plus copied figure images whenever a document includes
the figures block — everything needed to submit online, self-contained. The
export pane must state plainly *which journal and version* is being exported.

## 2. The export outline editor

Every journal (and Source) has a per-journal `ExportConfig` shown as a **stacked
list of document cards**:

- **Card header** owns page geometry: file type (PDF / DOCX / RTF / LaTeX),
  margins, single vs two-column. No document-level typography row — all
  typography lives per item.
- **Item rows** (title block, abstract, keywords, body sections by name,
  figures, tables, references, cover letter, page breaks) are draggable to
  reorder (three-line grab handle), removable, and renameable — clicking the
  item name renames its exported heading.
- **Per-item overrides as aligned columns** — Font · Size · Spacing · Lines —
  with inline controls showing each item's *effective* format; editing a value
  creates that item's override; right-click → "Reset Formatting to Document".
  Alignment across rows is what makes the format scannable — treat column
  misalignment as a bug.
- The outline is direct manipulation, not a form: the card stack should read
  top-to-bottom as "this is the package I will get."

## 3. Preflight (design guidance)

Before writing the package, surface the journal's current **Checks** state in
the export flow using the same check-row component as the Checks pane (05 §2) —
one visual language for "what's blocking submission". Failures never silently
block: the user sees what fails, can jump to fix it, and can still export
anyway (their deadline may win). Anything the chosen format cannot represent is
**declared before export, never silently dropped**.

## 4. The export flow

1. User picks the destination folder (the only dialog the happy path needs).
2. Package assembly runs **off the main thread with progress**; the editor
   stays live. Progress names the phase honestly ("Rendering PDF · page 12/40")
   once an operation exceeds ~1 s (07 §5).
3. On completion, **reveal the package in Finder**. On failure, the error names
   the file path and the reason, offers retry, and never loses the options the
   user set.

Re-exporting after a revision cycle is the hot path: with an outline already
configured, it should be click → progress → Finder, with no re-deciding.

## 5. Determinism & fidelity rules

- Same version + same outline ⇒ the same package. Citation tokens re-render
  through `RefEngine` at export, so numbering in output always matches the
  editor — the editor is the preview.
- Headings get a blank line before/after and are capitalized by default
  (including renamed titles), identically across attributed output and LaTeX.
- Prose is re-set in the document's font while preserving inline emphasis —
  editor typography (a reading preference) never leaks into the package.
- PDF pagination is deterministic (custom CoreText paginator honoring margins,
  page breaks, columns, continuous line numbers). No third-party dependencies.
- HTML/plain remain in the legacy ⌘E sheet until folded into outlines; don't
  present them as outline-quality output.
