//! Protocol/transport minimums (plan Phase 4+5): `get_state` filtering,
//! single-form click coordinates, logical-px viewport error propagation,
//! bounded logs, and `initialize` negotiation.

use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use slate_agent::engine::{
    DefaultAutomationEngine, DefaultElementController, DefaultStateProvider, DefaultUiInspector,
    DefaultVisualRenderer,
};
use slate_agent::error::AgentError;
use slate_agent::model::{AppState, Screenshot};
use slate_agent::traits::{StateProvider, VisualRenderer};
use slate_mcp::error::INTERNAL_ERROR;
use slate_mcp::resources::MAX_LOG_LINES;
use slate_mcp::schema::{McpInitializeResult, ToolCallResult};
use slate_mcp::server::{JsonRpcResponse, McpServer};
use slate_mcp::{create_in_memory_session, InMemoryMcpClient};

/// Renderer that cannot report a viewport (e.g. no window attached).
struct FailingRenderer;

#[async_trait::async_trait]
impl VisualRenderer for FailingRenderer {
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError> {
        Err(AgentError::render_error("no window attached"))
    }

    async fn get_viewport_size(&self) -> Result<(u32, u32), AgentError> {
        Err(AgentError::render_error("no window attached"))
    }
}

async fn engine_with_props(props: Vec<(&str, serde_json::Value)>) -> Arc<DefaultAutomationEngine> {
    let state = Arc::new(DefaultStateProvider::new("main"));
    for (k, v) in props {
        state.set_property(k, v).await.unwrap();
    }
    Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::new("Test Window", 800.0, 600.0)),
        Arc::new(DefaultElementController),
        state,
        Arc::new(DefaultVisualRenderer::new(800, 600)),
    ))
}

fn failing_viewport_engine() -> McpServer {
    let engine = Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::new("Test Window", 800.0, 600.0)),
        Arc::new(DefaultElementController),
        Arc::new(DefaultStateProvider::new("main")),
        Arc::new(FailingRenderer),
    ));
    McpServer::new(engine)
}

async fn call_tool(server: &McpServer, id: u64, name: &str, args: serde_json::Value) -> ToolCallResult {
    let raw = serde_json::json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": { "name": name, "arguments": args }
    });
    let line = serde_json::to_string(&raw).unwrap();
    let resp_str = server.handle_line(&line).await.expect("response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
    serde_json::from_value(resp.result.expect("result, not error")).unwrap()
}

#[tokio::test]
async fn test_get_state_keys_filter() {
    let engine =
        engine_with_props(vec![("a", serde_json::json!(1)), ("b", serde_json::json!(2))]).await;
    let server = McpServer::new(engine);

    let res = call_tool(&server, 1, "get_state", serde_json::json!({ "keys": ["a"] })).await;
    assert!(!res.is_error);
    let state: AppState = serde_json::from_str(res.content[0].text.as_ref().unwrap()).unwrap();
    assert!(state.properties.contains_key("a"));
    assert!(!state.properties.contains_key("b"));
}

#[tokio::test]
async fn test_get_state_legacy_query_filter() {
    let engine =
        engine_with_props(vec![("a", serde_json::json!(1)), ("b", serde_json::json!(2))]).await;
    let server = McpServer::new(engine);

    // Deprecated single-`query` string maps to a one-key filter.
    let res = call_tool(&server, 1, "get_state", serde_json::json!({ "query": "b" })).await;
    assert!(!res.is_error);
    let state: AppState = serde_json::from_str(res.content[0].text.as_ref().unwrap()).unwrap();
    assert_eq!(state.properties.len(), 1);
    assert!(state.properties.contains_key("b"));
}

