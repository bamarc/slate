use crate::harness::create_test_session;
use crate::types::*;

// ============================================================================
// Tier 3: Cross-Feature Interactions
// ============================================================================

pub async fn run_test_tier3_inspect_click_verify_state() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Inspect tree to find increment button
    let tree = client.inspect_tree(None, None).await.expect("inspect_tree failed");
    let btn = tree.root.find_by_id("increment_counter_btn").expect("Button not found in tree");
    let target_id = btn.id.as_ref().unwrap();

    // 2. Query initial state
    let state_before = client.get_state(Some(vec!["counter"])).await.expect("get_state failed");
    let count_before = state_before.properties["counter"].as_i64().unwrap();

    // 3. Click discovered element
    let click_res = client
        .click_element(serde_json::json!({ "id": target_id }))
        .await
        .expect("click_element failed");
    assert!(click_res.success);

    // 4. Verify updated state reflects increment
    let state_after = client.get_state(Some(vec!["counter"])).await.expect("get_state failed");
    let count_after = state_after.properties["counter"].as_i64().unwrap();
    assert_eq!(count_after, count_before + 1);
}

#[tokio::test]
async fn test_tier3_inspect_click_verify_state() {
    run_test_tier3_inspect_click_verify_state().await;
}

pub async fn run_test_tier3_inspect_send_keys_verify_state() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Inspect tree to locate email input
    let tree = client.inspect_tree(None, None).await.expect("inspect_tree failed");
    let input = tree.root.find_by_id("email_input").expect("email_input not in tree");
    assert_eq!(input.role.as_deref(), Some("textbox"));

    // 2. Send keys to typed text field
    let typed_email = "agent-qa@automation.internal";
    let res = client
        .send_keys(typed_email, Some("email_input"), true)
        .await
        .expect("send_keys failed");
    assert!(res.success);

    // 3. Verify get_state reflects typed value
    let state = client.get_state(Some(vec!["demo_input_text"])).await.expect("get_state failed");
    assert_eq!(state.properties["demo_input_text"], typed_email);
}

#[tokio::test]
async fn test_tier3_inspect_send_keys_verify_state() {
    run_test_tier3_inspect_send_keys_verify_state().await;
}

pub async fn run_test_tier3_send_keys_then_click_action() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Type input
    client.send_keys("custom_run_parameters", Some("email_input"), true).await.unwrap();

    // 2. Click increment button to trigger action
    let click_res = client
        .click_element(serde_json::json!({ "id": "increment_counter_btn" }))
        .await
        .unwrap();
    assert!(click_res.success);

    // 3. Verify both state properties updated concurrently
    let state = client.get_state(Some(vec!["demo_input_text", "counter"])).await.unwrap();
    assert_eq!(state.properties["demo_input_text"], "custom_run_parameters");
    assert_eq!(state.properties["counter"], 1);
}

#[tokio::test]
async fn test_tier3_send_keys_then_click_action() {
    run_test_tier3_send_keys_then_click_action().await;
}

pub async fn run_test_tier3_inspect_bounds_coordinate_click() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Inspect tree to retrieve geometric bounding rectangle
    let tree = client.inspect_tree(None, None).await.expect("inspect_tree failed");
    let btn = tree.root.find_by_id("increment_counter_btn").unwrap();
    let (cx, cy) = btn.bounds.center();

    // 2. Dispatch click directly to center coordinates
    let click_res = client
        .click_element(serde_json::json!({ "x": cx, "y": cy }))
        .await
        .expect("coordinate click failed");
    assert!(click_res.success);

    // 3. Verify state counter changed
    let state = client.get_state(Some(vec!["counter"])).await.unwrap();
    assert_eq!(state.properties["counter"], 1);
}

#[tokio::test]
async fn test_tier3_inspect_bounds_coordinate_click() {
    run_test_tier3_inspect_bounds_coordinate_click().await;
}

pub async fn run_test_tier3_click_theme_toggle_and_capture_screenshot() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Click theme toggle button
    let click_res = client
        .click_element(serde_json::json!({ "id": "theme_toggle_btn" }))
        .await
        .unwrap();
    assert!(click_res.success);

    // 2. Verify state toggled to dark
    let state = client.get_state(Some(vec!["is_dark"])).await.unwrap();
    assert_eq!(state.properties["is_dark"], true);

    // 3. Capture screenshot of dark theme frame
    let screenshot = client.get_screenshot(None).await.expect("screenshot failed");
    assert!(screenshot.is_valid_png());
    assert_eq!(screenshot.width, 1040);
    assert_eq!(screenshot.height, 720);
}

#[tokio::test]
async fn test_tier3_click_theme_toggle_and_capture_screenshot() {
    run_test_tier3_click_theme_toggle_and_capture_screenshot().await;
}

pub async fn run_test_tier3_send_keys_overwrite_fidelity() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Set initial text
    client.send_keys("first_long_initial_value_string", Some("email_input"), true).await.unwrap();
    let state1 = client.get_state(Some(vec!["demo_input_text"])).await.unwrap();
    assert_eq!(state1.properties["demo_input_text"], "first_long_initial_value_string");

    // 2. Clear and overwrite with shorter text
    client.send_keys("short", Some("email_input"), true).await.unwrap();
    let state2 = client.get_state(Some(vec!["demo_input_text"])).await.unwrap();
    assert_eq!(state2.properties["demo_input_text"], "short");
}

#[tokio::test]
async fn test_tier3_send_keys_overwrite_fidelity() {
    run_test_tier3_send_keys_overwrite_fidelity().await;
}

pub async fn run_test_tier3_resource_read_after_agent_actions() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Read initial logs
    let logs_before = client.read_resource("slate://logs/live").await.unwrap();
    let log_text_before = logs_before.text.unwrap();

    // 2. Execute multiple agent actions
    client.click_element(serde_json::json!({ "id": "theme_toggle_btn" })).await.unwrap();
    client.send_keys("user@test.org", Some("email_input"), true).await.unwrap();

    // 3. Read live logs resource again, verify new log entries recorded
    let logs_after = client.read_resource("slate://logs/live").await.unwrap();
    let log_text_after = logs_after.text.unwrap();
    assert!(log_text_after.len() > log_text_before.len());
    assert!(log_text_after.contains("[ACTION] Theme toggled"));
    assert!(log_text_after.contains("[ACTION] Typed into email_input"));
}

#[tokio::test]
async fn test_tier3_resource_read_after_agent_actions() {
    run_test_tier3_resource_read_after_agent_actions().await;
}

pub async fn run_test_tier3_acp_dispatch_interaction_with_mcp_client() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Send ACP command from external protocol adapter
    let acp_msg = AcpMessage {
        message_id: "acp-cross-1".to_string(),
        performative: AcpPerformative::Command,
        action: "send_keys".to_string(),
        sender: "peer-agent".to_string(),
        payload: serde_json::json!({
            "text": "remote-peer@acp.network",
            "element_id": "email_input",
            "clear_first": true
        }),
    };
    let acp_res = engine.dispatch_acp(acp_msg).await.expect("ACP dispatch failed");
    assert!(acp_res.success);

    // 2. Query state via MCP client and verify consistency across protocol boundaries
    let mcp_state = client.get_state(Some(vec!["demo_input_text"])).await.unwrap();
    assert_eq!(mcp_state.properties["demo_input_text"], "remote-peer@acp.network");
}

#[tokio::test]
async fn test_tier3_acp_dispatch_interaction_with_mcp_client() {
    run_test_tier3_acp_dispatch_interaction_with_mcp_client().await;
}
