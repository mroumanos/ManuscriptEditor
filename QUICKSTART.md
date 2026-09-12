# Quickstart — testing Manuscript Editor (v0)

Welcome! This guide takes about 15 minutes and assumes no technical background.
You'll install the app, connect it to GitHub, open the shared test manuscript,
make edits, create a journal version, and export a submission package.

> You'll need: a Mac, a GitHub account, and an invitation to the private test
> manuscript repository (ask the person who sent you this guide).

---

## 1. Install the app

1. Download `ManuscriptEditor-<version>.dmg` from the **Releases** page of this
   repository.
2. Open the downloaded file and drag **Manuscript Editor** onto **Applications**.
3. If macOS warns on first launch that it "could not verify" the app:
   **System Settings → Privacy & Security → scroll down → Open Anyway**
   (one time only). Notarized builds open with no warning at all.

The app opens on the **Welcome screen** — your project manager. No account or
login is needed for the app itself; everything stays on your Mac.

> **If macOS asks "ManuscriptEditor wants to use your confidential
> information stored in the keychain"**: click **Always Allow** (not
> "Allow"). This is the app reading the token and signing key *it stored
> for you* — macOS re-asks whenever an app is updated, and "Allow" only
> approves a single read, which is why clicking it makes the dialog come
> back. "Always Allow" answers once per item, permanently.

## 2. Connect GitHub (personal access token)

The app pulls and pushes manuscripts through your GitHub account using a
**personal access token (PAT)** — a limited password you create just for this.

**Create the token (on github.com):**

1. Go to **github.com → your profile picture → Settings → Credentials →
   Fine-grained personal access tokens → Generate new token**.
   (On some accounts the path is Settings → Developer settings →
   Personal access tokens → Fine-grained tokens.)
2. Name it "Manuscript Editor", set an expiration you're comfortable with.
3. **Repository access:** "Only select repositories" → pick the test
   manuscript repository you were invited to.
4. **Permissions → Repository permissions:**
   - **Contents → Read and write** (pull and push the manuscript)
   - **Administration → Read and write** (only needed if you'll create new
     repositories from inside the app — harmless to include)