#[tokio::test]
async fn test_get_state_keys_filter_via_client() {
    let engine =
        engine_with_props(vec![("a", serde_json::json!(1)), ("b", serde_json::json!(2))]).await;
    let server = Arc::new(McpServer::new(engine));
    let (client_stream, _handle) = create_in_memory_session(server, 65536);
    let client = InMemoryMcpClient::connect_duplex(client_stream);

    client.initialize("test", "0.0.0").await.expect("handshake");
    let val = client
        .get_state(Some(vec!["a".to_string()]))
        .await
        .expect("get_state");
    let res: ToolCallResult = serde_json::from_value(val).unwrap();
    assert!(!res.is_error);
    let state: AppState = serde_json::from_str(res.content[0].text.as_ref().unwrap()).unwrap();
    assert!(state.properties.contains_key("a"));
    assert!(!state.properties.contains_key("b"));
}

#[tokio::test]
async fn test_click_client_sends_single_coordinate_form() {
    let (client_stream, server_stream) = tokio::io::duplex(65536);
    let (srv_reader, mut srv_writer) = tokio::io::split(server_stream);
    // Minimal probe server: captures the wire arguments, then replies success.
    let probe = tokio::spawn(async move {
        let mut br = BufReader::new(srv_reader);
        let mut line = String::new();
        br.read_line(&mut line).await.expect("read request");
        let req: serde_json::Value = serde_json::from_str(line.trim()).expect("valid JSON-RPC");
        let args = req["params"]["arguments"].clone();
        let resp = serde_json::json!({
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": { "content": [{ "type": "text", "text": "ok" }], "isError": false }
        });
        let mut payload = serde_json::to_string(&resp).unwrap();
        payload.push('\n');
        srv_writer.write_all(payload.as_bytes()).await.expect("write");
        srv_writer.flush().await.expect("flush");
        args
    });

    let client = InMemoryMcpClient::connect_duplex(client_stream);
    let res = client
        .click_element(None, Some((10.0, 20.0)))
        .await
        .expect("click call");
    let args = probe.await.expect("probe done");

    assert_eq!(args["x"], serde_json::json!(10.0));
    assert_eq!(args["y"], serde_json::json!(20.0));
    assert!(
        args.get("point").is_none(),
        "legacy `point` duplicate must not be sent"
    );
    assert_eq!(res["isError"], serde_json::json!(false));
}

#[tokio::test]
async fn test_click_viewport_error_propagates() {
    let server = failing_viewport_engine();
    // No silent fake-size fallback: renderer failure rejects the click.
    let res = call_tool(
        &server,
        1,
        "click_element",
        serde_json::json!({ "x": 5.0, "y": 5.0 }),
    )
    .await;
    assert!(res.is_error);
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("Viewport unavailable"));
}

#[tokio::test]
async fn test_context_resource_viewport_error_propagates() {
    let server = failing_viewport_engine();
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": {"uri": "slate://app/context"}}"#;
    let resp_str = server.handle_line(raw).await.expect("response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
    assert!(resp.result.is_none());
    let err = resp.error.expect("error object");
    assert_eq!(err.code, INTERNAL_ERROR);
    assert!(err.message.contains("viewport"));
}

#[tokio::test]
async fn test_log_buffer_bounded_with_drop_count() {
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    for i in 0..(MAX_LOG_LINES + 50) {
        server.add_log(format!("line {i}")).await;
    }
    assert_eq!(server.logs().lock().await.len(), MAX_LOG_LINES);
    assert_eq!(server.dropped_log_count(), 50);
    // Oldest-first eviction: the first retained line is `line 50`.
    assert_eq!(server.logs().lock().await[0], "line 50");
}

#[tokio::test]
async fn test_initialize_accepts_known_version() {
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}"#;
    let resp_str = server.handle_line(raw).await.expect("response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
    let result = resp.result.clone().expect("result");
    let init: McpInitializeResult =
        serde_json::from_value(result.clone()).expect("init result");
    assert_eq!(init.protocol_version, "2024-11-05");
    assert!(server.is_initialized());
    // Known version answers bare: no negotiation `data` attached.
    assert!(result.get("data").is_none(), "no data for known version");
}

#[tokio::test]
async fn test_initialize_negotiates_version_mismatch() {
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}"#;
    let resp_str = server.handle_line(raw).await.expect("response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
    let result = resp.result.expect("mismatch still answers");
    // Our version is echoed ...
    assert_eq!(result["protocolVersion"], serde_json::json!("2024-11-05"));
    // ... plus the supported set and the requested version for the client.
    assert!(result["data"]["supportedVersions"]
        .as_array()
        .unwrap()
        .contains(&serde_json::json!("2024-11-05")));
    assert_eq!(result["data"]["requestedVersion"], serde_json::json!("2025-06-18"));
}

#[tokio::test]
async fn test_initialize_garbage_version_negotiates_with_echo() {
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "bogus-9.9"}}"#;
    let resp_str = server.handle_line(raw).await.expect("response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
    let result = resp.result.expect("garbage version still answers");
    assert_eq!(result["protocolVersion"], serde_json::json!("2024-11-05"));
    assert_eq!(result["data"]["requestedVersion"], serde_json::json!("bogus-9.9"));
}

