//! Data models for UI automation, inspection, snapshotting, and diagnostics.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;

/// A 2D point in logical window coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

impl Point {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    pub fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    /// Calculate Euclidean distance to another point.
    pub fn distance_to(&self, other: &Point) -> f32 {
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        (dx * dx + dy * dy).sqrt()
    }
}

impl fmt::Display for Point {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}

impl From<(f32, f32)> for Point {
    fn from((x, y): (f32, f32)) -> Self {
        Self { x, y }
    }
}

/// A 2D bounding rectangle in logical window coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    pub const ZERO: Self = Self {
        x: 0.0,
        y: 0.0,
        width: 0.0,
        height: 0.0,
    };

    pub fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    /// Returns the top-left origin point of the rectangle.
    pub fn origin(&self) -> Point {
        Point::new(self.x, self.y)
    }

    /// Returns the geometric center point of the rectangle.
    pub fn center(&self) -> Point {
        Point::new(self.x + self.width / 2.0, self.y + self.height / 2.0)
    }

    /// Returns whether the specified point is inside the rectangle bounds.
    pub fn contains(&self, p: &Point) -> bool {
        p.x >= self.x
            && p.x <= (self.x + self.width)
            && p.y >= self.y
            && p.y <= (self.y + self.height)
    }

    /// Returns whether this rectangle intersects another rectangle.
    pub fn intersects(&self, other: &Rect) -> bool {
        self.x < (other.x + other.width)
            && (self.x + self.width) > other.x
            && self.y < (other.y + other.height)
            && (self.y + self.height) > other.y
    }

    /// Total area of the rectangle in logical pixels squared.
    pub fn area(&self) -> f32 {
        self.width * self.height
    }
}

/// Represents a mouse button for click actions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum MouseButton {
    #[default]
    Left,
    Right,
    Middle,
}

/// Target selector representation for finding elements.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ElementSelector {
    /// Selector matching component ID (e.g. `#submit-btn` or `submit-btn`).
    Id(String),
    /// Selector matching accessible label or text content.
    Label(String),
    /// Selector targeting specific window coordinate.
    Coordinate(Point),
    /// Selector matching element role.
    Role(String),
}

impl ElementSelector {
    /// Parse a target selector string into an `ElementSelector`.
    pub fn parse(target: &str) -> Self {
        let trimmed = target.trim();

        // 1. Check for coordinates "x,y"
        if let Some((x_str, y_str)) = trimmed.split_once(',') {
            if let (Ok(x), Ok(y)) = (x_str.trim().parse::<f32>(), y_str.trim().parse::<f32>()) {
                return ElementSelector::Coordinate(Point::new(x, y));
            }
        }

        // 2. Explicit ID prefixes
        if let Some(id) = trimmed.strip_prefix('#') {
            return ElementSelector::Id(id.to_string());
        }
        if let Some(id) = trimmed.strip_prefix("id:") {
            return ElementSelector::Id(id.to_string());
        }

        // 3. Explicit label/text prefixes
        if let Some(label) = trimmed.strip_prefix("text:") {
            return ElementSelector::Label(label.to_string());
        }
        if let Some(label) = trimmed.strip_prefix("label:") {
            return ElementSelector::Label(label.to_string());
        }

        // 4. Explicit role prefix
        if let Some(role) = trimmed.strip_prefix("role:") {
            return ElementSelector::Role(role.to_string());
        }

        // 5. Default fallback to ID
        ElementSelector::Id(trimmed.to_string())
    }
}

/// A node in the hierarchical UI tree representing a Slint component or item.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UiElementNode {
    /// Unique identifier for the element.
    pub id: String,
    /// Component class or type name (e.g., "SlateButton", "TextInput", "TouchArea").
    pub type_name: String,
    /// Bounding rectangle in window coordinates.
    pub bounds: Rect,
    /// Accessible label or visible text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// Accessible role (e.g., "Button", "TextInput", "Checkbox", "Slider", "Window").
    pub role: String,
    /// Current element value (if applicable, e.g. text input content or slider progress).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// Whether the element is enabled for interaction.
    pub enabled: bool,
    /// Whether the element currently holds keyboard focus.
    pub focused: bool,
    /// Whether the element is currently visible.
    pub visible: bool,
    /// Child elements in the visual hierarchy.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<UiElementNode>,
    /// Dynamic or framework-specific properties.
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub properties: HashMap<String, serde_json::Value>,
}

