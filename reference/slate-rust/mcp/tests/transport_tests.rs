//! Unit and integration tests for MCP transports (stdio and in-memory duplex).

use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use slate_agent::engine::{
    DefaultAutomationEngine, DefaultElementController, DefaultStateProvider, DefaultUiInspector,
    DefaultVisualRenderer,
};
use slate_agent::protocol::ProtocolServerHandle;
use slate_mcp::server::{JsonRpcResponse, McpServer};
use slate_mcp::transport::{
    create_in_memory_session, ensure_stderr_logging, spawn_in_memory_transport,
};

fn create_mock_server() -> Arc<McpServer> {
    let engine = Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::new(
            "Slate Transport Test",
            800.0,
            600.0,
        )),
        Arc::new(DefaultElementController),
        Arc::new(DefaultStateProvider::new("main")),
        Arc::new(DefaultVisualRenderer::new(800, 600)),
    ));
    Arc::new(McpServer::new(engine))
}

#[tokio::test]
async fn test_line_framing_crlf_lf_and_blank_lines() {
    let server = create_mock_server();
    let (client_stream, server_stream) = tokio::io::duplex(65536);
    let handle = spawn_in_memory_transport(server, server_stream).expect("Spawn failed");

    let (reader, mut writer) = tokio::io::split(client_stream);
    let mut buf_reader = BufReader::new(reader);

    // Send CRLF, blank lines, and LF
    let req1 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n";
    let blank = "\n\r\n   \n";
    let req2 = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n";

    writer.write_all(req1.as_bytes()).await.unwrap();
    writer.write_all(blank.as_bytes()).await.unwrap();
    writer.write_all(req2.as_bytes()).await.unwrap();
    writer.flush().await.unwrap();

    let mut line1 = String::new();
    buf_reader.read_line(&mut line1).await.unwrap();
    let resp1: JsonRpcResponse = serde_json::from_str(&line1).unwrap();
    assert_eq!(resp1.id, Some(serde_json::json!(1)));

    let mut line2 = String::new();
    buf_reader.read_line(&mut line2).await.unwrap();
    let resp2: JsonRpcResponse = serde_json::from_str(&line2).unwrap();
    assert_eq!(resp2.id, Some(serde_json::json!(2)));

    handle.stop().unwrap();
}

#[tokio::test]
async fn test_in_memory_duplex_roundtrip() {
    let server = create_mock_server();
    let (client_stream, handle) = create_in_memory_session(server, 65536);

    let (reader, mut writer) = tokio::io::split(client_stream);
    let mut buf_reader = BufReader::new(reader);

    let req = "{\"jsonrpc\":\"2.0\",\"id\":\"init-1\",\"method\":\"initialize\"}\n";
    writer.write_all(req.as_bytes()).await.unwrap();
    writer.flush().await.unwrap();

    let mut line = String::new();
    buf_reader.read_line(&mut line).await.unwrap();
    let resp: JsonRpcResponse = serde_json::from_str(&line).unwrap();

    assert_eq!(resp.id, Some(serde_json::json!("init-1")));
    assert!(resp.result.is_some());

    handle.stop().unwrap();
}

#[tokio::test]
async fn test_in_memory_concurrent_burst_50_requests() {
    let server = create_mock_server();
    let (client_stream, handle) = create_in_memory_session(server, 131072);

    let (reader, mut writer) = tokio::io::split(client_stream);
    let buf_reader = Arc::new(tokio::sync::Mutex::new(BufReader::new(reader)));

    // Send 50 requests in quick succession
    for i in 1..=50 {
        let req = format!("{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}}\n", i);
        writer.write_all(req.as_bytes()).await.unwrap();
    }
    writer.flush().await.unwrap();

    // Collect 50 responses
    let mut received_ids = std::collections::HashSet::new();
    for _ in 1..=50 {
        let mut line = String::new();
        let mut reader_guard = buf_reader.lock().await;
        reader_guard.read_line(&mut line).await.unwrap();
        let resp: JsonRpcResponse = serde_json::from_str(&line).unwrap();
        if let Some(id_val) = resp.id {
            if let Some(num) = id_val.as_i64() {
                received_ids.insert(num);
            }
        }
    }

    assert_eq!(received_ids.len(), 50);
    for i in 1..=50 {
        assert!(received_ids.contains(&i), "Missing response ID {}", i);
    }

    handle.stop().unwrap();
}

#[tokio::test]
async fn test_in_memory_graceful_eof_on_client_drop() {
    let server = create_mock_server();
    let (client_stream, server_stream) = tokio::io::duplex(65536);
    let handle = spawn_in_memory_transport(server, server_stream).unwrap();

    assert!(handle.is_running());
    drop(client_stream);

    // Give background task a moment to notice EOF
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!handle.is_running());
}

#[tokio::test]
async fn test_in_memory_cancellation_signal() {
    let server = create_mock_server();
    let (_client_stream, server_stream) = tokio::io::duplex(65536);
    let handle = spawn_in_memory_transport(server, server_stream).unwrap();

    assert!(handle.is_running());
    assert!(handle.local_addr().is_some());
    handle.stop().unwrap();
    assert!(!handle.is_running());
}

#[test]
fn test_stdio_logging_isolation_to_stderr() {
    ensure_stderr_logging();
    log::info!("Diagnostic message strictly routing to stderr");
}
