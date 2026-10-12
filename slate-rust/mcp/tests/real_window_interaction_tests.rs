//! Phase 0 RED tests for the Slint-first MCP remediation plan
//! (`.agents/plans/20261012-114132-mcp-slint-first-remediation.md`, scenarios T1/T2).
//!
//! These tests drive the **production** automation layers
//! (`slate_agent::SlintWindowController` / `SlintWindowInspector`) against a **real**
//! Slint window on a **real event loop** provided by
//! `i_slint_backend_testing::init_integration_test_with_mock_time()`, instead of the
//! always-Ok mock engines used by the framing-only suites (`tool_tests.rs`,
//! `adapter_tests.rs`, `resource_tests.rs`).
//!
//! # A1 API validation (plan §8)
//! All `ElementHandle` / mock-time API names assumed by the plan were verified exact
//! against the vendored `i-slint-backend-testing-1.18.1` sources before writing this
//! file — no adjustments were needed:
//! - `init_integration_test_with_mock_time()` — `lib.rs:56` (`mock_time: true,
//!   threading: true`). Callable **once per process**; called here on the dedicated
//!   UI thread (see below).
//! - `ElementQuery::{match_id, match_accessible_role, match_descendants, find_first,
//!   find_all}`, `ElementHandle::{query_descendants, id, accessible_id,
//!   accessible_role, invoke_accessible_default_action, set_accessible_value,
//!   invoke_accessible_increment_action, invoke_accessible_decrement_action,
//!   invoke_accessible_expand_action, mock_single_click}` — `search_api.rs`.
//! - `mock_elapsed_time(Duration)` — `lib.rs:86`.
//! - `AccessibleRole` re-exported from `i_slint_core::items` — `lib.rs:153`.
//! - Cross-thread `invoke_from_event_loop` / `quit_event_loop` are safe with this
//!   backend (`testing_backend.rs` `Queue`: `Arc<Mutex<VecDeque>>` + thread unpark),
//!   so each scenario runs the Slint loop on the UI thread and drives the async
//!   controller/inspector from a worker thread with its own Tokio runtime.
//!
//! # Threading model (read before touching)
//! The testing backend pins window creation and the event loop to a single thread:
//! creating a component on any other thread fails with `PlatformError` ("The Slint
//! platform was initialized in another thread"). Cargo runs `#[test]` functions on
//! arbitrary harness threads, so **every Slint call lives on one dedicated UI
//! thread** (spawned once via `UI_THREAD`). Each test submits a job closure that
//! builds its window, spawns its driver thread, pumps the loop, and returns a
//! failure list; the `#[test]` body only blocks on the reply channel and asserts.
//! A job panic is caught and reported as a failure so the UI thread stays alive
//! for the next test; the reply `recv_timeout` guarantees a stuck loop surfaces
//! as a clear failure instead of hanging the suite.
//!
//! # Why T1 is green and T2 was RED (read before "fixing")
//! - T1 was written RED against the pre-Phase-1 controller, which dispatched
//!   **both** synthetic pointer press/release **and** the accessible `Default`
//!   action on the same element (old `slint_backend.rs` L419-431: double-flipped
//!   toggles landed back where they started — a silent no-op). While this file
//!   was being written, Phase 1 (D2 single dispatch by role) landed in the
//!   working tree (uncommitted at the time of writing: `toggle_element` and
//!   `click_element` on semantic roles now take the accessible `Default` path
//!   ONLY), so T1 now PASSES and serves as the locked regression guard the plan
//!   requires ("the suite fails if any of these regress"). It asserts both the
//!   end state (true after one call, false after two) and the mechanism
//!   (exactly one dispatch path fires per call). Do not weaken it to force red.
//! - T2 was RED: `UiElementNode` carried **no supported-actions annotation**,
//!   and `inspect_tree` returned duplicate `accessible-id`s as plain nodes
//!   with **no error**. Phases 2/3 turned it green by (a) annotating every
//!   node with `properties.supported_actions` (+ `id_source`/`id_stable`),
//!   and (b) failing inspection with a naming error on duplicate ids (plan
//!   W2). T2 is therefore split in two: the clean-window test asserts unique
//!   ids + actions + stability, and `t2_duplicate_accessible_ids_surface_an_
//!   error` asserts the W2 error path on a window that deliberately collides.

use std::sync::{mpsc, Arc, OnceLock};
use std::time::Duration;

use slate_agent::bridge::SlintUiBridge;
use slate_agent::slint_backend::{SlintWindowController, SlintWindowInspector};
use slate_agent::traits::{ElementController, UiInspector};

/// A scenario job: runs entirely on the UI thread, returns failure descriptions
/// (empty = pass). Captures nothing; everything is built inside the closure so
/// the job is unconditionally `Send`.
type Job = Box<dyn FnOnce() -> Vec<String> + Send>;

