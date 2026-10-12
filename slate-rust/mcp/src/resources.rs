//! MCP Resources implementation (`slate://app/context` and `slate://logs/live`).

use std::sync::Arc;
use tokio::sync::Mutex;

use crate::schema::{Resource, ResourceContent};
use slate_agent::traits::AutomationEngine;

/// Errors arising during resource access.
#[derive(Debug, Clone, PartialEq)]
pub enum ResourceError {
    NotFound(String),
    Internal(String),
}

/// Returns the standard exposed MCP resources.
pub fn list_resources() -> Vec<Resource> {
    vec![
        Resource {
            uri: "slate://app/context".to_string(),
            name: "Application Context".to_string(),
            description: Some(
                "Current Slate application window metadata and configuration".to_string(),
            ),
            mime_type: Some("application/json".to_string()),
        },
        Resource {
            uri: "slate://logs/live".to_string(),
            name: "Live Execution Logs".to_string(),
            description: Some("Real-time logging stream from Slate runtime".to_string()),
            mime_type: Some("text/plain".to_string()),
        },
    ]
}

/// Maximum retained lines of the live log buffer. Older lines are dropped
/// (oldest first) and the drops are counted; see `McpServer::add_log`.
pub const MAX_LOG_LINES: usize = 2000;

/// Append one line to a live log buffer, evicting oldest-first past
/// [`MAX_LOG_LINES`] and counting every drop in `dropped`.
///
/// This is the ONLY sanctioned write path for tool/dispatch logging: pushing
/// to the `Vec` directly bypasses the bound (unbounded growth) and loses the
/// eviction count. `McpServer::add_log` delegates here so the server and all
/// tools share one bounded implementation.
pub async fn push_bounded_log(
    logs: &Arc<Mutex<Vec<String>>>,
    dropped: &Arc<std::sync::atomic::AtomicU64>,
    line: String,
) {
    let mut guard = logs.lock().await;
    guard.push(line);
    if guard.len() > MAX_LOG_LINES {
        let excess = guard.len() - MAX_LOG_LINES;
        guard.drain(..excess);
        dropped.fetch_add(excess as u64, std::sync::atomic::Ordering::SeqCst);
    }
}

/// Reads the resource content for a specified URI.
///
/// Viewport contract: dimensions are logical px from the renderer's
/// `get_viewport_size` (the single source of truth shared with click
/// bounds-checking). A renderer failure surfaces as an error; no fake
/// fallback size is substituted.
///
/// `dropped_logs` is the process-local eviction count from the bounded buffer
/// (`McpServer::dropped_log_count`). When non-zero, the `slate://logs/live`
/// text carries a header line naming the count — eviction is visible over the
/// wire instead of silently truncating history.
pub async fn read_resource(
    engine: &dyn AutomationEngine,
    logs: &Arc<Mutex<Vec<String>>>,
    uri: &str,
    app_name: &str,
    app_version: &str,
    dropped_logs: u64,
) -> Result<ResourceContent, ResourceError> {
    match uri {
        "slate://app/context" => {
            let (window_width, window_height) = engine
                .renderer()
                .get_viewport_size()
                .await
                .map_err(|e| ResourceError::Internal(format!("viewport unavailable: {e}")))?;

            let context_json = serde_json::json!({
                "app": app_name,
                "version": app_version,
                "window_width": window_width,
                "window_height": window_height,
            });

            Ok(ResourceContent {
                uri: "slate://app/context".to_string(),
                mime_type: Some("application/json".to_string()),
                text: Some(context_json.to_string()),
                blob: None,
            })
        }
        "slate://logs/live" | "slate://app/logs" => {
            let lines = logs.lock().await;
            let mut text = String::new();
            if dropped_logs > 0 {
                text.push_str(&format!(
                    "[MCP] {dropped_logs} oldest log line(s) dropped (buffer cap {MAX_LOG_LINES})\n"
                ));
            }
            text.push_str(&lines.join("\n"));
            Ok(ResourceContent {
                uri: uri.to_string(),
                mime_type: Some("text/plain".to_string()),
                text: Some(text),
                blob: None,
            })
        }
        other => Err(ResourceError::NotFound(other.to_string())),
    }
}
