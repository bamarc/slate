//! Unit and integration tests for all 5 MCP standard tools.

use image::ImageEncoder;
use std::collections::HashMap;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use tokio::sync::Mutex;

use slate_agent::error::AgentError;
use slate_agent::model::{
    ActionResult, AppState, MouseButton, Point, Rect, Screenshot, UiElementNode, UiTree,
};
use slate_agent::traits::{
    AutomationEngine, ElementController, StateProvider, UiInspector, VisualRenderer,
};
use slate_mcp::error::{INVALID_PARAMS, METHOD_NOT_FOUND};
use slate_mcp::schema::{Tool, ToolCallResult};
use slate_mcp::server::{JsonRpcResponse, McpServer};

// ============================================================================
// Realistic Mock Automation Engine for Tool Testing
// ============================================================================

struct MockInspector;

#[async_trait::async_trait]
impl UiInspector for MockInspector {
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        let root = UiElementNode {
            id: "root_window".to_string(),
            type_name: "Window".to_string(),
            bounds: Rect::new(0.0, 0.0, 1040.0, 720.0),
            label: Some("Slate Showcase".to_string()),
            role: "Window".to_string(),
            value: None,
            enabled: true,
            focused: false,
            visible: true,
            children: vec![
                UiElementNode {
                    id: "header_bar".to_string(),
                    type_name: "SlateHeaderBar".to_string(),
                    bounds: Rect::new(0.0, 0.0, 1040.0, 48.0),
                    label: Some("Header".to_string()),
                    role: "header_bar".to_string(),
                    value: None,
                    enabled: true,
                    focused: false,
                    visible: true,
                    children: Vec::new(),
                    properties: HashMap::new(),
                },
                UiElementNode {
                    id: "email_input".to_string(),
                    type_name: "SlateInput".to_string(),
                    bounds: Rect::new(260.0, 120.0, 280.0, 36.0),
                    label: Some("Email Address".to_string()),
                    role: "textbox".to_string(),
                    value: Some("dev@slate.internal".to_string()),
                    enabled: true,
                    focused: false,
                    visible: true,
                    children: Vec::new(),
                    properties: HashMap::new(),
                },
                UiElementNode {
                    id: "counter_btn".to_string(),
                    type_name: "SlateButton".to_string(),
                    bounds: Rect::new(260.0, 70.0, 140.0, 36.0),
                    label: Some("Click Counter".to_string()),
                    role: "button".to_string(),
                    value: None,
                    enabled: true,
                    focused: false,
                    visible: true,
                    children: Vec::new(),
                    properties: HashMap::new(),
                },
                UiElementNode {
                    id: "nav_view".to_string(),
                    type_name: "SlateNavigationSplitView".to_string(),
                    bounds: Rect::new(0.0, 48.0, 240.0, 672.0),
                    label: Some("Navigation".to_string()),
                    role: "navigation".to_string(),
                    value: None,
                    enabled: true,
                    focused: false,
                    visible: true,
                    children: vec![UiElementNode {
                        id: "nav_item_buttons".to_string(),
                        type_name: "NavItem".to_string(),
                        bounds: Rect::new(10.0, 60.0, 220.0, 32.0),
                        label: Some("Buttons & Badges".to_string()),
                        role: "button".to_string(),
                        value: None,
                        enabled: true,
                        focused: false,
                        visible: true,
                        children: Vec::new(),
                        properties: HashMap::new(),
                    }],
                    properties: HashMap::new(),
                },
            ],
            properties: HashMap::new(),
        };

        Ok(UiTree::new(root).with_window_info("Slate Showcase", 1040.0, 720.0))
    }
}

struct MockController {
    click_count: AtomicI32,
    typed_text: Mutex<String>,
}

#[async_trait::async_trait]
impl ElementController for MockController {
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        if target == "nonexistent_element" {
            return Err(AgentError::element_not_found(
                target,
                "Element does not exist in component tree",
            ));
        }
        self.click_count.fetch_add(1, Ordering::SeqCst);
        Ok(ActionResult::success(format!("Clicked '{}'", target)).with_element_id(target))
    }

    async fn click_at(
        &self,
        point: Point,
        button: MouseButton,
    ) -> Result<ActionResult, AgentError> {
        self.click_count.fetch_add(1, Ordering::SeqCst);
        Ok(ActionResult::success(format!(
            "Clicked at ({}, {}) with {:?}",
            point.x, point.y, button
        )))
    }

    async fn send_keys(
        &self,
        target: Option<&str>,
        text: &str,
    ) -> Result<ActionResult, AgentError> {
        let mut val = self.typed_text.lock().await;
        val.push_str(text);
        let msg = match target {
            Some(t) => format!("Typed '{}' into '{}'", text, t),
            None => format!("Typed '{}' into active element", text),
        };
        Ok(ActionResult::success(msg))
    }

    async fn set_value(&self, _target: &str, value: &str) -> Result<ActionResult, AgentError> {
        let mut val = self.typed_text.lock().await;
        val.clear();
        val.push_str(value);
        Ok(ActionResult::success(format!("Set value '{}'", value)))
    }

    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Toggled '{}'", target)))
    }
}

