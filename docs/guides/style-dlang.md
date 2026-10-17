# Style Guide — Dlang (`slint-d` & `slate-dlang`)

## Tooling
- **Compiler & Build**: DMD `v2.113.0` + DUB `v1.42.0` (`just d-setup` / `just d-check`).
- **Formatter**: `dfmt` (`just d-fmt`), configured via [`.editorconfig`](../../.editorconfig) (4-space indentation, 120-column soft wrap, Unix LF).
- **Static Analyzer / Linter**: `dscanner` (`just d-lint`), configured via [`dscanner.ini`](../../dscanner.ini). All production and test modules must pass both `dscanner --syntaxCheck` and `dscanner --styleCheck --config dscanner.ini` with zero warnings.
- **LSP & AST Queries**: `serve-d` + `dcd` and the `dlang-lsp` MCP tools (`d_lint`, `d_format`, `d_find_declaration`, `d_lsp_document_symbols`, `d_module_imports`).

## Naming Conventions
| Construct | Style | Example |
|---|---|---|
| Packages & modules | `snake_case` | `module slate.components.file_dialog;` |
| Classes, structs, interfaces, enums, templates | `PascalCase` | `class FileDialogController`, `struct MediaTrackData` |
| User-Defined Attributes (UDAs) | `PascalCase` | `@McpProperty`, `@McpAction`, `@McpIgnore` |
| Functions, methods, properties, variables | `camelCase` | `mcpSetProperty`, `sortByColumn`, `selectedPaths` |
| Compile-time constants (`enum`) | `camelCase` or `PascalCase` | `enum maxTreeDepth = 128;` |

## Safety, Contracts & Resource Management
- **`@safe` by Default**: Mark functions and methods `@safe` whenever possible. Isolate C-ABI (`extern(C)`) calls inside minimal `@trusted` wrappers after verifying pointer lifetimes and bounds.
- **Design by Contract (DbC)**: Use `in (...)` and `out (...)` contracts on public controller methods and protocol parsers to enforce preconditions and postconditions.
- **Deterministic Cleanup**: Use `scope(exit)` and `scope(failure)` guards around FFI allocations (`slint_string_free`), file handles, and callback registrations (`ScopedCallback`).

## Imports
- Prefer **selective imports** (`import std.algorithm : map, filter;`) or **scoped local imports** inside functions/unittests to minimize namespace pollution and speed up compilation.
- Respect subpackage dependency boundaries:
  - `slate:core` imports only `std.*` / `core.*`.
  - `slate:mcp` imports only `slate:core` and `std.*` / `core.*` (never `slint`).
  - `slate:solid` imports `slate:core`, `slate:mcp`, `slate:ui` (pure-D `library` config only).

## Unit Testing & Documentation (`unittest`)
- Every behavioral feature or bugfix must have a `unittest` block.
- Prefix each `unittest` with a `// Spec:` comment referencing the requirement and a `/// Example:` Ddoc comment when documenting public API usage:
  ```d
  // Spec: FileDialogController rejects paths escaping sandboxRoot.
  /// Example:
  unittest {
      auto fs = new InMemoryFileSystem(["/workspace/readme.md": "hello"]);
      auto dlg = new FileDialogController(fs, "/workspace");
      assert(!dlg.navigateTo("/etc"));
      assert(dlg.currentDirectory == "/workspace");
  }
  ```
- Gate native Slint window tests with `version (SlintNative)` so `dub test` runs cleanly in pure-D mode.
