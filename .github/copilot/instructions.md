# GitHub Copilot Instructions

## Project Overview
Contract-first fullstack: OpenAPI → FastAPI (Python) + React (TypeScript).

## Language & Style
- Python: type-annotated, async, Pydantic v2, ruff linting — see `.github/instructions/python.instructions.md`
- TypeScript: strict, functional React, named exports — see `.github/instructions/typescript.instructions.md`
- OpenAPI/YAML: see `docs/guides/style-yaml.md`
- General conventions: see `docs/guides/style-general.md` (Conventional Commits, DCO sign-off, file naming)

## Architecture
- **Backend**: `app/` — routes (`api/`) → services (`services/` or `domains/<name>/service.py`) → repositories (`domains/<name>/repository.py`) → DB
- **Frontend**: Orval-generated API client from `api/openapi.yaml`, functional React + Tailwind
- **API**: Contract-first — always edit `api/openapi.yaml` before writing endpoints

## Custom Agents (`.github/agents/`)
- `human-gate.agent.md` — Read-only interview agent for approvals (no write access)
- `security-auditor.agent.md` — Dependency vulnerability scanner
- `docs-bot.agent.md` — Post-commit documentation updater
- `dev-assistant.agent.md` — Maps user intent → the right `just` recipe / script; confirms before destructive runs
- `migration-author.agent.md` — Drafts and reviews Alembic revisions safely

Select any agent from the Copilot Chat agent dropdown.

## Agent Skills (`.github/skills/`)
- `docs-usage` — Documentation structure and conventions
- `alembic-usage` — Database migration guide
- `code-generation` — OpenAPI → frontend client regeneration (includes script)
- `git-commit-workflow` — Commit checklist (test, gitignore, logical groups, conventional commits)
- `scripts-usage` — Reference for every `scripts/*.sh` and matching `just` recipe
- `local-stack-management` — Compose lifecycle, `.env`, healthchecks, troubleshooting
- `auth-integration` — OAuth2/OIDC layer (dev/Entra/Keycloak/Google), roles, protecting endpoints

## Workflow
- Before adding dependencies → follow `docs/guides/tool-selection.md`
- Before architecture decisions → delegate to `human-gate` agent
- After OpenAPI changes → run `code-generation` skill
- Before committing → follow `git-commit-workflow` skill checklist
- After committing → check `docs-bot` agent for doc updates
