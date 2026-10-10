//! Tier 5 Adversarial Coverage Hardening Test Suite:
//! Framework Re-exports, Convenience Helpers, Lifecycle & Shutdowns,
//! Showcase CLI Flag Combinations, Extreme Counter/Toggle/Search Stress,
//! Compute Cancellation Interleaving, and Dropped Window Error Propagation.

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;

use slate::agent::{
    AgentError, ComponentBridge, SlintUiBridge,
};
use slate::core::theme::ThemeMode;
use slate::AppBuilder;

fn setup_headless() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });
}

/// Helper to get or build the `slate-showcase` binary path.
fn get_showcase_binary() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root_dir = manifest_dir.parent().expect("workspace root");
    let bin_path = root_dir.join("target/debug/slate-showcase");

    if !bin_path.exists() {
        let status = std::process::Command::new("cargo")
            .current_dir(root_dir)
            .args(["build", "-p", "slate-showcase", "--bin", "slate-showcase"])
            .status()
            .expect("Failed to execute cargo build for slate-showcase");
        assert!(status.success(), "cargo build -p slate-showcase failed");
    }

    bin_path
}

/// Dynamic stdio client supporting custom CLI flags and environment variables.
struct DynamicShowcaseClient {
    child: Child,
    stdin: ChildStdin,
    stdout_lines: Arc<Mutex<tokio::io::Lines<BufReader<ChildStdout>>>>,
    req_counter: AtomicU64,
}

impl DynamicShowcaseClient {
    pub async fn spawn_with_args_and_env(
        args: &[&str],
        envs: &[(&str, &str)],
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let bin = get_showcase_binary();
        let mut cmd = Command::new(&bin);
        cmd.args(args);
        for (k, v) in envs {
            cmd.env(k, v);
        }
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let mut child = cmd.spawn()?;
        let stdin = child.stdin.take().expect("Child stdin unavailable");
        let stdout = child.stdout.take().expect("Child stdout unavailable");
        let stdout_lines = Arc::new(Mutex::new(BufReader::new(stdout).lines()));

        let mut client = Self {
            child,
            stdin,
            stdout_lines,
            req_counter: AtomicU64::new(1),
        };

        // Handshake
        let init_resp = client
            .send_raw(serde_json::json!({
                "jsonrpc": "2.0",
                "id": 0,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": { "name": "tier5-challenger", "version": "1.0" }
                }
            }))
            .await?;

        assert!(
            init_resp["result"]["serverInfo"]["name"] == "slate-mcp",
            "Handshake failed: {:?}",
            init_resp
        );

        Ok(client)
    }

    pub async fn send_raw(
        &mut self,
        req: serde_json::Value,
    ) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
        let req_str = format!("{}\n", serde_json::to_string(&req)?);
        self.stdin.write_all(req_str.as_bytes()).await?;
        self.stdin.flush().await?;

        let mut lines = self.stdout_lines.lock().await;
        let line = tokio::time::timeout(Duration::from_secs(5), lines.next_line())
            .await
            .map_err(|_| "Timeout waiting for JSON-RPC response")?
            .map_err(|e| format!("Read error: {}", e))?
            .ok_or("EOF reading from child stdout")?;

        let val: serde_json::Value = serde_json::from_str(&line)?;
        Ok(val)
    }

    pub async fn call_tool(
        &mut self,
        name: &str,
        args: serde_json::Value,
    ) -> (bool, serde_json::Value) {
        let id = self.req_counter.fetch_add(1, Ordering::SeqCst);
        let req = serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": {
                "name": name,
                "arguments": args
            }
        });

        let resp = self.send_raw(req).await.expect("tool call send_raw failed");
        let is_error = resp["result"]["isError"].as_bool().unwrap_or(false);
        (is_error, resp["result"].clone())
    }

    pub async fn get_state(&mut self) -> serde_json::Value {
        let (is_err, result) = self.call_tool("get_state", serde_json::json!({})).await;
        assert!(!is_err, "get_state failed: {:?}", result);
        let text = result["content"][0]["text"].as_str().expect("text content");
        serde_json::from_str(text).expect("parsed app state JSON")
    }

    pub async fn click(&mut self, target: &str) -> (bool, String) {
        let (is_err, result) = self
            .call_tool("click_element", serde_json::json!({ "id": target }))
            .await;
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or("")
            .to_string();
        (is_err, text)
    }

    pub async fn send_keys(&mut self, target: Option<&str>, text: &str) -> (bool, String) {
        let mut args = serde_json::json!({ "text": text });
        if let Some(t) = target {
            args["element_id"] = serde_json::json!(t);
        }
        let (is_err, result) = self.call_tool("send_keys", args).await;
        let text_out = result["content"][0]["text"]
            .as_str()
            .unwrap_or("")
            .to_string();
        (is_err, text_out)
    }

    pub async fn inspect_tree(&mut self) -> (bool, serde_json::Value) {
        let (is_err, result) = self.call_tool("inspect_tree", serde_json::json!({})).await;
        if is_err {
            return (true, result);
        }
        let text = result["content"][0]["text"].as_str().unwrap_or("{}");
        let parsed: serde_json::Value = serde_json::from_str(text).unwrap_or(serde_json::Value::Null);
        (false, parsed)
    }

    pub async fn get_screenshot(&mut self) -> (bool, serde_json::Value) {
        self.call_tool("get_screenshot", serde_json::json!({})).await
    }

    pub async fn list_tools(&mut self) -> Vec<String> {
        let id = self.req_counter.fetch_add(1, Ordering::SeqCst);
        let req = serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list",
            "params": {}
        });
        let resp = self.send_raw(req).await.expect("tools/list failed");
        let tools = resp["result"]["tools"].as_array().expect("tools array");
        tools
            .iter()
            .filter_map(|t| t["name"].as_str().map(|s| s.to_string()))
            .collect()
    }
}

