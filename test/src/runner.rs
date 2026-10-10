use std::time::Instant;

pub struct TestCase {
    pub name: &'static str,
    pub tier: u32,
    pub func: Box<dyn Fn() -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), String>> + Send>> + Send + Sync>,
}

pub struct TestReport {
    pub tier: u32,
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
    pub duration_ms: u128,
}

pub async fn run_e2e_tests(selected_tier: Option<u32>) -> (Vec<TestReport>, bool) {
    let mut reports = Vec::new();
    let mut all_passed = true;

    println!("\n================================================================================");
    println!("               SLATE AGENT / MCP END-TO-END TEST RUNNER");
    println!("================================================================================\n");

    let tiers_to_run: Vec<u32> = match selected_tier {
        Some(t) => vec![t],
        None => vec![1, 2, 3, 4],
    };

    for tier in tiers_to_run {
        let tier_name = match tier {
            1 => "Tier 1: Feature Coverage (>=5 test cases per core feature)",
            2 => "Tier 2: Boundary, Corner & Adversarial Edge Cases",
            3 => "Tier 3: Cross-Feature Multi-Step Interactions",
            4 => "Tier 4: Real-World Application Showcase Workloads",
            _ => "Unknown Tier",
        };

        println!("--------------------------------------------------------------------------------");
        println!(" RUNNING: {}", tier_name);
        println!("--------------------------------------------------------------------------------");

        let tests = get_tests_for_tier(tier);
        let tier_start = Instant::now();
        let mut passed = 0;
        let mut failed = 0;

        for test in &tests {
            let start = Instant::now();
            print!("  [TEST] {:<58} ... ", test.0);
            match (test.1)().await {
                Ok(_) => {
                    let dur = start.elapsed().as_millis();
                    println!("\x1b[32mPASSED\x1b[0m ({:>3}ms)", dur);
                    passed += 1;
                }
                Err(err) => {
                    let dur = start.elapsed().as_millis();
                    println!("\x1b[31mFAILED\x1b[0m ({:>3}ms)\n         Error: {}", dur, err);
                    failed += 1;
                    all_passed = false;
                }
            }
        }

        let tier_dur = tier_start.elapsed().as_millis();
        reports.push(TestReport {
            tier,
            total: tests.len(),
            passed,
            failed,
            duration_ms: tier_dur,
        });

        println!();
    }

    println!("================================================================================");
    println!("                          E2E TEST EXECUTION SUMMARY");
    println!("================================================================================");
    println!("{:<10} | {:<10} | {:<10} | {:<10} | {:<12} | {:<10}", "Tier", "Total", "Passed", "Failed", "Time (ms)", "Status");
    println!("{:-<10}-+-{:-<10}-+-{:-<10}-+-{:-<10}-+-{:-<12}-+-{:-<10}", "", "", "", "", "", "");

    for rep in &reports {
        let status = if rep.failed == 0 { "\x1b[32mOK\x1b[0m" } else { "\x1b[31mFAIL\x1b[0m" };
        println!(
            "Tier {:<5} | {:<10} | {:<10} | {:<10} | {:<12} | {}",
            rep.tier, rep.total, rep.passed, rep.failed, rep.duration_ms, status
        );
    }
    println!("================================================================================\n");

    (reports, all_passed)
}

type TestFuture = std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), String>> + Send>>;
type TestFn = fn() -> TestFuture;

