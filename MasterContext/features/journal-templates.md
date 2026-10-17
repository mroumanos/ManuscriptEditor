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
<slug>/structure.json      the Structure — the sections, their content,
                           and the typography a cut adopts
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
app's fixed parts (title, authors, abstract, references)
deliberately get none — the app supplies those, and a test would look for a body
section that cannot exist.

### Structure
More than a list of headings. Per section:

- **name** — name of the section
- **id** — stable, so renaming a section is a rename and not a delete-and-add.
  Written as `id` (which the fingerprint strips) and derived from the title for
  a file that has none, so every install agrees about which section is which.
- **kind** — `text`, `questions`, or `letter` (a text box that also carries a
  letterhead and a signature).  A section is a section whatever its kind; a
  letter entry becomes a letter section in the manuscript, boilerplate and all
- **boilerplate** (`boilerplate`) — the default content a journal gets when it
  is added: free-form for text sections, the questions for a question series.
  It may reference `[[title]]`, `[[authors.names]]`, `[[authors.institutes]]`.
  **Editable only while editing a template** — never captured from a cut.
- **export formatting** (`format`) — the typography of the sections export

Plus, for the whole document: `coreFormats` (the typography of the fixed parts —
title page, byline, abstract …) and `documentFormat` (page geometry). Both are
in `structure.json` itself; they were in the in-memory model only until Sep
2026, so a template lost its typography every time it reached the library (see
gotcha 22).

### Export
The outline: which documents a submission is, what goes in each, page breaks,
and per-item format. Carried in the template since Sep 2026 — before that it
lived in a second, parallel library, which is why a template saved from a
manuscript never appeared when adding a journal.

## 3. A template is an editable object (Sep 2026 — BUILT)

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
with the **journal content** live and the **core content** out of the way —
the split [`02-domain-model.md`](02-domain-model.md) defines once, in
`Models/ContentClass.swift`:

| | In a template | Why |
|---|---|---|
| Title page, submission questions, and any section the venue names — the abstract's format included, as an entry titled "Abstract" | **editable** | These *are* the venue's requirements — the layout it wants, the questions it asks |
| Title, authors, keywords, figures, tables, bibliography, the letter to the editor | **blank and inactive** | Journal-agnostic. A venue has an opinion about how they are *set*, never about what they say — and the letter's letterhead, signature and format are the author's |

The core parts stay **referenceable**: `[[title]]`, `[[authors.names]]`,
`[[authors.institutes]]` in a template's title page are how the venue's layout
is expressed, and they resolve against whatever manuscript adopts it — as do
`[[journal.name]]` and `[[journal.type]]`, which resolve to the journal the
export is for, so a template's letter can address the venue by name.

**The letter is the author's, not the venue's (Sep 2026).** For a week it
was a section kind a template could carry, added and removed like any other.
That was the wrong owner: a letter's letterhead, signature and format belong
to the person submitting and do not change from journal to journal. So it is
a **fixed pane** again — a row after Bibliography, above the rule, made the
first time it is opened and carried whole into every cut. The storage stayed
what the section-kind week left it (one `ManuscriptSection` of kind `.letter`
with `LetterDetails`), so nothing written in between needs converting; the
kind is simply not offered from Add Section, not listed with the sections,
not captured into a template, and a template's letter entry is ignored
wherever sections are read. In the outline it is the fixed *Letter to the
Editor* item (`coverLetter`) — the standard outline gives it a document of its
own with the heading off, and a template's outline can add it from Add Item,
since a venue may want the letter in the package. Manuscripts written before the
section-kind week carry `letterToEditor`; the store turns it into the section
on load
(`migrateLetter`) and never writes it. Old outlines' `.coverLetter` items are
pointed at the first letter section, or dropped; the `coverLetter` check
scope means "every letter section".

### 3.2 Its own workspace

Editing a template opens a **tab of its own, visibly not a manuscript** — its
own colour, so a window that can change a venue's rules never looks like a
window that changes your paper.

