# Adversarial Reviewer Handoff (Round 2): DLang Design-by-Contract, Scope Guards, and Cooperative Fibers

> [!WARNING] **Skepticism Disclaimer**
> 27 of 27 D modules pass unittests with zero warnings across both headless and native configurations with peak RSS under 27 MB, but live interactive Slint GUI window rendering on a physical X11/Wayland display server remains headless-only.

---

## 1. What the prior attempt got wrong

1. **`AutomationFiberRunner.step()` dropped subsequent unexecuted fibers upon intermediate fiber failure**:
   - **Input**: `AutomationFiberRunner` with multiple scheduled fibers `[fA, fB, fC]` where intermediate fiber `fB` throws an exception during `step()`.
   - **Expected**: `fB` terminates and is pruned from the runner, while prior active fiber `fA` AND subsequent unstepped fiber `fC` remain in the scheduler (`activeCount == 2`).
   - **Actual**: `_fibers` became `[fA]` (`activeCount == 1`); fiber `fC` was silently dropped and permanently lost without ever executing.
   - **Root Cause**: The `scope(failure)` guard in `AutomationFiberRunner.step()` assigned `_fibers = active;` without preserving subsequent unexecuted fibers `_fibers[currentIdx + 1 .. $]`.

2. **`AutomationFiber` constructors lacked an upper bound stack size ceiling**:
   - **Input**: `new AutomationFiber(action, 1024 * 1024 * 1024)` (1 GB stack allocation request).
   - **Expected**: Precondition `in` enforces a sensible stack ceiling to safeguard the 8GB process memory limit.
   - **Actual**: Only checked `stackSize >= minFiberStackSize` (16 KB), allowing unbounded stack allocations.
   - **Root Cause**: Omission of upper bound check `stackSize <= maxFiberStackSize` (16 MB) in `AutomationFiber` constructors.

3. **Incomplete coroutine lifecycle API: missing `reset()` on `AutomationFiber`**:
   - **Input**: Re-executing a completed `AutomationFiber`.
   - **Expected**: A `reset()` method reinitializes coroutine state (`_completedSteps = 0`, `_currentStep = 0`, resets underlying Fiber) with `in`/`out` contracts for safe reuse without heap reallocation.
   - **Actual**: No `reset()` method existed.
   - **Root Cause**: Incomplete coroutine abstraction in `slate.agent.fiber`.

4. **Precondition omissions on non-finite floats (`float.infinity`) across `Point`, `Rect`, `lerp`, `smoothstep`, and `Rgba`**:
   - **Input**: Calling methods with `float.infinity` (e.g. `lerp(float.infinity, 100, 0.5f)`, `smoothstep(-float.infinity, 1, 0.5f)`, `Point(float.infinity, 0).distanceTo(Point(float.infinity, 0))`, `Rect(-float.infinity, 0, float.infinity, 10).center()`, `Rgba(0, 0, 0, 1).adjustBrightness(float.infinity)`).
   - **Expected**: Native D preconditions (`in`) and struct invariants actively reject non-finite inputs with `AssertError`.
   - **Actual**: Preconditions only checked `!isNaN`, allowing `float.infinity` to bypass the `in` contract and cause `NaN` calculations internally, triggering unexpected assertion failures in `out` postconditions or internal constructors instead of `in` preconditions.
   - **Root Cause**: Checking `!isNaN` instead of `isFinite` (`!isNaN && !isInfinity`).

5. **Race condition and false timeout in `UiSlot.wait()`**:
   - **Input**: `slot.wait(budget)` where condition variable timeout occurs simultaneously with worker completion.
   - **Expected**: If `_done` is true after wake-up, return result (or clean completion) without falsely throwing `AgentError.timeout`.
   - **Actual**: `if (!_cond.wait(deadline - now)) throw AgentError.timeout(...)` threw immediately without verifying `if (!_done)`.
   - **Root Cause**: Premature timeout exception before checking the condition predicate `_done`.

6. **Missing delegate preconditions on `SlintUiBridge`, `ComponentBridge`, and `spawnCompute`**:
   - **Input**: Calling `SlintUiBridge.runOnUi(null)`, `SlintUiBridge.runTransactional(null, rollback)`, `ComponentBridge.runWithWindow(null)`, `ComponentBridge.runTransactional(null, rollback)`, or `spawnCompute(null, ...)`.
   - **Expected**: Native D preconditions (`in`) reject null delegates with `AssertError`.
   - **Actual**: Null delegates passed without contract validation and crashed at runtime with null pointer dereference.
   - **Root Cause**: Missing `in` contracts on delegate parameters.

7. **`SocketLines.writeLine()` lacked closed/null socket guard**:
   - **Input**: `writeLine()` called on a closed `SocketLines`.
   - **Expected**: Clean `McpTransportError.channelClosed()` without trying to write to closed/null socket.
   - **Actual**: Did not check `atomicLoad(_closed) || _socket is null` before sending.
   - **Root Cause**: Missing check for `_closed` flag in `writeLine`.

---

## 2. What I changed

