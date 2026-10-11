# Common brief for handover-document authors

You write work-package (WP) handover documents for an agent team implementing fully dynamic,
semantic MCP support in the Slate Rust/Slint framework at /home/marc/Entwicklung/slate.
Implementers are LOW-CAPABILITY (haiku-level): literal-minded, they take shortcuts (mocks,
`#[ignore]`, weakened assertions, hardcoding) unless forbidden, and cannot fill gaps. Docs must be
fully explicit: exact file paths, exact Rust signatures, full Red-step test code (or a skeleton with
every assertion spelled out), algorithms as numbered sub-steps, exact commands with expected output,
concrete STOP conditions.

## Read first (in order)
1. `.agents/plans/20261011-162725-dynamic-mcp-capabilities.md` (plan rev 3; D1 amendment: the semantic core walks raw `i_slint_core` `ItemRc`, NOT `ElementHandle`, because `ElementHandle` needs debug info).
2. `.agents/plans/20261011-162725-dynamic-mcp-capabilities/00-meta-implementation-plan.md`
3. `.agents/plans/20261011-162725-dynamic-mcp-capabilities/context/03-shared-contracts.md` — SINGLE SOURCE OF TRUTH. Every name/type/signature/error code/tool schema/file ownership must match it exactly.
4. `.agents/plans/20261011-162725-dynamic-mcp-capabilities/context/04-wp-template.md` — MANDATORY WP structure.
5. Verify every API fact yourself against real sources: `slate-rust/`, `ui/`, `slate-carbon/`, `Justfile`, and crate sources under `~/.cargo/registry/src/*/` (i-slint-core-1.18.1, i-slint-backend-testing-1.18.1, i-slint-common-1.18.1, i-slint-compiler-1.18.1, slint-1.18.1). Never guess; write UNVERIFIED if you cannot verify.

## Rules
- Do NOT modify source code, the plan, the contracts, or the meta plan. Only create your assigned files.
- WP files go to `.agents/plans/20261011-162725-dynamic-mcp-capabilities/handover/WP-xx-<kebab-title>.md`.
- Zero-mock policy: no mock/fake/simulated engines in prod or tests. Tests use a real Slint window via the WP-01 harness (contracts §8) and real JSON-RPC over real transports.
- Every behavior step is Red -> Green -> Iterate.
- Gates use `just` recipes (`just check`, `just test`, `just fmt`, `just optical-check`; confirm the working dir in the Justfile) and `cargo test -p <crate> --test <stem>` from `slate-rust/` for single files.
- If a contract is wrong or unworkable (verify with evidence), do NOT silently deviate: write the WP against the contract and add a marked `CONTRACT ISSUE` section at the top (problem, evidence file:line, proposed fix); list it in your final reply.
- Write each file as soon as it is done (do not batch to the end), so partial progress survives interruptions.
- Final reply: files written, size estimates, all CONTRACT ISSUEs, cross-WP dependencies the meta plan lacks.
