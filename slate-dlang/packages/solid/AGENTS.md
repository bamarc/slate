# AGENTS.md — `slate:solid` (`slint2solid`) Cross-Compiler Instructions

This directory contains **`slate:solid`** (`dub` subpackage `slate:solid`), the standalone `.slint` + Dlang controller to **SolidJS (`.tsx`)** and **TypeScript (`.ts`)** cross-compiler (`slint2solid` CLI).

---

## 1. Compiler Pipeline Overview

| Module | File | Responsibility |
|---|---|---|
| `slate.solid.ir` | [`source/slate/solid/ir.d`](source/slate/solid/ir.d) | Intermediate representation (`SlintModuleIr`, `ComponentIr`, `PropertyIr`, `CallbackIr`, `StructIr`, `GlobalIr`, `ElementIr`, `ExprIr`) |
| `slate.solid.lexer` | [`source/slate/solid/lexer.d`](source/slate/solid/lexer.d) | `.slint` tokenizer (keywords, hyphenated identifiers, durations `ms`/`s`, lengths `px`/`rem`, colors `#rrggbbaa`, string interpolation `\{...}`) |
| `slate.solid.parser` | [`source/slate/solid/parser.d`](source/slate/solid/parser.d) | Recursive-descent `.slint` parser producing `SlintModuleIr` |
| `slate.solid.sema` | [`source/slate/solid/sema.d`](source/slate/solid/sema.d) | Semantic analysis: resolves imports, identifies two-way `<=>` bindings, normalizes `kebab-case` ↔ `camelCase`, classifies reactive signals vs derived memos |
| `slate.solid.codegen_tsx` | [`source/slate/solid/codegen_tsx.d`](source/slate/solid/codegen_tsx.d) | Lowers `SlintModuleIr` into idiomatic SolidJS `.tsx` components (`createMutable` globals, `createSignal` for `in-out` properties, `<For>`, `<Show>`, flexbox layouts, SVG `<path>`) |
| `slate.solid.d_to_ts` | [`source/slate/solid/d_to_ts.d`](source/slate/solid/d_to_ts.d) | D2-subset lexer, AST parser, and TypeScript transpiler (`transpileDFileToTs`, `transpileDSourceToTs`) |
| `slate.solid.codegen_controller` | [`source/slate/solid/codegen_controller.d`](source/slate/solid/codegen_controller.d) | Combines compile-time D `__traits` reflection of `McpControllable` controllers with `d_to_ts` AST transpilation to emit `controllers.ts` and `chart.ts` |
| `slate.solid.compiler` | [`source/slate/solid/compiler.d`](source/slate/solid/compiler.d) | Orchestrates full directory compilation (`ui/` → `target/solid-ui/`), emits `runtime.ts` (including in-browser `McpStateRegistry` & `McpServer`), `index.ts`, and `package.json` |
| `slate.solid.cli` | [`source/slate/solid/cli.d`](source/slate/solid/cli.d) | `slint2solid` CLI entrypoint (`dub run :solid --config=slint2solid`) |

---

## 2. Rules for Modifying the Cross-Compiler or D Controllers

1. **Zero Native Slint Dependency**: `slate:solid` must remain 100% pure D (no `libslint_d_bridge` link requirement) so `slint2solid` can run in any headless CI or build container.
2. **Keeping `slate:ui` Controllers Transpiler-Compatible**:
   - When adding methods or fields to controllers in `slate-dlang/packages/ui/source/slate/components/` (`datagrid.d`, `media.d`, `file_dialog.d`, `dropzone.d`, `log_viewer.d`, `layouts.d`), ensure any D constructs used in transpiled classes are supported by `d_to_ts.d` (or mark Slint-native-only binding helpers with `version (SlintNative)` or `@McpIgnore`).
   - Transactional rollback in generated TypeScript relies on `mcpSnapshot()` and `mcpRestoreSnapshot(snap)` emitted by `codegen_controller.d`.
3. **Adding New `.slint` Components in `ui/`**:
   - Whenever a new `.slint` file or layout primitive is added to `ui/`, verify that `just solid-codegen` compiles all `.slint` files cleanly without diagnostics or unresolved imports.

---

## 3. Verification Checklist

Always run both commands before completing changes in `packages/solid/` or `ui/`:

```bash
just slate-test-solid   # Runs lexer, parser, sema, TSX codegen, D-to-TS transpiler, and Node/esbuild runtime E2E tests
just solid-codegen      # Compiles all 64 .slint files in ui/ + D controllers into target/solid-ui/
just d-lint             # Checks D syntax and style rules
```
