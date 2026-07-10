# 05 — Checks Design

> The live, per-journal requirements checklist — the surface that converts
> format-anxiety into visible, fixable state (00 §1.2). Acceptance criteria:
> [`05-features.md §J`](../05-features.md#j-checks-live-per-journal-comparable);
> requirements model: [`02-domain-model.md`](../02-domain-model.md); submission
> profiles (article types): [`05-features.md §D2`](../05-features.md#d2-submission-profiles-article-types).

## 1. Model recap (what the UI renders)

Checks evaluate a journal's content against **that journal's**
`JournalRequirements` (word/abstract limits, required sections present &
non-empty, figure/table/reference counts, custom rules) via the active
submission profile. Three properties are load-bearing for the design:

- **Deterministic.** Same content + same requirements ⇒ same results. No ML
  scoring, no network at check time. Custom free-text rules are user-checkable
  items, honestly presented as such.
- **Derived, not stored.** Results recompute from current content on demand, so
  they can never go stale. The UI never caches a result where it could show a
  live one.
- **Live.** Edit a journal over its word limit and the check flips to ✗ without
  a refresh; cut words and it returns to ✓. Recompute is debounced 150–250 ms —
  still "live" to the eye, never on the keystroke path.

## 2. The checklist pane

Structure, top to bottom:

1. **Summary banner** — the single ready/attention verdict ("Ready to submit" /
   "3 items need attention"), in `positive`/`warning` color with a glyph, never
   color alone. This banner is the payoff; it must be the first thing the eye
   lands on.
2. **Check rows** — one per requirement: state glyph (✓ pass / ✗ fail), title,
   and — when failing — the **measured value vs. the limit**, right-aligned:
   `Abstract: 291 / 250 words`. A red X without the numbers is a design bug:
   failures show *why* and *how far off*, never just that they failed.
3. Passing rows stay visible but quiet (successes are confirmatory, not noise);
   failures sort/stand out first.

Row identity must be **stable across recomputes** (derived from the rule, not a
fresh UUID) so rows don't churn focus or animate on every keystroke.

## 3. Comparable, like content

With multiple tabs open and **Checks** selected, the detail renders one
checklist pane per open journal — each against its own journal's requirements
(the Source pane — whose own requirements are empty defaults — shows an
explanatory state pointing at the journal tabs; no picker). Selectable and
navigable exactly like the Abstract page. This is the "which of my cuts is
submittable?" dashboard.

## 4. Fix-forward

- Every failing check should lead the user toward the fix: length checks name
  the offending component; required-section checks name the missing/empty
  section. Where navigation is possible, clicking a failure takes the user to
  the evidence without dialogs (01 §5).
- Length failures pair naturally with the live word counts already shown in the
  sidebar and pane headers — the user watches the number fall as they cut, and
  the check flips green the moment they're under. Preserve that feedback loop;
  never require a manual re-run.
- Requirements **editing** lives in the Journals settings, not in Checks. The
  Checks pane may link there ("Edit requirements…") but never embeds the editor.

## 5. Empty & edge states

- Journal with no requirements configured: one-sentence explanation + "Edit
  requirements…" action — teach the model, don't show an empty list.
- Custom rules the app can't evaluate automatically are rendered as manual
  checklist items with a checkbox — honest about what's user-judged versus
  machine-verified.
- Export should surface check state before packaging ([06-export.md §3](06-export.md))
  using this same check-row component, so the user meets one visual language for
  "what's blocking submission" everywhere.
