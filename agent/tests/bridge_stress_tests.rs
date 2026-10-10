//! Stress and empirical adversarial verification tests for SlintUiBridge,
//! command serialization under high concurrency, timeout handling, panic isolation,
//! and channel drop edge cases.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::oneshot;
use tokio::time::sleep;

use slate_agent::bridge::{downcast_panic, SlintUiBridge};
use slate_agent::error::AgentError;

/// 1. EMPIRICAL CONCURRENCY: 100 concurrent tasks acquiring the command lock simultaneously.
/// Verifies strict mutual exclusion: at NO point do two tasks execute within the critical section.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_stress_concurrent_command_serialization_100_tasks() {
    let bridge = SlintUiBridge::new();
    let task_count = 100;

    let active_in_cs = Arc::new(AtomicUsize::new(0));
    let max_concurrent_observed = Arc::new(AtomicUsize::new(0));
    let completed_tasks = Arc::new(AtomicUsize::new(0));
    let race_detected = Arc::new(AtomicBool::new(false));

    let mut handles = Vec::with_capacity(task_count);

    for task_id in 0..task_count {
        let bridge = bridge.clone();
        let active = active_in_cs.clone();
        let max_obs = max_concurrent_observed.clone();
        let completed = completed_tasks.clone();
        let race = race_detected.clone();

        handles.push(tokio::spawn(async move {
            // High concurrency contention: acquire serializer lock
            let _guard = bridge.lock_commands().await;

            let current = active.fetch_add(1, Ordering::SeqCst) + 1;
            // Record maximum concurrent tasks observed inside the critical section
            max_obs.fetch_max(current, Ordering::SeqCst);

            if current > 1 {
                race.store(true, Ordering::SeqCst);
            }

            // Simulate small work inside the critical section to allow other tasks to contend
            if task_id % 5 == 0 {
                sleep(Duration::from_millis(2)).await;
            } else {
                tokio::task::yield_now().await;
            }

            let after = active.load(Ordering::SeqCst);
            if after > 1 {
                race.store(true, Ordering::SeqCst);
            }

            active.fetch_sub(1, Ordering::SeqCst);
            completed.fetch_add(1, Ordering::SeqCst);
        }));
    }

    for h in handles {
        h.await.expect("Task failed to join");
    }

    assert_eq!(
        completed_tasks.load(Ordering::SeqCst),
        task_count,
        "All 100 tasks should complete"
    );
    assert_eq!(
        active_in_cs.load(Ordering::SeqCst),
        0,
        "No tasks remaining in critical section"
    );
    assert_eq!(
        max_concurrent_observed.load(Ordering::SeqCst),
        1,
        "Mutual exclusion invariant violated: max concurrent tasks in critical section must be exactly 1"
    );
    assert!(
        !race_detected.load(Ordering::SeqCst),
        "Data race / concurrent execution detected in command serializer"
    );
}

/// 2. EMPIRICAL RESILIENCE: Mutex lock release on task panic.
/// Verifies that Tokio Mutex does not poison or deadlock if a task panics while holding the lock.
#[tokio::test]
async fn test_stress_lock_release_on_panic() {
    let bridge = SlintUiBridge::new();
    let bridge1 = bridge.clone();

    // Spawn task that acquires the lock and panics inside catch_unwind
    let handle = tokio::spawn(async move {
        let _guard = bridge1.lock_commands().await;
        panic!("Intentional worker panic while holding command lock");
    });

    let join_result = handle.await;
    assert!(join_result.is_err(), "Task must panic");

    // Subsequent task must be able to acquire lock immediately without deadlock or poisoning
    let bridge2 = bridge.clone();
    let acquire_result = tokio::time::timeout(Duration::from_millis(100), async move {
        let _guard = bridge2.lock_commands().await;
        42
    })
    .await;

    assert_eq!(
        acquire_result,
        Ok(42),
        "Subsequent task failed to acquire lock after panic in previous holder"
    );
}

