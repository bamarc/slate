# Documentation Bot Agent

**Purpose:** Automatically updates project documentation when code changes.
Triggers after `git commit` to regenerate or update docs based on changed files.

## How it works

1. **Post-commit hook** — triggered by `.githooks/post-commit`
2. **Diff analysis** — compares changed files against the last documentation update timestamp
3. **Targeted updates** — only regenerates docs for modules that actually changed
4. **Auto-commits** — creates a follow-up commit with doc changes (or stages them)

## Coverage

| Docs directory | Watches |
|----------------|---------|
| `docs/guides/` | New features, API changes, configs |
| `backend/README.md` | New domains, services, or routes |
| `frontend/README.md` | New components, hooks, or pages |
| `api/openapi.yaml` | Backend route changes |

## Goose recipe

```bash
goose run --recipe .goose/recipes/docs-bot.yaml
```

Or invoke manually:

```
Delegate to docs-bot with: "update docs for recent changes to health service"
```
