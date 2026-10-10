# Security Auditor Agent

**Purpose:** Scans dependency files (`pyproject.toml`, `package.json`, `Cargo.toml`)
when they change during a session. Checks each new or updated package for known
vulnerabilities and evaluates risk level before installation.

## How it works

1. **Detects changes** — compares before/after state of dependency files
2. **Researches packages** — checks PyPI / npm / crates.io for each new dependency
3. **Scores risk** — evaluates based on CVEs, maintenance, postinstall scripts, transitive deps
4. **Escalates** — if risk is elevated, hands off to the human gate before allowing install

## Risk levels

| Level | Action | Example |
|-------|--------|---------|
| 🟢 Low | Allow (inform user) | Well-known lib, no CVEs, small dep tree |
| 🟡 Medium | Warn + ask user | Minor CVE, large dep tree, unmaintained |
| 🔴 High | Block + escalate to human gate | Known exploit, postinstall script, no maintenance |

## Goose recipe

```bash
goose run --recipe .goose/recipes/security-auditor.yaml
```

Or invoke during a session to check a specific file:

```
Delegate to security-auditor with: "check pyproject.toml for new deps"
```

## Integration

The `.githooks/pre-commit` hook runs the security auditor automatically when
`pyproject.toml` or `package.json` changes.