/// Request channel to the UI thread. The UI thread installs the mock-time backend
/// once, then executes jobs sequentially.
static UI_THREAD: OnceLock<mpsc::Sender<(Job, mpsc::Sender<Vec<String>>)>> = OnceLock::new();

fn ui_sender() -> mpsc::Sender<(Job, mpsc::Sender<Vec<String>>)> {
    UI_THREAD
        .get_or_init(|| {
            let (tx, rx) = mpsc::channel::<(Job, mpsc::Sender<Vec<String>>)>();
            std::thread::spawn(move || {
                i_slint_backend_testing::init_integration_test_with_mock_time();
                while let Ok((job, reply)) = rx.recv() {
                    let failures = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
                        job,
                    ))
                    .unwrap_or_else(|_| {
                        vec!["scenario job panicked on the UI thread".to_string()]
                    });
                    let _ = reply.send(failures);
                }
            });
            tx
        })
        .clone()
}

/// Submit a scenario to the UI thread and wait for its failure list.
fn run_scenario(job: impl FnOnce() -> Vec<String> + Send + 'static) -> Vec<String> {
    let (reply_tx, reply_rx) = mpsc::channel();
    ui_sender()
        .send((Box::new(job), reply_tx))
        .expect("UI thread must accept scenario jobs");
    reply_rx
        .recv_timeout(Duration::from_secs(60))
        .expect("scenario job must report back (event loop stuck or UI thread died?)")
}

/// Roles the plan treats as interactive (T2 scope). Kept as plain strings because
/// `UiElementNode.role` is a `String` in the current model.
const INTERACTIVE_ROLES: &[&str] = &[
    "button", "checkbox", "switch", "slider", "spinbox", "combobox", "textbox", "radio",
    "listitem", "tab",
];

// ---------------------------------------------------------------------------
// T1 — Toggle fires exactly once (covers plan W1)
// ---------------------------------------------------------------------------

/// Observation bundle collected on the driver thread; failure strings are built
/// on the UI thread *after* the event loop quits so a failure can never wedge
/// the loop.
struct T1Outcome {
    first_call: Result<(String, Option<String>), String>,
    toggled_after_first: Option<bool>,
    pointer_after_first: Option<i32>,
    accessible_after_first: Option<i32>,
    second_call: Result<(String, Option<String>), String>,
    toggled_after_second: Option<bool>,
    pointer_after_second: Option<i32>,
    accessible_after_second: Option<i32>,
}

