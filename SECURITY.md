# Security Policy

## Reporting a vulnerability

**Do not open public GitHub issues for security problems.** Instead:

1. Email the maintainers (see `CODEOWNERS`) with a clear description, reproducer, and impact assessment.
2. Allow 90 days for a fix before any public disclosure.
3. We aim to acknowledge within 3 business days and ship a fix or mitigation within 30 days for high-severity issues.

## Supported versions

Only the `main` branch is supported. Released versions follow SemVer; security
fixes are backported to the latest minor of the current major when feasible.

## Security baseline (this template)

- All commits scanned by `gitleaks` (pre-commit + CI).
- Dependencies scanned by `pip-audit`, `pnpm audit` (CI).
- Container images scanned by `trivy` (CI).
- Pre-commit security hook (`.githooks/pre-commit`) runs the security-auditor
  agent on dependency changes; high-risk findings block the commit.
- Structured JSON logs with a correlation-id make incident triage faster.
- See `docs/TEMPLATE-REVIEW.md` for the current list of known gaps that
  consumers of this template must close before going to production
  (authentication, non-root containers, rate limiting, secret handling).

## Hardening checklist before production

- [ ] Authentication & authorization on every non-public endpoint
- [ ] Rate limiting (slowapi or proxy-level)
- [ ] All containers run as a non-root user
- [ ] Secrets sourced from a secret manager, never committed
- [ ] TLS terminated at the edge; `Strict-Transport-Security` enabled
- [ ] CSP audited for the production frontend build
- [ ] Backups + restore drills for PostgreSQL
- [ ] Centralised log + trace pipeline wired (OTLP endpoint set)
- [ ] SBOM published with every release
