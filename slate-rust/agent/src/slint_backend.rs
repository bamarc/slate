//! Fully dynamic Slint window automation backend.
//!
//! Provides live UI tree introspection, native element interaction,
//! screenshot capture, and state extraction directly from any running Slint window.

use std::collections::HashMap;
use std::sync::Arc;
use image::ImageEncoder;
use slint::ComponentHandle;

use i_slint_core::accessibility::{AccessibilityAction, AccessibleStringProperty};
use i_slint_core::api::LogicalPosition;
use i_slint_core::item_tree::{visit_items, ItemVisitorResult, TraversalOrder};
use i_slint_core::items::{AccessibleRole, ItemRc};
use i_slint_core::platform::{PointerEventButton, WindowEvent};
use i_slint_core::window::WindowInner;

use crate::bridge::SlintUiBridge;
use crate::error::AgentError;
use crate::model::{
    ActionResult, AppState, DiagnosticMetrics, MouseButton, Point, Rect, Screenshot,
    UiElementNode, UiTree,
};
use crate::traits::{ElementController, StateProvider, UiInspector, VisualRenderer};

/// Helper holding an inspected node during recursive tree reconstruction.
struct RawNode {
    node: UiElementNode,
    children_indices: Vec<usize>,
    item_rc: ItemRc,
}

