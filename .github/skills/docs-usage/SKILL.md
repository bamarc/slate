---
name: docs-usage
description: 'Guidelines for using and maintaining project documentation. Use this when asked about documentation structure, how to update docs, or where to find style guides.'
---

# Documentation Usage Skill

This project maintains comprehensive documentation. Follow these rules when working with docs.

## Documentation structure
- `docs/guides/` — Style guides by language: `style-python.md`, `style-typescript.md`, `style-yaml.md`, `style-general.md`, `tool-selection.md`
- `docs/agents/` — Agent descriptions: `human-gate.md`, `security-auditor.md`, `docs-bot.md`
- `docs/README.md` — Index of all docs

## Rules
- **Do NOT duplicate information** that exists in docs — reference the doc file instead
- **Do NOT make assumptions** about project conventions — check `docs/guides/style-*.md` first
- **When adding new code**, check if existing docs need updating
- **When adding a new feature**, update relevant README and docs
- **README.md** files should always reflect the current state of the project

## Reading docs
Before implementing anything, check:
1. `docs/guides/style-python.md` for Python conventions
2. `docs/guides/style-typescript.md` for TypeScript conventions
3. `docs/guides/style-yaml.md` for OpenAPI conventions
4. `docs/guides/style-general.md` for git and general conventions
5. `docs/guides/tool-selection.md` before adding any new dependency
