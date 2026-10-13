# Slate-DLang (`slate-dlang`)

D port of the **Slate** Rust framework (`slate-rust`), built on `slint-d`
the way `slate` builds on the `slint` crate.

## Layer map (Rust → D)

| Rust (`slate-rust`) | D (`slate-dlang`) | Status |
|---|---|---|
| `slate-core::theme::ThemeMode` | `slate.theme` | ✅ exact port + tests |
| `slate-core::task` (`TaskCancellation`, `spawn_compute`) | `slate.tasks` | ✅ + tests |
| `slate-utils` (color, format, math) | `slate.utils.*` | ✅ exact port + tests |
| `slate-extensions::platform` | `slate.platform` | ✅ exact port + tests |
| `slate-extensions::plugin` | `slate.plugin` | ✅ + tests |
| `slate::AppBuilder`, `slate::init` | `slate.app` | ✅ + tests |
| `slate::controller::ComputeController` | `slate.controller` | ✅ + tests |
| `slate::demo` (Monte Carlo π) | `slate.demo` | ✅ bit-identical PRNG + tests |
| `slate-agent` engine (traits, model, error, defaults, bridge, builder) | `slate.agent.{model,error,engine,protocol,bridge,builder}` | ✅ + tests |
| `slate-agent` Slint backends / ACP / semantic | `slate.agent.slint_backend`, `acp`, `semantic` | 🔜 next (needs slint-d element APIs) |
| `slate-mcp` (server, client, tools, transports) | `slate.mcp.*` | 🔜 next |
| `slate-showcase` desktop app | `examples/showcase` | 🔜 next |

## Canonical-D adaptations

- `Option<T>` → `std.typecons.Nullable!T`; `Result<T, E>` → exceptions
  (`PluginException.duplicate`, `SlintCallError` in slint-d).
- Rust trait defaults don't exist for D interfaces: `Plugin.init` has a
  default via the `PluginInit` mixin.
- `AppBuilder` is a value-type builder: combinators return modified copies.
- Purity/safety are explicit: `@safe pure nothrow @nogc` where the Rust code
  is total, `@system`/`@trusted` at thread and FFI boundaries.
- Concurrency uses `core.thread`, `core.sync`, `core.atomic`; UI marshaling
  rides `slint-d` (`invokeFromEventLoop` on native builds).

## Build & test

```sh
source ~/dlang/dmd-*/activate
cd slate-dlang
dub test    # pure-D unit tests, no Slint runtime needed
dub build   # library
```
