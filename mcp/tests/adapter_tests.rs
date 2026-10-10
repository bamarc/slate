//! Unit and integration tests for `McpAdapter` and `AgentBuilderMcpExt`.

use std::sync::Arc;
use std::time::Duration;

use slate_agent::engine::{
    DefaultAutomationEngine, DefaultElementController, DefaultStateProvider, DefaultUiInspector,
    DefaultVisualRenderer,
};
use slate_agent::protocol::{AgentProtocolAdapter, ProtocolServerHandle};
use slate_mcp::adapter::{AgentBuilderMcpExt, McpAdapter, McpAdapterConfig};

slint::slint! {
    export component TestWindow inherits Window {
        width: 400px;
        height: 300px;
        title: "Test Adapter Window";
    }
}

fn create_mock_engine() -> Arc<DefaultAutomationEngine> {
    Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::new("Slate Adapter Test", 800.0, 600.0)),
        Arc::new(DefaultElementController),
        Arc::new(DefaultStateProvider::new("main")),
        Arc::new(DefaultVisualRenderer::new(800, 600)),
    ))
}

#[tokio::test]
async fn test_mcp_adapter_attach_in_memory() {
    let engine = create_mock_engine();
    let (client_stream, server_stream) = tokio::io::duplex(65536);

    let mut adapter = McpAdapter::new();
    let config = McpAdapterConfig::in_memory(server_stream).with_info("slate-mcp-test", "1.0.0");

    let handle = adapter.attach(engine, config).expect("Attach failed");
    assert!(handle.is_running());
    assert!(handle.local_addr().is_some());

    // Drop client half to trigger clean EOF
    drop(client_stream);
    tokio::time::sleep(Duration::from_millis(50)).await;

    let _ = handle.stop();
    assert!(!handle.is_running());
}

#[tokio::test]
async fn test_agent_builder_with_mcp_in_memory() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });
    let window = TestWindow::new().unwrap();

    let (_client_stream, server_stream) = tokio::io::duplex(65536);

    let handle = slate_agent::builder::AgentBuilder::new(&window)
        .with_name("mcp-builder-agent")
        .with_mcp_in_memory(server_stream)
        .start()
        .expect("Agent start failed");

    assert!(handle.is_running());
    assert_eq!(handle.server_handles().len(), 1);
    assert!(handle.server_handles()[0].is_running());

    handle.shutdown();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!handle.is_running());
}
