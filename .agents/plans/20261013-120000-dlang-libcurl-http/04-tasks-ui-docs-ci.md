# P4 — Tasks/UI integration + docs + CI harness

Owns: UB-5 (final enforcement), OPT-2 half. Depends on P2+P3 API freeze.

## 1. Goal

Drive the client from Slate background tasks without blocking the Slint UI, publish documentable examples, and stand up local H2/H3 test servers.

## 2. EARS

- **UB-5:** EVERY `unittest` SHALL carry `// Spec:` or `// Best practice:` plus `/// Example:`; CI review SHALL reject bare-coverage tests.
- **OPT-2:** WHERE configured, Alt-Svc cache MAY persist across `Client` instances (file-backed opt-in).
- Integration: WHEN `spawnCompute` runs a transfer THEN progress/completion SHALL marshal via `slate/tasks.d` dispatch (event loop on native builds), and worker SHALL NOT touch UI objects directly.

## 3. Design

- Thin glue (no new HTTP logic): `http_task.d` helper wrapping `spawnCompute!Response` with `TaskCancellation` → P3 cancel flag mapping; progress fraction from content-length/header or bytes-so-far.
- DDoc: every public symbol gets `/// Example:` that compiles as a unittest (one-shot vs pooled, `byChunk`, `h3Only` guard, cancel). Pooled-use page explicitly marked for high-iteration code.
- Harness: local `nghttpd` (H2+TLS) and H3-capable server (e.g. `quiche`/`nghttp3` example or `curl` test container) on loopback; self-signed cert + `SSL_VERIFYPEER` test both on/off paths; `dub test --config=integration` runs TC-02/TC-04/TC-06 end to end.
- CI: two libcurl matrix legs (H2-only, full H3); skip-with-reason when H3 leg unavailable locally.

## 4. TDD

```gherkin
  Scenario: TC-08 background fetch (integration)
    # Best practice: never block Slint event loop; marshal via dispatch
    # Use: spawnCompute download with progress-bar example
    Given a Slint app with progress callback
    When a background GET runs to completion
    Then UI progress is throttled and completion fires on the UI thread

  Scenario: TC-09 docs-as-tests (UB-5)
    # Best practice: every example is executed
    # Use: the docs pages themselves
    Given the DDoc examples
    When dub test runs
    Then each example executes against the loopback harness
```

## 5. Done criteria

- Integration suite green on H3 leg; H2-only leg skips H3 scenarios with explicit message.
- `dub ddox` (or `dub build --build=docs`) clean; no undocumented public symbol.
- No UI-thread network I/O in examples (`grep` for direct perform on UI path fails review).
