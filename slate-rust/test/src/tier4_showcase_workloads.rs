use crate::harness::create_test_session;
use std::sync::Arc;
use tokio::time::{sleep, Duration};

// ============================================================================
// Tier 4: Real-World Application Showcase Workloads
// ============================================================================

pub async fn run_test_tier4_showcase_tab_navigation() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Initial tab is 0 ("buttons")
    let s0 = client.get_state(Some(vec!["active_tab"])).await.unwrap();
    assert_eq!(s0.active_view, "buttons");

    // 2. Switch to Forms tab
    client.click_element(serde_json::json!({ "id": "tab_forms" })).await.unwrap();
    let s1 = client.get_state(Some(vec!["active_tab"])).await.unwrap();
    assert_eq!(s1.active_view, "forms");
    assert_eq!(s1.properties["active_tab"], 1);

    // 3. Switch to Compute Engine tab
    client.click_element(serde_json::json!({ "id": "tab_compute" })).await.unwrap();
    let s2 = client.get_state(Some(vec!["active_tab"])).await.unwrap();
    assert_eq!(s2.active_view, "compute");
    assert_eq!(s2.properties["active_tab"], 6);

    // 4. Switch back to Buttons tab
    client.click_element(serde_json::json!({ "id": "tab_buttons" })).await.unwrap();
    let s3 = client.get_state(Some(vec!["active_tab"])).await.unwrap();
    assert_eq!(s3.active_view, "buttons");
    assert_eq!(s3.properties["active_tab"], 0);
}

#[tokio::test]
async fn test_tier4_showcase_tab_navigation() {
    run_test_tier4_showcase_tab_navigation().await;
}

pub async fn run_test_tier4_showcase_form_automation() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Switch to Forms
    client.click_element(serde_json::json!({ "id": "tab_forms" })).await.unwrap();

    // 2. Fill email field
    client.send_keys("admin@enterprise.internal", Some("email_input"), true).await.unwrap();

    // 3. Fill textarea field
    client.send_keys("Automated test scenario for Slate desktop application.", Some("notes_textarea"), true).await.unwrap();

    // 4. Toggle switch
    client.click_element(serde_json::json!({ "id": "switch_notifications" })).await.unwrap();

    // 5. Query and verify complete form state
    let state = client.get_state(Some(vec![
        "demo_input_text",
        "demo_textarea_text",
        "demo_switch_1",
    ])).await.unwrap();

    assert_eq!(state.properties["demo_input_text"], "admin@enterprise.internal");
    assert_eq!(state.properties["demo_textarea_text"], "Automated test scenario for Slate desktop application.");
    assert_eq!(state.properties["demo_switch_1"], false);
}

#[tokio::test]
async fn test_tier4_showcase_form_automation() {
    run_test_tier4_showcase_form_automation().await;
}

pub async fn run_test_tier4_showcase_compute_start_and_query_concurrent() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Start Monte Carlo Pi compute task via agent
    let start_res = client
        .click_element(serde_json::json!({ "id": "start_compute_btn" }))
        .await
        .expect("start compute click failed");
    assert!(start_res.success);

    // 2. Query state concurrently while background compute is active
    let state = client.get_state(Some(vec!["compute_running", "compute_status"])).await.unwrap();
    assert_eq!(state.properties["compute_running"], true);
    assert_eq!(state.properties["compute_status"], "Computing");

    // 3. Execute another agent command (e.g. counter click or screenshot) concurrently
    //    Verifies background compute does not lock or freeze agent communication
    let count_res = client.click_element(serde_json::json!({ "id": "increment_counter_btn" })).await.unwrap();
    assert!(count_res.success);

    let screenshot = client.get_screenshot(None).await.expect("screenshot during compute failed");
    assert!(screenshot.is_valid_png());
}

#[tokio::test]
async fn test_tier4_showcase_compute_start_and_query_concurrent() {
    run_test_tier4_showcase_compute_start_and_query_concurrent().await;
}

pub async fn run_test_tier4_showcase_compute_cancel_workload() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Start background compute
    client.click_element(serde_json::json!({ "id": "start_compute_btn" })).await.unwrap();
    let s_running = client.get_state(Some(vec!["compute_running"])).await.unwrap();
    assert_eq!(s_running.properties["compute_running"], true);

    // 2. Dispatch cancel compute
    let cancel_res = client
        .click_element(serde_json::json!({ "id": "cancel_compute_btn" }))
        .await
        .expect("cancel compute click failed");
    assert!(cancel_res.success);

    // 3. Verify state transitions to Cancelled
    let s_cancelled = client.get_state(Some(vec!["compute_running", "compute_status", "compute_result"])).await.unwrap();
    assert_eq!(s_cancelled.properties["compute_running"], false);
    assert_eq!(s_cancelled.properties["compute_status"], "Cancelled");
    assert_eq!(s_cancelled.properties["compute_result"], "Computation was cancelled");
}

