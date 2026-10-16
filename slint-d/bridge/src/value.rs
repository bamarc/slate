use std::ffi::CString;
use std::os::raw::{c_char, c_double, c_int, c_void};

use i_slint_core::model::ModelRc;

use crate::error::*;

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
pub(crate) fn value_to_c(value: &slint_interpreter::Value) -> SlintValue {
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
pub(crate) fn value_to_c_owned(value: &slint_interpreter::Value) -> SlintValue {
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
pub(crate) fn c_to_value(sv: &SlintValue) -> slint_interpreter::Value {
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
                    drop(Box::from_raw(
                        value.handle as *mut ModelRc<slint_interpreter::Value>,
                    ));
                }
            } else if value.tag == 5 {
                // SAFETY: Struct handle allocated via Box::into_raw
                unsafe {
                    drop(Box::from_raw(
                        value.handle as *mut slint_interpreter::Struct,
                    ));
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
