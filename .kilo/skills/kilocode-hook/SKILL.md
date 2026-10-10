---
name: kilocode-hook
description: Use when the user asks to write a Kilo Code hook, custom command, or automation script. Hooks live in `.kilo/command/` (custom slash commands) or `.kilo/run-script` (session startup script).
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux, windows]
metadata:
  hermes:
    tags: [kilocode, hook, command, automation, project-local]
    related_skills: [kilocode-skill, kilocode-agent, kilocode-instruction, kilocode-setting, kilocode]
---

# Kilo Code Hook & Command Authoring

Create, edit, or manage Kilo Code hooks and custom commands. These are automation entry points that let you define reusable, parameterized workflows triggered by slash commands or session startup.

## Hook Types

### 1. Custom Slash Commands (`.kilo/command/`)

Files in `.kilo/command/` become invokable slash commands. The filename (minus `.md`) is the command name. These are markdown files with YAML frontmatter that define a reusable workflow.

**Location**: `.kilo/command/<name>.md`

**Example** — `.kilo/command/review-pr.md`:

```markdown
---
description: Review a GitHub PR and write summary reports
---

Review $1.

Branch off so we have all the code for the reviewed PR. Then run the
following reviews in parallel, using one subagent per review, and save
each result in a named markdown file at the repository root.

## Security Review
Check for input validation issues, auth flaws, data exposure.

## Performance Review
Check for N+1 queries, missing indexes, blocking operations.

When all subagents are done, commit the report files and create a draft PR.
```

**Parameters**: Use `$1`, `$2`, etc. for positional arguments passed when invoking the command (e.g., `/review-pr https://github.com/org/repo/pull/42`).

### 2. Run Script (`.kilo/run-script`)

A single file at `.kilo/run-script` that executes on session startup. This is a shebang-style script — shell or executable.

**Location**: `.kilo/run-script`

**Example**:

```bash
#!/bin/bash
# Session startup script — runs every time a Kilo Code session starts
echo "Project: $(basename $(pwd))"
echo "Node: $(node --version)"
echo "Git branch: $(git branch --show-current)"
```

Or for VS Code extension development:

```bash
bun run extension
```

### 3. Workflow Files (NEW)

Kilo Code also supports workflow definitions (see `/docs/customize/workflows`). These are more structured automation definitions. Check the latest docs for the current format.

## Workflow

### Create a Custom Command

1. Ask the user for the command name and what it should do
2. Determine if it needs parameters (`$1`, `$2`, etc.)
3. Create `.kilo/command/<name>.md` with `write_file`
4. Write YAML frontmatter with `description`
5. Write the body: clear, step-by-step instructions for the agent
6. Reference parameters with `$1`, `$2`, etc.

### Edit a Command

1. `read_file` the command file
2. Use `patch` for targeted edits, `write_file` for rewrites

### Create/Edit Run Script

1. `read_file` the existing `.kilo/run-script` (if any)
2. Use `write_file` to create or overwrite
3. Make sure it's executable: `chmod +x .kilo/run-script`

### Delete a Command

```bash
rm .kilo/command/<name>.md
```

## Pitfalls

1. **Command not appearing** — Check file is in `.kilo/command/` (not `.kilo/commands/`). Use `/reload` to pick up new commands.
2. **Parameter syntax** — Use `$1`, `$2` — not `{1}`, `%1`, or `{{1}}`.
3. **Run script permissions** — Must be executable (`chmod +x`) and have a valid shebang line.
4. **Run script errors** — If the run script fails, it may silently prevent the session from starting. Test it manually first.
5. **Confusing commands with agents** — Commands are one-shot workflows. Agents are persistent personas. Don't put agent prompts in the command directory.
6. **Overly complex commands** — If a command needs 50+ lines of instructions, consider making it a skill (`.agents/skills/`) instead. Commands are best for parameterized, repeatable workflows.

## Verification

- [ ] Command file at `.kilo/command/<name>.md` with YAML frontmatter
- [ ] `description` field present in frontmatter
- [ ] Body contains clear, step-by-step instructions
- [ ] Parameters (`$1`, `$2`) are documented in usage notes if present
- [ ] Run script (if applicable) is executable and has valid shebang
- [ ] Run script (if applicable) has been tested manually
