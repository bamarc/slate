//! Dynamic Slint runtime automation engine and component inspector.
//!
//! Provides [`SlintDynamicInspector`] and [`SlintDynamicController`] which inspect
//! the live Slint component hierarchy and dispatch interactions using Slint's native
//! accessibility tree and fallback synthetic input events.

use std::collections::HashMap;
use std::sync::Arc;
use i_slint_core::accessibility::{
    accessible_descendents, AccessibilityAction, AccessibleStringProperty,
    SupportedAccessibilityAction,
};
use i_slint_core::items::{AccessibleRole, ItemRc};
use i_slint_core::window::WindowInner;
use slint::{ComponentHandle, LogicalPosition, SharedString};

use crate::bridge::SlintUiBridge;
use crate::error::AgentError;
use crate::interactable::McpAction;
use crate::model::{
    ActionResult, ElementSelector, MouseButton, Point, Rect, UiElementNode, UiTree,
};
use crate::traits::{ElementController, UiInspector};

/// Convert an `AccessibleRole` variant to its standard string identifier.
pub fn accessible_role_to_str(role: AccessibleRole) -> &'static str {
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

/// Map an `AccessibleRole` to a semantic UI component type name.
pub fn role_to_type_name(role: AccessibleRole) -> String {
    match role {
        AccessibleRole::Button => "SlateButton".to_string(),
        AccessibleRole::TextInput => "SlateInput".to_string(),
        AccessibleRole::Switch => "SlateSwitch".to_string(),
        AccessibleRole::Checkbox => "SlateCheckbox".to_string(),
        AccessibleRole::Slider => "SlateSlider".to_string(),
        AccessibleRole::Spinbox => "SlateSpinbox".to_string(),
        AccessibleRole::Tab => "SlateTab".to_string(),
        AccessibleRole::TabList => "SlateTabs".to_string(),
        AccessibleRole::Table => "SlateTable".to_string(),
        AccessibleRole::ListItem => "SlateListItem".to_string(),
        AccessibleRole::RadioButton => "SlateRadio".to_string(),
        AccessibleRole::RadioGroup => "SlateRadioGroup".to_string(),
        AccessibleRole::ProgressIndicator => "SlateProgressBar".to_string(),
        AccessibleRole::Combobox => "SlateCombobox".to_string(),
        other => {
            let role_s = accessible_role_to_str(other);
            let mut c = role_s.chars();
            match c.next() {
                None => "Element".to_string(),
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
            }
        }
    }
}

