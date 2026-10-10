//! Adversarial stress testing for slate-mcp transport concurrency, lifecycle, and tool boundaries.

use image::ImageEncoder;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;

use slate_agent::error::AgentError;
use slate_agent::model::{
    ActionResult, AppState, DiagnosticMetrics, MouseButton, Point, Rect, Screenshot,
    UiElementNode, UiTree,
};
use slate_agent::protocol::ProtocolServerHandle;
use slate_agent::traits::{
    AutomationEngine, ElementController, StateProvider, UiInspector, VisualRenderer,
};
use slate_mcp::schema::ToolCallResult;
use slate_mcp::server::{JsonRpcResponse, McpServer};
use slate_mcp::transport::create_in_memory_session;

// ============================================================================
// Adversarial Mock Automation Engine
// ============================================================================

struct AdversarialInspector {
    deep_tree_depth: usize,
    wide_tree_count: usize,
}

#[async_trait::async_trait]
impl UiInspector for AdversarialInspector {
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        if self.wide_tree_count > 0 {
            // Build wide tree with thousands of child elements
            let children: Vec<UiElementNode> = (0..self.wide_tree_count)
                .map(|i| UiElementNode {
                    id: format!("wide_child_{}", i),
                    type_name: "SlateButton".to_string(),
                    bounds: Rect::new(0.0, (i as f32) * 10.0, 100.0, 10.0),
                    label: Some(format!("Item {}", i)),
                    role: "button".to_string(),
                    value: None,
                    enabled: true,
                    focused: false,
                    visible: true,
                    children: Vec::new(),
                    properties: HashMap::new(),
                })
                .collect();

            let root = UiElementNode {
                id: "root_window".to_string(),
                type_name: "Window".to_string(),
                bounds: Rect::new(0.0, 0.0, 1040.0, 720.0),
                label: Some("Wide Showcase".to_string()),
                role: "Window".to_string(),
                value: None,
                enabled: true,
                focused: false,
                visible: true,
                children,
                properties: HashMap::new(),
            };

            return Ok(UiTree::new(root).with_window_info("Wide Showcase", 1040.0, 720.0));
        }

        if self.deep_tree_depth > 0 {
            // Build deeply nested UI hierarchy
            let mut current = UiElementNode {
                id: format!("node_{}", self.deep_tree_depth),
                type_name: "LeafNode".to_string(),
                bounds: Rect::new(0.0, 0.0, 10.0, 10.0),
                label: Some(format!("Leaf {}", self.deep_tree_depth)),
                role: "leaf".to_string(),
                value: None,
                enabled: true,
                focused: false,
                visible: true,
                children: Vec::new(),
                properties: HashMap::new(),
            };

            for level in (1..self.deep_tree_depth).rev() {
                let parent = UiElementNode {
                    id: format!("node_{}", level),
                    type_name: "ContainerNode".to_string(),
                    bounds: Rect::new(0.0, 0.0, 100.0, 100.0),
                    label: Some(format!("Level {}", level)),
                    role: "container".to_string(),
                    value: None,
                    enabled: true,
                    focused: false,
                    visible: true,
                    children: vec![current],
                    properties: HashMap::new(),
                };
                current = parent;
            }

            let root = UiElementNode {
                id: "root_window".to_string(),
                type_name: "Window".to_string(),
                bounds: Rect::new(0.0, 0.0, 1040.0, 720.0),
                label: Some("Deep Showcase".to_string()),
                role: "Window".to_string(),
                value: None,
                enabled: true,
                focused: false,
                visible: true,
                children: vec![current],
                properties: HashMap::new(),
            };

            return Ok(UiTree::new(root).with_window_info("Deep Showcase", 1040.0, 720.0));
        }

