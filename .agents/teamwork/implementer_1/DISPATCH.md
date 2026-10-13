# Dispatch to Implementer 1

<original_task>
This is a single self-contained fix; keep it small and focused.

Implement native D Design-by-Contract (`in`, `out`, `invariant`), RAII Scope Guards (`scope(exit)`, `scope(failure)`), and Cooperative Fibers (`core.thread.fiber.Fiber`) in `slate-dlang`. Review and verification must strictly audit for no cheating, no stubs, no fake passes, and no shortcuts. All work must execute under an 8GB memory ceiling.

Working directory: `/home/developer/projects/slate/slate-dlang`
Integrity mode: benchmark

Reference Plan: `.agents/plans/20261013-094823-dlang-contracts-scope-guards-and-fibers.md`

## Requirements

### R1. Native Design-by-Contract
Implement formal preconditions (`in`), postconditions (`out`), and class invariants (`invariant`) across `slate.agent.model` (`Rect`, `Point`), `slate.utils.math` (`lerp`, `smoothstep`), `slate.tasks` (`ProgressGate.offer`), and `slate.plugin` (`PluginRegistry`). Must be real compiler-evaluated contracts, not no-op stubs or bypassed checks.

### R2. RAII Scope Guards (`scope(exit)`, `scope(failure)`)
Refactor resource cleanup and transactional execution to use native D scope guards in `slate.mcp.transport.memory` (socket lifecycle), `slate.tasks` (`runCompute` completion dispatch), and `slate.agent.bridge` (`UiSlot` handoffs). Implement genuine transactional state rollback on action failures using `scope(failure)`.

### R3. Cooperative Automation Fiber (`slate.agent.fiber`)
Implement `AutomationFiber` using `core.thread.fiber.Fiber` to execute multi-step agent actions that yield (`Fiber.yield()`) and resume across UI event loop frames. Must be a genuine stackful coroutine executing real yielding logic, not a hollow wrapper or synchronous loop pretending to yield.

### R4. Anti-Cheating & Shortcut Verification
The review pipeline must actively audit against:
- Stubs, dummy functions, or placeholder returns (`return true;`, `assert(true);`).
- Cheating tests that only test trivial identities instead of real failure modes.
- Disabled compiler checks or swallowed contract errors.
- Bypassing the 8GB memory ceiling.

## Acceptance Criteria

### Objective Verification
- [ ] `Rect` invariant actively triggers and fails on negative width/height or NaN values.
- [ ] `ProgressGate.offer` precondition actively rejects out-of-bounds (`pct > 1.0` or `< 0.0`) and NaN progress values.
- [ ] `PluginRegistry` invariant guarantees name uniqueness across all lifecycle transitions.
- [ ] `scope(failure)` rollback is proven by a test verifying pre-failure UI state is restored when an action throws.
- [ ] `scope(exit)` guarantees socket/resource cleanup on both clean returns and thrown exceptions.
- [ ] `AutomationFiber` is proven to suspend execution via `Fiber.yield()` and resume state on subsequent calls.
- [ ] Zero stubs, zero dummy passes, and zero bypassed contracts found by adversarial review.
- [ ] All 26+ D unit test modules in `slate-dlang` pass cleanly (`dub test`).
- [ ] Memory consumption remains strictly within the 8GB process limit.
</original_task>

## Additional Context
- Working directory: `/home/developer/projects/slate/.agents/teamwork/implementer_1`
- Parent orchestrator conversation ID: 2aa0772c-7fae-41bc-8083-3ca1f890b1a9
- Code working directory: `/home/developer/projects/slate/slate-dlang`
- Reference plan: `/home/developer/projects/slate/.agents/plans/20261013-094823-dlang-contracts-scope-guards-and-fibers.md`
- Report back with a full handoff and Verification Record.