#[test]
fn t1_toggle_fires_exactly_once_on_real_event_loop() {
    let failures = run_scenario(|| {
        slint::slint! {
            export component ToggleApp inherits Window {
                in-out property <bool> toggled: false;
                // Diagnostic counters: prove *which* dispatch paths fired.
                out property <int> pointer-hits: 0;
                out property <int> accessible-hits: 0;
                width: 400px;
                height: 300px;
                title: "T1 Toggle";
                // Fixture: the boolean is bound to BOTH the pointer path
                // (`clicked`) and the semantic path (`accessible-action-default`),
                // so any double dispatch (pointer + accessible on one call) shows
                // up as a net no-op. Single dispatch flips it exactly once.
                ta := TouchArea {
                    x: 0px;
                    y: 0px;
                    width: 200px;
                    height: 100px;
                    accessible-role: button;
                    accessible-label: "demo-toggle";
                    accessible-id: "demo-toggle";
                    accessible-action-default => {
                        root.toggled = !root.toggled;
                        root.accessible-hits += 1;
                    }
                    clicked => {
                        root.toggled = !root.toggled;
                        root.pointer-hits += 1;
                    }
                }
            }
        }

        let app = match ToggleApp::new() {
            Ok(a) => a,
            Err(e) => {
                return vec![format!("T1 setup: could not create live window: {e:?}")];
            }
        };
        let weak = app.as_weak();
        let bridge = Arc::new(SlintUiBridge::new());
        let controller = SlintWindowController::new(weak.clone(), bridge.clone());

        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("driver tokio runtime");
            let outcome = rt.block_on(async {
                macro_rules! read_state {
                    () => {
                        bridge
                            .run_on_ui({
                                let weak = weak.clone();
                                move || {
                                    weak.upgrade()
                                        .map(|w| {
                                            (
                                                w.get_toggled(),
                                                w.get_pointer_hits(),
                                                w.get_accessible_hits(),
                                            )
                                        })
                                        .ok_or(slate_agent::error::AgentError::WindowClosed)
                                }
                            })
                            .await
                            .ok()
                    };
                }
                let first_call = controller
                    .toggle_element("demo-toggle")
                    .await
                    .map(|r| {
                        (
                            r.message,
                            r.details
                                .get("resolution")
                                .and_then(|v| v.as_str())
                                .map(str::to_string),
                        )
                    })
                    .map_err(|e| e.to_string());
                let (t1, p1, a1) = read_state!().unwrap_or((false, -1, -1));
                let second_call = controller
                    .toggle_element("demo-toggle")
                    .await
                    .map(|r| {
                        (
                            r.message,
                            r.details
                                .get("resolution")
                                .and_then(|v| v.as_str())
                                .map(str::to_string),
                        )
                    })
                    .map_err(|e| e.to_string());
                let (t2, p2, a2) = read_state!().unwrap_or((false, -1, -1));
                T1Outcome {
                    first_call,
                    toggled_after_first: Some(t1),
                    pointer_after_first: Some(p1),
                    accessible_after_first: Some(a1),
                    second_call,
                    toggled_after_second: Some(t2),
                    pointer_after_second: Some(p2),
                    accessible_after_second: Some(a2),
                }
            });
            let _ = tx.send(outcome);
            // Always quit, even on failure, so the UI thread never hangs in the loop.
            let _ = slint::quit_event_loop();
        });

        if let Err(e) = slint::run_event_loop_until_quit() {
            return vec![format!("T1 setup: event loop failed: {e:?}")];
        }
        let outcome = match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(o) => o,
            Err(_) => {
                return vec![
                    "T1 setup: driver thread never reported back (loop quit first?)"
                        .to_string(),
                ];
            }
        };

        let mut failures = Vec::new();
        match &outcome.first_call {
            Ok((_, resolution)) => {
                // Coverage: accessible-id targets resolve through the
                // Slint-first query pipeline, never the substring walk.
                if resolution.as_deref() != Some("element-query") {
                    failures.push(format!(
                        "first call resolution is {resolution:?}, expected \
                         Some(\"element-query\") (accessible-id must take the \
                         ElementHandle query path; is SLINT_EMIT_DEBUG_INFO=1 \
                         set at build time?)"
                    ));
                }
            }
            Err(e) => failures.push(format!("first toggle_element call errored: {e}")),
        }
        // Mechanism lock (plan D2/W1): exactly one dispatch path fires per call.
        // (pointer, accessible) must be (0, 1): the button-role toggle takes the
        // semantic accessible path only. (1, 0) would mean pointer-only, (1, 1)
        // the old double dispatch, (0, 0) a silent no-op.
        let first_total =
            outcome.pointer_after_first.unwrap_or(-99) + outcome.accessible_after_first.unwrap_or(-99);
        if first_total != 1 {
            failures.push(format!(
                "first call fired {} dispatch path(s) (pointer-hits={:?}, \
                 accessible-hits={:?}), expected exactly 1 (plan W1: single dispatch)",
                first_total, outcome.pointer_after_first, outcome.accessible_after_first
            ));
        }
        if outcome.toggled_after_first != Some(true) {
            failures.push(format!(
                "after ONE toggle call, `toggled` is {:?} (pointer-hits={:?}, \
                 accessible-hits={:?}), expected Some(true)",
                outcome.toggled_after_first,
                outcome.pointer_after_first,
                outcome.accessible_after_first
            ));
        }
        match &outcome.second_call {
            Ok(_) => {}
            Err(e) => failures.push(format!("second toggle_element call errored: {e}")),
        }
        let second_total = outcome.pointer_after_second.unwrap_or(-99)
            + outcome.accessible_after_second.unwrap_or(-99)
            - first_total;
        if second_total != 1 {
            failures.push(format!(
                "second call fired {} additional dispatch path(s) \
                 (pointer-hits={:?}, accessible-hits={:?} cumulative), expected \
                 exactly 1 (plan W1: single dispatch)",
                second_total, outcome.pointer_after_second, outcome.accessible_after_second
            ));
        }
        if outcome.toggled_after_second != Some(false) {
            failures.push(format!(
                "after TWO toggle calls, `toggled` is {:?}, expected Some(false): each \
                 call must produce exactly one state transition (plan W1)",
                outcome.toggled_after_second
            ));
        }
        failures
    });

    assert!(
        failures.is_empty(),
        "T1 — toggle did not fire exactly once on a live window:\n  - {}",
        failures.join("\n  - ")
    );
}

// ---------------------------------------------------------------------------
// T2 — Stable unique IDs with supported actions + duplicate detector
// (covers plan U1, E1, W2)
// ---------------------------------------------------------------------------