/// Recursively collect an accessible item and all its accessible descendants into a `UiElementNode`.
pub fn collect_accessible_node(item: &ItemRc) -> UiElementNode {
    let role = item.accessible_role();
    let role_str = accessible_role_to_str(role);

    let geom = item.geometry();
    let abs_origin = item.map_to_native_window(geom.origin);
    let bounds = Rect::new(
        abs_origin.x,
        abs_origin.y,
        geom.size.width,
        geom.size.height,
    );

    let id_opt = item.accessible_string_property(AccessibleStringProperty::Id);
    let label_opt = item.accessible_string_property(AccessibleStringProperty::Label);
    let value_opt = item.accessible_string_property(AccessibleStringProperty::Value);
    let checked_opt = item.accessible_string_property(AccessibleStringProperty::Checked);
    let desc_opt = item.accessible_string_property(AccessibleStringProperty::Description);
    let enabled_opt = item.accessible_string_property(AccessibleStringProperty::Enabled);
    let placeholder_opt = item.accessible_string_property(AccessibleStringProperty::PlaceholderText);
    let expanded_opt = item.accessible_string_property(AccessibleStringProperty::Expanded);
    let selected_opt = item.accessible_string_property(AccessibleStringProperty::ItemSelected);
    let checkable_opt = item.accessible_string_property(AccessibleStringProperty::Checkable);

    let label_str = label_opt.as_ref().map(|s| s.to_string());

    // Compute stable ID with hierarchical fallbacks
    let id_str = if let Some(ref id) = id_opt {
        if !id.is_empty() {
            id.to_string()
        } else if let Some(ref l) = label_str {
            if !l.is_empty() {
                l.clone()
            } else {
                format!("{}_{}_{}", role_str, abs_origin.x as i32, abs_origin.y as i32)
            }
        } else {
            format!("{}_{}_{}", role_str, abs_origin.x as i32, abs_origin.y as i32)
        }
    } else if let Some(ref l) = label_str {
        if !l.is_empty() {
            l.clone()
        } else {
            format!("{}_{}_{}", role_str, abs_origin.x as i32, abs_origin.y as i32)
        }
    } else {
        format!("{}_{}_{}", role_str, abs_origin.x as i32, abs_origin.y as i32)
    };

    // Value resolution
    let value_str = if let Some(v) = value_opt {
        Some(v.to_string())
    } else if let Some(c) = checked_opt.as_ref() {
        Some(c.to_string())
    } else if let Some(e) = expanded_opt.as_ref() {
        Some(e.to_string())
    } else {
        None
    };

    // Enabled resolution
    let is_enabled = match enabled_opt.as_ref().map(|s| s.as_str()) {
        Some("false") => false,
        _ => true,
    };

    let mut properties = HashMap::new();
    if let Some(desc) = desc_opt {
        properties.insert("description".to_string(), serde_json::Value::String(desc.to_string()));
    }
    if let Some(placeholder) = placeholder_opt {
        properties.insert("placeholder".to_string(), serde_json::Value::String(placeholder.to_string()));
    }
    if let Some(ref c) = checked_opt {
        properties.insert("checked".to_string(), serde_json::json!(c.as_str() == "true"));
    }
    if let Some(ref e) = expanded_opt {
        properties.insert("expanded".to_string(), serde_json::json!(e.as_str() == "true"));
    }
    if let Some(ref s) = selected_opt {
        properties.insert("selected".to_string(), serde_json::json!(s.as_str() == "true"));
    }
    if let Some(ref chk) = checkable_opt {
        properties.insert("checkable".to_string(), serde_json::json!(chk.as_str() == "true"));
    }
    if let Some(ref v) = value_str {
        properties.insert("value".to_string(), serde_json::Value::String(v.clone()));
    }

    // Recurse into accessible child items
    let mut children = Vec::new();
    for child in accessible_descendents(item) {
        if child.accessible_role() != AccessibleRole::None {
            children.push(collect_accessible_node(&child));
        }
    }

    UiElementNode {
        id: id_str,
        type_name: role_to_type_name(role),
        bounds,
        label: label_str,
        role: role_str.to_string(),
        value: value_str,
        enabled: is_enabled,
        focused: false,
        visible: true,
        children,
        properties,
    }
}

/// Build the full hierarchical `UiTree` by introspecting the Slint window and popups.
pub fn build_slint_ui_tree(window: &slint::Window) -> Result<UiTree, AgentError> {
    let window_inner = WindowInner::from_pub(window);
    window_inner.ensure_tree_instantiated();

    let scale = window.scale_factor();
    let size = window.size();
    let (win_w, win_h) = (size.width as f32 / scale, size.height as f32 / scale);

    let mut top_children = Vec::new();

    // 1. Walk main component tree
    if let Some(comp_rc) = window_inner.try_component() {
        let root_item = ItemRc::new(comp_rc, 0);
        for child in accessible_descendents(&root_item) {
            if child.accessible_role() != AccessibleRole::None {
                top_children.push(collect_accessible_node(&child));
            }
        }
    }

    // 2. Walk active popups (modals, sheets, popovers, dropdowns)
    for popup in window_inner.active_popups().iter() {
        let popup_root = ItemRc::new_root(popup.component.clone());
        for child in accessible_descendents(&popup_root) {
            if child.accessible_role() != AccessibleRole::None {
                top_children.push(collect_accessible_node(&child));
            }
        }
    }

    let root_node = UiElementNode {
        id: "main_window".to_string(),
        type_name: "Window".to_string(),
        bounds: Rect::new(0.0, 0.0, win_w, win_h),
        label: Some("Slate Window".to_string()),
        role: "window".to_string(),
        value: None,
        enabled: true,
        focused: true,
        visible: true,
        children: top_children,
        properties: HashMap::new(),
    };

    Ok(UiTree::new(root_node).with_window_info("Slate Window", win_w, win_h))
}

