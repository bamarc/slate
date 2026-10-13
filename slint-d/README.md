# Slint-D (`slint-d`)

DLang bindings for [**Slint**](https://slint.dev) (v1.18.x), mirroring the
official **Node.js** (`slint-ui` npm package, `api/node`) and **Python**
(`slint` PyPI package, `api/python`) bindings.

## Architecture

Upstream research (slint-ui/slint @ master, docs.slint.dev, docs.rs
`slint-interpreter` 1.18.1) shows both official bindings are thin FFIs over
the **`slint-interpreter`** Rust crate:

- **Node**: `api/node/rust/*` (napi) wraps `Compiler`, `ComponentDefinition`,
  `ComponentInstance`, `Value`, models, and timers; `api/node/typescript/*`
  adds the idiomatic TS layer (`loadFile`, `Model<T>`/`ArrayModel`,
  `register.mjs` auto-loader). The Slint loop is driven by libuv.
- **Python**: `api/python/slint/*.rs` (pyo3/maturin) wraps the same surface
  plus gettext/asyncio integration (`slint/loop.py`); `slint/__init__.py`
  adds the idiomatic layer (`load_file`, `slint.loader`, `ListModel`,
  `@slint.callback`).

`slint-d` follows the same two-layer shape:

```
[ D application code (examples/hello/source/main.d) ]
                    │  idiomatic D: classes, interfaces, structs
                    ▼
[ slint-d D layer (source/slint/*.d) — dub package "slint-d" ]
                    │  extern(C): opaque handles, NUL-terminated UTF-8
                    ▼
[ Rust bridge (bridge/src/lib.rs → libslint_d_bridge.so/.a) ]
                    │  slint-interpreter 1.18.1 (same version as slate-rust)
                    ▼
[ Slint compiler + runtime (shared .slint markup, e.g. ../../ui/) ]
                    │
                    ▼
[ Slint native desktop window / renderer ]
```

## Layout

```
slint-d/
├── dub.json                 # dub package; configs: library (default), native
├── source/slint/
│   ├── package.d            # public root (mirrors TS index.ts / __init__.py)
│   ├── value.d              # Value/ValueType + FFI conversions
│   ├── diagnostics.d        # DiagnosticLevel, Diagnostic
│   ├── capi.d               # extern(C) bridge declarations (FFI boundary)
│   ├── compiler.d           # Compiler, CompilationResult
│   ├── definition.d         # ComponentDefinition + metadata + validateSpec
│   ├── instance.d           # ComponentInstance (props, callbacks, globals)
│   ├── callback.d           # handler registry, FFI shim, scoped lifetimes
│   ├── codegen.d            # SlintProps/SlintCallbacks compile-time mixins
│   ├── model.d              # Model!T, ArrayModel!T, adapters, GeneratorModel
│   ├── fiber.d              # UiTask cooperative tasks on D fibers
│   ├── eventloop.d          # run/quit/invokeFromEventLoop/setXdgAppId
│   ├── timer.d              # Timer / TimerMode (native-scheduled)
│   └── loader.d             # loadFile + LoadOptions
├── bridge/                  # Rust cdylib/staticlib over slint-interpreter
│   ├── Cargo.toml           # slint-interpreter + i-slint-core 1.18.1
│   └── src/lib.rs
└── examples/hello/          # dub app: counter window (app.slint + main.d)
    └── examples/menushow/       # Slate menubar gallery; `--shot out.png`
                                # renders offscreen (no display needed)
    └── examples/gallery/        # Full showcase gallery: wires the Rust
                                # showcase markup from D, renders all tabs
                                # offscreen into renders/dlang-gallery/
```

## Prerequisites

- **DMD 2.113+ + DUB 1.42+** via the user-local installer (no root needed):
  ```sh
  curl -fsS https://dlang.org/install.sh | bash -s install dmd
  source ~/dlang/dmd-*/activate
  ```
  (If `xz` is missing, a Python-`lzma` shim on `PATH` named `xz` suffices.)
- **Rust toolchain** (only for the native bridge): `cargo build` in `bridge/`.

## Build & test

```sh
source ~/dlang/dmd-*/activate

cd slint-d
dub test          # pure-D unit tests, no Slint runtime needed (9 modules)
dub build         # library, pure-D configuration

# Native runtime (run from slint-d/ after `cargo build` in bridge/):
export LD_LIBRARY_PATH=$PWD/bridge/target/debug:$LD_LIBRARY_PATH
dub build --config=native                      # library, native config
cd examples/hello && dub run --config=native  # needs a display server
```

Consumers opt into the native config with
`"subConfigurations": {"slint-d": "native"}` (see `examples/hello/dub.json`).
`LD_LIBRARY_PATH` must cover `bridge/target/debug` (or `release`) at runtime.

Two configurations, matching how Node ships lean vs. dev binaries
(`binaries.json` vs. `binaries-dev.json`) and Python ships `slint` vs.
`slint-dev` wheels:

| config | native runtime | behavior |
|---|---|---|
| `library` (default) | not linked | pure-D API works; runtime calls throw `NativeUnavailable` with a rebuild hint |
| `native` (`-version=SlintNative`, links `slint_d_bridge`) | `bridge/target/{debug,release}` | full compiler/instance/event-loop access |

## API mapping (Node / Python → D)

| Node (`slint-ui`) | Python (`slint`) | D (`slint-d`) |
|---|---|---|
| `loadFile(url, opts?)` | `load_file(path)` | `loadFile(path, LoadOptions)` |
| `new ComponentCompiler()` | `Compiler()` | `new Compiler()` (+ library paths forwarded) |
| `buildFromSource / buildFromPath` | `build_from_source / build_from_path` | `buildFromSource / buildFromPath` |
| `diagnostics` | `diagnostics` | `CompilationResult.diagnostics` |
| `definition(name).create()` | `compdef` → subclass + instantiate | `result.component(name).create()` (+ live metadata) |
| component `.d.ts` declarations | `loader`-generated classes | `SlintProps`/`SlintCallbacks` **compile-time mixins** (checked, zero-cost) |
| `getProperty / setProperty` | attribute get/set | `getNumber/setNumber`, `getString/setString`, `getBool/setBool` |
| `callback = fn` / `callback()` | `@slint.callback` / call | `setCallback` (delegates) / `invoke(name, args)` + `ScopedCallback` RAII |
| global classes | global classes | `get/setGlobal*`, `invokeGlobal`, `setGlobalCallback` |
| `show / hide / run` | `show / hide / run` | `show / hide / run` |
| Slate `render` tool (`take_snapshot`, offscreen) | — (no equivalent) | `snapshot()` + `slint.png.encodePngRgba` |
| `Model<T>` / `ArrayModel<T>` | `Model` / `ListModel` (+ adapters) | `Model!T` / `ArrayModel!T` + `Map/Filter/Sorted/ReverseModel`, fiber-fed `GeneratorModel` |
| `RgbaColor` / `Brush` | `Color` / `Brush` | `Color` (+ `RgbaColor` alias) / `Brush` |
| `ImageData` | `Image` | `ImageData` |
| `Timer` | `Timer` / `TimerMode` | `Timer` / `TimerMode` (native-scheduled) |
| `runEventLoop / quitEventLoop` (libuv) | `run_event_loop / quit_event_loop` (asyncio) | `runEventLoop / quitEventLoop` + `invokeFromEventLoop` (fibers coordinate here) |
| — | `set_xdg_app_id` | `setXdgAppId` |
| `my-prop` ↔ `my_prop` normalization | `my-prop` → `my_prop` | `normalizeProp` |

`.slint` → D type table: `int`/`float`/`length`/`duration`/`angle` → `double`;
`string` → `string`; `bool` → `bool`; `color` → `Color`; `brush` → `Brush`;
`image` → `ImageData`; `styled-text` → `StyledText`; structure → `SlintStruct`
(`Value[string]`); array → `Model!T`; enum → `EnumValue` (name + variant);
`keys` → `Keys`; `data-transfer` → `DataTransfer`.

## Quick start

```d
import slint;
import slint.codegen : Prop, SlintProps, SlintCallbacks;

struct MainWindow {
    ComponentInstance _instance;
    mixin SlintProps!(Prop!("counter", double));
    mixin SlintCallbacks!"request_increase_value";
    alias _instance this;
}

auto result = loadFile("app.slint");          // needs native config
auto w = MainWindow(result.component("MainWindow").create());
w.onRequestIncreaseValue(() { w.counter = w.counter + 1; });
w.run();
```

See `examples/hello/` (counter window, same shape as the Node README example).

## D idioms used

- **String + template mixins** (`slint.codegen`): per-component typed
  accessors generated at compile time from `Prop` specs — Python's runtime
  loader classes and Node's `.d.ts` files, but checked by the compiler.
  `validateSpec` cross-checks a spec against live compiler metadata.
- **`scope(exit)` / `scope(failure)` guards** (D's `defer`): every owned
  FFI string and every registry id is released on its guard; registration
  paths roll back on failure. `ScopedCallback` extends the idiom to RAII.
- **Fibers** (`slint.fiber`, `GeneratorModel`): cooperative `UiTask`s with
  captured errors, plus pull-based models fed by a producer fiber —
  D's answer to Python's asyncio integration, without the loop dependency.

## Roadmap (later phases)

1. ~~Variadic `invoke` / `setCallback` with a D-delegate trampoline~~ done.
2. ~~Globals accessors~~ done. ~~Timers~~ done (native). ~~`invokeFromEventLoop`
   + `setXdgAppId`~~ done.
3. `Value` ↔ interpreter conversion for structs/models/brushes/images
   (scalars cross today; complex payloads are stub shapes).
4. `ModelRc` hand-off: live D models behind Slint array properties
   (adapters compose pure-D today; the bridge half needs a Rust `Model`
   impl calling into D).
5. `Window` handle API, `language` module (input events, list items),
   gettext `initTranslations`, custom file loaders.
6. Code-generated specs from compiler metadata (introspection is live;
   closing the loop into `mixin` input is open).
7. Slate bindings (`AppBuilder`, theme tokens) on top of `slint-d`.
