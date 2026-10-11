//! MCP standard tools registry and dispatching.

pub mod click;
pub mod keys;
pub mod screenshot;
pub mod state;
pub mod tree;

// Friendly aliases
pub use click::*;
pub use keys::*;
pub use screenshot::*;
pub use state::*;
pub use tree::*;

pub use keys as send_keys;
pub use tree as inspect;

use crate::schema::ToolCallResult;
use slate_agent::traits::AutomationEngine;
use std::sync::Arc;
use tokio::sync::Mutex;

/// Errors arising during tool lookup or argument validation.
#[derive(Debug, Clone, PartialEq)]
pub enum ToolDispatchError {
    NotFound(String),
    InvalidParams(String),
    Internal(String),
}

/// Dispatches a tool by name against the AutomationEngine.
pub async fn dispatch_tool(
    engine: &dyn AutomationEngine,
    logs: &Arc<Mutex<Vec<String>>>,
    name: &str,
    arguments: serde_json::Value,
) -> Result<ToolCallResult, ToolDispatchError> {
    match name {
        "get_screenshot" => Ok(screenshot::handle_screenshot(engine, arguments).await),
        "inspect_tree" => Ok(tree::handle_inspect_tree(engine, arguments).await),
        "click_element" => Ok(click::handle_click_element(engine, logs, arguments).await),
        "send_keys" => {
            let text = match arguments.get("text").and_then(|v| v.as_str()) {
                Some(t) => t,
                None => {
                    return Err(ToolDispatchError::InvalidParams(
                        "Missing required argument 'text'".to_string(),
                    ));
                }
            };
            let element_id = arguments
                .get("element_id")
                .or_else(|| arguments.get("target_id"))
                .and_then(|v| v.as_str());
            let clear_first = arguments
                .get("clear_first")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);

            Ok(keys::handle_send_keys(engine, logs, text, element_id, clear_first).await)
        }
        "get_state" => Ok(state::handle_get_state(engine, arguments).await),
        unknown => Err(ToolDispatchError::NotFound(unknown.to_string())),
    }
}
