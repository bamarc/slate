//! Empirical adversarial stress test harness for `slate::agent::init` and `slate::agent::builder`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::io::{duplex, AsyncBufReadExt, AsyncWriteExt, BufReader};

use slate::agent::{
    builder, init, AgentBuilderMcpExt,
};

slint::slint! {
    export component AdversarialStressWindow inherits Window {
        width: 400px;
        height: 300px;
        title: "Adversarial Stress Window";

        in-out property <int> counter: 0;
        in-out property <string> text_value: "initial";

        callback bump();
        bump => {
            root.counter += 1;
        }
    }
}

fn init_headless() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });
}

// =========================================================================
// CHALLENGE SUITE 1: Runtime Bootstrapping & Context Variations
// =========================================================================

/// Test 1.1: Call `slate::agent::init` from a synchronous thread without Tokio.
/// Verifies `ensure_tokio_runtime` cleanly bootstraps a multi-thread runtime.
#[test]
fn test_sync_init_bootstraps_tokio_runtime() {
    init_headless();
    let window = AdversarialStressWindow::new().expect("create window failed");
    let handle = init(&window).expect("init without Tokio failed");
    assert!(handle.is_running(), "handle must be running");
    assert_eq!(handle.local_addr(), Some("stdio://process".to_string()));

    // Verify runtime is now entered on this thread
    assert!(
        tokio::runtime::Handle::try_current().is_ok(),
        "Runtime must be entered on current thread"
    );

    handle.stop().expect("stop failed");
    assert!(!handle.is_running(), "handle must be stopped");
}

/// Test 1.2: Call `slate::agent::init` within an existing multi-threaded Tokio runtime.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_init_inside_existing_multithread_tokio() {
    init_headless();
    let window = AdversarialStressWindow::new().expect("create window failed");
    let handle = init(&window).expect("init within Tokio failed");
    assert!(handle.is_running());
    handle.stop().expect("stop failed");
    assert!(!handle.is_running());
}

/// Test 1.3: Call `slate::agent::init` within a single-threaded (current_thread) Tokio runtime.
#[tokio::test(flavor = "current_thread")]
async fn test_init_inside_current_thread_tokio() {
    init_headless();
    let window = AdversarialStressWindow::new().expect("create window failed");
    let handle = init(&window).expect("init within current_thread Tokio failed");
    assert!(handle.is_running());
    handle.stop().expect("stop failed");
    assert!(!handle.is_running());
}

/// Test 1.4: Empirical Verification: `AgentBuilder::start` outside Tokio bootstraps runtime cleanly.
/// When called outside an active Tokio runtime, `AgentBuilder::start` must create the runtime
/// and enter it on the calling thread, allowing `tokio::spawn` inside protocol adapters to succeed.
#[test]
fn test_builder_start_without_tokio_succeeds() {
    init_headless();
    // Run on a clean OS thread that does NOT have a Tokio runtime entered
    let join_res = std::thread::spawn(|| {
        assert!(
            tokio::runtime::Handle::try_current().is_err(),
            "Precondition: must have NO Tokio runtime"
        );
        let window = AdversarialStressWindow::new().expect("create window");
        let (client, server_stream) = duplex(4096);

        let handle = builder(&window)
            .with_name("unentered-rt-test")
            .with_mcp_in_memory(server_stream)
            .start()?;
        assert!(handle.is_running(), "handle must be running inside thread");
        Ok::<_, slate::agent::AgentError>((client, handle))
    }).join();

    assert!(
        join_res.is_ok(),
        "Remediated: builder.start() without active Tokio runtime must succeed"
    );
    let (_client, handle) = join_res.unwrap().expect("start should succeed");
    assert!(handle.is_running());
    handle.stop().expect("stop failed");
    assert!(!handle.is_running());
}

// =========================================================================
// CHALLENGE SUITE 2: Lifecycle, Repeated Calls & Shutdown Resilience
// =========================================================================

/// Test 2.1: Repeated initialization and shutdown on the same window.
#[tokio::test]
async fn test_repeated_init_and_stop_cycles() {
    init_headless();
    let window = AdversarialStressWindow::new().expect("create window");

    for cycle in 0..10 {
        let handle = init(&window).unwrap_or_else(|e| panic!("Cycle {} init failed: {:?}", cycle, e));
        assert!(handle.is_running(), "Cycle {} handle must be running", cycle);

        // Verify idempotent stop
        handle.stop().expect("first stop failed");
        assert!(!handle.is_running(), "Cycle {} handle must be stopped", cycle);
        handle.stop().expect("second stop must be idempotent");
    }
}

/// Test 2.2: Drop behavior without explicit `stop()`.
#[tokio::test]
async fn test_handle_drop_triggers_clean_stop() {
    init_headless();
    let window = AdversarialStressWindow::new().expect("create window");

    {
        let handle = init(&window).expect("init failed");
        assert!(handle.is_running());
        // Handle drops here
    }
    // After dropping, subsequent init succeeds immediately
    let handle2 = init(&window).expect("subsequent init after drop failed");
    assert!(handle2.is_running());
    handle2.stop().expect("stop failed");
}

