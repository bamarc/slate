//! `send_keys` tool implementation.

use std::sync::Arc;
use tokio::sync::Mutex;

use crate::schema::ToolCallResult;
use crate::tools::click::McpActionResult;
use slate_agent::traits::AutomationEngine;

/// Dispatches the `send_keys` tool.
pub async fn handle_send_keys(
    engine: &dyn AutomationEngine,
    logs: &Arc<Mutex<Vec<String>>>,
    text: &str,
    element_id: Option<&str>,
    clear_first: bool,
) -> ToolCallResult {
    let target_name = element_id.unwrap_or("active").to_string();

    // Check if targeted element is editable by inspecting the UI tree
    if let Some(target_id) = element_id {
        if let Ok(tree) = engine.inspector().inspect_tree().await {
            if let Some(node) = tree.root.find_by_id(target_id) {
                let role_lower = node.role.to_lowercase();
                let type_lower = node.type_name.to_lowercase();
                let is_editable = role_lower.contains("text")
                    || role_lower.contains("input")
                    || role_lower.contains("edit")
                    || type_lower.contains("input")
                    || type_lower.contains("textarea")
                    || type_lower.contains("text_input");

                if !is_editable {
                    return ToolCallResult::failure_text(format!(
                        "Target element '{}' is not an editable text input",
                        target_id
                    ));
                }
            }
        }
    }

    if clear_first {
        if let Some(target_id) = element_id {
            let _ = engine.controller().set_value(target_id, "").await;
        }
    }

    match engine.controller().send_keys(element_id, text).await {
        Ok(act_res) => {
            logs.lock()
                .await
                .push(format!("[ACTION] Typed into {}: {}", target_name, text));
            let mcp_res = McpActionResult {
                success: act_res.success,
                target: target_name,
                details: Some(act_res.message),
            };
            ToolCallResult::success_text(serde_json::to_string(&mcp_res).unwrap())
        }
        Err(err) => {
            let err_str = err.to_string();
            if err_str.contains("not an editable") {
                ToolCallResult::failure_text(format!(
                    "Target element '{}' is not an editable text input",
                    target_name
                ))
            } else {
                ToolCallResult::failure_text(err_str)
            }
        }
    }
}
