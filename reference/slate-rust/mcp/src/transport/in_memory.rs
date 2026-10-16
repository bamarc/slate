//! In-memory asynchronous duplex channel transport for high-speed deterministic testing.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::DuplexStream;
use tokio::sync::broadcast;

use slate_agent::error::AgentError;
use slate_agent::protocol::ProtocolServerHandle;

use crate::server::McpServer;
use crate::transport::run_line_transport;

static SESSION_COUNTER: AtomicU64 = AtomicU64::new(1);

/// Lifecycle handle for an active In-Memory Duplex MCP transport server.
pub struct InMemoryTransportHandle {
    running: Arc<AtomicBool>,
    shutdown_tx: broadcast::Sender<()>,
    join_handle: Option<tokio::task::JoinHandle<()>>,
    session_id: u64,
}

impl ProtocolServerHandle for InMemoryTransportHandle {
    fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    fn stop(&self) -> Result<(), AgentError> {
        self.running.store(false, Ordering::SeqCst);
        let _ = self.shutdown_tx.send(());
        if let Some(ref handle) = self.join_handle {
            handle.abort();
        }
        Ok(())
    }

    fn local_addr(&self) -> Option<String> {
        Some(format!("inproc://duplex/{}", self.session_id))
    }
}

impl Drop for InMemoryTransportHandle {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

/// Spawns the in-memory duplex transport on an existing `DuplexStream`.
pub fn spawn_in_memory_transport(
    server: Arc<McpServer>,
    stream: DuplexStream,
) -> Result<InMemoryTransportHandle, AgentError> {
    let running = Arc::new(AtomicBool::new(true));
    let (shutdown_tx, shutdown_rx) = broadcast::channel(1);
    let running_clone = running.clone();
    let session_id = SESSION_COUNTER.fetch_add(1, Ordering::Relaxed);

    let join_handle = tokio::spawn(async move {
        let (reader, writer) = tokio::io::split(stream);
        let res = run_line_transport(server, reader, writer, Some(shutdown_rx)).await;
        running_clone.store(false, Ordering::SeqCst);
        if let Err(e) = res {
            log::debug!("In-memory transport session closed: {}", e);
        }
    });

    Ok(InMemoryTransportHandle {
        running,
        shutdown_tx,
        join_handle: Some(join_handle),
        session_id,
    })
}

/// Creates a connected pair of in-memory duplex streams, spawning the MCP server on one end
/// and returning the client stream ready for use with [`InMemoryMcpClient`].
///
/// Standard buffer size: 65,536 bytes (64 KB).
pub fn create_in_memory_session(
    server: Arc<McpServer>,
    buffer_size: usize,
) -> (DuplexStream, InMemoryTransportHandle) {
    let (client_stream, server_stream) = tokio::io::duplex(buffer_size);
    let handle = spawn_in_memory_transport(server, server_stream)
        .expect("Failed to spawn in-memory transport");
    (client_stream, handle)
}
