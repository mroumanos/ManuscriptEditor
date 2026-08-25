# Journal profiles

One file per journal (and article type): **where its rules come from**, and
**what the app checks**.

```
{
  "id": "…slug…",              // also the file name
  "name": "…",
  "articleType": "…",          // optional
  "sourceRequirements": {
    "url": "https://…",        // the journal's author-instructions page
    "summary": "…"             // a distilled, human-readable summary
  },
  "checks": [ … ]              // executable rules; see below
}
```

`sourceRequirements` is the **reference** — a link plus prose. `checks` is
what the app **enforces**.

## Checks

A check is a list of conditions joined by `ALL` or `ANY`:

```
{
  "name": "Abstract ≤ 250 words",
  "combinator": "ALL",
  "conditions": [
    {
      "metric": "LENGTH_WORDS",         // LENGTH_WORDS | LENGTH_CHARS | COUNT | EXISTS | CONTAINS
      "scopes": [{ "kind": "abstract" }],// several scopes measure TOGETHER
      "subsections": [],                // headings inside those scopes; empty = all
      "comparator": "<=",               // <= | >= | == | !=
      "number": 250,
      "text": ""                        // for CONTAINS
    }
  ]
}
```

Scope kinds: `title`, `subtitle`, `abstract`, `keywords`, `authors`, `body`,
`section` (with `"name": "Methods"`), `figures`, `tables`, `references`,
`coverLetter`.

A check with `"manual": true` and no conditions renders as a checkbox the
author ticks by hand.

## Where a profile lives

- **App defaults** — this folder. Shipped with Manuscript Editor and linked
  from the Checks pane.
- **This manuscript** — the moment you edit a journal's checks or source
  requirements, a copy is written to `journals/<slug>.json` inside the
  manuscript folder, so it travels with the manuscript locally and in its
  remote repository. The Checks pane then links there instead.
