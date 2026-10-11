use crate::harness::create_test_session;
use crate::types::*;

// ============================================================================
// Group 1: MCP Server Core, Handshake & Ping (FEAT-MCP-01)
// ============================================================================

pub async fn run_test_tier1_mcp_initialize_handshake() {
    let (client, _engine, _handle) = create_test_session();
    let init_res = client.initialize().await.expect("Initialize failed");

    assert_eq!(init_res.protocol_version, "2024-11-05");
    assert_eq!(init_res.server_info.name, "slate-mcp");
    assert_eq!(init_res.server_info.version, "0.1.0");
    assert!(init_res.capabilities.tools.is_some());
    assert!(init_res.capabilities.resources.is_some());
    assert!(init_res.capabilities.logging.is_some());
}

#[tokio::test]
async fn test_tier1_mcp_initialize_handshake() {
    run_test_tier1_mcp_initialize_handshake().await;
}

pub async fn run_test_tier1_mcp_initialized_notification() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    client.initialized().await.expect("Initialized notification failed");

    tokio::time::sleep(std::time::Duration::from_millis(20)).await;

    let logs = engine.logs.lock().await;
    assert!(logs.iter().any(|l| l.contains("Client initialized acknowledged")));
}

#[tokio::test]
async fn test_tier1_mcp_initialized_notification() {
    run_test_tier1_mcp_initialized_notification().await;
}

pub async fn run_test_tier1_mcp_ping() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    client.ping().await.expect("Ping failed");
}

#[tokio::test]
async fn test_tier1_mcp_ping() {
    run_test_tier1_mcp_ping().await;
}

pub async fn run_test_tier1_mcp_tools_list_count_and_names() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let tools = client.list_tools().await.expect("list_tools failed");

    assert_eq!(tools.len(), 5);
    let names: Vec<String> = tools.into_iter().map(|t| t.name).collect();
    assert!(names.contains(&"get_screenshot".to_string()));
    assert!(names.contains(&"inspect_tree".to_string()));
    assert!(names.contains(&"click_element".to_string()));
    assert!(names.contains(&"send_keys".to_string()));
    assert!(names.contains(&"get_state".to_string()));
}

#[tokio::test]
async fn test_tier1_mcp_tools_list_count_and_names() {
    run_test_tier1_mcp_tools_list_count_and_names().await;
}

pub async fn run_test_tier1_mcp_tools_schemas() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let tools = client.list_tools().await.expect("list_tools failed");

    for tool in tools {
        assert_eq!(tool.input_schema["type"], "object");
        assert!(tool.input_schema.get("properties").is_some());
        assert!(!tool.description.is_empty());
    }
}

#[tokio::test]
async fn test_tier1_mcp_tools_schemas() {
    run_test_tier1_mcp_tools_schemas().await;
}

// ============================================================================
// Group 2: Visual Snapshot / Screenshot (FEAT-MCP-02)
// ============================================================================

pub async fn run_test_tier1_get_screenshot_png_format() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let screenshot = client.get_screenshot(None).await.expect("get_screenshot failed");

    assert_eq!(screenshot.format, "image/png");
}

#[tokio::test]
async fn test_tier1_get_screenshot_png_format() {
    run_test_tier1_get_screenshot_png_format().await;
}

pub async fn run_test_tier1_get_screenshot_dimensions() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let screenshot = client.get_screenshot(None).await.expect("get_screenshot failed");

    assert_eq!(screenshot.width, 1040);
    assert_eq!(screenshot.height, 720);
}

#[tokio::test]
async fn test_tier1_get_screenshot_dimensions() {
    run_test_tier1_get_screenshot_dimensions().await;
}

pub async fn run_test_tier1_get_screenshot_png_magic_bytes() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let screenshot = client.get_screenshot(None).await.expect("get_screenshot failed");

    assert!(screenshot.is_valid_png(), "Screenshot data missing valid PNG header");
    assert_eq!(&screenshot.data[0..8], &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
}

#[tokio::test]
async fn test_tier1_get_screenshot_png_magic_bytes() {
    run_test_tier1_get_screenshot_png_magic_bytes().await;
}

