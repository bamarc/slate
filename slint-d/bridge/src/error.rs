use std::ffi::{CStr, CString};
use std::os::raw::c_char;

pub fn read_str(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    // SAFETY: contract requires a valid NUL-terminated UTF-8 string.
    unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() }
}

pub fn ok_or_error<T, E: ToString>(r: Result<T, E>) -> *mut c_char {
    match r {
        Ok(_) => std::ptr::null_mut(),
        Err(e) => CString::new(e.to_string())
            .map(|s| s.into_raw())
            .unwrap_or_else(|_| {
                CString::new("error text was not representable")
                    .unwrap()
                    .into_raw()
            }),
    }
}

pub fn error_owned(msg: impl Into<String>) -> *mut c_char {
    CString::new(msg.into())
        .map(|s| s.into_raw())
        .unwrap_or_else(|_| {
            CString::new("error text was not representable")
                .unwrap()
                .into_raw()
        })
}

pub fn out_string(text: &str) -> *mut c_char {
    CString::new(text)
        .unwrap_or_else(|_| CString::new("<non-utf8>").unwrap())
        .into_raw()
}

#[no_mangle]
pub extern "C" fn slint_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: pointer came from this crate as an owned CString.
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

#[no_mangle]
pub extern "C" fn slint_bytes_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: pointer/len pair came from `slint_instance_snapshot`.
    unsafe {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }
}
