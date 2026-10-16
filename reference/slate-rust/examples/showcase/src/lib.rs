//! Slate Showcase Application with Embedded MCP Agent Remote Control

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use slint::ComponentHandle;

use slate::agent::{
    builder, init, AgentBuilderMcpExt, AgentError, AgentHandle, AppState, DiagnosticMetrics,
    SlintUiBridge, StateProvider,
};
use slate::core::task::{spawn_compute, TaskCancellation};

slint::include_modules!();


/// State provider reading live application properties from `MainWindow`.
pub struct ShowcaseStateProvider {
    weak: slint::Weak<MainWindow>,
    bridge: Arc<SlintUiBridge>,
}

impl ShowcaseStateProvider {
    pub fn new(weak: slint::Weak<MainWindow>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl StateProvider for ShowcaseStateProvider {
    async fn get_state(&self, query: Option<&str>) -> Result<AppState, AgentError> {
        let weak = self.weak.clone();
        let query_owned = query.map(|s| s.to_string());
        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let tab = win.get_active_tab();
                let active_view = match tab {
                    0 => "buttons",
                    1 => "forms",
                    2 => "data",
                    3 => "feedback",
                    4 => "navigation",
                    5 => "overlays",
                    6 => "compute",
                    7 => "settings",
                    _ => "other",
                }
                .to_string();

                let is_dark = win.global::<SlateTheme>().get_is_dark();
                let mut props: HashMap<String, serde_json::Value> = HashMap::new();
                props.insert("active_tab".into(), serde_json::json!(tab));
                props.insert("active_view".into(), serde_json::json!(&active_view));
                props.insert("is_dark".into(), serde_json::json!(is_dark));
                props.insert("counter".into(), serde_json::json!(win.get_counter()));
                props.insert(
                    "demo_input_text".into(),
                    serde_json::json!(win.get_demo_input_text().as_str()),
                );
                props.insert(
                    "demo_textarea_text".into(),
                    serde_json::json!(win.get_demo_textarea_text().as_str()),
                );
                props.insert(
                    "demo_switch_1".into(),
                    serde_json::json!(win.get_demo_switch_1()),
                );
                props.insert(
                    "demo_switch_2".into(),
                    serde_json::json!(win.get_demo_switch_2()),
                );
                props.insert(
                    "compute_running".into(),
                    serde_json::json!(win.get_compute_running()),
                );
                props.insert(
                    "compute_progress".into(),
                    serde_json::json!(win.get_compute_progress()),
                );
                props.insert(
                    "compute_status".into(),
                    serde_json::json!(win.get_compute_status().as_str()),
                );
                props.insert(
                    "compute_result".into(),
                    serde_json::json!(win.get_compute_result().as_str()),
                );
                props.insert("modal_open".into(), serde_json::json!(win.get_modal_open()));
                props.insert("sheet_open".into(), serde_json::json!(win.get_sheet_open()));
                props.insert("alert_open".into(), serde_json::json!(win.get_alert_open()));
                props.insert("popover_open".into(), serde_json::json!(win.get_popover_open()));
                props.insert("toast_visible".into(), serde_json::json!(win.get_toast_visible()));
                props.insert("workspace_left_collapsed".into(), serde_json::json!(win.get_workspace_left_collapsed()));
                props.insert("workspace_right_collapsed".into(), serde_json::json!(win.get_workspace_right_collapsed()));
                props.insert("workspace_center_maximized".into(), serde_json::json!(win.get_workspace_center_maximized()));

                if let Some(ref key) = query_owned {
                    props.retain(|k, _| k == key);
                }

                let mut state = AppState::new(active_view);
                for (k, v) in props {
                    state = state.with_property(k, v);
                }
                Ok(state)
            })
            .await
    }

    async fn get_diagnostics(&self) -> Result<DiagnosticMetrics, AgentError> {
        Ok(DiagnosticMetrics::default())
    }