/// Test whether an `ItemRc` matches an `ElementSelector`.
fn item_matches_selector(item: &ItemRc, selector: &ElementSelector) -> bool {
    let id_opt = item.accessible_string_property(AccessibleStringProperty::Id);
    let label_opt = item.accessible_string_property(AccessibleStringProperty::Label);

    match selector {
        ElementSelector::Id(target_id) => {
            if let Some(ref id) = id_opt {
                if id.as_str() == target_id {
                    return true;
                }
            }
            if let Some(ref lbl) = label_opt {
                if lbl.as_str() == target_id {
                    return true;
                }
            }
            false
        }
        ElementSelector::Label(target_label) => {
            if let Some(ref lbl) = label_opt {
                if lbl.as_str() == target_label {
                    return true;
                }
            }
            false
        }
        ElementSelector::Role(target_role) => {
            let role = item.accessible_role();
            let role_str = accessible_role_to_str(role);
            role_str.eq_ignore_ascii_case(target_role)
        }
        ElementSelector::Coordinate(point) => {
            let geom = item.geometry();
            let abs_origin = item.map_to_native_window(geom.origin);
            let bounds = Rect::new(
                abs_origin.x,
                abs_origin.y,
                geom.size.width,
                geom.size.height,
            );
            bounds.contains(point)
        }
    }
}

/// Recursively search for an item matching `selector` in `parent`'s accessible descendants.
fn find_in_descendents(parent: &ItemRc, selector: &ElementSelector) -> Option<ItemRc> {
    for item in accessible_descendents(parent) {
        if item.accessible_role() == AccessibleRole::None {
            continue;
        }

        // For coordinates, perform deepest-first search so deepest child gets targeted
        if matches!(selector, ElementSelector::Coordinate(_)) {
            if let Some(leaf) = find_in_descendents(&item, selector) {
                return Some(leaf);
            }
            if item_matches_selector(&item, selector) {
                return Some(item);
            }
            continue;
        }

        // For IDs, labels, roles: check current node, then recurse
        if item_matches_selector(&item, selector) {
            return Some(item);
        }

        if let Some(child_match) = find_in_descendents(&item, selector) {
            return Some(child_match);
        }
    }
    None
}

/// Find an accessible item in a Slint window matching `selector`.
pub fn find_accessible_item_in_window(
    window: &slint::Window,
    selector: &ElementSelector,
) -> Option<ItemRc> {
    let window_inner = WindowInner::from_pub(window);
    window_inner.ensure_tree_instantiated();

    // 1. Search active popups first in reverse order (topmost z-order)
    for popup in window_inner.active_popups().iter().rev() {
        let popup_root = ItemRc::new_root(popup.component.clone());
        if let Some(found) = find_in_descendents(&popup_root, selector) {
            return Some(found);
        }
    }

    // 2. Search main component tree
    if let Some(comp_rc) = window_inner.try_component() {
        let root_item = ItemRc::new(comp_rc, 0);
        if let Some(found) = find_in_descendents(&root_item, selector) {
            return Some(found);
        }
    }

    None
}

// ============================================================================
// Dynamic Inspector Implementation
// ============================================================================

/// Dynamic UI inspector that traverses the live Slint accessibility tree.
pub struct SlintDynamicInspector<T: ComponentHandle + 'static> {
    weak: slint::Weak<T>,
    bridge: Arc<SlintUiBridge>,
}