#[test]
fn t2_inspect_tree_reports_stable_unique_ids_with_supported_actions() {
    let failures = run_scenario(|| {
        slint::slint! {
            export component QuadApp inherits Window {
                width: 400px;
                height: 300px;
                title: "T2 Identity";
                one := TouchArea {
                    x: 0px; y: 0px; width: 100px; height: 40px;
                    accessible-role: button;
                    accessible-label: "action-one";
                    accessible-id: "action-one";
                    clicked => {}
                }
                two := TouchArea {
                    x: 0px; y: 50px; width: 100px; height: 40px;
                    accessible-role: button;
                    accessible-label: "action-two";
                    accessible-id: "action-two";
                    clicked => {}
                }
                three := TouchArea {
                    x: 0px; y: 100px; width: 100px; height: 40px;
                    accessible-role: slider;
                    accessible-label: "level";
                    accessible-id: "level-slider";
                    accessible-action-default => {}
                }
                four := TouchArea {
                    x: 0px; y: 150px; width: 100px; height: 40px;
                    accessible-role: text-input;
                    accessible-label: "name";
                    accessible-id: "name-field";
                    accessible-action-default => {}
                }
            }
        }

        let app = match QuadApp::new() {
            Ok(a) => a,
            Err(e) => {
                return vec![format!("T2 setup: could not create live window: {e:?}")];
            }
        };
        let inspector = SlintWindowInspector::new(app.as_weak(), Arc::new(SlintUiBridge::new()));

        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("driver tokio runtime");
            let outcome = rt.block_on(async {
                let first = inspector.inspect_tree().await.map_err(|e| e.to_string());
                let second = inspector.inspect_tree().await.map_err(|e| e.to_string());
                (first, second)
            });
            let _ = tx.send(outcome);
            let _ = slint::quit_event_loop();
        });

        if let Err(e) = slint::run_event_loop_until_quit() {
            return vec![format!("T2 setup: event loop failed: {e:?}")];
        }
        let (first, second) = match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(o) => o,
            Err(_) => {
                return vec![
                    "T2 setup: driver thread never reported back (loop quit first?)"
                        .to_string(),
                ];
            }
        };

        let mut failures = Vec::new();
        let tree = match first {
            Ok(t) => t,
            Err(e) => {
                failures.push(format!("inspect_tree errored on a live window: {e}"));
                return failures;
            }
        };

        fn collect(node: &slate_agent::model::UiElementNode, out: &mut Vec<(String, String)>) {
            out.push((node.id.clone(), node.role.clone()));
            for child in &node.children {
                collect(child, out);
            }
        }
        let mut flat = Vec::new();
        collect(&tree.root, &mut flat);
        let interactive: Vec<(String, String)> = flat
            .iter()
            .filter(|(_, role)| INTERACTIVE_ROLES.contains(&role.as_str()))
            .cloned()
            .collect();

        // (a) Every interactive node has a non-empty id.
        for (id, role) in &interactive {
            if id.is_empty() {
                failures.push(format!(
                    "interactive node with role `{role}` has an empty id (plan U1)"
                ));
            }
        }

        // (b) No two nodes share the same id (the duplicate-detector case lives
        // in `t2_duplicate_accessible_ids_surface_an_error` below: a window
        // that DOES contain a colliding accessible-id must fail inspection
        // with an error naming it, plan W2).
        {
            let mut seen = std::collections::HashSet::new();
            let mut dups = std::collections::BTreeSet::new();
            for (id, _) in &interactive {
                if !id.is_empty() && !seen.insert(id.clone()) {
                    dups.insert(id.clone());
                }
            }
            if !dups.is_empty() {
                failures.push(format!(
                    "duplicate id(s) {dups:?} in a window that declares unique \
                     accessible-ids: identity contract violated (plan U1)"
                ));
            }
        }

        // (c) Each interactive node lists its supported actions (e.g. the semantic
        // actions the Slint-first layer can perform: accessible Default,
        // increment/decrement/expand, set_value, pointer). `UiElementNode` carries
        // no such annotation today, so every node fails this until Phase 2 lands.
        fn find<'a>(
            node: &'a slate_agent::model::UiElementNode,
            id: &str,
        ) -> Option<&'a slate_agent::model::UiElementNode> {
            if node.id == id {
                return Some(node);
            }
            node.children.iter().find_map(|c| find(c, id))
        }
        for (id, role) in &interactive {
            let actions = find(&tree.root, id)
                .and_then(|n| n.properties.get("supported_actions"))
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            if actions == 0 {
                failures.push(format!(
                    "interactive node id=`{id}` role=`{role}` lists no supported actions \
                     (plan U1: each node must annotate its supported actions)"
                ));
            }
        }

        // (d) Stability contract: two consecutive inspections must yield the same
        // id multiset (documents U1; informational — only appends on mismatch).
        if let Ok(second_tree) = &second {
            let mut flat2 = Vec::new();
            collect(&second_tree.root, &mut flat2);
            let mut ids1: Vec<&String> = flat.iter().map(|(id, _)| id).collect();
            let mut ids2: Vec<&String> = flat2.iter().map(|(id, _)| id).collect();
            ids1.sort();
            ids2.sort();
            if ids1 != ids2 {
                failures.push(format!(
                    "unstable IDs across consecutive inspections (plan U1):\n    first:  {ids1:?}\n    second: {ids2:?}"
                ));
            }
        }

        failures
    });

    assert!(
        failures.is_empty(),
        "T2 RED — inspect_tree identity contract violated on a live window:\n  - {}",
        failures.join("\n  - ")
    );
}

