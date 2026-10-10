//! `click_element` tool implementation.

use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::schema::ToolCallResult;
use slate_agent::model::{MouseButton, Point};
use slate_agent::traits::AutomationEngine;

/// Action result formatted for MCP client expectations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpActionResult {
    pub success: bool,
    pub target: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

/// Dispatches the `click_element` tool.
pub async fn handle_click_element(
    engine: &dyn AutomationEngine,
    logs: &Arc<Mutex<Vec<String>>>,
    args: serde_json::Value,
) -> ToolCallResult {
    let id_opt = args.get("id").and_then(|v| v.as_str());
    let label_opt = args.get("label").and_then(|v| v.as_str());
    let point_opt = args.get("point");
    let x_opt = args
        .get("x")
        .and_then(|v| v.as_f64())
        .or_else(|| point_opt.and_then(|p| p.get("x")).and_then(|v| v.as_f64()));
    let y_opt = args
        .get("y")
        .and_then(|v| v.as_f64())
        .or_else(|| point_opt.and_then(|p| p.get("y")).and_then(|v| v.as_f64()));
    let button_str = args
        .get("button")
        .and_then(|v| v.as_str())
        .unwrap_or("left");
    let click_count = args
        .get("click_count")
        .and_then(|v| v.as_u64())
        .unwrap_or(1) as u32;

    // Validate presence of target
    if id_opt.is_none() && label_opt.is_none() && (x_opt.is_none() || y_opt.is_none()) {
        return ToolCallResult::failure_text(
            "click_element requires 'id', 'label', or coordinates ('x','y')",
        );
    }

    let mouse_button = match button_str {
        "right" => MouseButton::Right,
        "middle" => MouseButton::Middle,
        _ => MouseButton::Left,
    };

    // Coordinate validation
    if let (Some(x), Some(y)) = (x_opt, y_opt) {
        if x < 0.0 || y < 0.0 {
            return ToolCallResult::failure_text(format!(
                "Coordinates cannot be negative: ({}, {})",
                x, y
            ));
        }

        let (viewport_w, viewport_h) = engine
            .renderer()
            .get_viewport_size()
            .await
            .unwrap_or((1920, 1080));

        if x > viewport_w as f64 || y > viewport_h as f64 {
            return ToolCallResult::failure_text(format!(
                "Coordinates ({}, {}) out of window bounds ({}x{})",
                x, y, viewport_w, viewport_h
            ));
        }
    }

    let target_name: String;
    let click_result = if let (Some(x), Some(y)) = (x_opt, y_opt) {
        let pt = Point::new(x as f32, y as f32);
        target_name = format!("{},{}", x, y);

        // Check if there is an element with an ID at this point in the UI tree
        let resolved_id = match engine.inspector().inspect_tree().await {
            Ok(tree) => tree.find_at_point(&pt).and_then(|n| {
                if !n.id.is_empty() {
                    Some(n.id.clone())
                } else {
                    None
                }
            }),
            Err(_) => None,
        };

        if let Some(ref target_id) = resolved_id {
            let mut last_res = engine.controller().click_element(target_id).await;
            if click_count >= 2 && last_res.is_ok() {
                last_res = engine.controller().click_element(target_id).await;
            }
            last_res
        } else {
            let mut last_res = engine.controller().click_at(pt, mouse_button).await;
            if click_count >= 2 && last_res.is_ok() {
                last_res = engine.controller().click_at(pt, mouse_button).await;
            }
            last_res
        }
    } else if let Some(id) = id_opt {
        target_name = id.to_string();
        let mut last_res = engine.controller().click_element(id).await;
        if click_count >= 2 && last_res.is_ok() {
            last_res = engine.controller().click_element(id).await;
        }
        last_res
    } else if let Some(label) = label_opt {
        target_name = label.to_string();
        let mut last_res = engine.controller().click_element(label).await;
        if click_count >= 2 && last_res.is_ok() {
            last_res = engine.controller().click_element(label).await;
        }
        last_res
    } else {
        unreachable!();
    };

    match click_result {
        Ok(act_res) => {
            logs.lock()
                .await
                .push(format!("[ACTION] Clicked {}", target_name));
            let mcp_res = McpActionResult {
                success: act_res.success,
                target: target_name,
                details: Some(act_res.message),
            };
            ToolCallResult::success_text(serde_json::to_string(&mcp_res).unwrap())
        }
        Err(err) => {
            let msg = match err {
                slate_agent::error::AgentError::ElementNotFound { target, .. } => {
                    format!("Element not found or not clickable: '{}'", target)
                }
                _ => {
                    let err_str = err.to_string();
                    if err_str.contains("not found") {
                        format!("Element not found or not clickable: '{}'", target_name)
                    } else {
                        err_str
                    }
                }
            };
            ToolCallResult::failure_text(msg)
        }
    }
}
