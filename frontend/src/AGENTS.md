# Frontend Source Structure

The frontend source uses a modular type-based structure rather than a top-level
`features/` directory.

- Keep pages under `pages/`, components under `components/`, hooks under
  `hooks/`, contexts under `contexts/`, and domain data access/utilities under `lib/`.
- Keep truly shared UI primitives directly under `components/ui/` or `components/`;
  do not place shared components inside domain directories.
- Do not introduce `src/features/` or add barrel `index.ts` files solely to
  hide import paths. Use the `@/` alias and explicit module paths.
- Keep routing in `App.tsx`; page modules should contain page rendering and
  domain-specific composition, not route registration.
- Generated API clients live under `api/generated/` and should be regenerated
  with `just generate` rather than manually edited.
