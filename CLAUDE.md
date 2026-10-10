# CLAUDE.md — Claude Code Project Rules

> Claude Code reads this file at session start. Keep it short and link out for detail.

## Project
**Contract-first fullstack template.** OpenAPI 3.1 in `api/openapi.yaml` drives:
- backend Pydantic v2 models (`datamodel-codegen` → `backend/app/models/_generated/`)
- frontend TypeScript client (`orval` → `frontend/src/api/generated/`)

**Stack:** Python 3.12 + FastAPI + async SQLAlchemy 2 + Alembic · React 19 +
Vite 6 + TypeScript 5.7 + Tailwind 4 · PostgreSQL 16 · OpenTelemetry · pnpm + uv.

## Hard rules

1. **Spec first.** Any API change starts in `api/openapi.yaml`. Then run
   `scripts/generate.sh` before touching backend or frontend code.
2. **Never edit generated files.** Anything under `*/generated/` or
   `*/_generated/` is rewritten by codegen.
3. **Style guides are authoritative.** See `docs/guides/` for python, typescript,
   yaml, and general conventions.
4. **No new dependencies without the human gate.** Use the `human-gate`
   subagent. After approval, the `security-auditor` subagent must run before
   `uv add` / `pnpm add`.
5. **Conventional Commits + DCO sign-off** (`git commit -s`).

## Where things live

| Area | Path |
|------|------|
| API spec | `api/openapi.yaml` |
| Backend app | `backend/app/` (routes `api/`, domains `domains/`, infra `core/` `db/` `services/`) |
| Backend tests | `backend/tests/` |
| Frontend app | `frontend/src/` (generated client in `src/api/generated/`) |
| Migrations | `backend/alembic/versions/` |
| Docs | `docs/` (guides, agents, ADRs in `docs/adr/`) |
| Scripts | `scripts/` (bootstrap, dev, test, lint, format, audit, generate, clean) |
| Agents | `.claude/agents/` (Claude Code), `.github/agents/` (Copilot), `.goose/recipes/` (Goose) |
| Skills | `.github/skills/` (alembic, code-generation, docs-usage, git-commit) |

## Common commands

```bash
scripts/bootstrap.sh   # install backend + frontend deps, setup git hooks
scripts/dev.sh         # start db + backend + frontend (compose)
scripts/test.sh        # backend pytest + frontend vitest
scripts/lint.sh        # ruff + eslint + yamllint
scripts/format.sh      # ruff format + prettier
scripts/audit.sh       # pip-audit + npm audit + gitleaks
scripts/generate.sh    # regenerate backend models + frontend client from OpenAPI
scripts/clean.sh       # wipe caches and generated artifacts
```

## Subagents (Claude Code)

`.claude/agents/` defines three subagents:

- **human-gate** — read-only interview. Invoke before any architecture change,
  dependency addition, or destructive action. Has no write access.
- **security-auditor** — vets new dependencies for CVEs, postinstall scripts,
  maintenance. Blocks on high-risk findings; escalates to `human-gate`.
- **docs-bot** — after committing, propose doc updates for the touched files.

Invoke with the `/agents` selector or by name (`@human-gate`, `@security-auditor`,
`@docs-bot`).

## Skills

The `.github/skills/` directory contains step-by-step procedures. Read them
before doing the matching task:

- `alembic-usage` — creating, running, and managing migrations
- `code-generation` — regenerating the frontend client (and backend models)
- `docs-usage` — where docs live and how to update them
- `git-commit-workflow` — commit checklist (test → gitignore → group → message)

## Workflow defaults

- **Add an endpoint:** edit `openapi.yaml` → `scripts/generate.sh` → add a
  router in `backend/app/api/v1/` (or `domains/<name>/router.py`), service in
  `domains/<name>/service.py`, repo in `domains/<name>/repository.py`, schema in
  `domains/<name>/schemas.py`, tests in `backend/tests/`. Then consume on the
  frontend via the regenerated client.
- **Add a dependency:** invoke `@human-gate` → if approved, `@security-auditor`
  → then `uv add <pkg>` (backend) or `pnpm add <pkg>` (frontend).
- **Run a migration:** `cd backend && uv run alembic revision --autogenerate -m
  "msg"` → review the file → `uv run alembic upgrade head`.
- **Before committing:** `scripts/test.sh && scripts/lint.sh && scripts/audit.sh`.

## Security baseline

- Never commit secrets. `.env*` is gitignored; use `.env.example` for shape.
- All endpoints that mutate state require auth (when the auth scheme is added —
  see `docs/TEMPLATE-REVIEW.md` for the current gap).
- Validate at the boundary with Pydantic. Trust internal types.
- Log via `logging.getLogger("app")` — never `print`. Never log tokens, PII,
  passwords, or full request bodies.
- Errors return structured JSON with a `correlation_id`. Don't leak stack
  traces in responses.

## When in doubt

Read `docs/TEMPLATE-REVIEW.md` for the open gaps and `docs/guides/tool-selection.md`
for the decision process.