        // Standard rich tree with diverse controls
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

struct AdversarialController {
    click_count: AtomicI32,
    typed_text: Mutex<String>,
    simulated_delay_ms: AtomicUsize,
}

#[async_trait::async_trait]
impl ElementController for AdversarialController {
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        let delay = self.simulated_delay_ms.load(Ordering::Relaxed);
        if delay > 0 {
            tokio::time::sleep(Duration::from_millis(delay as u64)).await;
        }
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
        let delay = self.simulated_delay_ms.load(Ordering::Relaxed);
        if delay > 0 {
            tokio::time::sleep(Duration::from_millis(delay as u64)).await;
        }
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
        let delay = self.simulated_delay_ms.load(Ordering::Relaxed);
        if delay > 0 {
            tokio::time::sleep(Duration::from_millis(delay as u64)).await;
        }
        let mut val = self.typed_text.lock().await;
        val.push_str(text);
        let msg = match target {
            Some(t) => format!("Typed {} bytes into '{}'", text.len(), t),
            None => format!("Typed {} bytes into active element", text.len()),
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

struct AdversarialStateProvider {
    properties: Mutex<HashMap<String, serde_json::Value>>,
}

#[async_trait::async_trait]
impl StateProvider for AdversarialStateProvider {
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

    async fn get_diagnostics(&self) -> Result<DiagnosticMetrics, AgentError> {
        Ok(DiagnosticMetrics::default())
    }

    async fn set_property(&self, key: &str, value: serde_json::Value) -> Result<(), AgentError> {
        self.properties.lock().await.insert(key.to_string(), value);
        Ok(())
    }
}

struct AdversarialRenderer;

#[async_trait::async_trait]
impl VisualRenderer for AdversarialRenderer {
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

struct AdversarialEngine {
    inspector: AdversarialInspector,
    controller: AdversarialController,
    state: AdversarialStateProvider,
    renderer: AdversarialRenderer,
}

impl AdversarialEngine {
    fn new(deep_tree_depth: usize, wide_tree_count: usize) -> Self {
        let mut initial_props = HashMap::new();
        initial_props.insert("counter".to_string(), serde_json::json!(42));

        Self {
            inspector: AdversarialInspector {
                deep_tree_depth,
                wide_tree_count,
            },
            controller: AdversarialController {
                click_count: AtomicI32::new(0),
                typed_text: Mutex::new(String::new()),
                simulated_delay_ms: AtomicUsize::new(0),
            },
            state: AdversarialStateProvider {
                properties: Mutex::new(initial_props),
            },
            renderer: AdversarialRenderer,
        }
    }
}

#[async_trait::async_trait]
impl AutomationEngine for AdversarialEngine {
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

fn create_adversarial_server(
    deep_tree: usize,
    wide_tree: usize,
) -> (McpServer, Arc<AdversarialEngine>) {
    let engine = Arc::new(AdversarialEngine::new(deep_tree, wide_tree));
    (McpServer::new(engine.clone()), engine)
}

// ============================================================================
// 1. Concurrent Bursts (50 to 100 requests) over Duplex Streams
// ============================================================================

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_adversarial_burst_100_concurrent_requests_ping() {
    let (server, _) = create_adversarial_server(0, 0);
    let (client_stream, handle) = create_in_memory_session(Arc::new(server), 262144);

    let (reader, writer) = tokio::io::split(client_stream);
    let shared_writer = Arc::new(Mutex::new(writer));
    let mut buf_reader = BufReader::new(reader);

    let mut send_tasks = Vec::new();
    // Launch 100 concurrent async tasks that write simultaneously
    for i in 1..=100 {
        let w = shared_writer.clone();
        send_tasks.push(tokio::spawn(async move {
            let req = format!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}}\n", i);
            let mut guard = w.lock().await;
            guard.write_all(req.as_bytes()).await.unwrap();
            guard.flush().await.unwrap();
        }));
    }

    // Wait for all senders to dispatch
    for t in send_tasks {
        t.await.unwrap();
    }

    // Read exactly 100 responses
    let mut received_ids = std::collections::HashSet::new();
    for _ in 1..=100 {
        let mut line = String::new();
        let bytes_read = tokio::time::timeout(
            Duration::from_secs(5),
            buf_reader.read_line(&mut line),
        )
        .await
        .expect("Timeout reading response from 100-request burst")
        .expect("I/O error reading response");

        assert!(bytes_read > 0, "Premature EOF during response reading");
        let resp: JsonRpcResponse = serde_json::from_str(&line).unwrap_or_else(|e| {
            panic!("Malformed JSON-RPC line received: '{}', err: {}", line, e);
        });

        assert_eq!(resp.jsonrpc, "2.0");
        assert!(resp.error.is_none());
        let id_num = resp.id.unwrap().as_i64().unwrap();
        received_ids.insert(id_num);
    }

    assert_eq!(received_ids.len(), 100, "Did not receive all 100 unique responses");
    for i in 1..=100 {
        assert!(received_ids.contains(&i), "Missing response ID {}", i);
    }

    handle.stop().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_adversarial_burst_100_mixed_tools_and_resources() {
    let (server, _) = create_adversarial_server(0, 0);
    let (client_stream, handle) = create_in_memory_session(Arc::new(server), 262144);

    let (reader, writer) = tokio::io::split(client_stream);
    let shared_writer = Arc::new(Mutex::new(writer));
    let mut buf_reader = BufReader::new(reader);

    // Prepare 100 heterogeneous requests (tools/call, tools/list, resources/list, resources/read, ping)
    let methods = vec![
        r#"{"jsonrpc":"2.0","id":__ID__,"method":"ping"}"#,
        r#"{"jsonrpc":"2.0","id":__ID__,"method":"tools/list"}"#,
        r#"{"jsonrpc":"2.0","id":__ID__,"method":"resources/list"}"#,
        r#"{"jsonrpc":"2.0","id":__ID__,"method":"resources/read","params":{"uri":"slate://context"}}"#,
        r#"{"jsonrpc":"2.0","id":__ID__,"method":"tools/call","params":{"name":"get_state","arguments":{}}}"#,
        r#"{"jsonrpc":"2.0","id":__ID__,"method":"tools/call","params":{"name":"inspect_tree","arguments":{}}}"#,
        r#"{"jsonrpc":"2.0","id":__ID__,"method":"tools/call","params":{"name":"get_screenshot","arguments":{}}}"#,
    ];

    let mut send_tasks = Vec::new();
    for i in 1..=100 {
        let pattern = methods[(i as usize) % methods.len()];
        let req = pattern.replace("__ID__", &i.to_string()) + "\n";
        let w = shared_writer.clone();

        send_tasks.push(tokio::spawn(async move {
            let mut guard = w.lock().await;
            guard.write_all(req.as_bytes()).await.unwrap();
            guard.flush().await.unwrap();
        }));
    }

    for t in send_tasks {
        t.await.unwrap();
    }

    let mut received_ids = std::collections::HashSet::new();
    for _ in 1..=100 {
        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(5), buf_reader.read_line(&mut line))
            .await
            .expect("Timeout on mixed request reading")
            .expect("I/O error reading response");

        let resp: JsonRpcResponse = serde_json::from_str(&line).unwrap_or_else(|e| {
            panic!("Invalid response JSON: '{}', error: {}", line, e);
        });

        assert_eq!(resp.jsonrpc, "2.0");
        let id_num = resp.id.unwrap().as_i64().unwrap();
        received_ids.insert(id_num);
    }

    assert_eq!(received_ids.len(), 100);
    for i in 1..=100 {
        assert!(received_ids.contains(&i), "Missing ID {}", i);
    }

    handle.stop().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_adversarial_gui_event_loop_non_blocking_during_burst() {
    let (server, _) = create_adversarial_server(0, 0);
    let (client_stream, handle) = create_in_memory_session(Arc::new(server), 262144);

    let (reader, writer) = tokio::io::split(client_stream);
    let shared_writer = Arc::new(Mutex::new(writer));
    let mut buf_reader = BufReader::new(reader);

    // Simulate GUI event loop heartbeat ticker: ticks every 5ms
    let gui_running = Arc::new(AtomicBool::new(true));
    let max_jitter_ms = Arc::new(AtomicUsize::new(0));

    let gui_flag = gui_running.clone();
    let jitter_record = max_jitter_ms.clone();
    let gui_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(5));
        let mut last_tick = Instant::now();
        while gui_flag.load(Ordering::Relaxed) {
            interval.tick().await;
            let elapsed = last_tick.elapsed().as_millis() as usize;
            if elapsed > 5 {
                let jitter = elapsed - 5;
                jitter_record.fetch_max(jitter, Ordering::Relaxed);
            }
            last_tick = Instant::now();
        }
    });