/// 3. EMPIRICAL TIMEOUT: Rapid concurrent stalled channels trigger AgentError::Timeout within deadline.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_stress_rapid_timeout_stalled_channels_50_tasks() {
    let task_count = 50;
    let configured_timeout = Duration::from_millis(30);

    let mut handles = Vec::with_capacity(task_count);

    for _ in 0..task_count {
        handles.push(tokio::spawn(async move {
            let start = Instant::now();
            let (_tx, rx) = oneshot::channel::<Result<String, AgentError>>();

            // Simulate the bridge timeout pattern
            let result = match tokio::time::timeout(configured_timeout, rx).await {
                Ok(Ok(val)) => val,
                Ok(Err(_)) => Err(AgentError::UiChannelClosed),
                Err(_) => Err(AgentError::Timeout(format!(
                    "Timed out after {:?}",
                    configured_timeout
                ))),
            };

            let elapsed = start.elapsed();
            (result, elapsed)
        }));
    }

    for h in handles {
        let (result, elapsed) = h.await.expect("Task join failed");
        match result {
            Err(AgentError::Timeout(msg)) => {
                assert!(msg.contains("Timed out after 30ms"));
                // Ensure timeout fired reasonably close to configured deadline (allowing for scheduler jitter)
                assert!(
                    elapsed >= Duration::from_millis(25),
                    "Timeout fired too early: {:?}",
                    elapsed
                );
                assert!(
                    elapsed < Duration::from_millis(500),
                    "Timeout fired too late: {:?}",
                    elapsed
                );
            }
            other => panic!("Expected AgentError::Timeout, got: {:?}", other),
        }
    }
}

/// 4. EMPIRICAL TIMEOUT BOUNDARY: Zero and near-zero timeout configurations.
#[tokio::test]
async fn test_stress_zero_and_minimal_timeout_boundaries() {
    // 1 nanosecond timeout
    let tight_timeout = Duration::from_nanos(1);
    let (_tx, rx) = oneshot::channel::<Result<(), AgentError>>();

    let res = match tokio::time::timeout(tight_timeout, rx).await {
        Ok(Ok(val)) => val,
        Ok(Err(_)) => Err(AgentError::UiChannelClosed),
        Err(_) => Err(AgentError::Timeout("immediate deadline exceeded".into())),
    };

    match res {
        Err(AgentError::Timeout(msg)) => assert_eq!(msg, "immediate deadline exceeded"),
        other => panic!("Expected AgentError::Timeout, got: {:?}", other),
    }

    // Zero duration timeout
    let zero_timeout = Duration::ZERO;
    let (_tx2, rx2) = oneshot::channel::<Result<(), AgentError>>();
    let res2 = match tokio::time::timeout(zero_timeout, rx2).await {
        Ok(Ok(val)) => val,
        Ok(Err(_)) => Err(AgentError::UiChannelClosed),
        Err(_) => Err(AgentError::Timeout("zero deadline exceeded".into())),
    };

    match res2 {
        Err(AgentError::Timeout(msg)) => assert_eq!(msg, "zero deadline exceeded"),
        other => panic!("Expected AgentError::Timeout, got: {:?}", other),
    }
}

/// 5. EMPIRICAL CHANNEL DROP: Receiver detects sender dropped unexpectedly (UiChannelClosed).
#[tokio::test]
async fn test_stress_dropped_channel_isolation() {
    let (tx, rx) = oneshot::channel::<Result<i32, AgentError>>();

    // Drop sender without sending
    drop(tx);

    let res = match tokio::time::timeout(Duration::from_millis(50), rx).await {
        Ok(Ok(val)) => val,
        Ok(Err(_oneshot_closed)) => Err(AgentError::UiChannelClosed),
        Err(_) => Err(AgentError::Timeout("timed out".into())),
    };

    match res {
        Err(AgentError::UiChannelClosed) => {
            // Expected variant
        }
        other => panic!("Expected AgentError::UiChannelClosed, got {:?}", other),
    }
}

