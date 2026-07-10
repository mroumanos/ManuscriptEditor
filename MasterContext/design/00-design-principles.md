# 00 — Design Principles

> Foundational context for all UI design and implementation decisions in this
> folder. Product definition and domain live in the numbered Master Context docs
> ([`01-product-vision.md`](../01-product-vision.md),
> [`02-domain-model.md`](../02-domain-model.md)); this doc ranks the design
> principles that break ties when two good ideas conflict.

## 1. What shapes the design

Manuscript Editor is a native macOS, account-free app for writing one **Source**
manuscript and adapting it into per-journal **cuts** that each meet a target
journal's requirements. Three product facts dominate the design:

1. **Comparison is the signature surface.** Side-by-side journal panes are not a
   power feature bolted onto an editor — they are the reason the app exists.
   Every content surface must work when rendered 2–4 abreast.
2. **The checklist is the emotional core.** Users are format-anxious; rejection
   for formatting reasons is a real fear. Checks exist to convert that anxiety
   into visible, fixable, *live* green checkmarks.
3. **Nothing is hidden behind an account or a network.** Every feature works
   local-first; integrations (backends, AI, Zotero) are optional and degrade
   gracefully when absent.

## 2. Who the user is

Primary persona: **the academic researcher** — a domain expert, not necessarily
technical, producing documents judged by gatekeepers (reviewers, editors).

Traits that must shape the UI:

- **Deadline-driven and revision-heavy.** A manuscript goes through many rounds
  (advisor feedback, co-author edits, R1/R2, camera-ready) across several target
  journals. Versioning and lineage are core workflow, not power features.
- **Format-anxious.** See §1.2. Checks must always be current and never overstate
  freshness (e.g. the Sync pane's "sync it first" warning in
  [`05-features.md §F`](../05-features.md#f-lineage-cuts-sync--rollback)).
- **Keyboard-fluent but not developer-fluent.** Comfortable with ⌘ shortcuts and
  find-and-replace; do **not** assume comfort with git concepts, regex, or
  terminals. Git-grade power (versions, lineage, sync) must be delivered through
  non-git vocabulary (§4).
- **Long sessions.** Multi-hour writing sessions are normal. Visual fatigue,
  focus preservation, and save reliability matter more than onboarding flash.
- **Works with co-authors asynchronously.** Notes are the feedback channel;
  real-time collaboration is Phase III (stub only).

## 3. Design principles (ranked)

When principles conflict, the lower number wins.

1. **The manuscript is the interface.** Content panes occupy the visual center
   and fill their space — never a shrunken, centered card. Every toolbar, popover,
   and panel is subordinate: collapsible, dismissible, and never modal over the
   text without an explicit user action.

2. **Never lose a word.** Saving is explicit (**Save** / **Save new version**)
   and unsaved state is loudly visible (the unsaved-changes banner). Everything
   destructive is soft or double-confirmed with a plain-language description of
   what will be lost: rollback **soft-archives** (never hard-deletes), version
   delete is leaf-only, sync warns before overwriting a working head and names
   the exact snapshot it will copy.

3. **State is always visible and always nameable.** At a glance the user can
   answer: *Which journal and version is this pane? Is it the working head or an
   older version? Are there unsaved edits? Do Checks pass for this journal?*
   Delivered by: color-coded tab chips (panes render below them in tab order),
   per-pane version control (`v3 ▾`), "(older)" badges, the unsaved banner, and
   the Checks summary. No hidden modes.

4. **Progressive disclosure over feature density.** A new user sees a writing
   app: sidebar + editor. The journal machinery (Sync, Checks, Export, Versions,
   lineage) lives in its own sidebar section and appears on demand. A power user
   finds everything within two interactions.

5. **Trust through predictability.** Checks are deterministic and **derived, not
   stored** — they can never go stale. Exports are deterministic: same version +
   same outline ⇒ same package. Reference tokens re-render automatically and
   render `[?]` rather than posing a stale number as live. Sync status never
   overstates freshness.

6. **Fast on real manuscripts.** The reference scale is 10k–40k words, 3–6
   versions per journal, dozens of figures/references
   ([`10-performance-plan.md`](../10-performance-plan.md)). Budgets: < 8 ms
   main-thread work per keystroke, saves < 50 ms off-main, launch-to-editable
   < 500 ms, checks live within 150–250 ms. The keystroke path must be O(edit),
   not O(document). If an operation must take longer, show progress and keep the
   editor interactive.

## 4. Vocabulary (binding)

Canonical terms live in [`glossary.md`](../glossary.md) — journal, Source, cut,
version, working head, lineage, sync, rollback, view, requirements, checks, note,
data asset. Use them in UI copy, code comments, and docs. Do not introduce
synonyms; in particular:

| Never say (user-facing) | Say instead |
|---|---|
| commit, save point, snapshot (noun) | **version** ("Save new version") |
| branch, fork, variant | **cut** / **journal** |
| merge, fast-forward, HEAD, checkout | **sync**, **working head** (internal docs may say "git-style") |
| diff | **comparison** / "side-by-side" |
| ruleset, linter | **requirements**, **checks** |
| template (for output structure) | **view** / **export outline** |
| project, file (for the whole) | **manuscript** |

"Snapshot" is acceptable as a verb of explanation ("Save new version snapshots
the working content") but never as an object name in UI.

## 5. Scope guardrails

Phasing is defined in [`09-roadmap.md`](../09-roadmap.md): Phase I is manual,
local editing **including export**; Phase II adds AI adaptation + backend
save-and-share; Phase III (submission/publishing, live collaboration) is
stub-only — visible, disabled, honest. Design no UI hooks for: real-time
multiplayer editing, a reference-manager rebuild (Zotero connects instead),
grammar/AI rewriting inside the editor, mobile layouts, or plugin marketplaces.
