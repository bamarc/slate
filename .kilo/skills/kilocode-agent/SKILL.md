---
name: kilocode-agent
description: Use when the user asks to create, edit, or delete a Kilo Code custom agent/mode. Agents are `.md` files with YAML frontmatter in `.kilo/agents/` or `.kilo/agent/` (project-local).
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux, windows]
metadata:
  hermes:
    tags: [kilocode, agent, custom-mode, project-local]
    related_skills: [kilocode-skill, kilocode-instruction, kilocode-hook, kilocode-setting, kilocode]
---

# Kilo Code Agent Authoring

Create, edit, or delete project-local Kilo Code custom agents (also called "custom modes"). An agent is a markdown file with YAML frontmatter that defines a specialized AI persona with tool access, model pinning, and behavior instructions.

## Where Agents Live

| Location | Scope |
|---|---|
| `.kilo/agents/<name>.md` | Project — **preferred** |
| `.kilo/agent/<name>.md` | Project — alternative (singular) |
| `.kilocode/agents/<name>.md` | Project — legacy compat |
| `~/.config/kilo/agent/<name>.md` | Global (user) |

Also definable inline in `kilo.jsonc` under the `agent` key.

**Default**: create in `.kilo/agents/<name>.md`.

## Agent File Format

```markdown
---
description: A short summary shown in the agent picker and used for delegation
mode: primary
color: "#10B981"
permission:
  edit:
    "*.md": allow
    "*": deny
  bash: deny
  read: allow
---

You are a [role description]. Your expertise includes:

- Capability 1
- Capability 2

Focus on [primary objective]. [Additional constraints].
```

### Frontmatter Fields

| Field | Required | Description |
|---|---|---|
| `description` | Yes | Short summary shown in agent picker and used for delegation |
| `mode` | No | `primary` (user picker), `subagent` (only invokable by other agents), `all` (both, default) |
| `color` | No | Hex color (`#10B981`) or theme keyword for the picker UI |
| `model` | No | Pin a model in `provider/model` format (e.g. `anthropic/claude-sonnet-4-20250514`) |
| `permission` | No | Ordered permission rules for tool access (see below) |
| `steps` | No | Max agentic iterations before forcing text-only response |
| `temperature` | No | Sampling temperature override |
| `top_p` | No | Nucleus sampling override |
| `hidden` | No | If `true`, hide from UI (for subagents) |
| `disable` | No | If `true`, remove the agent entirely |
| `variant` | No | Default model variant |

### Body (Prompt)

The markdown body after the closing `---` is the agent's **system prompt**. Write it as if briefing a colleague:
- Start with the agent's role and expertise
- List key capabilities
- Add constraints and focus areas
- Keep it focused — the prompt is always in context

### Permissions

Ordered, last-match-wins rules. Each permission type supports:

| Permission | Controls | Example glob |
|---|---|---|
| `read` | File reading | `*.md`, `docs/**`, `*` |
| `edit` | File writing/deletion | `*.py`, `src/**` |
| `bash` | Shell command execution | `git *`, `npm *` (command patterns) |
| `glob` | File pattern matching | — |
| `grep` | Content searching | — |
| `task` | Subagent delegation | — |
| `webfetch` | Web content fetching | — |
| `websearch` | Web searching | — |
| `todowrite` | Todo creation/modification | — |
| `todoread` | Todo reading | — |

Each rule maps a pattern to `allow`, `deny`, or `ask`. Put broad defaults first, specific exceptions after:

```yaml
permission:
  edit:
    "*": deny            # Deny all by default
    "*.md": allow        # Allow markdown
    "docs/**": allow     # Allow docs directory
  bash:
    "git *": allow       # Allow git commands
    "*": deny            # Deny everything else
  read: allow            # Allow all reads (shorthand for "read": {"*": "allow"})
```

### Mode Values

| Value | Behavior |
|---|---|
| `primary` | Shown in agent picker — user can select directly |
| `subagent` | Only invokable by other agents via the `task` tool |
| `all` | Both (default for user-defined agents) |

## Workflow

### Create a New Agent

1. Ask the user for the agent's **name**, **role/purpose**, and any **permission restrictions**
2. Create `.kilo/agents/<name>.md` with `write_file`
3. Write frontmatter: `description`, `mode`, `color`, `permission`
4. Write body: role, expertise, constraints
5. Verify the file is well-formed (frontmatter starts/ends with `---`)

### Edit an Existing Agent

1. `read_file` the agent file
2. Use `patch` for targeted edits, `write_file` for rewrites
3. Check that YAML frontmatter still parses

### Delete an Agent

```bash
rm .kilo/agents/<name>.md
```

Or remove the entry from `kilo.jsonc` if defined there.

### Override a Built-in Agent

To override built-in agents (`code`, `plan`, `debug`, `ask`, `explore`, `general`), create an agent with the same name:

```markdown
---
model: openai/gpt-4o
temperature: 0.2
permission:
  edit:
    "*.py": allow
    "*": deny
---
```

## Pitfalls

1. **YAML parse errors** — Frontmatter must start and end with `---` on its own line. No trailing whitespace on the closing `---`.
2. **Permission order** — Rules are last-match-wins. If `allow` comes before `deny`, the deny wins. Put broad denies first, then specific allows.
3. **Mode confusion** — `primary` = user can select. `subagent` = only other agents can invoke. `all` = both.
4. **Agent not appearing** — Check `mode` is `primary` or `all`. Check file is in `.kilo/agents/` (with 's').
5. **Glob patterns for bash** — Bash permissions match command prefixes, not file paths. `"git *": allow` matches any command starting with `git`.
6. **Filename vs agent name** — The filename (minus `.md`) IS the agent name. `docs-writer.md` → agent named `docs-writer`.

## Verification

- [ ] File at `.kilo/agents/<name>.md`
- [ ] Frontmatter starts on line 1 with `---`
- [ ] Frontmatter closes with `---` on its own line
- [ ] `description` field present
- [ ] `mode` is valid (`primary`, `subagent`, or `all`)
- [ ] Body (system prompt) is specific and actionable
- [ ] Permissions use valid glob patterns and actions (`allow`/`deny`/`ask`)
- [ ] If overriding built-in, name matches exactly (`code`, `plan`, `debug`, `ask`, `explore`, `general`)
