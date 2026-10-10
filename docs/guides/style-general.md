# Style Guide — General Conventions

## Git conventions
- **Commit messages**: Conventional Commits format
  ```
  feat(backend): add item CRUD endpoints
  fix(frontend): resolve race condition in health check
  docs(api): update OpenAPI spec for items
  chore: bump dependencies
  ```
- **DCO**: All commits must be signed off (`git commit -s`)
- **Branch names**: `type/description` (e.g., `feat/item-crud`, `fix/health-race`)

## Documentation
- Every module has a docstring explaining its purpose
- Functions with non-obvious logic have a brief "why" comment (not "what")
- ADRs (Architecture Decision Records) live in `docs/adr/` as `NNNN-title.md`
- Keep `README.md` files up to date with structural changes

## Project files
- `.env` files are never committed (listed in `.gitignore`)
- Secrets and API keys go through environment variables, never hardcoded
- Configuration has typed defaults in `app/core/config.py` (backend) or `.env.example`
- Dependency changes must be reflected in both pyproject.toml/package.json AND the lockfile

## File naming
| Context | Convention | Example |
|---------|-----------|---------|
| Python modules | `snake_case.py` | `health_service.py` |
| TypeScript/React | `kebab-case.tsx` | `user-profile.tsx` |
| YAML configs | `kebab-case.yaml` | `openapi.yaml` |
| Shell scripts | `kebab-case.sh` | `check-package-security.sh` |
| Documentation | `kebab-case.md` | `style-python.md` |

## AI agent coordination
- Before adding a new tool, framework, or dependency, read `docs/guides/tool-selection.md`
- For elevated-risk dependencies, run `.goose/recipes/security-auditor.yaml`
- After committing, `.githooks/post-commit` triggers doc updates
- Never make project-wide decisions without user approval
