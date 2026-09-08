# 11 — AI Integration (plan)

> **Status: proposed, not built.** This is the design for the AI feature set —
> account, context, "AI active", the two first integrations, and the local MCP
> server. Nothing here is implemented yet beyond the pieces noted as *existing*.
> Phase II per [`09-roadmap.md`](09-roadmap.md).

Governing principle, from [`00-master-prompt.md`](00-master-prompt.md):
**AI adapts; it never silently rewrites.** Every AI result lands as an editable,
undoable change the user can see and reject.

---

## 1. The architecture decision (read this first)

The instinct was: ship a **local MCP server**, let **Claude Desktop** be the
model, and avoid an API key. Half of that is right, and the half that isn't is
worth stating plainly before any code is written.

### What MCP actually gives us

An MCP **server** exposes tools, resources, and prompts to an MCP **client**
(Claude Desktop, Claude Code, …). The client owns the model. So a local MCP
server lets someone sit in Claude Desktop and say *"fast-forward my SNAP/EFO
manuscript to the AJPH cut"*, and Claude calls into Manuscript Editor. **No API
key, no per-token cost** — it runs on the user's existing Claude subscription.

What it does **not** give us is a way for a button *inside* Manuscript Editor to
call a model.

### The mechanism that would have — and why we can't use it

MCP **sampling** (`sampling/createMessage`) lets a server ask its client for a
completion. The 2025-06-18 spec describes it exactly as we'd want: servers
"leverage AI capabilities — with no server API keys necessary."

**As of protocol version `2026-07-28`, sampling is deprecated and scheduled for
removal**, and the specification's guidance is explicit:

> New implementations should integrate directly with LLM provider APIs instead.

(`roots` is deprecated in the same revision. `elicitation` survives and is
useful to us — see §6.)

So we must not build the in-app buttons on sampling. That is the whole fork:

| | Who calls the model | Cost | In-app buttons work? |
|---|---|---|---|
| **A. MCP server** | Claude Desktop / Claude Code | Covered by the user's Claude subscription | **No** — the user drives from Claude |
| **B. API key** | Manuscript Editor | Per token, user's key | **Yes** |

### Recommendation: one domain layer, two transports — MCP first

Build the *thinking* once and the *plumbing* twice:

```
        ┌────────────────────────────────────────────────┐
        │  AIIntent  (what we want, what we send back)    │
        │  · AIContextBundle    · AIIntent protocol       │
        │  · prompt assembly    · result application      │
        └───────────────┬────────────────┬───────────────┘
                        │                │
              ┌─────────▼──────┐  ┌──────▼──────────────┐
              │ MCPTransport   │  │ APIKeyTransport     │
              │ app = server;  │  │ app = client;       │
              │ Claude Desktop │  │ Anthropic Messages  │
              │ drives         │  │ API (exists today)  │
              └────────────────┘  └─────────────────────┘
```

- The intents, the context bundle, the prompt text, and the code that applies a
  result are **transport-agnostic** and testable without a network.
- **Ship the MCP server first.** It is the free path, it is genuinely useful,
  and it forces the domain layer to be clean (a tool call is just an intent
  invoked from outside).
- **Keep the API-key transport**, because `SmartSyncService` already implements
  it against `claude-opus-5` and it is the only way the in-app buttons can work.
- **"AI active" means *some* transport is configured** — a connected Claude
  Desktop *or* a verified key. Features light up either way; what a button does
  when pressed differs (§4).

---

## 2. What already exists (do not rebuild)

| Piece | Where | State |
|---|---|---|
| `AIProvider`, `AIServiceAccount` | `Models/AIServiceAccount.swift` | Real; `.claude` case present |
| Account add/verify UI | `Views/AccountsView.swift` | Real, GitHub-style, Keychain-backed |
| Secret storage | `Services/KeychainService.swift` | Real (`setSecret`/`secret`/`deleteSecret` by account id) |
| Per-manuscript AI selection | `ManuscriptSettings.activeAIServiceID` | Real |
| A working Anthropic call | `Services/SmartSyncService.swift` | Real, non-streaming, `claude-opus-5` |
| "Smart" sync toggle | `Views/JournalLineageCard.swift` | Real — **to be replaced** by "AI active" (§4) |