5. **Generate token** and **copy it** (you won't see it again).

**Add it to the app:**

1. In Manuscript Editor: **⌘,** (or the gear at the bottom of the sidebar) →
   **Accounts**.
2. **Add Account → GitHub**, give it any display name → **Add**.
3. Paste the token into **Personal access token** — it saves as you type
   (into your Mac's Keychain, never into any file).
4. Click the small **⚡ button** next to the token. You should see
   **"Connected to GitHub as ⟨your username⟩"** with a green check.

## 3. Set up your identity (who signs your edits)

Every version you save is signed, so collaborators can see who did what.

1. **⌘, → User.**
2. Enter your **Name** — this appears next to your edits.
3. Pick an identity type:
   - **Local** — zero setup. Your edits show a gray "?" badge (they can't be
     verified by others). **Fine for testing — you can stop here.**
   - **GitHub** *(optional, for the green ✓ badge)* — enter your GitHub
     username, pick your **GPG key** from the dropdown, and press **⚡ Test**.
     This only works if you already use GPG and have
     [added your key to GitHub](https://docs.github.com/en/authentication/managing-commit-signature-verification/adding-a-gpg-key-to-your-github-account).
     If you've never heard of GPG, use **Local** — nothing else in this guide
     depends on it.

## 4. Open the shared test manuscript

1. **File → Open Manuscript (Remote)…**
2. Account: the GitHub account you just added.
3. Repository: the test manuscript's address in `owner/name` form (ask the
   person who invited you, e.g. `their-username/test-manuscript`).
4. Leave Branch empty → **Open**.

The manuscript downloads and opens. Your copy lives on your Mac; nothing you
do touches GitHub until you explicitly save to remote.

## 5. Edit, save, and sync

- Click anything under **Content** in the sidebar (Title, Authors, Abstract,
  the body sections…) and just type. Edits save to your Mac automatically.
- **⌘S — Save (Local)** writes to disk right now; a green confirmation
  appears in the title bar, and the top-right corner always shows *when* you
  last saved locally / remotely.
- **⇧⌘S — Save (Remote)** pushes your copy back to GitHub. Watch the title
  bar for "Successfully saved to remote…".
- Try the **"/" menu**: in any body section, type `/` and start typing a
  figure, table, or reference name to insert a live cross-reference. In the
  **Letter to Editor**, `/` also offers **Date** and **Signature** (draw one
  in the Signature section first — then place it with `/`).

## 6. Journal versions ("cuts") and comparing

The big idea: you write **one Source manuscript**, then adapt copies of it
per target journal — the data and structure stay shared.

1. Sidebar → **Sync** (under Manuscript).
2. **Add Journal** → From: **Source** → pick a journal from the library
   (e.g. *JAMA*) → Add. A new **tab** appears at the top — that's the
   journal's own copy. Click tabs to switch; edit the JAMA tab freely and
   notice Source doesn't change.
3. **Stamping:** a journal's history is made of frozen, numbered versions.
   In the **Versions** pane, **Stamp Version** freezes what you have as v1,
   v2, … (Source stamps the same way.)
4. **Syncing:** when Source has moved ahead, the journal's row in the Sync
   pane offers **Sync** — it pulls Source's latest *stamped* version into
   the journal. If Source has unstamped edits, the app asks you to stamp
   first (that keeps the version history honest). Green/red messages appear
   in the title-bar banner.
5. **Comparing:** in the tab bar, switch the mode toggle to **Compare** and
   add two tabs (e.g. Source and JAMA) to see them side by side.
   **⌘⇧← / ⌘⇧→** cycles tabs in Active mode.

## 7. Export a submission package

1. Open the tab of the journal you want to export (or Source).
2. Sidebar → **Export** (under Journal).
3. The outline lists the documents to produce (manuscript PDF, DOCX, …) and
   what goes in each. Press **Export**, choose a folder.
4. Open the folder: you get real submission files — PDF with line numbers
   and rendered charts/tables, a Word file with native tables, the cover
   letter with your letterhead, date, and signature resolved.

## 8. AI assist (optional)

Assist lets a model of your choosing adapt a journal cut for you — on a
subscription you already have, or on a local model that never leaves your
Mac. Nothing is sent anywhere until you turn it on, and every request is
recorded.

**a. Connect a tool** (once, app-wide): Settings (⌘,) → **Accounts** →
**Add Connector**. Three kinds work today:

| Connector | What you need | Then |
|---|---|---|
| **Claude Code** | `npm install -g @anthropic-ai/claude-code`, run `claude` once in Terminal and sign in | Test |
| **Codex** | The ChatGPT app for Mac (it bundles the CLI), or `npm install -g @openai/codex`; then `codex login` once | Test |
| **Ollama** | `brew install ollama && ollama serve`, then `ollama pull gemma4:26b` (or any model) | Test — it lists what the server has pulled; pick one |

Press **Test** on the connector. It runs a one-word request through the real
tool and shows which model answered. Only tested connectors are offered to
manuscripts. (No API keys are involved; the app borrows the sign-in you
already made. Apps launched from Finder don't see your shell's `PATH`, so if
Test can't find a CLI, point **Browse…** at it.)

**b. Choose a model for the manuscript**: Sidebar → **Overview** → **Settings**
→ **AI**. The model is a manuscript decision, so every manuscript starts at
*None*. Pick one, then tick the **Context** rows the model may read — how the
app works, this manuscript's shape, any notes or files you add. Unticked rows
are never sent.

**c. Turn Assist on**: the ✦ button beside Active/Compare in the tab bar. It
is greyed until a model is chosen. On, the fast-forward buttons in the
lineage card take on the ✦ treatment.

**d. Run an assisted fast-forward**: Overview → the journal's row → ⏩. The
model adapts each section toward that journal's instructions, its
boilerplate, and its tests with their current numbers, and the result is
stamped as a new version — the previous content is in **Versions**, one
rollback away. Citations travel with their claims (the model sees your
reference list and cites by key); a reply that invents a reference, drops a
manuscript field, or loses every citation in a section is refused, and that
section keeps its previous text.

**e. Read what happened**: Sidebar → **Log** → **AI Requests**. Each request
shows the model, the time it took, a per-section bar of how much changed,
what happened to the citations, which tests still fail, and — expanded — the
prompt, the raw output, and the tool's own session log. Refused sections are
named with the reason. A local model can take minutes; the row shows a clock
and a live tail of the answer while it works.

## If something goes wrong

- **"No personal access token stored"** — revisit step 2; the ⚡ test should
  green-check.
- **A red message in the title bar** — that's the app telling you exactly
  what it refused and why (most often: "stamp first, then sync").
- **Assist's ✦ button is greyed** — that manuscript hasn't chosen a model:
  Overview → Settings → AI. Only *tested* connectors are listed there.
- **An assisted run "kept sections unchanged"** — the reply dropped a field
  or invented a reference; Log → AI Requests names each one. Run it again, or
  try a stronger model.
- Anything else: note what you clicked and what you expected, and send it to
  the person who invited you — that's exactly the feedback this test is for.