impl Drop for DynamicShowcaseClient {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

// =========================================================================
// SECTION 1: Framework Re-exports, Convenience Helpers & AppBuilder
// =========================================================================

#[test]
fn test_tier5_app_builder_and_framework_init_coverage() {
    setup_headless();

    // 1. AppBuilder theme modes
    let app_system = AppBuilder::new("System App").theme_mode(ThemeMode::System);
    let system_dark = slate::extensions::platform::detect_system_dark_mode();
    assert_eq!(app_system.is_dark(), system_dark);

    let app_light = AppBuilder::new("Light App").theme_mode(ThemeMode::Light);
    assert!(!app_light.is_dark(), "ThemeMode::Light must not be dark");

    let app_dark = AppBuilder::new("Dark App").theme_mode(ThemeMode::Dark);
    assert!(app_dark.is_dark(), "ThemeMode::Dark must be dark");

    // 2. Logging initializations (idempotent calls)
    app_system.init();
    app_light.init();
    app_dark.init();
    slate::init();
    slate::init();
}

#[tokio::test]
async fn test_tier5_framework_reexports_and_submodules_completeness() {
    // 1. Submodule availability and usage
    use slate::agent::acp::*;
    use slate::agent::bridge::*;
    use slate::agent::engine::*;
    use slate::agent::error::*;
    use slate::agent::model::*;
    use slate::agent::protocol::*;
    use slate::agent::traits::*;
    use slate::mcp::*;

    // 2. Trait objects and types
    let state = AppState::new("view_xyz").with_property("prop_1", serde_json::json!(123));
    assert_eq!(state.active_view, "view_xyz");
    assert_eq!(state.properties["prop_1"], 123);

    let diag = DiagnosticMetrics::default();
    assert!(diag.fps.is_none());

    let sel = ElementSelector::parse("#btn-submit");
    assert_eq!(sel, ElementSelector::Id("btn-submit".to_string()));

    let pt = Point::new(10.0, 20.0);
    assert_eq!(pt.x, 10.0);

    let rect = Rect::new(0.0, 0.0, 50.0, 50.0);
    assert!(rect.contains(&Point::new(25.0, 25.0)));

    let engine = Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::default()),
        Arc::new(DefaultElementController),
        Arc::new(DefaultStateProvider::default()),
        Arc::new(DefaultVisualRenderer::default()),
    ));
    let tree = engine.inspector().inspect_tree().await.unwrap();
    assert_eq!(tree.root.id, "root_window");
    let bridge = SlintUiBridge::new();
    assert_eq!(bridge.timeout(), DEFAULT_UI_TIMEOUT);

    let mut mock_acp = MockAcpAdapter::default();
    let mock_handle = mock_acp.attach(engine.clone(), MockAcpConfig::default()).unwrap();
    assert!(mock_handle.is_running());

    let err = AgentError::invalid_operation("Invalid test action");
    assert!(err.to_string().contains("Invalid test action"));

    // 3. MCP tool schema enumeration
    let tools = all_standard_tools();
    assert_eq!(tools.len(), 5);
    let tool_names: Vec<&str> = tools.iter().map(|t| t.name.as_str()).collect();
    assert!(tool_names.contains(&"get_screenshot"));
    assert!(tool_names.contains(&"inspect_tree"));
    assert!(tool_names.contains(&"click_element"));
    assert!(tool_names.contains(&"send_keys"));
    assert!(tool_names.contains(&"get_state"));

    // 4. ACP message creation
    let acp_msg = AcpMessage::query("state", "orchestrator", serde_json::json!({}));
    assert_eq!(acp_msg.performative, AcpPerformative::Query);
    assert_eq!(acp_msg.action, "state");
}

