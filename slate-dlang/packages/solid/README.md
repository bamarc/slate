# `slate:solid` — Slate `.slint` + Dlang to SolidJS Cross-Compiler (`slint2solid`)

`slate:solid` is a standalone, `@safe` Dlang compiler subpackage and CLI (`slint2solid`) that cross-compiles Slate's declarative `.slint` UI components and Dlang application controllers into fine-grained reactive **SolidJS (`.tsx`)** and **TypeScript (`.ts`)** web bundles.

Unlike WebAssembly canvas ports, `slate:solid` produces native semantic HTML5 DOM + Flexbox/Grid CSS + inline SVG elements and reactive TypeScript controller classes with zero Slint C++/Rust runtime dependency.

---

## Architecture & Module Map

| Module | File | Responsibility |
|--------|------|----------------|
| `slate.solid.ast` | [`source/slate/solid/ast.d`](source/slate/solid/ast.d) | Immutable `@safe` AST nodes (`SlintFile`, `GlobalDecl`, `StructDecl`, `PropDecl`, `CallbackDecl`, `ElementNode`, `ForNode`, `IfNode`, `StatesNode`, `TransitionsNode`, `SlintExpr`, `SourceLoc`) |
| `slate.solid.lexer` | [`source/slate/solid/lexer.d`](source/slate/solid/lexer.d) | Zero-allocation `@safe` `.slint` tokenizer supporting kebab-case identifiers, dimensional units (`px`, `rem`, `ms`, `%`, `deg`), color literals, and nested `\{...}` string interpolations |
| `slate.solid.parser` | [`source/slate/solid/parser.d`](source/slate/solid/parser.d) | Recursive-descent `.slint` parser with Pratt operator precedence and bounded recursion depth (`maxParseDepth = 128`) |
| `slate.solid.sema` | [`source/slate/solid/sema.d`](source/slate/solid/sema.d) | Symbol resolution, `in` / `out` / `in-out` two-way binding analysis, `states` flatteners, and `animate` -> CSS `transition` lowering |
| `slate.solid.codegen_tsx` | [`source/slate/solid/codegen_tsx.d`](source/slate/solid/codegen_tsx.d) | SolidJS `.tsx` emitter (`createMutable` globals, controlled/uncontrolled `createSignal` pairs for `in-out` properties, Flexbox/Grid CSS mapping, `<For>`, `<Show>`, `<svg>`, and `accessible-*` -> WAI-ARIA + `data-mcp-id` attributes) |
| `slate.solid.d_to_ts` | [`source/slate/solid/d_to_ts.d`](source/slate/solid/d_to_ts.d) | D2-subset-to-TypeScript AST transpiler for D structs, enums, interfaces, classes, slices (`a .. b`, `$`, `~=`, `.dup`), `foreach` loops, `scope(exit)`/`scope(failure)` (`try / finally`), `in`/`out` contracts, and Phobos math/string/algorithm idioms (`maxParseDepth = 128`) |
| `slate.solid.codegen_controller` | [`source/slate/solid/codegen_controller.d`](source/slate/solid/codegen_controller.d) | Combines compile-time D `__traits` reflection (`McpControllable`, `@McpProperty`, `@McpAction`, `@McpIgnore`) with `d_to_ts` method transpilation to generate reactive TypeScript controller classes with transactional `mcpSetProperty` rollback |
| `slate.solid.compiler` | [`source/slate/solid/compiler.d`](source/slate/solid/compiler.d) | Workspace compiler driver (`compileWorkspaceToSolid`), path/symlink confinement guards, barrel `index.ts` generation, and in-browser `McpStateRegistry` + `McpServer` JSON-RPC 2.0 runtime emitter |
| `slate.bin.slint2solid` | [`source/slate/bin/slint2solid.d`](source/slate/bin/slint2solid.d) | Command-line entrypoint (`slint2solid --ui-dir=... --out-dir=...`) |

---

## Translation Mapping

| Slate / Slint / Dlang Construct | Generated SolidJS / TypeScript Output |
|---|---|
| `export global SlateTheme { in-out property <bool> darkMode: true; ... }` | `export const SlateTheme = createMutable({ darkMode: true, get surface() { ... } });` |
| `in-out property <T> value` | Controlled (`props.value` + `props.onChange$value`) and uncontrolled (`createSignal`) two-way reactive accessor/setter pair |
| `VerticalLayout` / `HorizontalLayout` / `GridLayout` | `<div style={{ display: "flex", "flex-direction": ..., gap: ... }}>` / CSS Grid |
| `for item[idx] in model : Comp { ... }` | `<For each={...}>{(item, idx) => <Comp ... />}</For>` |
| `if cond : A {} else : B {}` | `<Show when={cond} fallback={<B />}><A /></Show>` |
| `TouchArea { clicked => { ... } }` | Pointer, hover (`onMouseEnter`/`onMouseLeave`), press (`onMouseDown`/`onMouseUp`), and keyboard activation handlers |
| `Path { commands: ... }` | `<svg viewBox={...}><path d={...} fill={...} stroke={...} /></svg>` |
| `accessible-role`, `accessible-label`, `accessible-value` | Semantic `role`, `aria-label`, `aria-valuenow`, and `data-mcp-id` DOM attributes |
| Dlang Controllers (`DataGridController`, `MediaPlayerController`, `FileDialogController`, `UploadQueueController`, `RingBufferLogModel`, `WorkspaceDockController`, `WizardController`, `MasterDetailController`) | Reactive TypeScript classes implementing `McpControllable` with `mcpSnapshot()`, transactional `mcpSetProperty()`, `mcpRestoreSnapshot()`, and `mcpInvokeAction()` |
| `slate.utils.chart` (`buildSparklinePath`, `buildAreaPath`, `buildDonutArcPath`) | Pure TypeScript `chart.ts` producing bit-identical SVG path strings |

---

## Usage

### Compile Workspace via `just`

```bash
just solid-codegen
```

### Run CLI Directly

```bash
cd slate-dlang
dub run :solid --config=slint2solid -- --ui-dir=../ui --out-dir=../target/solid-ui
```

### Run Compiler & Runtime Parity Tests

The test suite (`dub test :solid` / `just slate-test-solid`) runs:
1. Lexer & parser unit tests (`tests/parser_test.d`)
2. SolidJS `.tsx` codegen & reactivity tests (`tests/codegen_test.d`)
3. D-to-TypeScript transpiler & `chart.ts` Node runtime parity tests (`tests/d_to_ts_test.d`)
4. Controller reflection, transactional rollback, and in-browser MCP JSON-RPC 2.0 server execution tests (`tests/controller_codegen_test.d`)
5. Full 64-file `ui/` workspace compilation + `esbuild` bundle verification (`tests/workspace_e2e_test.d`)

```bash
just slate-test-solid
```
