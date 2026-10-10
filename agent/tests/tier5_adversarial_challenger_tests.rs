//! Tier 5 Adversarial Coverage Hardening Test Suite for `slate-agent`.
//!
//! Validates:
//! 1. `SlintUiBridge` concurrency limits, mutual exclusion with 200 tasks,
//!    clean lock release on panics and `WindowClosed` errors, exhaustive `downcast_panic` types.
//! 2. Core geometry & data model boundaries: zero/negative rects, NaN/Inf points,
//!    comprehensive `ElementSelector::parse` parsing matrix, z-order hit-testing, hidden element skipping.
//! 3. ACP protocol speech-act validation: `Query` mutation rejection, `Command`/`Request` allowance,
//!    `Inform`/`Subscribe` handling, missing payload errors, high-throughput 200-message burst.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use slate_agent::acp::{
    AcpEndpoint, AcpMessage, DefaultAcpEndpoint, MockAcpAdapter, MockAcpConfig,
};
use slate_agent::bridge::{downcast_panic, SlintUiBridge};
use slate_agent::engine::{
    DefaultAutomationEngine, DefaultElementController, DefaultStateProvider, DefaultUiInspector,
    DefaultVisualRenderer,
};
use slate_agent::model::{ElementSelector, Point, Rect, Screenshot, UiElementNode, UiTree};
use slate_agent::protocol::{AgentProtocolAdapter, ProtocolServerHandle};
use slate_agent::traits::AutomationEngine;

fn create_test_engine() -> Arc<dyn AutomationEngine> {
    Arc::new(DefaultAutomationEngine::new(
        Arc::new(DefaultUiInspector::new(
            "Adversarial Window",
            1040.0,
            720.0,
        )),
        Arc::new(DefaultElementController),
        Arc::new(DefaultStateProvider::new("main")),
        Arc::new(DefaultVisualRenderer::new(1040, 720)),
    ))
}

// ============================================================================
// 1. SlintUiBridge Concurrency, Lock Release & Boundary Races
// ============================================================================

/// 200 concurrent tasks competing for command lock. Verifies strict mutual exclusion
/// (never > 1 inside critical section) and zero deadlocks.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_adversarial_bridge_rapid_lock_contention_200_tasks() {
    let bridge = SlintUiBridge::new();
    let task_count = 200;

    let active_count = Arc::new(AtomicUsize::new(0));
    let max_concurrent = Arc::new(AtomicUsize::new(0));
    let race_detected = Arc::new(AtomicBool::new(false));
    let completed = Arc::new(AtomicUsize::new(0));

    let mut handles = Vec::with_capacity(task_count);

    for _ in 0..task_count {
        let bridge = bridge.clone();
        let active = active_count.clone();
        let max_obs = max_concurrent.clone();
        let race = race_detected.clone();
        let done = completed.clone();

        handles.push(tokio::spawn(async move {
            let _guard = bridge.lock_commands().await;

            let cur = active.fetch_add(1, Ordering::SeqCst) + 1;
            max_obs.fetch_max(cur, Ordering::SeqCst);

            if cur > 1 {
                race.store(true, Ordering::SeqCst);
            }

            tokio::task::yield_now().await;

            let after = active.load(Ordering::SeqCst);
            if after > 1 {
                race.store(true, Ordering::SeqCst);
            }

            active.fetch_sub(1, Ordering::SeqCst);
            done.fetch_add(1, Ordering::SeqCst);
        }));
    }

    for h in handles {
        h.await.expect("Task failed to join");
    }

    assert_eq!(completed.load(Ordering::SeqCst), task_count);
    assert_eq!(active_count.load(Ordering::SeqCst), 0);
    assert_eq!(
        max_concurrent.load(Ordering::SeqCst),
        1,
        "Invariant violated: max concurrent tasks in critical section must be 1"
    );
    assert!(
        !race_detected.load(Ordering::SeqCst),
        "Race condition detected in command serializer"
    );
}

