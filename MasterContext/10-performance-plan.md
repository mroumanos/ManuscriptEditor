# 10 — Performance & Smoothness Plan

Produced by a multi-agent audit (6 subsystem scanners over every source file,
then adversarial verification of each significant finding against the actual
code path). 13 findings **confirmed** by verifiers; ~40 more were identified by
scanners but their verification pass was cut short — those are listed as
*pending verification* and should be re-checked when picked up.

Scale assumption throughout: a real manuscript — 10k–40k words, 3–6 versions
(each embedding a full content snapshot with RTF blobs), dozens of
figures/references.

## The one sentence that matters

**Every keystroke currently JSON-encodes the entire manuscript (source + all
version snapshots, base64 RTF, pretty-printed) and writes it to disk
synchronously on the main thread — after also re-archiving the whole document
to RTF and invalidating every SwiftUI view that reads the store.** Fixing this
single pipeline (P0) removes the dominant source of typing latency and jank.

## P0 — The keystroke hot path (do first, in order)

1. **Debounce persistence** (`ManuscriptStore.touch` → `trySave`, ManuscriptStore.swift).
   `touch()` only mutates + marks dirty; a cancel-and-restart `Task` saves after
   ~1s idle. Keep **immediate** saves for structural/rare ops (create/delete
   version, imports, section add/delete/move) and add **flush hooks**:
   `NSApplication.willTerminateNotification`, scenePhase leaving `.active`,
   window close. Trade-off: ~1s crash-loss window, bounded by the hooks.
   *(confirmed HIGH, effort M)*
2. **Move encode+write off the main actor** (PersistenceService.save).
   `Manuscript` and `PersistenceService` are `Sendable`: snapshot the value,
   encode+write in a detached task (single in-flight + rerun-pending bit,
   last-writer-wins), hop back to set `lastSaved`/`saveError`.
   *(confirmed HIGH, M)*
3. **Drop `.prettyPrinted`/`.sortedKeys`** from the save encoder — machine-read
   file; ~30–40% smaller/faster. Decoding is unaffected (backward compatible).
   *(confirmed MEDIUM, S)*
4. **Stop re-archiving RTF per keystroke** (RichTextEditor `textDidChange`).
   Keep `plain` updated per keystroke, defer `storage.rtf(...)` to the same
   debounce (coordinator-side timer) or to focus-loss; flush before save.
   Careful with undo/binding semantics — do as its own change. *(confirmed HIGH, M)*
5. **Cheap `RichText` equality** — compare `plain` (+ rtf count) instead of
   byte-for-byte `Data` compares in `onChange`/Equatable. *(low, S)*

## P1 — Observation granularity & data shape

6. **Whole-store invalidation**: one `manuscript` property means every reader
   re-renders per keystroke (sidebar word counts, all panes, tab bar…).
   Mitigations in increasing ambition: (a) make leaf views read the narrowest
   derived values; (b) cache expensive derivations (word counts) behind a
   revision token; (c) split hot content (per-section text) into a small
   side-store keyed by section id, synced into `Manuscript` on save.
   *(confirmed HIGH, M–L; design carefully before coding)*
7. **Version snapshots multiply everything** (`ManuscriptVersion.content` = full
   `Manuscript`): save/load cost scales ×(versions+1). Plan: persist versions as
   **separate files** (`versions/{id}.json`) loaded lazily; keep top-level
   `manuscript.json` small. Needs a backward-compatible migration (read old
   embedded form; write split form). *(confirmed HIGH, L — pairs with the
   Journal/Version/Lineage migration in 09-roadmap)*
8. **Word counts re-tokenize on every access** (`Manuscript.bodyWordCount`,
   `ManuscriptSection.wordCount`): cache count per `RichText` (computed when
   `plain` changes) or memoize by revision. *(confirmed MEDIUM, S)*
9. **Startup**: async-load the manuscript (show a lightweight skeleton) instead
   of synchronous decode on the main actor; `listManuscripts()` should read a
   tiny index (id/title/date sidecar) instead of decoding every full file.
   *(confirmed MEDIUM, M / partial LOW, S)*

## P2 — Editor internals

10. **Line-number ruler** forces layout + enumerates all fragments from 0 each
    draw: cache (charIndex → line number) checkpoints, invalidate on edit,
    enumerate only the visible range. *(partial MEDIUM, S–M)*
11. **Width-ruler drag** writes `@AppStorage` per mouse-move → every open
    editor relayouts its full document per tick: track drag in local `@State`
    (`@GestureState`), commit on `.onEnded`. *(confirmed MEDIUM, S)*
12. **updateNSView full-string compare** (`value.plain != textView.string`)
    per SwiftUI render (pending verification): replace with a revision/dirty
    token on the binding; on genuine external reload, preserve selection.

## P3 — Views & services (mostly S effort, verification pending unless noted)

- **Figure thumbnails / editors / data images**: `NSImage(contentsOf:)` decodes
  synchronously in `body` with no cache — load async + downsample
  (`CGImageSourceCreateThumbnailAtIndex`) into a small in-memory cache.
- **SQLite & CSV**: run queries/imports off the main thread; wrap CSV row
  inserts in a **single transaction**; paginate result grids (render first N
  rows).
- **Export**: assemble/write the package off the main thread with progress;
  dedupe the duplicated flow between `ExportView` and `ExportSheet`.
- **Checks/Checklist**: `ChecklistResult` gets fresh `UUID()`s each run → row
  identity churn (animations, focus): derive stable ids from the rule; debounce
  recompute (still "live" at 150–250ms).
- **Draft-editor cascades**: `onChange(of: draft.X)` chains fire on row switch
  causing redundant store writes (bibliography/tables/journals/requirements) —
  guard with `draft != saved` or an `isLoading` flag.
- **Zotero bulk import**: one `touch` per entry → N full saves; add a batch add.
- **Stable pane colors**: key journal colors to the `VersionRef` (not tab
  index) so closing a tab doesn't recolor every pane.
- **WordCountService.countStripped**: precompile the 5 regexes (static).
- **Custom-rules ForEach keyed by index** (JournalsView): key by stable element
  identity to stop focus loss on delete.
- Welcome screen decodes every manuscript fully (see #9); `⌘S` handler does a
  synchronous full save (route through the async saver); notification-based
  menu commands → `@FocusedValue`-based commands (cleaner, per-window).

## P4 — Measurement (do alongside P0)

- Add `os_signpost` intervals: save-encode, save-write, RTF-archive, checklist
  run, thumbnail decode. Profile with Instruments (Time Profiler + os_signpost).
- Create a **large-doc fixture** (40k words, 6 versions, 30 figures) and a perf
  smoke test: typing latency < 8ms main-thread work per keystroke; save < 50ms
  off-main; launch-to-editable < 500ms.

## Sequencing

| Order | Items | Effort | Outcome |
|---|---|---|---|
| 1 | P0.1–3 (+P4 signposts) | ~1 day | Typing no longer hitches; saves invisible |
| 2 | P0.4–5, P2.11 | ~1 day | Keystroke cost O(keystroke), not O(document) |
| 3 | P1.8, P3 quick wins (thumbnails, transactions, stable ids, colors) | 1–2 days | Smooth lists, stable identity |
| 4 | P1.6 observation granularity | 2–3 days | Side-by-side stays fluid on big docs |
| 5 | P1.7 split version files (with the Journal migration) | with migration | Scale to many cuts |

**Standing rule:** treat regressions against this plan as bugs; new features
must not add work to the keystroke path (anything per-keystroke must be O(edit),
not O(document)).
