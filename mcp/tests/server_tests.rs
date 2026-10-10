//! Unit and integration tests for MCP JSON-RPC 2.0 protocol engine, handshake, and router.

use slate_agent::engine::{
    DefaultAutomationEngine, DefaultElementController, DefaultStateProvider, DefaultUiInspector,
    DefaultVisualRenderer,
};
use slate_mcp::error::{INVALID_REQUEST, METHOD_NOT_FOUND, PARSE_ERROR};
use slate_mcp::schema::McpInitializeResult;
use slate_mcp::server::{JsonRpcResponse, McpServer};
use std::sync::Arc;

fn create_test_server() -> McpServer {
    let engine = Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::new("Slate Test App", 800.0, 600.0)),
        Arc::new(DefaultElementController),
        Arc::new(DefaultStateProvider::new("main")),
        Arc::new(DefaultVisualRenderer::new(800, 600)),
    ));
    McpServer::new(engine)
}

#[tokio::test]
async fn test_jsonrpc_parse_error_malformed_json() {
    let server = create_test_server();
    let raw = "INVALID_JSON_RPC_PAYLOAD_STRING";
    let resp_str = server.handle_line(raw).await.expect("Expected response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).expect("Valid JSON-RPC response");

    assert!(resp.result.is_none());
    let err = resp.error.expect("Expected error object");
    assert_eq!(err.code, PARSE_ERROR);
    assert!(err.message.contains("Parse error"));
}

#[tokio::test]
async fn test_jsonrpc_invalid_request_not_object() {
    let server = create_test_server();
    let raw = "[1, 2, 3]";
    let resp_str = server.handle_line(raw).await.expect("Expected response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let err = resp.error.expect("Expected error object");
    assert_eq!(err.code, INVALID_REQUEST);
    assert!(err.message.contains("expected JSON object"));
}

#[tokio::test]
async fn test_jsonrpc_invalid_request_missing_version() {
    let server = create_test_server();
    let raw = r#"{"id": 1, "method": "ping"}"#;
    let resp_str = server.handle_line(raw).await.expect("Expected response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let err = resp.error.expect("Expected error object");
    assert_eq!(err.code, INVALID_REQUEST);
    assert!(err.message.contains("jsonrpc"));
}

#[tokio::test]
async fn test_jsonrpc_invalid_request_missing_method() {
    let server = create_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 1}"#;
    let resp_str = server.handle_line(raw).await.expect("Expected response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    let err = resp.error.expect("Expected error object");
    assert_eq!(err.code, INVALID_REQUEST);
    assert!(err.message.contains("Missing 'method'"));
}

#[tokio::test]
async fn test_jsonrpc_method_not_found() {
    let server = create_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": 42, "method": "system/shutdown"}"#;
    let resp_str = server.handle_line(raw).await.expect("Expected response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    assert_eq!(resp.id, Some(serde_json::json!(42)));
    let err = resp.error.expect("Expected error object");
    assert_eq!(err.code, METHOD_NOT_FOUND);
    assert!(err.message.contains("system/shutdown"));
}

#[tokio::test]
async fn test_mcp_initialize_handshake() {
    let server = create_test_server();
    assert!(!server.is_initialized());

    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}"#;
    let resp_str = server.handle_line(raw).await.expect("Expected response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    assert_eq!(resp.id, Some(serde_json::json!(1)));
    assert!(resp.error.is_none());

    let init_res: McpInitializeResult =
        serde_json::from_value(resp.result.unwrap()).expect("Valid McpInitializeResult");
    assert_eq!(init_res.protocol_version, "2024-11-05");
    assert_eq!(init_res.server_info.name, "slate-mcp");
    assert!(init_res.capabilities.tools.is_some());
    assert!(init_res.capabilities.resources.is_some());
    assert!(server.is_initialized());
}

#[tokio::test]
async fn test_mcp_notification_initialized() {
    let server = create_test_server();
    let raw = r#"{"jsonrpc": "2.0", "method": "notifications/initialized"}"#;
    let resp = server.handle_line(raw).await;

    // Notifications do not return wire responses
    assert!(resp.is_none());
    assert!(server.is_initialized());

    let logs = server.logs().lock().await.clone();
    assert!(logs
        .iter()
        .any(|l| l.contains("[MCP] Client initialized acknowledged")));
}

#[tokio::test]
async fn test_mcp_ping() {
    let server = create_test_server();
    let raw = r#"{"jsonrpc": "2.0", "id": "req-1", "method": "ping"}"#;
    let resp_str = server.handle_line(raw).await.expect("Expected response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();

    assert_eq!(resp.id, Some(serde_json::json!("req-1")));
    assert_eq!(resp.result, Some(serde_json::json!({})));
    assert!(resp.error.is_none());
}
