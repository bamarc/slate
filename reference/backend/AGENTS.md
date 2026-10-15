# Backend Agent Instructions

All backend behavior changes must be developed using test-driven development
(TDD) with the Red, Green, Iterate loop described in
`../.agents/skills/test-driven-development/SKILL.md`.

1. Write or update a focused failing test that specifies the required behavior.
2. Run the relevant test and confirm it fails for the expected reason (red).
3. Implement the smallest production change that makes the test pass.
4. Run the relevant test and confirm it passes (green).
5. Iterate with additional useful tests and refactor only while the tests
   remain green.

Do not implement backend behavior before its corresponding test exists, except
for narrowly necessary test infrastructure. Backend code must remain fully
testable with useful behavior-focused tests. Run the relevant backend test
subset during development and the complete backend suite before considering
the work complete.

Run the complete backend test suite with:

```sh
uv run pytest --no-cov
```