The colour is a wash, not a slab, and it sits on an **opaque** base: a
translucent band over an editor lets the editor's own chrome — the gutter rule
— show straight through it, so the rule appeared to run from the tab bar to
the bottom of the window. The rule belongs to the editor and starts where the
editor starts.

Its sidebar is the same three pages a cut has, and its content:

```
Template   Details       Local: Save · Load   Remote: Save · Load   Delete
                         About (name · type · publisher · country ·
                         description · version · last saved · branched from)
                         Requirements (link · one requirement per line)
           Tests         one per requirement
           Export        the outline, and how every part is set
Content    Title · Authors · Keywords · Figures · Tables ·
           Bibliography · Letter to the Editor   ← listed, greyed, inactive
           ───────────────────────── the soft rule a manuscript has
           Abstract                  ← always here: the venue's say about it
           Title Page
           Public Health Implications
           Submission Questions
           Add Section
```

**The Abstract is past the rule, in every template.** A venue always has a
say about the abstract — structured or not, which headings, in what order, a
boilerplate — so the row is there whether or not the template says anything
yet. The entry (`StructureSection` titled "Abstract", uid
`TemplateWorkspace.abstractUID`) is made on the first edit that leaves
something in it; opening the row never dirties the template. Its title and
kind are fixed: renamed, it would become an ordinary section every manuscript
creates. In a manuscript it never makes a second section — it seeds the
cut's abstract **section** (a section of its own kind since Sep 2026) when
the journal is added, pairs with it in the fast-forward prompt by kind (so a
renamed abstract still finds it), and the `STRUCTURE` test counts a written
abstract as meeting it.

**Content reads exactly as a manuscript's sidebar does** — the fixed parts
first, in their usual order, then the rule, then the sections. Nothing moves
to make room for the template; a template is a different object, not a
different app. The window's own chrome is untouched too: the title above the
sidebar stays the manuscript's, because that is what the window is. What says
"template" is the tab, the pane headers, and the colour.

No lineage, no versions, no backend settings: a template is not a manuscript
and should not pretend to be one. **Details** is where a save goes and what
the template is: the **About** box — name, type, publisher, country, a
free-text description (which is the requirements' `description:` bullets,
not a second field to disagree with them), version, last saved, ancestor —
and the **Requirements** box, the link and one requirement per line. There
is no Structure pane (Oct 2026): the sections below the rule are the
structure.

**No pass rate here.** A template has no content to measure, and a percentage
with nothing behind it is a number people would trust. The rate belongs to a
cut, where the sidebar carries it: *Tests (86%)*.

**A section is edited in the ordinary editor.** `RichEditor` — the one a body
section uses — so "/" opens the same picker and typing is the thing you
already know. In a template it offers the **part tokens only** (`/title`,
`/authors` → `[[title]]`, `[[authors.names]]`, `[[authors.institutes]]`):
those resolve wherever the template lands, while a citation or a figure
reference would point at one paper's bibliography and be wrong in every other.

**Export is the manuscript's Export pane, and it is where ALL formatting
lives.** Not a second, smaller editor: the same `ExportDocumentCard`, given
the template's sections instead of a paper's. Each row's formatting summary
opens `ComponentSettingsForm` — typography, the printed heading and its style,
the byline's delimiter, markers, + corr / + cred, the reference list's citation
style, the keyword delimiter. Those controls used to hang off a gear in each
component's own pane, which put the outline in one place and what it prints in
another, and left a template — which has no panes — unable to set any of it.
The gear is gone from the panes.

An outline saved from a manuscript names that manuscript's sections by id, so
a template repairs what it is given: unknown section items are dropped and the
template's own sections take their place, in Structure order.

**Opening a gear is not an edit.** SwiftUI controls settle their bindings
as they appear, and every one of those writes used to land in the outline —
so looking at a row's settings marked the Export part as differing from the
template. A write that changes nothing is dropped at both ends now.

**Export options are in Export, and nowhere else.** An outline edit changes
the Export part and only the Export part. For a while every outline edit was
mirrored into the structure (`coreFormats`, `documentFormat`, each section's
`format`), which made changing a font show up as a change to the *Structure* —
two parts that answer different questions ("what is a submission made of?"
and "how is it set?") coupled by a convenience. `structureCapture` no longer
captures formats either.

