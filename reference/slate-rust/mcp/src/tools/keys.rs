//! `send_keys` tool implementation.

use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::resources::push_bounded_log;
use crate::schema::ToolCallResult;
use crate::tools::click::McpActionResult;
use slate_agent::traits::AutomationEngine;

/// Roles whose Slint `AccessibleRole` carries editable text, matched EXACTLY
/// (lowercased) against the inspected node role. Derived from
/// `i_slint_core::items::AccessibleRole`: `TextInput` -> "textbox",
/// `Spinbox` -> "spinbox", `Combobox` -> "combobox".
/// Anything else (button, header, navigation, …) is not a `send_keys` target.
fn is_editable_role(role: &str) -> bool {
    matches!(role, "textbox" | "spinbox" | "combobox")
}

/// Dispatches the `send_keys` tool.
pub async fn handle_send_keys(
    engine: &dyn AutomationEngine,
    logs: &Arc<Mutex<Vec<String>>>,
    dropped: &Arc<AtomicU64>,
    text: &str,
    element_id: Option<&str>,
    clear_first: bool,
) -> ToolCallResult {
    let target_name = element_id.unwrap_or("active").to_string();

    // Exact role/type gate against Slint AccessibleRole values. Fails CLOSED:
    // an unknown target id is an error, never a silent fallback to the
    // focused element.
    if let Some(target_id) = element_id {
        match engine.inspector().inspect_tree().await {
            Ok(tree) => match tree.root.find_by_id(target_id) {
                Some(node) => {
                    if !is_editable_role(&node.role.to_lowercase()) {
                        return ToolCallResult::failure_text(format!(
                            "Target element '{}' is not an editable text input",
                            target_id
                        ));
                    }
                }
                None => {
                    return ToolCallResult::failure_text(format!(
                        "Target element '{}' not found in UI tree",
                        target_id
                    ));
                }
            },
            Err(err) => {
                return ToolCallResult::failure_text(format!(
                    "Unable to verify target element '{}': {}",
                    target_id, err
                ));
            }
        }
    }

    // `clear_first` is a real backend write: propagate its result instead of
    // discarding it, so callers never see a success after a failed clear.
    // Without a target there is nothing to clear — fail closed (M2) instead
    // of silently reporting success with no clear performed.
    if clear_first {
        match element_id {
            Some(target_id) => {
                if let Err(err) = engine.controller().set_value(target_id, "").await {
                    return ToolCallResult::failure_text(format!(
                        "Failed to clear target element '{}': {}",
                        target_id, err
                    ));
                }
            }
            None => {
                return ToolCallResult::failure_text(
                    "send_keys with 'clear_first' requires 'element_id': no target to clear",
                );
            }
        }
    }

    match engine.controller().send_keys(element_id, text).await {
        Ok(act_res) => {
            push_bounded_log(
                logs,
                dropped,
                format!("[ACTION] Typed into {}: {}", target_name, text),
            )
            .await;
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
