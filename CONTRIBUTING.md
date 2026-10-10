# Contributing

Thanks for your interest. This template values **small, reviewable changes**
that respect the contract-first workflow.

## Setup

```bash
scripts/bootstrap.sh   # installs backend + frontend deps, sets up git hooks
```

## Before you push

```bash
scripts/test.sh        # backend pytest + frontend vitest
scripts/lint.sh        # ruff + eslint + yamllint
scripts/audit.sh       # pip-audit + pnpm audit + gitleaks
```

Pre-commit will also run the above on staged files.

## Workflow

1. **Discuss first** for non-trivial changes — open an issue or invoke the
   `human-gate` agent.
2. **Spec first** — any API change starts in `api/openapi.yaml`, then run
   `scripts/generate.sh`.
3. **Branch naming**: `type/short-description` (e.g. `feat/item-tags`).
4. **Commits**: Conventional Commits + DCO sign-off (`git commit -s`).
5. **PRs**: small, focused, with the diff explained in the description. Tests
   and docs land in the same PR as the code.

## Style

- Python — see `docs/guides/style-python.md` and
  `.github/instructions/python.instructions.md`.
- TypeScript — see `docs/guides/style-typescript.md` and
  `.github/instructions/typescript.instructions.md`.
- YAML — see `docs/guides/style-yaml.md`.
- General (commits, file names, secrets) — see `docs/guides/style-general.md`.

## Adding dependencies

This template gates dependency additions:

1. Invoke the `human-gate` agent. Explain what, why, and what alternatives exist.
2. After approval, the `security-auditor` agent vets the package.
3. Only then run `uv add <pkg>` (backend) or `pnpm add <pkg>` (frontend).

See `docs/guides/tool-selection.md` for the decision criteria.

## Reporting security issues

Do **not** open a public issue. See `SECURITY.md`.