/// Mutex lock must be released immediately if action panics inside a task.
#[tokio::test]
async fn test_adversarial_bridge_serialized_lock_release_on_panic() {
    let bridge = SlintUiBridge::new();
    let b1 = bridge.clone();

    // Spawn a task that acquires the serializer lock and then panics
    let handle = tokio::spawn(async move {
        let _guard = b1.lock_commands().await;
        panic!("Simulated worker panic");
    });

    let _ = handle.await;

    // Subsequent task must acquire lock immediately without deadlock or poisoning
    let b2 = bridge.clone();
    let res = tokio::time::timeout(Duration::from_millis(100), async move {
        let _guard = b2.lock_commands().await;
        "acquired"
    })
    .await;

    assert_eq!(res, Ok("acquired"));
}

/// Mutex lock must be released immediately if `run_with_window` errors because window is closed.
#[tokio::test]
async fn test_adversarial_bridge_serialized_lock_release_on_window_closed() {
    slint::slint! {
        export component TempWindow inherits Window {
            width: 200px;
            height: 100px;
        }
    }

    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });

    let window = TempWindow::new().unwrap();
    let bridge = Arc::new(SlintUiBridge::new());
    let comp_bridge = slate_agent::bridge::ComponentBridge::new(window.as_weak(), bridge.clone());

    // Drop window immediately
    drop(window);

    // Call run_with_window_serialized: must return AgentError::WindowClosed or EventLoopUnavailable
    let result = comp_bridge
        .run_with_window_serialized(|_| Ok("alive"))
        .await;
    assert!(result.is_err());

    // Lock must be released immediately
    let b = bridge.clone();
    let res = tokio::time::timeout(Duration::from_millis(100), async move {
        let _guard = b.lock_commands().await;
        "lock free"
    })
    .await;

    assert_eq!(res, Ok("lock free"));
}

/// Exhaustive verification of `downcast_panic` across various exotic Rust types.
#[test]
fn test_adversarial_downcast_panic_exhaustive_types() {
    // 1. &str
    let p1: Box<dyn std::any::Any + Send + 'static> = Box::new("static str panic");
    assert_eq!(downcast_panic(p1), "static str panic");

    // 2. String
    let p2: Box<dyn std::any::Any + Send + 'static> = Box::new(String::from("heap string panic"));
    assert_eq!(downcast_panic(p2), "heap string panic");

    // 3. Integer types (i32, i64, usize)
    let p3: Box<dyn std::any::Any + Send + 'static> = Box::new(42i32);
    assert_eq!(downcast_panic(p3), "Unknown panic on UI thread");

    let p4: Box<dyn std::any::Any + Send + 'static> = Box::new(100usize);
    assert_eq!(downcast_panic(p4), "Unknown panic on UI thread");

    // 4. Boolean
    let p5: Box<dyn std::any::Any + Send + 'static> = Box::new(true);
    assert_eq!(downcast_panic(p5), "Unknown panic on UI thread");

    // 5. Tuple / Option
    let p6: Box<dyn std::any::Any + Send + 'static> = Box::new(Some("inner".to_string()));
    assert_eq!(downcast_panic(p6), "Unknown panic on UI thread");

    // 6. Unit type ()
    let p7: Box<dyn std::any::Any + Send + 'static> = Box::new(());
    assert_eq!(downcast_panic(p7), "Unknown panic on UI thread");
}

// ============================================================================
// 2. Core Geometry & Data Model Boundary Cases
// ============================================================================

