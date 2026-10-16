//! `click_element` tool implementation.

use serde::{Deserialize, Serialize};
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::resources::push_bounded_log;
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
///
/// Targeting is exclusive (M4): pass an element selector (`id`/`label`) OR
/// coordinates (`x`/`y`), never both — a combined call is rejected instead of
/// silently preferring one. The legacy `point: {x, y}` object remains accepted
/// as an alias for `x`/`y` (old clients); the canonical form is bare `x`/`y`
/// and the client only ever sends that.
pub async fn handle_click_element(
    engine: &dyn AutomationEngine,
    logs: &Arc<Mutex<Vec<String>>>,
    dropped: &Arc<AtomicU64>,
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

    // Exclusive targeting (M4): an element selector and coordinates together
    // are rejected — fail closed instead of silently preferring coordinates.
    // (Any `x`/`y` presence counts, including a half-formed pair.)
    if (id_opt.is_some() || label_opt.is_some()) && (x_opt.is_some() || y_opt.is_some()) {
        return ToolCallResult::failure_text(
            "click_element accepts either an element selector ('id'/'label') or coordinates ('x','y'), not both",
        );
    }

    // Validate `button` explicitly: unknown values are rejected, never coerced.
    let mouse_button = match button_str {
        "left" => MouseButton::Left,
        "right" => MouseButton::Right,
        "middle" => MouseButton::Middle,
        other => {
            return ToolCallResult::failure_text(format!(
                "Unsupported button '{}': expected 'left', 'right', or 'middle'",
                other
            ));
        }
    };

    // NOTE (Phase 1, E-3): the `click_element` backend path performs semantic
    // activation and is left-only. A non-left button on the element id/label
    // path is explicitly rejected so callers use coordinates + `click_at` for
    // context/middle clicks instead of silently getting a left click.
    // (Only applies when the element branch is actually taken — coordinates
    // take precedence and honor `button` via the pointer path.)
    let takes_element_branch = x_opt.is_none() || y_opt.is_none();
    let is_element_path = takes_element_branch && (id_opt.is_some() || label_opt.is_some());
    if is_element_path && mouse_button != MouseButton::Left {
        return ToolCallResult::failure_text(format!(
            "click_element with element id/label only supports button 'left' (got '{}'); use coordinates for '{}' clicks",
            button_str, button_str
        ));
    }

    // Coordinate validation.
    //
    // Viewport contract: all coordinates and bounds are logical px, matching
    // the `VisualRenderer::get_viewport_size` source of truth. There is no
    // per-callsite fallback size: if the renderer cannot report a viewport the
    // click is rejected instead of bounds-checked against a fake size.
    if let (Some(x), Some(y)) = (x_opt, y_opt) {
        if x < 0.0 || y < 0.0 {
            return ToolCallResult::failure_text(format!(
                "Coordinates cannot be negative: ({}, {})",
                x, y
            ));
        }

        let (viewport_w, viewport_h) = match engine.renderer().get_viewport_size().await {
            Ok(size) => size,
            Err(e) => {
                return ToolCallResult::failure_text(format!(
                    "Viewport unavailable, cannot validate coordinates: {}",
                    e
                ))
            }
        };

        if x > viewport_w as f64 || y > viewport_h as f64 {
            return ToolCallResult::failure_text(format!(
                "Coordinates ({}, {}) out of window bounds ({}x{})",
                x, y, viewport_w, viewport_h
            ));
        }
    }

    let target_name: String;
    // NOTE (Phase 1, E-4): a coordinate click always clicks the point via the
    // pointer-only `click_at` path. The tree is consulted solely to annotate
    // the report (`details`), never to substitute the target — this removes
    // the overlay-id hijack where a fullscreen overlay id replaced the point.
    //
    // NOTE (Phase 1, E-3): there are no OS double-click semantics yet.
    // `click_count` repeats the single-click dispatch that many times in
    // sequence (each repeat only on success of the previous); the schema
    // advertises [1, 2] but raw values are honored literally rather than
    // silently clamped to 2 (M3).
    let click_result = if let (Some(x), Some(y)) = (x_opt, y_opt) {
        let pt = Point::new(x as f32, y as f32);
        target_name = format!("{},{}", x, y);

        let mut last_res = engine.controller().click_at(pt, mouse_button).await;
        for _ in 1..click_count {
            if last_res.is_ok() {
                last_res = engine.controller().click_at(pt, mouse_button).await;
            }
        }
        last_res
    } else if let Some(id) = id_opt {
        target_name = id.to_string();
        let mut last_res = engine.controller().click_element(id).await;
        for _ in 1..click_count {
            if last_res.is_ok() {
                last_res = engine.controller().click_element(id).await;
            }
        }
        last_res
    } else if let Some(label) = label_opt {
        target_name = label.to_string();
        let mut last_res = engine.controller().click_element(label).await;
        for _ in 1..click_count {
            if last_res.is_ok() {
                last_res = engine.controller().click_element(label).await;
            }
        }
        last_res
    } else {
        unreachable!();
    };

    match click_result {
        Ok(act_res) => {
            push_bounded_log(
                logs,
                dropped,
                format!("[ACTION] Clicked {}", target_name),
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
