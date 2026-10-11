//! Empirical Challenger verification suite for Milestone 1:
//! Correctness, speech-act semantics, performative validation, error propagation,
//! lifecycle management, backpressure resilience, and message throughput
//! of ACP extension traits (DefaultAcpEndpoint, MockAcpAdapter, MockAcpClient).

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::time::Duration;

use slate_agent::acp::{
    AcpEndpoint, AcpMessage, AcpPerformative, DefaultAcpEndpoint, MockAcpAdapter,
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

// ============================================================================
// Instrumented Test Mocks with Mutation Tracking
// ============================================================================

#[derive(Default)]
struct MutationTracker {
    pub click_count: AtomicUsize,
    pub click_at_count: AtomicUsize,
    pub send_keys_count: AtomicUsize,
    pub set_value_count: AtomicUsize,
    pub toggle_count: AtomicUsize,
    pub inspect_tree_count: AtomicUsize,
    pub find_element_count: AtomicUsize,
    pub get_state_count: AtomicUsize,
    pub get_diagnostics_count: AtomicUsize,
    pub get_screenshot_count: AtomicUsize,
}

struct TrackingInspector {
    tracker: Arc<MutationTracker>,
}

#[async_trait::async_trait]
impl UiInspector for TrackingInspector {
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        self.tracker.inspect_tree_count.fetch_add(1, Ordering::SeqCst);
        let root = UiElementNode {
            id: "win_main".to_string(),
            type_name: "Window".to_string(),
            bounds: Rect::new(0.0, 0.0, 1024.0, 768.0),
            label: Some("Main Window".to_string()),
            role: "Window".to_string(),
            value: None,
            enabled: true,
            focused: true,
            visible: true,
            children: vec![
                UiElementNode {
                    id: "btn_save".to_string(),
                    type_name: "Button".to_string(),
                    bounds: Rect::new(10.0, 10.0, 120.0, 40.0),
                    label: Some("Save Data".to_string()),
                    role: "Button".to_string(),
                    value: None,
                    enabled: true,
                    focused: false,
                    visible: true,
                    children: vec![],
                    properties: HashMap::new(),
                },
                UiElementNode {
                    id: "txt_input".to_string(),
                    type_name: "TextInput".to_string(),
                    bounds: Rect::new(150.0, 10.0, 200.0, 40.0),
                    label: Some("Enter text".to_string()),
                    role: "TextInput".to_string(),
                    value: Some("Initial".to_string()),
                    enabled: true,
                    focused: false,
                    visible: true,
                    children: vec![],
                    properties: HashMap::new(),
                },
            ],
            properties: HashMap::new(),
        };
        Ok(UiTree::new(root))
    }

    async fn find_element(&self, selector: &str) -> Result<UiElementNode, AgentError> {
        self.tracker.find_element_count.fetch_add(1, Ordering::SeqCst);
        if selector == "missing" || selector == "#missing" {
            return Err(AgentError::element_not_found(selector, "element not found"));
        }
        Ok(UiElementNode {
            id: selector.trim_start_matches('#').to_string(),
            type_name: "Button".to_string(),
            bounds: Rect::new(10.0, 10.0, 100.0, 30.0),
            label: Some(selector.to_string()),
            role: "Button".to_string(),
            value: None,
            enabled: true,
            focused: false,
            visible: true,
            children: vec![],
            properties: HashMap::new(),
        })
    }
}

struct TrackingController {
    tracker: Arc<MutationTracker>,
}

#[async_trait::async_trait]
impl ElementController for TrackingController {
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        self.tracker.click_count.fetch_add(1, Ordering::SeqCst);
        if target == "error_target" {
            return Err(AgentError::invalid_operation("Target cannot be clicked"));
        }
        Ok(ActionResult::success(format!("Clicked {target}")).with_element_id(target))
    }

    async fn click_at(&self, point: Point, button: MouseButton) -> Result<ActionResult, AgentError> {
        self.tracker.click_at_count.fetch_add(1, Ordering::SeqCst);
        Ok(ActionResult::success(format!("Clicked at ({}, {}) with {:?}", point.x, point.y, button)))
    }

    async fn send_keys(&self, target: Option<&str>, text: &str) -> Result<ActionResult, AgentError> {
        self.tracker.send_keys_count.fetch_add(1, Ordering::SeqCst);
        if target == Some("error_input") {
            return Err(AgentError::invalid_operation("Input rejected"));
        }
        Ok(ActionResult::success(format!("Typed '{text}' into {:?}", target)))
    }

    async fn set_value(&self, target: &str, value: &str) -> Result<ActionResult, AgentError> {
        self.tracker.set_value_count.fetch_add(1, Ordering::SeqCst);
        Ok(ActionResult::success(format!("Set {target} to {value}")))
    }

    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        self.tracker.toggle_count.fetch_add(1, Ordering::SeqCst);
        Ok(ActionResult::success(format!("Toggled {target}")))
    }
}

