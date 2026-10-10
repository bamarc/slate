//! Asynchronous transport abstractions and common line-framing engine.

pub mod in_memory;
pub mod stdio;

pub use in_memory::{create_in_memory_session, spawn_in_memory_transport, InMemoryTransportHandle};
pub use stdio::{ensure_stderr_logging, run_stdio, spawn_stdio_transport, StdioTransportHandle};

use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{broadcast, mpsc};

use crate::server::McpServer;

/// Transport errors occurring during line framing or stream I/O.
#[derive(Debug, thiserror::Error)]
pub enum McpTransportError {
    #[error("I/O transport error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Transport write channel closed prematurely")]
    ChannelClosed,

    #[error("Server internal error: {0}")]
    Internal(String),
}

/// Bounded queue capacity for the asynchronous writer task.
const WRITER_QUEUE_CAPACITY: usize = 1024;

/// Asynchronous message framing pump that reads line-delimited JSON-RPC from `reader`,
/// dispatches requests via `server.handle_line(...)`, and writes formatted,
/// newline-terminated responses to `writer` with immediate flushing.
pub async fn run_line_transport<R, W>(
    server: Arc<McpServer>,
    reader: R,
    mut writer: W,
    mut shutdown_rx: Option<broadcast::Receiver<()>>,
) -> Result<(), McpTransportError>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let (writer_tx, mut writer_rx) = mpsc::channel::<String>(WRITER_QUEUE_CAPACITY);

    // Dedicated writer task ensuring serialized output and immediate flushing
    let writer_handle = tokio::spawn(async move {
        while let Some(mut payload) = writer_rx.recv().await {
            if !payload.ends_with('\n') {
                payload.push('\n');
            }
            if let Err(e) = writer.write_all(payload.as_bytes()).await {
                log::warn!("Transport writer write_all error: {}", e);
                break;
            }
            if let Err(e) = writer.flush().await {
                log::warn!("Transport writer flush error: {}", e);
                break;
            }
        }
    });

    let mut buf_reader = BufReader::new(reader);
    let mut line = String::new();

    loop {
        line.clear();
        tokio::select! {
            biased;

            // Check shutdown signal with highest priority
            Some(_) = async {
                match &mut shutdown_rx {
                    Some(rx) => rx.recv().await.ok(),
                    None => std::future::pending().await,
                }
            } => {
                log::debug!("Transport received cancellation shutdown signal");
                break;
            }

            read_res = buf_reader.read_line(&mut line) => {
                match read_res {
                    Ok(0) => {
                        // EOF: remote peer closed stream cleanly
                        log::debug!("Transport EOF encountered; closing session cleanly");
                        break;
                    }
                    Ok(_) => {
                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            continue; // Ignore blank lines / keep-alive pulses
                        }

                        let raw_line = trimmed.to_string();
                        let srv = server.clone();
                        let tx = writer_tx.clone();

                        // Dispatch request asynchronously to avoid blocking the read loop
                        tokio::spawn(async move {
                            if let Some(resp) = srv.handle_line(&raw_line).await {
                                let _ = tx.send(resp).await;
                            }
                        });
                    }
                    Err(err) => {
                        log::warn!("Transport reader error: {}", err);
                        drop(writer_tx);
                        let _ = writer_handle.await;
                        return Err(McpTransportError::Io(err));
                    }
                }
            }
        }
    }

    // Drop writer transmitter to trigger EOF on writer task queue
    drop(writer_tx);
    let _ = writer_handle.await;

    Ok(())
}