/// Inspects a single `ItemRc` and converts it into a `UiElementNode`.
fn inspect_single_item(
    item: &ItemRc,
    window_inner: &WindowInner,
    counter: &mut usize,
) -> UiElementNode {
    *counter += 1;
    let idx = *counter;

    // 1. Accessible Role
    let role_enum = item.accessible_role();
    let role_str = match role_enum {
        AccessibleRole::None => "none".to_string(),
        AccessibleRole::Button => "button".to_string(),
        AccessibleRole::Checkbox => "checkbox".to_string(),
        AccessibleRole::Combobox => "combobox".to_string(),
        AccessibleRole::Groupbox => "groupbox".to_string(),
        AccessibleRole::Image => "image".to_string(),
        AccessibleRole::List => "list".to_string(),
        AccessibleRole::Slider => "slider".to_string(),
        AccessibleRole::Spinbox => "spinbox".to_string(),
        AccessibleRole::Tab => "tab".to_string(),
        AccessibleRole::TabList => "tablist".to_string(),
        AccessibleRole::TabPanel => "tabpanel".to_string(),
        AccessibleRole::Text => "text".to_string(),
        AccessibleRole::Table => "table".to_string(),
        AccessibleRole::Tree => "tree".to_string(),
        AccessibleRole::ProgressIndicator => "progress".to_string(),
        AccessibleRole::TextInput => "textbox".to_string(),
        AccessibleRole::Switch => "switch".to_string(),
        AccessibleRole::ListItem => "listitem".to_string(),
        AccessibleRole::RadioButton => "radio".to_string(),
        AccessibleRole::RadioGroup => "radiogroup".to_string(),
        _ => format!("{:?}", role_enum).to_lowercase(),
    };

    // 2. Label & Properties
    let label = item
        .accessible_string_property(AccessibleStringProperty::Label)
        .map(|s| s.to_string())
        .or_else(|| {
            item.accessible_string_property(AccessibleStringProperty::PlaceholderText)
                .map(|s| s.to_string())
        });

    let mut properties = HashMap::new();

    if let Some(val) = item.accessible_string_property(AccessibleStringProperty::Value) {
        properties.insert("value".to_string(), serde_json::Value::String(val.to_string()));
    }
    if let Some(checked) = item.accessible_string_property(AccessibleStringProperty::Checked) {
        let is_checked = checked.as_str() == "true";
        properties.insert("checked".to_string(), serde_json::Value::Bool(is_checked));
    }
    if let Some(placeholder) =
        item.accessible_string_property(AccessibleStringProperty::PlaceholderText)
    {
        properties.insert(
            "placeholder".to_string(),
            serde_json::Value::String(placeholder.to_string()),
        );
    }
    if let Some(desc) = item.accessible_string_property(AccessibleStringProperty::Description) {
        properties.insert(
            "description".to_string(),
            serde_json::Value::String(desc.to_string()),
        );
    }
    if let Some(min) = item.accessible_string_property(AccessibleStringProperty::ValueMinimum) {
        if let Ok(num) = min.as_str().parse::<f64>() {
            properties.insert("min".to_string(), serde_json::json!(num));
        }
    }
    if let Some(max) = item.accessible_string_property(AccessibleStringProperty::ValueMaximum) {
        if let Ok(num) = max.as_str().parse::<f64>() {
            properties.insert("max".to_string(), serde_json::json!(num));
        }
    }
    if let Some(step) = item.accessible_string_property(AccessibleStringProperty::ValueStep) {
        if let Ok(num) = step.as_str().parse::<f64>() {
            properties.insert("step".to_string(), serde_json::json!(num));
        }
    }

    let enabled = item
        .accessible_string_property(AccessibleStringProperty::Enabled)
        .map(|s| s.as_str() == "true")
        .unwrap_or(true);

    let focused = window_inner
        .focus_item
        .borrow()
        .upgrade()
        .map(|f| f == *item)
        .unwrap_or(false);

    let visible = item.is_visible();

    // 3. Geometry & Absolute Bounds
    let geom = item.geometry();
    let abs_origin = item.map_to_window(geom.origin);
    let bounds = Rect::new(abs_origin.x, abs_origin.y, geom.size.width, geom.size.height);

    // 4. Element Type Name & ID
    let mut explicit_type_name = None;
    let mut explicit_id = None;

    if let Some(debug_infos) = item.element_type_names_and_ids(0) {
        for (t_name, id) in debug_infos {
            let t_str = t_name.to_string();
            let id_str = id.to_string();
            if explicit_type_name.is_none() && !t_str.is_empty() {
                explicit_type_name = Some(t_str);
            }
            if explicit_id.is_none() && !id_str.is_empty() {
                explicit_id = Some(id_str);
            }
        }
    }

    if let Some(acc_id) = item.accessible_string_property(AccessibleStringProperty::Id) {
        let acc_id_str = acc_id.to_string();
        if !acc_id_str.is_empty() {
            explicit_id = Some(acc_id_str);
        }
    }

    let type_name = explicit_type_name.unwrap_or_else(|| {
        if role_str != "none" {
            let mut c = role_str.chars();
            match c.next() {
                None => "Element".to_string(),
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
            }
        } else {
            "Element".to_string()
        }
    });

    let id = explicit_id.unwrap_or_else(|| {
        if let Some(lbl) = &label {
            let sanitized: String = lbl
                .chars()
                .map(|c| if c.is_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
                .collect();
            let clean = sanitized.trim_matches('_');
            if !clean.is_empty() {
                return clean.to_string();
            }
        }
        format!("{}_{}", type_name.to_lowercase(), idx)
    });

    let value = item
        .accessible_string_property(AccessibleStringProperty::Value)
        .map(|s| s.to_string())
        .or_else(|| {
            item.accessible_string_property(AccessibleStringProperty::Checked)
                .map(|s| s.to_string())
        });

    UiElementNode {
        id,
        type_name,
        bounds,
        label,
        role: role_str,
        value,
        enabled,
        focused,
        visible,
        children: Vec::new(),
        properties,
    }
}

/// Helper function to traverse an item tree and build the collection of RawNodes.
fn collect_item_tree(
    item_tree: &i_slint_core::item_tree::ItemTreeRc,
    window_inner: &WindowInner,
    all_nodes: &mut Vec<RawNode>,
    counter: &mut usize,
    parent_index: Option<usize>,
) {
    visit_items(
        item_tree,
        TraversalOrder::BackToFront,
        |sub_tree, _pin, index, parent_idx| {
            let item_rc = ItemRc::new(sub_tree.clone(), index);
            let ui_node = inspect_single_item(&item_rc, window_inner, counter);
            let my_idx = all_nodes.len();

            all_nodes.push(RawNode {
                node: ui_node,
                children_indices: Vec::new(),
                item_rc,
            });

            if let Some(p) = *parent_idx {
                all_nodes[p].children_indices.push(my_idx);
            }

            ItemVisitorResult::Continue(Some(my_idx))
        },
        parent_index,
    );
}

/// Recursively assemble `RawNode`s into a nested `UiElementNode`.
fn assemble_tree(idx: usize, all_nodes: &mut [Option<RawNode>]) -> UiElementNode {
    let mut raw = all_nodes[idx].take().expect("Valid node index");
    let children_indices = std::mem::take(&mut raw.children_indices);
    for child_idx in children_indices {
        raw.node.children.push(assemble_tree(child_idx, all_nodes));
    }
    raw.node
}

/// Fully dynamic UI tree inspector attached to any Slint application window.
pub struct SlintWindowInspector<T: ComponentHandle + 'static> {
    weak: slint::Weak<T>,
    bridge: Arc<SlintUiBridge>,
}

