# CLAUDE.md

**Read [`MasterContext/00-master-prompt.md`](MasterContext/00-master-prompt.md)
before doing anything in this repo.** It is the condensed source of truth for
what this app is and how to build it, and it links to deeper docs. Do not infer
requirements from a single recent message — start from the Master Context.

## What this project is

**Manuscript Editor** — a native macOS, **account-free** desktop app for writing
one **source** scientific manuscript and adapting it into journal-specific
**versions ("cuts")** that each meet a target journal's requirements. Raw data
lives once in a central **Data** repository and is referenced by figures/tables
via SQL, so a cut re-expresses presentation, not data.

## Where things are

- **Requirements & design:** [`MasterContext/`](MasterContext/) — start at its
  [`README.md`](MasterContext/README.md).
  - Schema → [`02-domain-model.md`](MasterContext/02-domain-model.md)
  - Architecture → [`03-architecture.md`](MasterContext/03-architecture.md)
  - Navigation / where each feature lives → [`04-information-architecture.md`](MasterContext/04-information-architecture.md)
  - Acceptance criteria → [`05-features.md`](MasterContext/05-features.md)
  - Visual bar → [`06-design-system.md`](MasterContext/06-design-system.md) and [`07-wireframes.md`](MasterContext/07-wireframes.md); deep design/UX context → [`design/`](MasterContext/design/)
  - Standards + platform gotchas → [`08-engineering-standards.md`](MasterContext/08-engineering-standards.md)
- **Source code:** `ManuscriptEditor/ManuscriptEditor/` (`Models/`, `Store/`,
  `Services/`, `Views/`, `Theme/`).

## Build & verify (every change)

```
cd ManuscriptEditor
xcodebuild -scheme ManuscriptEditor -destination 'platform=macOS' build
```

A green build is necessary but not sufficient: for UI/behavior changes, run the
app and look before claiming success, and report honestly if you can't verify.

## Working rules (summary — full list in the Master Context)

- Native macOS, **no third-party dependencies**, account-free, local-folder
  storage. Don't add packages or build Phase 2 systems (real backend sync, AI
  calls, export, publishing) without explicit approval — stub them honestly.
- Preserve backward-compatible decoding: older `manuscript.json` files must still
  open (`decodeIfPresent` for new fields).
- Match the surrounding code's documentation density; document the *why*.
- Heed the known platform gotchas (e.g. **TextKit 1 is required** for the editor
  on macOS 26) in [`08-engineering-standards.md`](MasterContext/08-engineering-standards.md).
- **When a requirement changes, update the relevant `MasterContext/` doc in the
  same change** so the docs never drift from the code.
