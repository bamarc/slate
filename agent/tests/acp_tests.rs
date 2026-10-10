//! Unit tests for ACP extension traits, performatives, message routing, and MockAcpAdapter.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::time::Duration;

use slate_agent::acp::{
    AcpEndpoint, AcpMessage, AcpPerformative, AcpResponse, DefaultAcpEndpoint, MockAcpAdapter,
    MockAcpConfig,
};
use slate_agent::error::AgentError;
use slate_agent::model::{
    ActionResult, AppState, DiagnosticMetrics, MouseButton, Point, Rect, Screenshot,
    UiElementNode, UiTree,
};
use slate_agent::protocol::{AgentProtocolAdapter, ProtocolServerHandle};
use slate_agent::traits::{
    AutomationEngine, ElementController, StateProvider, UiInspector, VisualRenderer,
};

// Mock sub-systems for isolated testing
struct MockInspector;
#[async_trait::async_trait]
impl UiInspector for MockInspector {
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        let root = UiElementNode {
            id: "window_main".to_string(),
            type_name: "Window".to_string(),
            bounds: Rect::new(0.0, 0.0, 800.0, 600.0),
            label: Some("Slate Showcase".to_string()),
            role: "Window".to_string(),
            value: None,
            enabled: true,
            focused: true,
            visible: true,
            children: vec![UiElementNode {
                id: "btn_calculate".to_string(),
                type_name: "Button".to_string(),
                bounds: Rect::new(10.0, 10.0, 100.0, 30.0),
                label: Some("Calculate Pi".to_string()),
                role: "Button".to_string(),
                value: None,
                enabled: true,
                focused: false,
                visible: true,
                children: vec![],
                properties: HashMap::new(),
            }],
            properties: HashMap::new(),
        };
        Ok(UiTree::new(root))
    }
}

struct MockController;
#[async_trait::async_trait]
impl ElementController for MockController {
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Clicked '{}'", target)).with_element_id(target))
    }
    async fn click_at(&self, point: Point, button: MouseButton) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!(
            "Clicked at ({}, {}) with {:?}",
            point.x, point.y, button
        )))
    }
    async fn send_keys(&self, target: Option<&str>, text: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Sent '{}' to {:?}", text, target)))
    }
    async fn set_value(&self, target: &str, value: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Set '{}' to '{}'", target, value)))
    }
    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Toggled '{}'", target)))
    }
}

struct MockState;
#[async_trait::async_trait]
impl StateProvider for MockState {
    async fn get_state(&self, query: Option<&str>) -> Result<AppState, AgentError> {
        let mut state = AppState::new("ComputeView");
        state = state.with_property("progress", serde_json::json!(0.75));
        if let Some(q) = query {
            if q == "progress" {
                return Ok(state);
            }
        }
        Ok(state)
    }
    async fn get_diagnostics(&self) -> Result<DiagnosticMetrics, AgentError> {
        Ok(DiagnosticMetrics {
            fps: Some(60.0),
            ..Default::default()
        })
    }
    async fn set_property(&self, _key: &str, _value: serde_json::Value) -> Result<(), AgentError> {
        Ok(())
    }
}

struct MockRenderer;
#[async_trait::async_trait]
impl VisualRenderer for MockRenderer {
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError> {
        Ok(Screenshot::new(100, 100, "png", vec![1, 2, 3, 4]))
    }
    async fn get_viewport_size(&self) -> Result<(u32, u32), AgentError> {
        Ok((100, 100))
    }
}

struct TestAutomationEngine {
    inspector: MockInspector,
    controller: MockController,
    state: MockState,
    renderer: MockRenderer,
}

impl TestAutomationEngine {
    fn new() -> Self {
        Self {
            inspector: MockInspector,
            controller: MockController,
            state: MockState,
            renderer: MockRenderer,
        }
    }
}

