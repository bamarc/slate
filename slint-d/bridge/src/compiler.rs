use std::ffi::CString;
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;

use slint_interpreter::DiagnosticLevel;

use crate::error::*;

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
                message: CString::new(d.message())
                    .unwrap_or_else(|_| CString::new("<non-utf8 diagnostic>").unwrap()),
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

// -- definition introspection -------------------------------------------
// Each name getter writes a fresh owned string (`slint_string_free`), so no
// lifetimes escape even though the underlying iterators are transient.

fn definition_ref(
    def: *mut slint_interpreter::ComponentDefinition,
) -> Option<&'static mut slint_interpreter::ComponentDefinition> {
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
