# Utility scripts

One-shot scripts for humans **and** agents. All scripts are POSIX-bash, idempotent, and safe to re-run.

| Script | What it does |
|--------|--------------|
| [bootstrap.sh](bootstrap.sh) | Install backend (uv) + frontend (pnpm) deps and set up git hooks. Run once after cloning. |
| [dev.sh](dev.sh) | Start the stack via docker compose. `--local` runs backend/frontend on host with the db in compose. |
| [test.sh](test.sh) | Run backend pytest + frontend vitest. `backend` / `frontend` / `--watch` flags supported. |
| [lint.sh](lint.sh) | ruff + mypy (if installed) + eslint + yamllint. `--fix` to apply ruff fixes. |
| [format.sh](format.sh) | ruff format + prettier. |
| [audit.sh](audit.sh) | pip-audit + pnpm audit + gitleaks + trivy (when installed). `--strict` fails on any finding. |
| [generate.sh](generate.sh) | Regenerate backend Pydantic models + frontend Orval client from `api/openapi.yaml`. `--dry-run` shows what would change. |
| [migrate.sh](migrate.sh) | Alembic wrapper: `upgrade`, `new "msg"`, `down`, `history`, `current`. |
| [new-domain.sh](new-domain.sh) | Scaffold a new backend domain (`<name>/{models,schemas,repository,service,router}.py` + a test file). |
| [clean.sh](clean.sh) | Wipe caches and generated artifacts. `--hard` also removes `node_modules` and `.venv`. |
| [setup-hooks.sh](setup-hooks.sh) | Point git at `.githooks/` (pre-commit + post-commit). Called by `bootstrap.sh`. |
| [agent-context.sh](agent-context.sh) | Print a one-screen project snapshot for AI agents (`--json` for machine-readable). |
| [test-scaffold-webapp.sh](test-scaffold-webapp.sh) | End-to-end scaffolding test: bootstraps clone via `scaffold.py`, configures port (10000+), runs `docker compose up`, verifies HTTP 200, pulls down, and prints timing breakdown. |

## Agent vs human use cases

| Use case | Recommended script |
|----------|--------------------|
| First-time setup (human) | `bootstrap.sh` |
| Daily development (human) | `dev.sh` / `test.sh --watch` |
| CI run (machine) | `lint.sh && test.sh && audit.sh --strict` |
| Agent orienting at session start | `agent-context.sh` |
| Agent regenerating client after spec change | `generate.sh` |
| Agent adding a new domain | `new-domain.sh <name>` |
| Agent verifying before commit | `test.sh && lint.sh && audit.sh` |

## Conventions

- All scripts use `set -euo pipefail`.
- All scripts derive `ROOT_DIR` from their own location, so they work from any cwd.
- Scripts exit non-zero on failure and return the worst exit code observed.
- Optional dependencies (mypy, gitleaks, trivy, prettier, pre-commit) are detected at runtime — missing tools log a hint and skip, never crash.
