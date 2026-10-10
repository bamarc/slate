# AGENTS.md — Project Instructions

Project-wide instructions for GitHub Copilot, Kilo Code, and other compatible
coding assistants. GitHub Copilot remains supported through the `.github/skills/`
and `.github/agents/` configuration.

## Project Overview
This is a **contract-first fullstack template** using:
- **API**: OpenAPI 3.1 specification-driven design
- **Backend**: Python FastAPI (uv-managed), Pydantic v2 models, SQLAlchemy + Alembic or MongoDB
- **Frontend**: React + Vite + TypeScript + Tailwind CSS + Orval (auto-generated API client)
- **Infrastructure**: OpenTofu/Terraform modules targeting Microsoft Azure
- **CI/CD**: GitLab CI with mandatory JFrog Artifactory image publishing

## Key Directories

| Path | Purpose |
|------|---------|
| `/api` | OpenAPI 3.1 specification files |
| `/backend` | FastAPI application (uv project) |
| `/frontend` | Vite + React + Tailwind application |
| `/infrastructure` | Layered OpenTofu configuration |
| `/docs` | Project documentation, ADRs, and runbooks |
| `/scripts` | Repository utility and validation scripts |
| `/.agents/skills` | Project-standard assistant skills |
| `/.kilo/agents` | Kilo Code project-local agents |
| `/.github/skills` | GitHub Copilot skills |
| `/.github/agents` | GitHub Copilot custom agents |

## Assistant Skills

Use the project-standard skills under `.agents/skills/` for architectural planning,
documentation, Alembic migrations, OpenAPI client generation, Git workflows,
scripts and Justfile usage, local stack management, and authentication/OIDC integration.

| Skill | Purpose | Location |
|---|---|---|
| `test-driven-development` | Work test-driven using the Red, Green, Iterate loop: write a focused failing test first, implement the smallest passing change, and keep production code fully testable with useful, behavior-focused tests. | `.agents/skills/test-driven-development/SKILL.md` |
| `debug-failure-analysis` | Systematically debug failures by reproducing them, modelling dataflow and auth flows, mapping involved services and infra/CI-CD, drawing dataflow and sequence diagrams, listing implicated files, tracing git history to find where the problem was introduced, and evaluating specifications for breaches, gaps, or ambiguity. | `.agents/skills/debug-failure-analysis/SKILL.md` |
| `architect` | Architectural planning, trade-off analysis, dataflow modeling, and EARS requirements authoring. | `.agents/skills/architect/SKILL.md` |
| `code-generation` | Regenerate backend Pydantic models and frontend Orval API client from OpenAPI spec. | `.agents/skills/code-generation/SKILL.md` |
| `alembic-usage` | Create, review, apply, and roll back database migrations with Alembic. | `.agents/skills/alembic-usage/SKILL.md` |
| `auth-integration` | Configure and use dual-mode OAuth2/OIDC auth (local mock tokens, Entra ID Easy Auth, Keycloak, GCP). | `.agents/skills/auth-integration/SKILL.md` |
| `git-commit-workflow` | Structured commit conventions, ticket references, pre-commit security checks, and branch rules. | `.agents/skills/git-commit-workflow/SKILL.md` |
| `local-stack-management` | Manage local Docker Compose stack (db, backend, frontend), logs, health checks, and troubleshooting. | `.agents/skills/local-stack-management/SKILL.md` |
| `scripts-usage` | Reference guide for all repository scripts in `scripts/` and their canonical `just` recipes. | `.agents/skills/scripts-usage/SKILL.md` |
| `terraform-usage` | Manage multi-layer OpenTofu cloud infrastructure on Azure, tfvars sync, and state backend. | `.agents/skills/terraform-usage/SKILL.md` |
| `docs-usage` | Guidelines for reading, using, and maintaining project documentation and style guides. | `.agents/skills/docs-usage/SKILL.md` |
| `slate-agent-control` | Inspect, interact with, automate, and capture visual snapshots of Slate desktop applications using the native Model Context Protocol (MCP) toolset and `slate-mcp` CLI helper. | `.agents/skills/slate-agent-control/SKILL.md` |

Kilo-specific configuration lives under `.kilo/`.

GitHub Copilot users may use the corresponding procedures under
`.github/skills/`.

## GitHub Copilot Agents

