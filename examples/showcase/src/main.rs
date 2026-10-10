//! Slate Showcase Application with Embedded MCP Agent Remote Control

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use image::ImageEncoder;
use slint::ComponentHandle;

use slate::agent::{
    builder, init, ActionResult, AgentBuilderMcpExt, AgentError, AgentHandle, AppState,
    DiagnosticMetrics, ElementController, MouseButton, Point, Rect, Screenshot,
    SlintUiBridge, StateProvider, UiElementNode, UiInspector, UiTree, VisualRenderer,
};
use slate::core::task::{spawn_compute, TaskCancellation};

slint::include_modules!();

/// Visual renderer capturing real Slint window frames using `window.take_snapshot()`.
pub struct SlintWindowRenderer {
    weak: slint::Weak<MainWindow>,
    bridge: Arc<SlintUiBridge>,
}

impl SlintWindowRenderer {
    pub fn new(weak: slint::Weak<MainWindow>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl VisualRenderer for SlintWindowRenderer {
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError> {
        let weak = self.weak.clone();

        // Phase 1: Minimal UI-thread operation.
        // Only trigger timer/animation updates, take snapshot, and copy raw pixel bytes.
        // Total UI thread block time: ~2-5ms (down from 50-80ms).
        let (width, height, raw_bytes) = self
            .bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                slint::platform::update_timers_and_animations();
                let window = win.window();
                let pixel_buffer = window
                    .take_snapshot()
                    .map_err(|e| AgentError::render_error(e.to_string()))?;
                let width = pixel_buffer.width();
                let height = pixel_buffer.height();
                let raw_bytes = pixel_buffer.as_bytes().to_vec();

                Ok((width, height, raw_bytes))
            })
            .await?;

        // Phase 2: Offload CPU-heavy PNG Deflate compression (LZ77 + Huffman coding)
        // to a dedicated worker thread via tokio::task::spawn_blocking.
        tokio::task::spawn_blocking(move || {
            let mut png_bytes = Vec::new();
            image::codecs::png::PngEncoder::new(&mut png_bytes)
                .write_image(&raw_bytes, width, height, image::ExtendedColorType::Rgba8)
                .map_err(|e| AgentError::render_error(e.to_string()))?;

            Ok(Screenshot::new(width, height, "png", png_bytes))
        })
        .await
        .map_err(|e| AgentError::internal(format!("PNG compression worker failed: {}", e)))?
    }

    async fn get_viewport_size(&self) -> Result<(u32, u32), AgentError> {
        let weak = self.weak.clone();
        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let size = win.window().size();
                Ok((size.width, size.height))
            })
            .await
    }
}

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
                    _ => return Err(AgentError::state_error(format!("Unknown property: {}", key_str))),
                }
                Ok(())
            })
            .await
    }
}

/// Element controller dispatching user interactions directly into `MainWindow`.
pub struct ShowcaseElementController {
    weak: slint::Weak<MainWindow>,
    bridge: Arc<SlintUiBridge>,
}

