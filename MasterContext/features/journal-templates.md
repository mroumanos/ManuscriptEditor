# Journal Templates — design and migration

A **template** is the reusable configuration a manuscript's journal is created
from, and compared against afterwards. A **journal** in a manuscript is an
*instance* of one: it has its own name, its own content, and its own copy of
the rules.

This document is the design of that relationship, and of how a template's
contents migrate into a manuscript. For the AI side see
[ai-assist.md](ai-assist.md); for the pane that edits all of this see
[../04-information-architecture.md](../04-information-architecture.md).

---

## 1. Why an instance is not a template

You can cut "BMJ test 1" and "BMJ test 2" from the BMJ template in one
manuscript. Renaming either side breaks nothing, because the link is not a
name — it is:

| On the journal | Meaning |
|---|---|
| `profileID` | the template's GUID |
| `templateName` | the template's name when it was adopted |
| `templateChecksum` | the template's checksum when it was adopted |

`Journal.profile` saves back under `templateName ?? name`, so renaming a cut
never renames the template it came from.

**Edited-since is a comparison, not a flag.** The pane asks whether each part
differs from the template as the library holds it — never whether someone
remembered to mark something dirty. A journal whose template is missing (it was
deleted, or the manuscript arrived from someone else) reads as *not linked*, and
**Link Template…** states the link rather than guessing it from a name.

## 2. The four parts

A template is four files in one folder, and each moves independently:

```
<slug>/requirements.json   the Summary — the venue's instructions, distilled
<slug>/checks.json         the Tests — one per requirement, machine-evaluated
<slug>/structure.json      the Content — what a submission here contains
<slug>/export.json         the Export outline and its formatting
```

Each part has its own checksum, its own **Open · Load · Save** on its row, and
its own confirmation. Tightening a test should not publish a summary you were
halfway through rewriting.

### Summary
Bullets in a standard vocabulary — `description:`, `limits:`, `components:`,
`format:`, `extra:` — grouped on display. The link at the top is the authority;
the summary is a distillation, and says so.

### Tests
Every requirement that can be checked, evaluated against the cut. Every
required Content section also gets its own `EXISTS` test, so a missing section
names itself instead of hiding inside one "matches the structure" verdict. The
app's fixed parts (title, authors, abstract, references, cover letter)
deliberately get none — the app supplies those, and a test would look for a body
section that cannot exist.

### Content
More than a list of headings. Per section:

- **presence** — required or optional
- **the content itself** (`sample`) — the title-page layout a venue expects, the
  boilerplate it wants
- **Format** (`formatNote`) — how the section must be *written* here
- **Notes** (`note`) — why the journal asks for it
- **export formatting** (`format`) — the typography this venue sets it in
- **questions** — for a question series, the questions with their word or
  character limits

Plus, for the whole document: `coreFormats` (the typography of the fixed parts —
title page, byline, abstract …) and `documentFormat` (page geometry).

### Export
The outline: which documents a submission is, what goes in each, page breaks,
and per-item format. Carried in the template since Sep 2026 — before that it
lived in a second, parallel library, which is why a template saved from a
manuscript never appeared when adding a journal.

## 3. Migration: what moves, and when

This is the part that took three tries to get right.

| Moment | What moves |
|---|---|
| **Adding a journal** | The SHAPE only. Sections are created empty; a question series arrives with its questions (those are the journal's, not the author's); export formatting is adopted. **No content.** Adding a journal must never put words in a manuscript. |
| **Fast-forward / backward** | Content. The template's content overwrites the sections it maps to, then the upstream's material arrives — adapted, if Assist is on. This is the moment the user asked for this journal's content to be (re)made. |
| **Save to template** | The other direction: this cut's active sections, their text, their formatting and its questions become the template's. Hidden sections are excluded — switching one off is how you say it isn't part of this submission. |

**Every sync offers three outcomes**: Cancel, **Append** (keep what is there,
add the incoming content after it) and **Overwrite**. A cut you have already
worked on shouldn't have to be replaced wholesale to take an upstream revision.

**The rule: nothing changes irreversibly without asking.**

⌘Z reverses every manuscript-side action — adding a journal, loading a part,
linking a template, renaming a journal, any sync including an assisted
fast-forward (one keystroke, and the previous content is also a stamped
version). Bookkeeping that only records what already happened (seeding a
profile on open, storing the template checksum after a save) is deliberately
not undoable, because there is nothing there to undo.

Writes to the **library** are files outside the manuscript, so ⌘Z cannot reach
them. Every one of them is therefore **confirmed first, naming what it
overwrites**: saving a part, saving or branching the whole template, cloning,
deleting, and renaming. Renaming used to commit when a text field lost focus —
silent and irreversible, the one combination this rule exists to prevent — and
now needs Rename… pressed, with Revert beside it. `rename` also writes before
it cleans up, and only removes a folder it has confirmed still holds the same
template.

## 4. The corpus, and where to fix it

Three places hold templates, in order of authority for a given manuscript:

1. **bundled** — `ManuscriptEditor/JournalProfiles/<slug>/`, ships with the app,
   version-controlled, reviewable on GitHub
2. **library** — the user's own copy in Application Support, seeded from bundled
   on first run
3. **manuscript** — the copy that travels with the manuscript, so a collaborator
   opens it with the rules the author used

The manuscript's copy always wins for evaluation. **Fix the bundled corpus**:
`load()` re-seeds any bundled profile the library no longer holds, so a
correction made only in Application Support is restored to the stale version the
moment its folder goes missing. This has bitten twice; see gotcha 21 in
[../08-engineering-standards.md](../08-engineering-standards.md).

## 5. Open questions

- The old `AppStore.journalLibrary` registry survives only to supply publisher
  and country, which a template doesn't carry. Folding those two fields into the
  template file would retire it.
- Per-section export formatting is carried and applied, but can only be *seen*
  in the Export pane.