fn get_tests_for_tier(tier: u32) -> Vec<(&'static str, TestFn)> {
    match tier {
        1 => vec![
            ("test_tier1_mcp_initialize_handshake", || Box::pin(async { wrap_test(tier1_mcp_initialize_handshake()).await })),
            ("test_tier1_mcp_initialized_notification", || Box::pin(async { wrap_test(tier1_mcp_initialized_notification()).await })),
            ("test_tier1_mcp_ping", || Box::pin(async { wrap_test(tier1_mcp_ping()).await })),
            ("test_tier1_mcp_tools_list_count_and_names", || Box::pin(async { wrap_test(tier1_mcp_tools_list_count_and_names()).await })),
            ("test_tier1_mcp_tools_schemas", || Box::pin(async { wrap_test(tier1_mcp_tools_schemas()).await })),
            ("test_tier1_get_screenshot_png_format", || Box::pin(async { wrap_test(tier1_get_screenshot_png_format()).await })),
            ("test_tier1_get_screenshot_dimensions", || Box::pin(async { wrap_test(tier1_get_screenshot_dimensions()).await })),
            ("test_tier1_get_screenshot_png_magic_bytes", || Box::pin(async { wrap_test(tier1_get_screenshot_png_magic_bytes()).await })),
            ("test_tier1_get_screenshot_custom_mime_param", || Box::pin(async { wrap_test(tier1_get_screenshot_custom_mime_param()).await })),
            ("test_tier1_get_screenshot_non_empty_payload", || Box::pin(async { wrap_test(tier1_get_screenshot_non_empty_payload()).await })),
            ("test_tier1_inspect_tree_root", || Box::pin(async { wrap_test(tier1_inspect_tree_root()).await })),
            ("test_tier1_inspect_tree_hierarchy_nodes", || Box::pin(async { wrap_test(tier1_inspect_tree_hierarchy_nodes()).await })),
            ("test_tier1_inspect_tree_element_roles_and_labels", || Box::pin(async { wrap_test(tier1_inspect_tree_element_roles_and_labels()).await })),
            ("test_tier1_inspect_tree_filter_by_root_id", || Box::pin(async { wrap_test(tier1_inspect_tree_filter_by_root_id()).await })),
            ("test_tier1_inspect_tree_max_depth", || Box::pin(async { wrap_test(tier1_inspect_tree_max_depth()).await })),
            ("test_tier1_click_element_by_id", || Box::pin(async { wrap_test(tier1_click_element_by_id()).await })),
            ("test_tier1_click_element_by_label", || Box::pin(async { wrap_test(tier1_click_element_by_label()).await })),
            ("test_tier1_click_element_by_coordinates", || Box::pin(async { wrap_test(tier1_click_element_by_coordinates()).await })),
            ("test_tier1_click_element_switch_toggle", || Box::pin(async { wrap_test(tier1_click_element_switch_toggle()).await })),
            ("test_tier1_click_element_double_click", || Box::pin(async { wrap_test(tier1_click_element_double_click()).await })),
            ("test_tier1_send_keys_to_input_field", || Box::pin(async { wrap_test(tier1_send_keys_to_input_field()).await })),
            ("test_tier1_send_keys_with_clear_first", || Box::pin(async { wrap_test(tier1_send_keys_with_clear_first()).await })),
            ("test_tier1_send_keys_append_without_clear", || Box::pin(async { wrap_test(tier1_send_keys_append_without_clear()).await })),
            ("test_tier1_send_keys_to_textarea", || Box::pin(async { wrap_test(tier1_send_keys_to_textarea()).await })),
            ("test_tier1_send_keys_special_symbols", || Box::pin(async { wrap_test(tier1_send_keys_special_symbols()).await })),
            ("test_tier1_get_state_full", || Box::pin(async { wrap_test(tier1_get_state_full()).await })),
            ("test_tier1_get_state_filtered_keys", || Box::pin(async { wrap_test(tier1_get_state_filtered_keys()).await })),
            ("test_tier1_get_state_active_view", || Box::pin(async { wrap_test(tier1_get_state_active_view()).await })),
            ("test_tier1_get_state_compute_fields", || Box::pin(async { wrap_test(tier1_get_state_compute_fields()).await })),
            ("test_tier1_get_state_timestamp", || Box::pin(async { wrap_test(tier1_get_state_timestamp()).await })),
            ("test_tier1_resources_list", || Box::pin(async { wrap_test(tier1_resources_list()).await })),
            ("test_tier1_resources_read_context", || Box::pin(async { wrap_test(tier1_resources_read_context()).await })),
            ("test_tier1_resources_read_logs", || Box::pin(async { wrap_test(tier1_resources_read_logs()).await })),
            ("test_tier1_acp_message_query_state", || Box::pin(async { wrap_test(tier1_acp_message_query_state()).await })),
            ("test_tier1_acp_message_command_click", || Box::pin(async { wrap_test(tier1_acp_message_command_click()).await })),
            ("test_tier1_acp_message_send_keys", || Box::pin(async { wrap_test(tier1_acp_message_send_keys()).await })),
        ],
        2 => vec![
            ("test_tier2_malformed_json_syntax", || Box::pin(async { wrap_test(tier2_malformed_json_syntax()).await })),
            ("test_tier2_invalid_request_structure", || Box::pin(async { wrap_test(tier2_invalid_request_structure()).await })),
            ("test_tier2_unknown_jsonrpc_method", || Box::pin(async { wrap_test(tier2_unknown_jsonrpc_method()).await })),
            ("test_tier2_unknown_mcp_tool", || Box::pin(async { wrap_test(tier2_unknown_mcp_tool()).await })),
            ("test_tier2_send_keys_missing_text_param", || Box::pin(async { wrap_test(tier2_send_keys_missing_text_param()).await })),
            ("test_tier2_click_element_missing_target", || Box::pin(async { wrap_test(tier2_click_element_missing_target()).await })),
            ("test_tier2_click_element_negative_coordinates", || Box::pin(async { wrap_test(tier2_click_element_negative_coordinates()).await })),
            ("test_tier2_click_element_extreme_out_of_bounds_coords", || Box::pin(async { wrap_test(tier2_click_element_extreme_out_of_bounds_coords()).await })),
            ("test_tier2_click_element_nonexistent_id", || Box::pin(async { wrap_test(tier2_click_element_nonexistent_id()).await })),
            ("test_tier2_send_keys_to_non_editable_element", || Box::pin(async { wrap_test(tier2_send_keys_to_non_editable_element()).await })),
            ("test_tier2_inspect_tree_invalid_depth_zero", || Box::pin(async { wrap_test(tier2_inspect_tree_invalid_depth_zero()).await })),
            ("test_tier2_inspect_tree_nonexistent_root", || Box::pin(async { wrap_test(tier2_inspect_tree_nonexistent_root()).await })),
            ("test_tier2_resource_read_invalid_uri", || Box::pin(async { wrap_test(tier2_resource_read_invalid_uri()).await })),
            ("test_tier2_acp_unknown_action", || Box::pin(async { wrap_test(tier2_acp_unknown_action()).await })),
            ("test_tier2_concurrent_burst_requests", || Box::pin(async { wrap_test(tier2_concurrent_burst_requests()).await })),
        ],
        3 => vec![
            ("test_tier3_inspect_click_verify_state", || Box::pin(async { wrap_test(tier3_inspect_click_verify_state()).await })),
            ("test_tier3_inspect_send_keys_verify_state", || Box::pin(async { wrap_test(tier3_inspect_send_keys_verify_state()).await })),
            ("test_tier3_send_keys_then_click_action", || Box::pin(async { wrap_test(tier3_send_keys_then_click_action()).await })),
            ("test_tier3_inspect_bounds_coordinate_click", || Box::pin(async { wrap_test(tier3_inspect_bounds_coordinate_click()).await })),
            ("test_tier3_click_theme_toggle_and_capture_screenshot", || Box::pin(async { wrap_test(tier3_click_theme_toggle_and_capture_screenshot()).await })),
            ("test_tier3_send_keys_overwrite_fidelity", || Box::pin(async { wrap_test(tier3_send_keys_overwrite_fidelity()).await })),
            ("test_tier3_resource_read_after_agent_actions", || Box::pin(async { wrap_test(tier3_resource_read_after_agent_actions()).await })),
            ("test_tier3_acp_dispatch_interaction_with_mcp_client", || Box::pin(async { wrap_test(tier3_acp_dispatch_interaction_with_mcp_client()).await })),
        ],
        4 => vec![
            ("test_tier4_showcase_tab_navigation", || Box::pin(async { wrap_test(tier4_showcase_tab_navigation()).await })),
            ("test_tier4_showcase_form_automation", || Box::pin(async { wrap_test(tier4_showcase_form_automation()).await })),
            ("test_tier4_showcase_compute_start_and_query_concurrent", || Box::pin(async { wrap_test(tier4_showcase_compute_start_and_query_concurrent()).await })),
            ("test_tier4_showcase_compute_cancel_workload", || Box::pin(async { wrap_test(tier4_showcase_compute_cancel_workload()).await })),
            ("test_tier4_showcase_theme_toggle_visual_verification", || Box::pin(async { wrap_test(tier4_showcase_theme_toggle_visual_verification()).await })),
            ("test_tier4_showcase_multi_threaded_non_blocking_stress", || Box::pin(async { wrap_test(tier4_showcase_multi_threaded_non_blocking_stress()).await })),
            ("test_tier4_showcase_full_remote_control_tour", || Box::pin(async { wrap_test(tier4_showcase_full_remote_control_tour()).await })),
        ],
        _ => vec![],
    }
}

