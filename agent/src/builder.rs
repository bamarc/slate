//! Fluent builder for configuring and starting Slate Agent remote-control servers.

use std::sync::Arc;
use std::time::Duration;
use slint::ComponentHandle;

use crate::bridge::{ComponentBridge, SlintUiBridge, DEFAULT_UI_TIMEOUT};
use crate::engine::{
    DefaultAutomationEngine, DefaultElementController, DefaultStateProvider,
    DefaultUiInspector, DefaultVisualRenderer,
};
use crate::error::AgentError;
use crate::protocol::{AgentProtocolAdapter, ProtocolServerHandle};
use crate::traits::{AutomationEngine, ElementController, StateProvider, UiInspector, VisualRenderer};

type AdapterFactory = Box<
    dyn FnOnce(
            Arc<dyn AutomationEngine>,
        ) -> Result<Box<dyn ProtocolServerHandle>, AgentError>
        + Send,
>;

/// Core automation components returned by [`AgentBuilder::build`].
pub type AgentBuildComponents<T> = (
    Arc<dyn AutomationEngine>,
    Arc<SlintUiBridge>,
    ComponentBridge<T>,
);

/// Configuration builder for initializing the agent automation engine and protocols.
pub struct AgentBuilder<T: ComponentHandle + 'static> {
    weak: slint::Weak<T>,
    name: String,
    version: String,
    timeout: Duration,
    enable_serialization: bool,
    custom_state_provider: Option<Arc<dyn StateProvider>>,
    custom_inspector: Option<Arc<dyn UiInspector>>,
    custom_controller: Option<Arc<dyn ElementController>>,
    custom_renderer: Option<Arc<dyn VisualRenderer>>,
    adapter_factories: Vec<AdapterFactory>,
    enable_stdio_mcp: bool,
    enable_in_memory_mcp: bool,
}

impl<T: ComponentHandle + 'static> AgentBuilder<T> {
    /// Creates a new builder attached to a Slint window or component handle.
    pub fn new(window: &T) -> Self {
        Self {
            weak: window.as_weak(),
            name: "slate-agent".to_string(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            timeout: DEFAULT_UI_TIMEOUT,
            enable_serialization: true,
            custom_state_provider: None,
            custom_inspector: None,
            custom_controller: None,
            custom_renderer: None,
            adapter_factories: Vec::new(),
            enable_stdio_mcp: false,
            enable_in_memory_mcp: false,
        }
    }

    /// Sets the application/agent name identifier.
    pub fn with_name(mut self, name: impl Into<String>) -> Self {
        self.name = name.into();
        self
    }

    /// Sets the application/agent version string.
    pub fn with_version(mut self, version: impl Into<String>) -> Self {
        self.version = version.into();
        self
    }

    /// Sets the UI operation timeout guard duration (default: 5 seconds).
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Toggles command serialization mutex (default: true).
    pub fn with_serialization(mut self, enable: bool) -> Self {
        self.enable_serialization = enable;
        self
    }

    /// Registers a custom application `StateProvider`.
    pub fn with_state_provider(mut self, provider: Arc<dyn StateProvider>) -> Self {
        self.custom_state_provider = Some(provider);
        self
    }

    /// Overrides the default `UiInspector`.
    pub fn with_inspector(mut self, inspector: Arc<dyn UiInspector>) -> Self {
        self.custom_inspector = Some(inspector);
        self
    }

    /// Overrides the default `ElementController`.
    pub fn with_controller(mut self, controller: Arc<dyn ElementController>) -> Self {
        self.custom_controller = Some(controller);
        self
    }

    /// Overrides the default `VisualRenderer`.
    pub fn with_renderer(mut self, renderer: Arc<dyn VisualRenderer>) -> Self {
        self.custom_renderer = Some(renderer);
        self
    }

    /// Attaches an alternative protocol adapter (e.g. ACP adapter).
    pub fn with_protocol_adapter<A>(mut self, mut adapter: A, config: A::Config) -> Self
    where
        A: AgentProtocolAdapter + 'static,
    {
        self.adapter_factories.push(Box::new(
            move |engine: Arc<dyn AutomationEngine>| {
                let handle = adapter.attach(engine, config)?;
                Ok(Box::new(handle) as Box<dyn ProtocolServerHandle>)
            },
        ));
        self
    }

    /// Enables the standard I/O (stdio) MCP server transport.
    pub fn with_stdio_mcp(mut self) -> Self {
        self.enable_stdio_mcp = true;
        self
    }

    /// Enables the in-memory duplex channel MCP server transport.
    pub fn with_in_memory_transport(mut self) -> Self {
        self.enable_in_memory_mcp = true;
        self
    }

    /// Returns whether stdio MCP transport is enabled.
    pub fn is_stdio_mcp_enabled(&self) -> bool {
        self.enable_stdio_mcp
    }

    /// Returns whether in-memory transport is enabled.
    pub fn is_in_memory_mcp_enabled(&self) -> bool {
        self.enable_in_memory_mcp
    }

    /// Builds the underlying `AutomationEngine`, `SlintUiBridge`, and `ComponentBridge`.
    pub fn build(self) -> Result<AgentBuildComponents<T>, AgentError> {
        let bridge = Arc::new(SlintUiBridge::with_timeout(self.timeout));
        let component_bridge = ComponentBridge::new(self.weak.clone(), bridge.clone());

        let inspector = self
            .custom_inspector
            .unwrap_or_else(|| Arc::new(DefaultUiInspector::default()));
        let controller = self
            .custom_controller
            .unwrap_or_else(|| Arc::new(DefaultElementController));
        let state_provider = self
            .custom_state_provider
            .unwrap_or_else(|| Arc::new(DefaultStateProvider::default()));
        let renderer = self
            .custom_renderer
            .unwrap_or_else(|| Arc::new(DefaultVisualRenderer::default()));

        let engine = Arc::new(DefaultAutomationEngine::new(
            inspector,
            controller,
            state_provider,
            renderer,
        ));

        Ok((engine, bridge, component_bridge))
    }

    /// Builds the automation engine and starts all configured transport servers and adapters.
    ///
    /// If no active Tokio runtime exists on the calling thread, spins up a background runtime.
    pub fn start(mut self) -> Result<AgentHandle, AgentError> {
        let factories = std::mem::take(&mut self.adapter_factories);

        let (engine, bridge, _) = self.build()?;
        let (shutdown_tx, _) = tokio::sync::broadcast::channel(1);

        // Ensure Tokio runtime exists for background protocol servers and is entered on the calling thread
        let _rt_handle = ensure_tokio_runtime()?;

        let mut server_handles = Vec::new();
        for factory in factories {
            let handle = factory(engine.clone())?;
            server_handles.push(handle);
        }

        Ok(AgentHandle {
            engine,
            bridge,
            server_handles,
            shutdown_sender: Arc::new(shutdown_tx),
        })
    }
}