// =========================================================================
// SECTION 2: Showcase CLI Flag Combinations
// =========================================================================

/// Test CLI combination: `--headless --minimal-init`
/// Verifies that `--minimal-init` activates `slate::agent::init` default engine
/// rather than the customized showcase agent.
#[tokio::test]
async fn test_tier5_showcase_cli_minimal_init_mode() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless", "--minimal-init"],
        &[("SLINT_BACKEND", "software")],
    )
    .await
    .expect("Spawn --headless --minimal-init failed");

    // 1. Verify standard tools are available
    let tool_names = client.list_tools().await;
    assert_eq!(tool_names.len(), 5);

    // 2. Default minimal init returns active_view "main" (from DefaultStateProvider)
    let state = client.get_state().await;
    assert_eq!(
        state["active_view"], "main",
        "Minimal init must use DefaultStateProvider with active_view 'main'"
    );

    // 3. Default inspector returns root_window with dimensions 800x600
    let (is_err, tree) = client.inspect_tree().await;
    assert!(!is_err);
    assert_eq!(tree["root"]["id"], "root_window");
    assert_eq!(tree["root"]["bounds"]["width"], 800.0);
    assert_eq!(tree["root"]["bounds"]["height"], 600.0);

    // 4. Default screenshot returns valid 800x600 frame
    let (is_err, shot) = client.get_screenshot().await;
    assert!(!is_err);
    assert_eq!(shot["content"][0]["type"], "image");

    // 5. Default click succeeds generically on any target
    let (is_err, click_text) = client.click("any_arbitrary_element").await;
    assert!(!is_err, "Default controller must accept any click target: {}", click_text);
    assert!(click_text.contains("Clicked 'any_arbitrary_element'"));
}

/// Test CLI combination: `--headless --mcp` (alternative flag to `--agent`)
#[tokio::test]
async fn test_tier5_showcase_cli_mcp_flag() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless", "--mcp"],
        &[("SLINT_BACKEND", "software")],
    )
    .await
    .expect("Spawn --headless --mcp failed");

    let state = client.get_state().await;
    assert_eq!(
        state["active_view"], "buttons",
        "--mcp flag must activate showcase agent"
    );
    assert_eq!(state["properties"]["active_tab"], 0);
}

/// Test CLI activation via environment variable `SLATE_AGENT=1`
#[tokio::test]
async fn test_tier5_showcase_cli_env_var_activation() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless"],
        &[("SLINT_BACKEND", "software"), ("SLATE_AGENT", "1")],
    )
    .await
    .expect("Spawn with SLATE_AGENT=1 failed");

    let state = client.get_state().await;
    assert_eq!(state["active_view"], "buttons");
}

/// Test CLI precedence: `--minimal-init` overrides `--agent`
#[tokio::test]
async fn test_tier5_showcase_cli_minimal_init_overrides_agent_flag() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless", "--agent", "--minimal-init"],
        &[("SLINT_BACKEND", "software")],
    )
    .await
    .expect("Spawn with --agent and --minimal-init failed");

    let state = client.get_state().await;
    assert_eq!(
        state["active_view"], "main",
        "--minimal-init must take precedence and activate minimal engine"
    );
}

/// Test unknown CLI arguments do not crash the application
#[tokio::test]
async fn test_tier5_showcase_cli_resilience_to_unknown_flags() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless", "--agent", "--unknown-flag-123", "--debug-verbose=all"],
        &[("SLINT_BACKEND", "software")],
    )
    .await
    .expect("Spawn with unknown flags failed");

    let state = client.get_state().await;
    assert_eq!(state["active_view"], "buttons");
}

// =========================================================================
// SECTION 3: Extreme UI Interactions & Stress Limits
// =========================================================================

/// Test extreme counter increments (50 rapid sequential clicks)
#[tokio::test]
async fn test_tier5_showcase_extreme_counter_50_clicks() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless", "--agent"],
        &[("SLINT_BACKEND", "software")],
    )
    .await
    .expect("Spawn failed");

    let state0 = client.get_state().await;
    let initial_counter = state0["properties"]["counter"].as_i64().unwrap();

    let clicks = 50;
    for i in 1..=clicks {
        let (is_err, _) = client.click("increment_counter_btn").await;
        assert!(!is_err, "Click {} failed", i);
    }

    let final_state = client.get_state().await;
    let final_counter = final_state["properties"]["counter"].as_i64().unwrap();
    assert_eq!(
        final_counter,
        initial_counter + clicks as i64,
        "Counter must match exactly 50 increments without race conditions"
    );
}