pub async fn run_test_tier1_get_screenshot_custom_mime_param() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let screenshot = client.get_screenshot(Some("image/png")).await.expect("get_screenshot with mime failed");

    assert_eq!(screenshot.format, "image/png");
    assert!(screenshot.is_valid_png());
}

#[tokio::test]
async fn test_tier1_get_screenshot_custom_mime_param() {
    run_test_tier1_get_screenshot_custom_mime_param().await;
}

pub async fn run_test_tier1_get_screenshot_non_empty_payload() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let screenshot = client.get_screenshot(None).await.expect("get_screenshot failed");

    assert!(screenshot.data.len() > 100, "PNG payload too small: {} bytes", screenshot.data.len());
    let base64_str = screenshot.to_base64_png();
    assert!(!base64_str.is_empty());
}

#[tokio::test]
async fn test_tier1_get_screenshot_non_empty_payload() {
    run_test_tier1_get_screenshot_non_empty_payload().await;
}

// ============================================================================
// Group 3: UI Hierarchy Inspection (FEAT-MCP-03)
// ============================================================================

pub async fn run_test_tier1_inspect_tree_root() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let tree = client.inspect_tree(None, None).await.expect("inspect_tree failed");

    assert_eq!(tree.root.id.as_deref(), Some("main_window"));
    assert_eq!(tree.root.type_name, "MainWindow");
    assert_eq!(tree.root.bounds.width, 1040.0);
    assert_eq!(tree.root.bounds.height, 720.0);
}

#[tokio::test]
async fn test_tier1_inspect_tree_root() {
    run_test_tier1_inspect_tree_root().await;
}

pub async fn run_test_tier1_inspect_tree_hierarchy_nodes() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let tree = client.inspect_tree(None, None).await.expect("inspect_tree failed");

    let child_ids: Vec<Option<String>> = tree.root.children.iter().map(|c| c.id.clone()).collect();
    assert!(child_ids.contains(&Some("header_bar".to_string())));
    assert!(child_ids.contains(&Some("nav_view".to_string())));
    assert!(child_ids.contains(&Some("content_area".to_string())));
}

#[tokio::test]
async fn test_tier1_inspect_tree_hierarchy_nodes() {
    run_test_tier1_inspect_tree_hierarchy_nodes().await;
}

pub async fn run_test_tier1_inspect_tree_element_roles_and_labels() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let tree = client.inspect_tree(None, None).await.expect("inspect_tree failed");

    let btn = tree.root.find_by_id("theme_toggle_btn").expect("theme_toggle_btn not found");
    assert_eq!(btn.role.as_deref(), Some("button"));
    assert!(btn.label.is_some());

    let input = tree.root.find_by_id("email_input").expect("email_input not found");
    assert_eq!(input.role.as_deref(), Some("textbox"));
    assert_eq!(input.label.as_deref(), Some("Email Address"));
}

#[tokio::test]
async fn test_tier1_inspect_tree_element_roles_and_labels() {
    run_test_tier1_inspect_tree_element_roles_and_labels().await;
}

pub async fn run_test_tier1_inspect_tree_filter_by_root_id() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let tree = client.inspect_tree(Some("nav_view"), None).await.expect("inspect_tree filtered failed");

    assert_eq!(tree.root.id.as_deref(), Some("nav_view"));
    assert_eq!(tree.root.role.as_deref(), Some("navigation"));
    assert!(!tree.root.children.is_empty());
}

#[tokio::test]
async fn test_tier1_inspect_tree_filter_by_root_id() {
    run_test_tier1_inspect_tree_filter_by_root_id().await;
}

pub async fn run_test_tier1_inspect_tree_max_depth() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");
    let tree = client.inspect_tree(None, Some(10)).await.expect("inspect_tree with depth failed");

    assert!(tree.root.children.len() >= 3);
}

#[tokio::test]
async fn test_tier1_inspect_tree_max_depth() {
    run_test_tier1_inspect_tree_max_depth().await;
}

