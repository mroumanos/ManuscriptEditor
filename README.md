# Manuscript Editor

A native macOS, **account-free** desktop app for scientific writing: maintain one
**source** manuscript and adapt it into journal-specific **cuts** that each meet a
target journal's requirements — word limits, required sections, citation style,
export format — with side-by-side comparison, deterministic submission checks,
and a complete export package per journal.

- **One source of data.** Raw data (CSV → SQLite, images) is imported once and
  referenced by figures/tables via SQL — a cut re-expresses presentation, never
  the data.
- **Journals, versions, lineage.** Every journal (including the Source) has its
  own save-point history; lineage edges track which version each cut derives
  from, with explicit per-edge sync and rollback.
- **Live checks.** Each journal's requirements render as a live pass/fail
  checklist, comparable side-by-side like any content pane.
- **Submission packages.** Per-journal export outlines produce PDF / DOCX / RTF /
  LaTeX documents plus figure files — everything needed to submit.
- **No account, no cloud, no telemetry.** Manuscripts are folders on your disk.
  Storage backends and AI services are optional bring-your-own integrations.

## Documentation

The complete product and engineering documentation lives in
[`MasterContext/`](MasterContext/) — start at its
[README](MasterContext/README.md). It covers the product vision, domain model,
architecture, feature acceptance criteria, design system, and engineering
standards.

## Distributions

Compiled builds are published on this repository's
[Releases](../../releases) page as zipped `.app` bundles. Requirements:
macOS 26 (Tahoe) or later. Release binaries are currently unsigned — see
[RELEASING.md](RELEASING.md) for how they are produced.

Release downloads are provided for personal evaluation only (see License).

## Building (copyright holder / authorized contributors only)

```
cd ManuscriptEditor
xcodebuild -scheme ManuscriptEditor -destination 'platform=macOS' build
```

No third-party dependencies; the project builds with Xcode alone.

## License

**All rights reserved.** This repository is source-visible for viewing only —
no reuse, copying, modification, redistribution, or incorporation into other
work (including ML training) is permitted. See [LICENSE](LICENSE).
