//! Unit and integration tests for all 5 MCP standard tools.
//!
//! FRAMING-ONLY (Slint-first remediation plan, Phase 0): every test in this file
//! runs against hand-rolled mock engines (`MockInspector`, `MockController`,
//! `MockStateProvider`, `MockRenderer`, `FullMockEngine`) whose methods return
//! canned `Ok` values without touching a Slint window. They cover JSON-RPC
//! framing and tool dispatch (method names, argument validation, error codes)
//! ONLY — they assert nothing about live Slint behavior (event-loop dispatch,
//! toggle semantics, element identity). In particular, mock click counters here
//! cannot catch double-dispatch regressions; see
//! `real_window_interaction_tests.rs` (T1/T2) for the live-window coverage.

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
                // Phase 1 regression probe: role is non-editable ("button") but the
                // type name contains "Input". Substring editability sniffing
                // (role/type `.contains("input")`) wrongly treats this as
                // editable; exact role checking must reject it.
                UiElementNode {
                    id: "tricky_btn".to_string(),
                    type_name: "SlateInput".to_string(),
                    bounds: Rect::new(260.0, 170.0, 140.0, 36.0),
                    label: Some("Tricky Button".to_string()),
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
    click_element_calls: AtomicI32,
    click_at_calls: AtomicI32,
    send_keys_calls: AtomicI32,
    set_value_calls: AtomicI32,
    toggle_calls: AtomicI32,
    typed_text: Mutex<String>,
    last_button: Mutex<Option<MouseButton>>,
    set_value_should_fail: bool,
}

impl MockController {
    fn new() -> Self {
        Self {
            click_count: AtomicI32::new(0),
            click_element_calls: AtomicI32::new(0),
            click_at_calls: AtomicI32::new(0),
            send_keys_calls: AtomicI32::new(0),
            set_value_calls: AtomicI32::new(0),
            toggle_calls: AtomicI32::new(0),
            typed_text: Mutex::new(String::new()),
            last_button: Mutex::new(None),
            set_value_should_fail: false,
        }
    }

    fn with_failing_set_value() -> Self {
        Self {
            set_value_should_fail: true,
            ..Self::new()
        }
    }
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
        self.click_element_calls.fetch_add(1, Ordering::SeqCst);
        Ok(ActionResult::success(format!("Clicked '{}'", target)).with_element_id(target))
    }

    async fn click_at(
        &self,
        point: Point,
        button: MouseButton,
    ) -> Result<ActionResult, AgentError> {
        self.click_count.fetch_add(1, Ordering::SeqCst);
        self.click_at_calls.fetch_add(1, Ordering::SeqCst);
        *self.last_button.lock().await = Some(button);
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
        self.send_keys_calls.fetch_add(1, Ordering::SeqCst);
        let mut val = self.typed_text.lock().await;
        val.push_str(text);
        let msg = match target {
            Some(t) => format!("Typed '{}' into '{}'", text, t),
            None => format!("Typed '{}' into active element", text),
        };
        Ok(ActionResult::success(msg))
    }

    async fn set_value(&self, _target: &str, value: &str) -> Result<ActionResult, AgentError> {
        self.set_value_calls.fetch_add(1, Ordering::SeqCst);
        if self.set_value_should_fail {
            return Err(AgentError::state_error("clear_first failed: backend unavailable"));
        }
        let mut val = self.typed_text.lock().await;
        val.clear();
        val.push_str(value);
        Ok(ActionResult::success(format!("Set value '{}'", value)))
    }

    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        self.toggle_calls.fetch_add(1, Ordering::SeqCst);
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
            controller: MockController::new(),
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
    // FRAMING-ONLY: counts invocations of the mock controller — it proves the
    // tool forwards `click_count`, not that a live window double-clicks (plan
    // E-3: the backend has no OS double-click semantics; `click_count >= 2` is
    // an explicit two-step of single clicks).
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