#[tokio::test]
async fn test_capabilities_deadvertise_unimplemented() {
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}"#;
    let resp_str = server.handle_line(raw).await.expect("response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
    let init: McpInitializeResult =
        serde_json::from_value(resp.result.expect("result")).expect("init result");
    // Only the implemented surface is advertised: no listChanged, no
    // subscribe, no logging (logging/setLevel unimplemented).
    assert_eq!(init.capabilities.tools, Some(serde_json::json!({})));
    assert_eq!(init.capabilities.resources, Some(serde_json::json!({})));
    assert!(init.capabilities.logging.is_none());
}

// ---------------------------------------------------------------------------
// Review-fix track: bounded tool logging through dispatch, strict get_state,
// init data-shape, capability negatives, kill idempotence, PNG magic.
// ---------------------------------------------------------------------------

/// BLOCKER: tool logging must flow through the bounded buffer — 2050
/// `click_element` calls through `handle_line` retain exactly MAX_LOG_LINES
/// with 50 counted drops (previously tools pushed the Vec directly,
/// bypassing the bound entirely).
#[tokio::test]
async fn test_tool_logging_bounded_through_dispatch() {
    assert_eq!(MAX_LOG_LINES, 2000, "buffer cap literal pinned at 2000");
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    for i in 0..(MAX_LOG_LINES + 50) {
        let raw = format!(
            r#"{{"jsonrpc": "2.0", "id": {}, "method": "tools/call", "params": {{"name": "click_element", "arguments": {{"id": "probe"}}}}}}"#,
            1000 + i
        );
        let resp_str = server.handle_line(&raw).await.expect("response");
        let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
        assert!(resp.result.is_some(), "click {i} must succeed, got {resp:?}");
    }
    assert_eq!(server.logs().lock().await.len(), MAX_LOG_LINES);
    assert_eq!(server.dropped_log_count(), 50);
}

/// Eviction is visible over the wire: once the buffer overflows,
/// `slate://logs/live` carries a header line naming the drop count.
#[tokio::test]
async fn test_logs_live_surfaces_drop_count_over_wire() {
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    // No eviction yet: no header line.
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": {"uri": "slate://logs/live"}}"#;
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.expect("response")).unwrap();
    let text = resp.result.unwrap()["contents"][0]["text"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(!text.contains("dropped"), "no header before any eviction");

    for i in 0..(MAX_LOG_LINES + 5) {
        server.add_log(format!("line {i}")).await;
    }
    assert_eq!(server.dropped_log_count(), 5);
    let resp: JsonRpcResponse =
        serde_json::from_str(&server.handle_line(raw).await.expect("response")).unwrap();
    let text = resp.result.unwrap()["contents"][0]["text"]
        .as_str()
        .unwrap()
        .to_string();
    let first_line = text.lines().next().unwrap_or("");
    assert!(
        first_line.contains("5 oldest log line(s) dropped"),
        "wire header must name the eviction count, got: {first_line}"
    );
}

