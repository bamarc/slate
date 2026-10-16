use std::os::raw::{c_char, c_double, c_int};

use slint_interpreter::ComponentHandle;

use crate::error::*;

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

    let label_str = label_opt
        .as_ref()
        .map(|s| s.to_string())
        .unwrap_or_default();
    let desc_str = desc_opt.as_ref().map(|s| s.to_string()).unwrap_or_default();

    let explicit_id = id_opt
        .as_ref()
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty());
    let id_stable = explicit_id.is_some();

    if let Some(ref eid) = explicit_id {
        if let Some(prev_role) = seen_explicit_ids.get(eid) {
            return Err(format!(
                "duplicate accessible-id '{}' found in UI tree (roles: '{}' and '{}')",
                eid, prev_role, role_str
            ));
        }
        seen_explicit_ids.insert(eid.clone(), role_str.to_string());
    }

    let id_str = explicit_id.unwrap_or_else(|| {
        if !label_str.is_empty() {
            label_str.clone()
        } else {
            format!(
                "{}_{}_{}",
                role_str, abs_origin.x as i32, abs_origin.y as i32
            )
        }
    });

    let is_enabled = !matches!(enabled_opt.as_ref().map(|s| s.as_str()), Some("false"));

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

    if id_opt
        .as_ref()
        .map(|s| s.as_str() == target)
        .unwrap_or(false)
        || label_opt
            .as_ref()
            .map(|s| s.as_str() == target)
            .unwrap_or(false)
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

    let label_str = label_opt
        .as_ref()
        .map(|s| s.to_string())
        .unwrap_or_default();
    let id_str = id_opt.as_ref().map(|s| s.to_string()).unwrap_or_else(|| {
        if !label_str.is_empty() {
            label_str.clone()
        } else {
            format!(
                "{}_{}_{}",
                accessible_role_to_str(item.accessible_role()),
                abs_origin.x as i32,
                abs_origin.y as i32
            )
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
        return error_owned(
            "null pointer passed to slint_instance_invoke_element_accessibility_action",
        );
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

                window.dispatch_event(i_slint_core::platform::WindowEvent::PointerMoved {
                    position: pos,
                });
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
            return error_owned(format!(
                "unknown accessibility action kind: {}",
                action_kind
            ));
        }
    }
    std::ptr::null_mut()
}