impl<T: ComponentHandle + 'static> SlintDynamicInspector<T> {
    pub fn new(weak: slint::Weak<T>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl<T: ComponentHandle + 'static> UiInspector for SlintDynamicInspector<T> {
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        let weak = self.weak.clone();
        self.bridge
            .run_on_ui(move || {
                let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = comp.window();
                build_slint_ui_tree(window)
            })
            .await
    }
}

// ============================================================================
// Dynamic Controller Implementation
// ============================================================================

/// Dynamic element controller dispatching actions to accessible items or synthetic events.
pub struct SlintDynamicController<T: ComponentHandle + 'static> {
    weak: slint::Weak<T>,
    bridge: Arc<SlintUiBridge>,
}

impl<T: ComponentHandle + 'static> SlintDynamicController<T> {
    pub fn new(weak: slint::Weak<T>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl<T: ComponentHandle + 'static> ElementController for SlintDynamicController<T> {
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        let target_str = target.to_string();
        self.bridge
            .run_on_ui(move || {
                let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = comp.window();
                let selector = ElementSelector::parse(&target_str);
                let item = find_accessible_item_in_window(window, &selector)
                    .ok_or_else(|| AgentError::element_not_found(&target_str, "Element not present in UI tree"))?;

                let id = item.accessible_string_property(AccessibleStringProperty::Id)
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| target_str.clone());

                if item.supported_accessibility_actions().contains(SupportedAccessibilityAction::Default) {
                    item.accessible_action(&AccessibilityAction::Default);
                    Ok(ActionResult::success(format!("Clicked '{}'", id)).with_element_id(id))
                } else {
                    // Fallback to synthetic pointer events directed at element center
                    let geom = item.geometry();
                    let abs_origin = item.map_to_native_window(geom.origin);
                    let center_x = abs_origin.x + geom.size.width / 2.0;
                    let center_y = abs_origin.y + geom.size.height / 2.0;
                    let pos = LogicalPosition::new(center_x, center_y);

                    window.dispatch_event(slint::platform::WindowEvent::PointerMoved { position: pos });
                    window.dispatch_event(slint::platform::WindowEvent::PointerPressed {
                        position: pos,
                        button: slint::platform::PointerEventButton::Left,
                    });
                    window.dispatch_event(slint::platform::WindowEvent::PointerReleased {
                        position: pos,
                        button: slint::platform::PointerEventButton::Left,
                    });

                    Ok(ActionResult::success(format!("Clicked '{}' via synthetic pointer", id)).with_element_id(id))
                }
            })
            .await
    }

    async fn click_at(&self, point: Point, button: MouseButton) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        self.bridge
            .run_on_ui(move || {
                let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = comp.window();
                let slint_btn = match button {
                    MouseButton::Left => slint::platform::PointerEventButton::Left,
                    MouseButton::Right => slint::platform::PointerEventButton::Right,
                    MouseButton::Middle => slint::platform::PointerEventButton::Middle,
                };
                let pos = LogicalPosition::new(point.x, point.y);
                window.dispatch_event(slint::platform::WindowEvent::PointerMoved { position: pos });
                window.dispatch_event(slint::platform::WindowEvent::PointerPressed {
                    position: pos,
                    button: slint_btn,
                });
                window.dispatch_event(slint::platform::WindowEvent::PointerReleased {
                    position: pos,
                    button: slint_btn,
                });
                Ok(ActionResult::success(format!("Clicked at ({}, {}) with {:?}", point.x, point.y, button)))
            })
            .await
    }

    async fn send_keys(&self, target: Option<&str>, text: &str) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        let target_str = target.map(|s| s.to_string());
        let text_str = text.to_string();
        self.bridge
            .run_on_ui(move || {
                let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = comp.window();

                if let Some(ref target) = target_str {
                    let selector = ElementSelector::parse(target);
                    let item = find_accessible_item_in_window(window, &selector)
                        .ok_or_else(|| AgentError::element_not_found(target, "Element not present in UI tree"))?;

                    if item.supported_accessibility_actions().contains(SupportedAccessibilityAction::SetValue) {
                        item.accessible_action(&AccessibilityAction::SetValue(SharedString::from(text_str.as_str())));
                        let id = item.accessible_string_property(AccessibleStringProperty::Id)
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| target.clone());
                        return Ok(ActionResult::success(format!("Sent keys to '{}'", id))
                            .with_element_id(id)
                            .with_value(serde_json::json!(text_str)));
                    }

                    // Focus via pointer click
                    let geom = item.geometry();
                    let abs_origin = item.map_to_native_window(geom.origin);
                    let center_x = abs_origin.x + geom.size.width / 2.0;
                    let center_y = abs_origin.y + geom.size.height / 2.0;
                    let pos = LogicalPosition::new(center_x, center_y);
                    window.dispatch_event(slint::platform::WindowEvent::PointerMoved { position: pos });
                    window.dispatch_event(slint::platform::WindowEvent::PointerPressed {
                        position: pos,
                        button: slint::platform::PointerEventButton::Left,
                    });
                    window.dispatch_event(slint::platform::WindowEvent::PointerReleased {
                        position: pos,
                        button: slint::platform::PointerEventButton::Left,
                    });
                }

                // Dispatch keystrokes
                for ch in text_str.chars() {
                    let s: SharedString = ch.to_string().into();
                    window.dispatch_event(slint::platform::WindowEvent::KeyPressed { text: s.clone() });
                    window.dispatch_event(slint::platform::WindowEvent::KeyReleased { text: s });
                }

                let mut res = ActionResult::success(format!("Sent keys '{}'", text_str));
                if let Some(ref t) = target_str {
                    res = res.with_element_id(t);
                }
                Ok(res)
            })
            .await
    }

    async fn set_value(&self, target: &str, value: &str) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        let target_str = target.to_string();
        let val_str = value.to_string();
        self.bridge
            .run_on_ui(move || {
                let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = comp.window();
                let selector = ElementSelector::parse(&target_str);
                let item = find_accessible_item_in_window(window, &selector)
                    .ok_or_else(|| AgentError::element_not_found(&target_str, "Element not present in UI tree"))?;

                let id = item.accessible_string_property(AccessibleStringProperty::Id)
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| target_str.clone());

                if item.supported_accessibility_actions().contains(SupportedAccessibilityAction::SetValue) {
                    item.accessible_action(&AccessibilityAction::SetValue(SharedString::from(val_str.as_str())));
                    Ok(ActionResult::success(format!("Set value '{}' on '{}'", val_str, id))
                        .with_element_id(id)
                        .with_value(serde_json::json!(val_str)))
                } else {
                    // Fallback to pointer click + synthetic key typing
                    let geom = item.geometry();
                    let abs_origin = item.map_to_native_window(geom.origin);
                    let center_x = abs_origin.x + geom.size.width / 2.0;
                    let center_y = abs_origin.y + geom.size.height / 2.0;
                    let pos = LogicalPosition::new(center_x, center_y);

                    window.dispatch_event(slint::platform::WindowEvent::PointerMoved { position: pos });
                    window.dispatch_event(slint::platform::WindowEvent::PointerPressed {
                        position: pos,
                        button: slint::platform::PointerEventButton::Left,
                    });
                    window.dispatch_event(slint::platform::WindowEvent::PointerReleased {
                        position: pos,
                        button: slint::platform::PointerEventButton::Left,
                    });

                    for ch in val_str.chars() {
                        let s: SharedString = ch.to_string().into();
                        window.dispatch_event(slint::platform::WindowEvent::KeyPressed { text: s.clone() });
                        window.dispatch_event(slint::platform::WindowEvent::KeyReleased { text: s });
                    }

                    Ok(ActionResult::success(format!("Set value via synthetic input on '{}'", id))
                        .with_element_id(id)
                        .with_value(serde_json::json!(val_str)))
                }
            })
            .await
    }

    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        self.toggle_element_state(target, None).await
    }

    async fn toggle_element_state(
        &self,
        target: &str,
        desired_state: Option<bool>,
    ) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        let target_str = target.to_string();
        self.bridge
            .run_on_ui(move || {
                let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = comp.window();
                let selector = ElementSelector::parse(&target_str);
                let item = find_accessible_item_in_window(window, &selector)
                    .ok_or_else(|| AgentError::element_not_found(&target_str, "Element not present in UI tree"))?;

                let id = item.accessible_string_property(AccessibleStringProperty::Id)
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| target_str.clone());

                if let Some(target_val) = desired_state {
                    let current_checked = item.accessible_string_property(AccessibleStringProperty::Checked)
                        .map(|s| s.as_str() == "true")
                        .unwrap_or(false);
                    if current_checked == target_val {
                        return Ok(ActionResult::success(format!("'{}' already in desired state {}", id, target_val))
                            .with_element_id(id)
                            .with_value(serde_json::json!(target_val)));
                    }
                }

                if item.supported_accessibility_actions().contains(SupportedAccessibilityAction::Default) {
                    item.accessible_action(&AccessibilityAction::Default);
                    Ok(ActionResult::success(format!("Toggled '{}'", id)).with_element_id(id))
                } else {
                    let geom = item.geometry();
                    let abs_origin = item.map_to_native_window(geom.origin);
                    let center_x = abs_origin.x + geom.size.width / 2.0;
                    let center_y = abs_origin.y + geom.size.height / 2.0;
                    let pos = LogicalPosition::new(center_x, center_y);

                    window.dispatch_event(slint::platform::WindowEvent::PointerMoved { position: pos });
                    window.dispatch_event(slint::platform::WindowEvent::PointerPressed {
                        position: pos,
                        button: slint::platform::PointerEventButton::Left,
                    });
                    window.dispatch_event(slint::platform::WindowEvent::PointerReleased {
                        position: pos,
                        button: slint::platform::PointerEventButton::Left,
                    });

                    Ok(ActionResult::success(format!("Toggled '{}' via synthetic pointer", id)).with_element_id(id))
                }
            })
            .await
    }

    async fn perform_action(
        &self,
        target: &str,
        action: &dyn McpAction,
    ) -> Result<ActionResult, AgentError> {
        let name = action.action_name();
        match name {
            "click" => self.click_element(target).await,
            "set_value" => {
                let val = action.payload().get("value").and_then(|v| v.as_str()).unwrap_or("").to_string();
                self.set_value(target, &val).await
            }
            "send_keys" => {
                let payload = action.payload();
                let text = payload.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let clear_before = payload.get("clear_before").and_then(|v| v.as_bool()).unwrap_or(false);
                if clear_before {
                    let _ = self.set_value(target, "").await;
                }
                self.send_keys(Some(target), &text).await
            }
            "toggle" => {
                let payload = action.payload();
                let state = payload.get("state").and_then(|v| v.as_bool());
                self.toggle_element_state(target, state).await
            }
            "step" => {
                let weak = self.weak.clone();
                let target_str = target.to_string();
                let delta = action.payload().get("delta").and_then(|d| d.as_f64()).unwrap_or(1.0);
                self.bridge
                    .run_on_ui(move || {
                        let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                        let window = comp.window();
                        let selector = ElementSelector::parse(&target_str);
                        let item = find_accessible_item_in_window(window, &selector)
                            .ok_or_else(|| AgentError::element_not_found(&target_str, "Element not present in UI tree"))?;

                        if delta > 0.0 {
                            item.accessible_action(&AccessibilityAction::Increment);
                        } else {
                            item.accessible_action(&AccessibilityAction::Decrement);
                        }

                        let id = item.accessible_string_property(AccessibleStringProperty::Id)
                            .map(|s| s.to_string())
                            .unwrap_or(target_str);

                        Ok(ActionResult::success(format!("Stepped '{}' by {}", id, delta)).with_element_id(id))
                    })
                    .await
            }
            "expand" => {
                let weak = self.weak.clone();
                let target_str = target.to_string();
                let payload = action.payload();
                let desired_expanded = payload.get("expanded").and_then(|v| v.as_bool());
                self.bridge
                    .run_on_ui(move || {
                        let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                        let window = comp.window();
                        let selector = ElementSelector::parse(&target_str);
                        let item = find_accessible_item_in_window(window, &selector)
                            .ok_or_else(|| AgentError::element_not_found(&target_str, "Element not present in UI tree"))?;

                        let id = item.accessible_string_property(AccessibleStringProperty::Id)
                            .map(|s| s.to_string())
                            .unwrap_or(target_str);

                        if let Some(target_exp) = desired_expanded {
                            let current_exp = item.accessible_string_property(AccessibleStringProperty::Expanded)
                                .map(|s| s.as_str() == "true");
                            if current_exp == Some(target_exp) {
                                return Ok(ActionResult::success(format!("'{}' already expanded={}", id, target_exp)).with_element_id(id));
                            }
                        }

                        if item.supported_accessibility_actions().contains(SupportedAccessibilityAction::Expand) {
                            item.accessible_action(&AccessibilityAction::Expand);
                            Ok(ActionResult::success(format!("Expanded/collapsed '{}'", id)).with_element_id(id))
                        } else if item.supported_accessibility_actions().contains(SupportedAccessibilityAction::Default) {
                            item.accessible_action(&AccessibilityAction::Default);
                            Ok(ActionResult::success(format!("Toggled expansion of '{}'", id)).with_element_id(id))
                        } else {
                            let geom = item.geometry();
                            let abs_origin = item.map_to_native_window(geom.origin);
                            let center_x = abs_origin.x + geom.size.width / 2.0;
                            let center_y = abs_origin.y + geom.size.height / 2.0;
                            let pos = LogicalPosition::new(center_x, center_y);

                            window.dispatch_event(slint::platform::WindowEvent::PointerMoved { position: pos });
                            window.dispatch_event(slint::platform::WindowEvent::PointerPressed {
                                position: pos,
                                button: slint::platform::PointerEventButton::Left,
                            });
                            window.dispatch_event(slint::platform::WindowEvent::PointerReleased {
                                position: pos,
                                button: slint::platform::PointerEventButton::Left,
                            });

                            Ok(ActionResult::success(format!("Toggled expansion of '{}' via pointer", id)).with_element_id(id))
                        }
                    })
                    .await
            }
            "dismiss" => self.click_element(target).await,
            "select_option" => {
                let weak = self.weak.clone();
                let target_str = target.to_string();
                let payload = action.payload();
                let maybe_val = payload.get("value").and_then(|v| v.as_str()).map(|s| s.to_string());
                let maybe_idx = payload.get("index").and_then(|v| v.as_u64()).map(|i| i as usize);

                self.bridge
                    .run_on_ui(move || {
                        let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                        let window = comp.window();

                        // 1. If value is provided, try direct selector lookup first
                        if let Some(ref val) = maybe_val {
                            let direct_sel = ElementSelector::parse(val);
                            if let Some(item) = find_accessible_item_in_window(window, &direct_sel) {
                                if item.supported_accessibility_actions().contains(SupportedAccessibilityAction::Default) {
                                    item.accessible_action(&AccessibilityAction::Default);
                                    return Ok(ActionResult::success(format!("Selected option '{}'", val)).with_element_id(val));
                                }
                            }
                        }

                        // 2. Find parent container
                        let selector = ElementSelector::parse(&target_str);
                        let parent = find_accessible_item_in_window(window, &selector)
                            .ok_or_else(|| AgentError::element_not_found(&target_str, "Container element not found in UI tree"))?;

                        let children: Vec<ItemRc> = accessible_descendents(&parent)
                            .filter(|item| item.accessible_role() != AccessibleRole::None)
                            .collect();

                        let target_item = if let Some(ref val) = maybe_val {
                            children.into_iter().find(|c| {
                                c.accessible_string_property(AccessibleStringProperty::Id).map(|s| s.as_str() == val).unwrap_or(false)
                                || c.accessible_string_property(AccessibleStringProperty::Label).map(|s| s.as_str() == val).unwrap_or(false)
                            })
                        } else if let Some(idx) = maybe_idx {
                            children.into_iter().nth(idx)
                        } else {
                            None
                        };

                        if let Some(item) = target_item {
                            let id = item.accessible_string_property(AccessibleStringProperty::Id)
                                .map(|s| s.to_string())
                                .unwrap_or_else(|| format!("{}_option", target_str));
                            item.accessible_action(&AccessibilityAction::Default);
                            Ok(ActionResult::success(format!("Selected option '{}'", id)).with_element_id(id))
                        } else {
                            Err(AgentError::element_not_found(&target_str, "Matching option not found in container"))
                        }
                    })
                    .await
            }
            "select_row" => {
                let weak = self.weak.clone();
                let target_str = target.to_string();
                let payload = action.payload();
                let maybe_row_id = payload.get("row_id").and_then(|v| v.as_str()).map(|s| s.to_string());
                let maybe_row_idx = payload.get("row_index").and_then(|v| v.as_u64()).map(|i| i as usize);

                self.bridge
                    .run_on_ui(move || {
                        let comp = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                        let window = comp.window();

                        // 1. If row_id is provided, try direct find first
                        if let Some(ref r_id) = maybe_row_id {
                            let direct_sel = ElementSelector::parse(r_id);
                            if let Some(item) = find_accessible_item_in_window(window, &direct_sel) {
                                item.accessible_action(&AccessibilityAction::Default);
                                return Ok(ActionResult::success(format!("Selected row '{}'", r_id)).with_element_id(r_id));
                            }
                        }

                        // 2. Search in table element
                        let selector = ElementSelector::parse(&target_str);
                        let table_item = find_accessible_item_in_window(window, &selector)
                            .ok_or_else(|| AgentError::element_not_found(&target_str, "Table element not found in UI tree"))?;

                        let rows: Vec<ItemRc> = accessible_descendents(&table_item)
                            .filter(|item| item.accessible_role() == AccessibleRole::ListItem)
                            .collect();

                        let target_row = if let Some(ref r_id) = maybe_row_id {
                            rows.into_iter().find(|r| {
                                r.accessible_string_property(AccessibleStringProperty::Id).map(|s| s.as_str() == r_id).unwrap_or(false)
                                || r.accessible_string_property(AccessibleStringProperty::Label).map(|s| s.as_str() == r_id).unwrap_or(false)
                            })
                        } else if let Some(idx) = maybe_row_idx {
                            rows.into_iter().nth(idx)
                        } else {
                            None
                        };

                        if let Some(row) = target_row {
                            let id = row.accessible_string_property(AccessibleStringProperty::Id)
                                .map(|s| s.to_string())
                                .unwrap_or_else(|| format!("{}_row", target_str));
                            row.accessible_action(&AccessibilityAction::Default);
                            Ok(ActionResult::success(format!("Selected row '{}'", id)).with_element_id(id))
                        } else {
                            Err(AgentError::element_not_found(&target_str, "Specified table row not found in table"))
                        }
                    })
                    .await
            }
            other => Err(AgentError::invalid_operation(format!(
                "Action '{}' not supported on target '{}'",
                other, target
            ))),
        }
    }
}