// ============================================================================
// Group 4: Element Controller / Click Dispatch (FEAT-MCP-04)
// ============================================================================

pub async fn run_test_tier1_click_element_by_id() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let initial_count = engine.counter.load(std::sync::atomic::Ordering::SeqCst);
    let res = client
        .click_element(serde_json::json!({ "id": "increment_counter_btn" }))
        .await
        .expect("click_element failed");

    assert!(res.success);
    assert_eq!(res.target, "increment_counter_btn");
    let new_count = engine.counter.load(std::sync::atomic::Ordering::SeqCst);
    assert_eq!(new_count, initial_count + 1);
}

#[tokio::test]
async fn test_tier1_click_element_by_id() {
    run_test_tier1_click_element_by_id().await;
}

pub async fn run_test_tier1_click_element_by_label() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let initial_dark = *engine.is_dark.lock().await;
    let res = client
        .click_element(serde_json::json!({ "label": "Dark Mode" }))
        .await
        .expect("click_element failed");

    assert!(res.success);
    let new_dark = *engine.is_dark.lock().await;
    assert_ne!(initial_dark, new_dark);
}

#[tokio::test]
async fn test_tier1_click_element_by_label() {
    run_test_tier1_click_element_by_label().await;
}

pub async fn run_test_tier1_click_element_by_coordinates() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let initial_count = engine.counter.load(std::sync::atomic::Ordering::SeqCst);
    let res = client
        .click_element(serde_json::json!({ "x": 300.0, "y": 85.0 }))
        .await
        .expect("click_element by coords failed");

    assert!(res.success);
    let new_count = engine.counter.load(std::sync::atomic::Ordering::SeqCst);
    assert_eq!(new_count, initial_count + 1);
}

#[tokio::test]
async fn test_tier1_click_element_by_coordinates() {
    run_test_tier1_click_element_by_coordinates().await;
}

pub async fn run_test_tier1_click_element_switch_toggle() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let initial_switch = *engine.demo_switch_1.lock().await;
    let res = client
        .click_element(serde_json::json!({ "id": "switch_notifications" }))
        .await
        .expect("click switch failed");

    assert!(res.success);
    let new_switch = *engine.demo_switch_1.lock().await;
    assert_eq!(new_switch, !initial_switch);
}

#[tokio::test]
async fn test_tier1_click_element_switch_toggle() {
    run_test_tier1_click_element_switch_toggle().await;
}

pub async fn run_test_tier1_click_element_double_click() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client
        .click_element(serde_json::json!({
            "id": "increment_counter_btn",
            "button": "left",
            "click_count": 2
        }))
        .await
        .expect("double click failed");

    assert!(res.success);
}

#[tokio::test]
async fn test_tier1_click_element_double_click() {
    run_test_tier1_click_element_double_click().await;
}

// ============================================================================
// Group 5: Text Input Controller / Send Keys (FEAT-MCP-05)
// ============================================================================

pub async fn run_test_tier1_send_keys_to_input_field() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let res = client
        .send_keys("tester@slate.internal", Some("email_input"), true)
        .await
        .expect("send_keys failed");

    assert!(res.success);
    let current_val = engine.demo_input_text.lock().await.clone();
    assert_eq!(current_val, "tester@slate.internal");
}

#[tokio::test]
async fn test_tier1_send_keys_to_input_field() {
    run_test_tier1_send_keys_to_input_field().await;
}

pub async fn run_test_tier1_send_keys_with_clear_first() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    client.send_keys("first_string", Some("email_input"), true).await.unwrap();
    client.send_keys("second_string", Some("email_input"), true).await.unwrap();

    let val = engine.demo_input_text.lock().await.clone();
    assert_eq!(val, "second_string");
}

#[tokio::test]
async fn test_tier1_send_keys_with_clear_first() {
    run_test_tier1_send_keys_with_clear_first().await;
}

pub async fn run_test_tier1_send_keys_append_without_clear() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    client.send_keys("Hello", Some("email_input"), true).await.unwrap();
    client.send_keys(" World", Some("email_input"), false).await.unwrap();

    let val = engine.demo_input_text.lock().await.clone();
    assert_eq!(val, "Hello World");
}

