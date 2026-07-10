# 03 — Versions & Lineage Design

> Design guidance for the journal/version/lineage model — the app's "git-grade
> power with zero git vocabulary" (00 §4). The model itself is defined in
> [`02-domain-model.md`](../02-domain-model.md); acceptance criteria in
> [`05-features.md §E–F`](../05-features.md#e-versioning-within-a-journal).

## 1. Keep the three axes verbally and visually distinct

The most common versioning-UX failure is blending layers into one "history"
soup. This app has three distinct axes; every surface must make clear which one
it is showing:

| Axis | Question it answers | Where it lives |
|---|---|---|
| **Journal** | "Which target is this copy for?" | Tab chips, Journals panel |
| **Version** (`v1, v2…` per journal) | "Which save point of that journal?" | Per-pane version control, Versions pane |
| **Lineage** (edges between versions) | "What was this derived from, and is it stale?" | Journals panel tree, Sync pane |

Version numbers are always **per-journal ordinals** — "NEJM v2" — never a
global counter.

## 2. Saving and version identity

- **Save** updates the journal's working content; **Save new version** stamps a
  new `vN`. Both live in the per-pane version control (`v3 ▾`) and the Versions
  pane. These are the only save verbs users see.
- **Unsaved edits are loud**: the tappable unsaved-changes banner ("Unsaved
  changes. Click here to save.") appears whenever a journal has unsaved edits
  and triggers Save. It must be prominent but not modal.
- Viewing a non-head version marks the tab **"(older)"** — the user must never
  mistake an older version for the working head (00 §3.3). Rolling back/forward
  moves only that journal.
- The free-text version label ("Synced from NEJM v2") is secondary context in
  pickers — it names the upstream, not the journal, so it is never the tab or
  pane identity.

## 3. Version history (per journal)

- The Versions pane is **per-tab** (its tab's journal, no picker): the linear
  history (v1 → v2 …, newest = working head), the lineage diagram of its
  upstream and downstream journals, and the selected version's details.
- **Leaf-only delete**: only the newest version may be deleted, with a
  confirmation that names it. No mid-history surgery.
- Timestamps display relative ("2 h ago") up to 48 h, absolute after; hover
  always reveals the absolute form.

## 4. Sync — explicit, individual, honest

- Sync is a per-edge fast-forward, **never recursive**. The Sync pane shows one
  card per target journal: the upstream edge (name + parent-version badge), the
  journal's current head badge, a drift status, and the Sync button.
- **Status must never overstate freshness.** When the upstream journal is
  itself behind *its* upstream, the card warns "sync it first" (orange) instead
  of a green "up to date"; when current only through an intermediate journal,
  the card dates the content actually carried.
- The sync confirmation names exactly what will happen in plain language: it
  overwrites the journal's working head, previous versions remain in history,
  and it names the exact snapshot being copied ("Nature does not pull from
  Source directly — sync NEJM first, then Nature").
- A **sync icon on an edge** in the lineage tree signals a fast-forward is
  available. Lineage defaults to the **compressed** view (journal nodes labeled
  with current version, edges labeled with parent version); clicking an edge
  opens the **detailed** history between those two journals.

## 5. Rollback and destruction standards

- **Rollback soft-archives** the newer versions it removes — hidden but
  recoverable, never hard-deleted. The confirmation states this ("previous
  versions remain recoverable"), so rollback reads as safe course-correction,
  not deletion.
- Every destructive or history-altering action follows one rule: **exactly one
  of {undoable, confirmed}** — never both, never neither. Confirmations state
  the concrete loss ("Deletes NEJM v3 — 1,204 words differ from v2"), never a
  bare "Are you sure?".
- Version/lineage operations never block typing in other panes; the UI stays
  interactive while a version is stamped.

## 6. Copy tone

Sync/rollback copy should feel like *managing derivations of a paper*, not
operating a VCS: "re-derive from Source v3", "restore the earlier derivation",
"this cut was made from NEJM v1". No commit/branch/merge/HEAD anywhere in UI
(00 §4).
