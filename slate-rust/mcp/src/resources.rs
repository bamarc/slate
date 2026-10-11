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

/// Reads the resource content for a specified URI.
pub async fn read_resource(
    engine: &dyn AutomationEngine,
    logs: &Arc<Mutex<Vec<String>>>,
    uri: &str,
) -> Result<ResourceContent, ResourceError> {
    match uri {
        "slate://app/context" => {
            let (window_width, window_height) = engine
                .renderer()
                .get_viewport_size()
                .await
                .unwrap_or((1040, 720));

            let context_json = serde_json::json!({
                "app": "slate-showcase",
                "version": "0.1.0",
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
            let log_text = logs.lock().await.join("\n");
            Ok(ResourceContent {
                uri: uri.to_string(),
                mime_type: Some("text/plain".to_string()),
                text: Some(log_text),
                blob: None,
            })
        }
        other => Err(ResourceError::NotFound(other.to_string())),
    }
}
