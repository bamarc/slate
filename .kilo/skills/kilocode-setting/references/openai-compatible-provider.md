# OpenAI-Compatible Provider Configuration

How to configure custom OpenAI-compatible providers (LiteLLM, local proxies, self-hosted endpoints) in Kilo Code's `kilo.jsonc` — especially getting pricing and model properties right.

## Why Pricing Doesn't Auto-Discover

Kilo Code uses the Vercel AI SDK's `@ai-sdk/openai-compatible` package (`npm` field) for custom providers. When you add a provider this way:

1. The OpenAI `/v1/models` endpoint doesn't return pricing data
2. Kilo Code defaults every model's `cost` to **$0** when not explicitly specified in config
3. There's no mechanism to pull pricing from LiteLLM or any other proxy

**Consequence**: models appear in the picker but show as free ($0.00), and usage tracking won't reflect real costs.

## Recipe: LiteLLM Provider with Pricing

```jsonc
{
  "provider": {
    "litellm": {
      "id": "litellm",
      "name": "LiteLLM",
      "api": "http://localhost:4000/v1",          // your LiteLLM proxy URL
      "env": ["LITELLM_API_KEY"],                   // env var holding your LiteLLM key
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://localhost:4000/v1"
      },
      "models": {
        "gpt-4o": {
          "name": "GPT-4o (via LiteLLM)",
          "cost": {
            "input": 2.5,       // $2.50 per 1M input tokens
            "output": 10.0,     // $10.00 per 1M output tokens
            "cache_read": 1.25,
            "cache_write": 2.5
          },
          "limit": {
            "context": 128000,
            "output": 16384
          }
        },
        "claude-sonnet-4-20250514": {
          "name": "Claude Sonnet 4 (via LiteLLM)",
          "cost": {
            "input": 3.0,
            "output": 15.0,
            "cache_read": 0.30,
            "cache_write": 3.75
          },
          "limit": {
            "context": 200000,
            "output": 8192
          }
        }
      }
    }
  }
}
```

## Model Cost Schema

Source: `packages/opencode/src/config/provider.ts` → `Model.cost`

| Field | Unit | Required | Description |
|---|---|---|---|
| `input` | USD per 1M tokens | Yes | Prompt token cost |
| `output` | USD per 1M tokens | Yes | Completion token cost |
| `cache_read` | USD per 1M tokens | No | Anthropic-style cache read discount |
| `cache_write` | USD per 1M tokens | No | Anthropic-style cache write cost |
| `context_over_200k` | Object with same fields | No | Tiered pricing for 200k+ context models |

### Scale is per 1 million tokens

This is the AI SDK convention. GPT-4o at $2.50/M input = `2.5`, **not** `0.0000025`.

## Model Limit Schema

| Field | Unit | Required | Description |
|---|---|---|---|
| `context` | Tokens | Yes | Max context window |
| `input` | Tokens | No | Max input tokens (optional override) |
| `output` | Tokens | Yes | Max output tokens |

## General Pattern (Any OpenAI-Compatible Endpoint)

The pattern is the same for any proxy or self-hosted endpoint — vLLM, Ollama with OpenAI compatibility, Text Generation Inference, etc.:

```jsonc
{
  "provider": {
    "<provider-id>": {
      "id": "<provider-id>",
      "name": "<Human name>",
      "api": "<base URL>/v1",
      "env": ["<ENV_VAR_FOR_API_KEY>"],
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "<base URL>/v1"
      },
      "models": {
        "<model-id>": {
          "name": "<display name>",
          "cost": {
            "input": <float>,
            "output": <float>
          },
          "limit": {
            "context": <int>,
            "output": <int>
          }
        }
      }
    }
  }
}
```

## Provider-Level Options

Set on the provider, not per-model:

| Option | Type | Description |
|---|---|---|
| `baseURL` | string | API base URL (e.g. `http://localhost:4000/v1`) |
| `timeout` | int or false | Request timeout in ms. Set `false` to disable |
| `headerTimeout` | int or false | Timeout for response headers in ms |
| `chunkTimeout` | int | Timeout between SSE chunks in ms |
| `setCacheKey` | bool | Enable `promptCacheKey` header (default false) |

## Auto-Discovery Limitation

Kilo Code does NOT auto-discover models from:

- LiteLLM's `/v1/models` endpoint (returns standard OpenAI format, no pricing)
- vLLM's `/v1/models`
- Any OpenAI-compatible `/v1/models` endpoint
- Ollama's `/api/tags`

**Every model must be manually listed under `"models"` with explicit `cost` and `limit`.** If you omit `cost`, the model defaults to $0 (appears as free).

## Token Usage Tracking

For openai-compatible providers, Kilo Code sets `includeUsage: true` by default (source: `provider.ts` line 1636-1637). This means the AI SDK requests usage/token counts in API responses. You can disable this if your proxy doesn't support it:

```jsonc
"options": {
  "baseURL": "http://localhost:4000/v1",
  "includeUsage": false
}
```

## Pitfalls

1. **Forgetting model definitions** — The provider itself will load (API key works), but the model picker will be empty or show only models you've explicitly listed.
2. **Wrong cost scale** — AI SDK uses per-1M-tokens, not per-token. GPT-4o input = `2.5`, not `0.0000025` or `0.0025`.
3. **Model ID mismatch** — The key in `"models"` (e.g. `"gpt-4o"`) is the ID sent to the API. If your LiteLLM routes `"gpt-4o"` but Kilo sends `"openai/gpt-4o"`, it won't match. Match the exact ID your proxy expects.
4. **Missing `limit` fields** — Without `limit.context`, Kilo Code can't manage the context window properly. Set it to the model's actual context length.
5. **API URL format** — Must include `/v1` suffix (e.g. `http://localhost:4000/v1`). The AI SDK appends model-specific paths to this base.
