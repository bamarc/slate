# Plan: D-Specific Scope Guards, Design-by-Contract, and Cooperative Fibers for Slate

- **Owning Project**: `slate-dlang`
- **Status**: `draft`
- **Revision**: 1
- **Timestamp**: 2026-10-13T09:48:23Z
- **Author**: Antigravity Architect & Systems Engineer

---

## 1. Goal, Scope, and Non-Goals

### Goal
Incorporate D's premier language features—**RAII Scope Guards** (`scope(exit)`, `scope(failure)`), **Design-by-Contract** (`in`, `out`, `invariant`), and **Cooperative Fibers** (`core.thread.fiber.Fiber`)—into `slate-dlang`. This eliminates manual resource cleanup boilerplate, formally enforces geometric and lifecycle invariants at compile/debug time, and introduces lightweight non-blocking coroutines for multi-step agent UI automation.

### Scope
1. **Scope Guards (`scope(exit)`, `scope(failure)`)**:
   - Replace nested `try / finally` blocks and manual cleanup in `slate.agent.bridge`, `slate.mcp.transport`, and `slate.tasks` with idiomatic `scope(exit)`.
   - Introduce transactional execution patterns with `scope(failure)` in agent action execution and plugin registration.
2. **Design-by-Contract (`in`, `out`, `invariant`)**:
   - Embed geometric invariants in `Rect` (`width >= 0`, `height >= 0`, no `NaN`) and `Point` (`!isNaN`).
   - Add formal contracts to math/color utilities (`lerp`, `smoothstep`, `Rgba.adjustBrightness`).
   - Enforce normalized range contracts on UI progress pipelines (`ProgressGate.offer`).
   - Embed class invariants on `PluginRegistry` guaranteeing uniqueness and non-empty plugin state.
3. **Cooperative Fibers (`slate.agent.fiber`)**:
   - Create a lightweight coroutine runner `AutomationFiber` using `core.thread.fiber.Fiber`.
   - Enable sequential, multi-step agent actions (click, wait, assert, type) that yield (`Fiber.yield()`) to the UI event loop without allocating OS kernel threads or adopting viral `async/await`.

### Non-Goals
- Replacing `core.thread.Thread` for heavy CPU parallel workloads (e.g. Monte Carlo $\pi$ calculation remains on dedicated OS worker threads).
- Altering the MCP JSON-RPC 2.0 wire protocol.
- Breaking backwards compatibility with the existing Slint C-ABI.

---

## 2. Evidence and Current Behavior

