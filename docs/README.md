# Documentation

## Guides

| Guide | Audience | Description |
|-------|----------|-------------|
| `guides/style-python.md` | All | Python/FastAPI conventions (typing, async, imports) |
| `guides/style-typescript.md` | All | React/Vite/TypeScript conventions |
| `guides/style-yaml.md` | All | OpenAPI/YAML spec conventions |
| `guides/style-general.md` | All | Git conventions, file naming, cross-cutting rules |
| `guides/tool-selection.md` | AI agents | Process for proposing new tools/frameworks |

## Agents

| Agent | File | Purpose |
|-------|------|---------|
| 🧑‍⚖️ Human Gate | `agents/human-gate.md` | Read-only interview agent for approvals |
| 🔒 Security Auditor | `agents/security-auditor.md` | Dependency vulnerability scanner |
| 📝 Docs Bot | `agents/docs-bot.md` | Post-commit documentation updater |

### Goose recipes (`.goose/recipes/`)
```
goose run --recipe .goose/recipes/human-gate.yaml
goose run --recipe .goose/recipes/security-auditor.yaml
goose run --recipe .goose/recipes/docs-bot.yaml
```

### GitHub Copilot agents (`.github/agents/`)
Select from the Copilot Chat agent dropdown:
- `human-gate` — Read-only interview agent
- `security-auditor` — Dependency vulnerability scanner
- `docs-bot` — Post-commit documentation updater

### GitHub Copilot skills (`.github/skills/`)
Skills auto-trigger based on context. Also available:
- `docs-usage` — Documentation structure and conventions
- `alembic-usage` — Database migration guide
- `code-generation` — OpenAPI → frontend client regeneration
- `git-commit-workflow` — Commit checklist (test, gitignore, logical groups)

### Custom instructions (`.github/instructions/`)
Auto-apply based on file patterns:
- `python.instructions.md` — Applied when editing `.py` files
- `typescript.instructions.md` — Applied when editing `.ts`/`.tsx` files
