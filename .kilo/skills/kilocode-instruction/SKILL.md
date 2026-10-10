---
name: kilocode-instruction
description: Use when the user asks to write, edit, or manage Kilo Code instruction files (AGENTS.md, CLAUDE.md, KILO.md, CONTEXT.md) — project-wide or per-agent behavioral guidance.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux, windows]
metadata:
  hermes:
    tags: [kilocode, instruction, rules, agents.md, project-local]
    related_skills: [kilocode-skill, kilocode-agent, kilocode-hook, kilocode-setting, kilocode]
---

# Kilo Code Instruction Authoring

Create, edit, or manage Kilo Code instruction files. Instructions are plain markdown files that tell Kilo Code how to behave — coding style, conventions, constraints, and workflow preferences.

## Instruction File Locations

Kilo Code auto-discovers these files at project root (and up through parent directories via `findUp`):

| File | Priority | Notes |
|---|---|---|
| `AGENTS.md` | **Primary** — use this | Open agent standard, works across agents |
| `CLAUDE.md` | Secondary | Claude Code compatibility |
| `KILO.md` | Secondary | Kilo-specific |
| `CONTEXT.md` | Secondary | Additional project context |

Also:
- **Global**: `~/.config/kilo/AGENTS.md` — applies across all projects
- **Per-directory**: `AGENTS.md` in any subdirectory — loaded dynamically when agent accesses files there
- **Additional paths**: `instructions` key in `kilo.jsonc` can point to more files or URLs
- **Per-agent prompts**: Through Settings UI → Agent Behaviour → Agents subtab
- **Legacy**: `.kilocoderules` files are auto-migrated but `AGENTS.md` is recommended for new projects

**Default**: always use `AGENTS.md` (standard, works across tools).

## Instruction File Format

Plain markdown — no frontmatter needed. Write clear, directive prose:

```markdown
# Project Instructions

## Coding Style
- Use 2-space indentation for TypeScript
- Prefer `const` over `let`
- No `any` types — use proper interfaces

## Testing
- Every component needs a unit test
- Run `npm test` before committing
- Aim for 80% coverage on new code

## Conventions
- Feature branches: `feat/<name>`
- PR titles: `type: description` (e.g. `feat: add login page`)
```

## Workflow

### Create/Write Instructions

1. Ask the user what conventions, style rules, or constraints they want to encode
2. Determine scope: project root (`AGENTS.md`), global (`~/.config/kilo/AGENTS.md`), or per-directory
3. If editing, `read_file` first; if creating, `write_file`
4. Keep it focused — instructions are always in context, so every line costs tokens

### Edit Instructions

1. `read_file` the current file
2. Use `patch` for targeted edits, `write_file` for rewrites
3. Preserve existing content unless explicitly told to remove it

### Structure Recommendations

- **Start with a heading**: `# Project Instructions` or `# <Project Name>`
- **Group by topic**: Coding Style, Testing, Conventions, Dependencies, etc.
- **Use bullet lists**: Easier for the agent to parse than prose paragraphs
- **Be specific**: "Use `pathlib.Path` over `os.path`" > "Use modern Python"
- **Include commands**: Give the agent exact verification commands (`npm test`, `cargo check`)

## Pitfalls

1. **Too long** — Instructions are always in the system prompt. Every token reduces room for conversation. Keep it tight.
2. **Vague directives** — "Be careful" doesn't change behavior. "Run `npm test` before declaring done" does.
3. **Conflicting with agent prompts** — Agent-specific prompts (in custom mode `.md` files) take precedence. Don't repeat agent-level instructions here.
4. **Per-directory overload** — Too many `AGENTS.md` files in subdirectories creates context fragmentation. Use sparingly.
5. **Not reloaded automatically** — Changes take effect on next session or after `/reload`.
6. **Global vs project conflict** — Project instructions override global ones. Be aware of the layering.

## Verification

- [ ] File is at the correct location (project root, global config, or subdirectory)
- [ ] Content is specific and actionable (commands, conventions, rules)
- [ ] No conflicting instructions with agent-level prompts
- [ ] File is plain markdown (no YAML frontmatter)
- [ ] Length is reasonable (< 500 lines is a good target)
