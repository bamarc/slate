//! Unit and integration tests for MCP resources (`slate://app/context` and `slate://logs/live`).

use slate_agent::engine::{
    DefaultAutomationEngine, DefaultElementController, DefaultStateProvider, DefaultUiInspector,
    DefaultVisualRenderer,
};
use slate_mcp::error::INVALID_PARAMS;
use slate_mcp::schema::{Resource, ResourceContent};
use slate_mcp::server::{JsonRpcResponse, McpServer};
use std::sync::Arc;

fn create_test_server() -> McpServer {
    let engine = Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::new("Slate Test Window", 1040.0, 720.0)),
        Arc::new(DefaultElementController),
        Arc::new(DefaultStateProvider::new("main")),
        Arc::new(DefaultVisualRenderer::new(1040, 720)),
    ));
    McpServer::new(engine)
}

#[tokio::test]
async fn test_resources_list() {
    let server = create_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "resources/list"}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res_val = resp.result.unwrap();
    let resources: Vec<Resource> = serde_json::from_value(res_val["resources"].clone()).unwrap();

    assert_eq!(resources.len(), 2);
    let uris: Vec<String> = resources.into_iter().map(|r| r.uri).collect();
    assert!(uris.contains(&"slate://app/context".to_string()));
    assert!(uris.contains(&"slate://logs/live".to_string()));
}

#[tokio::test]
async fn test_resources_read_context() {
    let server = create_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 2, "method": "resources/read", "params": {"uri": "slate://app/context"}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res_val = resp.result.unwrap();
    let contents: Vec<ResourceContent> =
        serde_json::from_value(res_val["contents"].clone()).unwrap();

    assert_eq!(contents.len(), 1);
    assert_eq!(contents[0].uri, "slate://app/context");
    assert_eq!(contents[0].mime_type.as_deref(), Some("application/json"));

    let text = contents[0].text.as_ref().unwrap();
    let json: serde_json::Value = serde_json::from_str(text).unwrap();
    assert_eq!(json["app"], "slate-showcase");
    assert_eq!(json["window_width"], 1040);
    assert_eq!(json["window_height"], 720);
}

#[tokio::test]
async fn test_resources_read_logs() {
    let server = create_test_server();
    server
        .add_log("[ACTION] Custom test action performed")
        .await;

    let raw = r#"{"jsonrpc": "2.0", "id": 3, "method": "resources/read", "params": {"uri": "slate://logs/live"}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res_val = resp.result.unwrap();
    let contents: Vec<ResourceContent> =
        serde_json::from_value(res_val["contents"].clone()).unwrap();

    assert_eq!(contents.len(), 1);
    assert_eq!(contents[0].uri, "slate://logs/live");
    assert_eq!(contents[0].mime_type.as_deref(), Some("text/plain"));

    let text = contents[0].text.as_ref().unwrap();
    assert!(text.contains("[INFO] Slate application initialized"));
    assert!(text.contains("[ACTION] Custom test action performed"));
}

#[tokio::test]
async fn test_resources_read_logs_alias() {
    let server = create_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": {"uri": "slate://app/logs"}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let res_val = resp.result.unwrap();
    let contents: Vec<ResourceContent> =
        serde_json::from_value(res_val["contents"].clone()).unwrap();

    assert_eq!(contents.len(), 1);
    assert!(contents[0].text.as_ref().unwrap().contains("[INFO]"));
}

#[tokio::test]
async fn test_resources_read_invalid_uri() {
    let server = create_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": {"uri": "slate://invalid/resource/uri"}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let err = resp.error.unwrap();
    assert_eq!(err.code, INVALID_PARAMS);
    assert!(err.message.contains("not found"));
}

#[tokio::test]
async fn test_resources_read_missing_uri() {
    let server = create_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 6, "method": "resources/read", "params": {}}"#;
    let resp_str = server.handle_line(raw).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let err = resp.error.unwrap();
    assert_eq!(err.code, INVALID_PARAMS);
    assert!(err.message.contains("Missing 'uri' parameter"));
}