async fn wrap_test<F: std::future::Future<Output = ()> + Send + 'static>(fut: F) -> Result<(), String> {
    tokio::spawn(fut)
        .await
        .map_err(|e| format!("Panic or Task failure: {:?}", e))
}

// Re-exports of test functions for runner execution
async fn tier1_mcp_initialize_handshake() { crate::tier1_feature_coverage::run_test_tier1_mcp_initialize_handshake().await; }
async fn tier1_mcp_initialized_notification() { crate::tier1_feature_coverage::run_test_tier1_mcp_initialized_notification().await; }
async fn tier1_mcp_ping() { crate::tier1_feature_coverage::run_test_tier1_mcp_ping().await; }
async fn tier1_mcp_tools_list_count_and_names() { crate::tier1_feature_coverage::run_test_tier1_mcp_tools_list_count_and_names().await; }
async fn tier1_mcp_tools_schemas() { crate::tier1_feature_coverage::run_test_tier1_mcp_tools_schemas().await; }
async fn tier1_get_screenshot_png_format() { crate::tier1_feature_coverage::run_test_tier1_get_screenshot_png_format().await; }
async fn tier1_get_screenshot_dimensions() { crate::tier1_feature_coverage::run_test_tier1_get_screenshot_dimensions().await; }
async fn tier1_get_screenshot_png_magic_bytes() { crate::tier1_feature_coverage::run_test_tier1_get_screenshot_png_magic_bytes().await; }
async fn tier1_get_screenshot_custom_mime_param() { crate::tier1_feature_coverage::run_test_tier1_get_screenshot_custom_mime_param().await; }
async fn tier1_get_screenshot_non_empty_payload() { crate::tier1_feature_coverage::run_test_tier1_get_screenshot_non_empty_payload().await; }
async fn tier1_inspect_tree_root() { crate::tier1_feature_coverage::run_test_tier1_inspect_tree_root().await; }
async fn tier1_inspect_tree_hierarchy_nodes() { crate::tier1_feature_coverage::run_test_tier1_inspect_tree_hierarchy_nodes().await; }
async fn tier1_inspect_tree_element_roles_and_labels() { crate::tier1_feature_coverage::run_test_tier1_inspect_tree_element_roles_and_labels().await; }
async fn tier1_inspect_tree_filter_by_root_id() { crate::tier1_feature_coverage::run_test_tier1_inspect_tree_filter_by_root_id().await; }
async fn tier1_inspect_tree_max_depth() { crate::tier1_feature_coverage::run_test_tier1_inspect_tree_max_depth().await; }
async fn tier1_click_element_by_id() { crate::tier1_feature_coverage::run_test_tier1_click_element_by_id().await; }
async fn tier1_click_element_by_label() { crate::tier1_feature_coverage::run_test_tier1_click_element_by_label().await; }
async fn tier1_click_element_by_coordinates() { crate::tier1_feature_coverage::run_test_tier1_click_element_by_coordinates().await; }
async fn tier1_click_element_switch_toggle() { crate::tier1_feature_coverage::run_test_tier1_click_element_switch_toggle().await; }
async fn tier1_click_element_double_click() { crate::tier1_feature_coverage::run_test_tier1_click_element_double_click().await; }
async fn tier1_send_keys_to_input_field() { crate::tier1_feature_coverage::run_test_tier1_send_keys_to_input_field().await; }
async fn tier1_send_keys_with_clear_first() { crate::tier1_feature_coverage::run_test_tier1_send_keys_with_clear_first().await; }
async fn tier1_send_keys_append_without_clear() { crate::tier1_feature_coverage::run_test_tier1_send_keys_append_without_clear().await; }
async fn tier1_send_keys_to_textarea() { crate::tier1_feature_coverage::run_test_tier1_send_keys_to_textarea().await; }
async fn tier1_send_keys_special_symbols() { crate::tier1_feature_coverage::run_test_tier1_send_keys_special_symbols().await; }
async fn tier1_get_state_full() { crate::tier1_feature_coverage::run_test_tier1_get_state_full().await; }
async fn tier1_get_state_filtered_keys() { crate::tier1_feature_coverage::run_test_tier1_get_state_filtered_keys().await; }
async fn tier1_get_state_active_view() { crate::tier1_feature_coverage::run_test_tier1_get_state_active_view().await; }
async fn tier1_get_state_compute_fields() { crate::tier1_feature_coverage::run_test_tier1_get_state_compute_fields().await; }
async fn tier1_get_state_timestamp() { crate::tier1_feature_coverage::run_test_tier1_get_state_timestamp().await; }
async fn tier1_resources_list() { crate::tier1_feature_coverage::run_test_tier1_resources_list().await; }
async fn tier1_resources_read_context() { crate::tier1_feature_coverage::run_test_tier1_resources_read_context().await; }
async fn tier1_resources_read_logs() { crate::tier1_feature_coverage::run_test_tier1_resources_read_logs().await; }
async fn tier1_acp_message_query_state() { crate::tier1_feature_coverage::run_test_tier1_acp_message_query_state().await; }
async fn tier1_acp_message_command_click() { crate::tier1_feature_coverage::run_test_tier1_acp_message_command_click().await; }
async fn tier1_acp_message_send_keys() { crate::tier1_feature_coverage::run_test_tier1_acp_message_send_keys().await; }