What a journal ADOPTS when it is added is therefore the **outline itself**,
pointed at the manuscript (`ManuscriptStore.adoptTemplateExport`): each
section item is matched by title through the template — uid → title → this
manuscript's section — the fixed parts pass straight through, and anything
that matches nothing is dropped. Copying the outline
raw, which is what happened before, left every section row reading "(missing
section)". The per-section `format` fields are still read for templates that
never had an outline, and are otherwise legacy.

The four parts are marked with an orange pencil where the draft has moved away
from the library's copy, and the tab carries a dot while anything is unsaved —
`TemplateWorkspace` holds every edit in memory until Overview saves it.

**Order is dragged, not stepped.** Structure rows and a question series'
questions reorder by drag, the way the sidebar and the Authors list do; the
up/down chevrons were the odd ones out.

**Publisher and country belong to the template.** They lived on a separate
registry entry, which meant a template could be managed in one place and its
country set in another — in Settings, where nothing else was editable. They
are identity now (`RequirementsDoc.publisher` / `.country`, ignored by the
fingerprint like the name), edited in the template's Overview; Settings →
Journals only reads.

### 3.3 The same pages, in the manuscript too

Details · Tests · Export are **sidebar sections for a journal cut as well**,
not rows in a card inside Checks. Each is this manuscript's own copy, edited
in place — grey boxes, a prominent pencil that becomes save / discard
(`JournalBox`, `EditControls`) — under one header: the journal's icon, name,
type, the instructions link and one warning icon. Details alone carries
**Save** and **Load**. Load takes the template's copy of the whole
configuration. **Save opens the template editor with this manuscript's copy
as the draft** — the cut never writes into a template directly (see *Where a
template is edited* below); it carries its copy to the one place a template
is saved, and from there to disk and to the shared repository.

The structure has no page in either place (Oct 2026). **A cut's active
sections are its structure**: adding a journal deactivates, in that cut, the
sections its template doesn't name; activating one (the eye) makes it part of
the journal and gives the structure an entry for it; grey means deactivated
and nothing else. The journal's say about a section — required, type, the
prompt shown while it is empty, the AI context, the default content — sits
behind the **gear in the section's pane header**, beside the eye, preview and
notes (`PaneSettingsButton`), where the writing happens. How a component
prints is set on the Export page's row and nowhere else: a section can print
in two documents, and only the row says which copy.

**What a cut may change is its own copy, and that is a lot**: its summary, its
tests, its export outline and formatting, and which sections it has. None of
it touches the template — which is the point. A scratchpad section, a tighter
limit, a different page for this one submission: all fine, all local.

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
| **Adding a journal** | The shape and the venue's content: sections created, the cut's copies holding the boilerplate (tokens live) and the questions; none of the upstream's text, and not its abstract either — an "Abstract" entry in the structure seeds it like a section. Export formatting adopted. |
| **Fast-forward / backward** | The upstream's text, into every section it has text in; a section it leaves empty keeps the cut's own (boilerplate or written). Adapted on the way, if Assist is on — the model's rewrite is the last word. Cancel · Append · Overwrite. |
| **Load into a cut** | Per part, confirmed, naming the template it comes from. Nothing written is touched, and ⌘Z undoes it. |
| **Add to Template Library** | The whole configuration becomes a template — overwriting the one it came from, or as a new one. The only path from a cut into the library, and it is a deliberate one. |

### 3.6 Every template ships with the manuscript

**Rule: a manuscript carries the rules it was written to — all of them, every
time.** Not only the modified ones: carrying just those leaves the rest
depending on the app that opens the manuscript being the app that made it, so
an app update that corrects a bundled template would silently re-grade a
finished paper, and a withdrawn one would leave a journal with no rules at all.

- On every save, `writeTravelingProfiles()` writes
  `journals/<template-slug>/{requirements,checks,structure,export}.json` for
  every journal in the manuscript.