The account flow the user asked for ("add and verify my AI account, similar to
GitHub") is therefore **mostly built**; what it lacks is *verification* — a
"Verify" button that makes one cheap call and reports success — and the Claude
Desktop / MCP pairing state.

---

## 3. Context

### 3.1 The model

```swift
enum AIContextKind { case appPrimer, manuscriptData, freeText, file }

struct AIContextEntry: Identifiable, Codable {
    var id: UUID
    var kind: AIContextKind
    var title: String
    var isEnabled: Bool          // the checkbox — opt OUT of sharing
    var body: String?            // freeText
    var fileName: String?        // file, copied into context/ (travels with the manuscript)
    var isLocked: Bool           // appPrimer only: not editable, not deletable
}
```

Stored on the manuscript (so it travels and is reviewable in git), with attached
files under `context/` beside `figures/` and `data/`.

### 3.2 The rows, in order

1. **How Manuscript Editor works** — `appPrimer`, **locked, not editable**,
   enabled by default. Explains source/cuts/versions/lineage, what a section,
   check, profile and export are. Generated from a constant in the app so it
   updates with the app rather than going stale in a user's file.
2. **This manuscript** — `manuscriptData`, enabled by default, **deselectable**.
   The manuscript itself: title, authors, sections, journals, checks. This is
   the row someone unticks when they don't want their content leaving the
   machine, and the UI should say so in as many words.
3. …**custom rows**, added by the user.
4. **Add row** — free text, or a file.

Every row carries a checkbox. Unticked = never sent. The Overview settings card
gets a **Context** table (`Views/AIContextTable.swift`), per the request.

### 3.3 The text editor's own AI button

A free-text row opens a normal editor with an **AI button top-right**. Pressed,
it sends: the enabled context so far + whatever is already typed + the intent
*"write a context note for this app"*, and replaces the box's contents with the
result. It is one `RichTextController` edit, so **⌘Z undoes it** like any other
edit — that is the whole safety story, and it is why the result must go through
the normal text path rather than a bespoke one.

---

## 4. "AI active"

A single toggle in the window toolbar: **✦ Assist**.

- **No transport configured** → disabled, with a tooltip pointing at
  Settings → Accounts.
- **Configured but off** → available, everything renders normally.
- **On** → every AI-capable control takes the *assist* treatment.

### The treatment

Not a purple wash on everything. One accent, used sparingly:

- A gradient stroke/tint drawn from a new `Theme/AssistStyle.swift`:
  `#7B5CFF → #B06AB3` (violet → orchid), at ~0.85 opacity for strokes and
  ~0.12 for fills, with a light/dark pair like every other colour in
  [`06-design-system.md`](06-design-system.md).
- Applied via **one modifier**, `.assistAffordance(active:)`, so a new AI
  feature gets the look by adopting the modifier and cannot invent its own.
- Motion: none by default. A slow shimmer *only* while a request is in flight —
  it is a progress signal, not decoration.

### Fast Forward

Per the request: **remove the "Smart" toggle**. The existing Fast Forward button
becomes the single control, and takes the assist treatment when Assist is on:

- **Assist off** → today's behaviour exactly (mechanical fast-forward).
- **Assist on, API-key transport** → runs `.fastForwardJournal` in-app and
  stamps the new version.
- **Assist on, MCP transport only** → the button explains it hands off, and
  offers a one-click *"Copy request for Claude"* / *"Open Claude Desktop"*. The
  work still happens through the same intent, just initiated from the other end.

---

## 5. The two intents

Both conform to one protocol, and both are **documented in a way that greps**.

```swift
/// Everything an AI feature needs to describe itself, so what is prompted and
/// what is sent is inspectable without reading the call site.
protocol AIIntent {
    static var id: String { get }            // "context.compose", "journal.fastForward"
    static var summary: String { get }       // one line, shown in the UI
    var contextPolicy: AIContextPolicy { get }   // which context rows this needs
    func payload(from: AIPayloadSource) throws -> AIPayload
    func apply(_ result: AIResult, to store: ManuscriptStore) throws
}
```

**Discoverability requirement (from the request).** Every intent lives in
`Services/AI/Intents/`, is registered in `AIIntentRegistry.all`, and carries a
`// MARK: - AI INTENT` banner. `grep -rn "AI INTENT"` returns the complete list
of everything that can talk to a model, and each one states its inputs. A
Settings → AI pane renders the same registry, so the user sees the identical
list the code does.

### 5.1 `context.compose`

- **Sends:** enabled context rows + current text box contents.
- **Asks for:** prose suitable as a context note.
- **Applies:** replaces the editor's text (undoable).

### 5.2 `journal.fastForward`

- **Sends:** enabled context rows + the **upstream** journal's full content +
  the **target** journal's profile (requirements bullets, structure, checks with
  their limits).