| Agent | Purpose | Location |
|---|---|---|
| `architect` | Architectural planning, trade-off analysis, and EARS plan authoring | `.github/agents/architect.agent.md` |
| `human-gate` | Read-only interview before risky or architectural changes | `.github/agents/human-gate.agent.md` |
| `security-auditor` | Review new dependencies for CVEs, postinstall behavior, and maintenance risk | `.github/agents/security-auditor.agent.md` |
| `docs-bot` | Update documentation after commits | `.github/agents/docs-bot.agent.md` |
| `dev-assistant` | Route development tasks to the appropriate `just` recipe and confirm destructive operations | `.github/agents/dev-assistant.agent.md` |
| `migration-author` | Draft and review safe Alembic revisions | `.github/agents/migration-author.agent.md` |

Invoke GitHub Copilot agents through the agent picker or with `@<agent-name>`.

## Workflow checklist

1. Work test-driven for all behavior changes: follow the `test-driven-development` skill (Red → Green → Iterate).
2. Edit `api/openapi.yaml` first for any API change.
3. `just generate` (or `scripts/generate.sh`) regenerates backend models + frontend client; generated directories are gitignored and rebuilt at build/CI/dev time.
4. Build the feature; `just test` and `just lint`.
5. Architecture/design change? → `@architect` (or the `architect` skill) to draft EARS requirements, evaluate alternatives, and obtain plan approval.
6. New dependency? → `@human-gate` → `@security-auditor` → `uv add` / `pnpm add`.
7. New migration? → `@migration-author` (or the `alembic-usage` skill).
8. Debugging a failure? → use the `debug-failure-analysis` skill to reproduce, model, and isolate the root cause before fixing.
9. Stuck on which script to run? → `@dev-assistant`.
10. Commit: follow the `git-commit-workflow` skill.
11. After commit: `@docs-bot` for doc updates.

## Plan Mode

- Follow the portable `architect` skill for evidence-driven investigation,
  material alternatives, EARS requirements, and test-driven implementation steps.
- Save the canonical plan in `.agents/plans/YYYYMMDD-HHMMSS-<topic>.md` relative
  to this project root; revise an existing task plan in place. Native viewers
  review that same file rather than maintaining a separate artifact.
- Obtain explicit approval of the current revision through the configured
  agent's review gate before handing off implementation.

## Command and Script Index

Run commands from the repository root. Prefer `just <recipe>` for all available
operations. Using the canonical `just` recipes makes command intent explicit,
enables faster command approval and auto-approval matching, and ensures the
project's environment setup and guardrails are applied consistently. Use a
direct underlying command only when no suitable recipe exists or when a
recipe's argument passthrough cannot express a genuinely narrower check;
extend the `Justfile` when that gap is recurring. Destructive recipes
(`down-hard`, `clean-hard`, and `migrate-down`) require confirmation before an
agent runs them.

### Justfile Recipes

| Recipe | Purpose | Underlying command |
|---|---|---|
| `just` / `just default` | List available recipes | `just --list --unsorted` |
| `just audit` | Run dependency, secret, and container audits | `scripts/audit.sh` |
| `just audit-strict` | Run audits and fail on moderate+ findings | `AUDIT_STRICT=1 scripts/audit.sh` |
| `just bootstrap` | Install backend/frontend dependencies and Git hooks | `scripts/bootstrap.sh` |
| `just clean` | Remove caches, build artifacts, and Python caches | `scripts/clean.sh` |
| `just clean-hard` | Clean and remove generated client code | `scripts/clean.sh --hard` |
| `just ctx` | Print an AI-agent project context snapshot | `scripts/agent-context.sh` |
| `just dev` | Start the attached Docker Compose development stack | `scripts/dev.sh` |
| `just down` | Stop the Compose stack while keeping volumes | `docker compose down` |
| `just down-hard` | Stop the stack and remove volumes | `docker compose down -v` |
| `just format` | Apply Ruff and Prettier formatting after tfvars synchronization | `scripts/format.sh` |
| `just generate` | Regenerate backend models and frontend API client | `scripts/generate.sh` |
| `just generate-dry` | Preview API client/model generation | `scripts/generate.sh --dry-run` |
| `just hooks` | Install Git hooks | `scripts/setup-hooks.sh` |
| `just lint` | Synchronize tfvars and run Ruff, mypy, ESLint, Prettier, and yamllint | `scripts/lint.sh` |
| `just lint-backend [paths...]` | Run targeted backend Ruff checks and format verification | `uv run ruff check ... && uv run ruff format --check ...` |
| `just lint-frontend` | Run frontend ESLint check directly | `cd frontend && pnpm lint` |
| `just logs [service]` | Follow Compose logs for all or one service | `docker compose logs -f [service]` |
| `just migrate` | Apply pending Alembic migrations | `scripts/migrate.sh upgrade` |
| `just migrate-down` | Downgrade one Alembic revision | `scripts/migrate.sh downgrade` |
| `just migrate-history` | Show Alembic migration history | `cd backend && uv run alembic history --verbose` |
| `just migrate-new "msg"` | Create an autogenerated migration | `scripts/migrate.sh new "msg"` |
| `just new-domain NAME` | Scaffold a backend domain | `scripts/new-domain.sh NAME` |
| `just psql` | Open a PostgreSQL shell in the Compose database | `docker compose exec db psql ...` |
| `just sync` | Synchronize global tfvars into infrastructure layers | `python3 infrastructure/layers/sync_tfvars.py` |
| `just test` | Run backend and frontend tests | `scripts/test.sh` |
| `just test-backend` | Run backend tests only | `cd backend && uv run pytest` |
| `just test-frontend` | Run frontend tests once | `cd frontend && pnpm test` |
| `just test-watch` | Run frontend tests in watch mode | `cd frontend && pnpm test:watch` |
| `just typecheck-frontend` | Run the frontend TypeScript compiler without emitting files | `cd frontend && pnpm exec tsc --noEmit` |
| `just build-frontend` | Build the frontend for production | `cd frontend && pnpm build` |
| `just up` | Build and start the Compose stack detached | `docker compose up -d --build` |
| `just _ensure-env` | Require `.env`, copying `.env.example` when absent | shell check and copy |