/// Strict `get_state` validation: both-keys-and-query is rejected...
#[tokio::test]
async fn test_get_state_rejects_keys_and_query_together() {
    let engine = engine_with_props(vec![("a", serde_json::json!(1))]).await;
    let server = McpServer::new(engine);
    let res = call_tool(
        &server,
        1,
        "get_state",
        serde_json::json!({ "keys": ["a"], "query": "a" }),
    )
    .await;
    assert!(res.is_error, "keys+query together must fail closed");
    assert!(res.content[0]
        .text
        .as_ref()
        .unwrap()
        .contains("not both"));
}

/// ...non-array `keys` and non-string `query` are rejected (no fail-open to
/// unfiltered state)...
#[tokio::test]
async fn test_get_state_rejects_malformed_filters() {
    let engine = engine_with_props(vec![("a", serde_json::json!(1))]).await;
    let server = McpServer::new(engine);
    for (id, args) in [
        (1, serde_json::json!({ "keys": "a" })),
        (2, serde_json::json!({ "keys": ["a", 1] })),
        (3, serde_json::json!({ "query": 5 })),
        (4, serde_json::json!({ "query": ["a"] })),
    ] {
        let res = call_tool(&server, id, "get_state", args).await;
        assert!(res.is_error, "malformed filter #{id} must fail closed");
    }
}

/// ...and an explicitly empty `keys: []` is valid, yielding empty properties.
#[tokio::test]
async fn test_get_state_empty_keys_yields_empty_properties() {
    let engine = engine_with_props(vec![("a", serde_json::json!(1))]).await;
    let server = McpServer::new(engine);
    let res = call_tool(&server, 1, "get_state", serde_json::json!({ "keys": [] })).await;
    assert!(!res.is_error, "empty keys must be accepted");
    let state: AppState = serde_json::from_str(res.content[0].text.as_ref().unwrap()).unwrap();
    assert!(state.properties.is_empty());
}

/// `initialize` without a requested version returns the bare result — `data`
/// is attached only when a version was actually requested.
#[tokio::test]
async fn test_initialize_without_version_has_no_data() {
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}"#;
    let resp_str = server.handle_line(raw).await.expect("response");
    let resp: JsonRpcResponse = serde_json::from_str(&resp_str).unwrap();
    let result = resp.result.expect("result");
    assert!(result.get("data").is_none(), "no data without a requested version");
    assert_eq!(result["protocolVersion"], serde_json::json!("2024-11-05"));
}

/// Raw-JSON negative capability assertions: nothing unimplemented is
/// advertised on the wire (`listChanged`, `subscribe`, `logging`).
#[tokio::test]
async fn test_capabilities_wire_has_no_unimplemented_keys() {
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}"#;
    let resp_str = server.handle_line(raw).await.expect("response");
    assert!(!resp_str.contains("listChanged"), "must not advertise listChanged");
    assert!(!resp_str.contains("subscribe"), "must not advertise subscribe");
    assert!(!resp_str.contains("logging"), "must not advertise logging");
}

/// `get_screenshot` returns PNG bytes (magic header) through the tool layer.
#[tokio::test]
async fn test_screenshot_tool_returns_png_magic() {
    let engine = engine_with_props(vec![]).await;
    let server = McpServer::new(engine);
    let res = call_tool(&server, 1, "get_screenshot", serde_json::json!({})).await;
    assert!(!res.is_error);
    let data = res.content[0].data.as_ref().expect("image data");
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .expect("valid base64");
    assert_eq!(&bytes[..8], &[137, 80, 78, 71, 13, 10, 26, 10], "PNG magic");
}

/// `kill()` is idempotent (`kill`+`wait` reaps; a second `kill` on the
/// exited child is not an error) and `wait()` returns the exit status.
#[tokio::test]
async fn test_process_client_kill_idempotent() {
    let mut proc = slate_mcp::ProcessMcpClient::spawn("sleep", &["30"]).expect("spawn sleep");
    proc.kill().await.expect("first kill");
    proc.kill().await.expect("second kill must be idempotent");
    let status = proc.wait().await.expect("wait reaps");
    assert!(!status.success(), "killed sleep must not exit 0");
}
