#!/usr/bin/env python3
"""
Sync LiteLLM proxy models into Kilo Code's kilo.jsonc config.

Queries a LiteLLM proxy to discover available models and their pricing,
then generates or updates the `provider` block in kilo.jsonc.

Usage:
    python sync_litellm_models.py [--url http://localhost:4000] [--key sk-...]
                                   [--config kilo.jsonc] [--provider-id litellm]
                                   [--dry-run] [--merge]

The --merge flag reads an existing kilo.jsonc and merges models into it
instead of replacing the whole provider block.
"""

import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path

# ── LiteLLM model cost map (fallback when proxy doesn't expose it) ──────────
# Prices per 1M tokens. Source: litellm model_prices_and_context_window.json
# This is a curated subset — the proxy's /public/litellm_model_cost_map is
# preferred when available.

FALLBACK_COST_MAP = {
    "gpt-4o":                   {"input": 2.50,  "output": 10.00, "cache_read": 1.25, "cache_write": 2.50},
    "gpt-4o-mini":              {"input": 0.15,  "output": 0.60,  "cache_read": 0.075,"cache_write": 0.15},
    "gpt-4.1":                  {"input": 2.00,  "output": 8.00,  "cache_read": 0.50, "cache_write": 2.00},
    "gpt-4.1-mini":             {"input": 0.40,  "output": 1.60,  "cache_read": 0.10, "cache_write": 0.40},
    "gpt-4.1-nano":             {"input": 0.10,  "output": 0.40,  "cache_read": 0.025,"cache_write": 0.10},
    "gpt-4-turbo":              {"input": 10.00, "output": 30.00},
    "gpt-4":                    {"input": 30.00, "output": 60.00},
    "gpt-3.5-turbo":            {"input": 0.50,  "output": 1.50},
    "o1":                       {"input": 15.00, "output": 60.00, "cache_read": 7.50},
    "o1-mini":                  {"input": 1.10,  "output": 4.40,  "cache_read": 0.55},
    "o3-mini":                  {"input": 1.10,  "output": 4.40,  "cache_read": 0.55},
    "o3":                       {"input": 10.00, "output": 40.00, "cache_read": 2.50},
    "o4-mini":                  {"input": 1.10,  "output": 4.40,  "cache_read": 0.55},
    "claude-sonnet-4-20250514": {"input": 3.00,  "output": 15.00, "cache_read": 0.30, "cache_write": 3.75},
    "claude-opus-4-20250514":   {"input": 15.00, "output": 75.00, "cache_read": 1.50, "cache_write": 15.00},
    "claude-3.5-sonnet":        {"input": 3.00,  "output": 15.00, "cache_read": 0.30, "cache_write": 3.75},
    "claude-3.5-haiku":         {"input": 0.80,  "output": 4.00,  "cache_read": 0.08, "cache_write": 1.00},
    "claude-3-opus":            {"input": 15.00, "output": 75.00},
    "claude-3-haiku":           {"input": 0.25,  "output": 1.25},
    "gemini-2.5-pro":           {"input": 1.25,  "output": 10.00},
    "gemini-2.5-flash":         {"input": 0.15,  "output": 0.60},
    "gemini-2.0-flash":         {"input": 0.10,  "output": 0.40},
    "gemini-1.5-pro":           {"input": 1.25,  "output": 5.00},
    "gemini-1.5-flash":         {"input": 0.075, "output": 0.30},
    "deepseek-chat":            {"input": 0.27,  "output": 1.10},
    "deepseek-reasoner":        {"input": 0.55,  "output": 2.19},
    "llama-3.1-70b":            {"input": 0.59,  "output": 0.79},
    "llama-3.1-8b":             {"input": 0.06,  "output": 0.06},
    "llama-3.1-405b":           {"input": 2.70,  "output": 2.70},
    "mixtral-8x7b":             {"input": 0.24,  "output": 0.24},
    "mistral-large":            {"input": 2.00,  "output": 6.00},
    "mistral-small":            {"input": 0.20,  "output": 0.60},
}


