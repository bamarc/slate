//! Adversarial Stress and Protocol Conformance Tests for `slate-mcp`.
//!
//! Validates:
//! 1. Malformed JSON inputs (truncated JSON, non-JSON strings, missing quotes, non-object JSON).
//! 2. Protocol violations (missing jsonrpc, wrong jsonrpc version, missing method, non-string method, unknown methods).
//! 3. ID variations and notification semantics (omitted id -> no response, null id -> response with id: null).
//! 4. Tool parameter violations (missing required params, invalid types, extreme coordinates).
//! 5. Resource URI errors (missing uri, invalid types, unknown uri, malformed uri).
//! 6. Line framing edge cases (CRLF vs LF, blank lines, whitespace, burst batches, single-byte writes).
//! 7. Adherence to JSON-RPC 2.0 error codes (-32700, -32600, -32601, -32602, -32603) and panic immunity.

use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::time::timeout;

use slate_agent::engine::{
    DefaultAutomationEngine, DefaultElementController, DefaultStateProvider, DefaultUiInspector,
    DefaultVisualRenderer,
};
use slate_agent::protocol::ProtocolServerHandle;
use slate_mcp::error::{INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND, PARSE_ERROR};
use slate_mcp::server::{JsonRpcResponse, McpServer};
use slate_mcp::transport::create_in_memory_session;

fn create_test_server() -> Arc<McpServer> {
    let engine = Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::new(
            "Slate Adversarial App",
            1024.0,
            768.0,
        )),
        Arc::new(DefaultElementController),
        Arc::new(DefaultStateProvider::new("main")),
        Arc::new(DefaultVisualRenderer::new(1024, 768)),
    ));
    Arc::new(McpServer::new(engine))
}

// ============================================================================
// 1. Malformed JSON Tests
// ============================================================================

