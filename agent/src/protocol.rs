//! Protocol extension abstractions for Slate Agent.
//!
//! This module provides clean extension traits allowing alternative protocols
//! (such as ACP, gRPC, custom WebSocket or IPC protocols) to attach to the
//! core [`AutomationEngine`] without altering core automation logic.

use std::sync::Arc;
use crate::error::AgentError;
use crate::traits::AutomationEngine;

/// Clean extension trait allowing alternative protocols (such as ACP, gRPC, custom RPC)
/// to attach to the automation engine without modifying core logic.
///
/// An adapter receives an `Arc<dyn AutomationEngine>` and a protocol-specific configuration,
/// starts any necessary network listeners, message pumps, or background tasks, and returns
/// a server lifecycle handle for monitoring and termination.
pub trait AgentProtocolAdapter: Send + Sync {
    /// Adapter-specific configuration (e.g. port, listen address, buffer size, identity).
    type Config: Send + Sync + 'static;

    /// Server/lifecycle handle returned after attaching to the engine.
    type ServerHandle: ProtocolServerHandle + 'static;

    /// Attaches the protocol adapter to the provided automation engine,
    /// starting any required listeners, channels, or background tasks.
    ///
    /// # Errors
    /// Returns [`AgentError`] if the adapter fails to bind ports, initialize channels,
    /// or attach to the engine.
    fn attach(
        &mut self,
        engine: Arc<dyn AutomationEngine>,
        config: Self::Config,
    ) -> Result<Self::ServerHandle, AgentError>;
}

/// Generic lifecycle management trait for server handles returned by protocol adapters.
pub trait ProtocolServerHandle: Send + Sync {
    /// Returns `true` if the protocol server/adapter is actively running and processing requests.
    fn is_running(&self) -> bool;

    /// Gracefully stops the protocol server, closing connections and terminating background tasks.
    fn stop(&self) -> Result<(), AgentError>;

    /// Returns the local listening address or endpoint identifier, if applicable.
    fn local_addr(&self) -> Option<String> {
        None
    }
}
