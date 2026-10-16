//! Fully dynamic Slint window automation backend.
//!
//! Provides live UI tree introspection, native element interaction,
//! screenshot capture, and state extraction directly from any running Slint window.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use image::ImageEncoder;
use slint::ComponentHandle;

// Phase 2 (D1): Slint-first targeting via the 1.18 ElementHandle query pipeline.
// Only the query types are used in production; the mock-time testing backend is
// never installed outside tests.
use i_slint_backend_testing::{ElementHandle, ElementQuery};

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

    // 4. Element Type Name & ID (Phase 2/3, D3 identity contract)
    //
    // Fallback chain, strongest first:
    //   1. `accessible-id` — author-declared, stable across runs (Phase 3 adds
    //      these to every interactive Slate component in `ui/`).
    //   2. Slint debug ID (`one := TouchArea {...}`) — stable for a given
    //      build with debug info, but not an authoring contract.
    //   3. Label slug / `type_counter` — UNSTABLE last resort, flagged in
    //      `properties.id_stable = false` so consumers never treat these as
    //      durable references.
    let mut explicit_type_name = None;
    let mut debug_id = None;

    if let Some(debug_infos) = item.element_type_names_and_ids(0) {
        for (t_name, id) in debug_infos {
            let t_str = t_name.to_string();
            let id_str = id.to_string();
            if explicit_type_name.is_none() && !t_str.is_empty() {
                explicit_type_name = Some(t_str);
            }
            if debug_id.is_none() && !id_str.is_empty() {
                debug_id = Some(id_str);
            }
        }
    }

    let accessible_id = item
        .accessible_string_property(AccessibleStringProperty::Id)
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty());

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

    let (id, id_source, id_stable) = if let Some(acc) = accessible_id {
        (acc, "accessible-id", true)
    } else if let Some(dbg) = debug_id {
        (dbg, "debug-id", true)
    } else {
        let fallback = if let Some(lbl) = &label {
            let sanitized: String = lbl
                .chars()
                .map(|c| if c.is_alphanumeric() { c.to_ascii_lowercase() } else { '_' })
                .collect();
            let clean = sanitized.trim_matches('_');
            if !clean.is_empty() {
                clean.to_string()
            } else {
                format!("{}_{}", type_name.to_lowercase(), idx)
            }
        } else {
            format!("{}_{}", type_name.to_lowercase(), idx)
        };
        (fallback, "unstable-fallback", false)
    };

    properties.insert(
        "id_source".to_string(),
        serde_json::Value::String(id_source.to_string()),
    );
    properties.insert(
        "id_stable".to_string(),
        serde_json::Value::Bool(id_stable),
    );
    properties.insert(
        "supported_actions".to_string(),
        serde_json::Value::Array(
            role_supported_actions(&role_str)
                .iter()
                .map(|a| serde_json::Value::String(a.to_string()))
                .collect(),
        ),
    );

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

// --- Phase 1 (D2): single dispatch by role ---------------------------------
//
// Dispatch table (action x role -> path). Exactly one backend dispatch per
// call; the focus click below is pointer-only focus acquisition, never paired
// with a semantic action on the same element:
//
// | action               | semantic roles (*)             | other roles / positional |
// |----------------------|--------------------------------|--------------------------|
// | `click_element`      | accessible `Default` ONLY      | pointer trio ONLY        |
// | `toggle_element`     | accessible `Default` ONLY      | accessible `Default` ONLY (semantic path, never `click_element`) |
// | `send_keys`+target   | focus click + `SetValue` ONLY  | focus click + key events ONLY |
// | `send_keys` untarget | —                              | key events ONLY          |
// | `set_value`          | focus click if unfocused + `SetValue` ONLY | focus click if unfocused + `SetValue` ONLY |
// | `click_at`           | — (positional)                 | pointer trio ONLY        |
//
// (*) `has_semantic_action`: Button, Checkbox, Switch, Slider, Spinbox,
// Combobox, RadioButton, ListItem, Tab — elements with a semantic accessible
// action.
//
// EXCEPTION — Slider `click_element` takes the pointer path, not `Default`:
// `SlateSlider` exposes increment/decrement/set-value handlers but no
// `accessible-action-default`, so a semantic dispatch would be a silent no-op.
// Slider clicks drive the thumb/track pointer math until T5
// increment/decrement/set_value MCP tools land (`slider_pointer_exception`).
// `toggle_element` rejects sliders outright (`is_toggleable_role`).