/// Rect edge cases: zero rect, negative/inverted rect, infinite coordinates.
#[test]
fn test_adversarial_rect_boundaries() {
    // 1. Zero rect
    let zero = Rect::ZERO;
    assert_eq!(zero.area(), 0.0);
    assert_eq!(zero.origin(), Point::ZERO);
    assert_eq!(zero.center(), Point::ZERO);
    assert!(zero.contains(&Point::ZERO));
    assert!(!zero.contains(&Point::new(0.001, 0.0)));

    // 2. Negative coordinates rect
    let neg_rect = Rect::new(-100.0, -100.0, 50.0, 50.0);
    assert!(neg_rect.contains(&Point::new(-75.0, -75.0)));
    assert!(!neg_rect.contains(&Point::new(0.0, 0.0)));
    assert_eq!(neg_rect.center(), Point::new(-75.0, -75.0));
    assert_eq!(neg_rect.area(), 2500.0);

    // 3. Inverted rect (negative width/height)
    let inv_rect = Rect::new(10.0, 10.0, -20.0, -20.0);
    assert_eq!(inv_rect.area(), 400.0);
    // contains evaluates p.x >= 10 && p.x <= -10 which is always false
    assert!(!inv_rect.contains(&Point::new(0.0, 0.0)));

    // 4. Intersection edge cases (touching borders do not intersect)
    let r1 = Rect::new(0.0, 0.0, 10.0, 10.0);
    let r2 = Rect::new(10.0, 0.0, 10.0, 10.0); // Touching at x = 10
    assert!(!r1.intersects(&r2), "Touching edges must not intersect");

    let r3 = Rect::new(5.0, 5.0, 10.0, 10.0); // Overlapping
    assert!(r1.intersects(&r3), "Overlapping rects must intersect");
}

/// Point geometry with NaN and Infinity floats.
#[test]
fn test_adversarial_point_nan_and_infinity() {
    let p_nan = Point::new(f32::NAN, 10.0);
    let p_inf = Point::new(f32::INFINITY, f32::NEG_INFINITY);

    let r = Rect::new(0.0, 0.0, 100.0, 100.0);
    // Comparison with NaN is always false
    assert!(!r.contains(&p_nan));
    assert!(!r.contains(&p_inf));

    assert!(p_nan.distance_to(&Point::ZERO).is_nan());
}

/// Comprehensive verification of `ElementSelector::parse` on edge inputs.
#[test]
fn test_adversarial_element_selector_parsing_matrix() {
    // 1. Explicit ID prefixes
    assert_eq!(
        ElementSelector::parse("#submit_btn"),
        ElementSelector::Id("submit_btn".into())
    );
    assert_eq!(
        ElementSelector::parse("id:custom_id"),
        ElementSelector::Id("custom_id".into())
    );

    // 2. Explicit label / text prefixes
    assert_eq!(
        ElementSelector::parse("text:Click Me"),
        ElementSelector::Label("Click Me".into())
    );
    assert_eq!(
        ElementSelector::parse("label:Save Settings"),
        ElementSelector::Label("Save Settings".into())
    );

    // 3. Explicit role prefix
    assert_eq!(
        ElementSelector::parse("role:button"),
        ElementSelector::Role("button".into())
    );
    assert_eq!(
        ElementSelector::parse("role:TextInput"),
        ElementSelector::Role("TextInput".into())
    );

    // 4. Coordinate parsing variations
    assert_eq!(
        ElementSelector::parse("100, 200"),
        ElementSelector::Coordinate(Point::new(100.0, 200.0))
    );
    assert_eq!(
        ElementSelector::parse("  -50.5 , +75.25  "),
        ElementSelector::Coordinate(Point::new(-50.5, 75.25))
    );
    assert_eq!(
        ElementSelector::parse("0, 0"),
        ElementSelector::Coordinate(Point::new(0.0, 0.0))
    );

    // 5. Fallback strings (unprefixed strings become IDs)
    assert_eq!(
        ElementSelector::parse("plain_id"),
        ElementSelector::Id("plain_id".into())
    );
    assert_eq!(
        ElementSelector::parse("  trimmed_id  "),
        ElementSelector::Id("trimmed_id".into())
    );

    // 6. Malformed coordinates fallback to ID
    assert_eq!(
        ElementSelector::parse(","),
        ElementSelector::Id(",".into())
    );
    assert_eq!(
        ElementSelector::parse("100,"),
        ElementSelector::Id("100,".into())
    );
    assert_eq!(
        ElementSelector::parse(",200"),
        ElementSelector::Id(",200".into())
    );
    assert_eq!(
        ElementSelector::parse(""),
        ElementSelector::Id("".into())
    );
}

