//! Extensible interaction architecture for UI elements and MCP actions.
//!
//! Provides the core [`Interactable`] and [`McpAction`] traits, alongside standard
//! action structures for clicking, typing, toggling, selecting, and stepping controls.

use std::any::Any;
use serde_json::Value;

use crate::error::AgentError;
use crate::model::{ActionResult, Rect, UiElementNode};

/// Extensible trait representing a user or automation action dispatched through MCP.
pub trait McpAction: Send + Sync + 'static {
    /// Return the canonical action name identifier (e.g. "click", "set_value").
    fn action_name(&self) -> &'static str;

    /// Return the action parameters serialized as JSON.
    fn payload(&self) -> Value;

    /// Downcast helper to access concrete action structs.
    fn as_any(&self) -> &dyn Any;
}

/// Unified trait implemented by accessible and interactable UI elements.
#[async_trait::async_trait]
pub trait Interactable: Send + Sync {
    /// Unique identifier or selector anchor for this element.
    fn id(&self) -> &str;

    /// Semantic accessible role (e.g. "button", "text-input", "switch", "slider").
    fn role(&self) -> &str;

    /// Human-readable label or text content.
    fn label(&self) -> Option<&str>;

    /// Current value of the element if stateful (e.g. text content, numeric value).
    fn value(&self) -> Option<Value>;

    /// Bounding rectangle in logical window coordinates.
    fn bounds(&self) -> Rect;

    /// Whether the element is currently enabled and can accept interactions.
    fn is_enabled(&self) -> bool;

    /// Whether the element is currently visible on screen.
    fn is_visible(&self) -> bool;

    /// List of standard action names supported by this element.
    fn supported_actions(&self) -> &[&'static str];

    /// Execute an action on this element.
    async fn perform_action(&self, action: &dyn McpAction) -> Result<ActionResult, AgentError>;

    /// Convert this element to a protocol-level `UiElementNode`.
    fn to_ui_element_node(&self) -> UiElementNode;
}

/// Concrete interactable element binding a snapshot [`UiElementNode`] to an [`ElementController`].
#[derive(Clone)]
pub struct DynamicInteractableElement {
    node: UiElementNode,
    controller: std::sync::Arc<dyn crate::traits::ElementController>,
    supported_actions: Vec<&'static str>,
}

impl DynamicInteractableElement {
    /// Create a new `DynamicInteractableElement` with automatically derived supported actions based on role.
    pub fn new(node: UiElementNode, controller: std::sync::Arc<dyn crate::traits::ElementController>) -> Self {
        let mut supported_actions = Vec::new();
        match node.role.as_str() {
            "button" => supported_actions.extend_from_slice(&["click"]),
            "text-input" => supported_actions.extend_from_slice(&["set_value", "send_keys", "click"]),
            "switch" | "checkbox" => supported_actions.extend_from_slice(&["toggle", "click"]),
            "slider" | "spinbox" => supported_actions.extend_from_slice(&["step", "set_value", "click"]),
            "tab" | "tab-list" => supported_actions.extend_from_slice(&["select_option", "click"]),
            "table" | "list-item" => supported_actions.extend_from_slice(&["select_row", "click"]),
            "groupbox" => supported_actions.extend_from_slice(&["expand", "click"]),
            _ => supported_actions.extend_from_slice(&["click"]),
        }
        Self {
            node,
            controller,
            supported_actions,
        }
    }

    /// Provide explicit supported action overrides.
    pub fn with_supported_actions(mut self, actions: Vec<&'static str>) -> Self {
        self.supported_actions = actions;
        self
    }
}

#[async_trait::async_trait]
impl Interactable for DynamicInteractableElement {
    fn id(&self) -> &str {
        &self.node.id
    }

    fn role(&self) -> &str {
        &self.node.role
    }

    fn label(&self) -> Option<&str> {
        self.node.label.as_deref()
    }

    fn value(&self) -> Option<Value> {
        self.node.value.as_ref().map(|v| Value::String(v.clone()))
    }

    fn bounds(&self) -> Rect {
        self.node.bounds
    }

    fn is_enabled(&self) -> bool {
        self.node.enabled
    }

    fn is_visible(&self) -> bool {
        self.node.visible
    }

    fn supported_actions(&self) -> &[&'static str] {
        &self.supported_actions
    }

    async fn perform_action(&self, action: &dyn McpAction) -> Result<ActionResult, AgentError> {
        self.controller.perform_action(&self.node.id, action).await
    }

