//! Empirical Challenger Verification Tests for Milestone 3 Re-Gate:
//! 1. Showcase Counter single increment per click (+1, not +2) via agent remote click
//! 2. Compute concurrency defense: repeated start clicks reject with AgentError::invalid_operation
//! 3. Compute cancellation immediately invalidates callbacks and restarts cleanly without thrashing
//! 4. Screenshot non-blocking event loop behavior: offloaded Deflate compression allows interleaved UI operations

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;

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

/// Asynchronous test client driving `slate-showcase` over stdio MCP.
struct StdioShowcaseClient {
    child: Child,
    stdin: ChildStdin,
    stdout_lines: Arc<Mutex<tokio::io::Lines<BufReader<ChildStdout>>>>,
    req_counter: AtomicU64,
}

impl StdioShowcaseClient {
    pub async fn spawn() -> Self {
        let bin = get_showcase_binary();
        let mut child = Command::new(&bin)
            .args(["--headless", "--agent"])
            .env("SLINT_BACKEND", "software")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("Failed to spawn slate-showcase");

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
                    "clientInfo": { "name": "empirical-challenger", "version": "1.0" }
                }
            }))
            .await;
        assert!(
            init_resp["result"]["serverInfo"]["name"] == "slate-mcp",
            "MCP Handshake failed: {:?}",
            init_resp
        );

        client
    }

    pub async fn send_raw(&mut self, req: serde_json::Value) -> serde_json::Value {
        let req_str = format!("{}\n", serde_json::to_string(&req).unwrap());
        self.stdin
            .write_all(req_str.as_bytes())
            .await
            .expect("write to child stdin failed");
        self.stdin.flush().await.expect("flush stdin failed");

        let mut lines = self.stdout_lines.lock().await;
        let line = tokio::time::timeout(Duration::from_secs(5), lines.next_line())
            .await
            .expect("Timeout waiting for response")
            .expect("read line error")
            .expect("EOF from child process");

        serde_json::from_str(&line).expect("JSON-RPC parse error")
    }

    pub async fn send_line_unawaited(&mut self, req: serde_json::Value) {
        let req_str = format!("{}\n", serde_json::to_string(&req).unwrap());
        self.stdin
            .write_all(req_str.as_bytes())
            .await
            .expect("write to child stdin failed");
        self.stdin.flush().await.expect("flush stdin failed");
    }

    pub async fn read_next_response(&self) -> serde_json::Value {
        let mut lines = self.stdout_lines.lock().await;
        let line = tokio::time::timeout(Duration::from_secs(5), lines.next_line())
            .await
            .expect("Timeout waiting for response")
            .expect("read line error")
            .expect("EOF from child process");

        serde_json::from_str(&line).expect("JSON-RPC parse error")
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

        let resp = self.send_raw(req).await;
        let is_error = resp["result"]["isError"].as_bool().unwrap_or(false);
        (is_error, resp["result"].clone())
    }

    pub async fn get_state(&mut self) -> serde_json::Value {
        let (is_err, result) = self.call_tool("get_state", serde_json::json!({})).await;
        assert!(!is_err, "get_state returned error: {:?}", result);
        let text = result["content"][0]["text"].as_str().expect("text content");
        serde_json::from_str(text).expect("parsed app state")
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

    pub async fn click_label(&mut self, label: &str) -> (bool, String) {
        let (is_err, result) = self
            .call_tool("click_element", serde_json::json!({ "label": label }))
            .await;
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or("")
            .to_string();
        (is_err, text)
    }
}

