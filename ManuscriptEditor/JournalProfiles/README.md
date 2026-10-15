# Journal profiles

One folder per journal profile. Each holds the three configuration files the
app reads:

| File | What it is |
|---|---|
| `requirements.json` | The journal's own instructions — a link to its author-instructions page and the distilled requirements, one per bullet. Reference material, not executable. |
| `checks.json` | `{"checks": [...]}` — the rules the app evaluates: automatic ones (`LENGTH_WORDS`, `LENGTH_CHARS`, `COUNT`, `EXISTS`, `CONTAINS`, `STRUCTURE`, `FONT_SIZE`, `LINE_SPACING`, `LINE_NUMBERS`) over `scopes` of a `type` (`title`, `subtitle`, `abstract`, `keywords`, `authors`, `body`, `section` with its `name`, `figures`, `tables`, `references`, `coverLetter`, `export`), and manual ones the user ticks by hand. Nothing else: no ids (a reader derives them from the rule), no identity (that is requirements.json's). Older files said `kind` and carried ids; both are still read. |
| `structure.json` | The manuscript sections a submission is expected to have, and the venue's say about each. Every entry can carry `type` (`text`, the default, or `questions` — a series of submission questions, each with `prompt`, `wordLimit`, `limitUnit` and its own `boilerplate`), `boilerplate` (the content a new cut starts with — `[[title]]`, `[[authors.names]]`, `[[authors.institutes]]` resolve), `formatNote` (how the section must be written — sent to the model when a cut is adapted), `note` (why the venue asks), `required`, and `format` — the section's typography (`fontFamily`, `fontSize`, `lineSpacing`), which lives here and nowhere else, so an outline that prints a section twice cannot disagree with itself. An `Abstract` entry describes the abstract field. Seeds a new cut, and the `STRUCTURE` check verifies it. Nothing else — no identity, no ids. Older files say `kind`, `sample`, a top-level `documentFormat` and an `id`; all are still read. |
| `export.json` | The venue's export outline, in these words: `documents`, each of a `type` (`docx`, `pdf`, `rtf`, `latex`) and its **document sections** — each with its own `margin`, `lineNumbers`, `pageNumbers` and `columns` (unsaid = inherit), and each beginning on a new page — holding `items` of `type: component` named by `title`: a manuscript section's title from `structure.json`, or a fixed component — `Title Page`, `Authors`, `Abstract`, `Keywords`, `References`, `Tables`, `Figures`, `Cover Letter`. No ids, and no typography on a document — typography is a component's: a fixed component carries its `format` on its item; a manuscript section's is the structure's. Anything else an item carries passes through under `settings`. The two AJPH profiles carry one: a separate title-page document, a blinded manuscript in four document sections, and the cover letter. Absent when the standard outline the app derives from the structure is the venue's. |

`requirements.json` carries the profile's `id` — its **GUID**. Identity lives
in that GUID, not in the folder name: one journal can carry several profiles (different
article types), a rename must not orphan a manuscript's copy, and the GUID is
what maps a manuscript's journal to an entry in the user's library.

These files are the **defaults**. On first run they are copied into the user's
journal library at
`~/Library/Application Support/ManuscriptEditor/JournalLibrary/<slug>/`, and
from then on that library belongs to the user. A manuscript carries its own
copy at `journals/<slug>/` so it opens the same way on someone else's machine;
where the two disagree, the Checks pane flags the part that differs and offers
to save it back.

## Editing

The files are hand-editable — `id` is the only field a check needs, and rules
may omit their own ids. A profile is loaded whole: `requirements.json` carries
the identity, so it is the one file a profile cannot do without.

## Generated profiles: the JAMA Network and Health Affairs Scholar

The thirteen JAMA Network journals (JAMA, JAMA Network Open, JAMA Health
Forum, and the specialty journals) and Health Affairs Scholar ship **one
profile per article type** — `jama-research-letter`,
`jama-dermatology-original-investigation`,
`health-affairs-scholar-policy-inquiry`, and so on — because the limits
differ by type far more than by journal. Those folders are **generated**:
`scripts/corpus/<network>/<journal>.json` holds each journal's article
types with the limits its Instructions for Authors state and, for every
number, the page's own sentence; what a publisher's journals share
(abstract layouts, the key-points box, formatting, export tests) is the
`NETWORKS` table in `scripts/corpus/build_corpus.py`, which turns the specs
into the three files here. Edit the spec and re-run the script; a hand-edit
to a generated folder is undone by the next run (`build_corpus.py --check`
says whether any is stale).

Article types the instructions describe without author limits — Editorials,
Invited Commentaries and the commissioned Clinical Review & Education
features — have no profile, and neither does Poetry (a poem is not a
manuscript this app writes). A journal's own formats appear under its name
in Settings → Journals and in Add Journal.

Health Affairs Scholar's site blocks automated reading of its instructions,
so that spec's limits come from search-indexed excerpts of the official
page; its `unread` field and each type's `notes` say what could not be
retrieved (manuscript formatting, the Letters' limits).

## A note on the summaries

Each `requirements.json` is the app's distillation of that journal's published
instructions, with a link to the page it came from. Journals revise these, and
most publisher sites block automated fetching — treat the bullets as a working
summary and confirm against the linked page before submitting.
