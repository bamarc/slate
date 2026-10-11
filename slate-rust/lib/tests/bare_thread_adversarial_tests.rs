//! Empirical Bare OS Thread Adversarial Stress Harness for `slate::agent::init` and `slate::agent::builder`.
//!
//! Validates:
//! 1. Bare OS thread startup without prior Tokio runtime.
//! 2. Zero runtime panics (especially "there is no reactor running").
//! 3. Clean shutdown semantics via `.stop()` and `Drop`.
//! 4. Cross-thread handle transfer and shutdown across unentered bare threads.
//! 5. High-frequency init/stop cycles on bare OS thread.

use std::sync::mpsc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use slate::agent::{builder, init, AgentBuilderMcpExt};

slint::slint! {
    export component BareThreadWindow inherits Window {
        width: 320px;
        height: 240px;
        title: "Bare Thread Window";

        in-out property <int> test_val: 42;
    }
}

fn setup_headless() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });
}

/// Scenario 1: Bare OS thread starts `slate::agent::init`, verifies zero panics,
/// verifies runtime was entered on the calling thread, and stops cleanly.
#[test]
fn test_bare_os_thread_init_and_clean_stop() {
    setup_headless();
    assert!(
        tokio::runtime::Handle::try_current().is_err(),
        "Precondition: calling thread must be a bare OS thread with NO Tokio runtime"
    );

    let window = BareThreadWindow::new().expect("create window failed");
    let agent = init(&window).expect("init failed on bare OS thread");

    assert!(agent.is_running(), "Agent handle must be running");
    assert_eq!(agent.local_addr(), Some("stdio://process".to_string()));

    // Verify runtime is now entered on this calling thread
    assert!(
        tokio::runtime::Handle::try_current().is_ok(),
        "Tokio runtime must be entered on calling thread after agent init"
    );

    // Stop cleanly
    agent.stop().expect("stop failed on bare thread");
    assert!(!agent.is_running(), "Agent must report stopped");

    // Idempotent stop
    agent.stop().expect("second stop must be idempotent");
}

/// Scenario 2: Rapid sequential init and immediate drop on bare thread.
/// Verifies Drop calls stop() cleanly without hanging, crashing, or panicking.
#[test]
fn test_bare_os_thread_rapid_init_and_drop_cycles() {
    setup_headless();
    let window = BareThreadWindow::new().expect("create window failed");

    for cycle in 0..30 {
        let agent = init(&window).unwrap_or_else(|e| panic!("Cycle {} init failed: {:?}", cycle, e));
        assert!(agent.is_running(), "Cycle {} must be running", cycle);
        // Immediate drop without explicit stop()
        drop(agent);
    }
}

/// Scenario 3: Cross-thread handle transfer and shutdown.
/// The agent handle is created on the bare OS Slint thread, then transferred
/// across an mpsc channel to a secondary bare OS thread that has NEVER entered
/// any Tokio runtime. The secondary thread calls stop() and drops the handle.
#[test]
fn test_bare_os_thread_cross_thread_shutdown_on_unentered_thread() {
    setup_headless();
    let window = BareThreadWindow::new().expect("create window failed");

    let agent = init(&window).expect("init failed on bare OS thread");
    assert!(agent.is_running());

    let (tx_agent, rx_agent) = mpsc::channel();
    let (tx_done, rx_done) = mpsc::channel();

    tx_agent.send(agent).unwrap();

    // Spawn an independent bare OS thread
    let unentered_thread = std::thread::spawn(move || {
        // Assert thread has NO Tokio runtime entered
        assert!(
            tokio::runtime::Handle::try_current().is_err(),
            "Secondary thread must have NO Tokio runtime"
        );

        let agent = rx_agent
            .recv_timeout(Duration::from_secs(5))
            .expect("failed to receive agent handle");
        assert!(agent.is_running());

        // Stop on unentered thread
        agent.stop().expect("stop on unentered thread failed");
        assert!(!agent.is_running());

        // Drop on unentered thread
        drop(agent);

        tx_done.send(()).unwrap();
    });

    rx_done
        .recv_timeout(Duration::from_secs(5))
        .expect("Shutdown on unentered thread timed out");
    assert!(unentered_thread.join().is_ok(), "Unentered thread panicked");
}

/// Scenario 4: Bare OS thread starts `builder` with in-memory MCP transport,
/// and client communicates bidirectional JSON-RPC messages before shutdown.
#[test]
fn test_bare_os_thread_builder_in_memory_bidirectional_traffic() {
    setup_headless();
    let window = BareThreadWindow::new().expect("create window failed");
    let (client_stream, server_stream) = tokio::io::duplex(8192);

    let agent = builder(&window)
        .with_name("bare-thread-builder-traffic")
        .with_mcp_in_memory(server_stream)
        .start()
        .expect("builder.start failed on bare thread");

    assert!(agent.is_running());
    let addr = agent.local_addr().expect("local_addr should be Some");
    assert!(addr.starts_with("inproc://duplex/"));

    let rt_handle = tokio::runtime::Handle::try_current()
        .expect("Runtime must be entered on calling thread");

    rt_handle.block_on(async move {
        let (mut client_read, mut client_write) = tokio::io::split(client_stream);
        let mut reader = BufReader::new(&mut client_read);

        // 1. Handshake initialize
        let init_req = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 100,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": { "name": "bare-client", "version": "1.0" }
            }
        });
        client_write.write_all(format!("{}\n", init_req).as_bytes()).await.unwrap();
        client_write.flush().await.unwrap();

        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let val: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(val["id"], 100);
        assert_eq!(val["result"]["serverInfo"]["name"], "slate-mcp");

        // 2. tools/list
        line.clear();
        let list_req = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 101,
            "method": "tools/list",
            "params": {}
        });
        client_write.write_all(format!("{}\n", list_req).as_bytes()).await.unwrap();
        client_write.flush().await.unwrap();

        reader.read_line(&mut line).await.unwrap();
        let list_val: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(list_val["id"], 101);
        let tools = list_val["result"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 5);

        // 3. Stop
        agent.stop().unwrap();
        assert!(!agent.is_running());
    });
}

/// Scenario 5: Multiple sequential builder instances with in-memory streams on bare thread.
#[test]
fn test_bare_os_thread_repeated_builder_in_memory_cycles() {
    setup_headless();
    let window = BareThreadWindow::new().expect("create window failed");

    for i in 0..10 {
        let (_client_stream, server_stream) = tokio::io::duplex(4096);
        let agent = builder(&window)
            .with_name(format!("cycle-app-{}", i))
            .with_mcp_in_memory(server_stream)
            .start()
            .unwrap_or_else(|e| panic!("Cycle {} builder failed: {:?}", i, e));

        assert!(agent.is_running());
        agent.stop().expect("stop failed");
        assert!(!agent.is_running());
    }
}