    // Send 100 heavy tool requests while GUI is ticking
    let mut send_tasks = Vec::new();
    for i in 1..=100 {
        let w = shared_writer.clone();
        send_tasks.push(tokio::spawn(async move {
            let req = format!(
                "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"tools/call\",\"params\":{{\"name\":\"get_state\",\"arguments\":{{}}}}}}\n",
                i
            );
            let mut guard = w.lock().await;
            guard.write_all(req.as_bytes()).await.unwrap();
            guard.flush().await.unwrap();
        }));
    }

    for t in send_tasks {
        t.await.unwrap();
    }

    for _ in 1..=100 {
        let mut line = String::new();
        buf_reader.read_line(&mut line).await.unwrap();
    }

    // Stop GUI heartbeat and analyze jitter
    gui_running.store(false, Ordering::Relaxed);
    gui_task.await.unwrap();

    let worst_jitter = max_jitter_ms.load(Ordering::Relaxed);
    // Verified that GUI event loop ticker did not freeze (worst jitter under 50ms)
    assert!(
        worst_jitter < 50,
        "Event loop experienced significant freeze: {}ms jitter",
        worst_jitter
    );

    handle.stop().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_adversarial_50_concurrent_independent_sessions() {
    let (server, _) = create_adversarial_server(0, 0);
    let srv_arc = Arc::new(server);

    let mut session_tasks = Vec::new();
    // Spawn 50 separate sessions running in parallel
    for session_idx in 0..50 {
        let s = srv_arc.clone();
        session_tasks.push(tokio::spawn(async move {
            let (client_stream, handle) = create_in_memory_session(s, 65536);
            let (reader, mut writer) = tokio::io::split(client_stream);
            let mut buf_reader = BufReader::new(reader);

            let req = format!(
                "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}}\n",
                session_idx
            );
            writer.write_all(req.as_bytes()).await.unwrap();
            writer.flush().await.unwrap();

            let mut resp_line = String::new();
            buf_reader.read_line(&mut resp_line).await.unwrap();

            let resp: JsonRpcResponse = serde_json::from_str(&resp_line).unwrap();
            assert_eq!(resp.id, Some(serde_json::json!(session_idx)));

            handle.stop().unwrap();
        }));
    }

    for t in session_tasks {
        t.await.unwrap();
    }
}

// ============================================================================
// 2. Abrupt Client Disconnects (EOF) & Teardown
// ============================================================================

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_adversarial_abrupt_disconnect_during_inflight_requests() {
    let (server, engine) = create_adversarial_server(0, 0);
    // Simulate 30ms latency inside the controller
    engine.controller.simulated_delay_ms.store(30, Ordering::Relaxed);

    let (client_stream, handle) = create_in_memory_session(Arc::new(server), 65536);
    let (_reader, mut writer) = tokio::io::split(client_stream);

    // Send 30 requests that each take 30ms
    for i in 1..=30 {
        let req = format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"tools/call\",\"params\":{{\"name\":\"click_element\",\"arguments\":{{\"id\":\"counter_btn\"}}}}}}\n",
            i
        );
        writer.write_all(req.as_bytes()).await.unwrap();
    }
    writer.flush().await.unwrap();