async fn tier2_malformed_json_syntax() { crate::tier2_boundary_corner::run_test_tier2_malformed_json_syntax().await; }
async fn tier2_invalid_request_structure() { crate::tier2_boundary_corner::run_test_tier2_invalid_request_structure().await; }
async fn tier2_unknown_jsonrpc_method() { crate::tier2_boundary_corner::run_test_tier2_unknown_jsonrpc_method().await; }
async fn tier2_unknown_mcp_tool() { crate::tier2_boundary_corner::run_test_tier2_unknown_mcp_tool().await; }
async fn tier2_send_keys_missing_text_param() { crate::tier2_boundary_corner::run_test_tier2_send_keys_missing_text_param().await; }
async fn tier2_click_element_missing_target() { crate::tier2_boundary_corner::run_test_tier2_click_element_missing_target().await; }
async fn tier2_click_element_negative_coordinates() { crate::tier2_boundary_corner::run_test_tier2_click_element_negative_coordinates().await; }
async fn tier2_click_element_extreme_out_of_bounds_coords() { crate::tier2_boundary_corner::run_test_tier2_click_element_extreme_out_of_bounds_coords().await; }
async fn tier2_click_element_nonexistent_id() { crate::tier2_boundary_corner::run_test_tier2_click_element_nonexistent_id().await; }
async fn tier2_send_keys_to_non_editable_element() { crate::tier2_boundary_corner::run_test_tier2_send_keys_to_non_editable_element().await; }
async fn tier2_inspect_tree_invalid_depth_zero() { crate::tier2_boundary_corner::run_test_tier2_inspect_tree_invalid_depth_zero().await; }
async fn tier2_inspect_tree_nonexistent_root() { crate::tier2_boundary_corner::run_test_tier2_inspect_tree_nonexistent_root().await; }
async fn tier2_resource_read_invalid_uri() { crate::tier2_boundary_corner::run_test_tier2_resource_read_invalid_uri().await; }
async fn tier2_acp_unknown_action() { crate::tier2_boundary_corner::run_test_tier2_acp_unknown_action().await; }
async fn tier2_concurrent_burst_requests() { crate::tier2_boundary_corner::run_test_tier2_concurrent_burst_requests().await; }