/// Roles with a semantic accessible action: activation goes through
/// `accessible_action(Default)` ONLY, never synthetic pointer events.
///
/// Kept in sync with `role_supported_actions` (M1): RadioButton, ListItem and
/// Tab are included because the Slate components backing them (`SlateRadio`,
/// `SlateTable` rows, `SlateTabs` tabs) all define
/// `accessible-action-default` handlers — advertising "default" in the
/// inspector while dispatching pointer events would be a lie in either
/// direction.
fn has_semantic_action(role: AccessibleRole) -> bool {
    matches!(
        role,
        AccessibleRole::Button
            | AccessibleRole::Checkbox
            | AccessibleRole::Switch
            | AccessibleRole::Slider
            | AccessibleRole::Spinbox
            | AccessibleRole::Combobox
            | AccessibleRole::RadioButton
            | AccessibleRole::ListItem
            | AccessibleRole::Tab
    )
}

/// D2 slider exception: `click_element` on a Slider takes the pointer path.
/// See the dispatch-table note above.
fn slider_pointer_exception(role: AccessibleRole) -> bool {
    matches!(role, AccessibleRole::Slider)
}

/// Roles `toggle_element` accepts (B1 gate): the semantic-action set minus
/// `Slider`, which carries increment/decrement/set-value but no `Default`
/// handler — toggling it would be a silent no-op, so it is rejected with an
/// `invalid_operation` naming the alternatives instead.
fn is_toggleable_role(role: AccessibleRole) -> bool {
    has_semantic_action(role) && !slider_pointer_exception(role)
}

/// Roles accepting `set_value` (B3 gate): editable text plus sliders
/// (`SlateSlider` maps `accessible-action-set-value` onto its clamp+changed
/// path). Any other role is an `invalid_operation`, never a silent no-op
/// write.
fn is_value_role(role: AccessibleRole) -> bool {
    is_text_editable_role(role) || matches!(role, AccessibleRole::Slider)
}

/// Roles carrying editable text: `send_keys` with a target uses the `SetValue`
/// semantic write for these; all other targeted roles (and untargeted input)
/// use raw key events. Never both.
fn is_text_editable_role(role: AccessibleRole) -> bool {
    matches!(
        role,
        AccessibleRole::TextInput | AccessibleRole::Spinbox | AccessibleRole::Combobox
    )
}

/// Phase 2 (U1): supported semantic actions per inspector role string. The
/// inspector annotates every node (`properties.supported_actions`) so MCP
/// clients can choose a valid tool without probing. Kept in sync with the D2
/// dispatch table above: roles with a semantic accessible action list it;
/// every interactive role lists `focus` (pointer focus acquisition).
fn role_supported_actions(role: &str) -> &'static [&'static str] {
    match role {
        "button" | "checkbox" | "switch" | "radio" | "listitem" | "tab" => {
            &["default", "focus"]
        }
        "slider" | "spinbox" => &["increment", "decrement", "set-value", "focus"],
        "combobox" => &["expand", "default", "focus"],
        "textbox" => &["set-value", "focus"],
        _ => &[],
    }
}

/// Phase 2 (D1): opt-out of the Slint-first query path. When
/// `SLATE_MCP_LEGACY_WALK` is set to a non-empty, non-`"0"` value, targeting
/// skips the `ElementHandle` query pipeline and uses only the hand-rolled
/// `visit_items` walk. The walk itself is retained as the flagged fallback
/// until T2 goes green without it; full deletion is blocked on Slint 1.18
/// `ElementHandle` exposing focus/visibility state (needed by the inspector —
/// see the deviation note on `collect_all_nodes`).
fn legacy_walk_forced() -> bool {
    static FORCED: OnceLock<bool> = OnceLock::new();
    *FORCED.get_or_init(|| {
        std::env::var("SLATE_MCP_LEGACY_WALK")
            .map(|v| !v.is_empty() && v != "0")
            .unwrap_or(false)
    })
}