    async fn set_property(&self, key: &str, value: serde_json::Value) -> Result<(), AgentError> {
        let weak = self.weak.clone();
        let key_str = key.to_string();
        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                match key_str.as_str() {
                    "active_tab" => {
                        if let Some(tab) = value.as_i64() {
                            win.set_active_tab(tab as i32);
                        }
                    }
                    "demo_input_text" => {
                        if let Some(s) = value.as_str() {
                            win.set_demo_input_text(s.into());
                        }
                    }
                    "demo_textarea_text" => {
                        if let Some(s) = value.as_str() {
                            win.set_demo_textarea_text(s.into());
                        }
                    }
                    "demo_switch_1" => {
                        if let Some(b) = value.as_bool() {
                            win.set_demo_switch_1(b);
                        }
                    }
                    "counter" => {
                        if let Some(c) = value.as_i64() {
                            win.set_counter(c as i32);
                        }
                    }
                    "is_dark" => {
                        if let Some(b) = value.as_bool() {
                            win.global::<SlateTheme>().set_is_dark(b);
                        }
                    }
                    "modal_open" => {
                        if let Some(b) = value.as_bool() {
                            win.set_modal_open(b);
                        }
                    }
                    "sheet_open" => {
                        if let Some(b) = value.as_bool() {
                            win.set_sheet_open(b);
                        }
                    }
                    "alert_open" => {
                        if let Some(b) = value.as_bool() {
                            win.set_alert_open(b);
                        }
                    }
                    "popover_open" => {
                        if let Some(b) = value.as_bool() {
                            win.set_popover_open(b);
                        }
                    }
                    "toast_visible" => {
                        if let Some(b) = value.as_bool() {
                            win.set_toast_visible(b);
                        }
                    }
                    "workspace_left_collapsed" => {
                        if let Some(b) = value.as_bool() {
                            win.set_workspace_left_collapsed(b);
                        }
                    }
                    "workspace_right_collapsed" => {
                        if let Some(b) = value.as_bool() {
                            win.set_workspace_right_collapsed(b);
                        }
                    }
                    "workspace_center_maximized" => {
                        if let Some(b) = value.as_bool() {
                            win.set_workspace_center_maximized(b);
                        }
                    }
                    _ => return Err(AgentError::state_error(format!("Unknown property: {}", key_str))),
                }
                Ok(())
            })
            .await
    }
}



/// Initialize the showcase agent remote control server using `slate::agent::builder`.
pub fn init_showcase_agent(window: &MainWindow) -> Result<AgentHandle, AgentError> {
    let bridge = Arc::new(SlintUiBridge::new());
    let weak = window.as_weak();

    let state_provider = Arc::new(ShowcaseStateProvider::new(weak, bridge));

    builder(window)
        .with_name("slate-showcase")
        .with_version(env!("CARGO_PKG_VERSION"))
        .with_state_provider(state_provider)
        .with_mcp_stdio()
        .start()
}

/// Native C ABI entrypoint for invoking the Slate Component Gallery from foreign runtimes (Carbon / C++).
#[no_mangle]
pub extern "C" fn slate_gallery_run_native(
    title: *const std::os::raw::c_char,
    initial_tab: i32,
    force_dark: bool,
    enable_mcp: bool,
) -> i32 {
    let title_str = if title.is_null() {
        "Slate Desktop Component Gallery (Carbon)"
    } else {
        match unsafe { std::ffi::CStr::from_ptr(title) }.to_str() {
            Ok(s) => s,
            Err(_) => "Slate Desktop Component Gallery (Carbon)",
        }
    };

    let args: Vec<String> = std::env::args().collect();
    let is_headless = args.iter().any(|a| a == "--headless");
    let is_agent_mode = enable_mcp
        || args.iter().any(|a| a == "--agent" || a == "--mcp")
        || std::env::var("SLATE_AGENT").map(|v| v == "1").unwrap_or(false);
    let is_minimal_init = args.iter().any(|a| a == "--minimal-init");

    match run_gallery_window(
        Some(title_str),
        Some(initial_tab),
        Some(force_dark),
        is_headless,
        is_agent_mode,
        is_minimal_init,
    ) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("[ERROR] Slate Gallery run failed: {e}");
            1
        }
    }
}

