# 01 — Product Vision

## The problem

Submitting a scientific manuscript to different journals usually means a near
complete rewrite. Each journal imposes its own word counts, section structure,
citation style, figure/table rules, and export format. On top of that, authors
bounce between Google Docs, Office 365, and others to collaborate — none of which
handle the full set of manuscript components (figures, tables, references) well.

## The product

A **native macOS desktop app** where the author maintains **one source
manuscript** and adapts it into journal-specific **cuts**. The hard,
open-ended work of fitting requirements (e.g. trimming 2,500 → 2,000 words) is
assisted by an LLM; the mechanical work (limit checks, required sections) is a
deterministic checklist. The app is easy enough for a non-technical researcher
yet structured enough to keep data, versions, and formatting rigorous.

## Who it's for

Researchers and academic authors who submit to multiple journals and want to stop
rewriting the same paper. They are domain experts, not necessarily technical.

## Goals

- Write and manage a **source** manuscript with all standard components.
- Adapt the source into journal **cuts** that meet each journal's requirements,
  with AI assistance for soft decisions and a deterministic checklist for hard
  rules.
- **Compare** source and cuts side-by-side, section by section.
- Keep **raw data** in one place, referenced by figures/tables via SQL so a cut
  changes presentation only.
- Let users bring their own **storage/collaboration backends** and **AI
  services** — no app account.
- Eventually **export** and **submit/publish** to journals with status tracking.

## Non-negotiable principles

1. **Account-free.** Download and use immediately. Persistence, collaboration,
   and AI are optional third-party integrations.
2. **Local-first.** A manuscript is a folder on disk the user chooses; the app
   reads/writes there. Backends sync that folder; they don't own it.
3. **One source of truth for data.** Imported data lives once in the Data
   repository. Figures/tables reference it by SQL. Cuts never duplicate or edit
   the underlying data.
4. **Versions are comparable peers.** Source and every cut share the same
   component set so they align for side-by-side comparison and review.
5. **AI assists, never silently rewrites.** AI generates cuts and performs opt-in
   revisions; the source is fully editable without any AI configured.
6. **Professional, modern, trustworthy.** The UI must feel like a polished
   writing tool: clean typography, light/dark theming, generous whitespace,
   minimal chrome. Sloppy or "demo-grade" UI is a bug.

## What success looks like

- An author writes their paper once, then spins up Nature/NEJM/Cell cuts, sees
  exactly what each requires, and edits cuts side-by-side against the source.
- A figure's underlying data is imported once; changing the journal changes only
  the SQL/format, and the numbers are provably identical across cuts.
- The author never created an account and chose where their files live.

## Explicit non-goals (for now)

- Not a general word processor or a LaTeX IDE (LaTeX may be an export backend
  later, but the frontend stays non-technical).
- Not a reference manager (Zotero integration is a future plugin, not a rebuild).
- Not a cloud service. No server, no app accounts, no telemetry.
