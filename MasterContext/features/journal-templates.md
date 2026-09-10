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

## 3. A template is an editable object (Sep 2026 — DESIGN, not yet built)

The first version of templates treated a template as something you *captured*
from a cut: write a title page in a manuscript, press Save, and the text
becomes the template's sample. That works exactly once. It makes editing a
template mean editing some manuscript that happens to be linked to it, it makes
"which manuscript is the good one" a question, and it turns every template edit
into a decision about somebody's paper.

**A template is edited directly, in its own tab.** It is a journal cut in
shape — sections, content, export outline — that behaves differently in four
ways.

### 3.1 What is editable

A journal's requirements are only ever about the venue. So a template opens
with the **journal-specific** sections live and everything else out of the way:

| | In a template | Why |
|---|---|---|
| Title page, Letter to the Editor, submission questions, and any section the venue names | **editable** | These *are* the venue's requirements — the layout it wants, the questions it asks, the letter it expects |
| Title, authors, abstract, keywords, figures, tables, bibliography | **blank and inactive** | Journal-agnostic. A venue has an opinion about how they are *set*, never about what they say |

The core parts stay **referenceable**: `[[title]]`, `[[authors.names]]`,
`[[authors.institutes]]` in a template's title page are how the venue's layout
is expressed, and they resolve against whatever manuscript adopts it.

**Letter to the Editor moves to journal-specific.** It is addressed to a named
editor at a named journal and follows that journal's conventions — it was only
ever "core" because every manuscript has one.

### 3.2 Its own workspace

Editing a template opens a **tab of its own, visibly not a manuscript** — its
own colour, so a window that can change a venue's rules never looks like a
window that changes your paper.

Its sidebar is the four parts plus an overview, and nothing else:

```
Overview      title · type · description; Save (overwrite) · Clone · Delete
Summary       the venue's instructions, distilled
Structure     which sections a submission here has
Tests         one per requirement, with the pass rate
Export        the outline and its formatting
              ── the journal-specific sections, editable ──
Title Page
Letter to the Editor
Submission Questions
```

No lineage, no versions, no backend settings: a template is not a manuscript
and should not pretend to be one. **Overview** is the template's identity —
title, type, free-text description — and the three things you can do to it.

### 3.3 The same four parts, in the manuscript too

Summary · Structure · Tests · Export become **sidebar sections for a journal
cut as well**, not a card inside Checks. Each is editable, each says which
template it is linked to, and each offers **Load · Save · Save as new template**
(which creates the template and links to it).

That symmetry is the point: the same four things, in the same order, whether
you are looking at a venue's template or at your cut of it.

### 3.4 Structure, reverted

Calling it "Content" was a mistake to fix rather than defend: the *content*
lives in the sections you can now edit directly, so the part goes back to being
**Structure** — which sections a submission at this venue has.

- Editing it **adds and removes** the template's journal-specific sections, and
  stays in sync with them: add "Public Health Implications" here and the
  section appears; delete it here and the section goes.
- **`required` disappears.** Every section in a template's structure is there
  because the venue wants it; a section you don't want is one you delete.
- A scratchpad section — something you want in your own cut and not in the
  template — is added the ordinary way, from the sidebar. It simply isn't part
  of the template.

### 3.5 What migrates, and when

| Moment | What moves |
|---|---|
| **Adding a journal** | The shape: sections created (empty), questions asked, export formatting adopted. No content. |
| **Fast-forward / backward** | Content. The template's sections overwrite the ones they map to, then the upstream's material arrives — adapted, if Assist is on. Cancel · Append · Overwrite. |
| **Save from a cut** | Per part, confirmed, naming what it overwrites. Structure and Export still capture from the cut; Summary and Tests are copied as they stand. |

### 3.6 Sharing a template

A template is a folder of four JSON files with a GUID and a checksum, which is
already most of what sharing needs. To make it a contribution:

- **Export** writes a single `<slug>.journaltemplate.json` — the four parts,
  the GUID, the checksum, and who exported it.
- **Import** reads one, and resolves by GUID: an unknown GUID is a new
  template; a known one shows what differs, part by part, before overwriting.
- **Contributing upstream** is a pull request against
  `ManuscriptEditor/JournalProfiles/`. The GUID makes the merge deterministic,
  the checksum makes "did this actually change" answerable in review, and
  someone else's corrected BMJ arrives as a diff rather than as a second BMJ.

### 3.7 What this costs

Being straight about the size, because it is the largest change since versions:

1. **A template needs content storage.** `structure.json`'s per-section
   `sample` becomes the section's real content — same file, promoted from
   "example text" to "the text".
2. **A second editing mode.** The editor, sidebar and tab bar currently assume
   a manuscript. A template needs the same views over a different object, with
   core parts suppressed.
3. **Migration.** Existing templates map straight across (`sample` → content);
   existing journals keep their links and checksums.
4. **The Checks card unwinds** into four sidebar sections, for cuts as well as
   templates.

Order I would build it in: content storage first (invisible, testable), then
the template tab with Overview and the editable sections, then the four
sidebar parts for cuts, then export/import and the contribution path.

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
