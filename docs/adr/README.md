<!--
ADR-README-VERSION: 1.0.0
STATUS: 2026-06-27
SOURCE: ci-support/docs/onboarding/adr/README.md (Single Source of Truth)
NOTE: This file is materialized to docs/adr/README.md during project onboarding.
      If an older version exists in the project repo, reconcile it deliberately.
      Projects place their own ADRs as separate files here (no originals in ci-support).
-->

# Architecture Decision Records (ADR)

This folder collects the architecture decisions of this project as **Architecture Decision Records (ADRs)**. ADRs complement the [arc42-light Canvases](../architecture/acc.md) (`acc.md` / `aic.md`) with individual, traceable decisions.

> General explanations (when to use an ADR vs. ACC/AIC, Nautilus context) are centralized in [platform-dev-docs](https://git.eon-cds.de/repos/ai-automation-envia/ops/platform-dev-docs). This README describes only **convention and template** for the ADRs of this project.

---

## Convention

| Point | Rule |
| --- | --- |
| **Filename** | `NNNN-short-title.md` (running number zero-padded, kebab-case). Example: `0001-stack-fastapi-over-nestjs.md`. |
| **Format** | Markdown, following the template below. |
| **Language** | English (consistent with the rest of the project documentation). |
| **Status** | An ADR goes through: `Draft` → `Accepted` → (optionally) `Superseded`. If a decision is revised, **do not delete**, but set the old ADR to `Superseded` and link a new one. |
| **Storage** | All ADRs in this folder. No subfolders. |
| **Linking** | ACC/AIC reference relevant ADRs (Core Decisions → ADR number). |

---

## Template for a single ADR

Copy this structure into a new file `NNNN-<short-title>.md`:

```markdown
# NNNN. <Title of the decision>

**Status:** Draft | Accepted | Superseded
**Date:** YYYY-MM-DD
**Deciders:** <who decided>
**Relevant ADRs:** <numbers of superseded or dependent ADRs>

## Context
What problem / question is at hand? What constraints are relevant?
(What happens if we don't answer the question?)

## Decision
What was decided? – one concise sentence, plus 3–6 bullets.

## Rationale
Why this option? Which criteria prevailed?

## Considered Alternatives
Which other options were examined, and why rejected?

## Consequences
Positive + negative + risks + follow-up ADRs / open points.
```

---

---

*Compliance context (Nautilus NJE, auditable gaps) see [platform-dev-docs](https://git.eon-cds.de/repos/ai-automation-envia/ops/platform-dev-docs).*

*Template source: `ci-support/docs/onboarding/adr/README.md` (version header above).*
