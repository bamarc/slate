//! Slate Agent: Core automation engine, MCP integration, and convenience initialization helpers.
//!
//! This module re-exports the core automation abstractions from `slate_agent`, the
//! MCP adapter extensions from `slate_mcp`, and provides single-line initialization
//! functions for desktop applications.

// Re-export submodules from slate_agent
pub use slate_agent::acp;
pub use slate_agent::bridge;
pub use slate_agent::engine;
pub use slate_agent::error;
pub use slate_agent::model;
pub use slate_agent::protocol;
pub use slate_agent::traits;

// Re-export all primary types and traits from slate_agent
pub use slate_agent::{
    // Core traits
    AutomationEngine, ElementController, StateProvider, UiInspector, VisualRenderer,
    // Protocol extension traits
    AgentProtocolAdapter, ProtocolServerHandle,
    // Slint bridge
    ComponentBridge, SlintUiBridge, DEFAULT_UI_TIMEOUT,
    // Builders & Handles
    AgentBuildComponents, AgentBuilder, AgentHandle, AutomationEngineBuilder, DefaultAutomationEngine,
    // Models
    ActionResult, AppState, DiagnosticMetrics, ElementSelector, MouseButton, Point, Rect,
    Screenshot, UiElementNode, UiTree,
    // Errors
    AgentError,
    // ACP types
    AcpEndpoint, AcpMessage, AcpPerformative, AcpResponse, DefaultAcpEndpoint,
    MockAcpAdapter, MockAcpClient, MockAcpConfig, MockAcpServerHandle,
};

pub use slate_agent::builder::ensure_tokio_runtime;

// Re-export MCP adapter extension trait and types
pub use slate_mcp::adapter::{
    AgentBuilderMcpExt, McpAdapter, McpAdapterConfig, McpServerHandle, McpTransportMode,
};

/// Convenience constructor returning an [`AgentBuilder`] attached to the given window.
///
/// # Example
/// ```rust,no_run
/// # slint::slint! { export component MyWindow inherits Window {} }
/// # let window = MyWindow::new().unwrap();
/// let builder = slate::agent::builder(&window)
///     .with_name("my-application");
/// ```
pub fn builder<T: slint::ComponentHandle + 'static>(
    window: &T,
) -> slate_agent::builder::AgentBuilder<T> {
    slate_agent::builder::AgentBuilder::new(window)
}

/// Single-line convenience helper to initialize agent remote-control on any Slint window.
///
/// Spawns a background stdio Model Context Protocol (MCP) server hooked to the application window.
/// Automatically starts and registers a background Tokio multi-thread runtime if one is not
/// already active on the calling thread.
///
/// # Note on Lifecycle
/// The returned [`AgentHandle`] must be retained in a variable (e.g. `let _agent = slate::agent::init(&win)?;`)
/// for the duration of the application. If dropped, the background server transport task will terminate.
///
/// # Example
/// ```rust,no_run
/// # slint::slint! { export component MyWindow inherits Window {} }
/// # let window = MyWindow::new().unwrap();
/// let _agent = slate::agent::init(&window).expect("Failed to initialize agent");
/// ```
#[must_use = "the agent handle must be held alive for the agent to run"]
pub fn init<T: slint::ComponentHandle + 'static>(
    window: &T,
) -> Result<slate_agent::builder::AgentHandle, slate_agent::error::AgentError> {
    builder(window).with_mcp_stdio().start()
}

#[cfg(test)]
mod tests {
    use super::*;

    slint::slint! {
        export component TestLibWindow inherits Window {
            width: 300px;
            height: 200px;
            title: "Test Lib Window";
        }
    }

    #[tokio::test]
    async fn test_slate_agent_builder_convenience() {
        let _ = std::panic::catch_unwind(|| {
            i_slint_backend_testing::init_no_event_loop();
        });
        let window = TestLibWindow::new().unwrap();

        let b = builder(&window).with_name("test-lib-app");
        let (engine, bridge, _comp_bridge) = b.build().unwrap();

        assert_eq!(bridge.timeout(), crate::agent::DEFAULT_UI_TIMEOUT);
        let state = engine.get_state(None).await.unwrap();
        assert_eq!(state.active_view, "main");
    }

    #[tokio::test]
    async fn test_slate_agent_init_convenience() {
        let _ = std::panic::catch_unwind(|| {
            i_slint_backend_testing::init_no_event_loop();
        });
        let window = TestLibWindow::new().unwrap();

        let handle = init(&window).expect("init failed");
        assert!(handle.is_running());
        assert_eq!(handle.local_addr(), Some("stdio://process".to_string()));

        let _ = handle.stop();
        assert!(!handle.is_running());
    }

    #[test]
    fn test_dyn_compatibility_and_thread_safety() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<McpServerHandle>();
        assert_send_sync::<AgentHandle>();
        assert_send_sync::<AgentError>();
        assert_send_sync::<SlintUiBridge>();
    }
}
