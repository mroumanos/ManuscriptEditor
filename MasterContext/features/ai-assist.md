# 11 — AI Integration (plan)

> **Status: proposed, not built.** The design for the AI feature set — connectors,
> context, "AI active", the prompt log, and the two first intents. Nothing here
> is implemented beyond the pieces marked *existing*. Phase II per
> [`09-roadmap.md`](09-roadmap.md).

Governing principle, from [`00-master-prompt.md`](00-master-prompt.md):
**AI adapts; it never silently rewrites.** Every result lands as an editable,
undoable change, and every request is recorded (§6).

---

## 1. Decisions, and why

### The app calls out; nothing calls in

**No MCP server.** An MCP server exposes this app *to* a model client — the
opposite of what we want, which is Manuscript Editor initiating. Dropping it
removes the tool loop, the write-concurrency problem (an outside tool writing to
a manuscript the app has open), and leaves each AI action as one request and one
response — which is precisely what makes the prompt log (§6) tractable.

If we ever want someone to drive the app from Claude Desktop, the intent layer
(§7) is the seam to add it behind; nothing here forecloses it.

### Why not have the app ask its client for a completion

For the record, because it looks like the obvious answer: MCP **sampling**
(`sampling/createMessage`) lets a server request a completion from its client —
the 2025-06-18 spec describes it as working "with no server API keys
necessary." **As of protocol version `2026-07-28` sampling is deprecated and
scheduled for removal**, with the spec directing new implementations to
"integrate directly with LLM provider APIs instead." So it is not a foundation.

### Local agent CLIs, not API keys

The app spawns a **locally installed agent CLI** the user is already signed into,
so AI features cost nothing beyond the subscription the user already has:

| CLI | Non-interactive | Subscription sign-in |
|---|---|---|
| Claude Code | `claude -p` | yes — only `--bare` requires `ANTHROPIC_API_KEY` |
| Codex | `codex exec` | yes — "Sign in with ChatGPT" |
| Gemini CLI | *assumed `-p`; verify* | *assumed; verify* |

Ollama is the fourth connector and a different shape: a local HTTP server, no
auth, no cost, fully offline — and the only one whose models we can enumerate.

**Built (Sep 2026).** `AIConnectorRunner.runOllama` posts to
`<endpoint>/api/generate` with `stream: true` and reads the newline-delimited
answer token by token, so the same stall clock that guards Claude Code guards
a local model: silence, not wall time, is what means stuck. The answer
reports the tag it came from, and a longer tag for the same model
(`llama3.1:latest` for `llama3.1`) is not a substitution. Settings → Accounts
shows the server URL and a **Models** picker read off `/api/tags` when Test
runs — `ollama pull` something new and press Test again — and the list is
kept on the connector (`availableModels`) so the manuscript's model picker
can offer it without a network call mid-render. A server with nothing pulled
tests red and says so.

The **existing API-key path** (`SmartSyncService`, real, `claude-opus-5`) stays
as a fallback for anyone who would rather pay per token than install a CLI. It
is not the headline and it is not the default.

### The app is not sandboxed

`ENABLE_APP_SANDBOX = NO`, so spawning subprocesses and reaching localhost are
both permitted. This design depends on that; if the app is ever sandboxed for
App Store distribution, **every CLI connector stops working** and only Ollama
(network) and the API key survive.

---

## 2. What already exists (do not rebuild)

| Piece | Where | State |
|---|---|---|
| `AIProvider`, `AIServiceAccount` | `Models/AIServiceAccount.swift` | Real |
| Account UI, Keychain-backed | `Views/AccountsView.swift`, `Services/KeychainService.swift` | Real |
| **Connection testing** | `Services/AccountTesting.swift` | Real — already probes Ollama's `/api/tags` |
| Per-manuscript AI selection | `ManuscriptSettings.activeAIServiceID` | Real |
| A working model call | `Services/SmartSyncService.swift` | Real, non-streaming |
| A local-service integration to copy | `Services/ZoteroService.swift` | Real — localhost:23119, "make sure Zotero is running" |
| "Smart" sync toggle | `Views/JournalLineageCard.swift` | Real — **to be replaced** (§5) |