struct TrackingState {
    tracker: Arc<MutationTracker>,
}

#[async_trait::async_trait]
impl StateProvider for TrackingState {
    async fn get_state(&self, query: Option<&str>) -> Result<AppState, AgentError> {
        self.tracker.get_state_count.fetch_add(1, Ordering::SeqCst);
        let mut app_state = AppState::new("ActiveWorkspace");
        app_state = app_state.with_property("item_count", serde_json::json!(42));
        if let Some("failing_query") = query {
            return Err(AgentError::state_error("State unavailable for query"));
        }
        Ok(app_state)
    }

    async fn get_diagnostics(&self) -> Result<DiagnosticMetrics, AgentError> {
        self.tracker.get_diagnostics_count.fetch_add(1, Ordering::SeqCst);
        Ok(DiagnosticMetrics {
            fps: Some(120.0),
            memory_bytes: Some(1024 * 1024 * 32),
            ..Default::default()
        })
    }

    async fn set_property(&self, _key: &str, _value: serde_json::Value) -> Result<(), AgentError> {
        Ok(())
    }
}

struct TrackingRenderer {
    tracker: Arc<MutationTracker>,
}

#[async_trait::async_trait]
impl VisualRenderer for TrackingRenderer {
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError> {
        self.tracker.get_screenshot_count.fetch_add(1, Ordering::SeqCst);
        Ok(Screenshot::new(640, 480, "png", vec![0x89, b'P', b'N', b'G']))
    }

    async fn get_viewport_size(&self) -> Result<(u32, u32), AgentError> {
        Ok((640, 480))
    }
}

struct TrackingEngine {
    inspector: TrackingInspector,
    controller: TrackingController,
    state: TrackingState,
    renderer: TrackingRenderer,
}

impl TrackingEngine {
    fn new(tracker: Arc<MutationTracker>) -> Self {
        Self {
            inspector: TrackingInspector { tracker: tracker.clone() },
            controller: TrackingController { tracker: tracker.clone() },
            state: TrackingState { tracker: tracker.clone() },
            renderer: TrackingRenderer { tracker },
        }
    }
}

impl AutomationEngine for TrackingEngine {
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

// ============================================================================
// Group 1: Speech-Act Semantics & Performative Validation
// ============================================================================

#[tokio::test]
async fn test_query_rejects_all_mutating_actions_with_zero_side_effects() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let endpoint = DefaultAcpEndpoint::new(engine);

    let mutating_actions = [
        ("click", serde_json::json!({ "target": "btn_save" })),
        ("click_element", serde_json::json!({ "target": "btn_save" })),
        ("send_keys", serde_json::json!({ "target": "txt_input", "text": "hello" })),
        ("toggle", serde_json::json!({ "target": "chk_option" })),
        ("toggle_element", serde_json::json!({ "target": "chk_option" })),
    ];

    for (action, payload) in mutating_actions {
        let msg = AcpMessage::query(action, "adversarial-agent", payload);
        let resp = endpoint.dispatch_acp(msg.clone()).await.unwrap();

        // Must reject with failure response envelope
        assert!(
            !resp.success,
            "Query performative MUST reject mutating action '{}'",
            action
        );
        assert_eq!(resp.correlation_id, msg.message_id);
        assert!(
            resp.error
                .as_ref()
                .unwrap()
                .contains("Query performative cannot be used for mutating action"),
            "Error for '{}' was: {:?}",
            action,
            resp.error
        );
    }