/// Test 2.3: Multiple concurrent agent handles on the same window.
#[tokio::test]
async fn test_concurrent_agent_instances_on_same_window() {
    init_headless();
    let window = AdversarialStressWindow::new().expect("create window");

    let handle1 = init(&window).expect("init 1 failed");
    let handle2 = init(&window).expect("init 2 failed");

    assert!(handle1.is_running());
    assert!(handle2.is_running());

    handle1.stop().expect("stop 1 failed");
    assert!(!handle1.is_running());
    assert!(handle2.is_running(), "handle2 should still be running after handle1 stops");

    handle2.stop().expect("stop 2 failed");
    assert!(!handle2.is_running());
}

// =========================================================================
// CHALLENGE SUITE 3: High-Volume In-Memory Stress & UI Synchronization
// =========================================================================

/// Test 3.1: 200 sequential MCP JSON-RPC requests through in-memory transport.
#[tokio::test]
async fn test_high_volume_in_memory_mcp_requests() {
    init_headless();
    let window = AdversarialStressWindow::new().expect("create window");
    let (client_stream, server_stream) = duplex(65536);

    let agent_handle = builder(&window)
        .with_name("stress-app")
        .with_mcp_in_memory(server_stream)
        .start()
        .expect("builder.start() failed");

    let (mut client_read, mut client_write) = tokio::io::split(client_stream);
    let mut reader = BufReader::new(&mut client_read);

    // Initialize MCP handshake
    let init_req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 0,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": { "name": "stress-tester", "version": "1.0" }
        }
    });
    client_write.write_all(format!("{}\n", init_req).as_bytes()).await.unwrap();
    client_write.flush().await.unwrap();

    let mut line = String::new();
    reader.read_line(&mut line).await.unwrap();
    assert!(line.contains("\"result\""));

    let start_time = Instant::now();
    let num_requests = 200;

    for i in 1..=num_requests {
        line.clear();
        let req = serde_json::json!({
            "jsonrpc": "2.0",
            "id": i,
            "method": "tools/call",
            "params": {
                "name": "get_state",
                "arguments": {}
            }
        });
        client_write.write_all(format!("{}\n", req).as_bytes()).await.unwrap();
        client_write.flush().await.unwrap();

        reader.read_line(&mut line).await.unwrap();
        assert!(line.contains(&format!("\"id\":{}", i)), "Response mismatch on req {}: {}", i, line);
    }

    let elapsed = start_time.elapsed();
    println!(
        "Stress test completed: {} requests in {:?} ({:.2} req/sec)",
        num_requests,
        elapsed,
        num_requests as f64 / elapsed.as_secs_f64()
    );

    agent_handle.shutdown();
}

/// Test 3.2: Concurrent background compute task vs Agent State & UI inspection.
#[tokio::test]
async fn test_agent_concurrency_with_background_compute() {
    init_headless();
    let window = AdversarialStressWindow::new().expect("create window");
    let (client_stream, server_stream) = duplex(16384);

    let agent_handle = builder(&window)
        .with_mcp_in_memory(server_stream)
        .start()
        .expect("start failed");

    // Spawn a heavy background task simulating Monte Carlo or CPU work
    let compute_cancelled = Arc::new(AtomicBool::new(false));
    let flag_clone = compute_cancelled.clone();
    let compute_handle = slate::core::task::spawn_compute(
        move |is_cancelled, _progress| {
            let mut sum: u64 = 0;
            for i in 0..1_000_000 {
                if is_cancelled() {
                    return None;
                }
                sum = sum.wrapping_add(i);
            }
            Some(sum)
        },
        |_pct| {},
        move |_res| {
            flag_clone.store(true, Ordering::SeqCst);
        },
    );

    // Concurrently query agent UI inspector and element controller
    let (mut client_read, mut client_write) = tokio::io::split(client_stream);
    let mut reader = BufReader::new(&mut client_read);

    // Call initialize
    let init_req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": { "name": "stress", "version": "1.0" }
        }
    });
    client_write.write_all(format!("{}\n", init_req).as_bytes()).await.unwrap();
    client_write.flush().await.unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).await.unwrap();

    // Call inspect_tree while compute task is running
    line.clear();
    let inspect_req = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": { "name": "inspect_tree", "arguments": {} }
    });
    client_write.write_all(format!("{}\n", inspect_req).as_bytes()).await.unwrap();
    client_write.flush().await.unwrap();
    reader.read_line(&mut line).await.unwrap();
    assert!(line.contains("\"result\""), "inspect_tree failed during compute: {}", line);

    // Clean up
    compute_handle.cancel();
    agent_handle.shutdown();
}