### Cited Repository Findings
- [`slate-dlang/source/slate/agent/model.d`](../../slate-dlang/source/slate/agent/model.d#L63-L104): `Rect` has no invariants guarding against negative dimensions or `NaN` values, allowing invalid geometry to propagate to the Slint layout engine.
- [`slate-dlang/source/slate/tasks.d`](../../slate-dlang/source/slate/tasks.d#L61-L76): `ProgressGate.offer` accepts raw `float pct` without formal contracts asserting that `pct in [0.0, 1.0]`.
- [`slate-dlang/source/slate/plugin.d`](../../slate-dlang/source/slate/plugin.d#L46-L88): `PluginRegistry` handles duplicate registrations imperatively via runtime `if` checks rather than declarative class invariants.
- [`slate-dlang/source/slate/mcp/transport/memory.d`](../../slate-dlang/source/slate/mcp/transport/memory.d): Sockets and transport loops rely on manual cleanup across exit paths.
- [`slate-dlang/source/slate/agent/bridge.d`](../../slate-dlang/source/slate/agent/bridge.d): Multi-step agent actions currently lack transactional rollback mechanisms if an intermediate action fails.

### Data Flow Diagram

```mermaid
flowchart TD
    subgraph Agent_Script["Agent Automation Script (Fiber)"]
        F[AutomationFiber] -->|Step 1: Focus| A1[Click/Focus]
        A1 -->|Fiber.yield()| EV[Slint Event Loop Tick]
        EV -->|Step 2: Input| A2[Send Keys]
        A2 -->|Fiber.yield()| EV
        EV -->|Step 3: Assert| A3[Inspect State]
    end

    subgraph State_Transaction["Action Execution Boundary"]
        A1 -->|scope(failure)| RB[Rollback UI State]
        A2 -->|scope(failure)| RB
    end

    subgraph Contracts["Design-by-Contract Invariants"]
        A1 -->|Rect invariant| G[Geometry Bounds Check]
        A2 -->|in/out contracts| P[ProgressGate Monotonicity]
    end
```

---

## 3. Proposed Design and Material Decisions

### Decision 1 (D1): Scope Guards for Cleanup & Rollback
- **Problem**: Manual resource cleanup and state recovery across multiple return paths is error-prone.
- **Options**:
  - *Option A (Keep try/catch/finally)*: Verbose, indentation-heavy, easily slips on new return paths.
  - *Option B (Use `scope(exit)` and `scope(failure)`)*: Canonical D idiom; cleanup is colocated with resource allocation, and rollback code only triggers on thrown exceptions.
- **Selected**: **Option B**.

### Decision 2 (D2): Contract Programming for Domain Models & Geometry
- **Problem**: Silent propagation of `NaN` or negative bounding box values in UI layout calculation.
- **Options**:
  - *Option A (Runtime exceptions on every field access)*: High runtime penalty, breaks `@nogc pure`.
  - *Option B (Native D `in`, `out`, and `invariant`)*: Zero production overhead in release builds (`-release`), guaranteed validation in debug and test suites.
- **Selected**: **Option B**.

### Decision 3 (D3): Cooperative Fibers for Multi-Step UI Automation
- **Problem**: Multi-step agent automation scripts (e.g., clicking, waiting for frame render, checking text) currently either block the calling thread or require complex callback state machines.
- **Options**:
  - *Option A (OS Threads with sleep)*: Heavyweight, allocates kernel thread stacks (2MB–8MB each), dangerous if synchronized with the UI event loop.
  - *Option B (Stackful `Fiber`)*: Runs cooperatively on the UI thread, yields when waiting for redraws, preserves stack state without async/await function coloring.
- **Selected**: **Option B** (implemented in `slate.agent.fiber`).

---

## 4. Requirements and Acceptance Tests

### EARS Requirements
- **U1**: The `Rect` struct shall maintain an invariant ensuring `width >= 0.0f`, `height >= 0.0f`, and coordinates are non-`NaN`.
- **U2**: The `ProgressGate.offer` function shall enforce preconditions that input progress is non-`NaN` and normalized within `[0.0, 1.0]`.
- **U3**: The `PluginRegistry` shall maintain a class invariant guaranteeing that no two registered plugins share the same name.
- **U4**: The `AutomationFiber` shall support sequential execution of actions and yield execution to the caller via `Fiber.yield()`.
- **E1**: When a multi-step agent action encounters an exception, the `scope(failure)` guard shall trigger state restoration.
- **E2**: When an in-memory transport session exits, the `scope(exit)` guard shall guarantee that connected sockets are closed cleanly.

### Acceptance Scenarios (Gherkin)

```gherkin
Scenario: T1 - Geometry invariant prevents negative dimensions (covers U1)
  Given a Rect initialized with valid positive bounds
  When width is set to a negative value in debug mode
  Then an InvariantError is triggered

Scenario: T2 - ProgressGate precondition rejects out-of-bounds progress (covers U2)
  Given an active ProgressGate
  When offer() is called with a progress value > 1.0 or NaN in debug mode
  Then an AssertError is triggered

Scenario: T3 - PluginRegistry invariant enforces name uniqueness (covers U3)
  Given an initialized PluginRegistry
  When plugins are registered
  Then the class invariant verifies that all registered names remain distinct

Scenario: T4 - AutomationFiber yields and resumes across frames (covers U4)
  Given an AutomationFiber with 3 sequential steps
  When call() is invoked
  Then Step 1 executes and yields
  When call() is invoked again
  Then Step 2 executes and yields without blocking the main thread

Scenario: T5 - scope(failure) transactional rollback on action failure (covers E1)
  Given a transactional UI action sequence
  When an exception is thrown during execution
  Then the scope(failure) block restores the pre-action snapshot
```

### Coverage Matrix
| Scenario | Requirement IDs | Target Test Module | Layer |
|---|---|---|---|
| `T1` | `U1` | `slate.agent.model` (unittest) | Unit |
| `T2` | `U2` | `slate.tasks` (unittest) | Unit |
| `T3` | `U3` | `slate.plugin` (unittest) | Unit |
| `T4` | `U4` | `slate.agent.fiber` (unittest) | Unit |
| `T5` | `E1` | `slate.agent.bridge` (unittest) | Unit |

---

## 5. Affected Files and Implementation Steps

### Planned Increments (TDD Red-Green Loop)

#### Increment 1: Contracts and Invariants
- `[MODIFY]` `slate-dlang/source/slate/agent/model.d`: Add `invariant()` blocks to `Rect` and `Point`.
- `[MODIFY]` `slate-dlang/source/slate/utils/math.d`: Add `in` contracts to `lerp` and `smoothstep`.
- `[MODIFY]` `slate-dlang/source/slate/tasks.d`: Add `in` contracts to `ProgressGate.offer`.
- `[MODIFY]` `slate-dlang/source/slate/plugin.d`: Add `invariant()` block to `PluginRegistry`.

#### Increment 2: Scope Guards Refactoring
- `[MODIFY]` `slate-dlang/source/slate/mcp/transport/memory.d`: Refactor socket cleanup with `scope(exit)`.
- `[MODIFY]` `slate-dlang/source/slate/tasks.d`: Refactor `runCompute` completion dispatch using `scope(exit)`.
- `[MODIFY]` `slate-dlang/source/slate/agent/bridge.d`: Use `scope(exit)` and `scope(failure)` in `UiSlot` handoffs.

#### Increment 3: Cooperative Automation Fiber
- `[NEW]` `slate-dlang/source/slate/agent/fiber.d`: Implement `AutomationFiber` and step-wise coroutine runner.
- `[MODIFY]` `slate-dlang/source/slate/agent/package.d`: Publicly export `slate.agent.fiber`.

---

## 6. Verification

### Execution Environment
- Compiler: `dmd-2.113.0` via `/home/developer/dlang/dmd-2.113.0/activate`
- Build System: `dub` (via `dub test`)
- Target Workspace: `/home/developer/projects/slate/slate-dlang`

### Verification Commands
```sh
source /home/developer/dlang/dmd-2.113.0/activate
cd /home/developer/projects/slate/slate-dlang
dub test
```

---

## 7. Risks and Delivery

- **Risk 1: Invariants breaking deserialization of incomplete JSON**:
  *Mitigation*: Default initializers for `Rect` and `Point` are `0.0f` (valid geometry). Deserialization populates complete values before invariant checks run.
- **Risk 2: Fiber stack size overhead**:
  *Mitigation*: Default fiber stack size is sized conservatively (64 KB) to support thousands of concurrent coroutines within the 8GB memory envelope.

---

## 8. Assumptions, Open Questions, and Approval Gate

### Assumptions
- Invariants run during debug/test builds (`dub test`) and are elided in release mode (`-release`), providing safety with zero production CPU penalty.
- `core.thread.fiber.Fiber` is fully supported on Linux x86_64 in Phobos.

### Approval Gate
- **Status**: `draft` awaiting user review.
- Canonical Plan File: `.agents/plans/20261013-094823-dlang-contracts-scope-guards-and-fibers.md`.