- The folder is named for the **template**, not the cut: "BMJ test 1" and "BMJ
  test 2" both carry `journals/bmj/`, because what travels is the venue's rules.
- `gatherRemoteFiles` includes those folders, so they reach the remote with
  everything else. They did not before — a modified template stayed on the
  machine that modified it, which is the gap this rule closes.
- On open, the manuscript's copy wins for evaluation (see §4).
- **Longer term**, a public repository of templates is the natural home for
  sharing — §3.7's single-file export is the unit it would trade in.

### Modifying, saving, overwriting

| Action | What happens |
|---|---|
| **Edit a template, don't save** | Held in memory. Nothing on disk changes, and nothing a manuscript uses changes. |
| **Overwrite** | Same GUID, **next version**, new `updatedAt`, and a fresh **checksum for every part** — all three written into `requirements.json`. Re-saving an untouched template does *not* take a version; nobody else's copy should look stale because you pressed Save. |
| **Save under a changed name or type** | A **new** template: new GUID, version 1, lineage pointing back at what it came from; no overwrite warning, because nothing is overwritten, and the tab becomes the new template's. There is no rename. |
| **Save a draft a manuscript brought** | The journal whose Details → Save opened the editor takes the saved copy; if the save made a new template, the journal's link moves to it (`linkToTemplate`) — said in the dialog, because it is the one effect you cannot see. |

Because each part's checksum is recorded, a manuscript can say **which part**
drifted — Summary, Structure, Tests or Export — using only the copy it carries.
The pane marks exactly those parts, and says nothing about the ones that match.

### Where a template is edited

**In the template editor, not in a manuscript.** A cut's Details · Tests ·
Export are *its own copy*: edited in place, **Load**ed from the template, and
never written back from the page. **Save** on the cut's Details opens the
template editor seeded with that copy (`TemplateWorkspace.open(_:seedFrom:
export:)`); the save is made there, under the template's rules — unique name
and type, a version, checksums — and goes back to the journal that brought
it. Editing a template from inside a manuscript made every template change
also a decision about somebody's paper, and left "which manuscript is the
good one" a real question; carrying the copy to the editor keeps the edits
and keeps the decision in one place.

### 3.7 Sharing: a template travels with the manuscript, and has a shared home

A manuscript carries **the whole of every template it uses** — the four
files under `journals/<slug>/`, written on every profile edit — and each
journal names its template by **GUID** (`Journal.profileID`). So a
collaborator opens the manuscript with the rules the author used, whatever
their own library holds.

Templates also have a shared home: the app's own repository, under
`ManuscriptEditor/JournalProfiles/<slug>/` — the bundled corpus, reviewed on
GitHub, shipped with every release (`TemplatePublishing`, Oct 2026).

- **The check.** A journal's copy is compared against the published one by
  slug (the folder a name and type derive — which is why a name and type are
  unique in a library), then by GUID, then part by part. The outcome is one
  warning icon beside the template's name on Details, Tests and
  Export, and on the template's own panes: *not published*, *differs:
  Tests, Export*, or *a different template is published under this name*. A
  check that cannot reach GitHub says nothing — no warning beats a false
  one. Reads need no token (the repository is public); a changed copy is
  checked again at once, an unchanged one every ten minutes.
- **Adding a journal takes the published copy when it has moved on.** Add
  Journal fetches the template's `checksum.txt` from the shared repository
  (one small file); if it differs from the library copy's checksum and the
  library copy is **untouched** — still what it took from the bundle or the
  repository, by its recorded `publishedChecksum` — the published files are
  pulled into the library and the journal is cut from them. So a template
  corrected on `main` reaches every install without a new build. An edited
  library copy is kept (the icon says it differs); offline, the library copy
  is used at once. Remote Load records the published checksum too.
