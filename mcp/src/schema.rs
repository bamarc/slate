//! MCP Tool Schemas and Protocol Data Models (Protocol Version: 2024-11-05).

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Tool definition matching the Model Context Protocol specification.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Tool {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema")]
    pub input_schema: Value,
}

pub type McpToolDefinition = Tool;
pub type ToolInputSchema = Value;

impl Tool {
    pub fn new(
        name: impl Into<String>,
        description: impl Into<String>,
        input_schema: Value,
    ) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
            input_schema,
        }
    }
}

/// Returns the tool definition for `get_screenshot`.
pub fn get_screenshot_schema() -> Tool {
    Tool::new(
        "get_screenshot",
        "Captures the current rendered window frame and returns PNG image data",
        serde_json::json!({
            "type": "object",
            "properties": {
                "mime_type": {
                    "type": "string",
                    "default": "image/png",
                    "description": "Image MIME type (default: image/png)"
                }
            }
        }),
    )
}

/// Returns the tool definition for `inspect_tree`.
pub fn inspect_tree_schema() -> Tool {
    Tool::new(
        "inspect_tree",
        "Returns the hierarchical UI tree of components, labels, IDs, and bounding rectangles",
        serde_json::json!({
            "type": "object",
            "properties": {
                "root_id": {
                    "type": "string",
                    "description": "Optional element ID to inspect a specific subtree"
                },
                "max_depth": {
                    "type": "integer",
                    "minimum": 1,
                    "description": "Maximum depth for tree traversal (minimum: 1)"
                }
            }
        }),
    )
}

/// Returns the tool definition for `click_element`.
pub fn click_element_schema() -> Tool {
    Tool::new(
        "click_element",
        "Dispatches click events to specific elements by ID, text label, or coordinates",
        serde_json::json!({
            "type": "object",
            "properties": {
                "id": {
                    "type": "string",
                    "description": "Target element unique ID"
                },
                "label": {
                    "type": "string",
                    "description": "Target element accessible label or text"
                },
                "x": {
                    "type": "number",
                    "description": "Horizontal logical window coordinate"
                },
                "y": {
                    "type": "number",
                    "description": "Vertical logical window coordinate"
                },
                "button": {
                    "type": "string",
                    "enum": ["left", "right", "middle"],
                    "default": "left",
                    "description": "Mouse button to click with"
                },
                "click_count": {
                    "type": "integer",
                    "enum": [1, 2],
                    "default": 1,
                    "description": "Number of clicks (1 for single click, 2 for double click)"
                }
            }
        }),
    )
}

/// Returns the tool definition for `send_keys`.
pub fn send_keys_schema() -> Tool {
    Tool::new(
        "send_keys",
        "Types text into active or targeted text inputs",
        serde_json::json!({
            "type": "object",
            "properties": {
                "text": {
                    "type": "string",
                    "description": "Text to type into the target element"
                },
                "element_id": {
                    "type": "string",
                    "description": "Target element ID (falls back to active element if omitted)"
                },
                "clear_first": {
                    "type": "boolean",
                    "default": false,
                    "description": "Whether to clear existing text before typing"
                }
            },
            "required": ["text"]
        }),
    )
}

/// Returns the tool definition for `get_state`.
pub fn get_state_schema() -> Tool {
    Tool::new(
        "get_state",
        "Reads application properties, active view, or diagnostic metrics",
        serde_json::json!({
            "type": "object",
            "properties": {
                "keys": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Optional list of state property keys to filter"
                }
            }
        }),
    )
}

/// Returns the list of all standard MCP tools for Slate remote control.
pub fn all_standard_tools() -> Vec<Tool> {
    vec![
        get_screenshot_schema(),
        inspect_tree_schema(),
        click_element_schema(),
        send_keys_schema(),
        get_state_schema(),
    ]
}

// ============================================================================
// MCP Specification Data Models
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ServerCapabilities {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resources: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logging: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct McpInitializeResult {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    pub capabilities: ServerCapabilities,
    #[serde(rename = "serverInfo")]
    pub server_info: ServerInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolContent {
    #[serde(rename = "type")]
    pub content_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
    #[serde(rename = "mimeType", skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
}

impl ToolContent {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content_type: "text".to_string(),
            text: Some(text.into()),
            data: None,
            mime_type: None,
        }
    }

    pub fn image(data: impl Into<String>, mime_type: impl Into<String>) -> Self {
        Self {
            content_type: "image".to_string(),
            text: None,
            data: Some(data.into()),
            mime_type: Some(mime_type.into()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolCallResult {
    pub content: Vec<ToolContent>,
    #[serde(rename = "isError", default)]
    pub is_error: bool,
}

impl ToolCallResult {
    pub fn success(content: Vec<ToolContent>) -> Self {
        Self {
            content,
            is_error: false,
        }
    }

    pub fn success_text(text: impl Into<String>) -> Self {
        Self {
            content: vec![ToolContent::text(text)],
            is_error: false,
        }
    }

    pub fn failure_text(err: impl Into<String>) -> Self {
        Self {
            content: vec![ToolContent::text(err)],
            is_error: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Resource {
    pub uri: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(rename = "mimeType", skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ResourceContent {
    pub uri: String,
    #[serde(rename = "mimeType", skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blob: Option<String>,
}
