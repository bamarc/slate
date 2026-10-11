# 04 — Work Package Template (mandatory for every `handover/WP-*.md`)

Every WP file uses **exactly** these sections in this order. Write it for an implementer that is
literal-minded and cannot fill gaps: give exact paths, signatures, commands, and expected output.
Never write "etc.", "as appropriate", "similar to", or "handle edge cases".

```markdown
# WP-XX — <Title>

| Field | Value |
|---|---|
| Wave | <n> (see 00-meta-implementation-plan.md) |
| Depends on | WP-.. (must be merged and gate-passed) |
| Blocks | WP-.. |
| Recommended model | haiku \| sonnet \| opus (and why, if not haiku) |
| Estimated size | S (<150 LOC) \| M (150-400) \| L (>400 → consider splitting) |
| Plan refs | requirement ids (U*/E*/W*/S*/O*), scenarios (T*), decisions (D*) |
| Contract refs | sections of context/03-shared-contracts.md |

## 1. Objective
Two to four sentences: what exists after this WP that did not exist before, and why.

## 2. Read first (in this order)
Exact file paths (with line ranges where useful) the implementer must read before starting.
Always include 03-shared-contracts.md §0 and the review rubric review/01-haiku-failure-rubric.md.

## 3. Files you own
The exact list from contracts §9. "Touch nothing else. If you must, STOP (§9)."

## 4. Preconditions check
Commands that must succeed before starting, with the expected output, e.g.
`cd slate-rust && cargo test -p slate-agent --test harness_spike_tests` → `test result: ok`.

## 5. Steps (Red → Green → Iterate)
Numbered steps. Every behavior step has three parts:
- **5.n.a Red:** the exact test (full Rust code, or a precise skeleton with every assertion
  spelled out), the file to put it in, the command to run, and the expected failure.
- **5.n.b Green:** the exact code to add or change (full signatures, and the algorithm in
  numbered sub-steps; full code when it is short or easy to get wrong).
- **5.n.c Verify:** the command and the expected passing output.
Refactor-only steps say so explicitly and end with the same verify command.

## 6. Acceptance criteria
A checklist. Each item can be checked by a command or a grep, with the expected result.
Always include:
- [ ] `cd slate-rust && just check` clean (or the narrower `cargo check -p <crate>` if a later WP owns compile breakage, stated explicitly)
- [ ] the WP's test command passes
- [ ] `just fmt` produces no diff
- [ ] forbidden-pattern grep (contracts §0 G5) on owned files returns nothing

## 7. Forbidden in this WP
WP-specific forbidden shortcuts (in addition to contracts G1–G8), e.g. "do not add a pointer
click to make activate work", "do not special-case the label 'Max Right'".

## 8. Report template
What the implementer must return to the orchestrator:
- the Red output (failing test run, pasted)
- the Green output (passing run, pasted)
- the files changed (`git diff --stat`)
- any deviation from the contracts (should be none; if there is one, it must have been escalated)
- open issues

## 9. STOP and escalate when
Concrete conditions under which the implementer stops and reports instead of improvising, e.g.
- a contract signature does not compile against Slint 1.18.1
- a test can only pass by mocking, by `#[ignore]`, or by weakening an assertion
- the work needs a file you do not own
- the work needs a new crate dependency
- more than 2 failed attempts at the same compile error
```