- **Remote Save = a pull request, never a merge.** The template's Details
  has the rows a manuscript's has — **Local: Save | Load**, **Remote: Save |
  Load** — with a picker for which of the app's GitHub accounts a proposal
  goes out under. Remote Save writes the template's files to a branch
  (`template/<slug>`) in the repository when the token may push to it, in a
  fork otherwise, and opens a pull request; the review decides what every
  install seeds from. Remote Load takes the published copy into the draft
  (same GUID only — a different template under the name must be renamed
  first). Remote Save needs the draft saved locally first: a proposal sends
  what your library holds.
- **One header on every page.** Details, Tests and Export share the
  journal's header — icon, name, type, the instructions link, the warning
  icon — and Details carries **Save** (the template editor, seeded with
  this copy) and **Load** (the template's copy, whole). No Copy: a template
  of your own is a save under a new name.

### 3.8 What it cost, and where it lives

Built in the order it was planned, and the plan held:

1. **Content storage.** `structure.json`'s per-section `sample` became
   `boilerplate` — the same file, promoted from "example text" to "the text" —
   and sections gained a stable `uid` so one can be renamed while you edit it.
   `StructureDoc` gained `coreFormats` and `documentFormat`, which it should
   always have had.
2. **A second editing mode.** `JournalTab.template` puts a template in the
   window's tab bar; `TemplateSidebarView` replaces the manuscript's sidebar
   while one is active, and `TemplateDetailRouter` routes its panes.
   `TemplateWorkspace` holds the open drafts — **edits live in memory until
   saved**, which is the whole safety property.
3. **Migration.** Nothing to migrate: `boilerplate` reads `sample`, derived
   section ids are stable, and the fingerprint ignores both new id fields, so
   no existing template's checksum moved.
4. **The Checks card unwound** into `JournalSummaryView` (Details), a
   sidebar section beside Tests and Export.

| Where | What |
|---|---|
| `Store/TemplateWorkspace.swift` | open drafts (seeded from the library, or from a journal's copy), dirty/edited-parts, save · save-as-new · revert · delete |
| `Views/Template/TemplateEditor.swift` | the sidebar, the router, the pane header |
| `Views/Template/TemplateDetailsView.swift` | Save and Load rows, About, Requirements |
| `Views/Template/TemplatePartEditors.swift` | Tests · Export |
| `Views/Template/TemplateSectionView.swift` | one of the venue's sections |
| `Views/JournalPartViews.swift` | the header and Details, as a cut holds them |
| `Views/PaneSettingsPopover.swift` | the gear on a section's format bar: the journal's fields and the export item |
| `Views/CheckRulesEditor.swift` | `CheckRuleCard`, one test editable, and the template's list of them |
| `Theme/JournalBox.swift` | the box and the pencil → save / discard standard |
| `Theme/TemplateStyle.swift` | the colour that says "not your paper", and the pane width |
| `Views/ComponentFormatViews.swift` | one component's export settings, over a binding |

## 4. The corpus, and where to fix it

Three places hold templates, in order of authority for a given manuscript:

1. **bundled** — `ManuscriptEditor/JournalProfiles/<slug>/`, ships with the app,
   version-controlled, reviewable on GitHub
2. **library** — the user's own copy in Application Support, seeded from bundled
   on first run
3. **manuscript** — the copy that travels with the manuscript, so a collaborator
   opens it with the rules the author used

The JAMA Network's thirteen journals and Health Affairs Scholar ship **one
bundled profile per article type**, generated from
`scripts/corpus/<network>/<journal>.json` by `scripts/corpus/build_corpus.py`
— the specs carry the page's own sentence for every limit, and the generated
folders are never hand-edited (see the corpus
[README](../../ManuscriptEditor/JournalProfiles/README.md)).
`scripts/harness/corpus_profiles.sh` checks that every bundled profile decodes
whole under the GUID its slug derives.

A library copy that has never been saved there (version 1, no checksums of
its own) **follows the bundle**: when the app ships a newer version of that
GUID, `load()` rewrites it. A saved copy is the user's and stays — the
published-copy check says when it differs. Journals that track the library
(never edited in the manuscript) take the refreshed copy on open
(`seedProfileIfNeeded`); an edited journal keeps its own until a part is
Loaded.

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