impl<T: ComponentHandle + 'static> SlintWindowInspector<T> {
    pub fn new(weak: slint::Weak<T>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl<T: ComponentHandle + 'static> UiInspector for SlintWindowInspector<T> {
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        let weak = self.weak.clone();
        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = win.window();
                let window_inner = WindowInner::from_pub(window);
                window_inner.ensure_tree_instantiated();

                let win_size = window.size();
                let title = window_inner
                    .window_item()
                    .map(|w| w.as_pin_ref().title().to_string())
                    .unwrap_or_else(|| "Slate Window".to_string());

                let mut all_nodes = Vec::new();
                let mut counter = 0;

                // 1. Root window component tree
                let component = window_inner.component();
                collect_item_tree(&component, &window_inner, &mut all_nodes, &mut counter, None);

                // 2. Active popups (dialogs, menus, popovers, combo boxes)
                let active_popups = window_inner.active_popups();
                for popup in active_popups.iter() {
                    collect_item_tree(&popup.component, &window_inner, &mut all_nodes, &mut counter, Some(0));
                }

                if all_nodes.is_empty() {
                    let root = UiElementNode {
                        id: "root_window".to_string(),
                        type_name: "Window".to_string(),
                        bounds: Rect::new(0.0, 0.0, win_size.width as f32, win_size.height as f32),
                        label: Some(title.clone()),
                        role: "window".to_string(),
                        value: None,
                        enabled: true,
                        focused: true,
                        visible: true,
                        children: Vec::new(),
                        properties: HashMap::new(),
                    };
                    return Ok(UiTree::new(root).with_window_info(
                        title,
                        win_size.width as f32,
                        win_size.height as f32,
                    ));
                }

                // If root element is not a full window wrapper, ensure bounds cover window
                let mut wrapped_nodes: Vec<Option<RawNode>> = all_nodes.into_iter().map(Some).collect();
                let root_node = assemble_tree(0, &mut wrapped_nodes);

                Ok(UiTree::new(root_node).with_window_info(
                    title,
                    win_size.width as f32,
                    win_size.height as f32,
                ))
            })
            .await
    }
}

/// Fully dynamic controller for dispatching mouse and keyboard events to any Slint application window.
pub struct SlintWindowController<T: ComponentHandle + 'static> {
    weak: slint::Weak<T>,
    bridge: Arc<SlintUiBridge>,
}