// ---------------------------------------------------------------------------
// T2 (W2) — Duplicate accessible-ids surface an inspection error
// (covers plan W2; companion to the clean-window T2 above)
// ---------------------------------------------------------------------------

#[test]
fn t2_duplicate_accessible_ids_surface_an_error() {
    let failures = run_scenario(|| {
        slint::slint! {
            export component DupApp inherits Window {
                width: 400px;
                height: 300px;
                title: "T2 Duplicates";
                // Two distinct elements deliberately share one accessible-id.
                // Inspection must fail with an error naming "dup-id" instead
                // of silently returning colliding nodes (first-match-wins).
                dup-a := TouchArea {
                    x: 0px; y: 0px; width: 100px; height: 40px;
                    accessible-role: button;
                    accessible-label: "dup-a";
                    accessible-id: "dup-id";
                    clicked => {}
                }
                dup-b := TouchArea {
                    x: 0px; y: 50px; width: 100px; height: 40px;
                    accessible-role: button;
                    accessible-label: "dup-b";
                    accessible-id: "dup-id";
                    clicked => {}
                }
            }
        }

        let app = match DupApp::new() {
            Ok(a) => a,
            Err(e) => {
                return vec![format!("T2-dup setup: could not create live window: {e:?}")];
            }
        };
        let inspector = SlintWindowInspector::new(app.as_weak(), Arc::new(SlintUiBridge::new()));

        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("driver tokio runtime");
            let outcome = rt.block_on(async {
                inspector.inspect_tree().await.map_err(|e| e.to_string())
            });
            let _ = tx.send(outcome);
            let _ = slint::quit_event_loop();
        });

        if let Err(e) = slint::run_event_loop_until_quit() {
            return vec![format!("T2-dup setup: event loop failed: {e:?}")];
        }
        let outcome = match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(o) => o,
            Err(_) => {
                return vec![
                    "T2-dup setup: driver thread never reported back (loop quit first?)"
                        .to_string(),
                ];
            }
        };

        match outcome {
            Ok(_) => vec![
                "inspect_tree SUCCEEDED on a window with duplicate accessible-id \
                 \"dup-id\": duplicates must surface as an error naming the \
                 offenders (plan W2)"
                    .to_string(),
            ],
            Err(e) if e.contains("dup-id") => Vec::new(),
            Err(e) => vec![format!(
                "inspect_tree failed on duplicate accessible-ids but the error \
                 does not name the offender (plan W2 requires naming): {e}"
            )],
        }
    });

    assert!(
        failures.is_empty(),
        "T2 (W2) — duplicate accessible-id did not surface a naming error:\n  - {}",
        failures.join("\n  - ")
    );
}

// ---------------------------------------------------------------------------
// T1b — click_element (not toggle_element) flips a button exactly once
// (review-fix B4: the T1 toggle path and the click path are distinct
// dispatches; both must single-fire on a button-role fixture).
// ---------------------------------------------------------------------------

struct T1bOutcome {
    first_call: Result<(String, Option<String>), String>,
    on_after_first: Option<bool>,
    pointer_after_first: Option<i32>,
    accessible_after_first: Option<i32>,
    second_call: Result<(String, Option<String>), String>,
    on_after_second: Option<bool>,
}

fn resolution_of(r: &slate_agent::model::ActionResult) -> Option<String> {
    r.details
        .get("resolution")
        .and_then(|v| v.as_str())
        .map(str::to_string)
}

