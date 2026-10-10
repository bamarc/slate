# Tool / Framework Selection Guidelines

This document defines the process for **AI agents** (and humans) when proposing
a new tool, framework, library, or dependency for the project.

---

## 1. Before proposing anything

Ask yourself (or the user) these questions first:

1. **Is there already something in the stack that does this?**
   - Check `backend/pyproject.toml`, `frontend/package.json`, and existing code
   - Duplicating functionality is a hard no

2. **Is the problem solvable with configuration instead of code?**
   - Environment variables, linter rules, or build tooling may suffice

3. **Is the tool widely maintained?**
   - Check GitHub stars, last release date, open issue count
   - Prefer tools with >1k GitHub stars and a release within the last 6 months

---

## 2. AI agent process

When an AI agent identifies a need for a new tool/framework:

```
1. Research → Find 1-3 candidate libraries
2. Brief     → Summarise each: what it does, why needed, alternatives
3. Escalate  → Present to the user (HUMAN GATE required)
4. Wait      → Do NOT install anything until the user approves
5. If approved → Run security-auditor on the dependency first
6. Install   → Use `cargo add`, `uv add`, `pnpm add` (never manual edits)
```

The **human gate agent** handles step 3:
- **Goose**: `goose run --recipe .goose/recipes/human-gate.yaml`
- **GitHub Copilot**: Select the `human-gate` agent from the chat dropdown

---

## 3. Evaluation criteria

| Criterion | Weight | Notes |
|-----------|--------|-------|
| Maintenance | High | Released within 6 months, active issue tracker |
| Community | Medium | >1k stars or >500k weekly npm downloads |
| License | High | Must be MIT, Apache 2.0, BSD, or compatible |
| Bundle size | Low | Only matters for frontend browser bundles |
| Security | High | No open CVEs; run via security-auditor |
| API stability | Medium | Prefer v1.x+ over v0.x; no breaking changes expected |
| Alternatives | Medium | At least 2 alternatives considered before choosing |

---

## 4. What requires user approval

**Always ask** before:
- Adding a new runtime dependency (backend or frontend)
- Adding a new dev dependency that introduces >10 transitive deps
- Changing the database, framework, or language version
- Adding a paid service or SaaS dependency
- Introducing a build tool, code generator, or linter that requires config

**Can be auto-approved** (but still inform user):
- Type packages (`@types/*`, `typing_extensions`)
- Dev tooling with no runtime impact (prettier, eslint rulesets)
- Patch/minor version bumps within existing dependencies