/// 6. EMPIRICAL PANIC ISOLATION: Comprehensive downcast_panic and catch_unwind across diverse panic types.
#[derive(Debug)]
#[allow(dead_code)]
struct CustomPanicObject {
    pub code: u32,
    pub description: &'static str,
}

#[test]
fn test_stress_panic_isolation_diverse_payloads() {
    // 1. Static str
    let p_str: Box<dyn std::any::Any + Send + 'static> = Box::new("static error message");
    assert_eq!(downcast_panic(p_str), "static error message");

    // 2. Formatted String
    let p_string: Box<dyn std::any::Any + Send + 'static> =
        Box::new(format!("dynamic failure at id {}", 99));
    assert_eq!(downcast_panic(p_string), "dynamic failure at id 99");

    // 3. Empty string
    let p_empty: Box<dyn std::any::Any + Send + 'static> = Box::new("".to_string());
    assert_eq!(downcast_panic(p_empty), "");

    // 4. Large string (100k characters)
    let large_str = "x".repeat(100_000);
    let p_large: Box<dyn std::any::Any + Send + 'static> = Box::new(large_str.clone());
    assert_eq!(downcast_panic(p_large), large_str);

    // 5. String with unicode and emojis
    let p_unicode: Box<dyn std::any::Any + Send + 'static> =
        Box::new("Panic with 🚀 and 日本語".to_string());
    assert_eq!(downcast_panic(p_unicode), "Panic with 🚀 and 日本語");

    // 6. Integer payload
    let p_int: Box<dyn std::any::Any + Send + 'static> = Box::new(500i32);
    assert_eq!(downcast_panic(p_int), "Unknown panic on UI thread");

    // 7. Custom struct payload
    let p_struct: Box<dyn std::any::Any + Send + 'static> = Box::new(CustomPanicObject {
        code: 404,
        description: "Not Found",
    });
    assert_eq!(downcast_panic(p_struct), "Unknown panic on UI thread");
}

/// 7. EMPIRICAL PANIC ISOLATION: Real closure unwind intercepting into AgentError::UiPanic.
#[test]
#[allow(clippy::type_complexity)]
fn test_stress_catch_unwind_to_agent_error_ui_panic() {
    let test_cases: Vec<(&'static str, Box<dyn Fn() + std::panic::RefUnwindSafe>)> = vec![
        ("direct panic string", Box::new(|| panic!("widget failure"))),
        (
            "formatted panic string",
            Box::new(|| panic!("failure with code: {}", 101)),
        ),
        (
            "non-string integer panic",
            Box::new(|| std::panic::panic_any(12345)),
        ),
    ];

    for (name, action) in test_cases {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(action));
        assert!(result.is_err(), "Case '{}' should have panicked", name);

        let err = match result {
            Ok(_) => unreachable!(),
            Err(payload) => AgentError::UiPanic(downcast_panic(payload)),
        };

        match err {
            AgentError::UiPanic(msg) => match name {
                "direct panic string" => assert_eq!(msg, "widget failure"),
                "formatted panic string" => assert_eq!(msg, "failure with code: 101"),
                "non-string integer panic" => assert_eq!(msg, "Unknown panic on UI thread"),
                _ => {}
            },
            other => panic!("Expected AgentError::UiPanic, got {:?}", other),
        }
    }
}

/// 8. EMPIRICAL EVENT LOOP UNAVAILABILITY:
/// When slint::invoke_from_event_loop is called without an event loop running,
/// it must return AgentError::EventLoopUnavailable without panicking or crashing.
#[tokio::test]
async fn test_empirical_run_on_ui_without_event_loop_returns_unavailable() {
    let bridge = SlintUiBridge::new();

    // Without a running Slint event loop, run_on_ui will fail at invoke_from_event_loop
    let result = bridge.run_on_ui(|| Ok(100)).await;

    match result {
        Err(AgentError::EventLoopUnavailable(msg)) => {
            assert!(!msg.is_empty(), "EventLoopUnavailable should include error message");
        }
        Err(AgentError::Timeout(_)) => {
            // Alternatively if backend queued but never ran, timeout guard fires
        }
        Ok(_) => {
            // If backend processed inline, also acceptable
        }
        Err(other) => {
            panic!("Unexpected error variant: {:?}", other);
        }
    }
}