#[test]
fn t1b_click_element_fires_exactly_once_on_real_event_loop() {
    let failures = run_scenario(|| {
        slint::slint! {
            export component ClickApp inherits Window {
                in-out property <bool> on: false;
                out property <int> pointer-hits: 0;
                out property <int> accessible-hits: 0;
                width: 400px;
                height: 300px;
                title: "T1b Click";
                ta := TouchArea {
                    x: 0px;
                    y: 0px;
                    width: 200px;
                    height: 100px;
                    accessible-role: button;
                    accessible-label: "demo-button";
                    accessible-id: "demo-button";
                    accessible-action-default => {
                        root.on = !root.on;
                        root.accessible-hits += 1;
                    }
                    clicked => {
                        root.on = !root.on;
                        root.pointer-hits += 1;
                    }
                }
            }
        }

        let app = match ClickApp::new() {
            Ok(a) => a,
            Err(e) => {
                return vec![format!("T1b setup: could not create live window: {e:?}")];
            }
        };
        let weak = app.as_weak();
        let bridge = Arc::new(SlintUiBridge::new());
        let controller = SlintWindowController::new(weak.clone(), bridge.clone());

        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("driver tokio runtime");
            let outcome = rt.block_on(async {
                macro_rules! read_state {
                    () => {
                        bridge
                            .run_on_ui({
                                let weak = weak.clone();
                                move || {
                                    weak.upgrade()
                                        .map(|w| {
                                            (
                                                w.get_on(),
                                                w.get_pointer_hits(),
                                                w.get_accessible_hits(),
                                            )
                                        })
                                        .ok_or(slate_agent::error::AgentError::WindowClosed)
                                }
                            })
                            .await
                            .ok()
                    };
                }
                let first_call = controller
                    .click_element("demo-button")
                    .await
                    .map(|r| (r.message.clone(), resolution_of(&r)))
                    .map_err(|e| e.to_string());
                let (o1, p1, a1) = read_state!().unwrap_or((false, -1, -1));
                let second_call = controller
                    .click_element("demo-button")
                    .await
                    .map(|r| (r.message.clone(), resolution_of(&r)))
                    .map_err(|e| e.to_string());
                let (o2, _, _) = read_state!().unwrap_or((false, -1, -1));
                T1bOutcome {
                    first_call,
                    on_after_first: Some(o1),
                    pointer_after_first: Some(p1),
                    accessible_after_first: Some(a1),
                    second_call,
                    on_after_second: Some(o2),
                }
            });
            let _ = tx.send(outcome);
            let _ = slint::quit_event_loop();
        });

        if let Err(e) = slint::run_event_loop_until_quit() {
            return vec![format!("T1b setup: event loop failed: {e:?}")];
        }
        let outcome = match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(o) => o,
            Err(_) => {
                return vec![
                    "T1b setup: driver thread never reported back (loop quit first?)"
                        .to_string(),
                ];
            }
        };

        let mut failures = Vec::new();
        match &outcome.first_call {
            Ok((_, resolution)) => {
                if resolution.as_deref() != Some("element-query") {
                    failures.push(format!(
                        "first click resolution is {resolution:?}, expected \
                         Some(\"element-query\") (is SLINT_EMIT_DEBUG_INFO=1 \
                         set at build time?)"
                    ));
                }
            }
            Err(e) => failures.push(format!("first click_element call errored: {e}")),
        }
        // Mechanism lock (plan D2/W1 via the CLICK path): (pointer,
        // accessible) must be (0, 1) — button-role clicks take the semantic
        // accessible path only.
        if (outcome.pointer_after_first, outcome.accessible_after_first) != (Some(0), Some(1)) {
            failures.push(format!(
                "first click mechanism is (pointer-hits={:?}, accessible-hits={:?}), \
                 expected (0, 1): click_element on a button must single-fire the \
                 semantic path",
                outcome.pointer_after_first, outcome.accessible_after_first
            ));
        }
        if outcome.on_after_first != Some(true) {
            failures.push(format!(
                "after ONE click call, `on` is {:?}, expected Some(true)",
                outcome.on_after_first
            ));
        }
        match &outcome.second_call {
            Ok(_) => {}
            Err(e) => failures.push(format!("second click_element call errored: {e}")),
        }
        if outcome.on_after_second != Some(false) {
            failures.push(format!(
                "after TWO click calls, `on` is {:?}, expected Some(false)",
                outcome.on_after_second
            ));
        }
        failures
    });

    assert!(
        failures.is_empty(),
        "T1b — click_element did not fire exactly once on a live window:\n  - {}",
        failures.join("\n  - ")
    );
}

// ---------------------------------------------------------------------------
// T1c — toggle_element on a non-toggleable role is a truthful error, not a
// silent no-op success (re-review B1 advisory: the positive path is locked by
// T1, but nothing drove the negative arm of the toggle role gate).
// ---------------------------------------------------------------------------

#[test]
fn t1c_toggle_non_toggleable_role_is_invalid_operation() {
    let failures = run_scenario(|| {
        slint::slint! {
            export component NonToggleApp inherits Window {
                width: 400px;
                height: 300px;
                title: "T1c Non-toggleable";
                slider_area := TouchArea {
                    x: 0px;
                    y: 0px;
                    width: 200px;
                    height: 50px;
                    accessible-role: slider;
                    accessible-label: "volume";
                    accessible-id: "volume-slider";
                }
                text_area := TouchArea {
                    x: 0px;
                    y: 60px;
                    width: 200px;
                    height: 50px;
                    accessible-role: text;
                    accessible-label: "note";
                    accessible-id: "note-text";
                }
            }
        }

        let app = match NonToggleApp::new() {
            Ok(a) => a,
            Err(e) => {
                return vec![format!("T1c setup: could not create live window: {e:?}")];
            }
        };
        let weak = app.as_weak();
        let bridge = Arc::new(SlintUiBridge::new());
        let controller = SlintWindowController::new(weak.clone(), bridge.clone());

        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("driver tokio runtime");
            let outcome = rt.block_on(async {
                let slider = controller.toggle_element("volume-slider").await;
                let text = controller.toggle_element("note-text").await;
                (slider.map_err(|e| e.to_string()), text.map_err(|e| e.to_string()))
            });
            let _ = tx.send(outcome);
            // Always quit, even on failure, so the UI thread never hangs in the loop.
            let _ = slint::quit_event_loop();
        });

        if let Err(e) = slint::run_event_loop_until_quit() {
            return vec![format!("T1c setup: event loop failed: {e:?}")];
        }
        let (slider_res, text_res) = match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(o) => o,
            Err(_) => {
                return vec![
                    "T1c setup: driver thread never reported back (loop quit first?)"
                        .to_string(),
                ];
            }
        };

        let mut failures = Vec::new();
        match &slider_res {
            Err(msg) => {
                if !msg.contains("volume-slider") {
                    failures.push(format!(
                        "toggle on slider errored but does not name the target: {msg}"
                    ));
                }
            }
            Ok(ok) => failures.push(format!(
                "toggle_element on a slider-role element reported SUCCESS ({ok:?}): \
                 non-toggleable roles must return invalid_operation, not a silent no-op"
            )),
        }
        match &text_res {
            Err(msg) => {
                if !msg.contains("note-text") {
                    failures.push(format!(
                        "toggle on text-role element errored but does not name the target: {msg}"
                    ));
                }
            }
            Ok(ok) => failures.push(format!(
                "toggle_element on a text-role element reported SUCCESS ({ok:?}): \
                 non-toggleable roles must return invalid_operation, not a silent no-op"
            )),
        }
        failures
    });

    assert!(
        failures.is_empty(),
        "T1c — toggle on non-toggleable roles must fail loudly:\n  - {}",
        failures.join("\n  - ")
    );
}

