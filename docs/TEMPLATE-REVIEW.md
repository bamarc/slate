# Template Review & Security Analysis

A snapshot review of the fullstack-template, scoring what is in place and what
should be added before using it as the basis for a production system.

## TL;DR

The template has an unusually strong **DX / agent-governance** story (contract-first
OpenAPI, three governance agents, structured logging, OTEL, layered config, DI
container, repository/service split). It is **not production-ready**: there is
no auth, no CI, no real security headers, containers run as root, secrets are
hard-coded in `compose.yaml`, and the only feature (`items`) has zero tests.

---

## What is good

- **Contract-first**: a single `api/openapi.yaml` drives backend models
  (`datamodel-codegen`) and the frontend client (`orval`).
- **Clear layering**: routes → service → repository → DB; protocols define the
  seams (`app/services/protocols.py`). No business logic in routes.
- **DI container** with lifespan-managed services (`app/services/container.py`,
  wired in `app/main.py`).
- **Observability baseline**: structured JSON logs with `correlation_id` +
  OTEL `trace_id`/`span_id` (`app/core/logging.py`, `app/core/otel.py`,
  `app/core/context.py`), and a `CorrelationIdMiddleware` that echoes the
  header back to clients (`app/core/errors.py`).
- **Layered config**: defaults → `config.yaml` → `config.{APP_ENV}.yaml` → env
  vars, all typed via `pydantic-settings` (`app/core/config.py`).
- **Pydantic v2** + async SQLAlchemy 2.x + Alembic — the modern stack.
- **Agent governance trio** with git-hook enforcement
  (`human-gate`, `security-auditor`, `docs-bot` under `.github/agents/`,
  `.goose/recipes/`, `docs/agents/`).
- **Multi-assistant rule files**: Copilot, Claude, Goose, Cursor, Codeium,
  Antigravity, Kilocode — so the project rules follow the user across tools.
- **Style guides** committed under `docs/guides/` (general, python, ts, yaml,
  tool-selection).
- **Idempotent `generate.sh`** with `--dry-run`, file-count reporting, and
  guardrails ("never edit generated files").
- **`scaffold.py`** lets the template be cloned + renamed in one command.

---

## What to fix / add

### Security (high priority)

| # | Issue | Where | Recommendation |
|---|-------|-------|----------------|
| S1 | **No auth / authz at all** | `api/openapi.yaml`, `app/api/v1/` | Add `securitySchemes` (bearer JWT or OIDC) to the spec; add an auth dependency on routes; create a `User` model + `current_user` dependency. |
| S2 | **No rate limiting** | `app/main.py` | Add `slowapi` or a reverse-proxy-level limit; the items endpoints are open and unmetered. |
| S3 | **No security headers** | `frontend/nginx.conf` | Add `Content-Security-Policy`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy`, `Strict-Transport-Security` (when behind TLS), `Permissions-Policy`. Fixed in this pass. |
| S4 | **Containers run as root** | `backend/Dockerfile`, `frontend/Dockerfile` | Add a non-root user (`USER 10001:10001`) and `--chown` on COPY. |
| S5 | **Hard-coded DB credentials in compose** | `compose.yaml` | Move `POSTGRES_PASSWORD`, `DATABASE_URL` to a `.env` file with an `.env.example` template; never commit real secrets. |
| S6 | **`allow_origins=settings.cors_origins` + `allow_credentials=True` + `allow_methods=["*"]`** | `app/main.py` | OK as long as origins is a strict list; document that `["*"]` is forbidden when credentials are allowed. Add a startup assertion. |
| S7 | **`debug=True` default** | `app/core/config.py` | Default to `False`; only set `True` in `config.dev.yaml`. Debug controls SQL echo + Alembic verbosity. |
| S8 | **No dependency-pinning lockfiles checked** | repo root | Ensure `uv.lock` and `pnpm-lock.yaml` are committed and required by CI. |
| S9 | **No secret scanning** | repo | Add `gitleaks` (or `trufflehog`) to pre-commit and CI. |
| S10 | **`uvicorn` without proxy headers** | `app/main.py` / Dockerfile | Add `--proxy-headers --forwarded-allow-ips=*` when behind nginx so `X-Forwarded-*` is trusted. |
| S11 | **No request body size limit** | `app/main.py` | Configure a max body size (nginx `client_max_body_size`, plus per-route validation). |
| S12 | **No CSRF strategy documented** | docs | If cookies+auth are used, document SameSite + CSRF; if pure bearer tokens, document that explicitly. |
| S13 | **`HTTPException(status_code=…)` raised without `detail`** | `app/domains/items/router.py` | Always pass a structured `detail` so clients can render errors; or raise a domain exception mapped by an exception handler. |
| S14 | **No SBOM / supply-chain artefacts** | CI | Add `cyclonedx-py` / `cyclonedx-npm` in CI to produce SBOMs per release. |
| S15 | **No container image scanning** | CI | Add `trivy fs` + `trivy image` to CI. |

### Quality gates

| # | Issue | Fix |
|---|-------|-----|
| Q1 | Ruff selects only `E F I W` — misses bugs, security, modernisation | Expand to `E,F,I,W,B,UP,S,SIM,C4,RUF,ASYNC,PT` with sensible per-file ignores. |
| Q2 | No `mypy` / `pyright` | Add `mypy --strict` for `app/` in CI. |
| Q3 | No backend test coverage gate | `pytest --cov=app --cov-fail-under=80` in CI. |
| Q4 | No frontend `eslint`/`prettier` configs committed | Add `eslint.config.js` (typescript-eslint, react-hooks, jsx-a11y) and `.prettierrc`. |
| Q5 | No `.editorconfig` | Added in this pass. |
| Q6 | No pre-commit framework | Added `.pre-commit-config.yaml` in this pass (ruff, prettier, gitleaks, hadolint, yamllint, end-of-file-fixer). |
| Q7 | No CI workflows | Added `.github/workflows/ci.yml` in this pass (lint + test + audit + build for backend & frontend). |
| Q8 | `items` domain has **zero tests** | Add repository, service, and router tests (TODO — out of scope for this pass but flagged in the review). |
| Q9 | `request: Request = None  # type: ignore[assignment]` smell | Use `request: Request` (FastAPI injects it) — no default needed. |
| Q10 | `ItemRepository.update` is a manual `__dict__` patch — silently drops `None` values, which means you cannot clear a nullable column | Use `Mapped` fields + explicit `getattr/setattr` on `model_fields`, or accept an explicit "unset" sentinel. |
| Q11 | No license file | Add `LICENSE` (MIT/Apache-2.0). |
| Q12 | No `CONTRIBUTING.md` / `SECURITY.md` / `CODE_OF_CONDUCT.md` | Add — required for OSS / discoverable for internal teams. |
| Q13 | No `CODEOWNERS` | Add for review routing. |
| Q14 | No `dependabot.yml` / `renovate.json` | Add Dependabot for `pip`, `npm`, `docker`, `github-actions`. |

