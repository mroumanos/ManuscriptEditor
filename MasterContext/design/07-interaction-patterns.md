# 07 — Interaction Patterns

> Cross-cutting behavior: keyboard, focus, saving, undo, latency, accessibility,
> errors. These patterns bind every surface in docs 01–06. macOS-native
> throughout: menu bar, ⌘ shortcuts, VoiceOver, standard focus behavior.

## 1. Keyboard model

The app must be fully operable without a mouse, through standard macOS means:

- **Menu bar is the command surface.** Every user action exists as a menu item
  (with its shortcut shown), which also makes it discoverable via Help search.
  Hover-only or drag-only affordances (inline delete, reorder) need menu or
  button equivalents.
- **Global:** ⌘N new manuscript · ⌘S save (routes through the async saver — no
  synchronous full save) · ⌘, preferences · ⌘F find · `Esc` de-escalates one
  level per press (popover → panel/sheet → transient state).
- **Editor:** standard rich-text bindings (⌘B/I/U, shift-⌘V paste variants as
  provided); `/` at a word boundary opens the reference autocomplete; Return/Tab
  accepts, `Esc` dismisses leaving exactly what was typed.
- Prefer `@FocusedValue`-based menu commands over notification plumbing so
  commands act on the right window.

## 2. Focus discipline

- Exactly one focus owner at all times; keyboard focus always visibly ringed
  (system behavior — don't suppress it).
- **Background work never steals anything**: persistence, checks recompute,
  token renumbering, thumbnail loads, and export rendering may not move focus,
  scroll a viewport, open UI, or drop a selection (02 §4). Results wait in
  their panes until the user looks.
- Opening a panel/popover does not take focus from the editor unless the user
  invoked it to interact with it; closing any surface returns focus to its
  previous owner.
- List edits must not churn focus: stable row identity (no index-keyed
  `ForEach` on mutable lists, no fresh UUIDs per recompute).

## 3. Saving & data safety (implements 00 §3.2)

- **Explicit save is the user model:** Save / Save new version, surfaced in the
  per-pane version control, ⌘S, and the unsaved-changes banner. There *is* a
  dirty state, and it is honestly visible — never a mystery.
- **Persistence is debounced and off-main** (~1 s idle), with immediate saves
  for structural operations and flush hooks on quit, deactivation, and window
  close ([`10-performance-plan.md`](../10-performance-plan.md) P0). The ~1 s
  crash-loss window is bounded by those hooks.
- **Failure is loud:** a failed write surfaces a persistent, clickable
  explanation (banner-level, red), never a silent retry loop or a toast that
  auto-dismisses. Nothing typed is discarded while the user resolves it.
- Writes are atomic (write-temp-then-rename); older `manuscript.json` files
  always continue to open (backward-compatible decoding).

## 4. Undo model

- Standard `NSTextView`/AppKit undo within each editor pane, per journal;
  accepted reference tokens, formatting, and paste each undo as discrete steps.
- Model-level operations follow the one-of rule (03 §5): **exactly one of
  {undoable, confirmed}** per action. Version stamping is cheap and safe (no
  confirmation); rollback/sync/delete are confirmed with concrete consequences.
- A background process must never collapse or split the user's undo history.

## 5. Latency & feedback ladder

| Duration | Treatment |
|---|---|
| < 100 ms | Just do it; no indicator |
| 100 ms – 1 s | Inline micro-progress in the affected component |
| > 1 s | Determinate progress with honest phase names ("Rendering PDF · page 12/40"); editor stays interactive |
| Indeterminate (network, Zotero) | Show what still works meanwhile; offer cancel; degrade gracefully offline |

Budgets from 00 §3.6: < 8 ms main-thread keystroke work, saves < 50 ms
off-main, launch-to-editable < 500 ms, checks live at 150–250 ms. Perceived
performance: optimistic UI for row-level actions, progressive rendering for
long lists, and **never block the keystroke path** — treat regressions as bugs
(the standing rule in [`10-performance-plan.md`](../10-performance-plan.md)).

## 6. Accessibility (non-negotiable)

- Full keyboard operability (§1) and visible focus (§2) are the foundation.
- Contrast: manuscript text ≥ 7:1; UI text ≥ 4.5:1; non-text indicators ≥ 3:1 —
  in both themes. Semantic system colors get most of this free; verify the
  journal palette's tab chips against their backgrounds in both themes.
- **Color is never the only channel:** check state pairs color with ✓/✗ glyphs;
  sync drift pairs orange with explanatory text; journal identity pairs color
  with the journal name on the tab chip.
- VoiceOver: panes are named regions ("NEJM — Abstract, v2"); check results
  read as "failed, Abstract, 291 of 250 words"; token hover-cards have
  accessible equivalents (the `.toolTip` fallback stays). Announce check-count
  and save-state changes politely and throttled.
- Respect system Reduce Motion (opacity steps instead of slides/pulses) and
  text-size scaling in chrome.

## 7. Error & empty states

- Errors state what happened, what was and wasn't affected, and one next
  action ("Export failed — the destination is not writable. Your manuscript is
  unaffected. [Retry]"). No raw error text in primary copy; a "details" fold
  may carry it.
- Empty states teach the model in one sentence + one action (component
  standards in [`06-design-system.md`](../06-design-system.md#components)). The
  Zotero/backends surfaces state clearly when the external service is
  unavailable, without blocking anything local.
- Modals exist only for: destructive confirms, file pickers, and flows needing
  commitment (Add Journal). Information never blocks in a modal.

## 8. Settings philosophy

Few, consequential, clearly scoped. Every setting names its scope — **global**
(Preferences ⌘,: appearance, editor typography, backends, AI services, views)
vs **per-manuscript** (Settings sidebar item: active backend, source view, AI)
vs **per-journal** (requirements, export outline, in Journals) — matching the
"where each capability lives" table in
[`04-information-architecture.md`](../04-information-architecture.md). View
state (open tabs, pane sizes, wrap width) is remembered automatically, not a
setting. When in doubt: good default, no setting.
