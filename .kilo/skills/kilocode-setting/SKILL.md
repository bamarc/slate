---
name: kilocode-setting
description: Use when the user asks to read, change, or adapt a Kilo Code setting — model selection, permissions, auto-approval, context limits, or any configuration in `kilo.jsonc`.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux, windows]
metadata:
  hermes:
    tags: [kilocode, settings, config, kilojsonc, project-local]
    related_skills: [kilocode-skill, kilocode-agent, kilocode-instruction, kilocode-hook, kilocode, kilocode-litellm-sync]
---

# Kilo Code Settings Management

Read, adapt, or write Kilo Code settings. Settings live in `kilo.jsonc` (JSON with comments) at the project root or global config directory.

## Config File Locations

| Location | Scope | Priority |
|---|---|---|
| `<project-root>/kilo.jsonc` | Project | Higher |
| `~/.config/kilo/kilo.jsonc` | Global (user) | Lower (project overrides) |
| `KILO_CONFIG_CONTENT` env var | Session | Highest (overrides all) |

Config merges from lowest to highest priority — project settings override global; env var overrides everything.

## Config Structure (`kilo.jsonc`)

JSON with comments (JSONC). Key sections:

```jsonc
{
  // Model & provider
  "model": "anthropic/claude-sonnet-4-20250514",
  "provider": "kilocode",  // or "openai", "anthropic", etc.

  // Agent definitions (inline alternative to .md files)
  "agent": {
    "docs-writer": {
      "description": "Documentation specialist",
      "mode": "primary",
      "color": "#10B981",
      "prompt": "You are a technical writer...",
      "permission": {
        "edit": { "*.md": "allow", "*": "deny" },
        "bash": "deny"
      }
    }
  },

  // Skills
  "skills": {
    "paths": ["/path/to/shared/skills", "~/my-skills"],
    "urls": ["https://example.com/.well-known/skills/"]
  },

  // Additional instruction sources
  "instructions": [
    "./docs/coding-standards.md",
    "./teams/frontend-rules.md"
  ],

  // Auto-approval
  "autoApproval": {
    "enabled": false,
    "maxRequests": 20,
    "enableNotifications": true,
    "actions": {
      "read": true,
      "edit": false,
      "bash": false,
      "task": false
    }
  },

  // Context limits
  "contextPrompt": ""
}
```

### Key Settings

| Setting | Description | Example |
|---|---|---|
| `model` | Default model in `provider/model` format | `"anthropic/claude-sonnet-4-20250514"` |
| `provider` | Default provider | `"kilocode"`, `"openai"`, `"anthropic"` |
| `agent` | Inline agent definitions (alternative to `.md` files) | See above |
| `skills.paths` | Additional skill directories | `["~/shared-skills"]` |
| `skills.urls` | Remote skill sources (must serve `index.json`) | `["https://example.com/skills/"]` |
| `instructions` | Additional instruction file paths or URLs | `["./docs/rules.md"]` |
| `autoApproval.enabled` | Skip permission prompts | `true` / `false` |
| `autoApproval.actions` | Per-tool auto-approval | `{"read": true, "edit": false}` |
| `contextPrompt` | Custom context window management | Provider-specific |

### Custom/OpenAI-Compatible Providers

For LiteLLM, vLLM, Ollama, and other OpenAI-compatible endpoints that need explicit model pricing and limits, see `references/openai-compatible-provider.md`. Key point: these providers do NOT auto-discover model pricing — every model must be manually defined with `cost` fields in `kilo.jsonc`, or else they default to $0.

## Workflow

### Read Current Settings

1. Check for project `kilo.jsonc` first, then global `~/.config/kilo/kilo.jsonc`
2. `read_file` the file
3. Parse the JSONC — note that it supports comments and trailing commas

### Change a Setting

1. `read_file` the current `kilo.jsonc` (create if absent)
2. Identify the key path to change (e.g., `model`, `autoApproval.actions.edit`)
3. Use `patch` for targeted edits — preserve existing structure
4. For new top-level keys, use `write_file` with the full updated content

### Add a New Setting

For new keys, add them at the appropriate location in the JSON structure:

```bash
# Before:
{ "model": "anthropic/claude-sonnet-4" }

# After — add skills section:
{
  "model": "anthropic/claude-sonnet-4",
  "skills": {
    "paths": ["./shared-skills"]
  }
}
```

### Remove a Setting

Delete the key-value pair. If it's the last entry in an object, handle trailing commas.

### Override a Built-in Agent via Config

```jsonc
{
  "agent": {
    "code": {
      "model": "openai/gpt-4o",
      "temperature": 0.2
    }
  }
}
```

This merges with the built-in `code` agent, overriding only the specified properties.

## Pitfalls

1. **JSONC syntax** — Trailing commas and comments are valid in JSONC. Don't strip them.
2. **Config merge semantics** — Project config merges with global, doesn't replace. An agent defined globally can be partially overridden in project config.
3. **Agent name collision** — If an agent is defined both in `kilo.jsonc` and as a `.md` file, the `.md` file takes precedence.
4. **Auto-approval risks** — Setting `autoApproval.enabled: true` skips all permission prompts. Only enable in trusted environments or CI.
5. **Config not reloaded** — Changes take effect on next session or after `/reload`.
6. **Wrong config file** — `kilo.jsonc` (project) vs `~/.config/kilo/kilo.jsonc` (global). Double-check which one the user wants.
7. **Model format** — Must be `provider/model` (e.g., `anthropic/claude-sonnet-4-20250514`), not just model name.
8. **Custom provider pricing** — OpenAI-compatible providers (LiteLLM, vLLM, etc.) default all models to $0 cost. You must explicitly define `cost.input`, `cost.output`, `limit.context`, and `limit.output` for every model under `provider.<id>.models`. See `references/openai-compatible-provider.md` for the full recipe.

## Quick Reference: Common Settings Changes

| User ask | Config change |
|---|---|
| "Change model to GPT-4o" | `"model": "openai/gpt-4o"` |
| "Use Claude for code agent" | `"agent": {"code": {"model": "anthropic/claude-sonnet-4-20250514"}}` |
| "Allow auto-read but not auto-edit" | `"autoApproval": {"actions": {"read": true, "edit": false}}` |
| "Add my LiteLLM models with pricing" | `kilocode-litellm-sync` — use the sync script |
| "Add coding standards docs" | `"instructions": ["./docs/coding-standards.md"]` |

## Verification

- [ ] File is valid JSONC (trailing commas OK, comments OK)
- [ ] Model format is `provider/model`
- [ ] `autoApproval.actions` use boolean values
- [ ] Agent names in `agent` key match existing agents if overriding
- [ ] Paths in `skills.paths` and `instructions` are valid relative or absolute paths
- [ ] No syntax errors (check braces, brackets, commas)