impl<T: ComponentHandle + 'static> SlintWindowController<T> {
    pub fn new(weak: slint::Weak<T>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl<T: ComponentHandle + 'static> ElementController for SlintWindowController<T> {
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        let target_str = target.to_string();

        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = win.window();
                let window_inner = WindowInner::from_pub(window);
                window_inner.ensure_tree_instantiated();

                let mut all_nodes = Vec::new();
                let mut counter = 0;
                let component = window_inner.component();
                collect_item_tree(&component, &window_inner, &mut all_nodes, &mut counter, None);

                let active_popups = window_inner.active_popups();
                for popup in active_popups.iter() {
                    collect_item_tree(&popup.component, &window_inner, &mut all_nodes, &mut counter, Some(0));
                }

                // Find candidate matching target:
                // Prioritize:
                // 1. Exact ID match (visible first)
                // 2. Exact label match (case-insensitive, visible first)
                // 3. Substring match (visible first)
                let target_lower = target_str.to_lowercase();

                let mut matches: Vec<&RawNode> = all_nodes
                    .iter()
                    .filter(|n| {
                        let id_exact = n.node.id == target_str;
                        let id_lower = n.node.id.to_lowercase() == target_lower;
                        let label_exact = n.node.label.as_deref() == Some(&target_str);
                        let label_lower = n
                            .node
                            .label
                            .as_ref()
                            .map(|l| l.to_lowercase() == target_lower)
                            .unwrap_or(false);
                        let label_substr = n
                            .node
                            .label
                            .as_ref()
                            .map(|l| l.to_lowercase().contains(&target_lower))
                            .unwrap_or(false);
                        let id_substr = n.node.id.to_lowercase().contains(&target_lower);

                        id_exact || id_lower || label_exact || label_lower || label_substr || id_substr
                    })
                    .collect();

                if matches.is_empty() {
                    return Err(AgentError::element_not_found(
                        &target_str,
                        "No matching element found in the live Slint UI tree",
                    ));
                }

                // Sort: visible first, exact matches first, non-zero dimensions first
                matches.sort_by(|a, b| {
                    let a_exact = a.node.id == target_str || a.node.label.as_deref() == Some(&target_str);
                    let b_exact = b.node.id == target_str || b.node.label.as_deref() == Some(&target_str);
                    b_exact.cmp(&a_exact)
                        .then_with(|| b.node.visible.cmp(&a.node.visible))
                        .then_with(|| {
                            let a_area = a.node.bounds.width * a.node.bounds.height;
                            let b_area = b.node.bounds.width * b.node.bounds.height;
                            b_area.partial_cmp(&a_area).unwrap_or(std::cmp::Ordering::Equal)
                        })
                });

                let best_match = matches[0];
                let cx = best_match.node.bounds.x + best_match.node.bounds.width / 2.0;
                let cy = best_match.node.bounds.y + best_match.node.bounds.height / 2.0;
                let pos = LogicalPosition::new(cx, cy);

                // Dispatch native pointer events simulating physical mouse click
                window.dispatch_event(WindowEvent::PointerMoved { position: pos });
                window.dispatch_event(WindowEvent::PointerPressed {
                    position: pos,
                    button: PointerEventButton::Left,
                });
                window.dispatch_event(WindowEvent::PointerReleased {
                    position: pos,
                    button: PointerEventButton::Left,
                });

                // In addition, if element declares an accessible default action, invoke it
                best_match.item_rc.accessible_action(&AccessibilityAction::Default);

                Ok(ActionResult::success(format!(
                    "Clicked '{}' (id: '{}') at ({:.1}, {:.1})",
                    best_match.node.label.as_deref().unwrap_or(&best_match.node.id),
                    best_match.node.id,
                    cx,
                    cy
                ))
                .with_element_id(&best_match.node.id))
            })
            .await
    }

    async fn click_at(&self, point: Point, button: MouseButton) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = win.window();
                let pos = LogicalPosition::new(point.x, point.y);
                let btn = match button {
                    MouseButton::Left => PointerEventButton::Left,
                    MouseButton::Right => PointerEventButton::Right,
                    MouseButton::Middle => PointerEventButton::Middle,
                };

                window.dispatch_event(WindowEvent::PointerMoved { position: pos });
                window.dispatch_event(WindowEvent::PointerPressed {
                    position: pos,
                    button: btn,
                });
                window.dispatch_event(WindowEvent::PointerReleased {
                    position: pos,
                    button: btn,
                });

                Ok(ActionResult::success(format!(
                    "Clicked at ({:.1}, {:.1}) with {:?}",
                    point.x, point.y, button
                )))
            })
            .await
    }

    async fn send_keys(&self, target: Option<&str>, text: &str) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        let target_owned = target.map(|s| s.to_string());
        let text_owned = text.to_string();

        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = win.window();

                // If target specified, focus it by clicking at its center or setting value
                if let Some(ref t) = target_owned {
                    let window_inner = WindowInner::from_pub(window);
                    window_inner.ensure_tree_instantiated();

                    let mut all_nodes = Vec::new();
                    let mut counter = 0;
                    let component = window_inner.component();
                    collect_item_tree(&component, &window_inner, &mut all_nodes, &mut counter, None);

                    let t_lower = t.to_lowercase();
                    if let Some(target_node) = all_nodes.iter().find(|n| {
                        n.node.id == *t
                            || n.node.id.to_lowercase() == t_lower
                            || n.node.label.as_deref() == Some(t.as_str())
                            || n.node.label.as_ref().map(|l| l.to_lowercase().contains(&t_lower)).unwrap_or(false)
                    }) {
                        let cx = target_node.node.bounds.x + target_node.node.bounds.width / 2.0;
                        let cy = target_node.node.bounds.y + target_node.node.bounds.height / 2.0;
                        let pos = LogicalPosition::new(cx, cy);

                        window.dispatch_event(WindowEvent::PointerMoved { position: pos });
                        window.dispatch_event(WindowEvent::PointerPressed {
                            position: pos,
                            button: PointerEventButton::Left,
                        });
                        window.dispatch_event(WindowEvent::PointerReleased {
                            position: pos,
                            button: PointerEventButton::Left,
                        });

                        // Try accessible SetValue first
                        target_node.item_rc.accessible_action(&AccessibilityAction::SetValue(
                            text_owned.clone().into(),
                        ));
                    }
                }

                // Dispatch key events to the window
                window.dispatch_event(WindowEvent::KeyPressed {
                    text: text_owned.clone().into(),
                });
                window.dispatch_event(WindowEvent::KeyReleased {
                    text: text_owned.clone().into(),
                });

                let mut res = ActionResult::success(format!("Sent keys '{}'", text_owned));
                if let Some(t) = target_owned {
                    res = res.with_element_id(t);
                }
                Ok(res)
            })
            .await
    }

    async fn set_value(&self, target: &str, value: &str) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        let target_str = target.to_string();
        let value_str = value.to_string();

        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = win.window();
                let window_inner = WindowInner::from_pub(window);
                window_inner.ensure_tree_instantiated();

                let mut all_nodes = Vec::new();
                let mut counter = 0;
                let component = window_inner.component();
                collect_item_tree(&component, &window_inner, &mut all_nodes, &mut counter, None);

                let t_lower = target_str.to_lowercase();
                let matched = all_nodes.iter().find(|n| {
                    n.node.id == target_str
                        || n.node.id.to_lowercase() == t_lower
                        || n.node.label.as_deref() == Some(&target_str)
                        || n.node.label.as_ref().map(|l| l.to_lowercase().contains(&t_lower)).unwrap_or(false)
                });

                if let Some(best) = matched {
                    // 1. Click to focus
                    let cx = best.node.bounds.x + best.node.bounds.width / 2.0;
                    let cy = best.node.bounds.y + best.node.bounds.height / 2.0;
                    let pos = LogicalPosition::new(cx, cy);

                    window.dispatch_event(WindowEvent::PointerMoved { position: pos });
                    window.dispatch_event(WindowEvent::PointerPressed {
                        position: pos,
                        button: PointerEventButton::Left,
                    });
                    window.dispatch_event(WindowEvent::PointerReleased {
                        position: pos,
                        button: PointerEventButton::Left,
                    });

                    // 2. Set value via accessible action
                    best.item_rc.accessible_action(&AccessibilityAction::SetValue(value_str.clone().into()));

                    // 3. Also dispatch KeyPressed for UI that handles direct key input
                    window.dispatch_event(WindowEvent::KeyPressed {
                        text: value_str.clone().into(),
                    });
                    window.dispatch_event(WindowEvent::KeyReleased {
                        text: value_str.clone().into(),
                    });

                    Ok(ActionResult::success(format!("Set value '{}' on '{}'", value_str, target_str))
                        .with_element_id(&target_str)
                        .with_value(serde_json::json!(value_str)))
                } else {
                    Err(AgentError::element_not_found(
                        &target_str,
                        "Target element not found in UI tree",
                    ))
                }
            })
            .await
    }

    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        self.click_element(target).await
    }
}