// ============================================================================
// Phase 1 — single dispatch by role (Red → Green → Iterate)
// Each tool call must produce exactly ONE backend controller action.
// ============================================================================

/// Coordinate clicks must go through the pointer path ONLY (`click_at`), even
/// when the point overlaps a known element. Resolving an id is reporting-only
/// and must never substitute the target (removes overlay-id hijack).
#[tokio::test]
async fn test_phase1_coordinate_click_uses_pointer_path_only() {
    // FRAMING-ONLY: mock dispatch counts only — live behavior is covered in real_window_interaction_tests.rs.
    let (server, engine) = create_full_test_server();
    // (270, 80) sits inside `counter_btn` (260,70,140x36): old code hijacked
    // this to `click_element`; single-dispatch requires `click_at`.
    let raw = r#"{"jsonrpc": "2.0", "id": 101, "method": "tools/call", "params": {"name": "click_element", "arguments": {"x": 270.0, "y": 80.0}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    assert_eq!(
        engine.controller.click_at_calls.load(Ordering::SeqCst),
        1,
        "coordinate click must call click_at exactly once"
    );
    assert_eq!(
        engine
            .controller
            .click_element_calls
            .load(Ordering::SeqCst),
        0,
        "coordinate click must never call click_element (no overlay hijack)"
    );
}

