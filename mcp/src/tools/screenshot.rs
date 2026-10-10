//! `get_screenshot` tool implementation.

use crate::schema::{ToolCallResult, ToolContent};
use slate_agent::traits::AutomationEngine;

/// Dispatches the `get_screenshot` tool.
pub async fn handle_screenshot(
    engine: &dyn AutomationEngine,
    args: serde_json::Value,
) -> ToolCallResult {
    let _mime_type = args
        .get("mime_type")
        .and_then(|v| v.as_str())
        .unwrap_or("image/png");

    match engine.renderer().get_screenshot().await {
        Ok(screenshot) => {
            let base64_data = screenshot.to_base64_png();
            let format = if screenshot.format.is_empty() {
                "image/png".to_string()
            } else {
                screenshot.format.clone()
            };
            ToolCallResult::success(vec![ToolContent::image(base64_data, format)])
        }
        Err(err) => ToolCallResult::failure_text(err.to_string()),
    }
}