#[tokio::test]
async fn test_tier1_send_keys_append_without_clear() {
    run_test_tier1_send_keys_append_without_clear().await;
}

pub async fn run_test_tier1_send_keys_to_textarea() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let long_text = "Line 1: High performance desktop UI.\nLine 2: Slint native framework.";
    let res = client
        .send_keys(long_text, Some("notes_textarea"), true)
        .await
        .expect("send_keys to textarea failed");

    assert!(res.success);
    let val = engine.demo_textarea_text.lock().await.clone();
    assert_eq!(val, long_text);
}

#[tokio::test]
async fn test_tier1_send_keys_to_textarea() {
    run_test_tier1_send_keys_to_textarea().await;
}

pub async fn run_test_tier1_send_keys_special_symbols() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let symbols = "!@#$%^&*()_+=-[]{};:'\",.<>?/\\|";
    let res = client
        .send_keys(symbols, Some("email_input"), true)
        .await
        .expect("send_keys with symbols failed");

    assert!(res.success);
    let val = engine.demo_input_text.lock().await.clone();
    assert_eq!(val, symbols);
}

#[tokio::test]
async fn test_tier1_send_keys_special_symbols() {
    run_test_tier1_send_keys_special_symbols().await;
}

// ============================================================================
// Group 6: Application State & Diagnostics (FEAT-MCP-06)
// ============================================================================

pub async fn run_test_tier1_get_state_full() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let state = client.get_state(None).await.expect("get_state failed");
    assert_eq!(state.active_view, "buttons");
    assert!(state.properties.contains_key("demo_input_text"));
    assert!(state.properties.contains_key("is_dark"));
    assert!(state.properties.contains_key("compute_running"));
    assert!(state.timestamp_ms > 0);
}

#[tokio::test]
async fn test_tier1_get_state_full() {
    run_test_tier1_get_state_full().await;
}

pub async fn run_test_tier1_get_state_filtered_keys() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let state = client
        .get_state(Some(vec!["is_dark", "counter"]))
        .await
        .expect("get_state filtered failed");

    assert_eq!(state.properties.len(), 2);
    assert!(state.properties.contains_key("is_dark"));
    assert!(state.properties.contains_key("counter"));
    assert!(!state.properties.contains_key("demo_input_text"));
}

#[tokio::test]
async fn test_tier1_get_state_filtered_keys() {
    run_test_tier1_get_state_filtered_keys().await;
}

pub async fn run_test_tier1_get_state_active_view() {
    let (client, engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    *engine.active_tab.lock().await = 6;
    let state = client.get_state(None).await.expect("get_state failed");
    assert_eq!(state.active_view, "compute");
}

#[tokio::test]
async fn test_tier1_get_state_active_view() {
    run_test_tier1_get_state_active_view().await;
}

pub async fn run_test_tier1_get_state_compute_fields() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let state = client.get_state(None).await.expect("get_state failed");
    assert_eq!(state.properties.get("compute_running"), Some(&serde_json::json!(false)));
    assert_eq!(state.properties.get("compute_status"), Some(&serde_json::json!("Ready")));
    assert_eq!(state.properties.get("compute_result"), Some(&serde_json::json!("Idle")));
}

#[tokio::test]
async fn test_tier1_get_state_compute_fields() {
    run_test_tier1_get_state_compute_fields().await;
}

pub async fn run_test_tier1_get_state_timestamp() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let state = client.get_state(None).await.expect("get_state failed");
    assert!(state.timestamp_ms >= 1700000000000);
}

#[tokio::test]
async fn test_tier1_get_state_timestamp() {
    run_test_tier1_get_state_timestamp().await;
}

// ============================================================================
// Group 7: MCP Resources & ACP Protocol (FEAT-MCP-07, FEAT-EXT-01/02)
// ============================================================================