impl Drop for StdioShowcaseClient {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

// ============================================================================
// TEST 1: Counter Single Increment Per Click (+1, Not +2)
// ============================================================================

#[tokio::test]
async fn test_empirical_counter_single_increment_per_click() {
    let mut client = StdioShowcaseClient::spawn().await;

    // 1. Initial counter state
    let state0 = client.get_state().await;
    let counter0 = state0["properties"]["counter"]
        .as_i64()
        .expect("counter property");
    assert_eq!(counter0, 0, "Precondition: initial counter must be 0");

    // 2. Click 1: Increment by element ID
    let (is_err, text) = client.click("increment_counter_btn").await;
    assert!(!is_err, "Click on increment_counter_btn failed: {}", text);
    assert!(
        text.contains("\"details\":\"Counter is now 1\""),
        "Click result must report Counter is now 1, got: {}",
        text
    );

    let state1 = client.get_state().await;
    let counter1 = state1["properties"]["counter"].as_i64().unwrap();
    assert_eq!(
        counter1, 1,
        "Empirical check: Counter after 1 click must be exactly 1 (+1, NOT +2)"
    );

    // 3. Repeated sequential clicks (10 clicks)
    for expected in 2..=11 {
        let (is_err, text) = client.click("increment_counter_btn").await;
        assert!(!is_err, "Sequential click failed on step {}", expected);
        assert!(
            text.contains(&format!("\"details\":\"Counter is now {}\"", expected)),
            "Expected details 'Counter is now {}', got: {}",
            expected,
            text
        );

        let s = client.get_state().await;
        let c = s["properties"]["counter"].as_i64().unwrap();
        assert_eq!(
            c, expected,
            "Sequential step {}: counter must be exactly {}, got {}",
            expected, expected, c
        );
    }

    // 4. Click by label "Interactive Counter"
    let (is_err, text) = client.click_label("Interactive Counter").await;
    assert!(!is_err, "Click by label failed: {}", text);
    assert!(text.contains("\"details\":\"Counter is now 12\""));
    let s_label = client.get_state().await;
    assert_eq!(s_label["properties"]["counter"].as_i64().unwrap(), 12);

    // 5. Click by dynamic label "Count: 12"
    let (is_err, text) = client.click_label("Count: 12").await;
    assert!(!is_err, "Click by Count prefix failed: {}", text);
    assert!(text.contains("\"details\":\"Counter is now 13\""));
    let s_dyn = client.get_state().await;
    assert_eq!(s_dyn["properties"]["counter"].as_i64().unwrap(), 13);
}

// ============================================================================
// TEST 2: Compute Concurrency Defense & Re-Trigger Guards
// ============================================================================

#[tokio::test]
async fn test_empirical_compute_concurrency_guard_and_rejection() {
    let mut client = StdioShowcaseClient::spawn().await;

    // 1. Precondition: Compute is idle
    let s0 = client.get_state().await;
    assert_eq!(s0["properties"]["compute_running"], false);
    assert_eq!(s0["properties"]["compute_status"], "Ready");

    // 2. Guard against cancelling while idle
    let (is_err, err_msg) = client.click("cancel_compute_btn").await;
    assert!(
        is_err,
        "Clicking cancel_compute_btn while idle must be rejected"
    );
    assert!(
        err_msg.contains("No compute task is currently running to cancel"),
        "Expected idle cancel error, got: {}",
        err_msg
    );

    // 3. Start compute task
    let (is_err, text) = client.click("start_compute_btn").await;
    assert!(!is_err, "start_compute_btn failed: {}", text);

    let s1 = client.get_state().await;
    assert_eq!(s1["properties"]["compute_running"], true);
    assert_eq!(s1["properties"]["compute_status"], "Computing");

    // 4. Concurrency Guard: Repeated clicks on start_compute_btn while running
    // Must return an error without spawning orphaned compute threads
    for i in 1..=5 {
        let (is_err, err_msg) = client.click("start_compute_btn").await;
        assert!(
            is_err,
            "Attempt {} to re-trigger compute while running must reject with error",
            i
        );
        assert!(
            err_msg.contains("Compute benchmark is already running (start_compute_btn is disabled)"),
            "Attempt {} returned unexpected message: {}",
            i,
            err_msg
        );
    }

    // 5. Clean teardown: if still running, cancel; otherwise verify it completed cleanly
    let s_end = client.get_state().await;
    if s_end["properties"]["compute_running"] == true {
        let (is_err, _) = client.click("cancel_compute_btn").await;
        assert!(!is_err, "Teardown cancel failed while running");
    } else {
        assert_eq!(s_end["properties"]["compute_status"], "Completed");
    }
}

// ============================================================================
// TEST 3: Compute Cancellation & Clean Restart Without Thrashing
// ============================================================================

#[tokio::test]
async fn test_empirical_compute_cancellation_and_clean_restart() {
    let mut client = StdioShowcaseClient::spawn().await;

    // 1. Start compute
    let (is_err, _) = client.click("start_compute_btn").await;
    assert!(!is_err);

    let s_run = client.get_state().await;
    assert_eq!(s_run["properties"]["compute_running"], true);

    // 2. Cancel compute immediately
    let (is_err, cancel_text) = client.click("cancel_compute_btn").await;
    assert!(!is_err, "Cancel failed: {}", cancel_text);

    // 3. Immediate state check
    let s_canc = client.get_state().await;
    assert_eq!(
        s_canc["properties"]["compute_running"], false,
        "compute_running must be false immediately upon cancellation"
    );
    assert_eq!(
        s_canc["properties"]["compute_status"], "Cancelled",
        "compute_status must be 'Cancelled'"
    );
    assert_eq!(
        s_canc["properties"]["compute_result"], "Computation was cancelled",
        "compute_result must be 'Computation was cancelled'"
    );

    // 4. Wait 250ms to verify trailing callbacks do NOT overwrite Cancelled state
    tokio::time::sleep(Duration::from_millis(250)).await;
    let s_wait = client.get_state().await;
    assert_eq!(
        s_wait["properties"]["compute_running"], false,
        "Trailing callback must not set compute_running to true"
    );
    assert_eq!(
        s_wait["properties"]["compute_status"], "Cancelled",
        "Trailing callback must not overwrite 'Cancelled' status"
    );
    assert_eq!(
        s_wait["properties"]["compute_result"], "Computation was cancelled",
        "Trailing completion must not overwrite result message"
    );

    // 5. Re-run compute restarts cleanly
    let (is_err, restart_text) = client.click("start_compute_btn").await;
    assert!(!is_err, "Restart compute failed: {}", restart_text);

    let s_restart = client.get_state().await;
    assert_eq!(
        s_restart["properties"]["compute_running"], true,
        "Restarted compute must be running"
    );
    assert_eq!(
        s_restart["properties"]["compute_status"], "Computing",
        "Restarted compute status must be 'Computing'"
    );

    let progress = s_restart["properties"]["compute_progress"]
        .as_f64()
        .unwrap();
    assert!(
        progress >= 0.0 && progress <= 1.0,
        "Progress must start valid (got {})",
        progress
    );

    // Clean cancel
    let _ = client.click("cancel_compute_btn").await;
}

// ============================================================================
// TEST 4: Screenshot Performance & Non-Blocking Event Loop Behavior
// ============================================================================

#[tokio::test]
async fn test_empirical_screenshot_non_blocking_event_loop() {
    let mut client = StdioShowcaseClient::spawn().await;

    // 1. Call get_screenshot and verify valid PNG bytes and geometry
    let (is_err, shot_result) = client
        .call_tool("get_screenshot", serde_json::json!({}))
        .await;
    assert!(!is_err, "get_screenshot failed: {:?}", shot_result);

    let content = &shot_result["content"][0];
    assert_eq!(content["type"], "image");
    assert_eq!(content["mimeType"], "png");

    let b64_data = content["data"].as_str().expect("base64 image data");
    assert!(!b64_data.is_empty(), "base64 image data cannot be empty");

    let raw_bytes = base64_decode_simple(b64_data);
    assert!(raw_bytes.len() > 100, "PNG image data too small");

    // Verify PNG magic signature: [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A]
    let magic = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    assert_eq!(
        &raw_bytes[..8],
        &magic,
        "Snapshot does not have valid PNG magic signature"
    );

    // 2. Empirical Verification of Non-Blocking Behavior:
    // Dispatch `get_screenshot` (request id 500) and immediately dispatch `get_state` (request id 501).
    // Because PNG Deflate compression is offloaded to tokio::task::spawn_blocking,
    // the UI thread is freed immediately after raw pixel copy.
    // Consequently, `get_state` must be processed and returned promptly,
    // demonstrating that screenshot compression does not stall the Slint event loop.
    let shot_req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 500,
        "method": "tools/call",
        "params": { "name": "get_screenshot", "arguments": {} }
    });
    let state_req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 501,
        "method": "tools/call",
        "params": { "name": "get_state", "arguments": {} }
    });

    let t0 = Instant::now();
    client.send_line_unawaited(shot_req).await;
    // Small yield to let shot_req be received
    tokio::time::sleep(Duration::from_millis(5)).await;
    client.send_line_unawaited(state_req).await;

    // Receive first response
    let resp1 = client.read_next_response().await;
    let t_first = t0.elapsed();

    // Receive second response
    let resp2 = client.read_next_response().await;
    let t_second = t0.elapsed();

    println!(
        "Screenshot concurrency timing: first resp={:?} (id={}) in {:?}, second resp={:?} (id={}) in {:?}",
        resp1.get("result").is_some(),
        resp1["id"],
        t_first,
        resp2.get("result").is_some(),
        resp2["id"],
        t_second
    );

    // Both requests must succeed without error
    assert_eq!(resp1["result"]["isError"], false);
    assert_eq!(resp2["result"]["isError"], false);

    // Out-of-order execution verification:
    // id 501 (get_state) completes significantly faster than id 500 (get_screenshot)
    // because screenshot PNG Deflate is offloaded to spawn_blocking!
    let (first_id, second_id) = (resp1["id"].as_i64().unwrap(), resp2["id"].as_i64().unwrap());
    assert_eq!(first_id, 501, "get_state (id 501) must return FIRST, proving non-blocking event loop");
    assert_eq!(second_id, 500, "get_screenshot (id 500) must return SECOND after offloaded Deflate completes");

    // 3. Sequential burst stress: 3 screenshots in sequence
    for i in 1..=3 {
        let (is_err, burst_shot) = client
            .call_tool("get_screenshot", serde_json::json!({}))
            .await;
        assert!(!is_err, "Burst screenshot {} failed", i);
        let b64 = burst_shot["content"][0]["data"].as_str().unwrap();
        let bytes = base64_decode_simple(b64);
        assert_eq!(&bytes[..8], &magic, "Burst screenshot {} magic failed", i);
    }
}

/// Simple base64 decoding helper without external crate dependencies.
fn base64_decode_simple(input: &str) -> Vec<u8> {
    let mut out = Vec::new();
    let mut buf = 0u32;
    let mut bits = 0u32;

    for b in input.bytes() {
        let val = match b {
            b'A'..=b'Z' => (b - b'A') as u32,
            b'a'..=b'z' => (b - b'a' + 26) as u32,
            b'0'..=b'9' => (b - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            b'=' | b'\r' | b'\n' | b' ' => continue,
            _ => continue,
        };
        buf = (buf << 6) | val;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }

    out
}