### DX / tooling

| # | Issue | Fix |
|---|-------|-----|
| D1 | Lots of one-off shell snippets in `Agent.md`, READMEs | Consolidated runnable scripts under `scripts/` (this pass): `bootstrap.sh`, `dev.sh`, `test.sh`, `lint.sh`, `format.sh`, `audit.sh`, `clean.sh`, `generate.sh`. |
| D2 | `generate.sh` lived at the repo root, mixed with config | Moved to `scripts/generate.sh`, root path replaced with a tiny shim that prints the new location for muscle memory. |
| D3 | `App.tsx` calls `http://localhost:8000/api/v1/health` directly — bypasses Orval | Use the generated client (`api/generated/`) once Orval has been run; remove hard-coded `API_BASE`. |
| D4 | `Agent.md` references Goose recipes as the canonical source, but `.github/agents/` and `.anthropic/` agents exist in parallel — drift risk | Make agent prompts a single shared file (`docs/agents/*.md`) and have the tool-specific files include it. The current Claude/Goose/Copilot agent files already do this in spirit; keep them slim. |
| D5 | No live-reload guidance for the full stack | `scripts/dev.sh` now starts db + backend + frontend in parallel via `compose`. |

### Documentation

- Add an architecture diagram (Mermaid) to top-level README showing
  spec → codegen → backend/frontend.
- Add ADR template at `docs/adr/0000-template.md`.
- Document the threat model (assumed deployment shape, trust boundaries).
- Document the OTEL exporter expectations (where traces go in each env).

---

## What this change set delivers

- `docs/TEMPLATE-REVIEW.md` (this file).
- Claude Code customization: `CLAUDE.md`, `.claude/agents/*.md`, refreshed
  `.anthropic/instructions.md` with agent + skill index.
- Quality gates: expanded `[tool.ruff.lint]` config, `.pre-commit-config.yaml`,
  `.editorconfig`, `.github/workflows/ci.yml`.
- Security: hardened `frontend/nginx.conf` (security headers + body-size limit),
  documented gaps that need code/structural changes (auth, non-root containers,
  secret handling) in this report.
- Scripts: `scripts/bootstrap.sh`, `dev.sh`, `test.sh`, `lint.sh`, `format.sh`,
  `audit.sh`, `clean.sh`, plus `scripts/generate.sh` (moved). Root
  `generate.sh` becomes a redirect shim.
