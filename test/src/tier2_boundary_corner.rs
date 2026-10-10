use crate::harness::create_test_session;
use crate::types::*;
use std::sync::Arc;

// ============================================================================
// Tier 2: Boundary, Corner & Adversarial Edge Cases
// ============================================================================

pub async fn run_test_tier2_malformed_json_syntax() {
    let (client, _engine, _handle) = create_test_session();
    let raw_resp = client.raw_json_rpc("{malformed: json, missing quotes").await.expect("raw call failed");

    let val: serde_json::Value = serde_json::from_str(&raw_resp).expect("response is not valid json");
    assert_eq!(val["jsonrpc"], "2.0");
    assert_eq!(val["error"]["code"], PARSE_ERROR);
    assert!(val["error"]["message"].as_str().unwrap().contains("Parse error"));
}

#[tokio::test]
async fn test_tier2_malformed_json_syntax() {
    run_test_tier2_malformed_json_syntax().await;
}

pub async fn run_test_tier2_invalid_request_structure() {
    let (client, _engine, _handle) = create_test_session();
    let raw_resp = client.raw_json_rpc(r#"{"version": "1.0", "call": "test"}"#).await.expect("raw call failed");

    let val: serde_json::Value = serde_json::from_str(&raw_resp).expect("response is not valid json");
    assert_eq!(val["error"]["code"], INVALID_REQUEST);
}

#[tokio::test]
async fn test_tier2_invalid_request_structure() {
    run_test_tier2_invalid_request_structure().await;
}

pub async fn run_test_tier2_unknown_jsonrpc_method() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let resp = client.request("system/shutdown", None).await.expect("request failed");
    assert!(resp.error.is_some());
    let err = resp.error.unwrap();
    assert_eq!(err.code, METHOD_NOT_FOUND);
    assert!(err.message.contains("Method 'system/shutdown' not found"));
}

#[tokio::test]
async fn test_tier2_unknown_jsonrpc_method() {
    run_test_tier2_unknown_jsonrpc_method().await;
}

pub async fn run_test_tier2_unknown_mcp_tool() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let resp = client.request("tools/call", Some(serde_json::json!({
        "name": "non_existent_fake_tool",
        "arguments": {}
    }))).await.expect("request failed");

    assert!(resp.error.is_some());
    let err = resp.error.unwrap();
    assert_eq!(err.code, METHOD_NOT_FOUND);
    assert!(err.message.contains("not found"));
}

#[tokio::test]
async fn test_tier2_unknown_mcp_tool() {
    run_test_tier2_unknown_mcp_tool().await;
}

pub async fn run_test_tier2_send_keys_missing_text_param() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let resp = client.request("tools/call", Some(serde_json::json!({
        "name": "send_keys",
        "arguments": { "element_id": "email_input" }
    }))).await.expect("request failed");

    assert!(resp.error.is_some());
    let err = resp.error.unwrap();
    assert_eq!(err.code, INVALID_PARAMS);
    assert!(err.message.contains("Missing required argument 'text'"));
}

#[tokio::test]
async fn test_tier2_send_keys_missing_text_param() {
    run_test_tier2_send_keys_missing_text_param().await;
}

pub async fn run_test_tier2_click_element_missing_target() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client.click_element(serde_json::json!({})).await;
    assert!(res.is_err());
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("requires 'id', 'label', or coordinates"));
}

#[tokio::test]
async fn test_tier2_click_element_missing_target() {
    run_test_tier2_click_element_missing_target().await;
}

pub async fn run_test_tier2_click_element_negative_coordinates() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client.click_element(serde_json::json!({ "x": -50.0, "y": -10.0 })).await;
    assert!(res.is_err());
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("cannot be negative"));
}

#[tokio::test]
async fn test_tier2_click_element_negative_coordinates() {
    run_test_tier2_click_element_negative_coordinates().await;
}

pub async fn run_test_tier2_click_element_extreme_out_of_bounds_coords() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client.click_element(serde_json::json!({ "x": 99999.0, "y": 99999.0 })).await;
    assert!(res.is_err());
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("out of window bounds"));
}

#[tokio::test]
async fn test_tier2_click_element_extreme_out_of_bounds_coords() {
    run_test_tier2_click_element_extreme_out_of_bounds_coords().await;
}

pub async fn run_test_tier2_click_element_nonexistent_id() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client.click_element(serde_json::json!({ "id": "unknown_ghost_element_123" })).await;
    assert!(res.is_err());
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("not found or not clickable"));
}

#[tokio::test]
async fn test_tier2_click_element_nonexistent_id() {
    run_test_tier2_click_element_nonexistent_id().await;
}

pub async fn run_test_tier2_send_keys_to_non_editable_element() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client.send_keys("hello", Some("header_bar"), false).await;
    assert!(res.is_err());
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("not an editable text input"));
}

#[tokio::test]
async fn test_tier2_send_keys_to_non_editable_element() {
    run_test_tier2_send_keys_to_non_editable_element().await;
}

pub async fn run_test_tier2_inspect_tree_invalid_depth_zero() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client.inspect_tree(None, Some(0)).await;
    assert!(res.is_err());
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("max_depth must be >= 1"));
}

#[tokio::test]
async fn test_tier2_inspect_tree_invalid_depth_zero() {
    run_test_tier2_inspect_tree_invalid_depth_zero().await;
}

pub async fn run_test_tier2_inspect_tree_nonexistent_root() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client.inspect_tree(Some("non_existent_root_node"), None).await;
    assert!(res.is_err());
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("not found"));
}

#[tokio::test]
async fn test_tier2_inspect_tree_nonexistent_root() {
    run_test_tier2_inspect_tree_nonexistent_root().await;
}

pub async fn run_test_tier2_resource_read_invalid_uri() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client.read_resource("slate://invalid/resource/uri").await;
    assert!(res.is_err());
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("not found"));
}

#[tokio::test]
async fn test_tier2_resource_read_invalid_uri() {
    run_test_tier2_resource_read_invalid_uri().await;
}

pub async fn run_test_tier2_acp_unknown_action() {
    let (_client, engine, _handle) = create_test_session();

    let msg = AcpMessage {
        message_id: "acp-err-1".to_string(),
        performative: AcpPerformative::Request,
        action: "unknown_custom_action".to_string(),
        sender: "test-client".to_string(),
        payload: serde_json::json!({}),
    };

    let resp = engine.dispatch_acp(msg).await.expect("dispatch_acp call failed");
    assert!(!resp.success);
    assert!(resp.error.is_some());
    assert!(resp.error.unwrap().contains("Unknown ACP action"));
}

#[tokio::test]
async fn test_tier2_acp_unknown_action() {
    run_test_tier2_acp_unknown_action().await;
}

pub async fn run_test_tier2_concurrent_burst_requests() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let client_arc = Arc::new(client);
    let mut handles = Vec::new();

    // Spawn 50 simultaneous asynchronous requests over the single duplex stream
    for _ in 0..50 {
        let cl = client_arc.clone();
        handles.push(tokio::spawn(async move {
            cl.click_element(serde_json::json!({ "id": "increment_counter_btn" })).await
        }));
    }

    for h in handles {
        let res = h.await.expect("tokio task panicked");
        assert!(res.is_ok(), "Request in burst failed: {:?}", res);
    }

    let final_count = engine.counter.load(std::sync::atomic::Ordering::SeqCst);
    assert_eq!(final_count, 50);
}

#[tokio::test]
async fn test_tier2_concurrent_burst_requests() {
    run_test_tier2_concurrent_burst_requests().await;
}