    // CRITICAL: Empirically verify ZERO mutations executed on the underlying controller!
    assert_eq!(tracker.click_count.load(Ordering::SeqCst), 0, "Clicks must remain 0");
    assert_eq!(tracker.send_keys_count.load(Ordering::SeqCst), 0, "SendKeys must remain 0");
    assert_eq!(tracker.toggle_count.load(Ordering::SeqCst), 0, "Toggles must remain 0");
    assert_eq!(tracker.set_value_count.load(Ordering::SeqCst), 0, "SetValues must remain 0");
}

#[tokio::test]
async fn test_query_permits_all_readonly_actions() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let endpoint = DefaultAcpEndpoint::new(engine);

    let readonly_actions = [
        ("inspect_tree", serde_json::Value::Null),
        ("find_element", serde_json::json!({ "selector": "#btn_save" })),
        ("get_state", serde_json::Value::Null),
        ("get_diagnostics", serde_json::Value::Null),
        ("get_screenshot", serde_json::Value::Null),
        ("screenshot", serde_json::Value::Null),
    ];

    for (action, payload) in readonly_actions {
        let msg = AcpMessage::query(action, "benign-agent", payload);
        let resp = endpoint.dispatch_acp(msg.clone()).await.unwrap();

        assert!(
            resp.success,
            "Query performative MUST permit read-only action '{}'. Error: {:?}",
            action,
            resp.error
        );
        assert_eq!(resp.correlation_id, msg.message_id);
    }

    assert_eq!(tracker.inspect_tree_count.load(Ordering::SeqCst), 1);
    assert_eq!(tracker.find_element_count.load(Ordering::SeqCst), 1);
    assert_eq!(tracker.get_state_count.load(Ordering::SeqCst), 1);
    assert_eq!(tracker.get_diagnostics_count.load(Ordering::SeqCst), 1);
    assert_eq!(tracker.get_screenshot_count.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn test_inform_returns_acknowledgment_without_any_mutations() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let endpoint = DefaultAcpEndpoint::new(engine);

    let inform_test_cases = [
        ("pipeline_completed", serde_json::json!({ "job_id": 123 })),
        ("click", serde_json::json!({ "target": "btn_save" })),
        ("send_keys", serde_json::json!({ "text": "secret" })),
        ("toggle", serde_json::json!({ "target": "sw1" })),
    ];

    for (action, payload) in inform_test_cases {
        let msg = AcpMessage::inform(action, "telemetry-agent", payload);
        let resp = endpoint.dispatch_acp(msg.clone()).await.unwrap();

        assert!(resp.success, "Inform performative must always succeed");
        assert_eq!(resp.correlation_id, msg.message_id);
        assert_eq!(resp.data["status"], "acknowledged");
        assert_eq!(resp.data["action"], action);
        assert_eq!(resp.data["sender"], "telemetry-agent");
    }

    // Crucial check: Inform must NOT invoke controller even if action is "click"
    assert_eq!(tracker.click_count.load(Ordering::SeqCst), 0);
    assert_eq!(tracker.send_keys_count.load(Ordering::SeqCst), 0);
    assert_eq!(tracker.toggle_count.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn test_subscribe_issues_valid_subscription_tokens_without_mutations() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let endpoint = DefaultAcpEndpoint::new(engine);

    let sub_cases = [
        ("watcher-1", "ui_events"),
        ("watcher-2", "diagnostics"),
        ("watcher-3", "click"),
    ];

    for (sender, topic) in sub_cases {
        let msg = AcpMessage::subscribe(topic, sender, serde_json::Value::Null);
        let resp = endpoint.dispatch_acp(msg.clone()).await.unwrap();

        assert!(resp.success);
        assert_eq!(resp.correlation_id, msg.message_id);
        assert_eq!(resp.data["status"], "subscribed");
        assert_eq!(resp.data["topic"], topic);
        let expected_token = format!("sub-{sender}-{topic}");
        assert_eq!(resp.data["subscription_id"], expected_token);
    }

    assert_eq!(tracker.click_count.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn test_command_and_request_execute_mutations() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let endpoint = DefaultAcpEndpoint::new(engine);

    // Command mutations
    let cmd_click = AcpMessage::command("click", "agent", serde_json::json!({ "target": "btn_save" }));
    let res1 = endpoint.dispatch_acp(cmd_click).await.unwrap();
    assert!(res1.success);
    assert_eq!(tracker.click_count.load(Ordering::SeqCst), 1);

    let cmd_keys = AcpMessage::command("send_keys", "agent", serde_json::json!({ "target": "txt_input", "text": "foo" }));
    let res2 = endpoint.dispatch_acp(cmd_keys).await.unwrap();
    assert!(res2.success);
    assert_eq!(tracker.send_keys_count.load(Ordering::SeqCst), 1);

    let cmd_toggle = AcpMessage::command("toggle", "agent", serde_json::json!({ "target": "chk" }));
    let res3 = endpoint.dispatch_acp(cmd_toggle).await.unwrap();
    assert!(res3.success);
    assert_eq!(tracker.toggle_count.load(Ordering::SeqCst), 1);

    // Request mutations
    let req_click = AcpMessage::request("click", "agent", serde_json::json!({ "target": "btn_save" }));
    let res4 = endpoint.dispatch_acp(req_click).await.unwrap();
    assert!(res4.success);
    assert_eq!(tracker.click_count.load(Ordering::SeqCst), 2);

    let req_keys = AcpMessage::request("send_keys", "agent", serde_json::json!({ "target": "txt_input", "text": "bar" }));
    let res5 = endpoint.dispatch_acp(req_keys).await.unwrap();
    assert!(res5.success);
    assert_eq!(tracker.send_keys_count.load(Ordering::SeqCst), 2);

    let req_toggle = AcpMessage::request("toggle", "agent", serde_json::json!({ "target": "chk" }));
    let res6 = endpoint.dispatch_acp(req_toggle).await.unwrap();
    assert!(res6.success);
    assert_eq!(tracker.toggle_count.load(Ordering::SeqCst), 2);
}

// ============================================================================
// Group 2: Action Routing, Edge Cases & Error Handling
// ============================================================================

#[tokio::test]
async fn test_action_parameter_variants_and_missing_parameter_errors() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let endpoint = DefaultAcpEndpoint::new(engine);

    // 1. Missing parameters
    let missing_tests = [
        ("find_element", serde_json::json!({}), "Missing 'selector' parameter"),
        ("find_element", serde_json::json!(""), "Missing 'selector' parameter"),
        ("click", serde_json::json!({}), "Missing 'target' parameter for click action"),
        ("click", serde_json::json!(""), "Missing 'target' parameter for click action"),
        ("send_keys", serde_json::json!({ "target": "foo" }), "Missing 'text' parameter for send_keys action"),
        ("send_keys", serde_json::json!(1234), "Missing 'text' parameter for send_keys action"),
        ("toggle", serde_json::json!({}), "Missing 'target' parameter for toggle action"),
        ("toggle", serde_json::json!(""), "Missing 'target' parameter for toggle action"),
    ];

    for (action, payload, expected_err) in missing_tests {
        let msg = AcpMessage::command(action, "agent", payload);
        let resp = endpoint.dispatch_acp(msg).await.unwrap();
        assert!(!resp.success, "Action '{}' should fail on missing params", action);
        assert!(
            resp.error.as_ref().unwrap().contains(expected_err),
            "Expected '{}' in error: {:?}",
            expected_err,
            resp.error
        );
    }

    // 2. Flexible parameter formats (string vs object)
    // find_element with direct string
    let msg = AcpMessage::query("find_element", "agent", serde_json::json!("#btn_save"));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(resp.success);
    assert_eq!(resp.data["id"], "btn_save");

    // click with selector alias
    let msg = AcpMessage::command("click", "agent", serde_json::json!({ "selector": "#btn_save" }));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(resp.success);

    // send_keys with direct string
    let msg = AcpMessage::command("send_keys", "agent", serde_json::json!("raw text"));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(resp.success);

    // toggle with explicit state boolean
    let msg = AcpMessage::command("toggle", "agent", serde_json::json!({ "target": "chk", "state": true }));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(resp.success);

    // 3. Unknown action
    let msg = AcpMessage::command("quantum_teleport", "agent", serde_json::Value::Null);
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("Unsupported ACP action: 'quantum_teleport'"));
}

