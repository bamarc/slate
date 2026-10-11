//! Plain-data (`Send + Sync`) types of the semantic automation surface.
//!
//! Nothing in this module touches Slint. All types are serialisable and are shared between the
//! UI-thread semantic core and the MCP layer.

use serde::{Deserialize, Serialize};

use crate::model::Rect;

// ---------------------------------------------------------------------------------------------
// 2.1 Identity and targeting
// ---------------------------------------------------------------------------------------------

/// Short element reference handed to agents, format `e<N>` (N = u64, starts at 1, never reused
/// within a process). Valid until the next `ui_snapshot` call.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ElementRef(pub String);

impl ElementRef {
    /// Builds the reference `e<n>`.
    pub fn from_index(n: u64) -> Self {
        ElementRef(format!("e{n}"))
    }

    /// Parses `e<digits>` (at least one ASCII digit, nothing else). Anything else yields `None`.
    pub fn parse(s: &str) -> Option<Self> {
        let digits = s.strip_prefix('e')?;
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        Some(ElementRef(s.to_string()))
    }

    /// The inner string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for ElementRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Selector fields are ANDed. At least one field must be `Some` (else `AgentError::InvalidParams`).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Selector {
    /// Exact match on accessible-id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Exact match on the role name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// Exact match on accessible-label (trimmed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Case-insensitive substring of accessible-label.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name_contains: Option<String>,
}

/// What an action or wait refers to.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Target {
    Ref(ElementRef),
    Selector(Selector),
}

// ---------------------------------------------------------------------------------------------
// 2.2 Nodes and snapshots
// ---------------------------------------------------------------------------------------------

/// Boolean state flags of a node.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct NodeStates {
    /// accessible-enabled, true when unset.
    pub enabled: bool,
    /// `ItemRc::is_visible()`.
    pub visible: bool,
    /// The item is the window focus item.
    pub focused: bool,
    /// Some only when checkable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked: Option<bool>,
    /// Some only when expandable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expanded: Option<bool>,
    /// Some only when item-selectable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<bool>,
    #[serde(default)]
    pub read_only: bool,
}

/// Numeric range of a slider-like element. `step` is 1.0 when unset.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ValueRange {
    pub min: f32,
    pub max: f32,
    pub step: f32,
}

/// Debug-build-only element information.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DebugInfo {
    pub element_id: String,
    pub type_name: String,
}

/// One node of the semantic tree.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SemanticNode {
    #[serde(rename = "ref")]
    pub reference: ElementRef,
    /// Role name (see `semantic::roles::role_name`).
    pub role: String,
    /// accessible-label, "" if unset.
    pub name: String,
    /// accessible-value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// accessible-description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// accessible-id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub states: NodeStates,
    /// Derived actions, sorted by enum order.
    pub actions: Vec<ActionKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub range: Option<ValueRange>,
    /// Logical px, window coordinates; only if `include_bounds`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bounds: Option<Rect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub debug: Option<DebugInfo>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<SemanticNode>,
}

/// Snapshot detail level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotMode {
    #[default]
    Semantic,
    Full,
}

/// Options of a snapshot request.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SnapshotOptions {
    #[serde(default)]
    pub mode: SnapshotMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<ElementRef>,
    #[serde(default)]
    pub include_bounds: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_depth: Option<u32>,
}

/// Window metadata, in LOGICAL px.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowInfo {
    pub title: String,
    /// LOGICAL px = physical / scale_factor.
    pub width: f32,
    pub height: f32,
    pub scale_factor: f32,
}

/// A complete semantic snapshot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SemanticSnapshot {
    /// Increments on every `ui_snapshot` call.
    pub generation: u64,
    pub window: WindowInfo,
    /// Role "window", name = window title.
    pub root: SemanticNode,
    /// Number of nodes in `root` including the root.
    pub node_count: usize,
    pub debug_info_available: bool,
}

// ---------------------------------------------------------------------------------------------
// 2.3 Actions and outcomes
// ---------------------------------------------------------------------------------------------

/// The semantic action vocabulary. Declaration order is the sort order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    Activate,
    Toggle,
    SetValue,
    Increment,
    Decrement,
    Expand,
    Focus,
    Type,
}

impl ActionKind {
    /// The snake_case wire name, identical to the serde representation.
    pub fn as_str(&self) -> &'static str {
        match self {
            ActionKind::Activate => "activate",
            ActionKind::Toggle => "toggle",
            ActionKind::SetValue => "set_value",
            ActionKind::Increment => "increment",
            ActionKind::Decrement => "decrement",
            ActionKind::Expand => "expand",
            ActionKind::Focus => "focus",
            ActionKind::Type => "type",
        }
    }
}

/// Pointer fallback policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Fallback {
    #[default]
    None,
    Pointer,
}

/// Extra parameters of an action.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ActOptions {
    /// For `set_value`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// For `type`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// For `type`: replace instead of append.
    #[serde(default)]
    pub replace: bool,
    #[serde(default)]
    pub fallback: Fallback,
}

/// How an action was delivered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionMethod {
    Accessibility,
    Focus,
    KeyEvents,
    Pointer,
}

/// Result of a successful action.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActionOutcome {
    pub action: ActionKind,
    pub method: ActionMethod,
    /// 1, or the number of increment/decrement steps for stepped `set_value`.
    pub steps: u32,
    /// State RE-READ after the action; children always empty.
    pub target: SemanticNode,
}

fn default_true() -> bool {
    true
}

/// Condition for `wait_for`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WaitCondition {
    pub target: Target,
    /// `false` = wait until gone.
    #[serde(default = "default_true")]
    pub exists: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked: Option<bool>,
}
