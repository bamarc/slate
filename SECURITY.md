# Security Policy

## Reporting a Vulnerability

**Do not open public issues for security vulnerabilities.** Instead:

1. Contact the maintainers with a clear description, minimal reproducer, and impact assessment.
2. Allow up to 90 days for remediation before public disclosure.
3. We aim to acknowledge reports within 3 business days and ship a fix or mitigation within 30 days for high-severity issues.

## Supported Versions

Security updates target the active development branch (`main` / active feature branches) for:
- `slate-dlang` (`:core`, `:net`, `:mcp`, `:ui`, `:solid`)
- `slint-d` (Dlang bindings and `slint-d/bridge` Rust FFI library)
- `ui/` (Shared Slint component library)
- `slate-dev/` (Portable developer toolchain and MCP bridge)

## Security Baseline & Architecture Hardening

- **Memory Safety (`@safe` D & Rust)**:
  - Dlang modules default to `@safe` with Design-by-Contract (`in`/`out`) preconditions and bounded recursion (`maxTreeDepth = 128`).
  - `extern(C)` FFI boundaries between `slint-d` and `slint-d/bridge` use deterministic `scope(exit)` / `scope(failure)` resource guards.
- **Sandboxed File System Access (`slate.components.file_dialog`)**:
  - `FileDialogController` and `LocalFileSystem` enforce canonical path resolution, strict `sandboxRoot` confinement, sibling-prefix collision checks, and symlink/traversal rejection.
- **Transactional MCP State Mutation (`slate.agent.traits`)**:
  - `McpControllable` controllers snapshot state prior to `mcpSetProperty` mutations and automatically roll back on validation failure or exception.
- **Secret & Dependency Scanning**:
  - Pre-commit hooks and `./scripts/security-scan.sh` scan staged changes with `gitleaks` and audit dependency manifests (`dub.json`, `Cargo.toml`, `package.json`).