#[tokio::test]
async fn test_engine_errors_propagate_properly_through_acp() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let endpoint = DefaultAcpEndpoint::new(engine);

    // Controller error: click error_target
    let msg = AcpMessage::command("click", "agent", serde_json::json!({ "target": "error_target" }));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("Target cannot be clicked"));

    // Controller error: send_keys error_input
    let msg = AcpMessage::command("send_keys", "agent", serde_json::json!({ "target": "error_input", "text": "test" }));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("Input rejected"));

    // Inspector error: find_element missing
    let msg = AcpMessage::query("find_element", "agent", serde_json::json!("#missing"));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("element not found"));

    // State error: get_state failing_query
    let msg = AcpMessage::query("get_state", "agent", serde_json::json!("failing_query"));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("State unavailable for query"));
}

// ============================================================================
// Group 3: MockAcpClient & Server Lifecycle Verification
// ============================================================================

#[tokio::test]
async fn test_mock_acp_client_roundtrips_and_correlation_fidelity() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let mut adapter = MockAcpAdapter;
    let config = MockAcpConfig {
        agent_id: "test-roundtrip".into(),
        channel_capacity: 128,
    };

    let server_handle = adapter.attach(engine, config).unwrap();
    let client = server_handle.client();

    for i in 0..50 {
        let conv_id = format!("turn-{i}");
        let msg = AcpMessage::command(
            "click",
            "tester",
            serde_json::json!({ "target": format!("item_{i}") }),
        )
        .with_conversation_id(&conv_id)
        .with_timestamp(1700000000 + i as u64);

        let sent_id = msg.message_id.clone();
        let resp = client.send(msg).await.unwrap();

        assert!(resp.success);
        assert_eq!(resp.correlation_id, sent_id, "Correlation ID must strictly match sent message ID");
    }

    assert_eq!(tracker.click_count.load(Ordering::SeqCst), 50);
}

