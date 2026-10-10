---
name: kilocode-litellm-sync
description: Use when the user wants to sync models from a LiteLLM proxy into Kilo Code's kilo.jsonc with proper pricing. Also use when models from an openai-compatible provider show $0 cost because pricing wasn't pulled.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [macos, linux, windows]
metadata:
  hermes:
    tags: [kilocode, litellm, proxy, sync, pricing, openai-compatible]
    related_skills: [kilocode-setting, kilocode-agent, kilocode]
---

# Sync LiteLLM Models to Kilo Code

Automatically discover models from a LiteLLM proxy and inject them into Kilo Code's `kilo.jsonc` with proper pricing, context limits, and capabilities.

## The Problem

When you add a LiteLLM (or any OpenAI-compatible) proxy as a provider in Kilo Code, model pricing shows as **$0.00**. This happens because:

1. The OpenAI `/v1/models` API doesn't return pricing data
2. Kilo Code defaults unknown model costs to `0`
3. LiteLLM's internal cost map isn't auto-imported

## The Solution

The script `sync_litellm_models.py` queries your LiteLLM proxy, discovers all deployed models, pulls pricing from LiteLLM's internal cost database, and generates the correct `kilo.jsonc` provider block.

**Script location:** `~/.hermes/skills/software-development/kilocode-setting/scripts/sync_litellm_models.py`

## Quick Start

```bash
# Basic usage — query local LiteLLM and write to kilo.jsonc
python ~/.hermes/skills/software-development/kilocode-setting/scripts/sync_litellm_models.py \
  --url http://localhost:4000 \
  --key sk-your-lite-key \
  --config kilo.jsonc

# Merge into existing config (preserves other settings)
python .../sync_litellm_models.py --url http://localhost:4000 --merge

# Preview without writing
python .../sync_litellm_models.py --url http://localhost:4000 --dry-run
```

## How It Works

1. **Discovers models** via LiteLLM's `/v1/model/info` endpoint
2. **Fetches pricing** from the proxy's `/public/litellm_model_cost_map` (if available)
3. **Falls back** to a built-in cost database for common models (GPT-4o, Claude, Gemini, DeepSeek, etc.)
4. **Generates** the `provider` block with per-model `cost`, `limit`, and `name` fields
5. **Merges** into existing `kilo.jsonc` preserving other configuration

## Workflow

### Step 1: Verify the proxy is reachable

```bash
curl http://localhost:4000/v1/model/info | python3 -m json.tool | head -30
```

If this returns model data, the script will work.

### Step 2: Run the sync

```bash
# First do a dry-run to see what will be generated
python ~/.hermes/skills/software-development/kilocode-setting/scripts/sync_litellm_models.py \
  --url http://localhost:4000 \
  --dry-run
```

### Step 3: Review and apply

Check the output. Models with unknown pricing are flagged with ⚠. You can add missing models to `FALLBACK_COST_MAP` in the script if needed.

```bash
# Merge into the project config
python ~/.hermes/skills/software-development/kilocode-setting/scripts/sync_litellm_models.py \
  --url http://localhost:4000 \
  --config kilo.jsonc \
  --merge
```

### Step 4: Reload Kilo Code

Run `/reload` or restart the session for changes to take effect.

## Generated Config Example

```jsonc
{
  "provider": {
    "litellm": {
      "id": "litellm",
      "name": "LiteLLM",
      "api": "http://localhost:4000/v1",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://localhost:4000/v1"
      },
      "models": {
        "gpt-4o": {
          "name": "gpt-4o",
          "cost": {
            "input": 2.5,
            "output": 10.0,
            "cache": {
              "read": 1.25,
              "write": 2.5
            }
          },
          "limit": {
            "context": 128000,
            "output": 16384
          }
        }
      }
    }
  }
}
```

## Adding Missing Models

If a model shows "no pricing found", add it to `FALLBACK_COST_MAP` in the script:

```python
FALLBACK_COST_MAP = {
    # ... existing entries ...
    "your-model-name": {"input": 1.50, "output": 6.00},
}
```

Prices are per **1 million tokens**. For a model charging $1.50/M input tokens, use `1.50` (not `0.0000015`).

## Environment Variables

| Variable | Purpose |
|---|---|
| `LITELLM_PROXY_URL` | Default proxy URL (overridden by `--url`) |
| `LITELLM_API_KEY` | Proxy API key (overridden by `--key`) |

## Common Pitfalls

1. **Proxy not running** — verify with `curl {url}/v1/model/info`
2. **API key required** — many LiteLLM setups require a key even for `/v1/model/info`
3. **Pricing not found** — the `/public/litellm_model_cost_map` endpoint may return empty if the proxy doesn't have cost data loaded; the script falls back to `FALLBACK_COST_MAP`
4. **Model name mismatch** — LiteLLM may name a model `openai/gpt-4o` but Kilo Code expects `gpt-4o`; the script strips provider prefixes
5. **JSON vs JSONC** — the script writes valid JSON; Kilo Code also accepts JSONC (JSON with comments)
6. **Duplicate models** — running with `--merge` preserves existing models that aren't in the proxy; models from the proxy overwrite same-name entries

## Verification

- [ ] `curl {proxy_url}/v1/model/info` returns model data
- [ ] `--dry-run` output looks correct (model names, pricing values)
- [ ] After merge, `kilo.jsonc` contains the `provider.litellm` block
- [ ] `/reload` in Kilo Code picks up the new models
- [ ] Model picker shows correct pricing (not $0.00)
