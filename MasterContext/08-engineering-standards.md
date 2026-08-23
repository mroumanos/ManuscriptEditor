# 08 — Engineering Standards

## Code structure

- One responsibility per type; small, well-named types over large catch-alls.
- **Models** (`Models/`): plain `Codable`, `Sendable`, `Identifiable` value types.
  No UI, no store references.
- **Stores** (`Store/`): `@MainActor @Observable`. All mutation funnels through a
  single `touch`-style helper that stamps `updatedAt` and saves. Public mutators
  take `ref: VersionRef = .source`.
- **Services** (`Services/`): stateless utilities (caseless enums or structs).
  Pure logic, easy to test.
- **Views** (`Views/`, `Theme/`): SwiftUI; read stores via `@Environment`. Keep
  AppKit interop isolated in dedicated files (`Theme/RichTextEditor.swift`).

## Documentation (match the existing density)

- Every file opens with a header comment: what it is and the key design intent.
- Every type and every non-obvious method/property gets a doc comment explaining
  **why**, not just what. Call out invariants and platform quirks inline.
- When a decision is non-obvious (e.g. "TextKit 1 required on macOS 26"), leave a
  comment so the next person/LLM doesn't "fix" it back into a bug.

## Persistence & compatibility

- New model fields use `decodeIfPresent` (+ sensible default) so older
  `manuscript.json` files keep opening.
- Save atomically; never partially write the model.
- Treat the user's chosen folder as the source of truth; access it through the
  security-scoped bookmark.

## Testing

- The brief requires the app be "thoroughly documented and tested." Prioritize
  unit tests on pure logic that the data-integrity promise rests on:
  `DataService` (CSV parse RFC-4180 edge cases, SQL execution + errors),
  `WordCountService`, `ChecklistService`, `ViewConfig.from(journal:)`, and
  `Manuscript`/`RichText` Codable round-trips including legacy decode.
- UI is verified by building and running (see below); logic is verified by tests.

## Build & verify (do this every change)

```
cd ManuscriptEditor
xcodebuild -scheme ManuscriptEditor -destination 'platform=macOS' build
```

- A green build is necessary, **not sufficient**. For UI/behavior changes, run the
  app and look before claiming success. Launch:
  `open "$(xcodebuild -scheme ManuscriptEditor -destination 'platform=macOS' \
   -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2}/ FULL_PRODUCT_NAME /{n=$2}END{print d"/"n}')"`
- Report failures honestly with the actual output. If you can't verify (e.g. no
  screen access), say so rather than asserting it works.

## Known platform gotchas (hard-won — do not regress)

1. **TextKit 1 is required for the editor on macOS 26.** A default `NSTextView`
   uses TextKit 2, where the TextKit-1 `layoutManager` is `nil` and the line-number
   gutter silently draws nothing. Build an explicit stack: `NSTextStorage` →
   `NSLayoutManager` → `NSTextContainer`, then `NSTextView(frame:textContainer:)`.
2. **Don't override `NSRulerView.draw(_:)` without calling `super`.** It blanks
   the scroll view. To restyle, call `super` then overpaint, or avoid overriding.
3. **Height-pin horizontal `ScrollView`s** (e.g. the formatting toolbar). Unpinned
   they grow vertically and the AppKit text view can overlap the SwiftUI chrome.
4. **macOS top safe area is the title bar.** Don't pin the comparison tab bar with
   `.safeAreaInset(edge: .top)`; place it first in a `VStack`.
5. **`onChange(of:)` needs `Equatable`.** Model arrays whose element isn't
   `Equatable` → observe `array.map(\.id)`.
6. **Detail views must not set `.navigationTitle`** — only the manuscript name
   should appear as the window title.
7. **Lists: kill stray glass.** `.scrollContentBackground(.hidden)` + a solid
   semantic background, and `frame(maxHeight: .infinity)`, or the pane renders as
   a floating translucent card.
8. **Side-by-side panes** are the same content views parameterized by
   `versionRef`; give each pane `.id(ref)` so SwiftUI keeps their state distinct.
9. **`"\r\n"` is a single Swift `Character`.** Iterating a `String` (or
   `Array(text)`) yields grapheme clusters, so a CRLF never matches a `"\r"` or
   `"\n"` case — a character-level parser silently swallows every Windows/Excel
   line break (the CSV importer once globbed whole files into one giant row this
   way). Normalize `\r\n` → `\n` before parsing, or iterate unicode scalars.
10. **Text-view undo must be scoped to the view's lifetime.** `NSUndoManager`
    holds action targets *unretained*; an `NSTextView` (including the one
    backing SwiftUI's `TextEditor`) registers typing operations into the
    window's long-lived undo manager, and when the view is destroyed (row
    deleted, pane switched, identity churn) ⌘Z dispatches
    `_undoRedoTextOperation:` into freed memory (the issue-#8 crash). Every
    text surface must use a manager owned by its coordinator (delegate
    `undoManager(for:)`), cleared on `dismantleNSView` and on programmatic
    content reloads. **Never use raw SwiftUI `TextEditor`** — use
    `PlainTextEditor` (Theme/), which exists precisely for this.
11. **The app runs UNSANDBOXED** (`ENABLE_APP_SANDBOX = NO`) — deliberately.
    The sandbox blocked two must-haves: reading `/opt/homebrew` (so `gpg` was
    unreachable for the local-keyring dropdown) and reading `~/.gnupg` (grants
    don't inherit to child processes). Do not re-enable it casually: sandboxed
    and unsandboxed builds use **different data homes** (container vs real
    `~/Library`) and **different Keychain partitions** (items written by one
    are invisible to the other). `SandboxMigration.runIfNeeded()` (called
    before the stores load) does the one-time container → real-`~/Library`
    migration; `KeychainService.setSecret` recovers slots blocked by an
    inaccessible other-partition item (delete-then-add on
    `errSecDuplicateItem`). Sandbox-era Keychain secrets are unrecoverable —
    users re-enter them once.
12. **One `alert(item:)` per view *branch*, ancestors included.** Two alert
    modifiers on the same node: only the last fires (killed the Sync button,
    the ⏪⏩ sync buttons, and the Load buttons — three separate times). But
    the rule is broader: an `alert(item:)` on an **ancestor** suppresses one
    on a descendant the same way (the delete alert on JournalLineageCard's
    outer VStack silently ate the sync confirmations on `lineageTree`
    inside it). Attach each alert to its own node on **sibling branches** —
    never stack them, never nest them.

## Releasing

`scripts/release.sh <version> [notes-file]` runs the whole pipeline: bump
(MARKETING_VERSION + build number) → signed Release build (Developer ID,
hardened runtime, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` — a plain build
injects get-task-allow, which Apple rejects) → DMG with volume icon →
notarize + staple (keychain profile "notary") → commit/tag/push → GitHub
release (notes from the given file, else commit subjects since the last
tag) → Slack announcement (incoming webhook from the Keychain item
`ManuscriptEditor-slack-webhook`; skipped with instructions when absent).
Requires: clean tree on main, the Developer ID cert, `gh` auth.

## Working style for LLM contributors

- Start from this Master Context; don't infer requirements from a single recent
  message.
- Make the smallest change that satisfies the acceptance criteria; match
  surrounding patterns.
- Don't introduce dependencies. Build Phase I and Phase II per
  [`09-roadmap.md`](09-roadmap.md); **Phase III (automated submission, active
  collaboration) is stub-only** — don't build it.
- Update the relevant Master Context doc in the same change when a requirement
  shifts.
