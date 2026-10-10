# Frontend — React + Vite + Tailwind + Orval

## Quick Start

```bash
cd frontend
pnpm install          # Install dependencies
pnpm dev              # Start dev server (port 5173)
```

## Code Generation

```bash
pnpm orval            # Generate API client from OpenAPI spec
```

The Orval config reads from `../api/openapi.yaml` and generates:
- TypeScript types/interfaces
- React Query hooks
- Mock handlers

## Project Structure

```
frontend/
├── src/
│   ├── api/            # Orval-generated API client & schemas
│   ├── components/     # Shared UI components
│   ├── pages/          # Route/page components
│   ├── hooks/          # Shared React hooks
│   ├── lib/            # Utilities
│   └── App.tsx         # Root component
├── orval.config.ts     # Orval codegen configuration
├── vite.config.ts      # Vite bundler config
└── package.json        # Dependencies
```

## Testing

```bash
pnpm test               # Run tests
pnpm test:watch         # Watch mode
```