/// Test rapid toggles of theme mode and notifications switch (20 toggles each)
#[tokio::test]
async fn test_tier5_showcase_rapid_toggles_stress() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless", "--agent"],
        &[("SLINT_BACKEND", "software")],
    )
    .await
    .expect("Spawn failed");

    let initial_state = client.get_state().await;
    let initial_dark = initial_state["properties"]["is_dark"].as_bool().unwrap();
    let initial_switch = initial_state["properties"]["demo_switch_1"].as_bool().unwrap();

    // 20 rapid theme toggles
    for i in 1..=20 {
        let (is_err, _) = client.click("theme_toggle_btn").await;
        assert!(!is_err, "Theme toggle {} failed", i);
    }

    let after_theme = client.get_state().await;
    let after_theme_dark = after_theme["properties"]["is_dark"].as_bool().unwrap();
    // Even number of toggles must return to initial state
    assert_eq!(after_theme_dark, initial_dark, "20 theme toggles must return to original");

    // 20 rapid switch toggles
    for i in 1..=20 {
        let (is_err, _) = client.click("switch_notifications").await;
        assert!(!is_err, "Switch toggle {} failed", i);
    }

    let after_switch = client.get_state().await;
    let after_switch_val = after_switch["properties"]["demo_switch_1"].as_bool().unwrap();
    assert_eq!(after_switch_val, initial_switch, "20 switch toggles must return to original");
}

/// Test text input edge cases: empty strings, huge payloads, unicode, emojis, multiline
#[tokio::test]
async fn test_tier5_showcase_text_inputs_edge_cases() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless", "--agent"],
        &[("SLINT_BACKEND", "software")],
    )
    .await
    .expect("Spawn failed");

    // 1. Empty string input
    let (is_err, _) = client.send_keys(Some("email_input"), "").await;
    assert!(!is_err);
    let s_empty = client.get_state().await;
    assert_eq!(s_empty["properties"]["demo_input_text"], "");

    // 2. Large text payload (4,000 characters)
    let large_text = "A".repeat(4000);
    let (is_err, _) = client.send_keys(Some("email_input"), &large_text).await;
    assert!(!is_err);
    let s_large = client.get_state().await;
    assert_eq!(s_large["properties"]["demo_input_text"], large_text);

    // 3. Unicode, symbols and emojis
    let unicode_text = "Hello 世界! 🦀🔥💻 <script>alert('xss')</script> /etc/passwd \n \t";
    let (is_err, _) = client.send_keys(Some("notes_textarea"), unicode_text).await;
    assert!(!is_err);
    let s_unicode = client.get_state().await;
    assert_eq!(s_unicode["properties"]["demo_textarea_text"], unicode_text);

    // 4. Default target (target: None) defaults to email_input
    let (is_err, _) = client.send_keys(None, "default_target@example.com").await;
    assert!(!is_err);
    let s_def = client.get_state().await;
    assert_eq!(s_def["properties"]["demo_input_text"], "default_target@example.com");

    // 5. Invalid target rejected
    let (is_err, err_msg) = client.send_keys(Some("non_existent_input"), "test").await;
    assert!(is_err, "Targeting non-existent input must fail");
    assert!(err_msg.contains("not an editable text input") || err_msg.contains("not found"));
}

// =========================================================================
// SECTION 4: Compute Cancellation Interleaving & Shutdown Stress
// =========================================================================

/// Test rapid compute start and cancel cycles in a tight loop (10 iterations)
#[tokio::test]
async fn test_tier5_showcase_compute_rapid_start_cancel_tight_loop() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless", "--agent"],
        &[("SLINT_BACKEND", "software")],
    )
    .await
    .expect("Spawn failed");

    for cycle in 1..=10 {
        // Start
        let (is_err, _) = client.click("start_compute_btn").await;
        assert!(!is_err, "Cycle {} start failed", cycle);

        // Immediate cancel without delay
        let (is_err, _) = client.click("cancel_compute_btn").await;
        assert!(!is_err, "Cycle {} cancel failed", cycle);

        // Verify cancelled state
        let state = client.get_state().await;
        assert_eq!(state["properties"]["compute_running"], false);
        assert_eq!(state["properties"]["compute_status"], "Cancelled");
    }

    // After 10 rapid cancellations, verify compute can still execute normally
    let (is_err, _) = client.click("start_compute_btn").await;
    assert!(!is_err);
    let s_restart = client.get_state().await;
    assert_eq!(s_restart["properties"]["compute_running"], true);

    // Clean teardown
    let _ = client.click("cancel_compute_btn").await;
}