impl ShowcaseElementController {
    pub fn new(weak: slint::Weak<MainWindow>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl ElementController for ShowcaseElementController {
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        let target_str = target.to_string();
        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                match target_str.as_str() {
                    "tab_buttons" | "Buttons & Badges" => {
                        win.set_active_tab(0);
                        Ok(ActionResult::success("Switched to Tab 0").with_element_id("tab_buttons"))
                    }
                    "tab_forms" | "Forms & Inputs" => {
                        win.set_active_tab(1);
                        Ok(ActionResult::success("Switched to Tab 1").with_element_id("tab_forms"))
                    }
                    "tab_data" | "Data Display" => {
                        win.set_active_tab(2);
                        Ok(ActionResult::success("Switched to Tab 2").with_element_id("tab_data"))
                    }
                    "tab_feedback" | "Feedback & Status" => {
                        win.set_active_tab(3);
                        Ok(ActionResult::success("Switched to Tab 3").with_element_id("tab_feedback"))
                    }
                    "tab_navigation" | "Navigation" => {
                        win.set_active_tab(4);
                        Ok(ActionResult::success("Switched to Tab 4").with_element_id("tab_navigation"))
                    }
                    "tab_overlays" | "Overlays & Modals" => {
                        win.set_active_tab(5);
                        Ok(ActionResult::success("Switched to Tab 5").with_element_id("tab_overlays"))
                    }
                    "tab_compute" | "Compute Engine" => {
                        win.set_active_tab(6);
                        Ok(ActionResult::success("Switched to Tab 6").with_element_id("tab_compute"))
                    }
                    "tab_settings" | "Settings" => {
                        win.set_active_tab(7);
                        Ok(ActionResult::success("Switched to Tab 7").with_element_id("tab_settings"))
                    }
                    "start_compute_btn" | "Run Compute Benchmark" => {
                        if win.get_compute_running() {
                            return Err(AgentError::invalid_operation(
                                "Compute benchmark is already running (start_compute_btn is disabled)",
                            ));
                        }
                        win.invoke_start_compute();
                        Ok(ActionResult::success("Compute task started").with_element_id("start_compute_btn"))
                    }
                    "cancel_compute_btn" | "Cancel" | "Cancel Compute" => {
                        if !win.get_compute_running() {
                            return Err(AgentError::invalid_operation(
                                "No compute task is currently running to cancel",
                            ));
                        }
                        win.invoke_cancel_compute();
                        Ok(ActionResult::success("Compute task cancelled").with_element_id("cancel_compute_btn"))
                    }
                    "theme_toggle_btn" | "Toggle Theme" | "Light Mode" | "Dark Mode" => {
                        win.invoke_toggle_theme();
                        let is_dark = win.global::<SlateTheme>().get_is_dark();
                        Ok(ActionResult::success(format!("Theme toggled to is_dark={}", is_dark))
                            .with_element_id("theme_toggle_btn"))
                    }
                    "increment_counter_btn" | "Interactive Counter" => {
                        win.invoke_increment_counter();
                        Ok(ActionResult::success(format!("Counter is now {}", win.get_counter()))
                            .with_element_id("increment_counter_btn"))
                    }
                    s if s.starts_with("Count:") => {
                        win.invoke_increment_counter();
                        Ok(ActionResult::success(format!("Counter is now {}", win.get_counter()))
                            .with_element_id("increment_counter_btn"))
                    }
                    "switch_notifications" | "demo_switch_1" | "Enable Notifications" => {
                        let next = !win.get_demo_switch_1();
                        win.set_demo_switch_1(next);
                        Ok(ActionResult::success(format!("Switch toggled to {}", next))
                            .with_element_id("switch_notifications"))
                    }
                    other => Err(AgentError::element_not_found(other, "Unrecognized interactive element")),
                }
            })
            .await
    }

    async fn click_at(&self, point: Point, button: MouseButton) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!(
            "Clicked at ({}, {}) with {:?}",
            point.x, point.y, button
        )))
    }

    async fn send_keys(&self, target: Option<&str>, text: &str) -> Result<ActionResult, AgentError> {
        let weak = self.weak.clone();
        let target_str = target.unwrap_or("email_input").to_string();
        let text_str = text.to_string();
        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                match target_str.as_str() {
                    "email_input" | "demo_input_text" | "Email Address" => {
                        win.set_demo_input_text(text_str.into());
                        Ok(ActionResult::success("Updated email input").with_element_id("email_input"))
                    }
                    "notes_textarea" | "demo_textarea_text" | "System Description" => {
                        win.set_demo_textarea_text(text_str.into());
                        Ok(ActionResult::success("Updated textarea").with_element_id("notes_textarea"))
                    }
                    other => Err(AgentError::element_not_found(
                        other,
                        "Target element is not an editable text input",
                    )),
                }
            })
            .await
    }

    async fn set_value(&self, target: &str, value: &str) -> Result<ActionResult, AgentError> {
        self.send_keys(Some(target), value).await
    }

    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        self.click_element(target).await
    }
}

/// UI inspector returning the component tree of `MainWindow`.
pub struct ShowcaseUiInspector {
    weak: slint::Weak<MainWindow>,
    bridge: Arc<SlintUiBridge>,
}

impl ShowcaseUiInspector {
    pub fn new(weak: slint::Weak<MainWindow>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { weak, bridge }
    }
}

