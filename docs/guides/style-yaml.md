# Style Guide — YAML / OpenAPI

## Formatting
- Indentation: 2 spaces (no tabs)
- Line length: 120 characters
- Use `---` document start marker at file beginning
- One blank line between top-level keys

## OpenAPI conventions
- Use OpenAPI 3.1.0
- `operationId` is `camelCase` and matches the generated function name
- Path parameters use `{param}` syntax
- Tag names are `PascalCase` (e.g., `Items`, `System`)
- Schema names are `PascalCase` (e.g., `ItemResponse`)
- Describe every parameter, response, and property
- Use `examples` for clarity on enums and formats

## Structure
```yaml
openapi: '3.1.0'
info:
  title: 'My API'
  version: '0.1.0'

paths:
  /resource:
    get:
      operationId: listResources
      summary: Short description
      tags: [Resources]
      parameters:
        - name: page
          in: query
          schema:
            type: integer
      responses:
        '200':
          description: Success
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/ResourceList'

components:
  schemas:
    ResourceList:
      type: object
      properties:
        items:
          type: array
          items:
            $ref: '#/components/schemas/Resource'
```

## Ordering
1. `openapi`, `info`, `servers`
2. `paths` (alphabetical by path, then HTTP method)
3. `components.schemas` (alphabetical)
4. `components.parameters`, `components.responses` (if any)