/// Phase 2 (D1/E1): Slint-first target resolution. Queries the live tree
/// through the `ElementHandle` pipeline for an exact `accessible-id` (then
/// debug-ID) match instead of label-substring search.
///
/// Returns `Ok(None)` when the legacy fallback is forced, nothing matches, or
/// the handle is stale (generation check via `is_valid`), letting callers
/// fall back to the walk. Returns `Err` when several elements claim the same
/// `accessible-id` — first-match-wins targeting would be silent misbehavior
/// there (plan W2). Debug-ID collisions across repeated component instances
/// are *not* an error (debug ids are per-template, not per-instance); the
/// first match wins and the inspector disambiguates them with a suffix.
///
/// Note: exact-match predicates are used instead of `ElementQuery::match_id`
/// because `match_id` normalizes `_` to `-`, which would miss slug-style ids.
/// The debug-id branch accepts the qualified form (`App::plain`, as reported
/// by the inspector) or the bare local suffix (`plain`); debug-id collisions
/// across repeated component instances keep first-match-wins (see below).
fn query_element<T: ComponentHandle + 'static>(
    win: &T,
    target: &str,
) -> Result<Option<ElementHandle>, AgentError> {
    if legacy_walk_forced() {
        return Ok(None);
    }
    let target_owned = target.to_string();
    let by_accessible_id = ElementQuery::from_root(win)
        .match_predicate(move |h: &ElementHandle| {
            h.accessible_id().as_deref() == Some(target_owned.as_str())
        })
        .find_all();
    let mut valid: Vec<ElementHandle> =
        by_accessible_id.into_iter().filter(|h| h.is_valid()).collect();
    match valid.len() {
        0 => {}
        1 => return Ok(valid.pop()),
        _ => {
            return Err(AgentError::invalid_operation(format!(
                "duplicate accessible-id '{target}' claimed by {} elements — \
                 assign a unique accessible-id to each interactive element",
                valid.len()
            )));
        }
    }
    let target_owned = target.to_string();
    Ok(ElementQuery::from_root(win)
        .match_predicate(move |h: &ElementHandle| {
            h.accessible_id().is_none()
                && h.id().is_some_and(|id| {
                    id.as_str() == target_owned
                        || id.as_str().rsplit("::").next() == Some(target_owned.as_str())
                })
        })
        .find_first()
        .filter(|h| h.is_valid()))
}

/// Phase 2/3 (W2): duplicate `accessible-id` detector. Returns the sorted
/// names of every author-declared (`id_source == "accessible-id"`) id claimed
/// by more than one node in a single window. Only declared ids are contract
/// violations: debug ids repeat across component instances by construction,
/// and label slugs coincide whenever two elements share a label — both are
/// disambiguated, not errors (see `disambiguate_unstable_ids`).
fn duplicate_accessible_ids(all_nodes: &[RawNode]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut dups = std::collections::BTreeSet::new();
    for n in all_nodes {
        let is_declared = n
            .node
            .properties
            .get("id_source")
            .and_then(|v| v.as_str())
            == Some("accessible-id");
        if is_declared && !n.node.id.is_empty() && !seen.insert(n.node.id.clone()) {
            dups.insert(n.node.id.clone());
        }
    }
    dups.into_iter().collect()
}

/// Phase 2/3 (U1): guarantee unique inspector ids without false errors.
/// Non-declared collisions (repeated debug ids, coincident label slugs) get a
/// deterministic `_2`, `_3`, … suffix in traversal order — stable across runs
/// because traversal order is deterministic — and keep their `id_source`
/// marking so consumers know which ids are durable references.
fn disambiguate_unstable_ids(all_nodes: &mut [RawNode]) {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for n in all_nodes.iter_mut() {
        if n.node.id.is_empty() {
            continue;
        }
        let is_declared = n
            .node
            .properties
            .get("id_source")
            .and_then(|v| v.as_str())
            == Some("accessible-id");
        if is_declared {
            continue;
        }
        let seen = counts.entry(n.node.id.clone()).or_insert(0);
        *seen += 1;
        if *seen > 1 {
            n.node.id = format!("{}_{}", n.node.id, seen);
        }
    }
}