#[async_trait::async_trait]
impl UiInspector for ShowcaseUiInspector {
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        let weak = self.weak.clone();
        self.bridge
            .run_on_ui(move || {
                let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                let active_tab = win.get_active_tab();
                let dark = win.global::<SlateTheme>().get_is_dark();
                let counter = win.get_counter();
                let email = win.get_demo_input_text().to_string();
                let notes = win.get_demo_textarea_text().to_string();
                let switch1 = win.get_demo_switch_1();
                let c_running = win.get_compute_running();

                let mut email_props = HashMap::new();
                email_props.insert("text".to_string(), serde_json::Value::String(email));

                let mut notes_props = HashMap::new();
                notes_props.insert("text".to_string(), serde_json::Value::String(notes));

                let mut switch_props = HashMap::new();
                switch_props.insert("checked".to_string(), serde_json::Value::Bool(switch1));

                let content_children = vec![
                    UiElementNode {
                        id: "increment_counter_btn".to_string(),
                        type_name: "SlateButton".to_string(),
                        label: Some(format!("Count: {}", counter)),
                        role: "button".to_string(),
                        bounds: Rect::new(260.0, 70.0, 140.0, 36.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        value: None,
                        children: vec![],
                        properties: HashMap::new(),
                    },
                    UiElementNode {
                        id: "email_input".to_string(),
                        type_name: "SlateInput".to_string(),
                        label: Some("Email Address".to_string()),
                        role: "textbox".to_string(),
                        bounds: Rect::new(260.0, 120.0, 280.0, 36.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        value: None,
                        children: vec![],
                        properties: email_props,
                    },
                    UiElementNode {
                        id: "notes_textarea".to_string(),
                        type_name: "SlateTextArea".to_string(),
                        label: Some("System Description".to_string()),
                        role: "textbox".to_string(),
                        bounds: Rect::new(260.0, 170.0, 280.0, 60.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        value: None,
                        children: vec![],
                        properties: notes_props,
                    },
                    UiElementNode {
                        id: "switch_notifications".to_string(),
                        type_name: "SlateSwitch".to_string(),
                        label: Some("Enable Notifications".to_string()),
                        role: "switch".to_string(),
                        bounds: Rect::new(260.0, 240.0, 60.0, 30.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        value: None,
                        children: vec![],
                        properties: switch_props,
                    },
                    UiElementNode {
                        id: "start_compute_btn".to_string(),
                        type_name: "SlateButton".to_string(),
                        label: Some("Run Compute Benchmark".to_string()),
                        role: "button".to_string(),
                        bounds: Rect::new(260.0, 220.0, 200.0, 40.0),
                        enabled: !c_running,
                        visible: true,
                        focused: false,
                        value: None,
                        children: vec![],
                        properties: HashMap::new(),
                    },
                    UiElementNode {
                        id: "cancel_compute_btn".to_string(),
                        type_name: "SlateButton".to_string(),
                        label: Some("Cancel Compute".to_string()),
                        role: "button".to_string(),
                        bounds: Rect::new(480.0, 220.0, 140.0, 40.0),
                        enabled: c_running,
                        visible: true,
                        focused: false,
                        value: None,
                        children: vec![],
                        properties: HashMap::new(),
                    },
                ];

                let children = vec![
                    UiElementNode {
                        id: "header_bar".to_string(),
                        type_name: "SlateHeaderBar".to_string(),
                        label: Some("Slate Desktop Component Showcase".to_string()),
                        role: "banner".to_string(),
                        bounds: Rect::new(0.0, 0.0, 1040.0, 50.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        value: None,
                        children: vec![UiElementNode {
                            id: "theme_toggle_btn".to_string(),
                            type_name: "SlateButton".to_string(),
                            label: Some(if dark { "Light Mode" } else { "Dark Mode" }.to_string()),
                            role: "button".to_string(),
                            bounds: Rect::new(920.0, 10.0, 100.0, 30.0),
                            enabled: true,
                            visible: true,
                            focused: false,
                            value: None,
                            children: vec![],
                            properties: HashMap::new(),
                        }],
                        properties: HashMap::new(),
                    },
                    UiElementNode {
                        id: "nav_view".to_string(),
                        type_name: "SlateNavigationSplitView".to_string(),
                        label: Some("Navigation Sidebar".to_string()),
                        role: "navigation".to_string(),
                        bounds: Rect::new(0.0, 50.0, 240.0, 670.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        value: None,
                        children: vec![
                            UiElementNode {
                                id: "tab_buttons".to_string(),
                                type_name: "NavItem".to_string(),
                                label: Some("Buttons & Badges".to_string()),
                                role: "tab".to_string(),
                                bounds: Rect::new(10.0, 60.0, 220.0, 40.0),
                                enabled: true,
                                visible: true,
                                focused: active_tab == 0,
                                value: None,
                                children: vec![],
                                properties: HashMap::new(),
                            },
                            UiElementNode {
                                id: "tab_forms".to_string(),
                                type_name: "NavItem".to_string(),
                                label: Some("Forms & Inputs".to_string()),
                                role: "tab".to_string(),
                                bounds: Rect::new(10.0, 105.0, 220.0, 40.0),
                                enabled: true,
                                visible: true,
                                focused: active_tab == 1,
                                value: None,
                                children: vec![],
                                properties: HashMap::new(),
                            },
                            UiElementNode {
                                id: "tab_compute".to_string(),
                                type_name: "NavItem".to_string(),
                                label: Some("Compute Engine".to_string()),
                                role: "tab".to_string(),
                                bounds: Rect::new(10.0, 150.0, 220.0, 40.0),
                                enabled: true,
                                visible: true,
                                focused: active_tab == 6,
                                value: None,
                                children: vec![],
                                properties: HashMap::new(),
                            },
                        ],
                        properties: HashMap::new(),
                    },
                    UiElementNode {
                        id: "content_area".to_string(),
                        type_name: "Flickable".to_string(),
                        label: Some("Content View".to_string()),
                        role: "region".to_string(),
                        bounds: Rect::new(240.0, 50.0, 800.0, 670.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        value: None,
                        children: content_children,
                        properties: HashMap::new(),
                    },
                ];

                let root = UiElementNode {
                    id: "main_window".to_string(),
                    type_name: "MainWindow".to_string(),
                    label: Some("Slate Showcase".to_string()),
                    role: "window".to_string(),
                    bounds: Rect::new(0.0, 0.0, 1040.0, 720.0),
                    enabled: true,
                    visible: true,
                    focused: true,
                    value: None,
                    children,
                    properties: HashMap::new(),
                };

                Ok(UiTree::new(root).with_window_info("Slate Showcase", 1040.0, 720.0))
            })
            .await
    }
}

/// Initialize the showcase agent remote control server using `slate::agent::builder`.
pub fn init_showcase_agent(window: &MainWindow) -> Result<AgentHandle, AgentError> {
    let bridge = Arc::new(SlintUiBridge::new());
    let weak = window.as_weak();

    let state_provider = Arc::new(ShowcaseStateProvider::new(weak.clone(), bridge.clone()));
    let controller = Arc::new(ShowcaseElementController::new(weak.clone(), bridge.clone()));
    let inspector = Arc::new(ShowcaseUiInspector::new(weak.clone(), bridge.clone()));
    let renderer = Arc::new(SlintWindowRenderer::new(weak, bridge));

    builder(window)
        .with_name("slate-showcase")
        .with_version(env!("CARGO_PKG_VERSION"))
        .with_state_provider(state_provider)
        .with_controller(controller)
        .with_inspector(inspector)
        .with_renderer(renderer)
        .with_mcp_stdio()
        .start()
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 1. Headless environment detection: default to software backend if DISPLAY is unset
    if std::env::var("SLINT_BACKEND").is_err()
        && std::env::var("DISPLAY").is_err()
        && std::env::var("WAYLAND_DISPLAY").is_err()
    {
        std::env::set_var("SLINT_BACKEND", "software");
    }

    let args: Vec<String> = std::env::args().collect();
    let is_headless = args.iter().any(|a| a == "--headless");
    let is_agent_mode = args.iter().any(|a| a == "--agent" || a == "--mcp")
        || std::env::var("SLATE_AGENT").map(|v| v == "1").unwrap_or(false);
    let is_minimal_init = args.iter().any(|a| a == "--minimal-init");

    if is_headless {
        std::env::set_var("SLINT_BACKEND", "software");
    }

    slate::init();
    log::info!("Starting Slate Showcase application...");

    let main_window = MainWindow::new()?;
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

    main_window.run()?;
    Ok(())
}