    fn to_ui_element_node(&self) -> UiElementNode {
        self.node.clone()
    }
}

// ============================================================================
// Standard MCP Action Implementations
// ============================================================================

/// Action requesting a default click or activation on an interactive element.
#[derive(Debug, Clone, Copy, Default)]
pub struct ClickAction;

impl McpAction for ClickAction {
    fn action_name(&self) -> &'static str {
        "click"
    }

    fn payload(&self) -> Value {
        serde_json::json!({})
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// Action requesting a direct string or text value assignment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetValueAction {
    pub value: String,
}

impl SetValueAction {
    pub fn new(value: impl Into<String>) -> Self {
        Self {
            value: value.into(),
        }
    }
}

impl McpAction for SetValueAction {
    fn action_name(&self) -> &'static str {
        "set_value"
    }

    fn payload(&self) -> Value {
        serde_json::json!({ "value": self.value })
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// Action requesting text input with optional pre-clearing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendKeysAction {
    pub text: String,
    pub clear_before: bool,
}

impl SendKeysAction {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            clear_before: false,
        }
    }

    pub fn with_clear(mut self, clear: bool) -> Self {
        self.clear_before = clear;
        self
    }
}

impl McpAction for SendKeysAction {
    fn action_name(&self) -> &'static str {
        "send_keys"
    }

    fn payload(&self) -> Value {
        serde_json::json!({
            "text": self.text,
            "clear_before": self.clear_before
        })
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// Action requesting a toggle on a boolean control (switch, checkbox).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ToggleAction {
    pub state: Option<bool>,
}

impl ToggleAction {
    pub fn new() -> Self {
        Self { state: None }
    }

    pub fn with_state(mut self, state: bool) -> Self {
        self.state = Some(state);
        self
    }
}

impl McpAction for ToggleAction {
    fn action_name(&self) -> &'static str {
        "toggle"
    }

    fn payload(&self) -> Value {
        serde_json::json!({ "state": self.state })
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// Action requesting an increment or decrement step on a numeric range control.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StepAction {
    pub delta: f64,
}

impl StepAction {
    pub fn new(delta: f64) -> Self {
        Self { delta }
    }
}

impl McpAction for StepAction {
    fn action_name(&self) -> &'static str {
        "step"
    }

    fn payload(&self) -> Value {
        serde_json::json!({ "delta": self.delta })
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// Action requesting selection of an option by index or string value.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SelectOptionAction {
    pub index: Option<usize>,
    pub value: Option<String>,
}

impl SelectOptionAction {
    pub fn by_index(index: usize) -> Self {
        Self {
            index: Some(index),
            value: None,
        }
    }

    pub fn by_value(value: impl Into<String>) -> Self {
        Self {
            index: None,
            value: Some(value.into()),
        }
    }
}

impl McpAction for SelectOptionAction {
    fn action_name(&self) -> &'static str {
        "select_option"
    }

    fn payload(&self) -> Value {
        serde_json::json!({
            "index": self.index,
            "value": self.value
        })
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// Action requesting selection of a table row by index or ID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelectRowAction {
    pub row_index: usize,
    pub row_id: Option<String>,
}

impl SelectRowAction {
    pub fn new(row_index: usize) -> Self {
        Self {
            row_index,
            row_id: None,
        }
    }

    pub fn with_row_id(mut self, row_id: impl Into<String>) -> Self {
        self.row_id = Some(row_id.into());
        self
    }
}

impl McpAction for SelectRowAction {
    fn action_name(&self) -> &'static str {
        "select_row"
    }

    fn payload(&self) -> Value {
        serde_json::json!({
            "row_index": self.row_index,
            "row_id": self.row_id
        })
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// Action requesting expansion or collapse of a disclosure component.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ExpandAction {
    pub expanded: Option<bool>,
}

impl ExpandAction {
    pub fn new(expanded: bool) -> Self {
        Self {
            expanded: Some(expanded),
        }
    }

    pub fn toggle() -> Self {
        Self { expanded: None }
    }
}

impl McpAction for ExpandAction {
    fn action_name(&self) -> &'static str {
        "expand"
    }

    fn payload(&self) -> Value {
        serde_json::json!({ "expanded": self.expanded })
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// Action requesting dismissal of a modal, sheet, or dialog barrier.
#[derive(Debug, Clone, Copy, Default)]
pub struct DismissAction;

impl McpAction for DismissAction {
    fn action_name(&self) -> &'static str {
        "dismiss"
    }

    fn payload(&self) -> Value {
        serde_json::json!({})
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}