`ZoteroService`'s header comment says the app is sandboxed. It isn't; fix while
passing.

---

## 3. Connectors

The core abstraction. A **connector** is a local service the app can talk to. No
username, no password — the credential lives in the tool the user already
configured.

```swift
/// A locally installed service the app drives.  Deliberately credential-free:
/// the user signs into the CLI (or runs the server) once, and the app borrows
/// that, so no key is stored, transmitted, or billed.
struct AIConnector: Identifiable, Codable {
    var id: UUID
    var kind: AIConnectorKind        // .claudeCLI | .codexCLI | .geminiCLI | .ollama
    var executablePath: String       // defaulted by probe, editable (see below)
    var selectedModel: String
    var lastTestedAt: Date?
    var lastTestResult: String?
}
```

### The settings row

Each connector renders as one row in Settings → Accounts, beside the existing
backend and AI-service rows:

```
 ✦  Claude Code                                    [ Test ]
    Local · signed in through the Claude Code CLI
    Install with:  npm i -g @anthropic-ai/claude-code   ⧉
    Path   [ /opt/homebrew/bin/claude              ] [ Browse… ]
    Model  [ Claude Opus 5                       ⌄ ]
```

- **No credential fields.** A short line on how to start or install the service,
  with a copyable command.
- **Executable path**, defaulted by probing and **editable** — see the next
  section, which is the part most likely to go wrong.
- **Test** button, which is load-bearing rather than decorative (§3.2).
- Ollama's row has a URL instead of a path (`http://localhost:11434`), same
  shape otherwise.

**One shape for every account.** Connectors, storage backends and API-key AI
services all follow the same two rules, in `RemoveAccountSection` and
`AccountsView.testedThisSession`:

- **Removal is the last section of the detail pane** — one red button behind a
  confirmation, never a minus in the list or a context-menu item. Deleting an
  account (and its Keychain secret) is a decision made while looking at the
  account you mean, not a gesture in a list you scroll.
- **The status dot is scoped to the settings window.** It appears when a test
  succeeds or fails and disappears when the window closes. A tick read back from
  storage claims live status for a token that may have been revoked, or a tool
  uninstalled, since it was written.

### 3.1 Resolving the executable — the real risk

**A GUI app launched from Finder does not inherit the shell's `PATH`.** `claude`,
`codex`, and `gemini` live in `/opt/homebrew/bin`, `/usr/local/bin`,
`~/.local/bin`, or an nvm directory, and a naive `Process()` will not find any of
them. Resolution order:

1. The stored `executablePath`, if it still exists and is executable.
2. A probe of the known locations for that CLI.
3. `/bin/zsh -lc "command -v <tool>"` — a login shell, which *does* read the
   user's profile.
4. Ask: the **Browse…** button.

Whatever resolves is written back to `executablePath`, so the slow path runs
once. This is why the field is editable rather than hidden.

### 3.2 What Test actually does

> **Built.** `AIConnectorRunner` + `ConnectorDetailView`; Claude Code only —
> the other three kinds appear in the UI and refuse with "isn't wired up yet".


Not a ping. Test resolves the binary (above), runs one trivial round-trip, and
reports what came back — including **which model actually answered**, because a
model the user selected may not be on their plan. Failure messages name the
cause: not installed, not signed in, model unavailable, timed out.

`AccountTesting.swift` already does exactly this for Ollama and is where this
belongs.

### 3.3 Models, per connector

**The model is chosen per manuscript, in Overview → Settings → AI — not on the
connector.** Settings → Accounts answers "is this tool installed and signed
in"; a manuscript answers "what does this one write with", and two manuscripts
can reasonably want different models from the same connector. The Overview
dropdown groups models under the connector that offers them, and hides
connectors that have not tested green.

The list per connector: 

- **Claude Code** — curated from the current family, defaulting to
  **Claude Opus 5**: Fable 5.1, Fable 5, Opus 5, Opus 4.8, Opus 4.7, Opus 4.6,
  Sonnet 5, Sonnet 4.6, Haiku 4.5. Passed as `--model`.
