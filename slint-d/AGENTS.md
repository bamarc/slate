# AGENTS.md — `slint-d` Slint Bindings & Rust Bridge Instructions

This directory contains **`slint-d`**, the idiomatic Dlang bindings for the [Slint](https://slint.dev) runtime (`v1.18.1`), backed by a modular Rust C-ABI bridge (`bridge/`).

---

## 1. Two-Layer Architecture

1. **Idiomatic D Layer (`source/slint/*.d`)**:
   - `capi.d`: `extern(C)` declarations matching `bridge/src/` FFI exports.
   - `compiler.d` / `definition.d` / `loader.d`: `.slint` compilation, diagnostics (`diagnostics.d`), component metadata introspection, and `validateSpec`.
   - `instance.d` / `window.d`: `ComponentInstance` & `WindowHandle` lifecycle, property get/set, global singletons, callbacks (`callback.d`), and offscreen software snapshots (`png.d`).
   - `value.d`: `Value` / `ValueType` tagged union (`Number`, `String`, `Bool`, `Color`, `Brush`, `Struct`, `Model`, `Image`, `Enumeration`).
   - `model.d`: Reactive `Model!T`, `ArrayModel!T`, `StructModel!T`, `TreeModel!T`, `MapModel`, `FilterModel`, `SortedModel`, `ReverseModel`, and fiber-fed `GeneratorModel!T`.
   - `codegen.d`: Compile-time `SlintProps` and `SlintCallbacks` mixins.
   - `eventloop.d` / `timer.d` / `fiber.d`: Event loop control, native timers, and cooperative `UiTask` D fibers.
2. **Modular Rust C-ABI Bridge (`bridge/src/*.rs` → `libslint_d_bridge.so` / `.a`)**:
   - `lib.rs`: C-ABI module root and shared string/handle utilities.
   - `error.rs`: Error reporting and FFI status codes.
   - `compiler.rs`: `slint_interpreter::Compiler` wrapper.
   - `value.rs`: `slint_interpreter::Value` ↔ C-ABI conversions.
   - `model.rs`: `ModelNotify` and `ModelRc` FFI adapters.
   - `instance.rs`: `ComponentDefinition` and `ComponentInstance` lifecycle, property, global, and callback FFI.
   - `window.rs`: Offscreen software rendering (`MinimalSoftwareWindow`), input event injection, and timers.
   - `accessibility.rs`: Accessibility tree traversal and element queries for MCP automation.

---

## 2. FFI & Memory Safety Rules

- **Strict C-ABI Synchronization**: Every `#[no_mangle] pub extern "C" fn` signature in `bridge/src/*.rs` must match its `extern(C)` declaration in `source/slint/capi.d` byte-for-byte.
- **Deterministic Cleanup (`scope(exit)` / `scope(failure)`)**:
  - Strings allocated by Rust and returned to D must be freed via `slint_string_free` inside a `scope(exit)` guard immediately after copying into D memory.
  - Opaque handles (`ComponentInstance`, `Compiler`, `Timer`, callback IDs) must release their Rust resources deterministically and roll back partial registrations on `scope(failure)`.
- **Dual DUB Configurations (`library` vs `native`)**:
  - `library` (default): Compiles pure-D code without linking `libslint_d_bridge`. Runtime bridge calls throw `NativeUnavailable` when `version (SlintNative)` is not enabled.
  - `native`: Enables `-version=SlintNative` and links `libslint_d_bridge`.
  - Never break the pure-D `library` build when adding native bridge features.

---

## 3. Verification Checklist

Run these checks from the repository root after editing `slint-d/`:

```bash
just d-bridge        # Build Rust C-ABI bridge (slint-d/bridge)
just lint            # Run dscanner + cargo fmt --check + cargo clippy + dub build
just d-test          # Run pure-D unit tests (15 modules)
just d-test-native   # Run native unit tests with SLINT_BACKEND=software
```
