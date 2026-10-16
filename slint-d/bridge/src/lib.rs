// C ABI bridge: slint-interpreter -> slint-d (DLang).
//
// This crate plays the same role for D as `api/node/rust/*` (napi) does for
// JavaScript and `api/python/slint/*.rs` (pyo3) does for Python: it wraps the
// `slint_interpreter` entry points (`Compiler`, `CompilationResult`,
// `ComponentDefinition`, `ComponentInstance`, event-loop functions) behind a
// C-simple ABI declared on the D side in `source/slint/capi.d`.
//
// Ownership rules (mirrored in capi.d):
// - Opaque pointers transfer ownership; free with the matching `_free` fn.
// - A returned `*mut c_char` that is non-null is an owned error string:
//   success is null. Release with `slint_string_free`.
// - Borrowed `*const c_char` getters stay valid while the owner lives.

#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod accessibility;
pub mod compiler;
pub mod error;
pub mod instance;
pub mod model;
pub mod value;
pub mod window;

pub use accessibility::*;
pub use compiler::*;
pub use error::*;
pub use instance::*;
pub use model::*;
pub use value::*;
pub use window::*;