- **Ollama** — **discovered live** from `/api/tags`; only this connector can
  enumerate honestly.
- **Codex / Gemini CLI** — curated list once verified, plus a free-text field.

Every connector's dropdown ends with a **free-text entry**, because model lists
go stale between app releases and a user on a newer CLI should not be blocked by
ours. Availability is confirmed by Test, not by the dropdown — the list offers,
it does not promise.

**Which model answered is read, not assumed.** The result JSON has no
top-level `model` field; `modelUsage` is keyed by model id but lists *every*
model the run touched — including the small one Claude Code uses for its own
housekeeping, which routinely burns more tokens than the answer. A real run
requesting `claude-opus-5` reports `claude-haiku-4-5-…` at 9 output tokens
beside `claude-opus-5` at 4, so both "first alphabetically" and "the busiest"
are wrong. The runner matches the **requested** id against that report
(prefix-wise, since ids carry date suffixes) and flags a genuine substitution
rather than papering over it.

### 3.4 Zotero

**Deferred.** `ZoteroService` is already a local connector in everything but
name; fold it into this UI once the AI connectors have proved the pattern.

---

## 4. Context

> **Built.** `Models/AIContext.swift`, the store block in `ManuscriptStore`
> (`aiContextEntries` … `aiContextBundle()`), `Views/AIContextTable.swift`.
>
> It renders **inside the Settings card, immediately below the AI model
> picker**, and only once a model is chosen — the two are one decision
> continued (*who* answers, then *what they may read*), and with no model there
> is nobody to send anything to. §4.3's AI button waits for the intent layer and
> the prompt log, so nothing can run before there is somewhere to log it.

### 4.1 The model

```swift
enum AIContextKind { case appPrimer, manuscriptData, freeText, file }

struct AIContextEntry: Identifiable, Codable {
    var id: UUID
    var kind: AIContextKind
    var title: String
    var isEnabled: Bool          // the checkbox — opt OUT of sharing
    var body: String             // freeText
    var fileName: String?        // file, copied into context/
    var isLocked: Bool           // appPrimer only
}
```

The rows live on `Manuscript.aiContext` (`decodeIfPresent`, so older files still
open); attached files live in `context/`, beside `figures/`, `data/`,
`attachments/`.

**The built-in rows carry fixed ids** (`AIContextKind.builtInID`). They are
regenerated on every read until the list is first written, so a fresh `UUID()`
each time changed the id under the checkbox the user had just clicked —
unticking "This manuscript" on a manuscript whose context had never been edited
silently did nothing. Caught by the harness, not by looking at it.

### 4.2 The rows

1. **How Manuscript Editor works** — locked, not editable, on by default.
   Source/cuts/versions/lineage, what a section, check, profile and export are.
   Generated from a constant in the app so it tracks the app instead of going
   stale in a user's file.
2. **This manuscript** — on by default, **deselectable**. The content itself.
   This is the row someone unticks when they don't want their work leaving the
   machine, and the UI should say so in as many words.
3. …custom rows: free text, or a file.
4. **Add row.**

Unticked means never sent — enforced where the payload is assembled, not in the
view.

### 4.3 The free-text row's AI button

Top-right of the editor. Sends enabled context + what is already typed + the
intent *"write a context note for this app"*, and replaces the box's contents.
It goes through the normal `RichTextController` path, so **⌘Z undoes it** — that
is the entire safety story, and the reason not to give it a bespoke edit path.

---

## 5. "AI active"

> **Built.** `Theme/AssistStyle.swift` (`.assistAffordance(active:busy:)`),
> `Views/AssistToolbarItem.swift`, `ManuscriptSettings.aiAssistEnabled`.
> The toggle is per-manuscript and persisted: one paper may be adapted with a
> model's help while another, under an embargo or a co-author's objection, is
> written entirely by hand.

One toggle: **✦ Assist**, a compact icon in the journal tab bar immediately
**left of Active/Compare** — those three say how the workspace is behaving right
now, and unlike a title-bar button the tab bar is visible in every pane. No
label: grey when off, assist violet when on, pulsing while a request is out.