impl UiElementNode {
    /// Find a descendant element by ID (pre-order search).
    pub fn find_by_id(&self, target_id: &str) -> Option<&UiElementNode> {
        if !self.id.is_empty() && self.id == target_id {
            return Some(self);
        }
        for child in &self.children {
            if let Some(found) = child.find_by_id(target_id) {
                return Some(found);
            }
        }
        None
    }

    /// Find a descendant element by accessible label or visible text.
    pub fn find_by_label(&self, target_label: &str) -> Option<&UiElementNode> {
        if self.label.as_deref() == Some(target_label) {
            return Some(self);
        }
        for child in &self.children {
            if let Some(found) = child.find_by_label(target_label) {
                return Some(found);
            }
        }
        None
    }

    /// Hit-test: find the deepest child node containing the given point.
    pub fn find_at_point(&self, point: &Point) -> Option<&UiElementNode> {
        if !self.visible || !self.bounds.contains(point) {
            return None;
        }

        // Search children in reverse order (top-most z-order first)
        for child in self.children.iter().rev() {
            if let Some(found) = child.find_at_point(point) {
                return Some(found);
            }
        }

        Some(self)
    }

    /// Collect all elements in this subtree as a flat vector.
    pub fn collect_elements(&self) -> Vec<&UiElementNode> {
        let mut elements = vec![self];
        for child in &self.children {
            elements.extend(child.collect_elements());
        }
        elements
    }

    /// Count total elements in this subtree.
    pub fn count_elements(&self) -> usize {
        1 + self.children.iter().map(|c| c.count_elements()).sum::<usize>()
    }
}

/// Hierarchical UI tree snapshot of the application window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UiTree {
    /// Root element of the UI hierarchy (typically the Window).
    pub root: UiElementNode,
    /// Timestamp in milliseconds since Unix epoch when inspected.
    pub timestamp_ms: u64,
    /// Window title if available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    /// Logical window dimensions.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_size: Option<Point>,
}

impl UiTree {
    pub fn new(root: UiElementNode) -> Self {
        Self {
            root,
            timestamp_ms: current_time_ms(),
            window_title: None,
            window_size: None,
        }
    }

    pub fn with_window_info(mut self, title: impl Into<String>, width: f32, height: f32) -> Self {
        self.window_title = Some(title.into());
        self.window_size = Some(Point::new(width, height));
        self
    }

    /// Find an element by ID.
    pub fn find_by_id(&self, id: &str) -> Option<&UiElementNode> {
        self.root.find_by_id(id)
    }

    /// Find an element by label.
    pub fn find_by_label(&self, label: &str) -> Option<&UiElementNode> {
        self.root.find_by_label(label)
    }

    /// Find deepest element at coordinate.
    pub fn find_at_point(&self, point: &Point) -> Option<&UiElementNode> {
        self.root.find_at_point(point)
    }

    /// Find an element using a generic selector string.
    pub fn find_by_selector(&self, selector: &str) -> Option<&UiElementNode> {
        match ElementSelector::parse(selector) {
            ElementSelector::Id(id) => self
                .root
                .find_by_id(&id)
                .or_else(|| self.root.find_by_label(&id)),
            ElementSelector::Label(label) => self.root.find_by_label(&label),
            ElementSelector::Coordinate(point) => self.root.find_at_point(&point),
            ElementSelector::Role(role) => self
                .root
                .collect_elements()
                .into_iter()
                .find(|e| e.role.eq_ignore_ascii_case(&role)),
        }
    }

    /// Total count of elements in the tree.
    pub fn count_elements(&self) -> usize {
        self.root.count_elements()
    }
}

/// Visual snapshot of the rendered application window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Screenshot {
    /// Width of the frame in pixels.
    pub width: u32,
    /// Height of the frame in pixels.
    pub height: u32,
    /// Image format (e.g. "png").
    pub format: String,
    /// Raw image bytes (PNG encoded).
    pub data: Vec<u8>,
    /// Timestamp in milliseconds since Unix epoch.
    pub timestamp_ms: u64,
}

impl Screenshot {
    pub fn new(width: u32, height: u32, format: impl Into<String>, data: Vec<u8>) -> Self {
        Self {
            width,
            height,
            format: format.into(),
            data,
            timestamp_ms: current_time_ms(),
        }
    }