### Scripts

| Script | Purpose and supported usage |
|---|---|
| `scripts/agent-context.sh` | Print a compact project snapshot; use `--json` for machine-readable output. |
| `scripts/audit.sh` | Run dependency, secret, and container audits; use `--strict` to fail on findings. |
| `scripts/bootstrap.sh` | Install toolchains/dependencies and configure hooks; use `--no-hooks` to skip hooks. |
| `scripts/check-package-security.sh` | Scan `pyproject.toml`, `package.json`, or `Cargo.toml` for package security issues. |
| `scripts/clean.sh` | Remove caches/artifacts; supports soft mode, `--all`, and `--hard`. |
| `scripts/dev.sh` | Start the Compose stack; supports `--detach`, `--no-frontend`, and `--local`. |
| `scripts/format.sh` | Apply Ruff formatting/check fixes and Prettier. |
| `scripts/generate.sh` | Regenerate backend models and frontend Orval client; supports `--dry-run`. |
| `scripts/lint.sh` | Run Ruff, mypy when installed, ESLint, Prettier, and yamllint; supports `--fix`. |
| `scripts/migrate.sh` | Run Alembic commands: default/`upgrade`, `new "msg"`, `down`, `history`, and `current`. |
| `scripts/new-domain.sh` | Scaffold a snake_case backend domain and its tests. |
| `scripts/security-scan.sh` | Run the repository security scan, including gitleaks and dependency checks. |
| `scripts/setup-hooks.sh` | Configure Git to use the repository `.githooks` directory. |
| `scripts/test-validation-hooks.py` | Test the repository validation hooks in an isolated temporary setup. |
| `scripts/test.sh` | Run backend/frontend tests; supports `backend`, `frontend`, and `--watch`. |
| `scripts/validate-commit-msg.py` | Validate commit messages against the project commit-type rules. |

`scripts/README.md` contains the maintained human-facing script reference and
use-case guidance. `check-package-security.sh`, `security-scan.sh`, and the
Python validation utilities are direct script entry points and do not currently
have dedicated Justfile recipes.

---

## 💡 What We Learned (Dev Notes & Troubleshooting)

### Frontend & ESLint Integration
- **Canonical frontend validation**: Use `just format` to apply Prettier formatting and `just lint` to verify Prettier, ESLint, and the remaining repository checks. Use `just typecheck-frontend` for a focused TypeScript check.
- **Generated OpenAPI Artifacts in CI & Linting**: Generated code in `frontend/src/api/generated/` and `backend/app/models/_generated/` is gitignored. In clean CI checkouts or fresh clones, TypeScript-based linting (`eslint .`, `tsc`) will fail with unresolved type errors unless OpenAPI code generation runs first. `ci-support`'s `.lint-ts` job and `scripts/lint.sh` automatically trigger code generation when missing.
- **ESLint Version Compatibility**: The project is using **ESLint v9.x** (`9.21.0`) with Flat Config (`eslint.config.js`). Avoid installing ESLint v10.x directly, as key plugins (e.g. `eslint-plugin-react`) currently rely on APIs removed in v10 (such as `context.getFilename()`), triggering errors like `TypeError: contextOrFilename.getFilename is not a function`.
- **React Compiler Rules**: The linter checks for React Compiler rules (e.g., component purity and React state safety). Side-effects like calling `Math.random()` in rendering/memoization are flagged as impure and should be bypassed or set to `'off'` in `eslint.config.js` (`react-hooks/purity`).
- **Date Range Picker & Outside Days**: When implementing calendar components with `react-day-picker` v9, check `!modifiers.outside` before rendering range styling attributes (`data-selected-single`, `data-range-start`, `data-range-end`, `data-range-middle`). Otherwise, outside days from adjacent months will render overlapping active range selections.

