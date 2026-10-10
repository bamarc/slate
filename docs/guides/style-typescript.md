# Style Guide — TypeScript / React

## Formatting
- Line length: 100 characters
- Indentation: 2 spaces
- Quotes: single quotes (`'`) for strings
- Semicolons: required
- Trailing commas: always where valid

## Naming
| Element | Convention | Example |
|---------|-----------|---------|
| Files/Dirs | `kebab-case` | `user-profile.tsx` |
| React components | `PascalCase` | `UserProfile` |
| Functions/Variables | `camelCase` | `fetchUser()` |
| Types/Interfaces | `PascalCase` | `UserProfileProps` |
| Constants | `UPPER_CASE` | `API_BASE_URL` |
| Private fields | `#` prefix | `#apiClient` |
| Enum members | `PascalCase` | `UserRole.Admin` |

## React conventions
- Functional components only (no class components)
- Props interface defined in the same file, named `{ComponentName}Props`
- Export as named exports, not default exports
- One component per file
- Hooks start with `use` — custom hooks go in `src/hooks/`
- Prefer `useEffect` cleanup over manual teardown

## Typing
- `strict: true` in `tsconfig.json`
- Prefer `interface` over `type` for object shapes
- Use `type` for unions, intersections, and mapped types
- Avoid `any` — use `unknown` and narrow with type guards
- Use `as const` for literal types

## Orval-generated code
- Never edit files in `src/api/generated/` — they are regenerated
- Re-run `pnpm orval` after OpenAPI spec changes
- Orval generates React Query hooks — use them directly in components

## Imports order
```typescript
// 1. React / framework
import { useState } from 'react';

// 2. Third-party
import { useQuery } from '@tanstack/react-query';

// 3. API generated
import { getItems } from '@/api/generated/endpoints';

// 4. App modules
import { UserAvatar } from '@/components/user-avatar';

// 5. Types
import type { Item } from '@/api/generated/schemas';
```

## Testing
- Use `vitest` with `@testing-library/react`
- Test files co-located: `Component.test.tsx` next to `Component.tsx`
- Prefer `screen.getByRole()` over `getByTestId()` where possible
- Use `userEvent` over `fireEvent` for realistic interaction tests
