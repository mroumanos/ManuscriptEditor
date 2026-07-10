# Assets — visual references

> **Real reference images live in [`../examples/`](../examples/)** and are already
> embedded in the docs (design system, features, domain model, IA). This folder
> is for any *additional* screenshots/mockups you capture. When you add one, embed
> it from the relevant doc.

Current `examples/`: `text-editing-bar`, `text-width-ruler`, `line-numbering`,
`text-highlight-add-notes`, `text-highlight-with-notes`, `banner-for-unsaved-content`,
`lineage-compressed`, `lineage-management`, `lineage-detailed`.

Drop reference images here and link them from the docs (especially
[`../06-design-system.md`](../06-design-system.md) and
[`../07-wireframes.md`](../07-wireframes.md)). Markdown image embeds render in
most editors:

```markdown
![Abstract editor, side-by-side](assets/editor-side-by-side.png)
```

I cannot generate binary images from here, so this folder ships with the
**specifications and ASCII wireframes** instead; add real screenshots/mockups as
you capture them.

## Suggested files to add

Capture these from a running build (light *and* dark) so the visual target is
unambiguous:

- `editor-side-by-side.png` — a Content item (e.g. Abstract) with Source + one
  cut open, showing colored tabs, title capsules, toolbar, width ruler, gutter.
- `versions-lineage.png` — the Versions panel lineage tree + a selected version's
  requirements/checklist.
- `data-csv-sql.png` — a CSV data asset with the SQL editor and result grid, and
  a figure bound to it as a chart.
- `preferences-editor.png` — Preferences → Editor (theme + typography + preview).
- `empty-state.png` — a list empty state with the centered "Add …" action.
- `light-dark.png` — the same screen in light and dark, side by side.

## Design inspiration

- **Untitled UI "Book profile"** (the cited north-star for clean editorial
  typography and layout): https://dribbble.com/shots/25828599-Book-profile-Untitled-UI
  Save a snapshot here as `inspiration-untitled-ui.png` for offline reference.

When adding an image, also add a one-line caption in the doc that references it so
its intent is clear (what to copy: spacing, hierarchy, type, color — not
necessarily literal colors).