struct MockStateProvider {
    properties: Mutex<HashMap<String, serde_json::Value>>,
}

#[async_trait::async_trait]
impl StateProvider for MockStateProvider {
    async fn get_state(&self, query: Option<&str>) -> Result<AppState, AgentError> {
        let props = self.properties.lock().await.clone();
        let mut state = AppState::new("buttons");
        if let Some(q) = query {
            if let Some(v) = props.get(q) {
                state = state.with_property(q, v.clone());
            }
        } else {
            for (k, v) in props {
                state = state.with_property(k, v);
            }
        }
        Ok(state)
    }

    async fn get_diagnostics(&self) -> Result<slate_agent::model::DiagnosticMetrics, AgentError> {
        Ok(slate_agent::model::DiagnosticMetrics::default())
    }

    async fn set_property(&self, key: &str, value: serde_json::Value) -> Result<(), AgentError> {
        self.properties.lock().await.insert(key.to_string(), value);
        Ok(())
    }
}

struct MockRenderer;

#[async_trait::async_trait]
impl VisualRenderer for MockRenderer {
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError> {
        let mut png_bytes = Vec::new();
        image::codecs::png::PngEncoder::new(&mut png_bytes)
            .write_image(&[0u8; 16], 2, 2, image::ExtendedColorType::Rgba8)
            .unwrap();
        Ok(Screenshot::new(1040, 720, "png", png_bytes))
    }

    async fn get_viewport_size(&self) -> Result<(u32, u32), AgentError> {
        Ok((1040, 720))
    }
}

struct FullMockEngine {
    inspector: MockInspector,
    controller: MockController,
    state: MockStateProvider,
    renderer: MockRenderer,
}

impl FullMockEngine {
    fn new() -> Self {
        let mut initial_props = HashMap::new();
        initial_props.insert("is_dark".to_string(), serde_json::json!(false));
        initial_props.insert("counter".to_string(), serde_json::json!(42));
        initial_props.insert(
            "demo_input_text".to_string(),
            serde_json::json!("slate@example.com"),
        );

        Self {
            inspector: MockInspector,
            controller: MockController {
                click_count: AtomicI32::new(0),
                typed_text: Mutex::new(String::new()),
            },
            state: MockStateProvider {
                properties: Mutex::new(initial_props),
            },
            renderer: MockRenderer,
        }
    }
}

#[async_trait::async_trait]
impl AutomationEngine for FullMockEngine {
    fn inspector(&self) -> &dyn UiInspector {
        &self.inspector
    }
    fn controller(&self) -> &dyn ElementController {
        &self.controller
    }
    fn state(&self) -> &dyn StateProvider {
        &self.state
    }
    fn renderer(&self) -> &dyn VisualRenderer {
        &self.renderer
    }
}

fn create_full_test_server() -> (McpServer, Arc<FullMockEngine>) {
    let engine = Arc::new(FullMockEngine::new());
    (McpServer::new(engine.clone()), engine)
}

// ============================================================================
// Tool Tests
// ============================================================================

#[tokio::test]
async fn test_tools_list_returns_all_5_tools() {
    let (server, _) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let tools_val = resp.result.unwrap();
    let tools: Vec<Tool> = serde_json::from_value(tools_val["tools"].clone()).unwrap();

    assert_eq!(tools.len(), 5);
    let names: Vec<String> = tools.into_iter().map(|t| t.name).collect();
    assert!(names.contains(&"get_screenshot".to_string()));
    assert!(names.contains(&"inspect_tree".to_string()));
    assert!(names.contains(&"click_element".to_string()));
    assert!(names.contains(&"send_keys".to_string()));
    assert!(names.contains(&"get_state".to_string()));
}

#[tokio::test]
async fn test_tool_get_screenshot() {
    let (server, _) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "get_screenshot", "arguments": {}}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    assert_eq!(res.content.len(), 1);
    assert_eq!(res.content[0].content_type, "image");
    assert!(res.content[0].data.is_some());
}

#[tokio::test]
async fn test_tool_inspect_tree_full() {
    let (server, _) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "inspect_tree", "arguments": {}}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    let text = res.content[0].text.as_ref().unwrap();
    assert!(text.contains("root_window"));
    assert!(text.contains("header_bar"));
    assert!(text.contains("email_input"));
}

#[tokio::test]
async fn test_tool_inspect_tree_filter_by_root_id() {
    let (server, _) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "inspect_tree", "arguments": {"root_id": "nav_view"}}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    let text = res.content[0].text.as_ref().unwrap();
    let tree: UiTree = serde_json::from_str(text).unwrap();
    assert_eq!(tree.root.id, "nav_view");
    assert_eq!(tree.root.role, "navigation");
}