    // Sleep briefly so requests are in-flight, then abruptly drop both reader and writer
    tokio::time::sleep(Duration::from_millis(10)).await;
    drop(writer);
    drop(_reader);

    // Verify handle detects termination cleanly within 2 seconds without freezing or panicking
    let wait_res = tokio::time::timeout(Duration::from_secs(2), async {
        while handle.is_running() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;

    assert!(wait_res.is_ok(), "Server loop did not cleanly terminate after abrupt client drop");
    assert!(!handle.is_running());
}

#[tokio::test]
async fn test_adversarial_abrupt_disconnect_partial_line() {
    let (server, _) = create_adversarial_server(0, 0);
    let (client_stream, handle) = create_in_memory_session(Arc::new(server), 65536);
    let (reader, mut writer) = tokio::io::split(client_stream);

    // Send truncated JSON line without terminating newline and abruptly drop
    let partial = "{\"jsonrpc\":\"2.0\",\"id\":999,\"method\":\"pi";
    writer.write_all(partial.as_bytes()).await.unwrap();
    writer.flush().await.unwrap();
    drop(writer);
    drop(reader);

    // Give background task a moment to notice EOF
    let wait_res = tokio::time::timeout(Duration::from_secs(1), async {
        while handle.is_running() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;

    assert!(wait_res.is_ok(), "Server must cleanly terminate on partial line EOF");
    assert!(!handle.is_running(), "Server must cleanly terminate on partial line EOF");
}

#[tokio::test]
async fn test_adversarial_cancellation_during_burst() {
    let (server, engine) = create_adversarial_server(0, 0);
    engine.controller.simulated_delay_ms.store(50, Ordering::Relaxed);

    let (client_stream, handle) = create_in_memory_session(Arc::new(server), 65536);
    let (_reader, mut writer) = tokio::io::split(client_stream);

    for i in 1..=50 {
        let req = format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"tools/call\",\"params\":{{\"name\":\"click_element\",\"arguments\":{{\"id\":\"counter_btn\"}}}}}}\n",
            i
        );
        let _ = writer.write_all(req.as_bytes()).await;
    }
    let _ = writer.flush().await;

    // Call stop() immediately while requests are executing
    handle.stop().unwrap();
    assert!(!handle.is_running(), "handle.stop() must immediately report not running");
}

#[tokio::test]
async fn test_adversarial_half_duplex_shutdown() {
    let (server, _) = create_adversarial_server(0, 0);
    let (client_stream, handle) = create_in_memory_session(Arc::new(server), 65536);
    let (reader, mut writer) = tokio::io::split(client_stream);
    let mut buf_reader = BufReader::new(reader);

    // Send 10 requests
    for i in 1..=10 {
        let req = format!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}}\n", i);
        writer.write_all(req.as_bytes()).await.unwrap();
    }
    writer.flush().await.unwrap();
    // Half-close: client closes write direction
    writer.shutdown().await.unwrap();

    // Client should still receive all 10 responses before EOF
    let mut count = 0;
    for _ in 1..=10 {
        let mut line = String::new();
        if buf_reader.read_line(&mut line).await.unwrap() > 0 {
            let resp: JsonRpcResponse = serde_json::from_str(&line).unwrap();
            assert!(resp.result.is_some());
            count += 1;
        }
    }
    assert_eq!(count, 10);

    // Next read should be EOF (0 bytes)
    let mut line = String::new();
    let eof_bytes = buf_reader.read_line(&mut line).await.unwrap();
    assert_eq!(eof_bytes, 0, "Server must close write side after reader EOF");

    handle.stop().unwrap();
}

// ============================================================================
// 3. Max Depth Boundaries in UI Tree Inspection
// ============================================================================

#[tokio::test]
async fn test_adversarial_tree_max_depth_zero_boundary() {
    let (server, _) = create_adversarial_server(0, 0);
    let raw = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"max_depth":0}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error, "max_depth 0 must produce is_error: true");
    assert!(res.content[0].text.as_ref().unwrap().contains("max_depth must be >= 1"));
}