#[tokio::test]
async fn test_adversarial_malformed_json_variants() {
    let server = create_test_server();

    let malformed_inputs = vec![
        "{",
        "{\"jsonrpc\":",
        "{\"jsonrpc\": \"2.0\", \"method\":",
        "{\"id\": 1, \"method\": \"ping\", \"params\": [}",
        "{jsonrpc: \"2.0\", id: 1}",
        "['unclosed array'",
        "\"unclosed string",
        "random non-json garbage string",
        "GET /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "{\"jsonrpc\": \"2.0\", \"id\": 1} trailing garbage",
    ];

    for input in malformed_inputs {
        let resp_opt = server.handle_line(input).await;
        assert!(
            resp_opt.is_some(),
            "Expected error response for malformed input: '{}'",
            input
        );
        let resp_str = resp_opt.unwrap();
        let val: serde_json::Value =
            serde_json::from_str(&resp_str).expect("Response must be valid JSON");

        assert_eq!(val["jsonrpc"], "2.0");
        assert!(
            val.get("error").is_some(),
            "Expected error object for input: '{}'",
            input
        );
        assert_eq!(
            val["error"]["code"], PARSE_ERROR,
            "Expected code -32700 for input: '{}'",
            input
        );
    }
}

#[tokio::test]
async fn test_adversarial_non_object_json_primitives() {
    let server = create_test_server();

    let non_objects = vec![
        "[1, 2, 3]",
        "\"just a string\"",
        "42",
        "-99.5",
        "true",
        "false",
        "null",
    ];

    for input in non_objects {
        let resp_opt = server.handle_line(input).await;
        assert!(
            resp_opt.is_some(),
            "Expected error response for non-object: '{}'",
            input
        );
        let resp_str = resp_opt.unwrap();
        let val: serde_json::Value =
            serde_json::from_str(&resp_str).expect("Response must be valid JSON");

        assert_eq!(val["jsonrpc"], "2.0");
        assert!(val.get("error").is_some());
        assert_eq!(
            val["error"]["code"], INVALID_REQUEST,
            "Expected code -32600 for non-object: '{}'",
            input
        );
        assert!(
            val["error"]["message"]
                .as_str()
                .unwrap()
                .contains("expected JSON object"),
            "Error message should mention 'expected JSON object' for: '{}'",
            input
        );
    }
}

// ============================================================================
// 2. Protocol Violations: jsonrpc version & method
// ============================================================================

#[tokio::test]
async fn test_adversarial_jsonrpc_version_violations() {
    let server = create_test_server();

    let invalid_version_requests = vec![
        // Missing jsonrpc
        r#"{"id": 1, "method": "ping"}"#,
        // Wrong version strings
        r#"{"jsonrpc": "1.0", "id": 2, "method": "ping"}"#,
        r#"{"jsonrpc": "2.1", "id": 3, "method": "ping"}"#,
        r#"{"jsonrpc": "3.0", "id": 4, "method": "ping"}"#,
        r#"{"jsonrpc": "", "id": 5, "method": "ping"}"#,
        // Non-string jsonrpc types
        r#"{"jsonrpc": 2.0, "id": 6, "method": "ping"}"#,
        r#"{"jsonrpc": 2, "id": 7, "method": "ping"}"#,
        r#"{"jsonrpc": true, "id": 8, "method": "ping"}"#,
        r#"{"jsonrpc": null, "id": 9, "method": "ping"}"#,
        r#"{"jsonrpc": [], "id": 10, "method": "ping"}"#,
        r#"{"jsonrpc": {}, "id": 11, "method": "ping"}"#,
    ];

    for raw in invalid_version_requests {
        let resp_opt = server.handle_line(raw).await;
        assert!(resp_opt.is_some(), "Expected error for: {}", raw);
        let resp_str = resp_opt.unwrap();
        let val: serde_json::Value = serde_json::from_str(&resp_str).unwrap();

        assert_eq!(val["jsonrpc"], "2.0");
        assert_eq!(
            val["error"]["code"], INVALID_REQUEST,
            "Expected code -32600 for: {}",
            raw
        );
        assert!(
            val["error"]["message"]
                .as_str()
                .unwrap()
                .contains("jsonrpc"),
            "Error message should mention 'jsonrpc' for: {}",
            raw
        );
    }
}

#[tokio::test]
async fn test_adversarial_method_field_violations() {
    let server = create_test_server();

    // 1. Missing method
    let missing_method = r#"{"jsonrpc": "2.0", "id": 10}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(missing_method).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], INVALID_REQUEST);
    assert_eq!(resp["id"], 10);

    // 2. Non-string method types
    let non_string_methods = vec![
        r#"{"jsonrpc": "2.0", "id": 11, "method": 123}"#,
        r#"{"jsonrpc": "2.0", "id": 12, "method": true}"#,
        r#"{"jsonrpc": "2.0", "id": 13, "method": null}"#,
        r#"{"jsonrpc": "2.0", "id": 14, "method": ["ping"]}"#,
        r#"{"jsonrpc": "2.0", "id": 15, "method": {"name": "ping"}}"#,
    ];
    for raw in non_string_methods {
        let resp: serde_json::Value =
            serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
        assert_eq!(
            resp["error"]["code"], INVALID_REQUEST,
            "Expected -32600 for non-string method in: {}",
            raw
        );
    }

    // 3. Unknown method names
    let unknown_methods = vec![
        r#"{"jsonrpc": "2.0", "id": 20, "method": "system/shutdown"}"#,
        r#"{"jsonrpc": "2.0", "id": 21, "method": "rpc.unknown"}"#,
        r#"{"jsonrpc": "2.0", "id": 22, "method": "tools/nonexistent"}"#,
        r#"{"jsonrpc": "2.0", "id": 23, "method": ""}"#,
        r#"{"jsonrpc": "2.0", "id": 24, "method": "null"}"#,
    ];
    for raw in unknown_methods {
        let resp: serde_json::Value =
            serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
        assert_eq!(
            resp["error"]["code"], METHOD_NOT_FOUND,
            "Expected -32601 for unknown method: {}",
            raw
        );
    }
}

// ============================================================================
// 3. ID Variations & Notification Semantics
// ============================================================================

#[tokio::test]
async fn test_adversarial_id_variations() {
    let server = create_test_server();

    // 1. Integer ID
    let raw = r#"{"jsonrpc": "2.0", "id": 42, "method": "ping"}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["id"], 42);
    assert!(resp.get("result").is_some());

    // 2. Negative integer ID
    let raw = r#"{"jsonrpc": "2.0", "id": -100, "method": "ping"}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["id"], -100);

    // 3. String ID
    let raw = r#"{"jsonrpc": "2.0", "id": "req-uuid-98765", "method": "ping"}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["id"], "req-uuid-98765");

    // 4. Null ID (JSON-RPC 2.0 allows null id for request)
    let raw = r#"{"jsonrpc": "2.0", "id": null, "method": "ping"}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert!(resp["id"].is_null());
    assert!(resp.get("result").is_some());

    // 5. Preserved ID on error
    let raw = r#"{"jsonrpc": "2.0", "id": "err-test-42", "method": "unknown_method"}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["id"], "err-test-42");
    assert_eq!(resp["error"]["code"], METHOD_NOT_FOUND);
}

#[tokio::test]
async fn test_adversarial_notification_semantics() {
    let server = create_test_server();

    // Notifications MUST NOT generate wire responses
    let notifications = vec![
        r#"{"jsonrpc": "2.0", "method": "notifications/initialized"}"#,
        r#"{"jsonrpc": "2.0", "method": "custom/notification", "params": {"foo": "bar"}}"#,
        r#"{"jsonrpc": "2.0", "method": "nonexistent_notification"}"#,
        r#"{"jsonrpc": "2.0", "method": "tools/call", "params": {}}"#, // Invalid params notification -> NO response
    ];

    for raw in notifications {
        let resp = server.handle_line(raw).await;
        assert!(
            resp.is_none(),
            "Notification MUST NOT generate response: {}",
            raw
        );
    }
}

// ============================================================================
// 4. Tool Parameter Violations
// ============================================================================

#[tokio::test]
async fn test_adversarial_tools_call_structure() {
    let server = create_test_server();

    // 1. Missing params in tools/call
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "tools/call"}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], INVALID_PARAMS);

    // 2. Non-object params (string, array, number)
    let bad_params = vec![
        r#"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": "get_state"}"#,
        r#"{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [1, 2]}"#,
        r#"{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": 42}"#,
    ];
    for raw in bad_params {
        let resp: serde_json::Value =
            serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
        assert_eq!(resp["error"]["code"], INVALID_PARAMS);
    }

    // 3. Missing 'name' in tools/call params
    let raw = r#"{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], INVALID_PARAMS);

    // 4. Non-string 'name' in tools/call params
    let raw = r#"{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": 12345}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], INVALID_PARAMS);

    // 5. Unknown tool name
    let raw =
        r#"{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "ghost_tool"}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], METHOD_NOT_FOUND);
}