- **No connector tests green** → disabled, pointing at Settings → Accounts.
- **Configured, off** → available; everything renders normally.
- **On** → AI-capable controls take the assist treatment.

**The treatment.** One accent, used sparingly: a gradient stroke/tint from
`Theme/AssistStyle.swift` — `#7B5CFF → #B06AB3`, ~0.85 opacity on strokes, ~0.12
on fills, with a light/dark pair like every colour in
[`06-design-system.md`](06-design-system.md). Applied through a single
`.assistAffordance(active:)` modifier so a new AI feature adopts the look rather
than inventing one. No motion except a slow shimmer while a request is in
flight, where it is a progress signal.

**Fast Forward.** Remove the "Smart" toggle. The existing button becomes the one
control: Assist off is today's mechanical behaviour exactly; Assist on runs
`journal.fastForward` and stamps the new version.

---

## 6. The prompt log

> **Built.** `Models/AIPromptLog.swift`, `Services/AI/AIPromptLogService.swift`,
> `Views/PromptLogView.swift` (the **AI Requests** section of the Log pane).
> Append-only; nothing in the app edits or deletes an entry. `gatherRemoteFiles`
> ships `ai/`, `ai/prompts/` and `ai/responses/` with the manuscript.

Every request, whether fired by a button or (later) typed by hand, is recorded.

**Location — not `manuscript.json`.** Its own folder in the manuscript, so it
travels with the work and shows up in the remote, without bloating the file the
app rewrites on every save:

```
<manuscript>/ai/
    log.json               index: id, intent, connector, model, when, outcome
    prompts/<id>.txt       the rendered prompt, verbatim
    responses/<id>.txt     the raw response
```

A fast-forward prompt carries an entire journal; keeping payloads out of
`manuscript.json` keeps saves fast and git diffs readable.

**Entries are independent.** Each carries its own context snapshot — no session
continuity in v1. Button-driven only for now; the log is built as a *transcript*
so that adding a custom prompt box later is an addition, not a rewrite.

**Where it is read: Log → AI Requests**, the third section of the Log pane
under Changelog and Events — not a popover behind an icon of its own. That pane
is already where someone goes to ask "what happened to this manuscript", and a
request to a model is one of the things that happened. Entries are newest
first: intent, connector + model, when, and a **summary diff of what the
response changed** — reusing `SentenceSimilarity` from compare mode, which
already answers "what changed between two texts" in ~1.2 ms and gives the log
the same green/yellow vocabulary the editors use. Expanding a row shows the
context sent, what was withheld, and the prompt and response verbatim.

Why this matters more than the generation features: for scientific work,
*"which parts of this were AI-written, from what prompt, by which model"* is a
question that will be asked, and a log that ships with the manuscript answers it
without anyone having to remember.

---

## 7. Intents

> **Built.** `Services/AI/AIIntent.swift` (descriptor + `AIIntentRegistry`),
> `Services/AI/AIRequestService.swift` (the one place a prompt leaves the app —
> it assembles context, dispatches to a connector or a keyed service, and the
> store records the outcome either way).
>
> The protocol landed smaller than sketched below: an intent **describes
> itself** and owns its prompt and its parsing, but does not carry
> `apply(_:to:)`. Applying a fast-forward is the existing `syncJournal`
> override — reusing it is what keeps stamping, recovery and the checksum
> precheck identical whether or not a model was involved, and a second write
> path would have been the risk, not the abstraction.

```swift
/// Everything an AI feature needs to describe itself, so what is prompted and
/// what is sent is inspectable without reading the call site.
protocol AIIntent {
    static var id: String { get }             // "context.compose", "journal.fastForward"
    static var summary: String { get }
    var contextPolicy: AIContextPolicy { get }
    func payload(from: AIPayloadSource) throws -> AIPayload
    func apply(_ result: AIResult, to store: ManuscriptStore) throws
}
```

Runners sit underneath, one per connector shape:

- `AgentCLIRunner` — spawns the resolved executable; per-CLI differences are
  argv only (`claude -p --model … --output-format json`, `codex exec …`).
- `HTTPRunner` — Ollama today; the keyed API path reuses it.

