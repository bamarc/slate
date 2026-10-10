//! Standard I/O (stdin/stdout) transport for CLI and IDE MCP agent connections.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::broadcast;

use slate_agent::error::AgentError;
use slate_agent::protocol::ProtocolServerHandle;

use crate::server::McpServer;
use crate::transport::{run_line_transport, McpTransportError};

/// Configures environment logging to write exclusively to `stderr`.
///
/// In MCP stdio mode, stdout is strictly reserved for JSON-RPC wire protocol messages.
/// Any logging or diagnostic output written to stdout will corrupt the JSON stream.
pub fn ensure_stderr_logging() {
    let _ = env_logger::Builder::from_default_env()
        .target(env_logger::Target::Stderr)
        .try_init();
}

/// Lifecycle handle for an active Stdio MCP transport server.
pub struct StdioTransportHandle {
    running: Arc<AtomicBool>,
    shutdown_tx: broadcast::Sender<()>,
    join_handle: Option<tokio::task::JoinHandle<()>>,
}

impl ProtocolServerHandle for StdioTransportHandle {
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
        Some("stdio://process".to_string())
    }
}

impl Drop for StdioTransportHandle {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

/// Spawns the Stdio MCP transport in a background Tokio task.
///
/// Automatically redirects logger output to `stderr` and binds to `tokio::io::stdin()`
/// and `tokio::io::stdout()`.
pub fn spawn_stdio_transport(server: Arc<McpServer>) -> Result<StdioTransportHandle, AgentError> {
    ensure_stderr_logging();

    let running = Arc::new(AtomicBool::new(true));
    let (shutdown_tx, shutdown_rx) = broadcast::channel(1);
    let running_clone = running.clone();

    let join_handle = tokio::spawn(async move {
        let stdin = tokio::io::stdin();
        let stdout = tokio::io::stdout();
        let res = run_line_transport(server, stdin, stdout, Some(shutdown_rx)).await;
        running_clone.store(false, Ordering::SeqCst);
        if let Err(e) = res {
            log::warn!("Stdio transport session ended: {}", e);
        }
    });

    Ok(StdioTransportHandle {
        running,
        shutdown_tx,
        join_handle: Some(join_handle),
    })
}

/// Runs the Stdio transport to completion on the current async task.
pub async fn run_stdio(
    server: Arc<McpServer>,
    shutdown_rx: Option<broadcast::Receiver<()>>,
) -> Result<(), McpTransportError> {
    ensure_stderr_logging();
    let stdin = tokio::io::stdin();
    let stdout = tokio::io::stdout();
    run_line_transport(server, stdin, stdout, shutdown_rx).await
}
