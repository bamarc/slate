# `slate:core` — Foundational Slate Runtime & Agent Traits

`slate:core` is the zero-dependency foundational DUB subpackage of [`slate-dlang`](../../README.md). It provides theme tokens, cooperative task scheduling, SVG vector path generation, controller abstractions, and compile-time Model Context Protocol (MCP) capability traits using only the D standard library (Phobos) and `druntime`.

---

## Key Modules (`source/slate/`)

| Module | File | Description |
|---|---|---|
| `slate.theme` | [`source/slate/theme.d`](source/slate/theme.d) | Dark/light theme color palettes, typography scales, and design token definitions matching `ui/components/theme.slint` |
| `slate.tasks` | [`source/slate/tasks.d`](source/slate/tasks.d) | Background worker thread dispatch (`spawnCompute`), progress reporting, and cooperative `CancellationToken` |
| `slate.controller` | [`source/slate/controller.d`](source/slate/controller.d) | Base reactive state controller abstractions and property change notifications |
| `slate.platform` | [`source/slate/platform.d`](source/slate/platform.d) | Host OS detection, desktop environment integration, and XDG directory helpers |
| `slate.plugin` | [`source/slate/plugin.d`](source/slate/plugin.d) | Extensible application plugin lifecycle and registration interfaces |
| `slate.demo` | [`source/slate/demo.d`](source/slate/demo.d) | Deterministic Monte Carlo simulation workload for compute tab demonstrations |
| `slate.utils.chart` | [`source/slate/utils/chart.d`](source/slate/utils/chart.d) | Pure-D SVG path builders (`buildSparklinePath`, `buildAreaPath`, `buildDonutArcPath`) for `SlateSparkline`, `SlateLineChart`, and `SlateDonutChart` |
| `slate.agent.traits` | [`source/slate/agent/traits.d`](source/slate/agent/traits.d) | Compile-time UDAs (`@McpProperty`, `@McpAction`, `@McpIgnore`), capability interfaces (`McpControllable`, `McpBindable`, `McpSeekable`, `McpSortable`, `McpFilterable`, `McpExpandable`, `McpDropReceiver`, `McpSelectable`), and `McpControllableImpl` mixin |

---

## Build & Test

```bash
# From repository root:
just slate-test-core

# Or directly via DUB:
cd slate-dlang && dub test :core
```
