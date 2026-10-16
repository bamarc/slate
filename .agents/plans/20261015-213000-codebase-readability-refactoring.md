# Plan: Codebase Readability, Modularity & Cleanliness Refactoring

## Context & Goal
Following the `slate` DUB sub-package split (`slate:core`, `slate:net`, `slate:mcp`, `slate:ui`) and MIT licensing, several individual source files remain overly long (>1,300–2,350 lines) due to a monolithic Rust FFI bridge (`slint-d/bridge/src/lib.rs`), large inline test suites at the bottom of D modules, and a 1,754-line QUIC connection struct. Additionally, a few legacy prototype directories (`slate-rust/`, `slate-carbon/`, `agent/`, `Cargo.lock`, empty `lib/`) remain at the repository root.

## EARS Requirements

### Ubiquitous Requirements
- **U1 (File Size Ceiling)**: Every production `.rs` and `.d` source file in `slint-d/` and `slate-dlang/` SHALL contain at most ~1,150 lines of code.
- **U2 (Rust Bridge Modularity & Linting)**: `slint-d/bridge/src/lib.rs` SHALL be decomposed into focused submodules (`error.rs`, `compiler.rs`, `value.rs`, `model.rs`, `instance.rs`, `window.rs`, `accessibility.rs`), and `cargo fmt --check` and `cargo clippy -- -D warnings` SHALL pass with zero warnings or errors.
- **U3 (Idiomatic D Test Separation)**: Heavy unit test suites (>300 lines) SHALL be extracted into sibling `*_test.d` modules, while each production module retains at least one concise inline `// Spec:` + `/// Example:` Ddoc `unittest` block. Every `unittest` block in both production and `*_test.d` modules SHALL include a `// Spec:` (or `// Best practice:`) header and `/// Example:` block.
- **U4 (Zero Behavioral Regression)**: All 9 Dlang test targets (`just d-test`, `just d-test-native`, `just slate-test-core`, `just slate-test-net`, `just slate-test-mcp`, `just slate-test-ui`, `just slate-test-ui-native`, `just slate-test`, `just slate-test-native`) SHALL pass with zero regressions, and `! grep -rn "import slint" slate-dlang/packages/{core,net,mcp}` SHALL continue to return 0 matches.
- **U5 (Root Directory Cleanliness)**: Legacy prototype directories at the repository root (`slate-rust`, `slate-carbon`, `agent`, `Cargo.lock`) SHALL be moved into `reference/`, the empty `lib/` directory removed, `.editorconfig` updated with `[*.{d,slint,rs}]`, `CLAUDE.md` updated for Dlang/Slint, and `Justfile` `lint` wired to check Rust bridge (`cargo fmt --check`, `cargo clippy -- -D warnings`) and Dlang builds.

## Implementation Steps

1. **Step 1: Modularize `slint-d/bridge/src/lib.rs` & Fix All Clippy/Rustfmt Findings**:
   - Split `slint-d/bridge/src/lib.rs` (2,353 lines) into:
     - `src/error.rs`
     - `src/compiler.rs`
     - `src/value.rs`
     - `src/model.rs`
     - `src/instance.rs`
     - `src/window.rs`
     - `src/accessibility.rs`
     - `src/lib.rs` (with `#![allow(clippy::not_unsafe_ptr_arg_deref)]` for C-ABI entrypoints, clean module exports, and any cleanups needed for `cargo clippy -- -D warnings` and `cargo fmt --check`).
   - Rebuild `cd slint-d/bridge && cargo build && cargo fmt --check && cargo clippy -- -D warnings`.

2. **Step 2: Split Large Dlang Modules & Extract Heavy Test Suites into `*_test.d`**:
   - `slint-d/source/slint/model.d` (1,323 lines) -> keep 1 inline `// Spec:` + `/// Example:` unittest in `model.d`, move the remaining unittests to `slint-d/source/slint/model_test.d`.
   - `slint-d/source/slint/instance.d` (1,366 lines) -> keep 1 inline `// Spec:` + `/// Example:` unittest in `instance.d`, move the remaining unittests to `slint-d/source/slint/instance_test.d`.
   - `slate-dlang/packages/mcp/source/slate/agent/model.d` (1,473 lines) -> extract `Point`, `Rect`, `MouseButton`, `ElementSelector`, `ElementRange` into `slate-dlang/packages/mcp/source/slate/agent/geometry.d` (and `public import slate.agent.geometry;` in `slate/agent/model.d`), keep 1 inline `// Spec:` + `/// Example:` unittest in `geometry.d` and `model.d`, and move the remaining test suite into `slate-dlang/packages/mcp/source/slate/agent/model_test.d`.
   - `slate-dlang/packages/net/source/slate/http/client.d` (1,473 lines) -> keep 1 inline `// Spec:` + `/// Example:` unittest in `client.d`, move the remaining test suite to `slate-dlang/packages/net/source/slate/http/client_test.d` (adjusting any needed `private` helpers tested directly to `package` visibility).
   - `slate-dlang/packages/net/source/slate/http/error.d` (1,099 lines) -> keep 1 inline `// Spec:` + `/// Example:` unittest in `error.d`, move the remaining test suite to `slate-dlang/packages/net/source/slate/http/error_test.d`.
   - `slate-dlang/packages/net/source/slate/quic/wire/frame.d` (1,394 lines) -> keep 1 inline `// Spec:` + `/// Example:` unittest in `frame.d`, move the remaining test suite to `slate-dlang/packages/net/source/slate/quic/wire/frame_test.d`.
   - `slate-dlang/packages/net/source/slate/quic/crypto/tls_session.d` (1,118 lines) -> keep 1 inline `// Spec:` + `/// Example:` unittest in `tls_session.d`, move the remaining test suite to `slate-dlang/packages/net/source/slate/quic/crypto/tls_session_test.d`.
   - `slate-dlang/packages/net/source/slate/quic/connection/connection.d` (1,754 lines) & `package.d` (796 lines):
     - Extract outbound packet packing methods (`pollTransmit`, `packInitialPacket`, `packHandshakePacket`, `packOneRttPacket`, `emitClosePacket`) into `mixin template QuicPacketPacker()` in `slate-dlang/packages/net/source/slate/quic/connection/packet_packer.d` and `mixin QuicPacketPacker;` inside `QuicConnection` in `connection.d`.
     - Move the 770 lines of unit tests from `slate-dlang/packages/net/source/slate/quic/connection/package.d` into `slate-dlang/packages/net/source/slate/quic/connection/connection_test.d`, leaving `package.d` as a concise re-export module.

3. **Step 3: Root Directory Cleanup & Tooling Integration**:
   - `git mv slate-rust slate-carbon agent Cargo.lock reference/` and `rm -rf lib`.
   - Update `.editorconfig` with `[*.{d,slint,rs}]`.
   - Update `CLAUDE.md` to document the Dlang + Slint architecture and `just` recipes.
   - Update `Justfile` `lint` recipe to run `cd slint-d/bridge && cargo fmt --check && cargo clippy -- -D warnings` plus Dlang build checks (moving the old Python/React lint to `lint-reference`).