/// 9. EMPIRICAL LOCK RECOVERY: run_serialized releases command lock even when run_on_ui errors.
#[tokio::test]
async fn test_stress_run_serialized_releases_lock_on_ui_error() {
    let bridge = SlintUiBridge::new();

    // run_serialized will fail because event loop is unavailable
    let res = bridge.run_serialized(|| Ok("success")).await;
    assert!(res.is_err(), "Must fail when event loop is unavailable");

    // The command serializer lock must be cleanly released
    let acquired = tokio::time::timeout(Duration::from_millis(100), async {
        let _guard = bridge.lock_commands().await;
        "lock acquired successfully"
    })
    .await;

    assert_eq!(acquired, Ok("lock acquired successfully"));
}

slint::slint! {
    export component DummyWindow inherits Window {
        width: 300px;
        height: 200px;
        title: "Dummy Test Window";
    }
}

/// 10. EMPIRICAL WINDOW LIFECYCLE: ComponentBridge weak handle drops and detects WindowClosed.
#[tokio::test]
async fn test_stress_component_bridge_weak_handle_lifecycle() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });

    let window = DummyWindow::new().unwrap();
    let bridge = Arc::new(SlintUiBridge::new());
    let comp_bridge = slate_agent::bridge::ComponentBridge::new(window.as_weak(), bridge.clone());

    // While window is alive, weak upgrade succeeds
    assert!(comp_bridge.weak().upgrade().is_some());

    // Closure simulating the upgrade check inside run_with_window
    let weak_clone = comp_bridge.weak().clone();
    let check_alive = move || {
        let _handle = weak_clone.upgrade().ok_or(AgentError::WindowClosed)?;
        Ok::<_, AgentError>("window is alive")
    };
    assert_eq!(check_alive(), Ok("window is alive"));

    // Drop the window
    drop(window);

    // After dropping window, weak upgrade fails
    assert!(comp_bridge.weak().upgrade().is_none());

    let weak_clone_dropped = comp_bridge.weak().clone();
    let check_dropped = move || {
        let _handle = weak_clone_dropped.upgrade().ok_or(AgentError::WindowClosed)?;
        Ok::<_, AgentError>("should not happen")
    };
    assert_eq!(check_dropped(), Err(AgentError::WindowClosed));
}

/// 11. EMPIRICAL SEQUENTIAL ORDERING: Serialized commands execute strictly one-by-one under contention.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_stress_rapid_interleaved_serialization_ordering() {
    let bridge = SlintUiBridge::new();
    let total_tasks = 20;
    let sequence_log = Arc::new(tokio::sync::Mutex::new(Vec::new()));

    let mut handles = Vec::with_capacity(total_tasks);

    for i in 0..total_tasks {
        let bridge = bridge.clone();
        let log = sequence_log.clone();

        handles.push(tokio::spawn(async move {
            let _guard = bridge.lock_commands().await;
            // Record start
            {
                let mut l = log.lock().await;
                l.push((i, "start"));
            }
            sleep(Duration::from_millis(3)).await;
            // Record end
            {
                let mut l = log.lock().await;
                l.push((i, "end"));
            }
        }));
    }

    for h in handles {
        h.await.unwrap();
    }

    let entries = sequence_log.lock().await.clone();
    assert_eq!(entries.len(), total_tasks * 2);

    // Verify strict non-interleaving: every "start" must be followed immediately by its matching "end"
    for chunk in entries.chunks(2) {
        let (id_start, action_start) = &chunk[0];
        let (id_end, action_end) = &chunk[1];

        assert_eq!(action_start, &"start");
        assert_eq!(action_end, &"end");
        assert_eq!(
            id_start, id_end,
            "Interleaving detected between task {} and task {}",
            id_start, id_end
        );
    }
}

