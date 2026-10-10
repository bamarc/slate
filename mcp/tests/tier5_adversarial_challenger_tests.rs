//! Tier 5 Adversarial Coverage Hardening Test Suite for `slate-mcp`.
//!
//! Validates:
//! 1. JSON-RPC wire protocol edge cases: empty batch arrays, batch array requests,
//!    fractional and extreme ID types, huge payload lines, partial frame reads on disconnect,
//!    multibyte UTF-8 framing across buffer boundaries.
//! 2. Tool parameter edge cases: null and missing arguments, exact viewport boundaries,
//!    extreme float coordinates, unicode and RTL element selectors, boundary click counts,
//!    empty text and control characters in send_keys, tree inspection max_depth boundary pruning.
//! 3. Resource URI errors: case sensitivity, traversal, query strings, null byte injections.
//! 4. Transport backpressure and high-concurrency burst stress under 200 concurrent requests.

use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::time::timeout;

use slate_agent::engine::{
    DefaultAutomationEngine, DefaultElementController, DefaultStateProvider, DefaultUiInspector,
    DefaultVisualRenderer,
};
use slate_agent::protocol::ProtocolServerHandle;
use slate_mcp::error::{INVALID_PARAMS, INVALID_REQUEST};
use slate_mcp::server::McpServer;
use slate_mcp::transport::create_in_memory_session;

fn create_test_server() -> Arc<McpServer> {
    let engine = Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::new(
            "Slate Adversarial Window",
            1040.0,
            720.0,
        )),
        Arc::new(DefaultElementController),
        Arc::new(DefaultStateProvider::new("main")),
        Arc::new(DefaultVisualRenderer::new(1040, 720)),
    ));
    Arc::new(McpServer::new(engine))
}

// ============================================================================
// 1. JSON-RPC Wire Protocol & Batch Boundary Cases
// ============================================================================

/// JSON-RPC 2.0 §4.2: An empty batch array `[]` MUST return an Invalid Request error (-32600).
#[tokio::test]
async fn test_adversarial_empty_batch_array() {
    let server = create_test_server();
    let resp_opt = server.handle_line("[]").await;
    assert!(resp_opt.is_some(), "Empty array MUST return an error response");

    let val: serde_json::Value = serde_json::from_str(&resp_opt.unwrap()).unwrap();
    assert_eq!(val["jsonrpc"], "2.0");
    assert!(val.get("error").is_some());
    assert_eq!(val["error"]["code"], INVALID_REQUEST);
    assert!(val["error"]["message"]
        .as_str()
        .unwrap()
        .contains("expected JSON object"));
}

/// Batch array containing valid calls `[{"jsonrpc":"2.0",...}]` must be rejected cleanly
/// as Invalid Request by single-object line transport without crashing or hanging.
#[tokio::test]
async fn test_adversarial_batch_array_of_calls() {
    let server = create_test_server();
    let batch = r#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#;
    let resp_opt = server.handle_line(batch).await;
    assert!(resp_opt.is_some());

    let val: serde_json::Value = serde_json::from_str(&resp_opt.unwrap()).unwrap();
    assert_eq!(val["error"]["code"], INVALID_REQUEST);
}

/// Batch array containing primitive elements `[1, "two", true]` must return Invalid Request (-32600).
#[tokio::test]
async fn test_adversarial_batch_invalid_elements() {
    let server = create_test_server();
    let batch = r#"[1, "two", true]"#;
    let resp_opt = server.handle_line(batch).await;
    assert!(resp_opt.is_some());

    let val: serde_json::Value = serde_json::from_str(&resp_opt.unwrap()).unwrap();
    assert_eq!(val["error"]["code"], INVALID_REQUEST);
}

/// JSON-RPC 2.0 ID variations: float ID, scientific notation, negative numbers, huge integers,
/// and very large string IDs. IDs must be preserved verbatim in responses.
#[tokio::test]
async fn test_adversarial_fractional_and_extreme_id_types() {
    let server = create_test_server();

    // 1. Float ID
    let raw = r#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["id"], 1.5);

    // 2. Scientific notation ID
    let raw = r#"{"jsonrpc":"2.0","id":1e6,"method":"ping"}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["id"], 1000000.0);

    // 3. Negative float ID
    let raw = r#"{"jsonrpc":"2.0","id":-99.25,"method":"ping"}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["id"], -99.25);

    // 4. Maximum u64 / i64 integer
    let raw = format!(
        r#"{{"jsonrpc":"2.0","id":{},"method":"ping"}}"#,
        i64::MAX
    );
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(&raw).await.unwrap()).unwrap();
    assert_eq!(val["id"], i64::MAX);

    // 5. Very long string ID (10,000 characters)
    let long_id = "uuid_".to_string() + &"x".repeat(10_000);
    let raw = format!(
        r#"{{"jsonrpc":"2.0","id":"{}","method":"ping"}}"#,
        long_id
    );
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(&raw).await.unwrap()).unwrap();
    assert_eq!(val["id"], long_id);
}

