# ADR NNNN: [Short, Imperative Title Summarizing the Decision]

- **Status:** Proposed <!-- Proposed | Accepted | Rejected | Deprecated | Superseded -->
- **Date:** YYYY-MM-DD
- **Authors:** Firstname Lastname (@handle)
- **Deciders:** Firstname Lastname (@handle), Firstname Lastname (@handle)
- **Category:** Architecture | Tooling | Infrastructure | Security | CI/CD
- **Supersedes:** None <!-- link:NNNN-title.md[ADR NNNN] if applicable -->
- **Superseded by:** None <!-- link:XXXX-title.md[ADR XXXX] once updated -->
- **Related MR / Issue:** [MR !XX / Issue #YY](https://git.eon-cds.de/...)

## Context & Problem Statement

<!--
What context led to this decision? What specific problem or friction are we solving?
State facts clearly without jumping directly into the solution.
-->

Describe the context and background here:
- Current state and its shortcomings.
- Pain points felt by contributors, consumers, or platform operations.
- External constraints (tooling limits, company compliance, deadlines).

## Decision Drivers

- **Technical / Quality:** [e.g., Modularity, performance, maintainability]
- **Security & Compliance:** [e.g., KRITIS compliance, least privilege, auditability]
- **Cost & Operations:** [e.g., FinOps impact, operational maintenance burden]
- **Developer Experience:** [e.g., Tooling consistency across teams, learning curve]

## Considered Options

### Option 1: [Name of Option]
- **Description:** [Short summary of how this option works]
- **Pros:** [Positive aspects]
- **Cons / Trade-offs:** [Drawbacks, missing features, friction]

### Option 2: [Name of Option]
- **Description:** [Short summary]
- **Pros:** [Positive aspects]
- **Cons / Trade-offs:** [Drawbacks, missing features, friction]

### Option 3: [Chosen Option Title]
- **Description:** [Short summary]
- **Pros:** [Positive aspects]
- **Cons / Trade-offs:** [Drawbacks]

## Decision Outcome

**Chosen Option:** **Option 3: [Title]**

**Core Justification:** We decide to [chosen option] because [summary justification mapped back to decision drivers].

### Specifics & Boundaries

1. **Mandatory Rule:** [What is enforced going forward]
2. **Legacy / Migration Rule:** [How existing systems or exceptions are handled]
3. **Out of Scope:** [What this decision explicitly does NOT solve or mandate right now]

## Consequences & Trade-Offs

### Positive Impacts
- [Benefit 1 — e.g., unified tooling across all repositories]
- [Benefit 2 — e.g., automated validation via CI]

### Negative Impacts & Mitigations
- **[Drawback 1]:** [Description of friction/cost]
  - **Mitigation:** [Concrete steps to alleviate this pain]
- **[Drawback 2]:** [e.g., Migration effort required for 15 services]
  - **Mitigation:** [e.g., Automated migration script provided in Phase 1]

## Validation & Success Metrics

- **Success Measure:** [e.g., Pipeline runtimes decreased by 20%, zero unauthenticated requests]
- **Review Trigger / Date:** [e.g., Re-evaluate in 6 months (YYYY-MM-DD) or when service load reaches X]

## Rollout & Implementation Plan (Optional)

- [ ] **Phase 1 (Preparation):** [e.g., Provide shared template and update guidelines]
- [ ] **Phase 2 (Pilot):** [e.g., Onboard 2 pilot teams/services]
- [ ] **Phase 3 (Enforcement):** [e.g., Turn on mandatory linting / deprecate old path]

## References & Discussions

- [GitLab MR / Issue / Architecture Discussion](https://git.eon-cds.de/...)
- [External Documentation / RFC / Standard](https://...)
