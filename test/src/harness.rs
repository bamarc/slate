use crate::types::*;
use slate_core::task::{spawn_compute, TaskCancellation};
use std::collections::HashMap;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::Mutex;

/// Test Engine simulating Slate Application State and UI Automation.
pub struct TestEngine {
    pub active_tab: Mutex<usize>,
    pub demo_input_text: Mutex<String>,
    pub demo_textarea_text: Mutex<String>,
    pub demo_switch_1: Mutex<bool>,
    pub demo_switch_2: Mutex<bool>,
    pub demo_check_1: Mutex<bool>,
    pub demo_radio_selection: Mutex<i32>,
    pub demo_slider_val: Mutex<f32>,
    pub is_dark: Mutex<bool>,
    pub counter: AtomicI32,
    pub compute_running: Mutex<bool>,
    pub compute_progress: Mutex<f32>,
    pub compute_status: Mutex<String>,
    pub compute_result: Mutex<String>,
    pub active_task: Mutex<Option<TaskCancellation>>,
    pub logs: Mutex<Vec<String>>,
}

impl Default for TestEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl TestEngine {
    pub fn new() -> Self {
        Self {
            active_tab: Mutex::new(0),
            demo_input_text: Mutex::new("dev@slate.internal".to_string()),
            demo_textarea_text: Mutex::new("High-performance desktop UI with Slint and Rust.".to_string()),
            demo_switch_1: Mutex::new(true),
            demo_switch_2: Mutex::new(false),
            demo_check_1: Mutex::new(true),
            demo_radio_selection: Mutex::new(0),
            demo_slider_val: Mutex::new(68.0),
            is_dark: Mutex::new(false),
            counter: AtomicI32::new(0),
            compute_running: Mutex::new(false),
            compute_progress: Mutex::new(0.0),
            compute_status: Mutex::new("Ready".to_string()),
            compute_result: Mutex::new("Idle".to_string()),
            active_task: Mutex::new(None),
            logs: Mutex::new(vec![
                "[INFO] Slate application initialized".to_string(),
                "[INFO] MCP agent attached over in-memory transport".to_string(),
            ]),
        }
    }

    /// Captures a rendered window screenshot as PNG bytes.
    pub async fn capture_screenshot(&self, _mime_type: Option<&str>) -> Screenshot {
        let width = 1040;
        let height = 720;

        // Render an RGBA8 image buffer and encode to genuine PNG bytes
        let mut img = image::RgbaImage::new(width, height);
        let dark = *self.is_dark.lock().await;

        let bg_color = if dark {
            image::Rgba([30, 30, 34, 255])
        } else {
            image::Rgba([245, 245, 247, 255])
        };

        for pixel in img.pixels_mut() {
            *pixel = bg_color;
        }

        let mut png_bytes = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut png_bytes);
        img.write_to(&mut cursor, image::ImageFormat::Png)
            .expect("PNG encoding failed");