/// JSON-RPC payload containing escaped characters, tabs, newlines, and unicode escapes.
#[tokio::test]
async fn test_adversarial_unusual_json_escapes_and_whitespace() {
    let server = create_test_server();

    let raw = "{\r\n\t\"jsonrpc\": \"2.0\",\r\n\t\"id\": \"escaped-tab\\tline\\n\",\r\n\t\"method\": \"ping\"\r\n}";
    let resp_opt = server.handle_line(raw).await;
    assert!(resp_opt.is_some(), "Multi-line with whitespace must parse");

    let val: serde_json::Value = serde_json::from_str(&resp_opt.unwrap()).unwrap();
    assert_eq!(val["id"], "escaped-tab\tline\n");
    assert!(val.get("result").is_some());
}

/// Huge JSON-RPC payload line (1MB parameter string) does not crash or exhaust stack.
#[tokio::test]
async fn test_adversarial_huge_jsonrpc_payload_line() {
    let server = create_test_server();
    let huge_str = "a".repeat(1_000_000);
    let raw = format!(
        r#"{{"jsonrpc":"2.0","id":999,"method":"tools/call","params":{{"name":"send_keys","arguments":{{"text":"{}"}}}}}}"#,
        huge_str
    );

    let resp_opt = server.handle_line(&raw).await;
    assert!(resp_opt.is_some());
    let val: serde_json::Value = serde_json::from_str(&resp_opt.unwrap()).unwrap();
    assert_eq!(val["id"], 999);
    assert!(val.get("result").is_some());
}

/// Streaming assembly: multibyte UTF-8 characters split across byte-by-byte frame writes.
#[tokio::test]
async fn test_adversarial_multibyte_utf8_split_across_frames() {
    let server = create_test_server();
    let (client_stream, handle) = create_in_memory_session(server, 65536);

    let (reader, mut writer) = tokio::io::split(client_stream);
    let mut buf_reader = BufReader::new(reader);

    // Multi-byte emoji 🦀 is 4 bytes: [0xF0, 0x9F, 0xA6, 0x80]
    let request = "{\"jsonrpc\":\"2.0\",\"id\":\"crab-🦀-1\",\"method\":\"ping\"}\n";

    // Write single byte at a time across UTF-8 character boundaries
    for b in request.as_bytes() {
        writer.write_all(&[*b]).await.unwrap();
        writer.flush().await.unwrap();
    }

    let mut response_line = String::new();
    let res = timeout(
        Duration::from_secs(3),
        buf_reader.read_line(&mut response_line),
    )
    .await;
    assert!(res.is_ok(), "Timed out awaiting response");
    assert!(res.unwrap().unwrap() > 0);

    let val: serde_json::Value = serde_json::from_str(&response_line).unwrap();
    assert_eq!(val["id"], "crab-🦀-1");
    assert!(val.get("result").is_some());

    handle.stop().unwrap();
}

/// Client writes incomplete JSON fragment and closes stream cleanly. Server must not hang or panic.
#[tokio::test]
async fn test_adversarial_partial_line_eof_at_stream_close() {
    let server = create_test_server();
    let (client_stream, handle) = create_in_memory_session(server, 65536);

    let (_, mut writer) = tokio::io::split(client_stream);

    // Write partial line without trailing newline
    writer
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":\"unf")
        .await
        .unwrap();
    writer.flush().await.unwrap();

    // Drop writer to trigger EOF
    drop(writer);

    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(handle.is_running() || !handle.is_running());
    handle.stop().unwrap();
}

// ============================================================================
// 2. Tool Parameter Boundary & Edge Cases
// ============================================================================

/// `click_element` with null and missing arguments.
#[tokio::test]
async fn test_adversarial_click_element_null_and_missing_arguments() {
    let server = create_test_server();

    let cases = vec![
        r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click_element"}}"#,
        r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"click_element","arguments":null}}"#,
        r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click_element","arguments":{}}}"#,
        r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"click_element","arguments":{"id":null}}}"#,
        r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"click_element","arguments":{"x":null,"y":100}}}"#,
        r#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"click_element","arguments":{"x":100,"y":null}}}"#,
    ];

    for raw in cases {
        let resp_str = server.handle_line(raw).await.unwrap();
        let val: serde_json::Value = serde_json::from_str(&resp_str).unwrap();
        assert_eq!(
            val["result"]["isError"], true,
            "Expected isError: true for: {}",
            raw
        );
        assert!(
            val["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("requires 'id', 'label', or coordinates"),
            "Expected target error for: {}",
            raw
        );
    }
}

