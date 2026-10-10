---
name: git-commit-workflow
description: 'Git commit best practices for this project: commit in logical groups, check gitignore, test before committing. Use this when asked about committing, staging, or preparing a pull request.'
allowed-tools: [shell]
---

# Git Commit Workflow Skill

## Before every commit, follow this checklist:

### 1. ✅ Test and Lint before committing
```bash
# Verify everything passes
just lint
just test
```

### 2. ✅ Check and update .gitignore
- Verify no secrets, credentials, or generated files are being tracked.
- Check if any new generated directories exist (e.g., `frontend/src/api/generated/`).
- Run `git status` to review what's staged.

### 3. ✅ Commit in logical groups
Split changes into **small, focused commits**. Each commit should represent one logical change.

### 4. ✅ Write structured commits with Ticket Numbers
All commit messages are validated by a Husky hook and must follow this structure:

#### Format:
```
<type>(#<ticket-id>-<ticket-short-name>): <short summary>

- <Action-Category>: <Description of specific change 1>
- <Action-Category>: <Description of specific change 2>
```

#### Guidelines:
- **Types**: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`.
- **Ticket Reference**: Must be prefixed with `#` and contain a short name (e.g., `#SPARK-105-husky` or `#123-husky`).
- **Subject line length**: Max 100 characters.
- **Action Categories**: Every body bullet point must start with one of the following action verbs:
  - `Added`
  - `Removed`
  - `Changed`
  - `Fixed`
  - `Updated`
  - `Security`

#### Example Message:
```
feat(#105-security-hooks): integrate husky with gitleaks scanning

- Added: gitleaks check to pre-commit hook
- Changed: package.json script to automatically configure husky on install
- Updated: SETUP.md instructions
```

### 5. ✅ Branch Conventions
- **Main/Dev Branches**: Direct commits to `main`, `master`, or `dev` are discouraged. Always use feature branches for active development and pull requests.

### 6. 🤖 AI Agent Commit Guidelines
When committing code, AI assistants MUST follow this workflow:
1. **Dry-Run Checks**: Run a dry-run of the hook validators (e.g. `./scripts/security-scan.sh` and `python3 scripts/validate-commit-msg.py`) on your proposed commit message before running any actual commit command.
2. **Report Warnings**: If ANY warnings occur during the dry-run (e.g. direct commits to `main`/`dev`, or missing ticket numbers in the branch name), the agent MUST hard report these warnings to the user in their response.
3. **Explicit User Approval**: The agent MUST ask for and receive explicit user approval before executing the actual git commit.