#[tokio::test]
async fn test_adversarial_tree_max_depth_one_boundary() {
    let (server, _) = create_adversarial_server(0, 0);
    let raw = r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"max_depth":1}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    let tree: UiTree = serde_json::from_str(res.content[0].text.as_ref().unwrap()).unwrap();
    assert_eq!(tree.root.id, "root_window");
    assert!(tree.root.children.is_empty(), "max_depth 1 must prune all children of root");
}

#[tokio::test]
async fn test_adversarial_tree_max_depth_extreme_1000() {
    let (server, _) = create_adversarial_server(0, 0);
    let raw = r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"max_depth":1000}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    let tree: UiTree = serde_json::from_str(res.content[0].text.as_ref().unwrap()).unwrap();
    assert_eq!(tree.root.id, "root_window");
    assert!(!tree.root.children.is_empty(), "Tree children should not be pruned at depth 1000");
}

#[tokio::test]
async fn test_adversarial_tree_max_depth_u32_max() {
    let (server, _) = create_adversarial_server(0, 0);
    let raw = r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"max_depth":4294967295}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
}

#[tokio::test]
async fn test_adversarial_tree_deep_nested_hierarchy_50_levels() {
    let (server, _) = create_adversarial_server(50, 0);

    // Inspect with max_depth: 10
    let raw10 = r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"max_depth":10}}}"#;
    let resp10: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw10).await.unwrap()).unwrap();
    let res10: ToolCallResult = serde_json::from_value(resp10.result.unwrap()).unwrap();
    assert!(!res10.is_error);

    // Traverse and count depth
    let tree10: UiTree = serde_json::from_str(res10.content[0].text.as_ref().unwrap()).unwrap();
    let mut d = 1;
    let mut curr = &tree10.root;
    while let Some(child) = curr.children.first() {
        d += 1;
        curr = child;
    }
    assert_eq!(d, 10, "Tree depth should be exactly 10 when pruned at max_depth 10");

    // Inspect with max_depth: 1000
    let raw_deep = r#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"max_depth":1000}}}"#;
    let resp_deep: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw_deep).await.unwrap()).unwrap();
    let res_deep: ToolCallResult = serde_json::from_value(resp_deep.result.unwrap()).unwrap();
    assert!(!res_deep.is_error);
    let tree_deep: UiTree = serde_json::from_str(res_deep.content[0].text.as_ref().unwrap()).unwrap();
    let mut d_full = 1;
    let mut curr_full = &tree_deep.root;
    while let Some(child) = curr_full.children.first() {
        d_full += 1;
        curr_full = child;
    }
    assert_eq!(d_full, 51, "Full tree depth should be 51 (root + 50 levels)");
}

