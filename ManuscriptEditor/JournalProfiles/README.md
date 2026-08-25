# Journal profiles

One folder per journal profile. Each holds the three configuration files the
app reads:

| File | What it is |
|---|---|
| `requirements.json` | The journal's own instructions — a link to its author-instructions page and the distilled requirements, one per bullet. Reference material, not executable. |
| `checks.json` | The rules the app evaluates: automatic ones (`LENGTH_WORDS`, `COUNT`, `EXISTS`, `CONTAINS`, `STRUCTURE`, `FONT_SIZE`, `LINE_SPACING`, `LINE_NUMBERS`) and manual ones the user ticks by hand. |
| `structure.json` | The sections a submission is expected to have. Seeds a new cut, and the `STRUCTURE` check verifies it. |

All three share an `id` — the profile's **GUID**. Identity lives in that GUID,
not in the folder name: one journal can carry several profiles (different
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

## A note on the summaries

Each `requirements.json` is the app's distillation of that journal's published
instructions, with a link to the page it came from. Journals revise these, and
most publisher sites block automated fetching — treat the bullets as a working
summary and confirm against the linked page before submitting.