// ---------------------------------------------------------------------------
// T3 probe — targeting precedence on a live window: accessible-id resolves
// through the query pipeline, debug-id is the second query key, and a
// duplicate accessible-id is an error naming the offender on EVERY
// query-first path (click, toggle, send_keys, set_value — W2 protects them
// all via the shared `query_element?`).
// ---------------------------------------------------------------------------

/// Drive one `click_element` probe: build nothing, just click + read the
/// flag. The caller owns window construction; this pumps the loop once.
fn drive_click_probe<T: slint::ComponentHandle + 'static>(
    weak: slint::Weak<T>,
    target: String,
    read_flag: impl Fn(slint::Weak<T>) -> Option<bool> + Send + 'static,
) -> (Result<(String, Option<String>), String>, Option<bool>) {
    let bridge = Arc::new(SlintUiBridge::new());
    let controller = SlintWindowController::new(weak.clone(), bridge.clone());
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("driver tokio runtime");
        let outcome = rt.block_on(async {
            let call = controller
                .click_element(&target)
                .await
                .map(|r| (r.message.clone(), resolution_of(&r)))
                .map_err(|e| e.to_string());
            let flag = bridge
                .run_on_ui({
                    let weak = weak.clone();
                    move || {
                        Ok(read_flag(weak))
                            as Result<Option<bool>, slate_agent::error::AgentError>
                    }
                })
                .await
                .ok()
                .flatten();
            (call, flag)
        });
        let _ = tx.send(outcome);
        let _ = slint::quit_event_loop();
    });
    match slint::run_event_loop_until_quit() {
        Err(e) => (
            Err(format!("event loop failed: {e:?}")),
            None,
        ),
        Ok(()) => match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(o) => o,
            Err(_) => (Err("driver thread never reported back".to_string()), None),
        },
    }
}