#[tokio::test]
async fn test_mock_acp_client_stopped_server_and_error_handling() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let mut adapter = MockAcpAdapter;
    let config = MockAcpConfig::default();

    let server_handle = adapter.attach(engine, config).unwrap();
    assert!(server_handle.is_running());
    let client = server_handle.client();

    // Verify it works before stopping
    let r1 = client.query("get_state", serde_json::Value::Null).await.unwrap();
    assert!(r1.success);

    // Stop server
    server_handle.stop().unwrap();
    tokio::time::sleep(Duration::from_millis(15)).await;
    assert!(!server_handle.is_running());

    // Subsequent dispatch direct call must return Err
    let direct_msg = AcpMessage::query("get_state", "agent", serde_json::Value::Null);
    let direct_err = server_handle.dispatch(direct_msg).await;
    assert!(direct_err.is_err());
    assert!(direct_err.err().unwrap().to_string().contains("ACP adapter is stopped"));

    // Subsequent client.send calls must return Err
    let client_msg = AcpMessage::query("get_state", "agent", serde_json::Value::Null);
    let client_err = client.send(client_msg).await;
    assert!(client_err.is_err());

    // Calling stop multiple times is safe (idempotent)
    assert!(server_handle.stop().is_ok());
}

#[tokio::test]
async fn test_mock_acp_adapter_drop_cleans_up() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let mut adapter = MockAcpAdapter;
    let client = {
        let handle = adapter.attach(engine, MockAcpConfig::default()).unwrap();
        handle.client()
        // handle is dropped here, invoking Drop -> stop()
    };

    tokio::time::sleep(Duration::from_millis(15)).await;
    let msg = AcpMessage::query("get_state", "agent", serde_json::Value::Null);
    let res = client.send(msg).await;
    assert!(res.is_err(), "Client must fail after server handle dropped");
}

// ============================================================================
// Group 4: High Throughput, Concurrency & Stress Harnesses
// ============================================================================

