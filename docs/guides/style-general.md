# Style Guide — General Conventions

## Git Conventions
- **Commit messages**: Conventional Commits format (`type(scope): description`), validated by `python3 scripts/validate-commit-msg.py`:
  ```
  feat(solid): add D controller to TypeScript transpiler
  fix(mcp): preserve rollback snapshot on validation error
  docs(ui): add README and AGENTS.md for Slint component library
  chore: update gitignore for generated Ddoc HTML
  ```
- **DCO**: Sign off commits (`git commit -s`).
- **Branch names**: `type/description` (e.g., `feat/rework-mcp`, `fix/quic-ack-ranges`).
- **Pre-commit validation**: Run `just lint`, `just d-test`, `just slate-test`, and `./scripts/security-scan.sh` before committing.

## Documentation & Specifications
- Every DUB package/subpackage and top-level directory (`slate-dlang/`, `slint-d/`, `ui/`, `slate-dev/`, `examples/`) maintains an up-to-date `README.md` and `AGENTS.md`.
- Architectural plans live in `.agents/plans/YYYYMMDD-HHMMSS-<topic>.md` and use EARS requirements + Gherkin acceptance scenarios.
- Architecture Decision Records (ADRs) live in `docs/adr/` as `NNNN-title.md`.
- Generated documentation (`slate-dlang/docs/`, `slint-d/docs/`) and generated cross-compiled output (`target/solid-ui/`) are gitignored and rebuilt via `just d-docs` and `just solid-codegen`.

## File Naming
| Context | Convention | Example |
|---------|-----------|---------|
| Dlang modules | `snake_case.d` | `file_dialog.d`, `codegen_tsx.d` |
| Slint components | `snake_case.slint` | `media_player.slint`, `dock_layout.slint` |
| Rust bridge modules | `snake_case.rs` | `accessibility.rs`, `instance.rs` |
| Shell scripts | `kebab-case.sh` | `security-scan.sh` |
| Documentation | `kebab-case.md` or `README.md` / `AGENTS.md` | `style-dlang.md`, `style-slint.md` |

## AI Agent Coordination
- Follow the scoped `AGENTS.md` in the target package (`slate-dlang/AGENTS.md`, `slate-dlang/packages/solid/AGENTS.md`, `slint-d/AGENTS.md`, `ui/AGENTS.md`).
- Before adding any external dependency (`dub.json`, `Cargo.toml`, `package.json`), consult `docs/guides/tool-selection.md` and obtain explicit user approval.
- Never execute `git commit` without first running commit/security validations and receiving explicit user approval.