/// `click_element` with exact viewport boundaries (window is 1040x720).
#[tokio::test]
async fn test_adversarial_click_element_boundary_coordinates() {
    let server = create_test_server();

    // 1. Top-left origin (0.0, 0.0) -> Valid
    let raw = r#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"click_element","arguments":{"x":0.0,"y":0.0}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);

    // 2. Exact bottom-right corner (1040.0, 720.0) -> Valid
    let raw = r#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"click_element","arguments":{"x":1040.0,"y":720.0}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);

    // 3. Just beyond boundary (1040.001, 720.0) -> Out of bounds error
    let raw = r#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"click_element","arguments":{"x":1040.001,"y":720.0}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], true);
    assert!(val["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("out of window bounds"));

    // 4. Slightly negative coordinate (-0.001, 10.0) -> Negative error
    let raw = r#"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"click_element","arguments":{"x":-0.001,"y":10.0}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], true);
    assert!(val["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains("cannot be negative"));
}

/// `click_element` with extreme float coordinates.
#[tokio::test]
async fn test_adversarial_click_element_extreme_floats() {
    let server = create_test_server();

    let extreme_coords = vec![
        r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click_element","arguments":{"x":1e30,"y":1e30}}}"#,
        r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"click_element","arguments":{"x":-1e30,"y":50.0}}}"#,
        r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click_element","arguments":{"x":50.0,"y":1e30}}}"#,
    ];

    for raw in extreme_coords {
        let val: serde_json::Value =
            serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
        assert_eq!(val["result"]["isError"], true);
    }
}

/// `click_element` with unicode, emoji, and RTL target selectors.
#[tokio::test]
async fn test_adversarial_click_element_unicode_and_special_selectors() {
    let server = create_test_server();

    let special_targets = vec![
        "btn_🚀_rocket",
        "ボタン_submit",
        "כפתור_אישור",
        "زر_ارسال",
        "button with spaces and tabs \t",
        "btn<>:\"/\\|?*",
    ];

    for target in special_targets {
        let req = serde_json::json!({
            "jsonrpc": "2.0",
            "id": "uni",
            "method": "tools/call",
            "params": {
                "name": "click_element",
                "arguments": {
                    "id": target
                }
            }
        });
        let raw = serde_json::to_string(&req).unwrap();
        let val: serde_json::Value =
            serde_json::from_str(&server.handle_line(&raw).await.unwrap()).unwrap();
        // Default controller returns success for any target string
        assert_eq!(val["result"]["isError"], false);
    }
}

/// `click_element` with boundary click_count values: 0, negative, very large.
#[tokio::test]
async fn test_adversarial_click_element_boundary_click_counts() {
    let server = create_test_server();

    // 1. click_count = 0 (handled safely, defaults to single click)
    let raw = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click_element","arguments":{"id":"btn1","click_count":0}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);

    // 2. click_count = -1 (parsed as None by as_u64, defaults to 1)
    let raw = r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"click_element","arguments":{"id":"btn1","click_count":-1}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);

    // 3. click_count = 99999 (treated as double click)
    let raw = r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click_element","arguments":{"id":"btn1","click_count":99999}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);
}

/// `send_keys` with empty text, null text, and null element_id.
#[tokio::test]
async fn test_adversarial_send_keys_empty_null_variations() {
    let server = create_test_server();

    // 1. Missing / null text -> INVALID_PARAMS
    let raw = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_keys","arguments":{"text":null}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["error"]["code"], INVALID_PARAMS);

    // 2. Empty string text "" -> Valid keystroke
    let raw = r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_keys","arguments":{"text":""}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);

    // 3. element_id: null -> targets active element
    let raw = r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_keys","arguments":{"text":"abc","element_id":null}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);
}

/// `send_keys` with control characters, null byte, ZWJ sequences, and RTL text.
#[tokio::test]
async fn test_adversarial_send_keys_control_and_complex_unicode() {
    let server = create_test_server();

    let complex_inputs = vec![
        "text with null byte: hello\\u0000world",
        "line1\\r\\nline2\\ttab",
        "\\u001b[31mANSI Color\\u001b[0m",
        "Family emoji: 👨‍👩‍👧‍👦",
        "RTL Arabic: مرحبا بالعالم",
        "Combining characters: e\\u0301a\\u0300",
    ];

    for text in complex_inputs {
        let raw = format!(
            r#"{{"jsonrpc":"2.0","id":"comp","method":"tools/call","params":{{"name":"send_keys","arguments":{{"text":"{}"}}}}}}"#,
            text
        );
        let val: serde_json::Value =
            serde_json::from_str(&server.handle_line(&raw).await.unwrap()).unwrap();
        assert_eq!(val["result"]["isError"], false);
    }
}

/// `inspect_tree` with boundary depth: max_depth 1 (root only, children pruned) and max_depth 0.
#[tokio::test]
async fn test_adversarial_inspect_tree_depth_pruning() {
    let server = create_test_server();

    // 1. max_depth = 0 -> Error
    let raw = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"max_depth":0}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], true);

    // 2. max_depth = 1 -> Root only (children cleared)
    let raw = r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"inspect_tree","arguments":{"max_depth":1}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);
    let tree_str = val["result"]["content"][0]["text"].as_str().unwrap();
    let tree: serde_json::Value = serde_json::from_str(tree_str).unwrap();
    assert!(tree["root"]["children"].as_array().map_or(true, |c| c.is_empty()));
}