/// Fully dynamic visual renderer capturing live Slint window frames using `window.take_snapshot()`.
pub struct SlintWindowRenderer<T: ComponentHandle + 'static> {
    weak: slint::Weak<T>,
    bridge: Arc<SlintUiBridge>,
}

impl<T: ComponentHandle + 'static> SlintWindowRenderer<T> {
    pub fn new(weak: slint::Weak<T>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl<T: ComponentHandle + 'static> VisualRenderer for SlintWindowRenderer<T> {
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError> {
        let weak = self.weak.clone();

        let (width, height, raw_bytes) = self
            .bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                slint::platform::update_timers_and_animations();
                let window = win.window();
                let pixel_buffer = window
                    .take_snapshot()
                    .map_err(|e| AgentError::render_error(e.to_string()))?;
                let width = pixel_buffer.width();
                let height = pixel_buffer.height();
                let raw_bytes = pixel_buffer.as_bytes().to_vec();

                Ok((width, height, raw_bytes))
            })
            .await?;

        tokio::task::spawn_blocking(move || {
            let mut png_bytes = Vec::new();
            image::codecs::png::PngEncoder::new(&mut png_bytes)
                .write_image(&raw_bytes, width, height, image::ExtendedColorType::Rgba8)
                .map_err(|e| AgentError::render_error(e.to_string()))?;

            Ok(Screenshot::new(width, height, "png", png_bytes))
        })
        .await
        .map_err(|e| AgentError::render_error(e.to_string()))?
    }

    async fn get_viewport_size(&self) -> Result<(u32, u32), AgentError> {
        let weak = self.weak.clone();
        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let size = win.window().size();
                Ok((size.width, size.height))
            })
            .await
    }
}

