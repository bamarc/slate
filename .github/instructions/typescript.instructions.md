---
description: 'TypeScript/React conventions for this project: functional components, strict types, Tailwind, Orval, vitest'
applyTo: '**.ts, **.tsx'
---

# TypeScript / React project conventions

## Style
- Line length: 100, indentation: 2 spaces, quotes: single `''`, semicolons: required
- trailingComma: always
- Run `pnpm lint` before committing

## React
- Functional components only, named exports (no defaults)
- One component per file, PascalCase filename
- Props interface: `{ComponentName}Props`
- Hooks in `src/hooks/`, utilities in `src/lib/`

## Typing
- `strict: true` in tsconfig
- Prefer `interface` over `type` for objects
- Never use `any` — use `unknown` and narrow
- Orval-generated types in `src/api/generated/` — never edit manually

## API client
- Generated from `api/openapi.yaml` via Orval
- Regenerate: `cd frontend && pnpm orval`
- Or use: `.github/skills/code-generation/generate-from-openapi.sh`

## Testing
- `vitest` with `@testing-library/react`
- Co-located test files: `Component.test.tsx`
- Prefer `screen.getByRole()` over `getByTestId()`