def http_get(url: str, api_key: str | None = None) -> dict | list:
    """GET a JSON endpoint from the LiteLLM proxy."""
    headers = {"Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:500]
        print(f"  ⚠  HTTP {e.code} from {url}: {body}", file=sys.stderr)
        return {}
    except Exception as e:
        print(f"  ⚠  Failed to reach {url}: {e}", file=sys.stderr)
        return {}


def fetch_model_cost_map(base_url: str, api_key: str | None) -> dict:
    """Try to fetch LiteLLM's internal cost map from the proxy."""
    # LiteLLM exposes this at /public/litellm_model_cost_map
    url = f"{base_url.rstrip('/')}/public/litellm_model_cost_map"
    data = http_get(url, api_key)
    if isinstance(data, dict) and data:
        return data
    return {}


def normalize_model_name(raw: str) -> str:
    """Strip provider prefixes like 'openai/', 'anthropic/' from model names."""
    for prefix in ("openai/", "anthropic/", "google/", "azure/", "bedrock/",
                   "cohere/", "mistral/", "deepseek/", "groq/", "together_ai/",
                   "vertex_ai/", "huggingface/", "replicate/", "ollama/"):
        if raw.startswith(prefix):
            return raw[len(prefix):]
    return raw


def find_cost(model_name: str, cost_map: dict) -> dict | None:
    """Find pricing for a model, trying exact and fuzzy matches."""
    norm = normalize_model_name(model_name)

    # Exact match
    if norm in cost_map:
        entry = cost_map[norm]
        if isinstance(entry, dict):
            return _extract_cost(entry)

    # Try the original name
    if model_name in cost_map:
        entry = cost_map[model_name]
        if isinstance(entry, dict):
            return _extract_cost(entry)

    # Fuzzy: strip date suffixes and try again
    fuzzy = re.sub(r'-\d{4,8}$', '', norm)
    if fuzzy != norm and fuzzy in cost_map:
        entry = cost_map[fuzzy]
        if isinstance(entry, dict):
            return _extract_cost(entry)

    # Try FALLBACK_COST_MAP
    if norm in FALLBACK_COST_MAP:
        return FALLBACK_COST_MAP[norm]
    if fuzzy in FALLBACK_COST_MAP:
        return FALLBACK_COST_MAP[fuzzy]

    # Try cost_map with fuzzy name
    if fuzzy in cost_map:
        entry = cost_map[fuzzy]
        if isinstance(entry, dict):
            return _extract_cost(entry)

    return None


def _extract_cost(entry: dict) -> dict:
    """Extract cost fields from a LiteLLM cost map entry."""
    cost = {}
    # LiteLLM stores prices per 1M tokens as float
    for field, key in [
        ("input", "input_cost_per_token"),
        ("output", "output_cost_per_token"),
    ]:
        val = entry.get(key, 0) or 0
        if isinstance(val, (int, float)) and val > 0:
            # Convert per-token to per-1M-tokens
            cost[field] = round(val * 1_000_000, 4)

    # Cache pricing
    for field, key in [
        ("cache_read", "cache_read_input_token_cost"),
        ("cache_write", "cache_creation_input_token_cost"),
    ]:
        val = entry.get(key, 0) or 0
        if isinstance(val, (int, float)) and val > 0:
            cost[field] = round(val * 1_000_000, 4)

    return cost if cost else None


def fetch_models(base_url: str, api_key: str | None) -> list[dict]:
    """Get all models from the LiteLLM proxy via /v1/model/info."""
    url = f"{base_url.rstrip('/')}/v1/model/info"
    data = http_get(url, api_key)

    if isinstance(data, dict) and "data" in data:
        items = data["data"]
        if isinstance(items, list):
            return items
        if isinstance(items, dict):
            return [items]

    print("  ⚠  /v1/model/info returned unexpected format", file=sys.stderr)
    return []


def build_kilo_model(model_name: str, litellm_model: str,
                     cost: dict | None, context_limit: int = 0) -> dict:
    """Build a single model entry for kilo.jsonc."""
    entry: dict = {
        "name": model_name,
    }

    if cost:
        entry["cost"] = {}
        if "input" in cost:
            entry["cost"]["input"] = cost["input"]
        if "output" in cost:
            entry["cost"]["output"] = cost["output"]
        if "cache_read" in cost:
            if "cache" not in entry["cost"]:
                entry["cost"]["cache"] = {}
            entry["cost"]["cache"]["read"] = cost["cache_read"]
        if "cache_write" in cost:
            if "cache" not in entry["cost"]:
                entry["cost"]["cache"] = {}
            entry["cost"]["cache"]["write"] = cost["cache_write"]

    if context_limit > 0:
        entry["limit"] = {
            "context": context_limit,
            "output": min(context_limit // 4, 16384),
        }

    return entry


def build_provider_block(base_url: str, provider_id: str,
                         models_data: list[dict],
                         cost_map: dict) -> dict:
    """Build the full provider config block."""
    models = {}
    count_with_cost = 0
    count_without_cost = 0

    for deployment in models_data:
        model_name = deployment.get("model_name", "")
        litellm_params = deployment.get("litellm_params", {})
        litellm_model = litellm_params.get("model", model_name)
        model_info = deployment.get("model_info", {})

        if not model_name or model_name == "*":
            continue

        # Skip internal/wildcard models
        if model_name.startswith("model_name_"):
            continue

        # Get cost from LiteLLM's cost map
        cost = find_cost(litellm_model, cost_map) or find_cost(model_name, cost_map)

        # Try to get context limit from model_info
        context_limit = model_info.get("max_tokens", 0) or model_info.get(
            "max_input_tokens", 0) or 0

        entry = build_kilo_model(model_name, litellm_model, cost, context_limit)
        models[model_name] = entry

        if cost:
            count_with_cost += 1
        else:
            count_without_cost += 1
            print(f"  ⚠  No pricing found for '{model_name}' "
                  f"(litellm model: {litellm_model})", file=sys.stderr)

    provider: dict = {
        "id": provider_id,
        "name": "LiteLLM",
        "api": base_url.rstrip("/"),
        "env": [],
        "npm": "@ai-sdk/openai-compatible",
        "options": {
            "baseURL": base_url.rstrip("/"),
        },
        "models": models,
    }

    return provider, count_with_cost, count_without_cost


def read_jsonc(path: str) -> dict:
    """Read a JSONC file, stripping comments."""
    with open(path) as f:
        text = f.read()
    # Strip // comments (naive but works for simple cases)
    cleaned = []
    for line in text.split('\n'):
        # Remove // comments (but not inside strings)
        in_string = False
        result = []
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == '"' and (i == 0 or line[i-1] != '\\'):
                in_string = not in_string
                result.append(ch)
            elif ch == '/' and not in_string and i+1 < len(line) and line[i+1] == '/':
                break  # rest is comment
            else:
                result.append(ch)
            i += 1
        cleaned.append(''.join(result))
    return json.loads('\n'.join(cleaned))


def merge_into_config(config_path: str, provider_id: str,
                      provider_block: dict) -> dict:
    """Merge the provider block into an existing kilo.jsonc."""
    if os.path.exists(config_path):
        config = read_jsonc(config_path)
    else:
        config = {}

    if "provider" not in config:
        config["provider"] = {}

    existing = config["provider"].get(provider_id, {})
    existing_models = existing.get("models", {})

    # Merge: new models from proxy take precedence (merge by name)
    new_models = provider_block.get("models", {})
    merged_models = {}
    for m_name, ext_model in existing_models.items():
        merged_models[m_name] = ext_model.copy()
    for m_name, nw_model in new_models.items():
        if m_name in merged_models:
            merged_models[m_name].update(nw_model)
        else:
            merged_models[m_name] = nw_model

    config["provider"][provider_id] = {
        "id": provider_id,
        "name": existing.get("name", provider_block.get("name", provider_id)),
        "api": existing.get("api", provider_block.get("api", "")),
        "env": existing.get("env", provider_block.get("env", [])),
        "npm": existing.get("npm", provider_block.get("npm", "@ai-sdk/openai-compatible")),
        "options": {**existing.get("options", {}), **provider_block.get("options", {})},
        "models": merged_models,
    }

    return config


def write_jsonc(config: dict, path: str):
    """Write a dict as pretty-printed JSON (not JSONC, but Kilo accepts it)."""
    with open(path, 'w') as f:
        json.dump(config, f, indent=2)
        f.write('\n')


def main():
    parser = argparse.ArgumentParser(
        description="Sync LiteLLM proxy models into Kilo Code's kilo.jsonc")
    parser.add_argument("--url", default=os.environ.get("LITELLM_PROXY_URL",
                        "http://localhost:4000"),
                        help="LiteLLM proxy base URL")
    parser.add_argument("--key", default=os.environ.get("LITELLM_API_KEY", ""),
                        help="LiteLLM proxy API key (or set LITELLM_API_KEY env)")
    parser.add_argument("--config", default="kilo.jsonc",
                        help="Path to kilo.jsonc (default: ./kilo.jsonc)")
    parser.add_argument("--provider-id", default="litellm",
                        help="Provider ID in kilo.jsonc (default: litellm)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print config to stdout instead of writing")
    parser.add_argument("--merge", action="store_true",
                        help="Merge into existing kilo.jsonc instead of replacing")
    parser.add_argument("--output", default="",
                        help="Write to this file instead of --config (for dry-run testing)")
    args = parser.parse_args()

    base_url = args.url.rstrip("/")
    api_key = args.key or None

    print(f"🔍 Querying LiteLLM proxy at {base_url} …")

    # 1. Fetch model info
    models_data = fetch_models(base_url, api_key)
    if not models_data:
        print("❌ No models found. Is the LiteLLM proxy running?")
        print("   Try: curl {}/v1/model/info".format(base_url))
        sys.exit(1)
    print(f"   Found {len(models_data)} deployment(s)")

    # 2. Fetch cost map (try proxy first, fall back to built-in)
    cost_map = fetch_model_cost_map(base_url, api_key)
    if cost_map:
        print(f"   Loaded cost map from proxy ({len(cost_map)} entries)")
    else:
        print("   Using built-in fallback cost map "
              f"({len(FALLBACK_COST_MAP)} entries)")

    # 3. Build provider config
    provider_block, with_cost, without_cost = build_provider_block(
        base_url, args.provider_id, models_data, cost_map)

    print(f"\n📊 Models: {with_cost} with pricing, {without_cost} with unknown pricing")

    # 4. Output
    if args.merge and not args.dry_run:
        config = merge_into_config(args.config, args.provider_id, provider_block)
        output_path = args.output or args.config
        write_jsonc(config, output_path)
        print(f"✅ Merged into {output_path}")
    elif args.dry_run or args.output:
        config = {args.provider_id: provider_block} if not args.merge else \
                 merge_into_config(args.config, args.provider_id, provider_block)
        output_path = args.output or args.config
        if args.dry_run:
            print("\n── Preview ──")
            print(json.dumps(config, indent=2))
        else:
            write_jsonc(config, output_path)
            print(f"✅ Written to {output_path}")
    else:
        # Write just the provider block to config
        config = {args.provider_id: provider_block}
        write_jsonc(config, args.config)
        print(f"✅ Written to {args.config}")


if __name__ == "__main__":
    main()