async fn tier3_inspect_click_verify_state() { crate::tier3_cross_feature::run_test_tier3_inspect_click_verify_state().await; }
async fn tier3_inspect_send_keys_verify_state() { crate::tier3_cross_feature::run_test_tier3_inspect_send_keys_verify_state().await; }
async fn tier3_send_keys_then_click_action() { crate::tier3_cross_feature::run_test_tier3_send_keys_then_click_action().await; }
async fn tier3_inspect_bounds_coordinate_click() { crate::tier3_cross_feature::run_test_tier3_inspect_bounds_coordinate_click().await; }
async fn tier3_click_theme_toggle_and_capture_screenshot() { crate::tier3_cross_feature::run_test_tier3_click_theme_toggle_and_capture_screenshot().await; }
async fn tier3_send_keys_overwrite_fidelity() { crate::tier3_cross_feature::run_test_tier3_send_keys_overwrite_fidelity().await; }
async fn tier3_resource_read_after_agent_actions() { crate::tier3_cross_feature::run_test_tier3_resource_read_after_agent_actions().await; }
async fn tier3_acp_dispatch_interaction_with_mcp_client() { crate::tier3_cross_feature::run_test_tier3_acp_dispatch_interaction_with_mcp_client().await; }

async fn tier4_showcase_tab_navigation() { crate::tier4_showcase_workloads::run_test_tier4_showcase_tab_navigation().await; }
async fn tier4_showcase_form_automation() { crate::tier4_showcase_workloads::run_test_tier4_showcase_form_automation().await; }
async fn tier4_showcase_compute_start_and_query_concurrent() { crate::tier4_showcase_workloads::run_test_tier4_showcase_compute_start_and_query_concurrent().await; }
async fn tier4_showcase_compute_cancel_workload() { crate::tier4_showcase_workloads::run_test_tier4_showcase_compute_cancel_workload().await; }
async fn tier4_showcase_theme_toggle_visual_verification() { crate::tier4_showcase_workloads::run_test_tier4_showcase_theme_toggle_visual_verification().await; }
async fn tier4_showcase_multi_threaded_non_blocking_stress() { crate::tier4_showcase_workloads::run_test_tier4_showcase_multi_threaded_non_blocking_stress().await; }
async fn tier4_showcase_full_remote_control_tour() { crate::tier4_showcase_workloads::run_test_tier4_showcase_full_remote_control_tour().await; }
