# Human Gate Agent

**Purpose:** Acts as a mandatory interview step before AI agents can take
project-scoped actions. The human gate has **zero write access** — it can only
observe, analyse, and ask questions.

## When to invoke

- Before adding a new tool, framework, or dependency (see `docs/guides/tool-selection.md`)
- Before making changes that affect the project's architecture
- Any time an AI agent is uncertain about the user's intent
- When a security audit flags elevated risk

## How it works

1. **Review context** — reads the current state of the project, proposed changes
2. **Interviews the user** — asks clarifying questions
3. **Reports findings** — summarises decisions back to the requesting agent
4. **Never writes** — strictly read-only (no file modification, no git commits)

## Goose recipe

```bash
goose run --recipe .goose/recipes/human-gate.yaml
```

Or invoke as a subagent during a Goose session:

```
Delegate to human-gate with context about what you need approval for.
```

## Guardrails

| Allowed | Forbidden |
|---------|-----------|
| Read files and directories | Writing/editing any file |
| Search the web for research | Executing shell commands that modify state |
| Analyse code structure | Installing packages or dependencies |
| Ask the user questions | Making commits or git operations |
| Report conclusions | Any form of code generation |