/// Reverse z-order hit testing and hidden element skipping in `UiTree`.
#[test]
fn test_adversarial_ui_tree_zorder_and_hidden_elements() {
    let child_bottom = UiElementNode {
        id: "child_bottom".to_string(),
        type_name: "Button".to_string(),
        bounds: Rect::new(10.0, 10.0, 50.0, 50.0),
        label: Some("Bottom".to_string()),
        role: "button".to_string(),
        value: None,
        enabled: true,
        focused: false,
        visible: true,
        children: vec![],
        properties: HashMap::new(),
    };

    let child_top = UiElementNode {
        id: "child_top".to_string(),
        type_name: "Button".to_string(),
        bounds: Rect::new(10.0, 10.0, 50.0, 50.0),
        label: Some("Top".to_string()),
        role: "button".to_string(),
        value: None,
        enabled: true,
        focused: false,
        visible: true,
        children: vec![],
        properties: HashMap::new(),
    };

    let hidden_child = UiElementNode {
        id: "hidden".to_string(),
        type_name: "Button".to_string(),
        bounds: Rect::new(10.0, 10.0, 50.0, 50.0),
        label: Some("Hidden".to_string()),
        role: "button".to_string(),
        value: None,
        enabled: true,
        focused: false,
        visible: false, // Hidden
        children: vec![],
        properties: HashMap::new(),
    };

    let root = UiElementNode {
        id: "root".to_string(),
        type_name: "Window".to_string(),
        bounds: Rect::new(0.0, 0.0, 200.0, 200.0),
        label: Some("Root".to_string()),
        role: "window".to_string(),
        value: None,
        enabled: true,
        focused: true,
        visible: true,
        children: vec![child_bottom, child_top, hidden_child],
        properties: HashMap::new(),
    };

    let tree = UiTree::new(root);

    // Hit test at point (25, 25) which is inside all three children
    // Must pick child_top (highest z-order among visible children, skipping hidden_child)
    let hit = tree.find_at_point(&Point::new(25.0, 25.0)).unwrap();
    assert_eq!(hit.id, "child_top");
}

/// Screenshot encoding with empty image buffer.
#[test]
fn test_adversarial_screenshot_empty_buffer() {
    let shot = Screenshot::new(0, 0, "png", vec![]);
    assert_eq!(shot.byte_len(), 0);
    assert_eq!(shot.to_base64(), "");
    assert_eq!(shot.data_url(), "data:image/png;base64,");
}

// ============================================================================
// 3. ACP Protocol Extension Boundaries & Speech-Act Validation
// ============================================================================

/// `AcpPerformative::Query` MUST reject all mutating actions with descriptive error.
#[tokio::test]
async fn test_adversarial_acp_query_rejects_all_mutating_actions() {
    let engine = create_test_engine();
    let endpoint = DefaultAcpEndpoint::new(engine);

    let mutating_actions = vec![
        "click",
        "click_element",
        "send_keys",
        "toggle",
        "toggle_element",
    ];

    for action in mutating_actions {
        let msg = AcpMessage::query(action, "adversarial-agent", serde_json::json!({}));
        let resp = endpoint.dispatch_acp(msg).await.unwrap();

        assert!(
            !resp.success,
            "Query performative MUST reject mutating action '{}'",
            action
        );
        let err_msg = resp.error.unwrap();
        assert!(
            err_msg.contains("Query performative cannot be used for mutating action"),
            "Error message must explain speech-act violation for '{}': {}",
            action,
            err_msg
        );
    }
}

