---
name: kilocode-skill
description: Use when the user asks to create, edit, or delete a Kilo Code skill (SKILL.md file). Kilo Code skills live in `.agents/skills/<name>/SKILL.md` (project-local, standard) or `.kilo/skills/<name>/SKILL.md` (Kilo-specific fallback).
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux, windows]
metadata:
  hermes:
    tags: [kilocode, skill, agent-skills, project-local]
    related_skills: [kilocode-agent, kilocode-instruction, kilocode-hook, kilocode-setting, kilocode]
---

# Kilo Code Skill Authoring

Create, edit, or delete project-local Kilo Code skills. A Kilo Code skill is a `SKILL.md` file inside a named directory. The agent (LLM) discovers skills from their descriptions and loads them on demand when a task matches.

## Where Skills Live

Kilo Code loads skills from (first match wins for same name):

| Location | Scope | Use when |
|---|---|---|
| `.agents/skills/<name>/SKILL.md` | Project | **Preferred** — open agent standard, works across agents |
| `.kilo/skills/<name>/SKILL.md` | Project | Kilo-specific fallback |
| `.kilocode/skills/<name>/SKILL.md` | Project | Legacy compat |
| `~/.kilo/skills/<name>/SKILL.md` | Global (user) | Personal, cross-project |

**Default**: always prefer `.agents/skills/<name>/SKILL.md` (standard). Use `.kilo/skills/` only if the user explicitly asks for Kilo-specific, or if `.agents/` is not appropriate for the project.

## SKILL.md Format

```markdown
---
name: my-skill-name
description: A brief description of what this skill does and when to use it. The agent reads this to decide if the skill applies — write it to match how users phrase requests.
---

# Instructions

Your detailed instructions for the AI agent go here.

The agent will read this content when it decides to use the skill based on
your request matching the description above.

## Example Usage

...
```

### Frontmatter Fields

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Lowercase, hyphens, ≤64 chars. Must match directory name |
| `description` | Yes | When to use. Match user phrasing — this is how the agent decides |

### Description Writing Tips

- **Be specific about triggers**: "Use when writing tests for React components with Jest and Testing Library" > "Use for testing"
- **Match user phrasing**: If users say "add a login page", the description should mention "login" or "authentication"
- **Include domain keywords**: framework names, file types, patterns the skill covers
- **Explicit invocation always works**: The agent can always be told "use the X skill"

## Workflow

1. **Determine location** — use `.agents/skills/` by default
2. **Choose name** — ask the user or derive from the task
3. **Write SKILL.md** — create directory + file with `write_file`
4. **Verify** — check the file parses correctly

### Create a New Skill

```bash
# In project root:
mkdir -p .agents/skills/<skill-name>
```

Then write the `SKILL.md` with proper frontmatter and instructions.

### Edit an Existing Skill

1. `read_file` the `SKILL.md`
2. Use `patch` for targeted edits or `write_file` for rewrites

### Delete a Skill

Remove the directory:
```bash
rm -rf .agents/skills/<skill-name>/
```

## Pitfalls

1. **Description too vague** — The agent decides based on description text. "Useful skill" won't match anything. Be specific.
2. **Frontmatter parse errors** — Must start with `---` on its own line, close with `---` on its own line. No trailing whitespace on the closing `---`.
3. **Name/directory mismatch** — The `name` in frontmatter should match the directory name.
4. **Wrong directory** — `.agents/skills/` (not `.agent/skills/`, not `.agends/skills/`). Double-check spelling.
5. **Skills not reloaded** — Kilo Code caches skills at session start. Use `/reload` or start a new session to pick up changes.

## Verification

- [ ] Directory exists at `.agents/skills/<name>/`
- [ ] `SKILL.md` starts with `---` on line 1
- [ ] Frontmatter has `name` and `description`
- [ ] `name` matches directory name
- [ ] Description is specific and matches how users phrase requests
- [ ] Body contains actionable instructions (not just "be helpful")
- [ ] No trailing whitespace on closing `---`