#[tokio::test]
async fn test_concurrent_burst_throughput_and_stress() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let mut adapter = MockAcpAdapter;
    let config = MockAcpConfig {
        agent_id: "bench-adapter".into(),
        channel_capacity: 256,
    };

    let server_handle = adapter.attach(engine, config).unwrap();
    let num_tasks = 20;
    let msgs_per_task = 100;
    let total_messages = num_tasks * msgs_per_task;

    let start = Instant::now();
    let mut join_handles = Vec::with_capacity(num_tasks);

    for task_idx in 0..num_tasks {
        let client = server_handle.client();
        let handle = tokio::spawn(async move {
            let mut matched_ids = 0;
            for i in 0..msgs_per_task {
                let action = match i % 4 {
                    0 => "click",
                    1 => "get_state",
                    2 => "inspect_tree",
                    _ => "find_element",
                };
                let payload = match action {
                    "click" => serde_json::json!({ "target": format!("btn_{task_idx}_{i}") }),
                    "find_element" => serde_json::json!({ "selector": "#btn_save" }),
                    _ => serde_json::Value::Null,
                };
                let performative = if action == "click" {
                    AcpPerformative::Command
                } else {
                    AcpPerformative::Query
                };
                let msg = AcpMessage::new(
                    performative,
                    action,
                    format!("worker-{task_idx}"),
                    payload,
                );
                let sent_id = msg.message_id.clone();
                let resp = client.send(msg).await.expect("send should succeed");
                assert!(resp.success);
                if resp.correlation_id == sent_id {
                    matched_ids += 1;
                }
            }
            matched_ids
        });
        join_handles.push(handle);
    }

    let mut total_matched = 0;
    for handle in join_handles {
        let matched = handle.await.unwrap();
        total_matched += matched;
    }

    let duration = start.elapsed();
    let throughput = (total_messages as f64) / duration.as_secs_f64();

    println!(
        "\n[BENCHMARK] Throughput: {:.2} msgs/sec ({} messages in {:?}) across {} concurrent tasks",
        throughput, total_messages, duration, num_tasks
    );

    assert_eq!(total_matched, total_messages);
    // 20 tasks * 25 clicks each (since i % 4 == 0) = 500 clicks
    assert_eq!(tracker.click_count.load(Ordering::SeqCst), (total_messages / 4));
}

#[tokio::test]
async fn test_small_channel_backpressure_resilience() {
    let tracker = Arc::new(MutationTracker::default());
    let engine = Arc::new(TrackingEngine::new(tracker.clone()));
    let mut adapter = MockAcpAdapter;
    // Tiny channel capacity of 1 forces constant backpressure and queue waiting
    let config = MockAcpConfig {
        agent_id: "backpressure-adapter".into(),
        channel_capacity: 1,
    };

    let server_handle = adapter.attach(engine, config).unwrap();
    let num_tasks = 10;
    let msgs_per_task = 50;
    let total_messages = num_tasks * msgs_per_task;

    let mut join_handles = Vec::with_capacity(num_tasks);
    for t in 0..num_tasks {
        let client = server_handle.client();
        let handle = tokio::spawn(async move {
            for i in 0..msgs_per_task {
                let msg = AcpMessage::command("click", format!("agent-{t}"), serde_json::json!({ "target": format!("t_{t}_{i}") }));
                let resp = client.send(msg).await.unwrap();
                assert!(resp.success);
            }
        });
        join_handles.push(handle);
    }

    for h in join_handles {
        h.await.unwrap();
    }

    assert_eq!(tracker.click_count.load(Ordering::SeqCst), total_messages);
}

#[tokio::test]
async fn test_message_id_uniqueness_under_heavy_concurrency() {
    let num_tasks = 16;
    let per_task = 625; // 16 * 625 = 10,000 unique IDs
    let total_expected = num_tasks * per_task;

    let mut join_handles = Vec::with_capacity(num_tasks);
    for t in 0..num_tasks {
        let handle = tokio::spawn(async move {
            let mut ids = Vec::with_capacity(per_task);
            for i in 0..per_task {
                let msg = AcpMessage::query(
                    "inspect_tree",
                    format!("gen-{t}-{i}"),
                    serde_json::Value::Null,
                );
                ids.push(msg.message_id);
            }
            ids
        });
        join_handles.push(handle);
    }

    let mut all_ids = HashSet::with_capacity(total_expected);
    for h in join_handles {
        let ids = h.await.unwrap();
        for id in ids {
            assert!(all_ids.insert(id), "Duplicate message ID detected!");
        }
    }

    assert_eq!(all_ids.len(), total_expected, "All 10,000 message IDs must be unique");
}