impl AutomationEngine for TestAutomationEngine {
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

#[test]
fn test_acp_performative_properties() {
    assert!(AcpPerformative::Query.is_read_only());
    assert!(!AcpPerformative::Command.is_read_only());
    assert!(!AcpPerformative::Request.is_read_only());

    assert!(AcpPerformative::Command.allows_mutation());
    assert!(AcpPerformative::Request.allows_mutation());
    assert!(!AcpPerformative::Query.allows_mutation());

    assert!(AcpPerformative::Query.expects_response());
    assert!(AcpPerformative::Command.expects_response());
    assert!(AcpPerformative::Request.expects_response());
    assert!(!AcpPerformative::Inform.expects_response());

    // Serde serialization
    let json = serde_json::to_string(&AcpPerformative::Query).unwrap();
    assert_eq!(json, "\"query\"");

    // Case-insensitive deserialization
    let p1: AcpPerformative = serde_json::from_str("\"query\"").unwrap();
    assert_eq!(p1, AcpPerformative::Query);
    let p2: AcpPerformative = serde_json::from_str("\"Query\"").unwrap();
    assert_eq!(p2, AcpPerformative::Query);
    let p3: AcpPerformative = serde_json::from_str("\"Request\"").unwrap();
    assert_eq!(p3, AcpPerformative::Request);
}

#[test]
fn test_acp_message_creation_and_envelopes() {
    let msg = AcpMessage::command(
        "click",
        "agent-007",
        serde_json::json!({ "target": "btn_start" }),
    )
    .with_conversation_id("conv-123")
    .with_timestamp(1700000000);

    assert!(msg.message_id.starts_with("acp-msg-"));
    assert_eq!(msg.performative, AcpPerformative::Command);
    assert_eq!(msg.action, "click");
    assert_eq!(msg.sender, "agent-007");
    assert_eq!(msg.conversation_id.as_deref(), Some("conv-123"));
    assert_eq!(msg.timestamp_ms, Some(1700000000));

    // Serde roundtrip
    let json = serde_json::to_string(&msg).unwrap();
    let deserialized: AcpMessage = serde_json::from_str(&json).unwrap();
    assert_eq!(deserialized, msg);
}

#[test]
fn test_acp_response_from_result() {
    let ok_res: Result<String, AgentError> = Ok("success_val".to_string());
    let resp1 = AcpResponse::from_result("msg-1", ok_res);
    assert!(resp1.success);
    assert_eq!(resp1.correlation_id, "msg-1");
    assert_eq!(resp1.data, serde_json::json!("success_val"));
    assert!(resp1.error.is_none());

    let err_res: Result<String, AgentError> = Err(AgentError::internal("crash"));
    let resp2 = AcpResponse::from_result("msg-2", err_res);
    assert!(!resp2.success);
    assert_eq!(resp2.correlation_id, "msg-2");
    assert!(resp2.error.unwrap().contains("crash"));
}

#[tokio::test]
async fn test_acp_endpoint_query_readonly_enforcement() {
    let engine = Arc::new(TestAutomationEngine::new());
    let endpoint = DefaultAcpEndpoint::new(engine);

    // Query on mutating action "click" must be actively rejected
    let query_click = AcpMessage::query(
        "click",
        "agent-1",
        serde_json::json!({ "target": "btn_start" }),
    );
    let resp = endpoint.dispatch_acp(query_click).await.unwrap();
    assert!(!resp.success);
    assert!(resp
        .error
        .unwrap()
        .contains("Query performative cannot be used for mutating action 'click'"));
}

#[tokio::test]
async fn test_acp_endpoint_inform_and_subscribe() {
    let engine = Arc::new(TestAutomationEngine::new());
    let endpoint = DefaultAcpEndpoint::new(engine);

    // Inform
    let inform_msg = AcpMessage::inform(
        "task_completed",
        "worker-1",
        serde_json::json!({ "progress": 1.0 }),
    );
    let resp = endpoint.dispatch_acp(inform_msg).await.unwrap();
    assert!(resp.success);
    assert_eq!(resp.data.get("status"), Some(&serde_json::json!("acknowledged")));

    // Subscribe
    let sub_msg = AcpMessage::subscribe(
        "task_progress",
        "listener-1",
        serde_json::Value::Null,
    );
    let sub_resp = endpoint.dispatch_acp(sub_msg).await.unwrap();
    assert!(sub_resp.success);
    assert_eq!(
        sub_resp.data.get("subscription_id"),
        Some(&serde_json::json!("sub-listener-1-task_progress"))
    );
}

#[tokio::test]
async fn test_acp_endpoint_action_routing() {
    let engine = Arc::new(TestAutomationEngine::new());
    let endpoint = DefaultAcpEndpoint::new(engine);

    // 1. inspect_tree
    let inspect_msg = AcpMessage::query("inspect_tree", "agent-1", serde_json::Value::Null);
    let res = endpoint.dispatch_acp(inspect_msg).await.unwrap();
    assert!(res.success);
    assert!(res.data.get("root").is_some());

    // 2. find_element
    let find_msg = AcpMessage::query(
        "find_element",
        "agent-1",
        serde_json::json!({ "selector": "#btn_calculate" }),
    );
    let find_res = endpoint.dispatch_acp(find_msg).await.unwrap();
    assert!(find_res.success);
    assert_eq!(find_res.data.get("id"), Some(&serde_json::json!("btn_calculate")));

    // 3. click
    let click_msg = AcpMessage::command(
        "click",
        "agent-1",
        serde_json::json!({ "target": "btn_calculate" }),
    );
    let click_res = endpoint.dispatch_acp(click_msg).await.unwrap();
    assert!(click_res.success);
    assert!(click_res.data.get("message").unwrap().as_str().unwrap().contains("Clicked"));

    // 4. send_keys
    let keys_msg = AcpMessage::command(
        "send_keys",
        "agent-1",
        serde_json::json!({ "target": "input_val", "text": "42" }),
    );
    let keys_res = endpoint.dispatch_acp(keys_msg).await.unwrap();
    assert!(keys_res.success);

    // 5. get_state
    let state_msg = AcpMessage::query("get_state", "agent-1", serde_json::Value::Null);
    let state_res = endpoint.dispatch_acp(state_msg).await.unwrap();
    assert!(state_res.success);
    assert_eq!(
        state_res.data.get("active_view"),
        Some(&serde_json::json!("ComputeView"))
    );

    // 6. get_screenshot
    let shot_msg = AcpMessage::query("get_screenshot", "agent-1", serde_json::Value::Null);
    let shot_res = endpoint.dispatch_acp(shot_msg).await.unwrap();
    assert!(shot_res.success);
    assert!(shot_res.data.get("data_base64").is_some());

    // 7. unknown action
    let unknown_msg = AcpMessage::request("fly_to_moon", "agent-1", serde_json::Value::Null);
    let unk_res = endpoint.dispatch_acp(unknown_msg).await.unwrap();
    assert!(!unk_res.success);
    assert!(unk_res.error.unwrap().contains("Unsupported ACP action"));
}

#[tokio::test]
async fn test_mock_acp_adapter_lifecycle_and_channel() {
    let engine = Arc::new(TestAutomationEngine::new());
    let mut adapter = MockAcpAdapter;
    let config = MockAcpConfig {
        agent_id: "test-acp".into(),
        channel_capacity: 16,
    };

    let server_handle = adapter.attach(engine, config).unwrap();
    assert!(server_handle.is_running());
    assert_eq!(
        server_handle.local_addr(),
        Some("inproc://mock-acp".to_string())
    );

    let client = server_handle.client();

    // Query via channel client
    let query_resp = client
        .query("get_state", serde_json::Value::Null)
        .await
        .unwrap();
    assert!(query_resp.success);
    assert_eq!(
        query_resp.data.get("active_view"),
        Some(&serde_json::json!("ComputeView"))
    );

    // Command via channel client
    let cmd_resp = client
        .command(
            "click",
            serde_json::json!({ "target": "btn_calculate" }),
        )
        .await
        .unwrap();
    assert!(cmd_resp.success);

    // Stop handle
    server_handle.stop().unwrap();
    tokio::time::sleep(Duration::from_millis(10)).await;
    assert!(!server_handle.is_running());
}
