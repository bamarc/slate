use std::os::raw::{c_char, c_double, c_int};

use slint_interpreter::ComponentHandle;

use crate::error::*;
use crate::value::SlintShim;

pub(crate) static EVENT_LOOP_ACTIVE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

pub(crate) struct EventLoopGuard;
impl EventLoopGuard {
    pub(crate) fn enter() -> Self {
        EVENT_LOOP_ACTIVE.store(true, std::sync::atomic::Ordering::SeqCst);
        EventLoopGuard
    }
}
impl Drop for EventLoopGuard {
    fn drop(&mut self) {
        EVENT_LOOP_ACTIVE.store(false, std::sync::atomic::Ordering::SeqCst);
    }
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
    timer.inner.start(
        mode,
        std::time::Duration::from_millis(interval_ms),
        move || {
            shim(ctx, std::ptr::null(), 0);
        },
    );
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
    if instance.is_null()
        || out_pixels.is_null()
        || out_len.is_null()
        || out_width.is_null()
        || out_height.is_null()
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
                let horiz = comp_pin
                    .as_ref()
                    .layout_info(i_slint_core::layout::Orientation::Horizontal);
                let vert = comp_pin
                    .as_ref()
                    .layout_info(i_slint_core::layout::Orientation::Vertical);
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
    instance
        .window()
        .set_size(slint_interpreter::LogicalSize::new(
            width as f32,
            height as f32,
        ));
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
        1 => i_slint_core::platform::WindowEvent::PointerPressed {
            position: pos,
            button: btn,
        },
        2 => i_slint_core::platform::WindowEvent::PointerReleased {
            position: pos,
            button: btn,
        },
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
