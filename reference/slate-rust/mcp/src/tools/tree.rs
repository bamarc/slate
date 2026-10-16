//! `inspect_tree` tool implementation.

use crate::schema::ToolCallResult;
use slate_agent::model::UiElementNode;
use slate_agent::traits::AutomationEngine;

/// Dispatches the `inspect_tree` tool.
pub async fn handle_inspect_tree(
    engine: &dyn AutomationEngine,
    args: serde_json::Value,
) -> ToolCallResult {
    let root_id = args.get("root_id").and_then(|v| v.as_str());
    let max_depth = args
        .get("max_depth")
        .and_then(|v| v.as_u64())
        .map(|d| d as u32);

    if let Some(0) = max_depth {
        return ToolCallResult::failure_text("max_depth must be >= 1");
    }

    let mut tree = match engine.inspector().inspect_tree().await {
        Ok(t) => t,
        Err(e) => return ToolCallResult::failure_text(e.to_string()),
    };

    if let Some(id) = root_id {
        match tree.root.find_by_id(id).cloned() {
            Some(matched) => {
                tree.root = matched;
            }
            None => {
                return ToolCallResult::failure_text(format!("Root element '{}' not found", id));
            }
        }
    }

    if let Some(depth) = max_depth {
        prune_depth(&mut tree.root, 1, depth);
    }

    match serde_json::to_string(&tree) {
        Ok(json_str) => ToolCallResult::success_text(json_str),
        Err(err) => ToolCallResult::failure_text(format!("Serialization error: {}", err)),
    }
}

fn prune_depth(node: &mut UiElementNode, current_depth: u32, max_depth: u32) {
    if current_depth >= max_depth {
        node.children.clear();
    } else {
        for child in &mut node.children {
            prune_depth(child, current_depth + 1, max_depth);
        }
    }
}