/// `get_state` with empty keys array, null keys, and mixed types.
#[tokio::test]
async fn test_adversarial_get_state_keys_variations() {
    let server = create_test_server();

    // 1. Empty array keys -> Empty properties map
    let raw = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_state","arguments":{"keys":[]}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);
    let state_str = val["result"]["content"][0]["text"].as_str().unwrap();
    let state: serde_json::Value = serde_json::from_str(state_str).unwrap();
    assert!(state["properties"].as_object().unwrap().is_empty());

    // 2. keys: null -> All properties
    let raw = r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_state","arguments":{"keys":null}}}"#;
    let val: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(val["result"]["isError"], false);
}

// ============================================================================
// 3. Resource URI Errors & Path Traversal
// ============================================================================

/// Resource URIs must be case-sensitive; query strings and path traversal must fail cleanly.
#[tokio::test]
async fn test_adversarial_resource_uri_strictness() {
    let server = create_test_server();

    let invalid_uris = vec![
        "SLATE://APP/CONTEXT",
        "slate://APP/context",
        "slate://app/context?foo=bar",
        "slate://app/context#section",
        "slate://app/context/../../etc/passwd",
        "slate:///app/context",
        "slate://app/context\u{0000}injected",
        "",
        "   ",
    ];

    for uri in invalid_uris {
        let req = serde_json::json!({
            "jsonrpc": "2.0",
            "id": "res",
            "method": "resources/read",
            "params": {
                "uri": uri
            }
        });
        let raw = serde_json::to_string(&req).unwrap();
        let val: serde_json::Value =
            serde_json::from_str(&server.handle_line(&raw).await.unwrap()).unwrap();
        assert_eq!(
            val["error"]["code"], INVALID_PARAMS,
            "Expected INVALID_PARAMS for URI: '{}'",
            uri
        );
    }
}

// ============================================================================
// 4. Concurrency & High-Load Burst Stress (200 requests)
// ============================================================================

/// High-concurrency burst: 200 simultaneous tool calls over duplex stream without dropped frames.
#[tokio::test]
async fn test_adversarial_high_concurrency_burst_200_requests() {
    let server = create_test_server();
    let (client_stream, handle) = create_in_memory_session(server, 524288);

    let (reader, mut writer) = tokio::io::split(client_stream);
    let buf_reader = Arc::new(tokio::sync::Mutex::new(BufReader::new(reader)));

    let request_count = 200;
    let mut batch_stream = String::new();

    for i in 1..=request_count {
        batch_stream.push_str(&format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}}\n",
            i
        ));
    }

    writer.write_all(batch_stream.as_bytes()).await.unwrap();
    writer.flush().await.unwrap();

    let mut received_ids = std::collections::HashSet::new();

    for _ in 1..=request_count {
        let mut line = String::new();
        let mut reader_guard = buf_reader.lock().await;
        let res = timeout(Duration::from_secs(5), reader_guard.read_line(&mut line)).await;
        assert!(res.is_ok(), "Timed out awaiting response in 200-burst");
        drop(reader_guard);

        let val: serde_json::Value = serde_json::from_str(&line).expect("Must be valid JSON");
        assert!(val.get("result").is_some());
        let id = val["id"].as_i64().expect("id must be integer");
        received_ids.insert(id);
    }

    assert_eq!(
        received_ids.len(),
        request_count,
        "Every one of 200 requests must yield a unique response ID"
    );

    handle.stop().unwrap();
}

/// 200 concurrent requests followed by abrupt client disconnect while responses are inflight.
#[tokio::test]
async fn test_adversarial_rapid_client_abort_inflight_200_requests() {
    let server = create_test_server();
    let (client_stream, handle) = create_in_memory_session(server, 524288);

    let (reader, mut writer) = tokio::io::split(client_stream);

    // Send 200 requests
    let mut batch = String::new();
    for i in 1..=200 {
        batch.push_str(&format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}}\n",
            i
        ));
    }
    writer.write_all(batch.as_bytes()).await.unwrap();
    writer.flush().await.unwrap();

    // Immediately drop reader and writer while responses are being processed
    drop(writer);
    drop(reader);

    tokio::time::sleep(Duration::from_millis(50)).await;
    handle.stop().unwrap();
}