    /// Encode image bytes to standard Base64 string for MCP protocol payloads.
    pub fn to_base64(&self) -> String {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(&self.data)
    }

    /// Alias for `to_base64()` returning the Base64-encoded PNG string.
    pub fn to_base64_png(&self) -> String {
        self.to_base64()
    }

    /// Data URL representation (e.g. "data:image/png;base64,...").
    pub fn data_url(&self) -> String {
        format!("data:image/{};base64,{}", self.format, self.to_base64())
    }

    /// Total byte length of the encoded image data.
    pub fn byte_len(&self) -> usize {
        self.data.len()
    }
}

/// Diagnostic and performance metrics of the running application.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct DiagnosticMetrics {
    /// Estimated frames per second.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fps: Option<f32>,
    /// Resident memory usage in bytes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory_bytes: Option<u64>,
    /// Measured latency of the Slint event loop in milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_loop_lag_ms: Option<f64>,
    /// Number of active background worker tasks.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_background_tasks: Option<usize>,
    /// Additional custom diagnostic key-values.
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub extra: HashMap<String, serde_json::Value>,
}

/// Snapshot of the high-level application state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppState {
    /// Currently active view or screen name (e.g. "Compute", "Settings").
    pub active_view: String,
    /// Key-value map of application state properties.
    pub properties: HashMap<String, serde_json::Value>,
    /// Timestamp in milliseconds since Unix epoch.
    pub timestamp_ms: u64,
    /// Optional diagnostic metrics.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub diagnostics: Option<DiagnosticMetrics>,
}

impl AppState {
    pub fn new(active_view: impl Into<String>) -> Self {
        Self {
            active_view: active_view.into(),
            properties: HashMap::new(),
            timestamp_ms: current_time_ms(),
            diagnostics: None,
        }
    }

    pub fn with_property(mut self, key: impl Into<String>, value: serde_json::Value) -> Self {
        self.properties.insert(key.into(), value);
        self
    }

    pub fn get_property(&self, key: &str) -> Option<&serde_json::Value> {
        self.properties.get(key)
    }

    pub fn with_diagnostics(mut self, diagnostics: DiagnosticMetrics) -> Self {
        self.diagnostics = Some(diagnostics);
        self
    }
}

/// Result returned from element interaction commands.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActionResult {
    /// Whether the action succeeded.
    pub success: bool,
    /// Descriptive message of the result.
    pub message: String,
    /// Whether the intended target element was found.
    pub target_found: bool,
    /// Timestamp in milliseconds since Unix epoch.
    pub timestamp_ms: u64,
    /// Qualified ID of the target element (if known).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub element_id: Option<String>,
    /// Updated value after the action (if applicable).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_value: Option<serde_json::Value>,
    /// Detailed action telemetry or properties.
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub details: HashMap<String, serde_json::Value>,
}

impl ActionResult {
    pub fn success(message: impl Into<String>) -> Self {
        Self {
            success: true,
            message: message.into(),
            target_found: true,
            timestamp_ms: current_time_ms(),
            element_id: None,
            updated_value: None,
            details: HashMap::new(),
        }
    }

    pub fn failure(message: impl Into<String>) -> Self {
        Self {
            success: false,
            message: message.into(),
            target_found: true,
            timestamp_ms: current_time_ms(),
            element_id: None,
            updated_value: None,
            details: HashMap::new(),
        }
    }

    pub fn not_found(target: &str) -> Self {
        Self {
            success: false,
            message: format!("Target element '{}' not found", target),
            target_found: false,
            timestamp_ms: current_time_ms(),
            element_id: None,
            updated_value: None,
            details: HashMap::new(),
        }
    }

    pub fn with_element_id(mut self, id: impl Into<String>) -> Self {
        self.element_id = Some(id.into());
        self
    }

    pub fn with_value(mut self, val: serde_json::Value) -> Self {
        self.updated_value = Some(val);
        self
    }

    pub fn with_detail(mut self, key: impl Into<String>, val: serde_json::Value) -> Self {
        self.details.insert(key.into(), val);
        self
    }
}

/// Helper function to retrieve the current Unix timestamp in milliseconds.
pub fn current_time_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
