//! Integration adapter connecting `slate-mcp` with `slate_agent::builder::AgentBuilder`.

use slint::ComponentHandle;
use std::sync::Arc;
use tokio::io::DuplexStream;

use slate_agent::builder::AgentBuilder;
use slate_agent::error::AgentError;
use slate_agent::protocol::{AgentProtocolAdapter, ProtocolServerHandle};
use slate_agent::traits::AutomationEngine;

use crate::server::McpServer;
use crate::transport::{
    spawn_in_memory_transport, spawn_stdio_transport, InMemoryTransportHandle, StdioTransportHandle,
};

/// Transport mode selection for [`McpAdapter`].
pub enum McpTransportMode {
    /// Standard I/O (stdin/stdout) transport.
    Stdio,
    /// In-memory duplex stream transport.
    InMemory(DuplexStream),
}

/// Configuration options for the MCP protocol adapter.
pub struct McpAdapterConfig {
    pub mode: McpTransportMode,
    pub server_name: String,
    pub server_version: String,
}

impl McpAdapterConfig {
    pub fn stdio() -> Self {
        Self {
            mode: McpTransportMode::Stdio,
            server_name: "slate-mcp".to_string(),
            server_version: env!("CARGO_PKG_VERSION").to_string(),
        }
    }

    pub fn in_memory(stream: DuplexStream) -> Self {
        Self {
            mode: McpTransportMode::InMemory(stream),
            server_name: "slate-mcp".to_string(),
            server_version: env!("CARGO_PKG_VERSION").to_string(),
        }
    }

    pub fn with_info(mut self, name: impl Into<String>, version: impl Into<String>) -> Self {
        self.server_name = name.into();
        self.server_version = version.into();
        self
    }
}

/// MCP protocol adapter implementing [`AgentProtocolAdapter`].
#[derive(Debug, Clone, Default)]
pub struct McpAdapter;

impl McpAdapter {
    pub fn new() -> Self {
        Self
    }

    pub fn stdio() -> Self {
        Self
    }

    pub fn in_memory() -> Self {
        Self
    }
}

/// Unified server handle returned when attaching the MCP adapter.
pub enum McpServerHandle {
    Stdio(StdioTransportHandle),
    InMemory(InMemoryTransportHandle),
}

impl McpServerHandle {
    /// Returns `true` if the underlying transport server is currently active.
    pub fn is_running(&self) -> bool {
        match self {
            Self::Stdio(h) => h.is_running(),
            Self::InMemory(h) => h.is_running(),
        }
    }

    /// Stops the underlying transport server and terminates background tasks.
    pub fn stop(&self) -> Result<(), AgentError> {
        match self {
            Self::Stdio(h) => h.stop(),
            Self::InMemory(h) => h.stop(),
        }
    }

    /// Returns the local address or connection descriptor for this transport.
    pub fn local_addr(&self) -> Option<String> {
        match self {
            Self::Stdio(h) => h.local_addr(),
            Self::InMemory(h) => h.local_addr(),
        }
    }
}

impl ProtocolServerHandle for McpServerHandle {
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

impl AgentProtocolAdapter for McpAdapter {
    type Config = McpAdapterConfig;
    type ServerHandle = McpServerHandle;

    fn attach(
        &mut self,
        engine: Arc<dyn AutomationEngine>,
        config: Self::Config,
    ) -> Result<Self::ServerHandle, AgentError> {
        let server = Arc::new(McpServer::with_info(
            engine,
            config.server_name,
            config.server_version,
        ));

        match config.mode {
            McpTransportMode::Stdio => {
                let handle = spawn_stdio_transport(server)?;
                Ok(McpServerHandle::Stdio(handle))
            }
            McpTransportMode::InMemory(stream) => {
                let handle = spawn_in_memory_transport(server, stream)?;
                Ok(McpServerHandle::InMemory(handle))
            }
        }
    }
}

/// Extension trait extending [`AgentBuilder`] with fluent MCP configuration methods.
pub trait AgentBuilderMcpExt<T: ComponentHandle + 'static> {
    /// Enables and attaches the Stdio MCP server to the builder.
    fn with_mcp_stdio(self) -> Self;

    /// Enables and attaches an In-Memory Duplex MCP server using the provided stream.
    fn with_mcp_in_memory(self, stream: DuplexStream) -> Self;
}

impl<T: ComponentHandle + 'static> AgentBuilderMcpExt<T> for AgentBuilder<T> {
    fn with_mcp_stdio(self) -> Self {
        self.with_protocol_adapter(McpAdapter::stdio(), McpAdapterConfig::stdio())
    }

    fn with_mcp_in_memory(self, stream: DuplexStream) -> Self {
        self.with_protocol_adapter(McpAdapter::in_memory(), McpAdapterConfig::in_memory(stream))
    }
}