/// Ensures that a Tokio runtime is running and entered on the current thread.
///
/// If no active Tokio runtime exists on the calling thread, initializes a multi-threaded
/// Tokio runtime, leaks it for the process lifetime, and enters its context on the calling thread.
pub fn ensure_tokio_runtime() -> Result<tokio::runtime::Handle, AgentError> {
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => Ok(handle),
        Err(_) => {
            let rt = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .thread_name("slate-agent-worker")
                .build()
                .map_err(|e| AgentError::internal(format!("Failed to start Tokio runtime: {}", e)))?;
            let handle = rt.handle().clone();
            let leaked = Box::leak(Box::new(rt));
            std::mem::forget(leaked.enter());
            Ok(handle)
        }
    }
}

/// Handle to an active agent instance, maintaining references to the engine and bridge.
pub struct AgentHandle {
    engine: Arc<dyn AutomationEngine>,
    bridge: Arc<SlintUiBridge>,
    server_handles: Vec<Box<dyn ProtocolServerHandle>>,
    shutdown_sender: Arc<tokio::sync::broadcast::Sender<()>>,
}

impl AgentHandle {
    /// Returns a reference to the core `AutomationEngine`.
    pub fn engine(&self) -> &Arc<dyn AutomationEngine> {
        &self.engine
    }

    /// Returns a reference to the `SlintUiBridge`.
    pub fn bridge(&self) -> &Arc<SlintUiBridge> {
        &self.bridge
    }

    /// Returns references to the protocol server handles.
    pub fn server_handles(&self) -> &[Box<dyn ProtocolServerHandle>] {
        &self.server_handles
    }

    /// Returns `true` if all attached protocol servers are running.
    pub fn is_running(&self) -> bool {
        if self.server_handles.is_empty() {
            true
        } else {
            self.server_handles.iter().all(|h| h.is_running())
        }
    }

    /// Stops all attached background protocol servers and broadcasts shutdown.
    pub fn stop(&self) -> Result<(), AgentError> {
        let _ = self.shutdown_sender.send(());
        let mut last_err = None;
        for handle in &self.server_handles {
            if let Err(e) = handle.stop() {
                last_err = Some(e);
            }
        }
        if let Some(err) = last_err {
            Err(err)
        } else {
            Ok(())
        }
    }

    /// Returns the local address of the primary attached protocol server, if available.
    pub fn local_addr(&self) -> Option<String> {
        self.server_handles.first().and_then(|h| h.local_addr())
    }

    /// Broadcasts a shutdown signal to all background servers and transport tasks.
    pub fn shutdown(&self) {
        let _ = self.stop();
    }
}

impl ProtocolServerHandle for AgentHandle {
    fn is_running(&self) -> bool {
        self.is_running()
    }

    fn stop(&self) -> Result<(), AgentError> {
        self.stop()
    }

    fn local_addr(&self) -> Option<String> {
        self.local_addr()
    }
}

impl Drop for AgentHandle {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}
