//! Unit tests for AgentBuilder and AgentHandle.

use std::sync::Arc;
use std::time::Duration;

use slate_agent::acp::{MockAcpAdapter, MockAcpConfig};
use slate_agent::builder::AgentBuilder;
use slate_agent::engine::DefaultStateProvider;

slint::slint! {
    export component TestWindow inherits Window {
        width: 400px;
        height: 300px;
        title: "Test Builder Window";
    }
}

#[tokio::test]
async fn test_agent_builder_fluent_configuration() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });
    let window = TestWindow::new().unwrap();

    let custom_state = Arc::new(DefaultStateProvider::new("CustomTestView"));

    let builder = AgentBuilder::new(&window)
        .with_name("custom-agent")
        .with_version("2.0.0")
        .with_timeout(Duration::from_millis(3500))
        .with_serialization(true)
        .with_state_provider(custom_state)
        .with_stdio_mcp()
        .with_in_memory_transport();

    assert!(builder.is_stdio_mcp_enabled());
    assert!(builder.is_in_memory_mcp_enabled());

    let (engine, bridge, component_bridge) = builder.build().unwrap();
    assert_eq!(bridge.timeout(), Duration::from_millis(3500));

    let state = engine.get_state(None).await.unwrap();
    assert_eq!(state.active_view, "CustomTestView");

    assert!(component_bridge.weak().upgrade().is_some());
}

#[tokio::test]
async fn test_agent_builder_with_protocol_adapter() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });
    let window = TestWindow::new().unwrap();

    let adapter = MockAcpAdapter;
    let config = MockAcpConfig {
        agent_id: "builder-test-agent".into(),
        channel_capacity: 32,
    };

    let handle = AgentBuilder::new(&window)
        .with_name("acp-attached-agent")
        .with_protocol_adapter(adapter, config)
        .start()
        .unwrap();

    assert!(handle.is_running());
    assert_eq!(handle.server_handles().len(), 1);
    assert_eq!(
        handle.server_handles()[0].local_addr(),
        Some("inproc://mock-acp".into())
    );

    // Shutdown
    handle.shutdown();
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert!(!handle.is_running());
}
