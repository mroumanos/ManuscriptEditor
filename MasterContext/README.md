# Master Context — Manuscript Editor

This folder is the **single source of truth** for what the Manuscript Editor app
is, how it should behave, and how it should be built. It exists so that any
contributor — human or LLM — can load it and produce work that fits the product
without re-deriving requirements from scattered prompts.

> If a change request conflicts with this folder, the folder wins unless the
> request explicitly updates it. When requirements change, **update these docs in
> the same change** so they never drift from the code.

## How to use this folder

- **Starting a coding task with an LLM?** Paste [`00-master-prompt.md`](00-master-prompt.md)
  as the system/context prompt, then add the specific task. It links to the
  deeper docs below for detail.
- **Need a specific detail?** Go straight to the relevant numbered doc.
- **Adding reference screenshots/mockups?** Drop them in [`assets/`](assets/) and
  link them from the relevant doc.

## Contents

| Doc | Purpose |
|-----|---------|
| [00-master-prompt.md](00-master-prompt.md) | The condensed, paste-ready context prompt for any LLM task. |
| [01-product-vision.md](01-product-vision.md) | The problem, the users, the goals, and the non-negotiable principles. |
| [02-domain-model.md](02-domain-model.md) | Entities, relationships, and the Journal / Version / Lineage model. The schema. |
| [03-architecture.md](03-architecture.md) | Tech stack, stores, persistence, file layout, services. |
| [04-information-architecture.md](04-information-architecture.md) | Navigation, the journal comparison tabs, and where each thing lives. |
| [05-features.md](05-features.md) | Feature-by-feature behavior with acceptance criteria. |
| [06-design-system.md](06-design-system.md) | Visual language: theme, typography, color, components, the editor. |
| [design/](design/) | Deep design context: ranked principles, per-surface UX rules, interaction patterns, accessibility. Extends 06-design-system and the wireframes. |
| [07-wireframes.md](07-wireframes.md) | ASCII layouts of every major screen. |
| [08-engineering-standards.md](08-engineering-standards.md) | Code structure, documentation, testing, and known platform gotchas. |
| [09-roadmap.md](09-roadmap.md) | Phase I & II (build now) vs Phase III (stub), and current build status. |
| [10-performance-plan.md](10-performance-plan.md) | Audited performance/smoothness findings and the phased fix plan. |
| [glossary.md](glossary.md) | Precise definitions of every domain term. |
| [examples/](examples/) | Real UI reference images (editor bar, ruler, line numbers, notes, unsaved banner, lineage views) — embedded throughout the docs. |
| [assets/](assets/) | Space for additional screenshots/mockups + design inspiration. |

## The one-paragraph version

Manuscript Editor is a **native macOS, account-free** desktop app for writing one
**source** manuscript and adapting it into per-**journal** copies ("cuts") that
each satisfy a target journal's formatting and length rules. Each journal
(including the root Source) carries its own **version** history, and **lineage**
edges track which version was derived from which. Raw data lives once in a central
**Data** repository and is referenced (never copied) by figures/tables via SQL, so
a cut only re-expresses presentation, not data.
Users bring their own **backends** (GitHub, Google Docs, …) and **AI services**
(Claude, …); the app requires neither to write the source. The product bar is a
**professional, modern, trustworthy writing tool** — clean typography, light/dark
theming, and a comparison-first editing surface.
