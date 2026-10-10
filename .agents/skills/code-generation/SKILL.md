---
name: code-generation
description: 'Regenerate frontend API client from the OpenAPI spec using Orval. Use this when the OpenAPI spec changes and the frontend client needs updating.'
allowed-tools: [shell]
---

# Code Generation Skill

This project uses an **OpenAPI contract-first** workflow. The frontend API client is auto-generated from `api/openapi.yaml` via Orval.

## When to regenerate
- After adding or modifying endpoints in `api/openapi.yaml`
- After changing request/response schemas in the OpenAPI spec
- When the generated types are out of sync with the spec

## How to regenerate
Run the generation script from the project root:
```bash
.github/skills/code-generation/generate-from-openapi.sh
```

Or manually:
```bash
cd frontend
pnpm orval
```

## What gets generated
- TypeScript types and interfaces in `frontend/src/api/generated/schemas/`
- React Query hooks in `frontend/src/api/generated/endpoints.ts`
- Mock handlers if configured in `orval.config.ts`

## Rules
- NEVER edit generated files in `frontend/src/api/generated/` — they will be overwritten
- If the generated types don't match what you need, change the OpenAPI spec instead
- Always regenerate after changing `api/openapi.yaml` before building frontend features
- Commit the regenerated files alongside the OpenAPI changes