/// Dynamic application state provider reading live window properties and metrics.
pub struct SlintWindowStateProvider<T: ComponentHandle + 'static> {
    weak: slint::Weak<T>,
    bridge: Arc<SlintUiBridge>,
}

impl<T: ComponentHandle + 'static> SlintWindowStateProvider<T> {
    pub fn new(weak: slint::Weak<T>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl<T: ComponentHandle + 'static> StateProvider for SlintWindowStateProvider<T> {
    async fn get_state(&self, query: Option<&str>) -> Result<AppState, AgentError> {
        let weak = self.weak.clone();
        let query_owned = query.map(|q| q.to_string());

        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = win.window();
                let window_inner = WindowInner::from_pub(window);
                let title = window_inner
                    .window_item()
                    .map(|w| w.as_pin_ref().title().to_string())
                    .unwrap_or_else(|| "Slate Window".to_string());
                let size = window.size();

                let mut state = AppState::new(title.clone())
                    .with_property("window_title", serde_json::json!(title))
                    .with_property("width", serde_json::json!(size.width))
                    .with_property("height", serde_json::json!(size.height));

                if let Some(ref q) = query_owned {
                    state = state.with_property("query", serde_json::json!(q));
                }

                Ok(state)
            })
            .await
    }

    async fn get_diagnostics(&self) -> Result<DiagnosticMetrics, AgentError> {
        Ok(DiagnosticMetrics::default())
    }

    async fn set_property(&self, _key: &str, _value: serde_json::Value) -> Result<(), AgentError> {
        Ok(())
    }
}
