//! Integration tests for `slate::agent` convenience APIs and MCP extension traits.

use std::sync::Arc;
use tokio::io::duplex;

use slate::agent::{builder, init, AgentBuilderMcpExt};

slint::slint! {
    export component IntegrationWindow inherits Window {
        width: 400px;
        height: 300px;
        title: "Integration Test Window";

        in-out property <int> test-counter: 0;
        in-out property <string> test-input: "initial";

        callback increment();
        increment => {
            root.test-counter += 1;
        }
    }
}

fn setup_headless() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });
}

#[tokio::test]
async fn test_agent_init_stdio_lifecycle() {
    setup_headless();
    let window = IntegrationWindow::new().expect("Failed to create Slint window");

    let agent_handle = init(&window).expect("slate::agent::init failed");
    assert!(agent_handle.is_running(), "Agent handle must be running");
    assert_eq!(agent_handle.server_handles().len(), 1);
    assert_eq!(
        agent_handle.local_addr(),
        Some("stdio://process".to_string())
    );

    // Stop server cleanly
    agent_handle.stop().expect("Stop failed");
    assert!(
        !agent_handle.is_running(),
        "Agent handle must be stopped"
    );
}

#[test]
fn test_sync_thread_initialization() {
    setup_headless();
    let join_res = std::thread::spawn(|| {
        assert!(
            tokio::runtime::Handle::try_current().is_err(),
            "Precondition: must have NO Tokio runtime on this bare thread"
        );
        let window = IntegrationWindow::new().expect("Failed to create Slint window");

        // 1. Verify slate::agent::init works from bare OS thread and returns AgentHandle
        let init_handle = init(&window).expect("slate::agent::init failed on sync thread");
        assert!(init_handle.is_running());
        assert_eq!(
            init_handle.local_addr(),
            Some("stdio://process".to_string())
        );
        init_handle.stop().expect("init handle stop failed");
        assert!(!init_handle.is_running());

        // 2. Verify slate::agent::builder works from bare OS thread
        let (_client_stream, server_stream) = tokio::io::duplex(4096);
        let builder_handle = builder(&window)
            .with_name("sync-thread-builder-test")
            .with_mcp_in_memory(server_stream)
            .start()
            .expect("builder.start() failed on sync thread");
        assert!(builder_handle.is_running());
        builder_handle.stop().expect("builder stop failed");
        assert!(!builder_handle.is_running());
    }).join();

    assert!(join_res.is_ok(), "Sync thread initialization must not panic");
}

#[tokio::test]
async fn test_agent_builder_with_mcp_in_memory() {
    setup_headless();
    let window = IntegrationWindow::new().expect("Failed to create Slint window");

    let (client_stream, server_stream) = duplex(4096);

    let agent_handle = builder(&window)
        .with_name("integration-test-app")
        .with_version("1.0.0")
        .with_mcp_in_memory(server_stream)
        .start()
        .expect("Failed to start agent via builder with in-memory MCP");

    assert!(agent_handle.is_running());
    let addr = agent_handle.server_handles()[0]
        .local_addr()
        .expect("local_addr should be Some");
    assert!(
        addr.starts_with("inproc://duplex/"),
        "Expected inproc://duplex/*, got {}",
        addr
    );

    // Verify MCP communication through client_stream
    let (mut client_read, mut client_write) = tokio::io::split(client_stream);
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let init_req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {
                "name": "integration-test-client",
                "version": "1.0.0"
            }
        }
    });

    let req_line = format!("{}\n", serde_json::to_string(&init_req).unwrap());
    client_write
        .write_all(req_line.as_bytes())
        .await
        .expect("write init req failed");
    client_write.flush().await.expect("flush failed");

    let mut lines = BufReader::new(&mut client_read).lines();
    let resp_line = lines
        .next_line()
        .await
        .expect("read line failed")
        .expect("expected response line");

    let resp_val: serde_json::Value =
        serde_json::from_str(&resp_line).expect("JSON-RPC response parse failed");
    assert_eq!(resp_val["jsonrpc"], "2.0");
    assert_eq!(resp_val["id"], 1);
    assert_eq!(
        resp_val["result"]["serverInfo"]["name"],
        "slate-mcp"
    );

    // Stop the agent
    agent_handle.shutdown();
}

#[test]
fn test_agent_reexports_completeness() {
    // Verify that all required types and traits are exported at slate::agent
    use slate::agent::{
        ActionResult, AgentError, AppState, AutomationEngine, ElementController,
        ElementSelector, Point, Rect, Screenshot, SlintUiBridge, StateProvider, UiElementNode,
        UiInspector, UiTree, VisualRenderer,
    };

    fn check_dyn_engine(_: Arc<dyn AutomationEngine>) {}
    fn check_dyn_inspector(_: Arc<dyn UiInspector>) {}
    fn check_dyn_controller(_: Arc<dyn ElementController>) {}
    fn check_dyn_state(_: Arc<dyn StateProvider>) {}
    fn check_dyn_renderer(_: Arc<dyn VisualRenderer>) {}

    let _ = (
        check_dyn_engine as fn(Arc<dyn AutomationEngine>),
        check_dyn_inspector as fn(Arc<dyn UiInspector>),
        check_dyn_controller as fn(Arc<dyn ElementController>),
        check_dyn_state as fn(Arc<dyn StateProvider>),
        check_dyn_renderer as fn(Arc<dyn VisualRenderer>),
    );

    let state = AppState::new("test_view").with_property("key", serde_json::json!("val"));
    assert_eq!(state.active_view, "test_view");
    assert_eq!(state.properties["key"], "val");

    let selector = ElementSelector::parse("#btn_1");
    assert_eq!(selector, ElementSelector::Id("btn_1".to_string()));

    let pt = Point::new(10.0, 20.0);
    assert_eq!(pt.x, 10.0);

    let shot = Screenshot::new(100, 200, "png", vec![1, 2, 3]);
    assert_eq!(shot.width, 100);

    let bridge = SlintUiBridge::new();
    assert_eq!(bridge.timeout(), slate::agent::DEFAULT_UI_TIMEOUT);

    let tree = UiTree::new(UiElementNode {
        id: "root".to_string(),
        type_name: "Window".to_string(),
        label: None,
        role: "window".to_string(),
        bounds: Rect::new(0.0, 0.0, 100.0, 100.0),
        enabled: true,
        visible: true,
        focused: false,
        value: None,
        children: vec![],
        properties: std::collections::HashMap::new(),
    });
    assert_eq!(tree.root.id, "root");

    let res = ActionResult::success("ok").with_element_id("elem_1");
    assert!(res.success);
    assert_eq!(res.element_id.as_deref(), Some("elem_1"));

    let err = AgentError::element_not_found("elem_missing", "details");
    assert!(err.to_string().contains("elem_missing"));
}
