//! `get_state` tool implementation.

use crate::schema::ToolCallResult;
use slate_agent::traits::AutomationEngine;

/// Dispatches the `get_state` tool.
///
/// Canonical filter: `keys` (array of property names). Legacy `query` (a single
/// property name string) is still accepted during client migration and maps to a
/// one-key filter; it is deprecated and will be removed.
///
/// Validation is strict and fails closed: `keys` and `query` together are
/// rejected (ambiguous), a non-array `keys` is rejected (never silently
/// treated as "no filter"), non-string entries are rejected, and a non-string
/// `query` is rejected. Explicit JSON `null` counts as absent for either key.
/// An explicitly empty `keys: []` is valid and yields an empty property map.
pub async fn handle_get_state(
    engine: &dyn AutomationEngine,
    args: serde_json::Value,
) -> ToolCallResult {
    // Explicit null == absent (standard JSON-RPC convention).
    let keys_arg = args.get("keys").filter(|v| !v.is_null());
    let query_arg = args.get("query").filter(|v| !v.is_null());
    if keys_arg.is_some() && query_arg.is_some() {
        return ToolCallResult::failure_text(
            "get_state accepts either 'keys' or legacy 'query', not both",
        );
    }
    let keys_filter: Option<Vec<String>> = if let Some(keys_val) = keys_arg {
        let arr = match keys_val.as_array() {
            Some(a) => a,
            None => {
                return ToolCallResult::failure_text(
                    "'keys' must be an array of property name strings",
                );
            }
        };
        let mut filter = Vec::with_capacity(arr.len());
        for item in arr {
            match item.as_str() {
                Some(s) => filter.push(s.to_string()),
                None => {
                    return ToolCallResult::failure_text(
                        "'keys' must be an array of property name strings",
                    );
                }
            }
        }
        Some(filter)
    } else if let Some(query_val) = query_arg {
        // Deprecated legacy form: single `query` string -> one-key filter.
        match query_val.as_str() {
            Some(q) => Some(vec![q.to_string()]),
            None => {
                return ToolCallResult::failure_text(
                    "'query' must be a single property name string (prefer 'keys')",
                );
            }
        }
    } else {
        None
    };

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
