use std::ffi::CString;
use std::os::raw::{c_char, c_double, c_int};

use slint_interpreter::ComponentHandle;

use crate::error::*;
use crate::value::{
    c_to_value, slint_value_free, value_to_c, value_to_c_owned, SlintShim, SlintValue,
};
use crate::window::EventLoopGuard;

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
            let owned = CString::new(s.as_str()).unwrap_or_else(|_| CString::new("").unwrap());
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
        Ok(other) => error_owned(format!(
            "global '{global}' property '{name}' is not a number ({other:?})"
        )),
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
        Ok(other) => error_owned(format!(
            "global '{global}' property '{name}' is not a string ({other:?})"
        )),
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
        Ok(other) => error_owned(format!(
            "global '{global}' property '{name}' is not a bool ({other:?})"
        )),
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