/// Element id/label clicks honor `button`: non-left buttons on the element
/// path must be explicitly rejected (the `click_element` backend path is
/// left-only semantic activation), not silently coerced to Left.
#[tokio::test]
async fn test_phase1_element_click_rejects_non_left_button() {
    // FRAMING-ONLY: mock dispatch counts only — live behavior is covered in real_window_interaction_tests.rs.
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 102, "method": "tools/call", "params": {"name": "click_element", "arguments": {"id": "counter_btn", "button": "right"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(
        res.is_error,
        "element-path click with button=right must be rejected, not coerced to Left"
    );
    assert_eq!(
        engine
            .controller
            .click_element_calls
            .load(Ordering::SeqCst),
        0
    );
    assert_eq!(engine.controller.click_at_calls.load(Ordering::SeqCst), 0);
}

/// Coordinate clicks must honor `button` through the pointer path.
#[tokio::test]
async fn test_phase1_coordinate_click_honors_button() {
    // FRAMING-ONLY: mock dispatch counts only — live behavior is covered in real_window_interaction_tests.rs.
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 103, "method": "tools/call", "params": {"name": "click_element", "arguments": {"x": 500.0, "y": 600.0, "button": "right"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    assert_eq!(engine.controller.click_at_calls.load(Ordering::SeqCst), 1);
    assert_eq!(*engine.controller.last_button.lock().await, Some(MouseButton::Right));
}

/// A single element click is exactly one backend action.
#[tokio::test]
async fn test_phase1_element_click_is_single_backend_action() {
    // FRAMING-ONLY: mock dispatch counts only — live behavior is covered in real_window_interaction_tests.rs.
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 104, "method": "tools/call", "params": {"name": "click_element", "arguments": {"id": "counter_btn"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    assert_eq!(
        engine
            .controller
            .click_element_calls
            .load(Ordering::SeqCst),
        1
    );
    assert_eq!(engine.controller.click_at_calls.load(Ordering::SeqCst), 0);
}

/// Unknown target ids must fail CLOSED (no silent fallback to active element).
#[tokio::test]
async fn test_phase1_send_keys_unknown_id_fails_closed() {
    // FRAMING-ONLY: mock dispatch counts only — live behavior is covered in real_window_interaction_tests.rs.
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 105, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": "hi", "element_id": "no_such_element_xyz"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error, "unknown element_id must fail closed");
    assert_eq!(engine.controller.send_keys_calls.load(Ordering::SeqCst), 0);
    assert_eq!(engine.controller.set_value_calls.load(Ordering::SeqCst), 0);
}

/// Exact role check: `tricky_btn` has role "button" with a type name
/// containing "Input". Substring sniffing wrongly calls it editable; the
/// Slint AccessibleRole exact check must reject it with exactly one
/// inspection and zero backend writes.
#[tokio::test]
async fn test_phase1_send_keys_rejects_non_text_role_despite_input_type() {
    // FRAMING-ONLY: mock dispatch counts only — live behavior is covered in real_window_interaction_tests.rs.
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 106, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": "hi", "element_id": "tricky_btn"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(
        res.is_error,
        "role=button must be rejected even when type contains 'Input'"
    );
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("not an editable text input"));
    assert_eq!(engine.controller.send_keys_calls.load(Ordering::SeqCst), 0);
}

/// `clear_first` failures must propagate instead of being discarded: one
/// `set_value` attempt, zero `send_keys`, error result.
#[tokio::test]
async fn test_phase1_send_keys_clear_first_error_propagates() {
    // FRAMING-ONLY: mock dispatch counts only — live behavior is covered in real_window_interaction_tests.rs.
    let engine = Arc::new(FullMockEngine {
        inspector: MockInspector,
        controller: MockController::with_failing_set_value(),
        state: MockStateProvider {
            properties: Mutex::new(HashMap::new()),
        },
        renderer: MockRenderer,
    });
    let server = McpServer::new(engine.clone());
    let raw = r#"{"jsonrpc": "2.0", "id": 107, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": "hi", "element_id": "email_input", "clear_first": true}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error, "clear_first set_value failure must propagate");
    assert_eq!(engine.controller.set_value_calls.load(Ordering::SeqCst), 1);
    assert_eq!(engine.controller.send_keys_calls.load(Ordering::SeqCst), 0);
}

/// FRAMING-ONLY: `clear_first` without a target is rejected before any backend
/// write (M2) — no silent no-clear success. Zero `set_value`/`send_keys` calls.
#[tokio::test]
async fn test_send_keys_clear_first_without_target_is_rejected() {
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 201, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": "hi", "clear_first": true}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error, "clear_first with no element_id must fail closed");
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("requires 'element_id'"));
    assert_eq!(engine.controller.set_value_calls.load(Ordering::SeqCst), 0);
    assert_eq!(engine.controller.send_keys_calls.load(Ordering::SeqCst), 0);
}

/// FRAMING-ONLY: `click_count` repeats the single-click dispatch literally
/// (M3) — a raw 3 performs three backend calls, never a silent clamp to 2.
#[tokio::test]
async fn test_tool_click_count_repeats_literally() {
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 202, "method": "tools/call", "params": {"name": "click_element", "arguments": {"id": "counter_btn", "click_count": 3}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    assert_eq!(engine.controller.click_element_calls.load(Ordering::SeqCst), 3);
}

/// FRAMING-ONLY: element selector + coordinates together are rejected (M4) —
/// exclusive targeting, fail closed. No backend call is issued.
#[tokio::test]
async fn test_tool_click_id_and_coordinates_rejected() {
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 203, "method": "tools/call", "params": {"name": "click_element", "arguments": {"id": "counter_btn", "x": 10.0, "y": 20.0}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error, "id+coordinates must be rejected, not silently prioritized");
    assert!(res.content[0].text.as_ref().unwrap().contains("not both"));
    assert_eq!(engine.controller.click_element_calls.load(Ordering::SeqCst), 0);
    assert_eq!(engine.controller.click_at_calls.load(Ordering::SeqCst), 0);
}

/// FRAMING-ONLY: the legacy `point: {x, y}` object remains accepted as an
/// alias for bare `x`/`y` (documents the asymmetry; canonical form is x/y).
#[tokio::test]
async fn test_tool_click_legacy_point_alias_accepted() {
    let (server, engine) = create_full_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 204, "method": "tools/call", "params": {"name": "click_element", "arguments": {"point": {"x": 270.0, "y": 80.0}}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error, "legacy point alias must keep working");
    assert_eq!(engine.controller.click_at_calls.load(Ordering::SeqCst), 1);
}