- **Asks for:** per-section adapted content that satisfies the target's checks.
- **Applies:** writes the downstream cut and stamps a version — never touching
  the upstream, and never applying without the diff being visible.
- **Verification is the interesting part:** the target's checks already exist
  and are machine-evaluable (`ChecklistService`). After applying, **re-run the
  checks and report which now pass** — turning "the AI wrote something" into a
  measurable claim. When a limit is still blown, say so rather than pretending.

---

## 6. The MCP server

A separate executable target, `ManuscriptEditorMCP`, speaking **stdio JSON-RPC**
so it drops into `claude_desktop_config.json`:

```json
{ "mcpServers": {
    "manuscript-editor": { "command": "/Applications/Manuscript Editor.app/Contents/MacOS/ManuscriptEditorMCP" } } }
```

It reads and writes the same manuscript folders the app does, through the
existing `PersistenceService` — **not** a second copy of the domain logic.

**Tools** (each one an `AIIntent` or a thin read):

| Tool | Kind | Notes |
|---|---|---|
| `list_manuscripts` | read | id, title, journals |
| `get_manuscript` | read | honours the context checkboxes — an unticked row is not returned |
| `get_journal_profile` | read | requirements, structure, checks |
| `run_checks` | read | the same verdicts the Checks pane shows |
| `compose_context` | write | `context.compose` |
| `fast_forward_journal` | write | `journal.fastForward` |

**Safety, since this writes to a user's manuscript from outside the app:**

- Write tools require the manuscript to be **closed in the app** or apply
  through the store's normal `touch`/undo path — never a blind file write while
  the app holds it open.
- Every write stamps a version, so it is recoverable by the existing rollback.
- The context checkboxes are enforced **server-side**. Unticked means the data
  does not leave the process, whatever the caller asks for.
- **elicitation** (still current) is the right way to ask "which target
  journal?" instead of guessing.

---

## 7. Sequencing

| Step | Deliverable | Why this order |
|---|---|---|
| 0 | Confirm the transport decision (§1) | It changes what ships first |
| 1 | Context model, `context/` storage, Overview table with the locked primer row | Nothing else can be prompted without it |
| 2 | `AIIntent` + registry + the greppable convention | The seam both transports sit on |
| 3 | MCP server: read tools only | Useful and safe on day one; proves the seam from outside |
| 4 | `AssistStyle` + `.assistAffordance` + the toolbar toggle | Visual language, once |
| 5 | `context.compose` (both transports) | Small, self-contained, undoable |
| 6 | `journal.fastForward`; retire the Smart toggle | The real one; check-verified |
| 7 | Account **verification** + Claude Desktop pairing state | Makes "AI active" honest |

---

## 8. Open questions

1. **Transport** — MCP only, API key only, or both (recommended: both, MCP
   first). §1.
2. **Where the primer lives** — a constant in the app (updates with releases,
   what this plan assumes) or a bundled file the user can read before it is
   sent.
3. **Cut-level or manuscript-level context** — this plan puts context on the
   manuscript. A journal-specific context row ("this cut is for a clinical
   audience") may want to live on the journal instead.
4. **MCP write concurrency** — simplest safe rule is that write tools refuse
   while the app has the manuscript open, and say so. Worth confirming that is
   acceptable before building the alternative.