#[tokio::test]
async fn test_tier4_showcase_compute_cancel_workload() {
    run_test_tier4_showcase_compute_cancel_workload().await;
}

pub async fn run_test_tier4_showcase_theme_toggle_visual_verification() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // Light mode snapshot
    let snap_light = client.get_screenshot(None).await.unwrap();
    assert!(snap_light.is_valid_png());

    // Toggle theme to dark
    client.click_element(serde_json::json!({ "id": "theme_toggle_btn" })).await.unwrap();
    let state_dark = client.get_state(Some(vec!["is_dark"])).await.unwrap();
    assert_eq!(state_dark.properties["is_dark"], true);

    // Dark mode snapshot
    let snap_dark = client.get_screenshot(None).await.unwrap();
    assert!(snap_dark.is_valid_png());
    assert_eq!(snap_light.width, snap_dark.width);
    assert_eq!(snap_light.height, snap_dark.height);
}

#[tokio::test]
async fn test_tier4_showcase_theme_toggle_visual_verification() {
    run_test_tier4_showcase_theme_toggle_visual_verification().await;
}

pub async fn run_test_tier4_showcase_multi_threaded_non_blocking_stress() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    // 1. Start heavy background task
    client.click_element(serde_json::json!({ "id": "start_compute_btn" })).await.unwrap();

    let client_arc = Arc::new(client);
    let mut tasks = Vec::new();

    // 2. Spawn 20 parallel agent operations while background compute executes
    for i in 0..20 {
        let cl = client_arc.clone();
        tasks.push(tokio::spawn(async move {
            if i % 2 == 0 {
                cl.get_state(Some(vec!["compute_running"])).await.map(|_| ())
            } else {
                cl.click_element(serde_json::json!({ "id": "increment_counter_btn" })).await.map(|_| ())
            }
        }));
    }

    // Await all parallel tasks; ensure zero deadlocks or stalls
    for t in tasks {
        let res = t.await.expect("Task panicked");
        assert!(res.is_ok(), "Concurrent request failed during background compute: {:?}", res);
    }

    // Cancel compute task cleanly
    client_arc.click_element(serde_json::json!({ "id": "cancel_compute_btn" })).await.unwrap();
}

#[tokio::test]
async fn test_tier4_showcase_multi_threaded_non_blocking_stress() {
    run_test_tier4_showcase_multi_threaded_non_blocking_stress().await;
}

pub async fn run_test_tier4_showcase_full_remote_control_tour() {
    let (client, _engine, _handle) = create_test_session();

    // Step 1: Handshake
    let init = client.initialize().await.expect("1. Handshake failed");
    assert_eq!(init.server_info.name, "slate-mcp");
    client.initialized().await.expect("Initialized notification failed");

    // Step 2: Tool discovery
    let tools = client.list_tools().await.expect("2. Tool discovery failed");
    assert_eq!(tools.len(), 5);

    // Step 3: Inspect initial UI tree
    let tree = client.inspect_tree(None, None).await.expect("3. Tree inspection failed");
    assert_eq!(tree.root.id.as_deref(), Some("main_window"));

    // Step 4: Navigate to Forms tab
    client.click_element(serde_json::json!({ "id": "tab_forms" })).await.expect("4. Tab switch failed");

    // Step 5: Fill in input data
    client.send_keys("tour-agent@slate.rs", Some("email_input"), true).await.expect("5. Send keys failed");

    // Step 6: Start compute engine
    client.click_element(serde_json::json!({ "id": "start_compute_btn" })).await.expect("6. Start compute failed");
    sleep(Duration::from_millis(50)).await;

    // Step 7: Query state
    let state = client.get_state(None).await.expect("7. Query state failed");
    assert_eq!(state.properties["demo_input_text"], "tour-agent@slate.rs");
    assert_eq!(state.properties["compute_running"], true);

    // Step 8: Cancel compute
    client.click_element(serde_json::json!({ "id": "cancel_compute_btn" })).await.expect("8. Cancel compute failed");

    // Step 9: Capture visual snapshot
    let snapshot = client.get_screenshot(None).await.expect("9. Screenshot failed");
    assert!(snapshot.is_valid_png());

    // Step 10: Inspect live logs
    let logs = client.read_resource("slate://logs/live").await.expect("10. Read logs failed");
    assert!(logs.text.unwrap().contains("[ACTION]"));
}

#[tokio::test]
async fn test_tier4_showcase_full_remote_control_tour() {
    run_test_tier4_showcase_full_remote_control_tour().await;
}