pub async fn run_test_tier1_resources_list() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let resources = client.list_resources().await.expect("list_resources failed");
    assert_eq!(resources.len(), 2);
    let uris: Vec<String> = resources.into_iter().map(|r| r.uri).collect();
    assert!(uris.contains(&"slate://app/context".to_string()));
    assert!(uris.contains(&"slate://logs/live".to_string()));
}

#[tokio::test]
async fn test_tier1_resources_list() {
    run_test_tier1_resources_list().await;
}

pub async fn run_test_tier1_resources_read_context() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let content = client.read_resource("slate://app/context").await.expect("read context resource failed");
    assert_eq!(content.uri, "slate://app/context");
    assert_eq!(content.mime_type.as_deref(), Some("application/json"));
    let text = content.text.expect("text content missing");
    let json_val: serde_json::Value = serde_json::from_str(&text).expect("invalid json in context resource");
    assert_eq!(json_val["app"], "slate-showcase");
}

#[tokio::test]
async fn test_tier1_resources_read_context() {
    run_test_tier1_resources_read_context().await;
}

pub async fn run_test_tier1_resources_read_logs() {
    let (client, _engine, _handle) = create_test_session();
    let _ = client.initialize().await.expect("Initialize failed");

    let content = client.read_resource("slate://logs/live").await.expect("read logs resource failed");
    assert_eq!(content.uri, "slate://logs/live");
    assert_eq!(content.mime_type.as_deref(), Some("text/plain"));
    let text = content.text.expect("text content missing");
    assert!(text.contains("[INFO] Slate application initialized"));
}

#[tokio::test]
async fn test_tier1_resources_read_logs() {
    run_test_tier1_resources_read_logs().await;
}

pub async fn run_test_tier1_acp_message_query_state() {
    let (_client, engine, _handle) = create_test_session();

    let msg = AcpMessage {
        message_id: "acp-101".to_string(),
        performative: AcpPerformative::Query,
        action: "query_state".to_string(),
        sender: "external-agent".to_string(),
        payload: serde_json::json!({}),
    };

    let resp = engine.dispatch_acp(msg).await.expect("dispatch_acp failed");
    assert_eq!(resp.correlation_id, "acp-101");
    assert!(resp.success);
    assert_eq!(resp.data["active_view"], "buttons");
}

#[tokio::test]
async fn test_tier1_acp_message_query_state() {
    run_test_tier1_acp_message_query_state().await;
}

pub async fn run_test_tier1_acp_message_command_click() {
    let (_client, engine, _handle) = create_test_session();

    let initial_count = engine.counter.load(std::sync::atomic::Ordering::SeqCst);
    let msg = AcpMessage {
        message_id: "acp-102".to_string(),
        performative: AcpPerformative::Command,
        action: "click".to_string(),
        sender: "external-agent".to_string(),
        payload: serde_json::json!({ "id": "increment_counter_btn" }),
    };

    let resp = engine.dispatch_acp(msg).await.expect("dispatch_acp click failed");
    assert_eq!(resp.correlation_id, "acp-102");
    assert!(resp.success);
    let new_count = engine.counter.load(std::sync::atomic::Ordering::SeqCst);
    assert_eq!(new_count, initial_count + 1);
}

#[tokio::test]
async fn test_tier1_acp_message_command_click() {
    run_test_tier1_acp_message_command_click().await;
}

pub async fn run_test_tier1_acp_message_send_keys() {
    let (_client, engine, _handle) = create_test_session();

    let msg = AcpMessage {
        message_id: "acp-103".to_string(),
        performative: AcpPerformative::Command,
        action: "send_keys".to_string(),
        sender: "external-agent".to_string(),
        payload: serde_json::json!({
            "text": "agent@acp.network",
            "element_id": "email_input",
            "clear_first": true
        }),
    };

    let resp = engine.dispatch_acp(msg).await.expect("dispatch_acp send_keys failed");
    assert_eq!(resp.correlation_id, "acp-103");
    assert!(resp.success);
    let text = engine.demo_input_text.lock().await.clone();
    assert_eq!(text, "agent@acp.network");
}

#[tokio::test]
async fn test_tier1_acp_message_send_keys() {
    run_test_tier1_acp_message_send_keys().await;
}