/// Collect the live item tree (root component + active popups) into `RawNode`s.
fn collect_all_nodes(window_inner: &WindowInner) -> Vec<RawNode> {
    let mut all_nodes = Vec::new();
    let mut counter = 0;
    let component = window_inner.component();
    collect_item_tree(&component, window_inner, &mut all_nodes, &mut counter, None);

    let active_popups = window_inner.active_popups();
    for popup in active_popups.iter() {
        collect_item_tree(&popup.component, window_inner, &mut all_nodes, &mut counter, Some(0));
    }
    all_nodes
}

/// Shared target resolution for the controller: exact id, exact label
/// (case-insensitive), then substring — visible, exact, and larger matches
/// win. Returns the single best match.
fn find_best_match<'a>(all_nodes: &'a [RawNode], target: &str) -> Option<&'a RawNode> {
    let target_lower = target.to_lowercase();

    let mut matches: Vec<&'a RawNode> = all_nodes
        .iter()
        .filter(|n| {
            let id_exact = n.node.id == target;
            let id_lower = n.node.id.to_lowercase() == target_lower;
            let label_exact = n.node.label.as_deref() == Some(target);
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
        return None;
    }

    // Sort: visible first, exact matches first, non-zero dimensions first
    matches.sort_by(|a, b| {
        let a_exact = a.node.id == target || a.node.label.as_deref() == Some(target);
        let b_exact = b.node.id == target || b.node.label.as_deref() == Some(target);
        b_exact
            .cmp(&a_exact)
            .then_with(|| b.node.visible.cmp(&a.node.visible))
            .then_with(|| {
                let a_area = a.node.bounds.width * a.node.bounds.height;
                let b_area = b.node.bounds.width * b.node.bounds.height;
                b_area.partial_cmp(&a_area).unwrap_or(std::cmp::Ordering::Equal)
            })
    });

    Some(matches[0])
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

                // W2 duplicate detector (Phase 2/3): colliding *declared*
                // accessible-ids in one window are an inspection error naming
                // the offenders — never silently returned for
                // first-match-wins targeting. Non-declared collisions are
                // deterministically disambiguated instead (U1 uniqueness
                // without false errors on repeated components).
                let dups = duplicate_accessible_ids(&all_nodes);
                if !dups.is_empty() {
                    return Err(AgentError::invalid_operation(format!(
                        "duplicate accessible-id(s) in window '{}': [{}] — \
                         assign a unique accessible-id to each interactive element",
                        title,
                        dups.join(", ")
                    )));
                }
                disambiguate_unstable_ids(&mut all_nodes);

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

                // Slint-first targeting (Phase 2, D1/E1): exact accessible-id
                // via the ElementHandle query pipeline. Single dispatch by
                // role (D2) applies identically on this path — semantic roles
                // take accessible `Default` ONLY, others pointer trio ONLY.
                // Sliders are the documented exception: no `Default` handler
                // exists, so they take the pointer path (never a silent no-op).
                if let Some(handle) = query_element(&win, &target_str)? {
                    let id = handle
                        .accessible_id()
                        .or_else(|| handle.id())
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| target_str.clone());
                    let label = handle.accessible_label().map(|s| s.to_string());
                    let caption = label.as_deref().unwrap_or(&id);
                    let semantic = handle
                        .accessible_role()
                        .is_some_and(|r| has_semantic_action(r) && !slider_pointer_exception(r));
                    if semantic {
                        handle.invoke_accessible_default_action();
                        return Ok(ActionResult::success(format!(
                            "Clicked '{caption}' (id: '{id}') via accessible action"
                        ))
                        .with_element_id(&id)
                        .with_detail("resolution", serde_json::json!("element-query")));
                    }
                    let pos = handle.absolute_position();
                    let size = handle.size();
                    let center = LogicalPosition::new(
                        pos.x + size.width / 2.0,
                        pos.y + size.height / 2.0,
                    );
                    window.dispatch_event(WindowEvent::PointerMoved { position: center });
                    window.dispatch_event(WindowEvent::PointerPressed {
                        position: center,
                        button: PointerEventButton::Left,
                    });
                    window.dispatch_event(WindowEvent::PointerReleased {
                        position: center,
                        button: PointerEventButton::Left,
                    });
                    return Ok(ActionResult::success(format!(
                        "Clicked '{caption}' (id: '{id}') at ({:.1}, {:.1}) via pointer",
                        center.x, center.y
                    ))
                    .with_element_id(&id)
                    .with_detail("resolution", serde_json::json!("element-query")));
                }

                // Flagged fallback: hand-rolled walk (same D2 dispatch).
                let all_nodes = collect_all_nodes(&window_inner);
                let best_match = find_best_match(&all_nodes, &target_str).ok_or_else(|| {
                    AgentError::element_not_found(
                        &target_str,
                        "No matching element found in the live Slint UI tree",
                    )
                })?;

                let role = best_match.item_rc.accessible_role();
                let cx = best_match.node.bounds.x + best_match.node.bounds.width / 2.0;
                let cy = best_match.node.bounds.y + best_match.node.bounds.height / 2.0;

                // Single dispatch by role (D2): semantic roles take the
                // accessible `Default` path ONLY; everything else takes the
                // pointer path ONLY. Never both (previously both fired,
                // double-toggling switches/checkboxes into a visible no-op).
                // Sliders take the pointer path (documented D2 exception).
                if has_semantic_action(role) && !slider_pointer_exception(role) {
                    best_match.item_rc.accessible_action(&AccessibilityAction::Default);
                    Ok(ActionResult::success(format!(
                        "Clicked '{}' (id: '{}') via accessible action",
                        best_match.node.label.as_deref().unwrap_or(&best_match.node.id),
                        best_match.node.id,
                    ))
                    .with_element_id(&best_match.node.id)
                    .with_detail("resolution", serde_json::json!("legacy-walk")))
                } else {
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
                    Ok(ActionResult::success(format!(
                        "Clicked '{}' (id: '{}') at ({:.1}, {:.1}) via pointer",
                        best_match.node.label.as_deref().unwrap_or(&best_match.node.id),
                        best_match.node.id,
                        cx,
                        cy
                    ))
                    .with_element_id(&best_match.node.id)
                    .with_detail("resolution", serde_json::json!("legacy-walk")))
                }
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

                // Single dispatch by role (D2): a targeted send_keys performs a
                // single focus click, then EXACTLY ONE of:
                // - text-editable roles (TextInput/Spinbox/Combobox): semantic
                //   `SetValue` ONLY (no key events — the old triple dispatch
                //   sent click + SetValue + Key blob, double-applying input);
                // - any other targeted role: raw key events ONLY (no SetValue).
                // Untargeted input sends key events ONLY (no focus click, no
                // SetValue).
                if let Some(ref t) = target_owned {
                    let window_inner = WindowInner::from_pub(window);
                    window_inner.ensure_tree_instantiated();

                    // Slint-first targeting (Phase 2, D1/E1, B2): exact
                    // accessible-id via the ElementHandle query pipeline
                    // first — the same structure as click_element/toggle.
                    // The W2 duplicate-id error propagates via `?`, never
                    // first-match-wins.
                    if let Some(handle) = query_element(&win, t)? {
                        let editable = handle
                            .accessible_role()
                            .is_some_and(is_text_editable_role);
                        let id = handle
                            .accessible_id()
                            .or_else(|| handle.id())
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| t.clone());
                        // Focus acquisition: `ElementHandle` exposes no focus
                        // state in Slint 1.18, so the query path
                        // conservatively focus-clicks; the walk fallback
                        // below skips the click when the element already
                        // holds focus (M6).
                        let hpos = handle.absolute_position();
                        let hsize = handle.size();
                        let hcenter = LogicalPosition::new(
                            hpos.x + hsize.width / 2.0,
                            hpos.y + hsize.height / 2.0,
                        );
                        window.dispatch_event(WindowEvent::PointerMoved { position: hcenter });
                        window.dispatch_event(WindowEvent::PointerPressed {
                            position: hcenter,
                            button: PointerEventButton::Left,
                        });
                        window.dispatch_event(WindowEvent::PointerReleased {
                            position: hcenter,
                            button: PointerEventButton::Left,
                        });
                        if editable {
                            handle.set_accessible_value(text_owned.clone());
                        } else {
                            window.dispatch_event(WindowEvent::KeyPressed {
                                text: text_owned.clone().into(),
                            });
                            window.dispatch_event(WindowEvent::KeyReleased {
                                text: text_owned.clone().into(),
                            });
                        }
                        return Ok(ActionResult::success(format!("Sent keys '{}'", text_owned))
                            .with_element_id(&id)
                            .with_detail("resolution", serde_json::json!("element-query")));
                    }

                    // Flagged fallback: hand-rolled walk (same D2 dispatch).
                    let all_nodes = collect_all_nodes(&window_inner);
                    let target_node = find_best_match(&all_nodes, t).ok_or_else(|| {
                        AgentError::element_not_found(
                            t,
                            "Target element not found in UI tree",
                        )
                    })?;

                    // Focus acquisition only (M6): skip the pointer trio when
                    // the element already holds focus, mirroring `set_value`.
                    let already_focused = window_inner
                        .focus_item
                        .borrow()
                        .upgrade()
                        .map(|f| f == target_node.item_rc)
                        .unwrap_or(false);
                    if !already_focused {
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
                    }

                    if is_text_editable_role(target_node.item_rc.accessible_role()) {
                        target_node.item_rc.accessible_action(&AccessibilityAction::SetValue(
                            text_owned.clone().into(),
                        ));
                    } else {
                        window.dispatch_event(WindowEvent::KeyPressed {
                            text: text_owned.clone().into(),
                        });
                        window.dispatch_event(WindowEvent::KeyReleased {
                            text: text_owned.clone().into(),
                        });
                    }
                    return Ok(
                        ActionResult::success(format!("Sent keys '{}'", text_owned))
                            .with_element_id(&target_node.node.id)
                            .with_detail("resolution", serde_json::json!("legacy-walk")),
                    );
                } else {
                    // Dispatch key events to the window
                    window.dispatch_event(WindowEvent::KeyPressed {
                        text: text_owned.clone().into(),
                    });
                    window.dispatch_event(WindowEvent::KeyReleased {
                        text: text_owned.clone().into(),
                    });
                }

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

                // Slint-first targeting (Phase 2, D1/E1, B2): exact
                // accessible-id via the ElementHandle query pipeline first.
                // The W2 duplicate-id error propagates via `?`.
                //
                // Value gate (B3): only text/value roles accept `set_value`.
                // Anything else is an `invalid_operation` — never an
                // unconditional write to whatever the substring walk found.
                if let Some(handle) = query_element(&win, &target_str)? {
                    if !handle.accessible_role().is_some_and(is_value_role) {
                        return Err(AgentError::invalid_operation(format!(
                            "set_value target '{target_str}' does not accept a value \
                             (role: {}); set_value supports text inputs, \
                             spinbox/combobox editors, and sliders",
                            handle
                                .accessible_role()
                                .map(|r| format!("{r:?}"))
                                .unwrap_or_else(|| "unknown".to_string())
                        )));
                    }
                    // Single semantic write (D2): exactly one `SetValue`,
                    // no focus click, no key events. The handle write needs
                    // no focus acquisition.
                    handle.set_accessible_value(value_str.clone());
                    return Ok(ActionResult::success(format!(
                        "Set value '{}' on '{}'",
                        value_str, target_str
                    ))
                    .with_element_id(
                        &handle
                            .accessible_id()
                            .or_else(|| handle.id())
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| target_str.clone()),
                    )
                    .with_value(serde_json::json!(value_str))
                    .with_detail("resolution", serde_json::json!("element-query")));
                }

                // Flagged fallback: hand-rolled walk (same B3 gate + D2 write).
                let all_nodes = collect_all_nodes(&window_inner);
                let best = find_best_match(&all_nodes, &target_str).ok_or_else(|| {
                    AgentError::element_not_found(
                        &target_str,
                        "Target element not found in UI tree",
                    )
                })?;

                if !is_value_role(best.item_rc.accessible_role()) {
                    return Err(AgentError::invalid_operation(format!(
                        "set_value target '{target_str}' does not accept a value \
                         (role: {:?}); set_value supports text inputs, \
                         spinbox/combobox editors, and sliders",
                        best.item_rc.accessible_role()
                    )));
                }

                // Single semantic write (D2): the value change is EXACTLY ONE
                // `SetValue` accessible action. A pointer-only focus click is
                // issued solely when the element does not already hold focus
                // (focus acquisition, not activation); no KeyPressed/Released
                // pair follows — the old triple dispatch (click + SetValue +
                // keys) double-applied input on text fields.
                let already_focused = window_inner
                    .focus_item
                    .borrow()
                    .upgrade()
                    .map(|f| f == best.item_rc)
                    .unwrap_or(false);
                if !already_focused {
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
                }

                best.item_rc.accessible_action(&AccessibilityAction::SetValue(value_str.clone().into()));

                Ok(ActionResult::success(format!("Set value '{}' on '{}'", value_str, target_str))
                    .with_element_id(&target_str)
                    .with_value(serde_json::json!(value_str))
                    .with_detail("resolution", serde_json::json!("legacy-walk")))
            })
            .await
    }

    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        // Semantic path ONLY (D2): toggling is an accessible `Default` action,
        // never a pointer click. Delegating to `click_element` was wrong twice
        // over — it re-entered role dispatch and, before single-dispatch,
        // fired pointer + accessible together (double toggle = no-op).
        let weak = self.weak.clone();
        let target_str = target.to_string();

        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let window = win.window();
                let window_inner = WindowInner::from_pub(window);
                window_inner.ensure_tree_instantiated();

                // Slint-first targeting (Phase 2, D1): exact accessible-id via
                // the ElementHandle query pipeline, semantic path ONLY.
                //
                // Toggle gate (B1): only toggleable roles take the accessible
                // `Default` path. Anything else (text inputs, sliders, plain
                // containers, unknown roles) is an `invalid_operation` — a
                // blind `Default` there would be a silent no-op.
                if let Some(handle) = query_element(&win, &target_str)? {
                    if !handle.accessible_role().is_some_and(is_toggleable_role) {
                        return Err(AgentError::invalid_operation(format!(
                            "toggle_element target '{target_str}' is not toggleable \
                             (role: {}); toggle supports button/checkbox/switch/radio \
                             semantics — sliders have no toggle action (use \
                             click_element), text inputs take send_keys/set_value",
                            handle
                                .accessible_role()
                                .map(|r| format!("{r:?}"))
                                .unwrap_or_else(|| "unknown".to_string())
                        )));
                    }
                    handle.invoke_accessible_default_action();
                    let id = handle
                        .accessible_id()
                        .or_else(|| handle.id())
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| target_str.clone());
                    return Ok(ActionResult::success(format!(
                        "Toggled '{target_str}' via accessible action"
                    ))
                    .with_element_id(&id)
                    .with_detail("resolution", serde_json::json!("element-query")));
                }

                // Flagged fallback: hand-rolled walk, same semantic path +
                // same B1 gate.
                let all_nodes = collect_all_nodes(&window_inner);
                let best = find_best_match(&all_nodes, &target_str).ok_or_else(|| {
                    AgentError::element_not_found(
                        &target_str,
                        "Target element not found in UI tree",
                    )
                })?;

                if !is_toggleable_role(best.item_rc.accessible_role()) {
                    return Err(AgentError::invalid_operation(format!(
                        "toggle_element target '{target_str}' is not toggleable \
                         (role: {:?}); toggle supports button/checkbox/switch/radio \
                         semantics — sliders have no toggle action (use \
                         click_element), text inputs take send_keys/set_value",
                        best.item_rc.accessible_role()
                    )));
                }

                best.item_rc.accessible_action(&AccessibilityAction::Default);

                Ok(ActionResult::success(format!(
                    "Toggled '{}' via accessible action",
                    target_str
                ))
                .with_element_id(&best.node.id)
                .with_detail("resolution", serde_json::json!("legacy-walk")))
            })
            .await
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