        Screenshot {
            width,
            height,
            format: "image/png".to_string(),
            data: png_bytes,
        }
    }

    /// Builds the current UI element tree.
    pub async fn build_ui_tree(&self, root_id: Option<&str>, max_depth: Option<u32>) -> Result<UiTree, String> {
        let depth_limit = max_depth.unwrap_or(50);
        if depth_limit == 0 {
            return Err("max_depth must be >= 1".to_string());
        }

        let current_tab = *self.active_tab.lock().await;
        let input_text = self.demo_input_text.lock().await.clone();
        let switch_val = *self.demo_switch_1.lock().await;
        let dark = *self.is_dark.lock().await;
        let c_running = *self.compute_running.lock().await;
        let cnt = self.counter.load(Ordering::SeqCst);

        let children = vec![
            UiElementNode {
                id: Some("header_bar".to_string()),
                type_name: "SlateHeaderBar".to_string(),
                label: Some("Slate Desktop Component Showcase".to_string()),
                role: Some("banner".to_string()),
                bounds: Rect::new(0.0, 0.0, 1040.0, 50.0),
                enabled: true,
                visible: true,
                focused: false,
                properties: HashMap::new(),
                children: vec![
                    UiElementNode {
                        id: Some("theme_toggle_btn".to_string()),
                        type_name: "SlateButton".to_string(),
                        label: Some(if dark { "Light Mode" } else { "Dark Mode" }.to_string()),
                        role: Some("button".to_string()),
                        bounds: Rect::new(920.0, 10.0, 100.0, 30.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        properties: HashMap::new(),
                        children: vec![],
                    },
                ],
            },
            UiElementNode {
                id: Some("nav_view".to_string()),
                type_name: "SlateNavigationSplitView".to_string(),
                label: Some("Navigation Sidebar".to_string()),
                role: Some("navigation".to_string()),
                bounds: Rect::new(0.0, 50.0, 240.0, 670.0),
                enabled: true,
                visible: true,
                focused: false,
                properties: HashMap::new(),
                children: vec![
                    UiElementNode {
                        id: Some("tab_buttons".to_string()),
                        type_name: "NavItem".to_string(),
                        label: Some("Buttons & Badges".to_string()),
                        role: Some("tab".to_string()),
                        bounds: Rect::new(10.0, 60.0, 220.0, 40.0),
                        enabled: true,
                        visible: true,
                        focused: current_tab == 0,
                        properties: HashMap::new(),
                        children: vec![],
                    },
                    UiElementNode {
                        id: Some("tab_forms".to_string()),
                        type_name: "NavItem".to_string(),
                        label: Some("Forms & Inputs".to_string()),
                        role: Some("tab".to_string()),
                        bounds: Rect::new(10.0, 105.0, 220.0, 40.0),
                        enabled: true,
                        visible: true,
                        focused: current_tab == 1,
                        properties: HashMap::new(),
                        children: vec![],
                    },
                    UiElementNode {
                        id: Some("tab_compute".to_string()),
                        type_name: "NavItem".to_string(),
                        label: Some("Compute Engine".to_string()),
                        role: Some("tab".to_string()),
                        bounds: Rect::new(10.0, 150.0, 220.0, 40.0),
                        enabled: true,
                        visible: true,
                        focused: current_tab == 6,
                        properties: HashMap::new(),
                        children: vec![],
                    },
                ],
            },
            UiElementNode {
                id: Some("content_area".to_string()),
                type_name: "Flickable".to_string(),
                label: Some("Content View".to_string()),
                role: Some("region".to_string()),
                bounds: Rect::new(240.0, 50.0, 800.0, 670.0),
                enabled: true,
                visible: true,
                focused: false,
                properties: HashMap::new(),
                children: vec![
                    UiElementNode {
                        id: Some("increment_counter_btn".to_string()),
                        type_name: "SlateButton".to_string(),
                        label: Some(format!("Count: {}", cnt)),
                        role: Some("button".to_string()),
                        bounds: Rect::new(260.0, 70.0, 140.0, 36.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        properties: HashMap::new(),
                        children: vec![],
                    },
                    UiElementNode {
                        id: Some("email_input".to_string()),
                        type_name: "SlateInput".to_string(),
                        label: Some("Email Address".to_string()),
                        role: Some("textbox".to_string()),
                        bounds: Rect::new(260.0, 120.0, 280.0, 36.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        properties: {
                            let mut p = HashMap::new();
                            p.insert("text".to_string(), serde_json::Value::String(input_text));
                            p
                        },
                        children: vec![],
                    },
                    UiElementNode {
                        id: Some("switch_notifications".to_string()),
                        type_name: "SlateSwitch".to_string(),
                        label: Some("Enable Notifications".to_string()),
                        role: Some("switch".to_string()),
                        bounds: Rect::new(260.0, 170.0, 60.0, 30.0),
                        enabled: true,
                        visible: true,
                        focused: false,
                        properties: {
                            let mut p = HashMap::new();
                            p.insert("checked".to_string(), serde_json::Value::Bool(switch_val));
                            p
                        },
                        children: vec![],
                    },
                    UiElementNode {
                        id: Some("start_compute_btn".to_string()),
                        type_name: "SlateButton".to_string(),
                        label: Some("Run Compute Benchmark".to_string()),
                        role: Some("button".to_string()),
                        bounds: Rect::new(260.0, 220.0, 200.0, 40.0),
                        enabled: !c_running,
                        visible: true,
                        focused: false,
                        properties: HashMap::new(),
                        children: vec![],
                    },
                    UiElementNode {
                        id: Some("cancel_compute_btn".to_string()),
                        type_name: "SlateButton".to_string(),
                        label: Some("Cancel Compute".to_string()),
                        role: Some("button".to_string()),
                        bounds: Rect::new(480.0, 220.0, 140.0, 40.0),
                        enabled: c_running,
                        visible: true,
                        focused: false,
                        properties: HashMap::new(),
                        children: vec![],
                    },
                ],
            },
        ];

        let root = UiElementNode {
            id: Some("main_window".to_string()),
            type_name: "MainWindow".to_string(),
            label: Some("Slate Showcase".to_string()),
            role: Some("window".to_string()),
            bounds: Rect::new(0.0, 0.0, 1040.0, 720.0),
            enabled: true,
            visible: true,
            focused: true,
            properties: HashMap::new(),
            children,
        };

        if let Some(target_id) = root_id {
            if let Some(found) = root.find_by_id(target_id) {
                return Ok(UiTree {
                    root: found.clone(),
                    timestamp_ms: 1728529200000,
                });
            } else {
                return Err(format!("Root element '{}' not found", target_id));
            }
        }

        Ok(UiTree {
            root,
            timestamp_ms: 1728529200000,
        })
    }

    /// Handles click element dispatching.
    pub async fn dispatch_click(&self, args: &serde_json::Value) -> Result<ActionResult, String> {
        let id_opt = args.get("id").and_then(|v| v.as_str());
        let label_opt = args.get("label").and_then(|v| v.as_str());
        let x_opt = args.get("x").and_then(|v| v.as_f64()).map(|f| f as f32);
        let y_opt = args.get("y").and_then(|v| v.as_f64()).map(|f| f as f32);

        // Target resolution
        let target_name = if let Some(id) = id_opt {
            id.to_string()
        } else if let Some(label) = label_opt {
            label.to_string()
        } else if let (Some(x), Some(y)) = (x_opt, y_opt) {
            format!("{},{}", x, y)
        } else {
            return Err("click_element requires 'id', 'label', or coordinates ('x','y')".to_string());
        };

        // Negative coordinate validation
        if let (Some(x), Some(y)) = (x_opt, y_opt) {
            if x < 0.0 || y < 0.0 {
                return Err(format!("Coordinates cannot be negative: ({}, {})", x, y));
            }
            if x > 1040.0 || y > 720.0 {
                return Err(format!("Coordinates ({}, {}) out of window bounds (1040x720)", x, y));
            }
        }

        // Action routing
        match target_name.as_str() {
            "theme_toggle_btn" | "Light Mode" | "Dark Mode" | "Toggle Theme" => {
                let mut d = self.is_dark.lock().await;
                *d = !*d;
                self.add_log(format!("[ACTION] Theme toggled to dark={}", *d)).await;
                Ok(ActionResult {
                    success: true,
                    target: target_name,
                    details: Some(format!("Theme toggled to is_dark={}", *d)),
                })
            }
            "switch_notifications" | "Enable Notifications" => {
                let mut s = self.demo_switch_1.lock().await;
                *s = !*s;
                self.add_log(format!("[ACTION] Notification switch toggled to {}", *s)).await;
                Ok(ActionResult {
                    success: true,
                    target: target_name,
                    details: Some(format!("Switch toggled to {}", *s)),
                })
            }
            "increment_counter_btn" => {
                let val = self.counter.fetch_add(1, Ordering::SeqCst) + 1;
                self.add_log(format!("[ACTION] Counter incremented to {}", val)).await;
                Ok(ActionResult {
                    success: true,
                    target: target_name,
                    details: Some(format!("Counter is now {}", val)),
                })
            }
            "start_compute_btn" | "Run Compute Benchmark" => {
                self.start_compute_task().await;
                self.add_log("[ACTION] Started Monte Carlo Pi compute task".to_string()).await;
                Ok(ActionResult {
                    success: true,
                    target: target_name,
                    details: Some("Compute task started".to_string()),
                })
            }
            "cancel_compute_btn" | "Cancel Compute" => {
                self.cancel_compute_task().await;
                self.add_log("[ACTION] Cancelled compute task".to_string()).await;
                Ok(ActionResult {
                    success: true,
                    target: target_name,
                    details: Some("Compute task cancelled".to_string()),
                })
            }
            "tab_buttons" | "Buttons & Badges" => {
                *self.active_tab.lock().await = 0;
                Ok(ActionResult {
                    success: true,
                    target: target_name,
                    details: Some("Switched to Tab 0".to_string()),
                })
            }
            "tab_forms" | "Forms & Inputs" => {
                *self.active_tab.lock().await = 1;
                Ok(ActionResult {
                    success: true,
                    target: target_name,
                    details: Some("Switched to Tab 1".to_string()),
                })
            }
            "tab_compute" | "Compute Engine" => {
                *self.active_tab.lock().await = 6;
                Ok(ActionResult {
                    success: true,
                    target: target_name,
                    details: Some("Switched to Tab 6".to_string()),
                })
            }
            coords if coords.contains(',') => {
                // Coordinate hit test
                let tree = self.build_ui_tree(None, None).await?;
                if let (Some(x), Some(y)) = (x_opt, y_opt) {
                    if let Some(node) = tree.root.find_at_point(x, y) {
                        let node_id = node.id.clone().unwrap_or_else(|| node.type_name.clone());
                        // Recursive dispatch by resolved ID
                        let mut sub_args = args.clone();
                        sub_args["id"] = serde_json::Value::String(node_id.clone());
                        let res = Box::pin(self.dispatch_click(&sub_args)).await?;
                        return Ok(ActionResult {
                            success: true,
                            target: coords.to_string(),
                            details: Some(format!("Hit node '{}': {:?}", node_id, res.details)),
                        });
                    }
                }
                Ok(ActionResult {
                    success: true,
                    target: target_name,
                    details: Some("Clicked at coordinates".to_string()),
                })
            }
            other => {
                // If element is not recognized
                Err(format!("Element not found or not clickable: '{}'", other))
            }
        }
    }

    /// Handles send keys input dispatching.
    pub async fn dispatch_send_keys(&self, args: &serde_json::Value) -> Result<ActionResult, String> {
        let text = args
            .get("text")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "send_keys requires 'text' field".to_string())?;

        let element_id = args.get("element_id").and_then(|v| v.as_str());
        let clear_first = args.get("clear_first").and_then(|v| v.as_bool()).unwrap_or(false);

        let target_field = element_id.unwrap_or("email_input");

        match target_field {
            "email_input" => {
                let mut field = self.demo_input_text.lock().await;
                if clear_first {
                    field.clear();
                }
                field.push_str(text);
                self.add_log(format!("[ACTION] Typed into email_input: {}", field)).await;
                Ok(ActionResult {
                    success: true,
                    target: target_field.to_string(),
                    details: Some(format!("Value is now '{}'", *field)),
                })
            }
            "notes_textarea" => {
                let mut field = self.demo_textarea_text.lock().await;
                if clear_first {
                    field.clear();
                }
                field.push_str(text);
                self.add_log(format!("[ACTION] Typed into notes_textarea: {}", field)).await;
                Ok(ActionResult {
                    success: true,
                    target: target_field.to_string(),
                    details: Some(format!("Value is now '{}'", *field)),
                })
            }
            other => Err(format!("Target element '{}' is not an editable text input", other)),
        }
    }

    /// Reads application state.
    pub async fn get_state(&self, keys: Option<Vec<&str>>) -> Result<AppState, String> {
        let mut props = HashMap::new();

        let tab = *self.active_tab.lock().await;
        let email = self.demo_input_text.lock().await.clone();
        let notes = self.demo_textarea_text.lock().await.clone();
        let switch1 = *self.demo_switch_1.lock().await;
        let dark = *self.is_dark.lock().await;
        let c_running = *self.compute_running.lock().await;
        let c_progress = *self.compute_progress.lock().await;
        let c_status = self.compute_status.lock().await.clone();
        let c_result = self.compute_result.lock().await.clone();
        let cnt = self.counter.load(Ordering::SeqCst);

        props.insert("active_tab".to_string(), serde_json::json!(tab));
        props.insert("demo_input_text".to_string(), serde_json::json!(email));
        props.insert("demo_textarea_text".to_string(), serde_json::json!(notes));
        props.insert("demo_switch_1".to_string(), serde_json::json!(switch1));
        props.insert("is_dark".to_string(), serde_json::json!(dark));
        props.insert("counter".to_string(), serde_json::json!(cnt));
        props.insert("compute_running".to_string(), serde_json::json!(c_running));
        props.insert("compute_progress".to_string(), serde_json::json!(c_progress));
        props.insert("compute_status".to_string(), serde_json::json!(c_status));
        props.insert("compute_result".to_string(), serde_json::json!(c_result));

        if let Some(filter_keys) = keys {
            props.retain(|k, _| filter_keys.contains(&k.as_str()));
        }

        let active_view = match tab {
            0 => "buttons",
            1 => "forms",
            6 => "compute",
            _ => "other",
        }
        .to_string();

        Ok(AppState {
            active_view,
            properties: props,
            timestamp_ms: 1728529200000,
        })
    }

    /// Dispatches an ACP message.
    pub async fn dispatch_acp(&self, msg: AcpMessage) -> Result<AcpResponse, String> {
        match msg.action.as_str() {
            "query_state" => {
                let state = self.get_state(None).await?;
                Ok(AcpResponse {
                    correlation_id: msg.message_id,
                    success: true,
                    data: serde_json::to_value(state).unwrap(),
                    error: None,
                })
            }
            "click" => {
                let res = self.dispatch_click(&msg.payload).await?;
                Ok(AcpResponse {
                    correlation_id: msg.message_id,
                    success: res.success,
                    data: serde_json::to_value(res).unwrap(),
                    error: None,
                })
            }
            "send_keys" => {
                let res = self.dispatch_send_keys(&msg.payload).await?;
                Ok(AcpResponse {
                    correlation_id: msg.message_id,
                    success: res.success,
                    data: serde_json::to_value(res).unwrap(),
                    error: None,
                })
            }
            unknown => Ok(AcpResponse {
                correlation_id: msg.message_id,
                success: false,
                data: serde_json::Value::Null,
                error: Some(format!("Unknown ACP action: {}", unknown)),
            }),
        }
    }

    /// Spawns real background compute task with `slate_core::task::spawn_compute`.
    pub async fn start_compute_task(&self) {
        *self.compute_running.lock().await = true;
        *self.compute_progress.lock().await = 0.0;
        *self.compute_status.lock().await = "Computing".to_string();
        *self.compute_result.lock().await = "Working on 1,000,000 samples...".to_string();

        let cancellation = spawn_compute(
            |is_cancelled, progress| {
                let total = 1_000_000u64;
                let batch = 50_000u64;
                let mut inside = 0u64;
                let mut lfsr: u64 = 0xACE1;

                for i in 0..total {
                    if i % batch == 0 {
                        if is_cancelled() {
                            return None;
                        }
                        progress(i as f32 / total as f32);
                    }
                    lfsr = (lfsr >> 1) ^ (-( (lfsr & 1) as i64 ) as u64 & 0xB400);
                    let x = (lfsr as f64) / (u64::MAX as f64) * 2.0 - 1.0;
                    lfsr = (lfsr >> 1) ^ (-( (lfsr & 1) as i64 ) as u64 & 0xB400);
                    let y = (lfsr as f64) / (u64::MAX as f64) * 2.0 - 1.0;
                    if x * x + y * y <= 1.0 {
                        inside += 1;
                    }
                }
                Some(4.0 * (inside as f64) / (total as f64))
            },
            |_pct| {
                // progress reporting
            },
            |_result| {
                // completion reporting
            },
        );

        *self.active_task.lock().await = Some(cancellation);
    }

    /// Cancels the compute task.
    pub async fn cancel_compute_task(&self) {
        if let Some(handle) = self.active_task.lock().await.take() {
            handle.cancel();
        }
        *self.compute_running.lock().await = false;
        *self.compute_status.lock().await = "Cancelled".to_string();
        *self.compute_result.lock().await = "Computation was cancelled".to_string();
    }

    /// Appends log line.
    pub async fn add_log(&self, line: String) {
        self.logs.lock().await.push(line);
    }
}

// ============================================================================
// Test MCP Server Protocol Engine
// ============================================================================

pub struct TestMcpServer {
    pub engine: Arc<TestEngine>,
}

impl TestMcpServer {
    pub fn new(engine: Arc<TestEngine>) -> Self {
        Self { engine }
    }

    /// Runs server loop handling JSON-RPC over duplex stream.
    pub async fn run(&self, stream: tokio::io::DuplexStream) {
        let (reader, mut writer) = tokio::io::split(stream);
        let mut buf_reader = BufReader::new(reader);
        let mut line = String::new();

        loop {
            line.clear();
            match buf_reader.read_line(&mut line).await {
                Ok(0) => break, // EOF
                Ok(_) => {
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }

                    let response = self.handle_line(trimmed).await;
                    if let Some(resp_json) = response {
                        let mut out = resp_json;
                        out.push('\n');
                        if writer.write_all(out.as_bytes()).await.is_err() {
                            break;
                        }
                        if writer.flush().await.is_err() {
                            break;
                        }
                    }
                }
                Err(_) => break,
            }
        }
    }

    async fn handle_line(&self, raw: &str) -> Option<String> {
        let req_val: serde_json::Value = match serde_json::from_str(raw) {
            Ok(v) => v,
            Err(e) => {
                let err_resp = JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id: None,
                    result: None,
                    error: Some(JsonRpcError {
                        code: PARSE_ERROR,
                        message: format!("Parse error: {}", e),
                        data: None,
                    }),
                };
                return Some(serde_json::to_string(&err_resp).unwrap());
            }
        };

        // Check if object
        let req_obj = match req_val.as_object() {
            Some(obj) => obj,
            None => {
                let err_resp = JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id: None,
                    result: None,
                    error: Some(JsonRpcError {
                        code: INVALID_REQUEST,
                        message: "Invalid Request: expected JSON object".to_string(),
                        data: None,
                    }),
                };
                return Some(serde_json::to_string(&err_resp).unwrap());
            }
        };

        let jsonrpc = req_obj.get("jsonrpc").and_then(|v| v.as_str());
        if jsonrpc != Some("2.0") {
            let err_resp = JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id: req_obj.get("id").cloned(),
                result: None,
                error: Some(JsonRpcError {
                    code: INVALID_REQUEST,
                    message: "Invalid Request: missing or invalid 'jsonrpc' version".to_string(),
                    data: None,
                }),
            };
            return Some(serde_json::to_string(&err_resp).unwrap());
        }

        let id = req_obj.get("id").cloned();
        let method = match req_obj.get("method").and_then(|v| v.as_str()) {
            Some(m) => m,
            None => {
                let err_resp = JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id,
                    result: None,
                    error: Some(JsonRpcError {
                        code: INVALID_REQUEST,
                        message: "Missing 'method'".to_string(),
                        data: None,
                    }),
                };
                return Some(serde_json::to_string(&err_resp).unwrap());
            }
        };

        let params = req_obj.get("params").cloned();

        // Handle notifications
        if id.is_none() {
            let _ = self.handle_notification(method, params).await;
            return None;
        }

        let resp = self.handle_request(id.clone(), method, params).await;
        Some(serde_json::to_string(&resp).unwrap())
    }

    async fn handle_notification(&self, method: &str, _params: Option<serde_json::Value>) {
        if method == "notifications/initialized" {
            self.engine.add_log("[MCP] Client initialized acknowledged".to_string()).await;
        }
    }

    async fn handle_request(
        &self,
        id: Option<serde_json::Value>,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> JsonRpcResponse {
        match method {
            "initialize" => {
                let res = McpInitializeResult {
                    protocol_version: "2024-11-05".to_string(),
                    capabilities: ServerCapabilities {
                        tools: Some(serde_json::json!({ "listChanged": true })),
                        resources: Some(serde_json::json!({ "subscribe": true })),
                        logging: Some(serde_json::json!({})),
                    },
                    server_info: ServerInfo {
                        name: "slate-mcp".to_string(),
                        version: "0.1.0".to_string(),
                    },
                };
                JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id,
                    result: Some(serde_json::to_value(res).unwrap()),
                    error: None,
                }
            }
            "ping" => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id,
                result: Some(serde_json::json!({})),
                error: None,
            },
            "tools/list" => {
                let tools = vec![
                    Tool {
                        name: "get_screenshot".to_string(),
                        description: "Captures the current rendered window frame and returns PNG image data".to_string(),
                        input_schema: serde_json::json!({
                            "type": "object",
                            "properties": {
                                "mime_type": { "type": "string", "default": "image/png" }
                            }
                        }),
                    },
                    Tool {
                        name: "inspect_tree".to_string(),
                        description: "Returns the hierarchical UI tree of components, labels, IDs, and bounding rectangles".to_string(),
                        input_schema: serde_json::json!({
                            "type": "object",
                            "properties": {
                                "root_id": { "type": "string" },
                                "max_depth": { "type": "integer", "minimum": 1 }
                            }
                        }),
                    },
                    Tool {
                        name: "click_element".to_string(),
                        description: "Dispatches click events to specific elements by ID, text label, or coordinates".to_string(),
                        input_schema: serde_json::json!({
                            "type": "object",
                            "properties": {
                                "id": { "type": "string" },
                                "label": { "type": "string" },
                                "x": { "type": "number" },
                                "y": { "type": "number" },
                                "button": { "type": "string", "enum": ["left", "right", "middle"], "default": "left" },
                                "click_count": { "type": "integer", "enum": [1, 2], "default": 1 }
                            }
                        }),
                    },
                    Tool {
                        name: "send_keys".to_string(),
                        description: "Types text into active or targeted text inputs".to_string(),
                        input_schema: serde_json::json!({
                            "type": "object",
                            "properties": {
                                "text": { "type": "string" },
                                "element_id": { "type": "string" },
                                "clear_first": { "type": "boolean", "default": false }
                            },
                            "required": ["text"]
                        }),
                    },
                    Tool {
                        name: "get_state".to_string(),
                        description: "Reads application properties, active view, or diagnostic metrics".to_string(),
                        input_schema: serde_json::json!({
                            "type": "object",
                            "properties": {
                                "keys": { "type": "array", "items": { "type": "string" } }
                            }
                        }),
                    },
                ];

                JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id,
                    result: Some(serde_json::json!({ "tools": tools })),
                    error: None,
                }
            }
            "tools/call" => {
                let p = params.unwrap_or(serde_json::Value::Null);
                let tool_name = match p.get("name").and_then(|v| v.as_str()) {
                    Some(n) => n,
                    None => {
                        return JsonRpcResponse {
                            jsonrpc: "2.0".to_string(),
                            id,
                            result: None,
                            error: Some(JsonRpcError {
                                code: INVALID_PARAMS,
                                message: "Missing 'name' in tools/call".to_string(),
                                data: None,
                            }),
                        };
                    }
                };

                let args = p.get("arguments").cloned().unwrap_or(serde_json::json!({}));

                match tool_name {
                    "get_screenshot" => {
                        let mt = args.get("mime_type").and_then(|v| v.as_str());
                        let screenshot = self.engine.capture_screenshot(mt).await;
                        let res = ToolCallResult {
                            content: vec![ToolContent {
                                content_type: "image".to_string(),
                                text: None,
                                data: Some(screenshot.to_base64_png()),
                                mime_type: Some(screenshot.format),
                            }],
                            is_error: false,
                        };
                        JsonRpcResponse {
                            jsonrpc: "2.0".to_string(),
                            id,
                            result: Some(serde_json::to_value(res).unwrap()),
                            error: None,
                        }
                    }
                    "inspect_tree" => {
                        let root_id = args.get("root_id").and_then(|v| v.as_str());
                        let max_depth = args.get("max_depth").and_then(|v| v.as_u64()).map(|u| u as u32);
                        match self.engine.build_ui_tree(root_id, max_depth).await {
                            Ok(tree) => {
                                let res = ToolCallResult {
                                    content: vec![ToolContent {
                                        content_type: "text".to_string(),
                                        text: Some(serde_json::to_string(&tree).unwrap()),
                                        data: None,
                                        mime_type: None,
                                    }],
                                    is_error: false,
                                };
                                JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id,
                                    result: Some(serde_json::to_value(res).unwrap()),
                                    error: None,
                                }
                            }
                            Err(e) => {
                                let res = ToolCallResult {
                                    content: vec![ToolContent {
                                        content_type: "text".to_string(),
                                        text: Some(e),
                                        data: None,
                                        mime_type: None,
                                    }],
                                    is_error: true,
                                };
                                JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id,
                                    result: Some(serde_json::to_value(res).unwrap()),
                                    error: None,
                                }
                            }
                        }
                    }
                    "click_element" => {
                        match self.engine.dispatch_click(&args).await {
                            Ok(act_res) => {
                                let res = ToolCallResult {
                                    content: vec![ToolContent {
                                        content_type: "text".to_string(),
                                        text: Some(serde_json::to_string(&act_res).unwrap()),
                                        data: None,
                                        mime_type: None,
                                    }],
                                    is_error: false,
                                };
                                JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id,
                                    result: Some(serde_json::to_value(res).unwrap()),
                                    error: None,
                                }
                            }
                            Err(e) => {
                                let res = ToolCallResult {
                                    content: vec![ToolContent {
                                        content_type: "text".to_string(),
                                        text: Some(e),
                                        data: None,
                                        mime_type: None,
                                    }],
                                    is_error: true,
                                };
                                JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id,
                                    result: Some(serde_json::to_value(res).unwrap()),
                                    error: None,
                                }
                            }
                        }
                    }
                    "send_keys" => {
                        if args.get("text").is_none() {
                            return JsonRpcResponse {
                                jsonrpc: "2.0".to_string(),
                                id,
                                result: None,
                                error: Some(JsonRpcError {
                                    code: INVALID_PARAMS,
                                    message: "Missing required argument 'text'".to_string(),
                                    data: None,
                                }),
                            };
                        }
                        match self.engine.dispatch_send_keys(&args).await {
                            Ok(act_res) => {
                                let res = ToolCallResult {
                                    content: vec![ToolContent {
                                        content_type: "text".to_string(),
                                        text: Some(serde_json::to_string(&act_res).unwrap()),
                                        data: None,
                                        mime_type: None,
                                    }],
                                    is_error: false,
                                };
                                JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id,
                                    result: Some(serde_json::to_value(res).unwrap()),
                                    error: None,
                                }
                            }
                            Err(e) => {
                                let res = ToolCallResult {
                                    content: vec![ToolContent {
                                        content_type: "text".to_string(),
                                        text: Some(e),
                                        data: None,
                                        mime_type: None,
                                    }],
                                    is_error: true,
                                };
                                JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id,
                                    result: Some(serde_json::to_value(res).unwrap()),
                                    error: None,
                                }
                            }
                        }
                    }
                    "get_state" => {
                        let keys = args
                            .get("keys")
                            .and_then(|v| v.as_array())
                            .map(|arr| arr.iter().filter_map(|x| x.as_str()).collect());
                        match self.engine.get_state(keys).await {
                            Ok(state) => {
                                let res = ToolCallResult {
                                    content: vec![ToolContent {
                                        content_type: "text".to_string(),
                                        text: Some(serde_json::to_string(&state).unwrap()),
                                        data: None,
                                        mime_type: None,
                                    }],
                                    is_error: false,
                                };
                                JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id,
                                    result: Some(serde_json::to_value(res).unwrap()),
                                    error: None,
                                }
                            }
                            Err(e) => {
                                let res = ToolCallResult {
                                    content: vec![ToolContent {
                                        content_type: "text".to_string(),
                                        text: Some(e),
                                        data: None,
                                        mime_type: None,
                                    }],
                                    is_error: true,
                                };
                                JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id,
                                    result: Some(serde_json::to_value(res).unwrap()),
                                    error: None,
                                }
                            }
                        }
                    }
                    unknown => JsonRpcResponse {
                        jsonrpc: "2.0".to_string(),
                        id,
                        result: None,
                        error: Some(JsonRpcError {
                            code: METHOD_NOT_FOUND,
                            message: format!("Tool '{}' not found", unknown),
                            data: None,
                        }),
                    },
                }
            }
            "resources/list" => {
                let resources = vec![
                    Resource {
                        uri: "slate://app/context".to_string(),
                        name: "Application Context".to_string(),
                        description: Some("Current Slate application window metadata and configuration".to_string()),
                        mime_type: Some("application/json".to_string()),
                    },
                    Resource {
                        uri: "slate://logs/live".to_string(),
                        name: "Live Execution Logs".to_string(),
                        description: Some("Real-time logging stream from Slate runtime".to_string()),
                        mime_type: Some("text/plain".to_string()),
                    },
                ];

                JsonRpcResponse {
                    jsonrpc: "2.0".to_string(),
                    id,
                    result: Some(serde_json::json!({ "resources": resources })),
                    error: None,
                }
            }
            "resources/read" => {
                let uri = params.as_ref().and_then(|p| p.get("uri")).and_then(|v| v.as_str());
                match uri {
                    Some("slate://app/context") => {
                        let content = ResourceContent {
                            uri: "slate://app/context".to_string(),
                            mime_type: Some("application/json".to_string()),
                            text: Some(serde_json::json!({
                                "app": "slate-showcase",
                                "version": "0.1.0",
                                "window_width": 1040,
                                "window_height": 720
                            }).to_string()),
                            blob: None,
                        };
                        JsonRpcResponse {
                            jsonrpc: "2.0".to_string(),
                            id,
                            result: Some(serde_json::json!({ "contents": [content] })),
                            error: None,
                        }
                    }
                    Some("slate://logs/live") => {
                        let log_lines = self.engine.logs.lock().await.join("\n");
                        let content = ResourceContent {
                            uri: "slate://logs/live".to_string(),
                            mime_type: Some("text/plain".to_string()),
                            text: Some(log_lines),
                            blob: None,
                        };
                        JsonRpcResponse {
                            jsonrpc: "2.0".to_string(),
                            id,
                            result: Some(serde_json::json!({ "contents": [content] })),
                            error: None,
                        }
                    }
                    Some(other) => JsonRpcResponse {
                        jsonrpc: "2.0".to_string(),
                        id,
                        result: None,
                        error: Some(JsonRpcError {
                            code: INVALID_PARAMS,
                            message: format!("Resource '{}' not found", other),
                            data: None,
                        }),
                    },
                    None => JsonRpcResponse {
                        jsonrpc: "2.0".to_string(),
                        id,
                        result: None,
                        error: Some(JsonRpcError {
                            code: INVALID_PARAMS,
                            message: "Missing 'uri' parameter".to_string(),
                            data: None,
                        }),
                    },
                }
            }
            unknown => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id,
                result: None,
                error: Some(JsonRpcError {
                    code: METHOD_NOT_FOUND,
                    message: format!("Method '{}' not found", unknown),
                    data: None,
                }),
            },
        }
    }
}

/// Helper function to create an in-memory test session with connected client and server.
pub fn create_test_session() -> (crate::client::InMemoryMcpClient, Arc<TestEngine>, tokio::task::JoinHandle<()>) {
    // Ensure headless software rendering is configured
    if std::env::var("SLINT_BACKEND").is_err() {
        std::env::set_var("SLINT_BACKEND", "software");
    }

    let (client_stream, server_stream) = tokio::io::duplex(65536);
    let engine = Arc::new(TestEngine::new());
    let server = TestMcpServer::new(engine.clone());

    let server_handle = tokio::spawn(async move {
        server.run(server_stream).await;
    });

    let client = crate::client::InMemoryMcpClient::new(client_stream);
    (client, engine, server_handle)
}
