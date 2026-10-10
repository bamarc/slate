---
name: debug-failure-analysis
description: 'Systematically debug a failure by reproducing it, modelling the dataflow, mapping involved services and infra/CI-CD, drawing sequence diagrams, identifying implicated files, tracing git history to find where the problem was introduced, and evaluating the relevant specification for breaches or ambiguity. Use when investigating bugs, test failures, pipeline failures, or unexpected behavior.'
---

# Debug Failure Analysis Skill

Debug systematically: reproduce first, model the system, then isolate the cause.
Never guess a fix before the failure is reproduced and the dataflow is understood.

## Phase 1 — Reproduce the Failure

1. Collect the failure evidence: error messages, stack traces, logs, screenshots,
   failing test names, CI job output, timestamps, and environment details.
2. Determine the exact reproduction path: command, request, UI flow, or pipeline
   trigger that causes the failure.
3. Reproduce locally if possible. Use the project's preferred tooling
   (`just`, `scripts/`, `uv run`, `pnpm`, etc.). Record the exact command.
4. If local reproduction is impossible, gather equivalent evidence from logs,
   CI artifacts, or staging environments and document the gap.
5. Note whether the failure is deterministic or intermittent, and any timing,
   ordering, or environment sensitivity.

## Phase 2 — Build the Analysis Overview

Produce a structured analysis with the following sections. Skip a section only
when it is clearly irrelevant to the failure type, and state why.

### Dataflow Model

- Identify the data entities involved in the failing path.
- Trace each entity from its source through transformations, validations,
  storage, and consumption to the point of failure.
- Note data format expectations, serialization boundaries, and schema versions.
- Highlight where the data first diverges from expectations.

### Auth Model (when relevant)

Include this section when the failure involves authentication, authorization,
permissions, tokens, sessions, or identity propagation.

- Map the identity flow: who authenticates, how, and against which provider.
- Trace token/session lifecycle: issuance, validation, refresh, expiry, revocation.
- Identify authorization checkpoints: which roles, scopes, or claims are required
  at each step.
- Note any mismatches between expected and actual auth state at the failure point.

### Involved Services and Infrastructure

- List every service, library, database, queue, cache, external API, and CI/CD
  stage that participates in the failing path.
- Note versions, configurations, and environment-specific differences.
- For infrastructure or CI/CD failures, identify the pipeline stage, runner,
  container image, Terraform/OpenTofu layer, or deployment step involved.

### Dataflow Diagram

Draw a dataflow diagram (Mermaid `flowchart` or `graph`) showing:
- Nodes for each service, store, or transformation step.
- Directed edges labelled with the data or event being passed.
- The point of failure highlighted.

### Sequence Diagram

Draw a sequence diagram (Mermaid `sequenceDiagram`) showing:
- Actors and systems involved.
- Messages in temporal order leading to the failure.
- The failing interaction annotated.

### Involved Files

List every file implicated in the failure path:
- Source files containing the logic that processes the failing data.
- Configuration files that control behavior.
- Test files that cover (or should cover) the behavior.
- Schema, contract, or specification files.
- Infrastructure and CI/CD definition files if relevant.

For each file, note its role in the failure path and whether it was recently
changed.

### Git History — Where Was the Problem Introduced

1. Identify the last known good state (commit, tag, deployment, or date).
2. Use `git log --oneline`, `git log -p`, `git blame`, or `git bisect` to
   narrow the window between the last good state and the first known bad state.
3. Identify the specific commit(s) that introduced or exposed the problem.
4. Note the author, date, commit message, and any related PR/MR or ticket.
5. If the problem is in configuration, infrastructure, or CI/CD, trace changes
   to those files as well.

### Specification Evaluation

- Locate any specification, contract, OpenAPI definition, ADR, design document,
  or acceptance criterion that governs the failing behavior.
- Classify the failure as one of:
  - **Spec breach**: the code contradicts an existing specification.
  - **Spec gap**: the specification is missing, too vague, or does not cover
    the scenario, and the implementation had to guess.
  - **Spec conflict**: two specifications or requirements contradict each other.
- Quote the relevant spec text and explain how the implementation diverges.
- If the spec is vague, note the ambiguity and propose a clarification.

## Phase 3 — Root Cause and Fix Strategy

1. State the root cause in one sentence.
2. Explain why the root cause produces the observed failure, referencing the
   dataflow model and git history.
3. Propose the minimal fix, following the project's TDD workflow:
   - Write a failing regression test first.
   - Implement the smallest change to make it pass.
   - Iterate.
4. Note any follow-up work: spec clarification, documentation update,
   monitoring/alerting addition, or broader refactor.

## Output Format

Structure the analysis as:

```
## Failure Summary
<one-paragraph description>

## Reproduction
<exact command or steps>

## Dataflow Model
<narrative + diagram>

## Auth Model (if relevant)
<narrative>

## Involved Services / Infra / CI-CD
<list>

## Dataflow Diagram
<mermaid>

## Sequence Diagram
<mermaid>

## Involved Files
<table or list>

## Git History
<commit range, introducing commit, blame analysis>

## Specification Evaluation
<spec breach / gap / conflict, with quoted text>

## Root Cause
<one sentence + explanation>

## Fix Strategy
<TDD steps: failing test, minimal fix, iterate>
```

## Working Rules

- Never propose a fix before reproducing the failure and understanding the
  dataflow.
- Use Mermaid for all diagrams.
- Prefer the project's own tooling and commands for reproduction.
- Do not modify production code during the analysis phase.
- Follow the TDD skill (`.agents/skills/test-driven-development/SKILL.md`) for
  the fix implementation.