### Backend, Mypy & Unit Testing
- **Async Database Operations**: To execute backend database integration tests successfully, ensure the **`greenlet`** package is installed in the python virtual environment (`uv add greenlet`). Without `greenlet`, SQLAlchemy async session factories raise `ValueError: the greenlet library is required to use this function`.
- **Test database**: Backend DB integration tests require the isolated PostgreSQL `test-db` service. SQLite is not supported because the models use PostgreSQL-specific types such as `JSONB`; set `TEST_DATABASE_URL` when running tests outside the provided service.
- **Mypy Strict Overrides**: The backend code uses dynamic DI and OAuth containers which trigger lint errors in strict mode. Overrides for rules like `PLC0415` (local imports inside functions), `PLW0603` (global statement updates), `PLR0912`/`PLR0915` (high branch count in routing), and `S106` (mock credentials) are configured inside `pyproject.toml` to keep checks passing cleanly.

### GitLab CI, YAML & OpenTofu Validation
- **Single pipeline entrypoint**: Use `.gitlab-ci.yml` for all scopes (`application`, `infrastructure`, `bootstrap`). Infrastructure-specific inputs (`layer`, `image_tag`, `taint_resources`, `tofu_command`, `az_command`) use `spec.inputs.rules` and are only presented for the applicable scope or action.
- **Registry policy**: JFrog Artifactory is the only supported CI container registry. Do not add ACR registry selectors or CI ACR build, push, or deployment jobs. Azure Container Registry OpenTofu modules may remain when they are part of the infrastructure model.
- **JFrog authentication**: CI jobs authenticate to JFrog with `ARTIFACTORY_USERNAME` + `ARTIFACTORY_TOKEN` (basic auth), matching the deployment jobs. Do not use JFrog OIDC token exchange — the JFrog OIDC integration is not configured for it and returns `400 Invalid audience`.
- **YAML linting**: Install the missing linter with `uv tool install yamllint`, then run `yamllint -c .yamllint.yaml .`. Existing repository YAML may report line-length warnings; fix syntax and errors in files changed by the task.
- **OpenTofu layer validation**: Layers (`infrastructure/layers/base`, `networking`, `data`, and `services`) consume versioned OpenTofu modules published to the GitLab Module Registry (`git.eon-cds.de/repos/*`). CI/CD templates are centrally included from `repos/ai-automation-envia/ops/ci-support`.
- **Multi-container support (`v1.2.0-beta`)**: `ci-support` supports multi-container builds and deployments via `containers` (JSON array) or `containers_file` (e.g. `containers.json`, see `containers.example.json`). Each entry specifies `name`, `image_name`, `dockerfile`, `build_context`, `container_name`, and `containerapp_name`. When empty, the pipeline transparently falls back to single-container mode using `image_name`, `dockerfile`, and `build_context`. Symmetrical `enable_backend` and `enable_frontend` flags allow frontend-only or backend-only projects to exclude irrelevant lint and test jobs.

### 🤖 AI Agent Git Commit Rules
- **Commit Dry-Run & Warning Report**: Before executing any git commit, AI assistants must dry-run commit validations and report all warnings (like direct commits to `main`/`dev`, or missing ticket numbers in the branch name) to the user.
- **Explicit Consent**: Commits must be explicitly approved by the user after reviewing the warning report.

### 🤖 AI Agent Subagent / Worktree Rules
- **In-session subagents only**: When the user asks to "use subagents", run them via the in-session `task` tool. Do NOT use Agent Manager (`agent_manager` tool) or create Agent Manager git worktrees unless the user explicitly asks for Agent Manager sessions.
- **Worktree base branch**: If Agent Manager worktrees are ever used, they must be created from the current feature branch (e.g. the active `#<n>-...` branch), never from the default base branch (`main`/`dev`). Worktrees based on the wrong base branch miss the branch's commits and produce broken or conflicting work. Verify the base branch before starting any managed session.
