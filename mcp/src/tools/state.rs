//! `get_state` tool implementation.

use crate::schema::ToolCallResult;
use slate_agent::traits::AutomationEngine;

/// Dispatches the `get_state` tool.
pub async fn handle_get_state(
    engine: &dyn AutomationEngine,
    args: serde_json::Value,
) -> ToolCallResult {
    let keys_filter: Option<Vec<String>> = args.get("keys").and_then(|v| v.as_array()).map(|arr| {
        arr.iter()
            .filter_map(|x| x.as_str().map(|s| s.to_string()))
            .collect()
    });

    match engine.state().get_state(None).await {
        Ok(mut state) => {
            if let Some(ref filter) = keys_filter {
                state.properties.retain(|k, _| filter.contains(k));
            }
            ToolCallResult::success_text(serde_json::to_string(&state).unwrap())
        }
        Err(err) => ToolCallResult::failure_text(err.to_string()),
    }
}