#[tokio::test]
async fn test_tool_inspect_tree_depth_zero_error() {
    let (server, _) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "inspect_tree", "arguments": {"max_depth": 0}}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error);
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("max_depth must be >= 1"));
}

#[tokio::test]
async fn test_tool_inspect_tree_nonexistent_root_error() {
    let (server, _) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "inspect_tree", "arguments": {"root_id": "nonexistent_node"}}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error);
    assert!(res.content[0].text.as_ref().unwrap().contains("not found"));
}

#[tokio::test]
async fn test_tool_click_by_id_and_double_click() {
    let (server, engine) = create_full_test_server();

    // Single click
    let raw = r#"{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "click_element", "arguments": {"id": "counter_btn"}}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    assert_eq!(engine.controller.click_count.load(Ordering::SeqCst), 1);

    // Double click
    let raw_double = r#"{"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "click_element", "arguments": {"id": "counter_btn", "click_count": 2}}}"#;
    let resp_str2 = server.handle_line(raw_double).await.unwrap();
    let resp2: JsonRpcResponse = serde_json::from_str(&resp_str2).unwrap();
    let res2: ToolCallResult = serde_json::from_value(resp2.result.unwrap()).unwrap();
    assert!(!res2.is_error);
    assert_eq!(engine.controller.click_count.load(Ordering::SeqCst), 3);
}

#[tokio::test]
async fn test_tool_click_coordinates() {
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "click_element", "arguments": {"x": 270.0, "y": 80.0}}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();

    assert!(!res.is_error);
    assert_eq!(engine.controller.click_count.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn test_tool_click_errors() {
    let (server, _) = create_full_test_server();

    // Missing targets
    let r1 = r#"{"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "click_element", "arguments": {}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r1).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error);
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("requires 'id', 'label', or coordinates"));

    // Negative coordinates
    let r2 = r#"{"jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": {"name": "click_element", "arguments": {"x": -10.0, "y": 50.0}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r2).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error);
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("cannot be negative"));

    // Out of bounds coordinates
    let r3 = r#"{"jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": {"name": "click_element", "arguments": {"x": 5000.0, "y": 5000.0}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r3).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error);
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("out of window bounds"));

    // Nonexistent element
    let r4 = r#"{"jsonrpc": "2.0", "id": 13, "method": "tools/call", "params": {"name": "click_element", "arguments": {"id": "nonexistent_element"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r4).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error);
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("not found or not clickable"));
}

#[tokio::test]
async fn test_tool_send_keys() {
    let (server, engine) = create_full_test_server();

    // Normal typing
    let r1 = r#"{"jsonrpc": "2.0", "id": 14, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": "hello", "element_id": "email_input"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r1).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    assert_eq!(*engine.controller.typed_text.lock().await, "hello");

    // Clear first and type
    let r2 = r#"{"jsonrpc": "2.0", "id": 15, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": "world", "element_id": "email_input", "clear_first": true}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r2).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    assert_eq!(*engine.controller.typed_text.lock().await, "world");

    // Missing text parameter -> returns JSON-RPC INVALID_PARAMS (-32602)
    let r3 = r#"{"jsonrpc": "2.0", "id": 16, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"element_id": "email_input"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r3).await.unwrap()).unwrap();
    assert!(resp.result.is_none());
    let err = resp.error.unwrap();
    assert_eq!(err.code, INVALID_PARAMS);
    assert!(err.message.contains("Missing required argument 'text'"));

    // Send keys to non-editable element
    let r4 = r#"{"jsonrpc": "2.0", "id": 17, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": "fail", "element_id": "header_bar"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r4).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error);
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("not an editable text input"));
}

#[tokio::test]
async fn test_tool_get_state() {
    let (server, _) = create_full_test_server();

    // Full state
    let r1 = r#"{"jsonrpc": "2.0", "id": 18, "method": "tools/call", "params": {"name": "get_state", "arguments": {}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r1).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    let state: AppState = serde_json::from_str(res.content[0].text.as_ref().unwrap()).unwrap();
    assert_eq!(state.active_view, "buttons");
    assert!(state.properties.contains_key("is_dark"));
    assert!(state.properties.contains_key("counter"));

    // Filtered state
    let r2 = r#"{"jsonrpc": "2.0", "id": 19, "method": "tools/call", "params": {"name": "get_state", "arguments": {"keys": ["is_dark"]}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r2).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    let state2: AppState = serde_json::from_str(res.content[0].text.as_ref().unwrap()).unwrap();
    assert_eq!(state2.properties.len(), 1);
    assert!(state2.properties.contains_key("is_dark"));
    assert!(!state2.properties.contains_key("counter"));
}

#[tokio::test]
async fn test_tool_unknown_name() {
    let (server, _) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 20, "method": "tools/call", "params": {"name": "nonexistent_tool", "arguments": {}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();

    let err = resp.error.unwrap();
    assert_eq!(err.code, METHOD_NOT_FOUND);
    assert!(err.message.contains("Tool 'nonexistent_tool' not found"));
}
