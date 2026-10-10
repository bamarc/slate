---
name: kilocode
description: Use when the user asks to configure, customize, or work with Kilo Code project-local files — skills, agents, instructions, hooks, or settings. This meta-skill dispatches to the appropriate sub-skill.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux, windows]
metadata:
  hermes:
    tags: [kilocode, meta, dispatch, project-local]
    related_skills: [kilocode-skill, kilocode-agent, kilocode-instruction, kilocode-hook, kilocode-setting, kilocode-litellm-sync]
---

# Kilo Code Project Configuration (Meta)

This is the umbrella skill for all Kilo Code project-local configuration tasks. When the user asks to do anything with Kilo Code configuration at the project level, load this skill first, then dispatch to the appropriate sub-skill(s).

## Sub-Skill Dispatch

| User says… | Load this sub-skill |
|---|---|
| "Write a skill for kilocode" / "Create a kilocode skill" | `kilocode-skill` |
| "Write an agent for kilocode" / "Create a custom mode" | `kilocode-agent` |
| "Write an instruction for kilocode" / "Add project rules" / "Write AGENTS.md" | `kilocode-instruction` |
| "Write a hook for kilocode" / "Create a command" / "Add a run script" | `kilocode-hook` |
| "Adapt a kilocode setting" / "Change model" / "Configure auto-approval" | `kilocode-setting` |
| "Sync LiteLLM models" / "Pull model pricing from LiteLLM" / "Add LiteLLM as provider" | `kilocode-litellm-sync` |

## Quick Directory Reference

All project-local Kilo Code files live under the project root:

```
project/
├── .kilo/
│   ├── agents/<name>.md      # Custom agents (modes)
│   ├── agent/<name>.md       # Alternative agent location
│   ├── command/<name>.md     # Custom slash commands (hooks)
│   ├── run-script            # Session startup script (hook)
│   ├── skills/<name>/        # Kilo-specific skills
│   │   └── SKILL.md
│   └── plans/                # Auto-generated plan files
├── .agents/
│   └── skills/<name>/        # Open-standard skills (preferred)
│       └── SKILL.md
├── AGENTS.md                 # Project instructions (preferred)
├── CLAUDE.md                 # Alternative instructions
├── KILO.md                   # Kilo-specific instructions
├── CONTEXT.md                # Project context
└── kilo.jsonc                # Settings/config
```

## Workflow

1. **Identify the task** — what type of Kilo Code artifact does the user want?
2. **Load the sub-skill** — `skill_view(name='kilocode-<type>')`
3. **Follow the sub-skill's workflow** — each sub-skill has exact steps
4. **Verify** — check the sub-skill's verification checklist

## Standard Location Convention

| Artifact | Standard Location | Fallback |
|---|---|---|
| Skills | `.agents/skills/<name>/SKILL.md` | `.kilo/skills/<name>/SKILL.md` |
| Agents | `.kilo/agents/<name>.md` | `.kilo/agent/<name>.md` |
| Instructions | `AGENTS.md` (project root) | `CLAUDE.md`, `KILO.md` |
| Commands | `.kilo/command/<name>.md` | — |
| Run script | `.kilo/run-script` | — |
| Settings | `kilo.jsonc` (project root) | `~/.config/kilo/kilo.jsonc` |

Use standardized locations (`.agents/`, `AGENTS.md`) whenever possible — they work across multiple agent tools.

## Common Pitfalls

1. **Directory spelling** — `.agents/skills/` (with 's'), `.kilo/agents/` (with 's'), `.kilo/command/` (singular). Double-check.
2. **File vs directory** — Agents are single `.md` files. Skills are directories containing `SKILL.md`.
3. **Frontmatter format** — Agents and commands use YAML frontmatter (`---`). Instructions (`AGENTS.md`) are plain markdown.
4. **Reload required** — Most changes need `/reload` or a new session to take effect.
5. **Config merge** — Project `kilo.jsonc` merges with global config; agent `.md` files take precedence over `kilo.jsonc` agent definitions.
