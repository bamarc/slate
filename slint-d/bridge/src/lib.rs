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

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_double, c_int, c_void};
use std::path::PathBuf;
use std::rc::Rc;

use i_slint_core::model::{Model, ModelRc, VecModel};
use slint_interpreter::{ComponentHandle, DiagnosticLevel};

fn read_str(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    // SAFETY: contract requires a valid NUL-terminated UTF-8 string.
    unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() }
}

fn ok_or_error<T, E: ToString>(r: Result<T, E>) -> *mut c_char {
    match r {
        Ok(_) => std::ptr::null_mut(),
        Err(e) => CString::new(e.to_string()).map(|s| s.into_raw()).unwrap_or_else(|_| {
            CString::new("error text was not representable").unwrap().into_raw()
        }),
    }
}

fn error_owned(msg: impl Into<String>) -> *mut c_char {
    CString::new(msg.into()).map(|s| s.into_raw()).unwrap_or_else(|_| {
        CString::new("error text was not representable").unwrap().into_raw()
    })
}

// -- compiler -----------------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_compiler_new() -> *mut slint_interpreter::Compiler {
    Box::into_raw(Box::new(slint_interpreter::Compiler::default()))
}

#[no_mangle]
pub extern "C" fn slint_compiler_free(compiler: *mut slint_interpreter::Compiler) {
    if !compiler.is_null() {
        // SAFETY: pointer came from `slint_compiler_new`.
        unsafe {
            drop(Box::from_raw(compiler));
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_compiler_set_style(
    compiler: *mut slint_interpreter::Compiler,
    style: *const c_char,
) {
    if compiler.is_null() {
        return;
    }
    // SAFETY: pointer came from `slint_compiler_new`.
    let compiler = unsafe { &mut *compiler };
    compiler.set_style(read_str(style));
}

#[no_mangle]
pub extern "C" fn slint_compiler_add_include_path(
    compiler: *mut slint_interpreter::Compiler,
    path: *const c_char,
) {
    if compiler.is_null() {
        return;
    }
    // SAFETY: pointer came from `slint_compiler_new`.
    let compiler = unsafe { &mut *compiler };
    let mut paths = compiler.include_paths().clone();
    paths.push(PathBuf::from(read_str(path)));
    compiler.set_include_paths(paths);
}

#[no_mangle]
pub extern "C" fn slint_compiler_set_translation_domain(
    compiler: *mut slint_interpreter::Compiler,
    domain: *const c_char,
) {
    if compiler.is_null() {
        return;
    }
    // SAFETY: pointer came from `slint_compiler_new`.
    let compiler = unsafe { &mut *compiler };
    compiler.set_translation_domain(read_str(domain));
}

struct OwnedDiagnostic {
    level: c_int,
    message: CString,
    line: usize,
    column: usize,
}

pub struct SlintResult {
    diagnostics: Vec<OwnedDiagnostic>,
    components: Vec<CString>,
    inner: slint_interpreter::CompilationResult,
}

fn level_to_int(level: DiagnosticLevel) -> c_int {
    match level {
        DiagnosticLevel::Error => 0,
        DiagnosticLevel::Warning => 1,
        _ => 2,
    }
}

fn wrap_result(inner: slint_interpreter::CompilationResult) -> *mut SlintResult {
    let diagnostics = inner
        .diagnostics()
        .map(|d| {
            let (line, column) = d.line_column();
            OwnedDiagnostic {
                level: level_to_int(d.level()),
                message: CString::new(d.message()).unwrap_or_else(|_| {
                    CString::new("<non-utf8 diagnostic>").unwrap()
                }),
                line,
                column,
            }
        })
        .collect();
    let components = inner
        .component_names()
        .map(|n| CString::new(n).unwrap_or_else(|_| CString::new("<bad-name>").unwrap()))
        .collect();
    Box::into_raw(Box::new(SlintResult {
        diagnostics,
        components,
        inner,
    }))
}

#[no_mangle]
pub extern "C" fn slint_compiler_build_from_source(
    compiler: *mut slint_interpreter::Compiler,
    source: *const c_char,
    path: *const c_char,
    out_result: *mut *mut SlintResult,
) -> *mut c_char {
    if compiler.is_null() || out_result.is_null() {
        return error_owned("null compiler or out-result pointer");
    }
    let source = read_str(source);
    let path = PathBuf::from(read_str(path));
    // SAFETY: pointers checked above; compiler came from `slint_compiler_new`.
    let result = {
        let compiler = unsafe { &*compiler };
        spin_on::spin_on(compiler.build_from_source(source, path))
    };
    unsafe {
        *out_result = wrap_result(result);
    }
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_compiler_build_from_path(
    compiler: *mut slint_interpreter::Compiler,
    path: *const c_char,
    out_result: *mut *mut SlintResult,
) -> *mut c_char {
    if compiler.is_null() || out_result.is_null() {
        return error_owned("null compiler or out-result pointer");
    }
    let path = PathBuf::from(read_str(path));
    // SAFETY: pointers checked above; compiler came from `slint_compiler_new`.
    let result = {
        let compiler = unsafe { &*compiler };
        spin_on::spin_on(compiler.build_from_path(&path))
    };
    unsafe {
        *out_result = wrap_result(result);
    }
    std::ptr::null_mut()
}

// -- compilation result -------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_result_free(result: *mut SlintResult) {
    if !result.is_null() {
        // SAFETY: pointer came from a `build_from_*` call.
        unsafe {
            drop(Box::from_raw(result));
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_result_diagnostic_count(result: *const SlintResult) -> usize {
    if result.is_null() {
        return 0;
    }
    // SAFETY: pointer came from a `build_from_*` call.
    let result = unsafe { &*result };
    result.diagnostics.len()
}

#[no_mangle]
pub extern "C" fn slint_result_diagnostic_level(result: *const SlintResult, index: usize) -> c_int {
    if result.is_null() {
        return 0;
    }
    // SAFETY: pointer came from a `build_from_*` call.
    let result = unsafe { &*result };
    result.diagnostics.get(index).map(|d| d.level).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn slint_result_diagnostic_message(
    result: *const SlintResult,
    index: usize,
) -> *const c_char {
    if result.is_null() {
        return std::ptr::null();
    }
    // SAFETY: pointer came from a `build_from_*` call; the CString lives as
    // long as the result object.
    let result = unsafe { &*result };
    result
        .diagnostics
        .get(index)
        .map(|d| d.message.as_ptr())
        .unwrap_or_else(std::ptr::null)
}

#[no_mangle]
pub extern "C" fn slint_result_diagnostic_line(result: *const SlintResult, index: usize) -> usize {
    if result.is_null() {
        return 0;
    }
    // SAFETY: pointer came from a `build_from_*` call.
    let result = unsafe { &*result };
    result.diagnostics.get(index).map(|d| d.line).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn slint_result_diagnostic_column(
    result: *const SlintResult,
    index: usize,
) -> usize {
    if result.is_null() {
        return 0;
    }
    // SAFETY: pointer came from a `build_from_*` call.
    let result = unsafe { &*result };
    result.diagnostics.get(index).map(|d| d.column).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn slint_result_component_count(result: *const SlintResult) -> usize {
    if result.is_null() {
        return 0;
    }
    // SAFETY: pointer came from a `build_from_*` call.
    let result = unsafe { &*result };
    result.components.len()
}

#[no_mangle]
pub extern "C" fn slint_result_component_name(
    result: *const SlintResult,
    index: usize,
) -> *const c_char {
    if result.is_null() {
        return std::ptr::null();
    }
    // SAFETY: pointer came from a `build_from_*` call; the CString lives as
    // long as the result object.
    let result = unsafe { &*result };
    result
        .components
        .get(index)
        .map(|n| n.as_ptr())
        .unwrap_or_else(std::ptr::null)
}

#[no_mangle]
pub extern "C" fn slint_result_component_get(
    result: *mut SlintResult,
    name: *const c_char,
) -> *mut slint_interpreter::ComponentDefinition {
    if result.is_null() {
        return std::ptr::null_mut();
    }
    let name = read_str(name);
    // SAFETY: pointer came from a `build_from_*` call.
    let result = unsafe { &mut *result };
    let def = result.inner.component(&name);
    match def {
        Some(d) => Box::into_raw(Box::new(d)),
        None => std::ptr::null_mut(),
    }
}

// -- component definition -----------------------------------------------

#[no_mangle]
pub extern "C" fn slint_definition_free(def: *mut slint_interpreter::ComponentDefinition) {
    if !def.is_null() {
        // SAFETY: pointer came from `slint_result_component_get`.
        unsafe {
            drop(Box::from_raw(def));
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_create(
    def: *mut slint_interpreter::ComponentDefinition,
) -> *mut slint_interpreter::ComponentInstance {
    if def.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: pointer came from `slint_result_component_get`.
    let def = unsafe { &*def };
    let instance = def.create();
    match instance {
        Ok(i) => Box::into_raw(Box::new(i)),
        Err(_) => std::ptr::null_mut(),
    }
}

// -- component instance -------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_instance_free(instance: *mut slint_interpreter::ComponentInstance) {
    if !instance.is_null() {
        // SAFETY: pointer came from `slint_definition_create`.
        unsafe {
            drop(Box::from_raw(instance));
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_set_number(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    value: c_double,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let name = read_str(name);
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &mut *instance };
    let r = instance.set_property(&name, slint_interpreter::Value::Number(value));
    ok_or_error(r)
}

#[no_mangle]
pub extern "C" fn slint_instance_set_string(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    value: *const c_char,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let name = read_str(name);
    let value = read_str(value);
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &mut *instance };
    let r = instance.set_property(
        &name,
        slint_interpreter::Value::String(value.as_str().into()),
    );
    ok_or_error(r)
}

#[no_mangle]
pub extern "C" fn slint_instance_set_bool(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    value: c_int,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let name = read_str(name);
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &mut *instance };
    let r = instance.set_property(&name, slint_interpreter::Value::Bool(value != 0));
    ok_or_error(r)
}

#[no_mangle]
pub extern "C" fn slint_instance_get_number(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    out_value: *mut c_double,
) -> *mut c_char {
    if instance.is_null() || out_value.is_null() {
        return error_owned("null instance or out pointer");
    }
    let name = read_str(name);
    // SAFETY: pointers checked above; instance came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    let r = instance.get_property(&name);
    match r {
        Ok(slint_interpreter::Value::Number(v)) => {
            unsafe {
                *out_value = v;
            }
            std::ptr::null_mut()
        }
        Ok(other) => error_owned(format!("property '{name}' is not a number ({other:?})")),
        Err(e) => error_owned(e.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_get_string(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    out_value: *mut *mut c_char,
) -> *mut c_char {
    if instance.is_null() || out_value.is_null() {
        return error_owned("null instance or out pointer");
    }
    let name = read_str(name);
    // SAFETY: pointers checked above; instance came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    let r = instance.get_property(&name);
    match r {
        Ok(slint_interpreter::Value::String(s)) => {
            let owned =
                CString::new(s.as_str()).unwrap_or_else(|_| CString::new("").unwrap());
            unsafe {
                *out_value = owned.into_raw();
            }
            std::ptr::null_mut()
        }
        Ok(other) => error_owned(format!("property '{name}' is not a string ({other:?})")),
        Err(e) => error_owned(e.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_get_bool(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    out_value: *mut c_int,
) -> *mut c_char {
    if instance.is_null() || out_value.is_null() {
        return error_owned("null instance or out pointer");
    }
    let name = read_str(name);
    // SAFETY: pointers checked above; instance came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    let r = instance.get_property(&name);
    match r {
        Ok(slint_interpreter::Value::Bool(b)) => {
            unsafe {
                *out_value = if b { 1 } else { 0 };
            }
            std::ptr::null_mut()
        }
        Ok(other) => error_owned(format!("property '{name}' is not a bool ({other:?})")),
        Err(e) => error_owned(e.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_get_property(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    out_value: *mut SlintValue,
) -> *mut c_char {
    if instance.is_null() || out_value.is_null() {
        return error_owned("null instance or out pointer");
    }
    let name = read_str(name);
    // SAFETY: pointers checked above; instance came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    match instance.get_property(&name) {
        Ok(v) => {
            unsafe {
                *out_value = value_to_c_owned(&v);
            }
            std::ptr::null_mut()
        }
        Err(e) => error_owned(e.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_set_property(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    value: *const SlintValue,
) -> *mut c_char {
    if instance.is_null() || value.is_null() {
        return error_owned("null instance or value pointer");
    }
    let name = read_str(name);
    // SAFETY: pointers checked above; instance came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    let mut val = unsafe { c_to_value(&*value) };
    if let slint_interpreter::Value::EnumerationValue(ref enum_name, ref variant) = val {
        if enum_name.is_empty() {
            if let Ok(slint_interpreter::Value::EnumerationValue(target_enum, _)) =
                instance.get_property(&name)
            {
                val = slint_interpreter::Value::EnumerationValue(target_enum, variant.clone());
            }
        }
    }
    let r = instance.set_property(&name, val);
    ok_or_error(r)
}

#[no_mangle]
pub extern "C" fn slint_instance_invoke(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let name = read_str(name);
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    let r = instance.invoke(&name, &[]);
    ok_or_error(r.map(|_| ()))
}

#[no_mangle]
pub extern "C" fn slint_instance_show(instance: *mut slint_interpreter::ComponentInstance) {
    if instance.is_null() {
        return;
    }
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    instance.show().ok();
}

#[no_mangle]
pub extern "C" fn slint_instance_hide(instance: *mut slint_interpreter::ComponentInstance) {
    if instance.is_null() {
        return;
    }
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    instance.hide().ok();
}

static EVENT_LOOP_ACTIVE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

struct EventLoopGuard;
impl EventLoopGuard {
    fn enter() -> Self {
        EVENT_LOOP_ACTIVE.store(true, std::sync::atomic::Ordering::SeqCst);
        EventLoopGuard
    }
}
impl Drop for EventLoopGuard {
    fn drop(&mut self) {
        EVENT_LOOP_ACTIVE.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_run(
    instance: *mut slint_interpreter::ComponentInstance,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let _guard = EventLoopGuard::enter();
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    let r = instance.run();
    ok_or_error(r)
}

// -- event loop ---------------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_run_event_loop() -> *mut c_char {
    let _guard = EventLoopGuard::enter();
    ok_or_error(slint_interpreter::run_event_loop())
}

#[no_mangle]
pub extern "C" fn slint_quit_event_loop() -> *mut c_char {
    ok_or_error(slint_interpreter::quit_event_loop())
}

// -- strings ------------------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: pointer came from this crate as an owned CString.
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

fn out_string(text: &str) -> *mut c_char {
    CString::new(text)
        .unwrap_or_else(|_| CString::new("<non-utf8>").unwrap())
        .into_raw()
}

// -- dynamically-typed values -------------------------------------------
// Mirrors `slint.capi.SlintValue` field for field. Tags match
// `slint_interpreter::ValueType` ordinals used by the D `ValueType` enum.

#[repr(C)]
#[derive(Default)]
pub struct SlintValue {
    pub tag: c_int,
    pub number: c_double,
    pub text_ptr: *const c_char,
    pub text_len: usize,
    pub boolean: c_int,
    pub color_argb: u32,
    pub brush_kind: c_int,
    pub handle: *mut c_void,
    pub owned: c_int,
}

/// D-side handler entry point (`slintDCallbackShim` in `slint.callback`).
/// `Option` so a null pointer is a checked error instead of UB.
pub type SlintShim = Option<extern "C" fn(usize, *const SlintValue, usize) -> SlintValue>;

/// Borrowed view of an interpreter value (strings borrow the caller).
fn value_to_c(value: &slint_interpreter::Value) -> SlintValue {
    match value {
        slint_interpreter::Value::Number(n) => SlintValue {
            tag: 1,
            number: *n,
            ..Default::default()
        },
        slint_interpreter::Value::String(s) => SlintValue {
            tag: 2,
            text_ptr: s.as_str().as_ptr() as *const c_char,
            text_len: s.as_str().len(),
            ..Default::default()
        },
        slint_interpreter::Value::Bool(b) => SlintValue {
            tag: 3,
            boolean: if *b { 1 } else { 0 },
            ..Default::default()
        },
        slint_interpreter::Value::Model(m) => SlintValue {
            tag: 4,
            handle: Box::into_raw(Box::new(m.clone())) as *mut c_void,
            owned: 1,
            ..Default::default()
        },
        slint_interpreter::Value::Struct(s) => SlintValue {
            tag: 5,
            handle: Box::into_raw(Box::new(s.clone())) as *mut c_void,
            owned: 1,
            ..Default::default()
        },
        slint_interpreter::Value::Brush(b) => match b {
            slint_interpreter::Brush::SolidColor(c) => {
                let col: i_slint_core::graphics::RgbaColor<u8> = (*c).into();
                let argb = ((col.alpha as u32) << 24)
                    | ((col.red as u32) << 16)
                    | ((col.green as u32) << 8)
                    | (col.blue as u32);
                let brush_kind = if col.alpha == 0 { 0 } else { 1 };
                SlintValue {
                    tag: 6,
                    color_argb: argb,
                    brush_kind,
                    ..Default::default()
                }
            }
            _ => SlintValue {
                tag: 6,
                brush_kind: 0,
                color_argb: 0,
                ..Default::default()
            },
        },
        slint_interpreter::Value::EnumerationValue(_enum_name, val) => SlintValue {
            tag: 8,
            text_ptr: val.as_ptr() as *const c_char,
            text_len: val.len(),
            ..Default::default()
        },
        _ => SlintValue::default(),
    }
}

/// Owned copy of an interpreter value for returns (strings heap-allocated
/// with `owned` set; D releases them with `slint_value_free`).
fn value_to_c_owned(value: &slint_interpreter::Value) -> SlintValue {
    match value {
        slint_interpreter::Value::String(s) => {
            let text = s.as_str();
            let raw = CString::new(text).unwrap_or_else(|_| CString::new("").unwrap());
            SlintValue {
                tag: 2,
                text_ptr: raw.into_raw() as *const c_char,
                text_len: text.len(),
                owned: 1,
                ..Default::default()
            }
        }
        slint_interpreter::Value::EnumerationValue(_enum_name, val) => {
            let raw = CString::new(val.as_str()).unwrap_or_else(|_| CString::new("").unwrap());
            SlintValue {
                tag: 8,
                text_ptr: raw.into_raw() as *const c_char,
                text_len: val.len(),
                owned: 1,
                ..Default::default()
            }
        }
        other => value_to_c(other),
    }
}

/// Copy an FFI payload into an interpreter value (strings are copied, so
/// borrowed D memory is safe).
fn c_to_value(sv: &SlintValue) -> slint_interpreter::Value {
    match sv.tag {
        1 => slint_interpreter::Value::Number(sv.number),
        2 => {
            if !sv.text_ptr.is_null() && sv.text_len > 0 {
                // SAFETY: contract guarantees `text_len` readable bytes.
                let bytes =
                    unsafe { std::slice::from_raw_parts(sv.text_ptr as *const u8, sv.text_len) };
                slint_interpreter::Value::String(
                    String::from_utf8_lossy(bytes).into_owned().as_str().into(),
                )
            } else {
                slint_interpreter::Value::String("".into())
            }
        }
        3 => slint_interpreter::Value::Bool(sv.boolean != 0),
        4 => {
            if !sv.handle.is_null() {
                // SAFETY: handle came from slint_model_new_vec or value_to_c.
                let m = unsafe { &*(sv.handle as *const ModelRc<slint_interpreter::Value>) };
                slint_interpreter::Value::Model(m.clone())
            } else {
                slint_interpreter::Value::Model(ModelRc::default())
            }
        }
        5 => {
            if !sv.handle.is_null() {
                // SAFETY: handle came from slint_struct_new or value_to_c.
                let s = unsafe { &*(sv.handle as *const slint_interpreter::Struct) };
                slint_interpreter::Value::Struct(s.clone())
            } else {
                slint_interpreter::Value::Struct(slint_interpreter::Struct::default())
            }
        }
        6 => {
            if sv.brush_kind == 0 {
                slint_interpreter::Value::Brush(slint_interpreter::Brush::SolidColor(
                    slint_interpreter::Color::from(i_slint_core::graphics::RgbaColor {
                        red: 0,
                        green: 0,
                        blue: 0,
                        alpha: 0,
                    }),
                ))
            } else {
                let a = (sv.color_argb >> 24) as u8;
                let r = (sv.color_argb >> 16) as u8;
                let g = (sv.color_argb >> 8) as u8;
                let b = sv.color_argb as u8;
                slint_interpreter::Value::Brush(slint_interpreter::Brush::SolidColor(
                    slint_interpreter::Color::from(i_slint_core::graphics::RgbaColor {
                        red: r,
                        green: g,
                        blue: b,
                        alpha: a,
                    }),
                ))
            }
        }
        8 if !sv.text_ptr.is_null() => {
            let bytes =
                unsafe { std::slice::from_raw_parts(sv.text_ptr as *const u8, sv.text_len) };
            let val = String::from_utf8_lossy(bytes).into_owned();
            slint_interpreter::Value::EnumerationValue(String::new(), val)
        }
        _ => slint_interpreter::Value::Void,
    }
}

#[no_mangle]
pub extern "C" fn slint_value_free(value: *mut SlintValue) {
    if value.is_null() {
        return;
    }
    // SAFETY: pointer refers to a SlintValue produced by this crate.
    let value = unsafe { &mut *value };
    if value.owned != 0 {
        if !value.text_ptr.is_null() {
            // SAFETY: an owned payload is a CString created by this crate.
            unsafe {
                drop(CString::from_raw(value.text_ptr as *mut c_char));
            }
            value.text_ptr = std::ptr::null();
            value.text_len = 0;
        }
        if !value.handle.is_null() {
            if value.tag == 4 {
                // SAFETY: Model handle allocated via Box::into_raw
                unsafe {
                    drop(Box::from_raw(value.handle as *mut ModelRc<slint_interpreter::Value>));
                }
            } else if value.tag == 5 {
                // SAFETY: Struct handle allocated via Box::into_raw
                unsafe {
                    drop(Box::from_raw(value.handle as *mut slint_interpreter::Struct));
                }
            }
            value.handle = std::ptr::null_mut();
        }
        value.owned = 0;
    }
}

// -- struct manipulation ------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_struct_new() -> *mut slint_interpreter::Struct {
    Box::into_raw(Box::new(slint_interpreter::Struct::default()))
}

#[no_mangle]
pub extern "C" fn slint_struct_free(s: *mut slint_interpreter::Struct) {
    if !s.is_null() {
        unsafe {
            drop(Box::from_raw(s));
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_struct_set_field(
    s: *mut slint_interpreter::Struct,
    name: *const c_char,
    value: *const SlintValue,
) -> *mut c_char {
    if s.is_null() || value.is_null() {
        return error_owned("null struct or value pointer");
    }
    let name = read_str(name);
    let s = unsafe { &mut *s };
    let val = unsafe { c_to_value(&*value) };
    s.set_field(name, val);
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_struct_get_field(
    s: *mut slint_interpreter::Struct,
    name: *const c_char,
    out_value: *mut SlintValue,
) -> *mut c_char {
    if s.is_null() || out_value.is_null() {
        return error_owned("null struct or out_value pointer");
    }
    let name = read_str(name);
    let s = unsafe { &*s };
    if let Some(v) = s.get_field(&name) {
        unsafe {
            *out_value = value_to_c_owned(v);
        }
        std::ptr::null_mut()
    } else {
        error_owned(format!("field '{name}' not found in struct"))
    }
}

#[no_mangle]
pub extern "C" fn slint_struct_field_count(s: *mut slint_interpreter::Struct) -> usize {
    if s.is_null() {
        return 0;
    }
    let s = unsafe { &*s };
    s.iter().count()
}

#[no_mangle]
pub extern "C" fn slint_struct_field_name(
    s: *mut slint_interpreter::Struct,
    index: usize,
    out_name: *mut *mut c_char,
) -> *mut c_char {
    if s.is_null() || out_name.is_null() {
        return error_owned("null struct or out_name pointer");
    }
    let s = unsafe { &*s };
    if let Some((name, _)) = s.iter().nth(index) {
        unsafe {
            *out_name = out_string(name);
        }
        std::ptr::null_mut()
    } else {
        error_owned("struct field index out of range")
    }
}

// -- model manipulation -------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_model_new_vec() -> *mut ModelRc<slint_interpreter::Value> {
    let vec_model = Rc::new(VecModel::<slint_interpreter::Value>::default());
    let model_rc = ModelRc::from(vec_model);
    Box::into_raw(Box::new(model_rc))
}

#[no_mangle]
pub extern "C" fn slint_model_free(model: *mut ModelRc<slint_interpreter::Value>) {
    if !model.is_null() {
        unsafe {
            drop(Box::from_raw(model));
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_model_row_count(model: *mut ModelRc<slint_interpreter::Value>) -> usize {
    if model.is_null() {
        return 0;
    }
    let m = unsafe { &*model };
    m.row_count()
}

#[no_mangle]
pub extern "C" fn slint_model_row_data(
    model: *mut ModelRc<slint_interpreter::Value>,
    row: usize,
    out_value: *mut SlintValue,
) -> *mut c_char {
    if model.is_null() || out_value.is_null() {
        return error_owned("null model or out_value pointer");
    }
    let m = unsafe { &*model };
    if let Some(val) = m.row_data(row) {
        unsafe {
            *out_value = value_to_c_owned(&val);
        }
        std::ptr::null_mut()
    } else {
        error_owned(format!("row {} out of range", row))
    }
}

#[no_mangle]
pub extern "C" fn slint_model_set_row_data(
    model: *mut ModelRc<slint_interpreter::Value>,
    row: usize,
    value: *const SlintValue,
) -> *mut c_char {
    if model.is_null() || value.is_null() {
        return error_owned("null model or value pointer");
    }
    let m = unsafe { &*model };
    let val = unsafe { c_to_value(&*value) };
    m.set_row_data(row, val);
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_model_vec_push(
    model: *mut ModelRc<slint_interpreter::Value>,
    value: *const SlintValue,
) -> *mut c_char {
    if model.is_null() || value.is_null() {
        return error_owned("null model or value pointer");
    }
    let m = unsafe { &*model };
    let val = unsafe { c_to_value(&*value) };
    if let Some(vec_model) = m.as_any().downcast_ref::<VecModel<slint_interpreter::Value>>() {
        vec_model.push(val);
        std::ptr::null_mut()
    } else {
        match m.push_row(val) {
            Ok(()) => std::ptr::null_mut(),
            Err(e) => error_owned(format!("failed to push row to model: {:?}", e)),
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_model_vec_remove(
    model: *mut ModelRc<slint_interpreter::Value>,
    index: usize,
) -> *mut c_char {
    if model.is_null() {
        return error_owned("null model pointer");
    }
    let m = unsafe { &*model };
    if let Some(vec_model) = m.as_any().downcast_ref::<VecModel<slint_interpreter::Value>>() {
        if index >= vec_model.row_count() {
            return error_owned(format!("index {} out of bounds for remove", index));
        }
        vec_model.remove(index);
        std::ptr::null_mut()
    } else {
        match m.remove_row(index) {
            Ok(()) => std::ptr::null_mut(),
            Err(e) => error_owned(format!("failed to remove row from model: {:?}", e)),
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_model_vec_clear(
    model: *mut ModelRc<slint_interpreter::Value>,
) -> *mut c_char {
    if model.is_null() {
        return error_owned("null model pointer");
    }
    let m = unsafe { &*model };
    if let Some(vec_model) = m.as_any().downcast_ref::<VecModel<slint_interpreter::Value>>() {
        vec_model.set_vec(Vec::new());
        std::ptr::null_mut()
    } else {
        while m.row_count() > 0 {
            if let Err(e) = m.remove_row(0) {
                return error_owned(format!("failed to clear model: {:?}", e));
            }
        }
        std::ptr::null_mut()
    }
}



// -- definition introspection -------------------------------------------
// Each name getter writes a fresh owned string (`slint_string_free`), so no
// lifetimes escape even though the underlying iterators are transient.

fn definition_ref(def: *mut slint_interpreter::ComponentDefinition) -> Option<&'static mut slint_interpreter::ComponentDefinition> {
    if def.is_null() {
        None
    } else {
        // SAFETY: pointer came from `slint_result_component_get`. The
        // reference must not outlive the caller's handle discipline; every
        // use below is synchronous within one extern call.
        Some(unsafe { &mut *def })
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_get_name(
    def: *mut slint_interpreter::ComponentDefinition,
    out_name: *mut *mut c_char,
) -> *mut c_char {
    if out_name.is_null() {
        return error_owned("null out pointer");
    }
    let Some(def) = definition_ref(def) else {
        return error_owned("null definition");
    };
    // SAFETY: out pointer checked above.
    unsafe {
        *out_name = out_string(def.name());
    }
    std::ptr::null_mut()
}

fn snapshot_names(names: Vec<String>, index: usize, out: *mut *mut c_char) -> *mut c_char {
    if out.is_null() {
        return error_owned("null out pointer");
    }
    match names.into_iter().nth(index) {
        // SAFETY: out pointer checked above.
        Some(n) => unsafe {
            *out = out_string(&n);
            std::ptr::null_mut()
        },
        None => error_owned("member index out of range"),
    }
}

fn value_type_tag(t: &slint_interpreter::ValueType) -> c_int {
    match t {
        slint_interpreter::ValueType::Number => 1,
        slint_interpreter::ValueType::String => 2,
        slint_interpreter::ValueType::Bool => 3,
        slint_interpreter::ValueType::Model => 4,
        slint_interpreter::ValueType::Struct => 5,
        slint_interpreter::ValueType::Brush => 6,
        slint_interpreter::ValueType::Image => 7,
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_property_count(
    def: *mut slint_interpreter::ComponentDefinition,
) -> usize {
    match definition_ref(def) {
        Some(def) => def.properties().count(),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_property_name(
    def: *mut slint_interpreter::ComponentDefinition,
    index: usize,
    out_name: *mut *mut c_char,
) -> *mut c_char {
    let Some(def) = definition_ref(def) else {
        return error_owned("null definition");
    };
    snapshot_names(def.properties().map(|(n, _)| n).collect(), index, out_name)
}

#[no_mangle]
pub extern "C" fn slint_definition_property_type(
    def: *mut slint_interpreter::ComponentDefinition,
    index: usize,
) -> c_int {
    match definition_ref(def) {
        Some(def) => def
            .properties()
            .nth(index)
            .map(|(_, t)| value_type_tag(&t))
            .unwrap_or(0),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_callback_count(
    def: *mut slint_interpreter::ComponentDefinition,
) -> usize {
    match definition_ref(def) {
        Some(def) => def.callbacks().count(),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_callback_name(
    def: *mut slint_interpreter::ComponentDefinition,
    index: usize,
    out_name: *mut *mut c_char,
) -> *mut c_char {
    let Some(def) = definition_ref(def) else {
        return error_owned("null definition");
    };
    snapshot_names(def.callbacks().collect(), index, out_name)
}

#[no_mangle]
pub extern "C" fn slint_definition_function_count(
    def: *mut slint_interpreter::ComponentDefinition,
) -> usize {
    match definition_ref(def) {
        Some(def) => def.functions().count(),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_function_name(
    def: *mut slint_interpreter::ComponentDefinition,
    index: usize,
    out_name: *mut *mut c_char,
) -> *mut c_char {
    let Some(def) = definition_ref(def) else {
        return error_owned("null definition");
    };
    snapshot_names(def.functions().collect(), index, out_name)
}

#[no_mangle]
pub extern "C" fn slint_definition_global_count(
    def: *mut slint_interpreter::ComponentDefinition,
) -> usize {
    match definition_ref(def) {
        Some(def) => def.globals().count(),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_global_name(
    def: *mut slint_interpreter::ComponentDefinition,
    index: usize,
    out_name: *mut *mut c_char,
) -> *mut c_char {
    let Some(def) = definition_ref(def) else {
        return error_owned("null definition");
    };
    snapshot_names(def.globals().collect(), index, out_name)
}

#[no_mangle]
pub extern "C" fn slint_definition_global_property_count(
    def: *mut slint_interpreter::ComponentDefinition,
    global: *const c_char,
) -> usize {
    match definition_ref(def) {
        Some(def) => def
            .global_properties(&read_str(global))
            .map(|it| it.count())
            .unwrap_or(0),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_global_property_name(
    def: *mut slint_interpreter::ComponentDefinition,
    global: *const c_char,
    index: usize,
    out_name: *mut *mut c_char,
) -> *mut c_char {
    let Some(def) = definition_ref(def) else {
        return error_owned("null definition");
    };
    match def.global_properties(&read_str(global)) {
        Some(it) => snapshot_names(it.map(|(n, _)| n).collect(), index, out_name),
        None => error_owned("unknown global"),
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_global_property_type(
    def: *mut slint_interpreter::ComponentDefinition,
    global: *const c_char,
    index: usize,
) -> c_int {
    match definition_ref(def) {
        Some(def) => def
            .global_properties(&read_str(global))
            .and_then(|mut it| it.nth(index))
            .map(|(_, t)| value_type_tag(&t))
            .unwrap_or(0),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_global_callback_count(
    def: *mut slint_interpreter::ComponentDefinition,
    global: *const c_char,
) -> usize {
    match definition_ref(def) {
        Some(def) => def
            .global_callbacks(&read_str(global))
            .map(|it| it.count())
            .unwrap_or(0),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_global_callback_name(
    def: *mut slint_interpreter::ComponentDefinition,
    global: *const c_char,
    index: usize,
    out_name: *mut *mut c_char,
) -> *mut c_char {
    let Some(def) = definition_ref(def) else {
        return error_owned("null definition");
    };
    match def.global_callbacks(&read_str(global)) {
        Some(it) => snapshot_names(it.collect(), index, out_name),
        None => error_owned("unknown global"),
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_global_function_count(
    def: *mut slint_interpreter::ComponentDefinition,
    global: *const c_char,
) -> usize {
    match definition_ref(def) {
        Some(def) => def
            .global_functions(&read_str(global))
            .map(|it| it.count())
            .unwrap_or(0),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn slint_definition_global_function_name(
    def: *mut slint_interpreter::ComponentDefinition,
    global: *const c_char,
    index: usize,
    out_name: *mut *mut c_char,
) -> *mut c_char {
    let Some(def) = definition_ref(def) else {
        return error_owned("null definition");
    };
    match def.global_functions(&read_str(global)) {
        Some(it) => snapshot_names(it.collect(), index, out_name),
        None => error_owned("unknown global"),
    }
}

// -- callbacks and variadic invoke --------------------------------------

#[no_mangle]
pub extern "C" fn slint_instance_invoke_values(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    args: *const SlintValue,
    nargs: usize,
    out_return: *mut SlintValue,
) -> *mut c_char {
    if instance.is_null() || out_return.is_null() {
        return error_owned("null instance or out pointer");
    }
    if nargs > 0 && args.is_null() {
        return error_owned("null args with nonzero count");
    }
    let name = read_str(name);
    // SAFETY: pointers checked above; instance came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    // SAFETY: `args` holds `nargs` readable entries (or nargs is 0).
    let values: Vec<slint_interpreter::Value> = if nargs == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(args, nargs) }
            .iter()
            .map(c_to_value)
            .collect()
    };
    match instance.invoke(&name, &values) {
        // SAFETY: out pointer checked above.
        Ok(ret) => unsafe {
            *out_return = value_to_c_owned(&ret);
            std::ptr::null_mut()
        },
        Err(e) => error_owned(e.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_set_callback(
    instance: *mut slint_interpreter::ComponentInstance,
    name: *const c_char,
    shim: SlintShim,
    ctx: usize,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let Some(shim) = shim else {
        return error_owned("null callback shim");
    };
    let name = read_str(name);
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &mut *instance };
    ok_or_error(instance.set_callback(
        &name,
        move |call_args: &[slint_interpreter::Value]| -> slint_interpreter::Value {
            let c_args: Vec<SlintValue> = call_args.iter().map(value_to_c).collect();
            let mut ret = shim(ctx, c_args.as_ptr(), c_args.len());
            let result = c_to_value(&ret);
            slint_value_free(&mut ret);
            for mut arg in c_args {
                slint_value_free(&mut arg);
            }
            result
        },
    ))
}

// -- globals ------------------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_instance_get_global_number(
    instance: *mut slint_interpreter::ComponentInstance,
    global: *const c_char,
    name: *const c_char,
    out_value: *mut c_double,
) -> *mut c_char {
    if instance.is_null() || out_value.is_null() {
        return error_owned("null instance or out pointer");
    }
    let (global, name) = (read_str(global), read_str(name));
    // SAFETY: pointers checked above.
    let instance = unsafe { &*instance };
    match instance.get_global_property(&global, &name) {
        Ok(slint_interpreter::Value::Number(v)) => {
            // SAFETY: out pointer checked above.
            unsafe {
                *out_value = v;
            }
            std::ptr::null_mut()
        }
        Ok(other) => error_owned(format!("global '{global}' property '{name}' is not a number ({other:?})")),
        Err(e) => error_owned(e.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_set_global_number(
    instance: *mut slint_interpreter::ComponentInstance,
    global: *const c_char,
    name: *const c_char,
    value: c_double,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let (global, name) = (read_str(global), read_str(name));
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &mut *instance };
    ok_or_error(instance.set_global_property(
        &global,
        &name,
        slint_interpreter::Value::Number(value),
    ))
}

#[no_mangle]
pub extern "C" fn slint_instance_get_global_string(
    instance: *mut slint_interpreter::ComponentInstance,
    global: *const c_char,
    name: *const c_char,
    out_value: *mut *mut c_char,
) -> *mut c_char {
    if instance.is_null() || out_value.is_null() {
        return error_owned("null instance or out pointer");
    }
    let (global, name) = (read_str(global), read_str(name));
    // SAFETY: pointers checked above.
    let instance = unsafe { &*instance };
    match instance.get_global_property(&global, &name) {
        Ok(slint_interpreter::Value::String(s)) => {
            let owned = CString::new(s.as_str()).unwrap_or_else(|_| CString::new("").unwrap());
            // SAFETY: out pointer checked above.
            unsafe {
                *out_value = owned.into_raw();
            }
            std::ptr::null_mut()
        }
        Ok(other) => error_owned(format!("global '{global}' property '{name}' is not a string ({other:?})")),
        Err(e) => error_owned(e.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_set_global_string(
    instance: *mut slint_interpreter::ComponentInstance,
    global: *const c_char,
    name: *const c_char,
    value: *const c_char,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let (global, name, value) = (read_str(global), read_str(name), read_str(value));
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &mut *instance };
    ok_or_error(instance.set_global_property(
        &global,
        &name,
        slint_interpreter::Value::String(value.as_str().into()),
    ))
}

#[no_mangle]
pub extern "C" fn slint_instance_get_global_bool(
    instance: *mut slint_interpreter::ComponentInstance,
    global: *const c_char,
    name: *const c_char,
    out_value: *mut c_int,
) -> *mut c_char {
    if instance.is_null() || out_value.is_null() {
        return error_owned("null instance or out pointer");
    }
    let (global, name) = (read_str(global), read_str(name));
    // SAFETY: pointers checked above.
    let instance = unsafe { &*instance };
    match instance.get_global_property(&global, &name) {
        Ok(slint_interpreter::Value::Bool(b)) => {
            // SAFETY: out pointer checked above.
            unsafe {
                *out_value = if b { 1 } else { 0 };
            }
            std::ptr::null_mut()
        }
        Ok(other) => error_owned(format!("global '{global}' property '{name}' is not a bool ({other:?})")),
        Err(e) => error_owned(e.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_set_global_bool(
    instance: *mut slint_interpreter::ComponentInstance,
    global: *const c_char,
    name: *const c_char,
    value: c_int,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let (global, name) = (read_str(global), read_str(name));
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &mut *instance };
    ok_or_error(instance.set_global_property(
        &global,
        &name,
        slint_interpreter::Value::Bool(value != 0),
    ))
}

#[no_mangle]
pub extern "C" fn slint_instance_invoke_global(
    instance: *mut slint_interpreter::ComponentInstance,
    global: *const c_char,
    name: *const c_char,
    args: *const SlintValue,
    nargs: usize,
    out_return: *mut SlintValue,
) -> *mut c_char {
    if instance.is_null() || out_return.is_null() {
        return error_owned("null instance or out pointer");
    }
    if nargs > 0 && args.is_null() {
        return error_owned("null args with nonzero count");
    }
    let (global, name) = (read_str(global), read_str(name));
    // SAFETY: pointers checked above.
    let instance = unsafe { &*instance };
    // SAFETY: `args` holds `nargs` readable entries (or nargs is 0).
    let values: Vec<slint_interpreter::Value> = if nargs == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(args, nargs) }
            .iter()
            .map(c_to_value)
            .collect()
    };
    match instance.invoke_global(&global, &name, &values) {
        // SAFETY: out pointer checked above.
        Ok(ret) => unsafe {
            *out_return = value_to_c_owned(&ret);
            std::ptr::null_mut()
        },
        Err(e) => error_owned(e.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn slint_instance_set_global_callback(
    instance: *mut slint_interpreter::ComponentInstance,
    global: *const c_char,
    name: *const c_char,
    shim: SlintShim,
    ctx: usize,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null instance");
    }
    let Some(shim) = shim else {
        return error_owned("null callback shim");
    };
    let (global, name) = (read_str(global), read_str(name));
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &mut *instance };
    ok_or_error(instance.set_global_callback(
        &global,
        &name,
        move |call_args: &[slint_interpreter::Value]| -> slint_interpreter::Value {
            let c_args: Vec<SlintValue> = call_args.iter().map(value_to_c).collect();
            let mut ret = shim(ctx, c_args.as_ptr(), c_args.len());
            let result = c_to_value(&ret);
            slint_value_free(&mut ret);
            for mut arg in c_args {
                slint_value_free(&mut arg);
            }
            result
        },
    ))
}

// -- library paths ------------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_compiler_set_library_path(
    compiler: *mut slint_interpreter::Compiler,
    name: *const c_char,
    path: *const c_char,
) {
    if compiler.is_null() {
        return;
    }
    // SAFETY: pointer came from `slint_compiler_new`.
    let compiler = unsafe { &mut *compiler };
    let mut paths = compiler.library_paths().clone();
    paths.insert(read_str(name), PathBuf::from(read_str(path)));
    compiler.set_library_paths(paths);
}

// -- timers -------------------------------------------------------------

pub struct SlintTimer {
    inner: i_slint_core::timers::Timer,
}

#[no_mangle]
pub extern "C" fn slint_timer_new() -> *mut SlintTimer {
    Box::into_raw(Box::new(SlintTimer {
        inner: Default::default(),
    }))
}

#[no_mangle]
pub extern "C" fn slint_timer_free(timer: *mut SlintTimer) {
    if !timer.is_null() {
        // SAFETY: pointer came from `slint_timer_new`.
        unsafe {
            drop(Box::from_raw(timer));
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_timer_start(
    timer: *mut SlintTimer,
    single_shot: c_int,
    interval_ms: u64,
    shim: SlintShim,
    ctx: usize,
) -> *mut c_char {
    if timer.is_null() {
        return error_owned("null timer");
    }
    let Some(shim) = shim else {
        return error_owned("null timer shim");
    };
    // SAFETY: pointer came from `slint_timer_new`.
    let timer = unsafe { &*timer };
    let mode = if single_shot != 0 {
        i_slint_core::timers::TimerMode::SingleShot
    } else {
        i_slint_core::timers::TimerMode::Repeated
    };
    timer.inner.start(mode, std::time::Duration::from_millis(interval_ms), move || {
        shim(ctx, std::ptr::null(), 0);
    });
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_timer_stop(timer: *mut SlintTimer) {
    if timer.is_null() {
        return;
    }
    // SAFETY: pointer came from `slint_timer_new`.
    let timer = unsafe { &*timer };
    timer.inner.stop();
}

// -- offscreen snapshots ------------------------------------------------
// Same technique as Slate's screenshot tool (`render.rs`): the software
// renderer paints on demand and `take_snapshot` hands back RGBA8 pixels.
// No display server, no event loop needed.

#[no_mangle]
pub extern "C" fn slint_instance_snapshot(
    instance: *mut slint_interpreter::ComponentInstance,
    out_pixels: *mut *mut u8,
    out_len: *mut usize,
    out_width: *mut u32,
    out_height: *mut u32,
) -> *mut c_char {
    if instance.is_null() || out_pixels.is_null() || out_len.is_null()
        || out_width.is_null() || out_height.is_null()
    {
        return error_owned("null snapshot out pointer");
    }
    // SAFETY: pointer came from `slint_definition_create`.
    let instance = unsafe { &*instance };
    let window = instance.window();
    let phys = window.size();
    if phys.width == 0 || phys.height == 0 {
        let mut w = 0.0_f64;
        let mut h = 0.0_f64;
        let _ = slint_window_get_size(
            instance as *const _ as *mut slint_interpreter::ComponentInstance,
            &mut w,
            &mut h,
        );
        let target_w = if w > 0.0 { w as f32 } else { 800.0 };
        let target_h = if h > 0.0 { h as f32 } else { 600.0 };
        window.set_size(slint_interpreter::LogicalSize::new(target_w, target_h));
    }
    let _ = instance.show();
    let pixels = match window.take_snapshot() {
        Ok(p) => p,
        Err(e) => return error_owned(e.to_string()),
    };
    let (w, h) = (pixels.width(), pixels.height());
    let bytes = pixels.as_bytes().to_vec().into_boxed_slice();
    // SAFETY: out pointers checked above.
    unsafe {
        *out_width = w;
        *out_height = h;
        *out_len = bytes.len();
        *out_pixels = Box::into_raw(bytes) as *mut u8;
    }
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_bytes_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: pointer/len pair came from `slint_instance_snapshot`.
    unsafe {
        drop(Box::from_raw(std::slice::from_raw_parts_mut(ptr, len)));
    }
}


// -- event loop extras --------------------------------------------------

#[no_mangle]
pub extern "C" fn slint_invoke_from_event_loop(shim: SlintShim, ctx: usize) -> *mut c_char {
    let Some(shim) = shim else {
        return error_owned("null event-loop shim");
    };
    if !EVENT_LOOP_ACTIVE.load(std::sync::atomic::Ordering::SeqCst) {
        return error_owned("The Slint event loop is not running");
    }
    ok_or_error(slint_interpreter::invoke_from_event_loop(move || {
        shim(ctx, std::ptr::null(), 0);
    }))
}

#[no_mangle]
pub extern "C" fn slint_set_xdg_app_id(app_id: *const c_char) -> *mut c_char {
    ok_or_error(slint_interpreter::set_xdg_app_id(read_str(app_id)))
}

// -- window controls & event dispatching --------------------------------

#[no_mangle]
pub extern "C" fn slint_window_get_size(
    instance: *mut slint_interpreter::ComponentInstance,
    out_width: *mut c_double,
    out_height: *mut c_double,
) -> *mut c_char {
    if instance.is_null() || out_width.is_null() || out_height.is_null() {
        return error_owned("null pointer passed to slint_window_get_size");
    }
    let instance = unsafe { &*instance };
    let window = instance.window();
    let scale = window.scale_factor() as f64;
    let phys = window.size();
    let (mut w, mut h) = if scale > 0.0 {
        (phys.width as f64 / scale, phys.height as f64 / scale)
    } else {
        (phys.width as f64, phys.height as f64)
    };
    if w == 0.0 && h == 0.0 {
        let window_inner = i_slint_core::window::WindowInner::from_pub(window);
        window_inner.ensure_tree_instantiated();
        if let Some(comp_rc) = window_inner.try_component() {
            let root_item = i_slint_core::items::ItemRc::new(comp_rc.clone(), 0);
            let geom = root_item.geometry();
            if geom.size.width > 0.0 || geom.size.height > 0.0 {
                w = geom.size.width as f64;
                h = geom.size.height as f64;
            } else {
                let comp_pin = i_slint_core::item_tree::ItemTreeRc::borrow_pin(&comp_rc);
                let horiz = comp_pin.as_ref().layout_info(i_slint_core::layout::Orientation::Horizontal);
                let vert = comp_pin.as_ref().layout_info(i_slint_core::layout::Orientation::Vertical);
                w = horiz.preferred_bounded() as f64;
                h = vert.preferred_bounded() as f64;
            }
        }
    }
    unsafe {
        *out_width = w;
        *out_height = h;
    }
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_window_set_size(
    instance: *mut slint_interpreter::ComponentInstance,
    width: c_double,
    height: c_double,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null pointer passed to slint_window_set_size");
    }
    let instance = unsafe { &*instance };
    instance.window().set_size(slint_interpreter::LogicalSize::new(width as f32, height as f32));
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_window_is_visible(
    instance: *mut slint_interpreter::ComponentInstance,
    out_visible: *mut c_int,
) -> *mut c_char {
    if instance.is_null() || out_visible.is_null() {
        return error_owned("null pointer passed to slint_window_is_visible");
    }
    let instance = unsafe { &*instance };
    let vis = instance.window().is_visible();
    unsafe {
        *out_visible = if vis { 1 } else { 0 };
    }
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_window_dispatch_pointer(
    instance: *mut slint_interpreter::ComponentInstance,
    event_type: c_int,
    x: c_double,
    y: c_double,
    button: c_int,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null pointer passed to slint_window_dispatch_pointer");
    }
    let instance = unsafe { &*instance };
    let pos = slint_interpreter::LogicalPosition::new(x as f32, y as f32);
    let btn = match button {
        0 => i_slint_core::items::PointerEventButton::Left,
        1 => i_slint_core::items::PointerEventButton::Right,
        2 => i_slint_core::items::PointerEventButton::Middle,
        _ => i_slint_core::items::PointerEventButton::Other,
    };
    let event = match event_type {
        0 => i_slint_core::platform::WindowEvent::PointerMoved { position: pos },
        1 => i_slint_core::platform::WindowEvent::PointerPressed { position: pos, button: btn },
        2 => i_slint_core::platform::WindowEvent::PointerReleased { position: pos, button: btn },
        3 => i_slint_core::platform::WindowEvent::PointerExited,
        _ => return error_owned(format!("unrecognized pointer event type: {}", event_type)),
    };
    instance.window().dispatch_event(event);
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_window_dispatch_key(
    instance: *mut slint_interpreter::ComponentInstance,
    event_type: c_int,
    text: *const c_char,
) -> *mut c_char {
    if instance.is_null() {
        return error_owned("null pointer passed to slint_window_dispatch_key");
    }
    let instance = unsafe { &*instance };
    let text_str = i_slint_core::SharedString::from(read_str(text));
    let event = match event_type {
        0 => i_slint_core::platform::WindowEvent::KeyPressed { text: text_str },
        1 => i_slint_core::platform::WindowEvent::KeyReleased { text: text_str },
        _ => return error_owned(format!("unrecognized key event type: {}", event_type)),
    };
    instance.window().dispatch_event(event);
    std::ptr::null_mut()
}

// -- element & accessibility introspection ------------------------------

fn accessible_role_to_str(role: i_slint_core::items::AccessibleRole) -> &'static str {
    use i_slint_core::items::AccessibleRole;
    match role {
        AccessibleRole::None => "none",
        AccessibleRole::Button => "button",
        AccessibleRole::Checkbox => "checkbox",
        AccessibleRole::Combobox => "combobox",
        AccessibleRole::Groupbox => "groupbox",
        AccessibleRole::Image => "image",
        AccessibleRole::List => "list",
        AccessibleRole::Slider => "slider",
        AccessibleRole::Spinbox => "spinbox",
        AccessibleRole::Tab => "tab",
        AccessibleRole::TabList => "tab-list",
        AccessibleRole::TabPanel => "tab-panel",
        AccessibleRole::Text => "text",
        AccessibleRole::Table => "table",
        AccessibleRole::Tree => "tree",
        AccessibleRole::ProgressIndicator => "progress-indicator",
        AccessibleRole::TextInput => "text-input",
        AccessibleRole::Switch => "switch",
        AccessibleRole::ListItem => "list-item",
        AccessibleRole::RadioButton => "radio-button",
        AccessibleRole::RadioGroup => "radio-group",
        AccessibleRole::WindowTitleBar => "window-title-bar",
        AccessibleRole::Banner => "banner",
        AccessibleRole::Complementary => "complementary",
        AccessibleRole::ContentInfo => "content-info",
        AccessibleRole::Form => "form",
        AccessibleRole::Main => "main",
        AccessibleRole::Navigation => "navigation",
        AccessibleRole::Region => "region",
        AccessibleRole::Search => "search",
        _ => "unknown",
    }
}

fn collect_accessible_value(
    item: &i_slint_core::items::ItemRc,
    seen_explicit_ids: &mut std::collections::HashMap<String, String>,
) -> Result<serde_json::Value, String> {
    use i_slint_core::accessibility::{accessible_descendents, AccessibleStringProperty};
    let role = item.accessible_role();
    let role_str = accessible_role_to_str(role);
    let geom = item.geometry();
    let abs_origin = item.map_to_native_window(geom.origin);

    let id_opt = item.accessible_string_property(AccessibleStringProperty::Id);
    let label_opt = item.accessible_string_property(AccessibleStringProperty::Label);
    let value_opt = item.accessible_string_property(AccessibleStringProperty::Value);
    let checked_opt = item.accessible_string_property(AccessibleStringProperty::Checked);
    let enabled_opt = item.accessible_string_property(AccessibleStringProperty::Enabled);
    let desc_opt = item.accessible_string_property(AccessibleStringProperty::Description);

    let label_str = label_opt.as_ref().map(|s| s.to_string()).unwrap_or_default();
    let desc_str = desc_opt.as_ref().map(|s| s.to_string()).unwrap_or_default();
    let explicit_id = id_opt.as_ref().map(|s| s.to_string()).filter(|s| !s.is_empty());
    let id_stable = explicit_id.is_some();

    if let Some(ref eid) = explicit_id {
        if let Some(prev_role) = seen_explicit_ids.get(eid) {
            return Err(format!("duplicate accessible-id '{}' found in UI tree (roles: '{}' and '{}')", eid, prev_role, role_str));
        }
        seen_explicit_ids.insert(eid.clone(), role_str.to_string());
    }

    let id_str = explicit_id.unwrap_or_else(|| {
        if !label_str.is_empty() {
            label_str.clone()
        } else {
            format!("{}_{}_{}", role_str, abs_origin.x as i32, abs_origin.y as i32)
        }
    });

    let is_enabled = match enabled_opt.as_ref().map(|s| s.as_str()) {
        Some("false") => false,
        _ => true,
    };

    let value_str = if let Some(v) = value_opt {
        v.to_string()
    } else if let Some(c) = checked_opt {
        c.to_string()
    } else {
        String::new()
    };

    let mut children = Vec::new();
    for child in accessible_descendents(item) {
        if child.accessible_role() != i_slint_core::items::AccessibleRole::None {
            children.push(collect_accessible_value(&child, seen_explicit_ids)?);
        }
    }

    Ok(serde_json::json!({
        "id": id_str,
        "id_stable": id_stable,
        "role": role_str,
        "label": label_str,
        "description": desc_str,
        "value": value_str,
        "x": abs_origin.x,
        "y": abs_origin.y,
        "width": geom.size.width,
        "height": geom.size.height,
        "bounds": {
            "x": abs_origin.x,
            "y": abs_origin.y,
            "width": geom.size.width,
            "height": geom.size.height
        },
        "enabled": is_enabled,
        "visible": true,
        "children": children,
    }))
}

fn item_matches_target(item: &i_slint_core::items::ItemRc, target: &str) -> bool {
    use i_slint_core::accessibility::AccessibleStringProperty;
    let id_opt = item.accessible_string_property(AccessibleStringProperty::Id);
    let label_opt = item.accessible_string_property(AccessibleStringProperty::Label);
    let role = item.accessible_role();
    let role_str = accessible_role_to_str(role);

    if id_opt.as_ref().map(|s| s.as_str() == target).unwrap_or(false)
        || label_opt.as_ref().map(|s| s.as_str() == target).unwrap_or(false)
        || role_str.eq_ignore_ascii_case(target)
    {
        return true;
    }
    false
}

fn find_element_in_tree(
    item: &i_slint_core::items::ItemRc,
    target: &str,
) -> Option<i_slint_core::items::ItemRc> {
    use i_slint_core::accessibility::accessible_descendents;
    if item_matches_target(item, target) {
        return Some(item.clone());
    }
    for child in accessible_descendents(item) {
        if child.accessible_role() == i_slint_core::items::AccessibleRole::None {
            continue;
        }
        if item_matches_target(&child, target) {
            return Some(child);
        }
        if let Some(found) = find_element_in_tree(&child, target) {
            return Some(found);
        }
    }
    None
}

fn find_accessible_item_in_window(
    window: &slint_interpreter::Window,
    target: &str,
) -> Option<i_slint_core::items::ItemRc> {
    use i_slint_core::items::ItemRc;
    use i_slint_core::window::WindowInner;

    let window_inner = WindowInner::from_pub(window);
    window_inner.ensure_tree_instantiated();

    // 1. Search active popups first in reverse order (topmost z-order)
    for popup in window_inner.active_popups().iter().rev() {
        let popup_root = ItemRc::new_root(popup.component.clone());
        if let Some(found) = find_element_in_tree(&popup_root, target) {
            return Some(found);
        }
    }

    // 2. Search main component tree
    if let Some(comp_rc) = window_inner.try_component() {
        let root_item = ItemRc::new(comp_rc, 0);
        if let Some(found) = find_element_in_tree(&root_item, target) {
            return Some(found);
        }
    }

    None
}

#[no_mangle]
pub extern "C" fn slint_instance_dump_ui_tree(
    instance: *mut slint_interpreter::ComponentInstance,
    out_json: *mut *mut c_char,
) -> *mut c_char {
    if instance.is_null() || out_json.is_null() {
        return error_owned("null pointer passed to slint_instance_dump_ui_tree");
    }
    let instance = unsafe { &*instance };
    let window = instance.window();
    let window_inner = i_slint_core::window::WindowInner::from_pub(window);
    window_inner.ensure_tree_instantiated();

    let scale = window.scale_factor();
    let size = window.size();
    let (win_w, win_h) = if scale > 0.0 {
        (size.width as f32 / scale, size.height as f32 / scale)
    } else {
        (size.width as f32, size.height as f32)
    };

    let mut seen_explicit_ids = std::collections::HashMap::new();
    let mut children = Vec::new();
    if let Some(comp_rc) = window_inner.try_component() {
        let root_item = i_slint_core::items::ItemRc::new(comp_rc, 0);
        for child in i_slint_core::accessibility::accessible_descendents(&root_item) {
            if child.accessible_role() != i_slint_core::items::AccessibleRole::None {
                match collect_accessible_value(&child, &mut seen_explicit_ids) {
                    Ok(v) => children.push(v),
                    Err(e) => return error_owned(e),
                }
            }
        }
    }
    for popup in window_inner.active_popups().iter() {
        let popup_root = i_slint_core::items::ItemRc::new_root(popup.component.clone());
        for child in i_slint_core::accessibility::accessible_descendents(&popup_root) {
            if child.accessible_role() != i_slint_core::items::AccessibleRole::None {
                match collect_accessible_value(&child, &mut seen_explicit_ids) {
                    Ok(v) => children.push(v),
                    Err(e) => return error_owned(e),
                }
            }
        }
    }

    let root_node = serde_json::json!({
        "id": "root_window",
        "id_stable": true,
        "role": "window",
        "label": "Window",
        "description": "",
        "value": "",
        "x": 0.0,
        "y": 0.0,
        "width": win_w,
        "height": win_h,
        "bounds": {
            "x": 0.0,
            "y": 0.0,
            "width": win_w,
            "height": win_h
        },
        "enabled": true,
        "visible": true,
        "children": children,
    });

    let json_str = serde_json::to_string(&root_node).unwrap_or_else(|_| "{}".to_string());
    unsafe {
        *out_json = out_string(&json_str);
    }
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_instance_find_element(
    instance: *mut slint_interpreter::ComponentInstance,
    target: *const c_char,
    out_id: *mut *mut c_char,
    out_role: *mut *mut c_char,
    out_label: *mut *mut c_char,
    out_value: *mut *mut c_char,
    out_x: *mut c_double,
    out_y: *mut c_double,
    out_width: *mut c_double,
    out_height: *mut c_double,
    out_enabled: *mut c_int,
    out_visible: *mut c_int,
) -> *mut c_char {
    if instance.is_null() || target.is_null() {
        return error_owned("null pointer passed to slint_instance_find_element");
    }
    let instance = unsafe { &*instance };
    let target_str = read_str(target);
    let found = find_accessible_item_in_window(instance.window(), &target_str);

    let Some(item) = found else {
        unsafe {
            if !out_role.is_null() {
                *out_role = std::ptr::null_mut();
            }
        }
        return std::ptr::null_mut();
    };

    use i_slint_core::accessibility::AccessibleStringProperty;
    let geom = item.geometry();
    let abs_origin = item.map_to_native_window(geom.origin);
    let id_opt = item.accessible_string_property(AccessibleStringProperty::Id);
    let label_opt = item.accessible_string_property(AccessibleStringProperty::Label);
    let value_opt = item.accessible_string_property(AccessibleStringProperty::Value);
    let checked_opt = item.accessible_string_property(AccessibleStringProperty::Checked);
    let enabled_opt = item.accessible_string_property(AccessibleStringProperty::Enabled);

    let label_str = label_opt.as_ref().map(|s| s.to_string()).unwrap_or_default();
    let id_str = id_opt.as_ref().map(|s| s.to_string()).unwrap_or_else(|| {
        if !label_str.is_empty() {
            label_str.clone()
        } else {
            format!("{}_{}_{}", accessible_role_to_str(item.accessible_role()), abs_origin.x as i32, abs_origin.y as i32)
        }
    });

    let is_enabled = match enabled_opt.as_ref().map(|s| s.as_str()) {
        Some("false") => 0,
        _ => 1,
    };

    let value_str = if let Some(v) = value_opt {
        v.to_string()
    } else if let Some(c) = checked_opt {
        c.to_string()
    } else {
        String::new()
    };
    let role_str = accessible_role_to_str(item.accessible_role());

    unsafe {
        if !out_id.is_null() {
            *out_id = out_string(&id_str);
        }
        if !out_role.is_null() {
            *out_role = out_string(role_str);
        }
        if !out_label.is_null() {
            *out_label = out_string(&label_str);
        }
        if !out_value.is_null() {
            *out_value = out_string(&value_str);
        }
        if !out_x.is_null() {
            *out_x = abs_origin.x as f64;
        }
        if !out_y.is_null() {
            *out_y = abs_origin.y as f64;
        }
        if !out_width.is_null() {
            *out_width = geom.size.width as f64;
        }
        if !out_height.is_null() {
            *out_height = geom.size.height as f64;
        }
        if !out_enabled.is_null() {
            *out_enabled = is_enabled;
        }
        if !out_visible.is_null() {
            *out_visible = 1;
        }
    }
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn slint_instance_invoke_element_action(
    instance: *mut slint_interpreter::ComponentInstance,
    target: *const c_char,
) -> *mut c_char {
    slint_instance_invoke_element_accessibility_action(instance, target, 0, std::ptr::null())
}

#[no_mangle]
pub extern "C" fn slint_instance_invoke_element_accessibility_action(
    instance: *mut slint_interpreter::ComponentInstance,
    target: *const c_char,
    action_kind: c_int,
    value_str: *const c_char,
) -> *mut c_char {
    if instance.is_null() || target.is_null() {
        return error_owned("null pointer passed to slint_instance_invoke_element_accessibility_action");
    }
    let instance = unsafe { &*instance };
    let target_str = read_str(target);
    let window = instance.window();
    let found = find_accessible_item_in_window(window, &target_str);

    let Some(item) = found else {
        return error_owned(format!("element '{}' not found", target_str));
    };

    use i_slint_core::accessibility::{AccessibilityAction, SupportedAccessibilityAction};
    let supported = item.supported_accessibility_actions();
    match action_kind {
        0 => {
            if supported.contains(SupportedAccessibilityAction::Default) {
                item.accessible_action(&AccessibilityAction::Default);
            } else {
                // Fallback to synthetic pointer events directed at element center
                let geom = item.geometry();
                let abs_origin = item.map_to_native_window(geom.origin);
                let center_x = abs_origin.x + geom.size.width / 2.0;
                let center_y = abs_origin.y + geom.size.height / 2.0;
                let pos = slint_interpreter::LogicalPosition::new(center_x, center_y);

                window.dispatch_event(i_slint_core::platform::WindowEvent::PointerMoved { position: pos });
                window.dispatch_event(i_slint_core::platform::WindowEvent::PointerPressed {
                    position: pos,
                    button: i_slint_core::items::PointerEventButton::Left,
                });
                window.dispatch_event(i_slint_core::platform::WindowEvent::PointerReleased {
                    position: pos,
                    button: i_slint_core::items::PointerEventButton::Left,
                });
            }
        }
        1 => {
            if supported.contains(SupportedAccessibilityAction::Increment) {
                item.accessible_action(&AccessibilityAction::Increment);
            } else {
                return error_owned(format!(
                    "element '{}' does not support Increment accessibility action",
                    target_str
                ));
            }
        }
        2 => {
            if supported.contains(SupportedAccessibilityAction::Decrement) {
                item.accessible_action(&AccessibilityAction::Decrement);
            } else {
                return error_owned(format!(
                    "element '{}' does not support Decrement accessibility action",
                    target_str
                ));
            }
        }
        3 => {
            if supported.contains(SupportedAccessibilityAction::Expand) {
                item.accessible_action(&AccessibilityAction::Expand);
            } else if supported.contains(SupportedAccessibilityAction::Default) {
                item.accessible_action(&AccessibilityAction::Default);
            } else {
                return error_owned(format!(
                    "element '{}' does not support Expand accessibility action",
                    target_str
                ));
            }
        }
        4 => {
            let val = i_slint_core::SharedString::from(read_str(value_str));
            if supported.contains(SupportedAccessibilityAction::SetValue) {
                item.accessible_action(&AccessibilityAction::SetValue(val));
            } else {
                return error_owned(format!(
                    "element '{}' does not support SetValue accessibility action",
                    target_str
                ));
            }
        }
        _ => {
            return error_owned(format!("unknown accessibility action kind: {}", action_kind));
        }
    }
    std::ptr::null_mut()
}