#[tokio::test]
async fn test_adversarial_send_keys_parameters() {
    let server = create_test_server();

    // 1. Missing required 'text' parameter
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "send_keys", "arguments": {}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], INVALID_PARAMS);
    assert!(resp["error"]["message"].as_str().unwrap().contains("text"));

    // 2. Non-string 'text' parameter (integer, boolean, null, object, array)
    let bad_texts = vec![
        r#"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": 123}}}"#,
        r#"{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": true}}}"#,
        r#"{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": null}}}"#,
        r#"{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": []}}}"#,
        r#"{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": {}}}}"#,
    ];
    for raw in bad_texts {
        let resp: serde_json::Value =
            serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
        assert_eq!(
            resp["error"]["code"], INVALID_PARAMS,
            "Expected INVALID_PARAMS for bad text type: {}",
            raw
        );
    }

    // 3. Non-string element_id falls back gracefully without panic
    let raw = r#"{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "send_keys", "arguments": {"text": "hello", "element_id": 999}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert!(resp.get("result").is_some());

    // 4. Large text payload does not panic or crash
    let large_text = "A".repeat(20_000);
    let raw = format!(
        r#"{{"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {{"name": "send_keys", "arguments": {{"text": "{}"}}}}}}"#,
        large_text
    );
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(&raw).await.unwrap()).unwrap();
    assert!(resp.get("result").is_some());
}