/// `AcpPerformative::Command` and `Request` MUST permit mutating actions.
#[tokio::test]
async fn test_adversarial_acp_command_and_request_permit_mutations() {
    let engine = create_test_engine();
    let endpoint = DefaultAcpEndpoint::new(engine);

    // 1. Command click -> allowed
    let cmd = AcpMessage::command("click", "agent-1", serde_json::json!({"target": "btn1"}));
    let resp = endpoint.dispatch_acp(cmd).await.unwrap();
    assert!(resp.success);

    // 2. Request send_keys -> allowed
    let req = AcpMessage::request(
        "send_keys",
        "agent-1",
        serde_json::json!({"text": "hello", "target": "input1"}),
    );
    let resp = endpoint.dispatch_acp(req).await.unwrap();
    assert!(resp.success);
}

/// `AcpPerformative::Inform` and `Subscribe` handling.
#[tokio::test]
async fn test_adversarial_acp_inform_and_subscribe_semantics() {
    let engine = create_test_engine();
    let endpoint = DefaultAcpEndpoint::new(engine);

    // 1. Inform returns acknowledgment without mutating engine
    let info_msg = AcpMessage::inform("status_update", "peer_agent", serde_json::json!({"cpu": 45}));
    let resp = endpoint.dispatch_acp(info_msg).await.unwrap();
    assert!(resp.success);
    assert_eq!(resp.data["status"], "acknowledged");

    // 2. Subscribe returns subscription registration
    let sub_msg = AcpMessage::subscribe("live_logs", "peer_agent", serde_json::json!({}));
    let resp = endpoint.dispatch_acp(sub_msg).await.unwrap();
    assert!(resp.success);
    assert_eq!(resp.data["status"], "subscribed");
    assert_eq!(resp.data["topic"], "live_logs");
}

/// ACP actions with missing required parameters return clean failure responses.
#[tokio::test]
async fn test_adversarial_acp_missing_payload_parameters() {
    let engine = create_test_engine();
    let endpoint = DefaultAcpEndpoint::new(engine);

    // 1. find_element missing selector
    let msg = AcpMessage::request("find_element", "agent", serde_json::json!({}));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("Missing 'selector'"));

    // 2. click missing target
    let msg = AcpMessage::command("click", "agent", serde_json::json!({}));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("Missing 'target'"));

    // 3. send_keys missing text
    let msg = AcpMessage::command("send_keys", "agent", serde_json::json!({}));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("Missing 'text'"));

    // 4. toggle missing target
    let msg = AcpMessage::command("toggle", "agent", serde_json::json!({}));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("Missing 'target'"));

    // 5. Unknown action
    let msg = AcpMessage::request("nonexistent_action", "agent", serde_json::json!({}));
    let resp = endpoint.dispatch_acp(msg).await.unwrap();
    assert!(!resp.success);
    assert!(resp.error.unwrap().contains("Unsupported ACP action"));
}

/// High-throughput burst: 200 concurrent ACP messages dispatched over `MockAcpClient` channel.
#[tokio::test]
async fn test_adversarial_acp_high_throughput_burst_200_messages() {
    let engine = create_test_engine();
    let mut adapter = MockAcpAdapter;
    let config = MockAcpConfig {
        agent_id: "test-burst".to_string(),
        channel_capacity: 256,
    };

    let server_handle = adapter.attach(engine, config).unwrap();
    let client = server_handle.client();

    let message_count = 200;
    let mut handles = Vec::with_capacity(message_count);

    for i in 0..message_count {
        let client = client.clone();
        handles.push(tokio::spawn(async move {
            let msg = AcpMessage::query("get_state", "agent", serde_json::json!({}));
            let resp = client.send(msg).await.unwrap();
            (i, resp.success)
        }));
    }

    for h in handles {
        let (_id, success) = h.await.unwrap();
        assert!(success);
    }

    server_handle.stop().unwrap();
}