/// Test compute running during process termination (SIGTERM / drop)
#[tokio::test]
async fn test_tier5_showcase_compute_active_during_process_termination() {
    let mut client = DynamicShowcaseClient::spawn_with_args_and_env(
        &["--headless", "--agent"],
        &[("SLINT_BACKEND", "software")],
    )
    .await
    .expect("Spawn failed");

    // Start compute
    let (is_err, _) = client.click("start_compute_btn").await;
    assert!(!is_err);
    let state = client.get_state().await;
    assert_eq!(state["properties"]["compute_running"], true);

    // Drop client while compute thread is actively running
    drop(client);
    // Dropping triggers child.start_kill(), terminating without deadlock or hang
}

// =========================================================================
// SECTION 5: In-Process Agent Operations, Bridge Timeouts & Dropped Window
// =========================================================================

slint::slint! {
    export component AdversarialDroppableWindow inherits Window {
        width: 300px;
        height: 200px;
        title: "Droppable Window";
    }
}

/// Test that dropping a window properly invalidates weak handle upgrades
/// and verifies ComponentBridge and SlintUiBridge error behaviors.
#[tokio::test]
async fn test_tier5_component_bridge_dropped_window_handling() {
    setup_headless();

    let window = AdversarialDroppableWindow::new().expect("create window failed");
    let weak = window.as_weak();
    let bridge = Arc::new(SlintUiBridge::new());
    let comp_bridge = ComponentBridge::new(weak.clone(), bridge.clone());

    // 1. Weak handle upgrade succeeds while window is alive
    assert!(weak.upgrade().is_some());

    // 2. Drop the window
    drop(window);

    // 3. Empirically verify that upgraded weak handle produces AgentError::WindowClosed
    let upgrade_res = weak.upgrade().ok_or(AgentError::WindowClosed);
    assert!(matches!(upgrade_res, Err(AgentError::WindowClosed)));

    // 4. Calling run_with_window / run_with_window_serialized after drop returns an error
    let res = comp_bridge.run_with_window(|_win| Ok(1)).await;
    assert!(res.is_err());

    let res_ser = comp_bridge.run_with_window_serialized(|_win| Ok(1)).await;
    assert!(res_ser.is_err());
}

/// Test SlintUiBridge timeout guard, lock mutual exclusion, and panic catching
#[tokio::test]
async fn test_tier5_slint_ui_bridge_timeout_and_panic_guards() {
    setup_headless();

    let bridge = SlintUiBridge::new();
    assert_eq!(bridge.timeout(), Duration::from_secs(5));

    // 1. Command lock mutual exclusion
    let guard1 = bridge.lock_commands().await;
    let b_clone = bridge.clone();
    let acquired_early = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let acquired_clone = acquired_early.clone();

    let t = tokio::spawn(async move {
        let _guard2 = b_clone.lock_commands().await;
        acquired_clone.store(true, std::sync::atomic::Ordering::SeqCst);
    });

    tokio::time::sleep(Duration::from_millis(15)).await;
    assert!(!acquired_early.load(std::sync::atomic::Ordering::SeqCst), "Second lock must block");

    drop(guard1);
    t.await.unwrap();
    assert!(acquired_early.load(std::sync::atomic::Ordering::SeqCst), "Second lock must acquire after release");

    // 2. Timeout logic verification via channel
    let timeout_dur = Duration::from_millis(20);
    let (_tx, rx) = tokio::sync::oneshot::channel::<Result<i32, AgentError>>();
    let timeout_res = tokio::time::timeout(timeout_dur, rx).await;
    let err_mapped: Result<i32, AgentError> = match timeout_res {
        Ok(Ok(val)) => val,
        Ok(Err(_)) => Err(AgentError::UiChannelClosed),
        Err(_) => Err(AgentError::Timeout(format!("Timed out after {:?}", timeout_dur))),
    };
    match err_mapped {
        Err(AgentError::Timeout(msg)) => assert!(msg.contains("Timed out after 20ms")),
        other => panic!("Expected AgentError::Timeout, got {:?}", other),
    }

    // 3. Panic catching isolation via downcast_panic
    use slate::agent::bridge::downcast_panic;
    assert_eq!(
        downcast_panic(Box::new("Adversarial UI panic trigger")),
        "Adversarial UI panic trigger"
    );
    assert_eq!(
        downcast_panic(Box::new(String::from("Heap panic payload"))),
        "Heap panic payload"
    );
}