#[tokio::test]
async fn test_adversarial_tree_wide_hierarchy_5000_nodes() {
    let (server, _) = create_adversarial_server(0, 5000);

    // Full inspection
    let raw = r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"inspect_tree","arguments":{}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    let tree: UiTree = serde_json::from_str(res.content[0].text.as_ref().unwrap()).unwrap();
    assert_eq!(tree.root.children.len(), 5000);

    // Pruned to max_depth: 1
    let raw_pruned = r#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"max_depth":1}}}"#;
    let resp_pruned: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw_pruned).await.unwrap()).unwrap();
    let res_pruned: ToolCallResult = serde_json::from_value(resp_pruned.result.unwrap()).unwrap();
    assert!(!res_pruned.is_error);
    let tree_pruned: UiTree = serde_json::from_str(res_pruned.content[0].text.as_ref().unwrap()).unwrap();
    assert_eq!(tree_pruned.root.children.len(), 0);
}

#[tokio::test]
async fn test_adversarial_tree_nonexistent_root_id() {
    let (server, _) = create_adversarial_server(0, 0);
    let raw = r#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"root_id":"nonexistent_element_99999"}}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(res.is_error);
    assert!(res.content[0].text.as_ref().unwrap().contains("Root element 'nonexistent_element_99999' not found"));
}

// ============================================================================
// 4. Out-of-Bounds Coordinates in click_element
// ============================================================================

#[tokio::test]
async fn test_adversarial_click_negative_coordinates() {
    let (server, _) = create_adversarial_server(0, 0);

    // Negative x
    let r1 = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click_element","arguments":{"x":-1.0,"y":50.0}}}"#;
    let resp1: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r1).await.unwrap()).unwrap();
    let res1: ToolCallResult = serde_json::from_value(resp1.result.unwrap()).unwrap();
    assert!(res1.is_error);
    assert!(res1.content[0].text.as_ref().unwrap().contains("Coordinates cannot be negative"));

    // Negative y
    let r2 = r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"click_element","arguments":{"x":50.0,"y":-0.001}}}"#;
    let resp2: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r2).await.unwrap()).unwrap();
    let res2: ToolCallResult = serde_json::from_value(resp2.result.unwrap()).unwrap();
    assert!(res2.is_error);
    assert!(res2.content[0].text.as_ref().unwrap().contains("Coordinates cannot be negative"));

    // Extreme negative
    let r3 = r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click_element","arguments":{"x":-1000000.0,"y":-1000000.0}}}"#;
    let resp3: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r3).await.unwrap()).unwrap();
    let res3: ToolCallResult = serde_json::from_value(resp3.result.unwrap()).unwrap();
    assert!(res3.is_error);
    assert!(res3.content[0].text.as_ref().unwrap().contains("Coordinates cannot be negative"));
}

#[tokio::test]
async fn test_adversarial_click_out_of_bounds_coordinates() {
    let (server, _) = create_adversarial_server(0, 0);
    // Viewport is 1040 x 720

    // x exceeding viewport
    let r1 = r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"click_element","arguments":{"x":1040.1,"y":700.0}}}"#;
    let resp1: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r1).await.unwrap()).unwrap();
    let res1: ToolCallResult = serde_json::from_value(resp1.result.unwrap()).unwrap();
    assert!(res1.is_error);
    assert!(res1.content[0].text.as_ref().unwrap().contains("out of window bounds"));

    // y exceeding viewport
    let r2 = r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"click_element","arguments":{"x":500.0,"y":720.1}}}"#;
    let resp2: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r2).await.unwrap()).unwrap();
    let res2: ToolCallResult = serde_json::from_value(resp2.result.unwrap()).unwrap();
    assert!(res2.is_error);
    assert!(res2.content[0].text.as_ref().unwrap().contains("out of window bounds"));

    // Astronomical coordinates
    let r3 = r#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"click_element","arguments":{"x":100000.0,"y":100000.0}}}"#;
    let resp3: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r3).await.unwrap()).unwrap();
    let res3: ToolCallResult = serde_json::from_value(resp3.result.unwrap()).unwrap();
    assert!(res3.is_error);
    assert!(res3.content[0].text.as_ref().unwrap().contains("out of window bounds"));
}

