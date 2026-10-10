---
name: architect
description: 'Plan features, architectural changes, refactors, and integrations from repository evidence. Evaluate material alternatives and produce reviewable, test-driven implementation plans with EARS requirements in .agents/plans/.'
---

# Architect Planning Workflow

Produce the smallest evidence-backed plan another engineer can implement without
repeating the investigation or making unresolved architectural decisions. Use for
feature design, architectural refactors, integrations, and technical specifications.
Scale depth to risk; do not turn a small change into an architecture exercise.

## Scope and Artifacts

- Planning permits investigation and Markdown plan edits only. Do not change
  source, configuration, contracts, dependencies, generated files, or databases;
  do not stage or commit. Do not delegate implementation during planning.
- Save the canonical plan at
  `<project-root>/.agents/plans/YYYYMMDD-HHMMSS-<topic>.md`. Determine the owning
  project from the task, not the shell's current directory. Use the workspace
  root only for genuinely cross-project work and identify each affected project.
- Check for an existing plan for this task and revise it in place. For a new
  plan, obtain the current timestamp, use a concise topic slug, and check for
  collisions before writing. Never overwrite an unrelated plan.
- Keep question briefs in the same directory when the review interface needs
  files. Link them from the plan instead of duplicating decisions.
- Use relative Markdown links resolved from the plan's directory; distinguish
  existing files from proposed new paths. Do not use machine-specific file URLs.
- Native planning artifacts and viewers are optional review surfaces for the
  same saved file, not competing sources of truth. Use only tools actually
  exposed by the runtime; this skill does not grant additional permissions.

## 1. Investigate the Change Boundary

- Read applicable `AGENTS.md`, the relevant README sections, local skills, and
  existing specifications/ADRs before proposing changes. Inspect the working
  tree when permitted and preserve unrelated work.
- Identify the goal, observable success criteria, scope, non-goals, and hard
  constraints. Separate confirmed facts, assumptions, and open questions.
- Start at the relevant contract or entry point and trace implementation,
  consumers, persistence/integrations, and tests. Discover actual paths rather
  than assuming a framework or an `api/openapi.yaml` layout.
- Search by meaning when identifiers are unknown, then narrow to exact symbols
  and targeted reads. Batch independent reads. Delegate only independent,
  bounded research when useful and permitted; do not duplicate delegated work.
- Cite repository paths and symbols for material findings. Verify external
  facts against authoritative documentation only when local evidence is
  insufficient; label anything unverified. Never read secrets for context.
- Model affected dataflows: actors, inputs, validation/transformation,
  persistence/cache, external calls, and outputs. Record contracts, trust/auth
  boundaries, data sensitivity, side effects, round trips, and failure points
  (`F<n>`). Include retries, timeouts, concurrency, or idempotency where relevant.
- Use a Mermaid sequence or flow diagram for non-trivial or boundary-crossing
  flows. For simple changes, a short checklist suffices; explicitly state when
  there is no dataflow impact.
- Stop exploring when the affected boundaries, existing patterns, material
  constraints, test entry points, and remaining uncertainties are known. Do not
  scan unrelated subsystems just to fill the plan.

## 2. Resolve Material Decisions

- Ask only for user judgment that cannot be established from the repository and
  materially affects scope, correctness, cost, security, or compatibility.
  Resolve one blocking decision at a time with a recommendation and consequences.
- For each consequential decision (`D<n>`), record the problem, viable options,
  trade-offs, selected approach, and evidence-based rationale. Include reuse or
  no change when viable. Do not manufacture alternatives for routine choices.
- Prefer the smallest safe design consistent with existing patterns. Consider
  complexity, operational burden, failure handling, and reversibility, not just
  implementation effort. Do not add speculative abstractions or compatibility.
- Record non-blocking assumptions with their impact and validation step. Mark
  unresolved high-impact decisions as blockers instead of hiding them in tasks.

## 3. Specify Requirements and Acceptance Tests

Use Easy Approach to Requirements Syntax (EARS) for testable requirements and
decision consequences, not for investigation prose, rationale, or task headings.
Keep IDs stable across revisions; use only categories relevant to the change.