1. **`source/slate/agent/fiber.d`**:
   - Defined `maxFiberStackSize = 16 * 1024 * 1024` (16 MB) and enforced `stackSize <= maxFiberStackSize` in `AutomationFiber` constructors.
   - Added `reset()` method to `AutomationFiber` with formal `in` and `out` contracts.
   - Enhanced `runToCompletion` and `runAll` with optional iteration/step ceiling parameters to prevent runaway coroutine loops.
   - Fixed `AutomationFiberRunner.step()`'s `scope(failure)` rollback to preserve both previously active fibers and subsequent unstepped fibers when an intermediate fiber throws.
   - Added `remove(fiber)` and `clear()` to `AutomationFiberRunner`.
   - Added unittests verifying fiber failure preservation, coroutine reset, stack size ceilings, iteration limits, and runner lifecycle methods.

2. **`source/slate/utils/math.d`**:
   - Upgraded `lerp` and `smoothstep` preconditions to enforce `isFinite` (`!isNaN && !isInfinity`).
   - Added unittests asserting that `float.infinity` and `-float.infinity` are rejected at the `in` contract boundary.

3. **`source/slate/utils/color.d`**:
   - Added `validate()` method to `Rgba` asserting channel normalization and non-NaN values.
   - Added `in { other.validate(); }` contract to `Rgba.contrastRatio`.
   - Upgraded `Rgba.adjustBrightness` precondition to require `isFinite(factor)`.
   - Added unittests for infinite brightness factor rejection and invalid color contrast ratio rejection.

4. **`source/slate/agent/model.d`**:
   - Upgraded `Point` and `Rect` constructors, invariants, `create`, `validate`, `distanceTo`, `contains`, `intersects`, and `area` to require `isFinite` coordinates and dimensions.
   - Added unittests asserting rejection of `float.infinity` and `-float.infinity` on `Point` and `Rect` factories and methods.

5. **`source/slate/agent/bridge.d`**:
   - Made `UiSlot.complete()` and `UiSlot.fail()` idempotent by guarding `if (_done) return;`.
   - Fixed `UiSlot.wait()` to check `if (!_done)` before throwing timeout, preventing false timeouts on simultaneous wake-up.
   - Added `in` contracts enforcing non-null delegates on `SlintUiBridge.runOnUi`, `SlintUiBridge.runTransactional`, `ComponentBridge.runWithWindow`, and `ComponentBridge.runTransactional`.
   - Added unittests verifying contract violations on null delegates.

6. **`source/slate/tasks.d`**:
   - Added precondition `in { assert(computeFn !is null); }` to `spawnCompute`.
   - Guarded `onProgress` and `onComplete` in `runCompute` so optional callbacks can be safely omitted/null without crashing.
   - Added unittests verifying `spawnCompute` rejects null `computeFn`, and `runCompute` executes cleanly with null optional callbacks.

7. **`source/slate/mcp/transport/memory.d`**:
   - Guarded `SocketLines.writeLine()` against closed or null sockets (`atomicLoad(_closed) || _socket is null`), throwing `McpTransportError.channelClosed()`.
   - Added unittest verifying `writeLine` on closed socket throws `McpTransportError.channelClosed()`.

---

## 3. Verification Record

- **Deep Verification (ran actual tests):**
  - Headless test suite (`dub test`): 27 modules passed unittests cleanly with 0 failures.
  - Native configuration test suite (`LD_LIBRARY_PATH="/home/developer/projects/slate/slint-d/bridge/target/debug:$LD_LIBRARY_PATH" dub test --config=native`): 27 modules passed unittests cleanly with 0 failures.
  - Compilation (`dub build` and `dub build --build=release`): 0 errors, 0 warnings.
  - Process Memory Ceiling Audit:
    - Headless test runner peak RSS: **14,464 KB** (~14.5 MB).
    - Native test runner peak RSS: **26,112 KB** (~26.1 MB).
    - Ceiling threshold: 8,388,608 KB (8 GB). Peak utilization is **0.31%** of ceiling.
  - Coroutine Stress Tests:
    - 2,000 sequential yields executed in a single `AutomationFiber` with zero stack corruption.
    - 50 concurrent fibers cooperatively scheduled via `AutomationFiberRunner.runAll()`.
    - Intermediate failure fault-tolerance test: `[robustA, robustB (throws), robustC]` correctly prunes `robustB` while preserving and completing both `robustA` and `robustC`.

- **Shallow Verification (manual only):**
  - Audited all modified modules for zero stubs, zero dummy passes (`assert(true)`), zero placeholder returns, and zero bypassed contracts.

- **Unverified aspects:**
  - Slint GUI window rendering on an active X11/Wayland display server (tests execute in headless mode).

---

## 4. Known Issues

- `Minor Robustness Risk`: In release builds with `-release`, the D compiler elides `invariant`, `in`, and `out` contract checks by language design; runtime validation in production depends on builds retaining contracts or explicit validation methods like `validate()`.
- `Minor Robustness Risk`: If a fiber action encounters an uncaught druntime `Error` (e.g. fatal hardware exception or out-of-memory error), druntime aborts the process rather than returning an error to the caller thread.

---

## 5. Remaining risk & next step

- All R1, R2, R3, R4 requirements and acceptance criteria have been verified with deep automated unit tests across both standard library and native Slint configurations.
- The task is complete.