#[tokio::test]
async fn test_adversarial_click_element_parameters() {
    let server = create_test_server();

    // 1. Missing target (no id, label, or coords)
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "click_element", "arguments": {}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    let result = &resp["result"];
    assert_eq!(result["isError"], true);
    assert!(
        result["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("requires 'id', 'label', or coordinates")
    );

    // 2. Negative coordinates
    let raw = r#"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "click_element", "arguments": {"x": -10.0, "y": 50.0}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["result"]["isError"], true);
    assert!(
        resp["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("cannot be negative")
    );

    // 3. Out-of-bounds coordinates (viewport is 1024x768)
    let raw = r#"{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "click_element", "arguments": {"x": 2000.0, "y": 500.0}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["result"]["isError"], true);
    assert!(
        resp["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("out of window bounds")
    );

    // 4. Invalid coord types (strings instead of numbers)
    let raw = r#"{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "click_element", "arguments": {"x": "not_a_num", "y": "NaN"}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["result"]["isError"], true);

    // 5. Invalid mouse button string defaults safely to Left
    let raw = r#"{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "click_element", "arguments": {"x": 100.0, "y": 100.0, "button": "unknown_button"}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["result"]["isError"], false);
}

#[tokio::test]
async fn test_adversarial_inspect_tree_parameters() {
    let server = create_test_server();

    // 1. max_depth == 0 must return error
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "inspect_tree", "arguments": {"max_depth": 0}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["result"]["isError"], true);
    assert!(
        resp["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("max_depth must be >= 1")
    );

    // 2. Non-existent root_id
    let raw = r#"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "inspect_tree", "arguments": {"root_id": "ghost_root_123"}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["result"]["isError"], true);
    assert!(
        resp["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("not found")
    );

    // 3. Negative max_depth is handled gracefully (as_u64 fails -> defaults to unpruned)
    let raw = r#"{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "inspect_tree", "arguments": {"max_depth": -1}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["result"]["isError"], false);
}

#[tokio::test]
async fn test_adversarial_get_state_parameters() {
    let server = create_test_server();

    // 1. Non-array keys argument is ignored gracefully
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_state", "arguments": {"keys": "not_an_array"}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["result"]["isError"], false);

    // 2. Array with mixed non-string types
    let raw = r#"{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "get_state", "arguments": {"keys": [1, null, true, "valid_key"]}}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["result"]["isError"], false);
}

// ============================================================================
// 5. Resource URI Errors
// ============================================================================

#[tokio::test]
async fn test_adversarial_resource_uri_errors() {
    let server = create_test_server();

    // 1. Missing params in resources/read
    let raw = r#"{"jsonrpc": "2.0", "id": 1, "method": "resources/read"}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], INVALID_PARAMS);

    // 2. Missing 'uri' field in params
    let raw = r#"{"jsonrpc": "2.0", "id": 2, "method": "resources/read", "params": {}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], INVALID_PARAMS);

    // 3. Non-string 'uri'
    let raw = r#"{"jsonrpc": "2.0", "id": 3, "method": "resources/read", "params": {"uri": 999}}"#;
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], INVALID_PARAMS);

    // 4. Unknown URI scheme or path
    let unknown_uris = vec![
        r#"{"jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": {"uri": "slate://unknown/resource"}}"#,
        r#"{"jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": {"uri": "http://evil.com/logs"}}"#,
        r#"{"jsonrpc": "2.0", "id": 6, "method": "resources/read", "params": {"uri": "file:///etc/passwd"}}"#,
        r#"{"jsonrpc": "2.0", "id": 7, "method": "resources/read", "params": {"uri": ""}}"#,
    ];
    for raw in unknown_uris {
        let resp: serde_json::Value =
            serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
        assert_eq!(
            resp["error"]["code"], INVALID_PARAMS,
            "Expected INVALID_PARAMS (-32602) for bad URI: {}",
            raw
        );
        assert!(
            resp["error"]["message"]
                .as_str()
                .unwrap()
                .contains("not found"),
            "Error message should mention 'not found' for: {}",
            raw
        );
    }
}

// ============================================================================
// 6. Line Framing, Streaming & Concurrency Stress
// ============================================================================

#[tokio::test]
async fn test_adversarial_line_framing_crlf_lf_whitespace() {
    let server = create_test_server();
    let (client_stream, handle) = create_in_memory_session(server, 65536);

    let (reader, mut writer) = tokio::io::split(client_stream);
    let mut buf_reader = BufReader::new(reader);

    // Complex framing mix:
    // 1. CRLF line
    // 2. Multiple empty lines and blank spaces
    // 3. Tab-indented LF line
    // 4. Line with trailing whitespace and CRLF
    // 5. Valid request terminated with LF
    let mixed_payload = concat!(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n",
        "\r\n\r\n   \t  \r\n\n\n",
        "\t  {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}   \t  \r\n",
        "\n\n\n",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}\n"
    );

    writer.write_all(mixed_payload.as_bytes()).await.unwrap();
    writer.flush().await.unwrap();

    for expected_id in 1..=4 {
        let mut line = String::new();
        let read_result = timeout(Duration::from_secs(2), buf_reader.read_line(&mut line)).await;
        assert!(
            read_result.is_ok(),
            "Timed out waiting for id {}",
            expected_id
        );
        assert!(read_result.unwrap().unwrap() > 0, "EOF reached prematurely");

        let resp: JsonRpcResponse = serde_json::from_str(&line).unwrap();
        assert_eq!(resp.id, Some(serde_json::json!(expected_id)));
        assert!(resp.result.is_some());
    }

    handle.stop().unwrap();
}

#[tokio::test]
async fn test_adversarial_slow_drip_single_byte_writes() {
    let server = create_test_server();
    let (client_stream, handle) = create_in_memory_session(server, 65536);

    let (reader, mut writer) = tokio::io::split(client_stream);
    let mut buf_reader = BufReader::new(reader);

    let request = "{\"jsonrpc\":\"2.0\",\"id\":\"drip-1\",\"method\":\"ping\"}\n";

    // Write single byte at a time to test streaming framing assembly
    for byte in request.as_bytes() {
        writer.write_all(&[*byte]).await.unwrap();
        writer.flush().await.unwrap();
        tokio::time::sleep(Duration::from_millis(1)).await;
    }

    let mut response_line = String::new();
    let read_result = timeout(
        Duration::from_secs(3),
        buf_reader.read_line(&mut response_line),
    )
    .await;
    assert!(
        read_result.is_ok(),
        "Timed out waiting for slow drip response"
    );
    assert!(read_result.unwrap().unwrap() > 0);

    let resp: JsonRpcResponse = serde_json::from_str(&response_line).unwrap();
    assert_eq!(resp.id, Some(serde_json::json!("drip-1")));
    assert!(resp.result.is_some());

    handle.stop().unwrap();
}

#[tokio::test]
async fn test_adversarial_burst_batch_interleaved_valid_and_invalid() {
    let server = create_test_server();
    let (client_stream, handle) = create_in_memory_session(server, 262144);

    let (reader, mut writer) = tokio::io::split(client_stream);
    let buf_reader = Arc::new(tokio::sync::Mutex::new(BufReader::new(reader)));

    // Send a burst of 60 interleaved requests:
    // - 20 valid ping requests (ids: 100..120)
    // - 20 parse errors (malformed syntax)
    // - 20 invalid request errors (missing version, ids: 200..220)
    // - sprinkled with empty lines
    let mut combined_stream = String::new();
    for i in 0..20 {
        combined_stream.push_str(&format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}}\n",
            100 + i
        ));
        combined_stream.push_str("\n\r\n");
        combined_stream.push_str(&format!("{{malformed_json_without_quotes_{}}}\n", i));
        combined_stream.push_str(&format!("{{\"id\":{},\"method\":\"ping\"}}\n", 200 + i)); // missing jsonrpc
    }

    writer.write_all(combined_stream.as_bytes()).await.unwrap();
    writer.flush().await.unwrap();

    // Expect exactly 60 responses:
    // 20 successes with ids 100..120
    // 20 parse errors (-32700)
    // 20 invalid request errors (-32600) with ids 200..220
    let mut success_ids = std::collections::HashSet::new();
    let mut parse_error_count = 0;
    let mut invalid_req_ids = std::collections::HashSet::new();

    for _ in 0..60 {
        let mut line = String::new();
        let mut reader_guard = buf_reader.lock().await;
        let res = timeout(Duration::from_secs(3), reader_guard.read_line(&mut line)).await;
        assert!(res.is_ok(), "Timed out waiting for response in burst");
        drop(reader_guard);

        let val: serde_json::Value =
            serde_json::from_str(&line).expect("Response must be valid JSON");
        if val.get("result").is_some() {
            let id = val["id"].as_i64().unwrap();
            success_ids.insert(id);
        } else if let Some(err) = val.get("error") {
            let code = err["code"].as_i64().unwrap();
            if code == PARSE_ERROR {
                parse_error_count += 1;
            } else if code == INVALID_REQUEST {
                let id = val["id"].as_i64().unwrap();
                invalid_req_ids.insert(id);
            }
        }
    }

    assert_eq!(
        success_ids.len(),
        20,
        "Should have 20 successful ping responses"
    );
    assert_eq!(parse_error_count, 20, "Should have 20 parse errors");
    assert_eq!(
        invalid_req_ids.len(),
        20,
        "Should have 20 invalid request errors with preserved IDs"
    );

    handle.stop().unwrap();
}

// ============================================================================
// 7. Extreme Payload & Deep Nesting
// ============================================================================

#[tokio::test]
async fn test_adversarial_deeply_nested_brackets_no_stack_overflow() {
    let server = create_test_server();

    // Deeply nested brackets (100 levels)
    let mut nested = String::new();
    for _ in 0..100 {
        nested.push('[');
    }
    for _ in 0..100 {
        nested.push(']');
    }

    let resp_opt = server.handle_line(&nested).await;
    assert!(resp_opt.is_some());
    let resp: serde_json::Value = serde_json::from_str(&resp_opt.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], INVALID_REQUEST);
}

#[tokio::test]
async fn test_adversarial_null_byte_in_method_name() {
    let server = create_test_server();
    let raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\\u0000injected\"}";
    let resp: serde_json::Value =
        serde_json::from_str(&server.handle_line(raw).await.unwrap()).unwrap();
    assert_eq!(resp["error"]["code"], METHOD_NOT_FOUND);
}