pub fn run_from_cli() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let is_headless = args.iter().any(|a| a == "--headless");
    let is_agent_mode = args.iter().any(|a| a == "--agent" || a == "--mcp")
        || std::env::var("SLATE_AGENT").map(|v| v == "1").unwrap_or(false);
    let is_minimal_init = args.iter().any(|a| a == "--minimal-init");

    let initial_tab = if let Some(tab_pos) = args.iter().position(|a| a == "--tab") {
        args.get(tab_pos + 1).and_then(|val| val.parse::<i32>().ok())
    } else {
        std::env::var("SLATE_ACTIVE_TAB").ok().and_then(|val| val.parse::<i32>().ok())
    };

    run_gallery_window(None, initial_tab, None, is_headless, is_agent_mode, is_minimal_init)
}

pub fn run_gallery_window(
    _title: Option<&str>,
    initial_tab: Option<i32>,
    force_dark: Option<bool>,
    is_headless: bool,
    is_agent_mode: bool,
    is_minimal_init: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if is_headless || (std::env::var("SLINT_BACKEND").is_err()
        && std::env::var("DISPLAY").is_err()
        && std::env::var("WAYLAND_DISPLAY").is_err())
    {
        std::env::set_var("SLINT_BACKEND", "software");
    }

    slate::init();
    log::info!("Starting Slate Showcase application...");

    let main_window = MainWindow::new()?;
    if let Some(tab) = initial_tab {
        main_window.set_active_tab(tab);
    }
    if let Some(dark) = force_dark {
        let theme = main_window.global::<SlateTheme>();
        theme.set_is_dark(dark);
    }
    let current_task: Arc<Mutex<Option<TaskCancellation>>> = Arc::new(Mutex::new(None));
    let task_generation: Arc<AtomicU64> = Arc::new(AtomicU64::new(0));

    // Wire Increment Counter Callback
    {
        let window_weak = main_window.as_weak();
        main_window.on_increment_counter(move || {
            if let Some(win) = window_weak.upgrade() {
                win.set_counter(win.get_counter() + 1);
            }
        });
    }

    // Wire Start Compute Callback
    {
        let window_weak = main_window.as_weak();
        let task_slot = current_task.clone();
        let task_gen = task_generation.clone();

        main_window.on_start_compute(move || {
            let Some(window) = window_weak.upgrade() else { return; };

            // 1. Cancel and drop any active computation to prevent orphan thread leaks
            if let Some(existing) = task_slot.lock().unwrap().take() {
                existing.cancel();
            }

            // 2. Increment task generation to isolate callbacks from superseded tasks
            let gen_id = task_gen.fetch_add(1, Ordering::SeqCst) + 1;
            let gen_progress = task_gen.clone();
            let gen_complete = task_gen.clone();

            window.set_compute_running(true);
            window.set_compute_progress(0.0);
            window.set_compute_status("Computing".into());
            window.set_compute_result("Working on 20,000,000 samples...".into());

            let win_progress = window_weak.clone();
            let win_complete = window_weak.clone();

            let cancellation = spawn_compute(
                |is_cancelled, progress| {
                    let total_samples: u64 = 20_000_000;
                    let batch_size: u64 = 200_000;
                    let mut inside_circle: u64 = 0;
                    let mut lfsr: u64 = 0xACE1;

                    for i in 0..total_samples {
                        if i % batch_size == 0 {
                            if is_cancelled() {
                                return None;
                            }
                            progress(i as f32 / total_samples as f32);
                            std::thread::sleep(std::time::Duration::from_millis(5));
                        }

                        lfsr = (lfsr >> 1) ^ (-( (lfsr & 1) as i64 ) as u64 & 0xB400);
                        let x = (lfsr as f64) / (u64::MAX as f64) * 2.0 - 1.0;

                        lfsr = (lfsr >> 1) ^ (-( (lfsr & 1) as i64 ) as u64 & 0xB400);
                        let y = (lfsr as f64) / (u64::MAX as f64) * 2.0 - 1.0;

                        if x * x + y * y <= 1.0 {
                            inside_circle += 1;
                        }
                    }

                    Some(4.0 * (inside_circle as f64) / (total_samples as f64))
                },
                move |pct| {
                    if gen_progress.load(Ordering::SeqCst) == gen_id {
                        if let Some(win) = win_progress.upgrade() {
                            win.set_compute_progress(pct);
                        }
                    }
                },
                move |result| {
                    if gen_complete.load(Ordering::SeqCst) == gen_id {
                        if let Some(win) = win_complete.upgrade() {
                            win.set_compute_running(false);
                            match result {
                                Some(pi) => {
                                    win.set_compute_progress(1.0);
                                    win.set_compute_status("Completed".into());
                                    win.set_compute_result(format!("π ≈ {:.6}", pi).into());
                                }
                                None => {
                                    win.set_compute_status("Cancelled".into());
                                    win.set_compute_result("Computation was cancelled".into());
                                }
                            }
                        }
                    }
                },
            );

            *task_slot.lock().unwrap() = Some(cancellation);
        });
    }

    // Wire Cancel Compute Callback
    {
        let task_slot = current_task.clone();
        let task_gen = task_generation.clone();
        let window_weak = main_window.as_weak();
        main_window.on_cancel_compute(move || {
            task_gen.fetch_add(1, Ordering::SeqCst);
            if let Some(handle) = task_slot.lock().unwrap().take() {
                handle.cancel();
            }
            if let Some(win) = window_weak.upgrade() {
                if win.get_compute_running() {
                    win.set_compute_running(false);
                    win.set_compute_status("Cancelled".into());
                    win.set_compute_result("Computation was cancelled".into());
                }
            }
        });
    }

    // Wire Theme Toggle Callback
    {
        let window_weak = main_window.as_weak();
        main_window.on_toggle_theme(move || {
            if let Some(win) = window_weak.upgrade() {
                let theme = win.global::<SlateTheme>();
                theme.set_is_dark(!theme.get_is_dark());
            }
        });
    }

    // Initialize Agent Remote Control (FEAT-INT-01 / FEAT-INT-02)
    let _agent_handle: Option<AgentHandle> = if is_agent_mode || is_headless {
        if is_minimal_init {
            Some(init(&main_window)?)
        } else {
            Some(init_showcase_agent(&main_window)?)
        }
    } else {
        None
    };

    if let Some(tab_pos) = args.iter().position(|a| a == "--tab") {
        if let Some(val) = args.get(tab_pos + 1) {
            if let Ok(t) = val.parse::<i32>() {
                main_window.set_active_tab(t);
            }
        }
    } else if let Ok(val) = std::env::var("SLATE_ACTIVE_TAB") {
        if let Ok(t) = val.parse::<i32>() {
            main_window.set_active_tab(t);
        }
    }

    if args.iter().any(|a| a == "--left-collapsed") {
        main_window.set_workspace_left_collapsed(true);
    }
    if args.iter().any(|a| a == "--right-collapsed") {
        main_window.set_workspace_right_collapsed(true);
    }
    if args.iter().any(|a| a == "--center-maximized") {
        main_window.set_workspace_center_maximized(true);
    }
    if args.iter().any(|a| a == "--sheet-open") {
        main_window.set_sheet_open(true);
    }
    if args.iter().any(|a| a == "--alert-open") {
        main_window.set_alert_open(true);
    }
    if args.iter().any(|a| a == "--modal-open") {
        main_window.set_modal_open(true);
    }

    main_window.run()?;
    Ok(())
}