#[test]
fn t3_targeting_probe_accessible_id_then_debug_id_then_dup_error() {
    let failures = run_scenario(|| {
        let mut failures = Vec::new();

        // Phase A: accessible-id resolves through the query pipeline.
        slint::slint! {
            export component ProbeAApp inherits Window {
                in-out property <bool> on: false;
                width: 400px;
                height: 300px;
                title: "probe-a";
                ta := TouchArea {
                    x: 0px; y: 0px; width: 200px; height: 100px;
                    accessible-role: button;
                    accessible-label: "probe-a";
                    accessible-id: "probe-a";
                    accessible-action-default => { root.on = !root.on; }
                    clicked => { root.on = !root.on; }
                }
            }
        }
        let app_a = match ProbeAApp::new() {
            Ok(a) => a,
            Err(e) => {
                return vec![format!("probe-A setup: could not create live window: {e:?}")];
            }
        };
        let (call_a, flag_a) = drive_click_probe(
            app_a.as_weak(),
            "probe-a".to_string(),
            |w: slint::Weak<ProbeAApp>| w.upgrade().map(|x| x.get_on()),
        );
        match call_a {
            Ok((_, ref resolution)) if flag_a == Some(true) => {
                if resolution.as_deref() != Some("element-query") {
                    failures.push(format!(
                        "probe-A resolution is {resolution:?}, expected \
                         Some(\"element-query\") (accessible-id must take the query path)"
                    ));
                }
            }
            other => failures.push(format!(
                "probe-A click on accessible-id failed: call={other:?}, on={flag_a:?} \
                 (expected Ok + on=true)"
            )),
        }
        drop(app_a);

        // Phase B: no accessible-id — the Slint debug id (`plain := ...`) is
        // the second query key. Requires debug info in the build
        // (SLINT_EMIT_DEBUG_INFO=1 in the Justfile test recipe); without it
        // the query misses and this phase reports legacy-walk/failure
        // instead of element-query.
        slint::slint! {
            export component ProbeBApp inherits Window {
                in-out property <bool> on: false;
                width: 400px;
                height: 300px;
                title: "probe-b";
                plain := TouchArea {
                    x: 0px; y: 0px; width: 200px; height: 100px;
                    accessible-role: button;
                    accessible-label: "plain-label";
                    accessible-action-default => { root.on = !root.on; }
                    clicked => { root.on = !root.on; }
                }
            }
        }
        let app_b = match ProbeBApp::new() {
            Ok(a) => a,
            Err(e) => {
                return vec![format!("probe-B setup: could not create live window: {e:?}")];
            }
        };
        let (call_b, flag_b) = drive_click_probe(
            app_b.as_weak(),
            "plain".to_string(),
            |w: slint::Weak<ProbeBApp>| w.upgrade().map(|x| x.get_on()),
        );
        match call_b {
            Ok((_, ref resolution)) if flag_b == Some(true) => {
                if resolution.as_deref() != Some("element-query") {
                    failures.push(format!(
                        "probe-B resolution is {resolution:?}, expected \
                         Some(\"element-query\") (debug-id must take the query path; \
                         is SLINT_EMIT_DEBUG_INFO set?)"
                    ));
                }
            }
            other => failures.push(format!(
                "probe-B click on debug-id failed: call={other:?}, on={flag_b:?} \
                 (expected Ok + on=true; is SLINT_EMIT_DEBUG_INFO set?)"
            )),
        }
        drop(app_b);

        // Phase C: duplicate accessible-id is an error naming the offender on
        // every query-first path (click, toggle, send_keys, set_value).
        slint::slint! {
            export component ProbeCApp inherits Window {
                in-out property <string> text: "";
                width: 400px;
                height: 300px;
                title: "probe-c";
                a := TouchArea {
                    x: 0px; y: 0px; width: 100px; height: 40px;
                    accessible-role: button;
                    accessible-label: "dup-a";
                    accessible-id: "dup-probe";
                    clicked => {}
                }
                b := TouchArea {
                    x: 0px; y: 50px; width: 100px; height: 40px;
                    accessible-role: button;
                    accessible-label: "dup-b";
                    accessible-id: "dup-probe";
                    clicked => {}
                }
            }
        }
        let app_c = match ProbeCApp::new() {
            Ok(a) => a,
            Err(e) => {
                return vec![format!("probe-C setup: could not create live window: {e:?}")];
            }
        };
        {
            let weak = app_c.as_weak();
            let bridge = Arc::new(SlintUiBridge::new());
            let controller = SlintWindowController::new(weak.clone(), bridge);
            let (tx, rx) = mpsc::channel();
            std::thread::spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("driver tokio runtime");
                let outcome = rt.block_on(async {
                    let c = controller
                        .click_element("dup-probe")
                        .await
                        .map(|r| r.message)
                        .map_err(|e| e.to_string());
                    let t = controller
                        .toggle_element("dup-probe")
                        .await
                        .map(|r| r.message)
                        .map_err(|e| e.to_string());
                    let k = controller
                        .send_keys(Some("dup-probe"), "x")
                        .await
                        .map(|r| r.message)
                        .map_err(|e| e.to_string());
                    let s = controller
                        .set_value("dup-probe", "x")
                        .await
                        .map(|r| r.message)
                        .map_err(|e| e.to_string());
                    (c, t, k, s)
                });
                let _ = tx.send(outcome);
                let _ = slint::quit_event_loop();
            });
            if let Err(e) = slint::run_event_loop_until_quit() {
                return vec![format!("probe-C setup: event loop failed: {e:?}")];
            }
            match rx.recv_timeout(Duration::from_secs(30)) {
                Ok((c, t, k, s)) => {
                    for (name, res) in [
                        ("click_element", c),
                        ("toggle_element", t),
                        ("send_keys", k),
                        ("set_value", s),
                    ] {
                        match res {
                            Err(e) if e.contains("dup-probe") => {}
                            Err(e) => failures.push(format!(
                                "probe-C {name} failed on duplicate accessible-ids but the \
                                 error does not name the offender (W2 requires naming): {e}"
                            )),
                            Ok(msg) => failures.push(format!(
                                "probe-C {name} SUCCEEDED on duplicate accessible-id \
                                 \"dup-probe\" ({msg}): duplicates must error, never \
                                 first-match-wins"
                            )),
                        }
                    }
                }
                Err(_) => failures.push(
                    "probe-C setup: driver thread never reported back".to_string(),
                ),
            }
        }
        drop(app_c);

        failures
    });

    assert!(
        failures.is_empty(),
        "T3 probe — live targeting precedence violated:\n  - {}",
        failures.join("\n  - ")
    );
}