#[tokio::test]
async fn test_adversarial_click_exact_boundaries() {
    let (server, engine) = create_adversarial_server(0, 0);

    // Exact origin (0, 0)
    let r1 = r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"click_element","arguments":{"x":0.0,"y":0.0}}}"#;
    let resp1: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r1).await.unwrap()).unwrap();
    let res1: ToolCallResult = serde_json::from_value(resp1.result.unwrap()).unwrap();
    assert!(!res1.is_error, "Exact boundary (0, 0) must succeed");

    // Exact max bounds (1040, 720)
    let r2 = r#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"click_element","arguments":{"x":1040.0,"y":720.0}}}"#;
    let resp2: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(r2).await.unwrap()).unwrap();
    let res2: ToolCallResult = serde_json::from_value(resp2.result.unwrap()).unwrap();
    assert!(!res2.is_error, "Exact boundary (1040, 720) must succeed");

    assert_eq!(engine.controller.click_count.load(Ordering::SeqCst), 2);
}

// ============================================================================
// 5. Long Text in send_keys & Non-Editable Targets
// ============================================================================

#[tokio::test]
async fn test_adversarial_send_keys_100k_characters() {
    let (server, engine) = create_adversarial_server(0, 0);

    // 100,000 characters payload
    let huge_text = "A".repeat(100_000);
    let payload = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "send_keys",
            "arguments": {
                "text": huge_text,
                "element_id": "email_input"
            }
        }
    });

    let raw = serde_json::to_string(&payload).unwrap();
    let resp_str = server.handle_line(&raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error, "100K characters should succeed");
    assert_eq!(engine.controller.typed_text.lock().await.len(), 100_000);
}

#[tokio::test]
async fn test_adversarial_send_keys_special_characters_and_newlines() {
    let (server, engine) = create_adversarial_server(0, 0);

    // Text with newline escapes, tabs, quotes, emojis, RTL unicode
    let special_text = "Line 1\nLine 2\r\n\tTabbed\t\"Quotes\" 'Single' 🚀🎉🦀 مرحبا بالعالم \u{0000}";
    let payload = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
            "name": "send_keys",
            "arguments": {
                "text": special_text,
                "element_id": "email_input"
            }
        }
    });

    let raw = serde_json::to_string(&payload).unwrap();
    let resp_str = server.handle_line(&raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
    assert!(!res.is_error);
    assert_eq!(*engine.controller.typed_text.lock().await, special_text);
}

#[tokio::test]
async fn test_adversarial_send_keys_non_editable_targets() {
    let (server, _) = create_adversarial_server(0, 0);

    let non_editable_ids = vec![
        ("header_bar", "SlateHeaderBar"),
        ("counter_btn", "SlateButton"),
        ("nav_view", "SlateNavigationSplitView"),
        ("nav_item_buttons", "NavItem"),
    ];

    for (idx, (id, _elem_type)) in non_editable_ids.iter().enumerate() {
        let payload = serde_json::json!({
            "jsonrpc": "2.0",
            "id": idx + 10,
            "method": "tools/call",
            "params": {
                "name": "send_keys",
                "arguments": {
                    "text": "test",
                    "element_id": id
                }
            }
        });

        let raw = serde_json::to_string(&payload).unwrap();
        let resp_str = server.handle_line(&raw).await.unwrap();
        let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

        let res: ToolCallResult = serde_json::from_value(resp.result.unwrap()).unwrap();
        assert!(res.is_error, "Element '{}' should be rejected as non-editable", id);
        assert!(
            res.content[0].text.as_ref().unwrap().contains("not an editable text input"),
            "Error for '{}' should explain it is not editable",
            id
        );
    }
}