**Every write is a version (required).** An intent that changes the manuscript
must land as a stamped version, never as an in-place edit — a model's work is
exactly the kind that has to be reversible after the fact, when the problem is
noticed a day later rather than one ⌘Z ago. `journal.fastForward` gets this by
writing through the same `syncJournal` / `pushToUpstream` override a manual copy
uses: the overridden content is stamped into history first, and the new version
is labelled **"Adapted from … by \<model\>"** so an assisted version can be
told from a hand-made one at a glance in Versions. An intent that edits a text
box instead (`context.compose`) goes through the undo manager, which is that
case's equivalent — but nothing writes with neither.

**Discoverability (required).** Every intent lives in `Services/AI/Intents/`, is
registered in `AIIntentRegistry.all`, and carries an `// AI INTENT` banner.
`grep -rn "AI INTENT"` returns everything that can talk to a model, each
declaring its inputs. A Settings → AI pane renders the same registry, so the
user sees the list the code sees.

### 7.1 `context.compose`

Enabled context + the text box's contents → prose for a context note → replaces
the editor's text, undoably.

### 7.2 `journal.fastForward`

Enabled context + the content a plain fast-forward would bring down (the
**upstream**'s text where it has some, the cut's own — its boilerplate, tokens
and all — where it hasn't) + the **target**'s profile (requirements bullets,
structure, checks with their limits) → per-section adapted content → writes
the downstream cut and stamps a version. Never touches the upstream; never
applies without the diff being visible. The adaptation is the **last write**:
nothing (the template's content included) is applied over it afterwards.

**Seeing what the tool is doing.** Claude Code writes a transcript of every run
under `~/.claude/projects/<encoded working directory>/<session>.jsonl`. The app
passes `--session-id` so that file is named after the prompt-log entry and can
be computed rather than hunted for — `AIConnectorRunner.transcriptURL(for:)`,
surfaced as **Show the tool's own transcript** in Log → AI Requests, and present
even when the run failed.

The runner reads `--output-format stream-json --verbose
--include-partial-messages` rather than waiting for one JSON blob, because the
blob told us nothing while it mattered. Diagnosing a "stalled" ten-minute run
meant replaying it by hand outside the app; the stream showed the answer
immediately — the model was **thinking**, 15,850 tokens of it, before writing a
character. So progress is now reported as it happens (`AIRunProgress`: thinking
tokens, then response characters), the row shows it, and **silence** — no event
for three minutes — is what counts as stuck, instead of a wall clock that cannot
tell a big job from a dead one.

**Watching a run.** The busy row carries an eye that opens the answer as it
arrives (`AssistLiveOutputView`) — a 4,000-character tail, because a
full-manuscript run produced 71,000 output tokens and copying that buffer on
every delta would cost more than the request. During the thinking phase there is
deliberately nothing to show, and the view says so rather than looking broken.
In Log → AI Requests every entry offers its three logs, each in a window of its
own rather than crammed into the row: **Prompt** (what was sent, context
first), **Output** (the raw reply before parsing) and **Session log** (what the
tool itself recorded — one readable row per event: prompt size, model reply, API
error, cost — with a Raw toggle for the file as written), plus Reveal.

**How long it takes.** Measured, on a real seven-section manuscript: **14 min
20 s, $3.53, 71,099 output tokens** for one pass. No wall clock chosen to be
"generous enough" survives a longer paper on a slower day, so the hard cutoff is
45 minutes and does almost nothing: the real guard is silence, which
`AIConnectorRunner.stallTimeout` catches in three minutes. The generation, not the
network, is the cost — the model rewrites every section in full, and thinks
first. That is the number to design against, and it is the argument for
splitting a fast-forward into per-section requests rather than one. So the cutoff is 15 minutes (`AIRequestService.longRunTimeout`), the
busy row shows a bar and a running clock against it
(`Views/AssistRunIndicator.swift`), and the indicator is keyed to the journal
whose button was pressed rather than the card. The context also stops repeating
the manuscript body when the intent already sends the sections
(`aiContextBundle(includeSectionText:)`) — it was going out twice, ~46 kB for
that manuscript.

**Proved end to end (Sep 2026).** One real `claude -p` run against a two-section
manuscript with a 120-word limit: Opus 5 answered in 12.6 s, expanded the
abbreviations the journal's instructions asked for (`HF` → heart failure,
`SGLT2i` → sodium-glucose cotransporter 2 inhibitor, `eGFR` → estimated
glomerular filtration rate), returned Methods unchanged because it already
suited the target, and preserved every number — 412, 72 hours, 10 mg, p = 0.03.

**What the first real run got wrong, and what fixed it (Sep 2026).** A
44-minute pass on a seven-section manuscript applied cleanly and was still
wrong in three ways. Each fix is a rule the prompt now leads with:

1. **It dropped every citation.** A citation is not a character in the text — it
   is a `.link` attribute on the RTF carrying `cite://<uuid>`. The plain mirror
   that was sent contained no trace of the Introduction's fourteen references,
   and writing the answer back as `RichText(plain:)` destroyed all twenty-one in
   the manuscript. `Services/AI/AIRefMarkers.swift` now sends each one as
   `[[cite:3]]` and restores it to the exact link run afterwards; the same
   protection covers part tokens (`[[authors.names]]`, which the model had
   replaced with an invented author list). A marker that doesn't come back is
   reported in the banner and the log rather than lost quietly.
2. **It ignored the length checks.** The checks were sent as names ("Body ≤ 1200
   words"), which is a rule, not an instruction. They are now evaluated against
   the content being adapted and sent with their measurements — *FAILING · Body
   ≤ 1200 words · 2,360 of 1,200 words used* — plus a per-section **word
   budget** apportioned to each section's current share, so a limit spanning six
   sections is arithmetic done here rather than guessed there.
3. **It left required-but-empty sections empty.** `payloads` sends every active
   section including empty ones, question series arrive as their questions with
   word limits, and answers come back per question id — the earlier run returned
   the submission questions verbatim and the write silently discarded them,
   because a question section renders from `questions`, not `content`.

After applying, the target's checks are re-run and any that still fail are
named in the banner and the log entry. The measure and the instruction are the
same thing, which is the point.

**Verified, not asserted.** The target's checks are already machine-evaluable
(`ChecklistService`), so after applying, re-run them and report which now pass.
"10 of 11 checks pass, abstract still 12 words over" is a measurement; "the AI
adapted your manuscript" is not. This also makes connectors comparable on the
same manuscript — including showing honestly where a local Ollama model does
worse than a frontier one.

---

## 8. Sequencing

| Step | Deliverable | Why here |
|---|---|---|
| 1 | ✅ **Built** — `AIConnector`, path resolution, Test, settings rows (Claude Code only); model choice in Overview | Everything else needs a way to reach a model |
| 2 | ✅ **Built** — context model, `context/` storage, Overview table with the locked primer | Nothing can be prompted without it |
| 3 | ✅ **Built** — `AIIntent` + registry + the greppable convention + runners | The seam |
| 4 | ✅ **Built** — prompt log (`ai/`, popup, diff) | Built *before* the first intent, so nothing ever runs unlogged |
| 5 | ✅ **Built** — `AssistStyle`, `.assistAffordance`, the toolbar toggle | Visual language, once |
| 6 | `context.compose` | Small, self-contained, undoable |
| 7 | ✅ **Built** — `journal.fastForward`; Smart toggle retired | The real one; check-verified |
| 8 | Fold Zotero into connectors | After the pattern is proved |

---

## 9. Open questions

1. **Gemini CLI** — non-interactive flag, sign-in model, and model list are
   assumed above and unverified.
2. **Codex structured output** — Claude Code has `--json-schema`; Codex's
   equivalent is unconfirmed, so `journal.fastForward` may need tolerant parsing
   on that connector.
3. **Shipping a dependency on someone else's CLI** — whether requiring or
   bundling Claude Code / Codex in a distributed app is permitted under those
   subscriptions is a licensing question, not an engineering one.
4. **Log retention** — every fast-forward payload is large. Keep all of them
   forever, cap the folder, or store a hash and summary past some size?
