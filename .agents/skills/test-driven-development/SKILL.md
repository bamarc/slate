---
name: test-driven-development
description: 'Use test-driven development (TDD) with the Red, Green, Iterate loop for production code changes: write a useful failing test first, implement the smallest change that makes it pass, then iterate while keeping tests green. Use when creating features, fixing bugs, refactoring behavior, or asking how to work test-driven.'
---

# Test-Driven Development Skill

Apply TDD by default for behavior changes. The goal is fully testable production code with useful, behavior-focused tests — not tests written only to satisfy coverage.

## Core Loop: Red, Green, Iterate

1. **Red — specify behavior with a failing test**
   - Before changing production code, add or update the smallest focused test that expresses the required behavior.
   - Prefer observable outcomes, boundaries, errors, and state transitions over implementation details.
   - Run the narrowest relevant test command and confirm the test fails for the expected reason.

2. **Green — make the test pass simply**
   - Implement the smallest production change that satisfies the failing test.
   - Avoid speculative abstractions, unrelated cleanup, or extra behavior.
   - Run the focused test again and confirm it passes.

3. **Iterate — improve safely while green**
   - Add the next focused failing test, then repeat Red → Green.
   - Refactor only when relevant tests are green, preserving behavior.
   - Keep production code testable by separating pure logic, I/O, and framework wiring.

## What “Useful Tests” Means

Write tests that:
- Name the behavior or rule being protected.
- Cover critical paths, edge cases, failure modes, and regressions.
- Assert outcomes and contracts, not private implementation details unless necessary.
- Are deterministic, independent, and fast enough for the relevant suite.
- Fail with a clear reason when behavior is broken.

Avoid tests that:
- Merely duplicate implementation structure.
- Depend on unrelated global state, timing, network access, or database state unless explicitly required.
- Are broader than needed before a narrower test has established the behavior.

## Working Rules

- Do not implement behavior before a corresponding failing test exists, except for narrowly necessary test setup or infrastructure.
- Start with the narrowest test level that can express the behavior reliably: unit, integration, then end-to-end only where it adds confidence.
- For bug fixes, first write a regression test that reproduces the bug.
- For refactors, preserve or add characterization tests before changing structure.
- Keep test data minimal and intention-revealing.
- Run focused tests during development and the relevant broader suite before considering work complete.

## Agent Execution Checklist

For each behavior change:
1. Identify the exact behavior to change.
2. Write or update one focused failing test.
3. Run it and verify the expected failure.
4. Implement the smallest production change.
5. Run the focused test and verify success.
6. Iterate with additional tests for edge cases and regressions.
7. Refactor only while tests remain green.
8. Run the project’s relevant broader test and lint commands using the repository workflow.