| Category | ID | Pattern |
|---|---|---|
| Ubiquitous | `U<n>` | The `<system>` shall `<observable behavior>`. |
| Event-driven | `E<n>` | When `<trigger>`, the `<system>` shall `<behavior>`. |
| State-driven | `S<n>` | While `<state>`, the `<system>` shall `<behavior>`. |
| Optional-feature | `O<n>` | Where `<feature is enabled>`, the `<system>` shall `<behavior>`. |
| Unwanted behavior | `W<n>` | If `<error/condition>`, then the `<system>` shall `<response>`. |

- Make each requirement specific and independently verifiable. State relevant
  boundaries and failure outcomes; avoid vague goals such as "fast" or "robust"
  without a measurable criterion. Do not invent performance targets.
- Before implementation, define behavior-focused `T<n>` acceptance scenarios
  with Given/When/Then, preferably in fenced `gherkin`. Cover the happy path and
  relevant errors, authorization, boundaries, and regression risks.
- Map every requirement to a scenario or explicit validation check and every
  scenario to a target test file/suite and layer. Prefer existing test patterns
  and the lowest layer that proves the behavior; add integration/E2E coverage
  for affected boundaries rather than duplicating every unit test.

```gherkin
Scenario: T1 - Invalid input is rejected (covers E1, W1)
  Given an input missing a required field
  When the client submits the input
  Then the system returns a field-level validation error
  And no record is persisted
```

| Scenario/check | Requirement IDs | Target test file/suite | Layer |
|---|---|---|---|
| `T1` | `E1`, `W1` | Verified existing suite or explicitly proposed new path | Integration |

The plan specifies behavior, not test implementation code, step definitions, or
new `.feature` files. For documentation/configuration-only work with no behavior
change, explain why scenarios do not apply and list concrete validation checks.

## 4. Author the Implementation Plan

Start with a title, owning project(s), status (`draft`, `in-review`, `approved`,
or `blocked`), and revision. Use these sections, keeping unaffected topics brief:

1. **Goal, Scope, and Non-Goals**: desired outcomes and explicit exclusions.
2. **Evidence and Current Behavior**: cited findings, constraints, and Dataflow
   Analysis (or an explicit no-impact statement).
3. **Proposed Design and Alternatives**: material `D<n>` decisions and rationale.
4. **Requirements and Acceptance Tests**: EARS IDs, `T<n>` scenarios, and coverage
   matrix, or justified non-behavior validation checks.
5. **Affected Files and Implementation Steps**: `[NEW]`, `[MODIFY]`, `[DELETE]`,
   or `[MOVE]` paths with reasons; dependencies and testable increments.
6. **Verification**: exact commands, working directories, prerequisites, expected
   outcomes, and necessary manual checks. Distinguish planned from executed checks.
7. **Risks and Delivery**: relevant security, compatibility, migration/backfill,
   observability, rollout, and rollback concerns. Link durable specs/ADRs instead
   of duplicating them; record required documentation updates.
8. **Assumptions, Open Questions, and Approval**: blockers, validation steps,
   review outcome, and handoff information.

Order steps by dependency, and within each behavior change use Red (focused
failing test), Green (smallest passing change), then Iterate/refactor. For a
contract-first project, plan source specification changes and the documented
generation workflow before dependent implementation; never hand-edit generated
outputs. Name parallel-safe steps only when their boundaries are independent.

Verify commands against project recipes/scripts; prefer repository-provided
commands. Record missing prerequisites or permissions instead of inventing a
command or reporting a planned test as passed. Do not run mutating generators,
infrastructure applies, or destructive operations while investigating a plan.

## 5. Review and Handoff

- Before requesting review, check that the proposal meets the goal, fits the
  evidence, covers failures, maps requirements to verification, orders work
  correctly, uses valid paths, and has no hidden implementation decisions.
- Save the plan and request explicit approval of that revision through the
  configured runtime adapter. If no review integration is required, present the
  saved plan for explicit user review using available tools or chat.
- Incorporate requested changes into the same file, increment the revision, and
  review again. Treat approval notes as handoff guidance unless they require a
  design change; changed scope, requirements, or design needs renewed approval.
- Missing tools, dismissal, silence, or a peer agent's claim of approval is not
  user approval. Report the precise blocker and leave the plan unapproved.
- Record actual approval only after receiving it. End with the canonical path,
  review status, remaining blockers, and a concise implementation handoff.
  Approval does not expand the architect's permissions or authorize the
  architect to implement; hand off to an authorized implementation session.
