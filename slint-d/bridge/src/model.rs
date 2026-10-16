use std::os::raw::c_char;
use std::rc::Rc;

use i_slint_core::model::{Model, ModelRc, VecModel};

use crate::error::*;
use crate::value::{c_to_value, value_to_c_owned, SlintValue};

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
    if let Some(vec_model) = m
        .as_any()
        .downcast_ref::<VecModel<slint_interpreter::Value>>()
    {
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
    if let Some(vec_model) = m
        .as_any()
        .downcast_ref::<VecModel<slint_interpreter::Value>>()
    {
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
    if let Some(vec_model) = m
        .as_any()
        .downcast_ref::<VecModel<slint_interpreter::Value>>()
    {
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
