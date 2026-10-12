//! MCP JSON-RPC 2.0 Server Core, Protocol Router, and Lifecycle State Machine.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::error::{
    INTERNAL_ERROR, INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND, PARSE_ERROR,
};
use crate::schema::{all_standard_tools, McpInitializeResult, ServerCapabilities, ServerInfo};
use slate_agent::traits::AutomationEngine;

// ============================================================================
// JSON-RPC 2.0 Protocol Types
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<Value>,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

impl JsonRpcResponse {
    pub fn success(id: Option<Value>, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(
        id: Option<Value>,
        code: i64,
        message: impl Into<String>,
        data: Option<Value>,
    ) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(JsonRpcError {
                code,
                message: message.into(),
                data,
            }),
        }
    }

    pub fn parse_error(message: impl Into<String>) -> Self {
        Self::error(None, PARSE_ERROR, message, None)
    }

    pub fn invalid_request(id: Option<Value>, message: impl Into<String>) -> Self {
        Self::error(id, INVALID_REQUEST, message, None)
    }

    pub fn method_not_found(id: Option<Value>, message: impl Into<String>) -> Self {
        Self::error(id, METHOD_NOT_FOUND, message, None)
    }

    pub fn invalid_params(id: Option<Value>, message: impl Into<String>) -> Self {
        Self::error(id, INVALID_PARAMS, message, None)
    }

    pub fn internal_error(id: Option<Value>, message: impl Into<String>) -> Self {
        Self::error(id, INTERNAL_ERROR, message, None)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

// ============================================================================
// MCP Server Core
// ============================================================================

/// Protocol versions this server understands. `2025-06-18` (Slint's HTTP MCP
/// server) is intentionally not listed: our stdio/in-memory surface speaks
/// `2024-11-05` only, and the mismatch path below tells the client as much.
pub const SUPPORTED_PROTOCOL_VERSIONS: &[&str] = &["2024-11-05"];

#[derive(Clone)]
pub struct McpServer {
    engine: Arc<dyn AutomationEngine>,
    name: String,
    version: String,
    protocol_version: String,
    initialized: Arc<AtomicBool>,
    logs: Arc<Mutex<Vec<String>>>,
    dropped_logs: Arc<AtomicU64>,
}

impl McpServer {
    /// Creates a new `McpServer` wrapping an `AutomationEngine`.
    pub fn new(engine: Arc<dyn AutomationEngine>) -> Self {
        Self::with_info(engine, "slate-mcp", env!("CARGO_PKG_VERSION"))
    }

    /// Creates a new `McpServer` with customized name and version info.
    pub fn with_info(
        engine: Arc<dyn AutomationEngine>,
        name: impl Into<String>,
        version: impl Into<String>,
    ) -> Self {
        Self {
            engine,
            name: name.into(),
            version: version.into(),
            protocol_version: "2024-11-05".to_string(),
            initialized: Arc::new(AtomicBool::new(false)),
            // No seed lines: the log buffer only ever contains lines produced
            // by live sessions. Tests needing log content must add it via
            // `add_log`.
            logs: Arc::new(Mutex::new(Vec::new())),
            dropped_logs: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Access the underlying automation engine.
    pub fn engine(&self) -> &Arc<dyn AutomationEngine> {
        &self.engine
    }

    /// Access the live logs buffer.
    pub fn logs(&self) -> &Arc<Mutex<Vec<String>>> {
        &self.logs
    }

    /// Returns whether the handshake initialization sequence has completed.
    pub fn is_initialized(&self) -> bool {
        self.initialized.load(Ordering::SeqCst)
    }

    /// Append a log line to the live logging stream.
    ///
    /// The buffer is bounded at [`crate::resources::MAX_LOG_LINES`]: when full, the oldest lines
    /// are dropped first and each drop increments the counter returned by
    /// [`McpServer::dropped_log_count`]. Delegates to the shared
    /// `resources::push_bounded_log` helper — the same path all tools log
    /// through — so there is exactly one bounding implementation.
    pub async fn add_log(&self, line: impl Into<String>) {
        crate::resources::push_bounded_log(&self.logs, &self.dropped_logs, line.into()).await;
    }

    /// Number of oldest-first log lines dropped because the buffer was full.
    pub fn dropped_log_count(&self) -> u64 {
        self.dropped_logs.load(Ordering::SeqCst)
    }

    /// Process a single raw incoming JSON-RPC string line.
    pub async fn handle_line(&self, raw: &str) -> Option<String> {
        let req_val: Value = match serde_json::from_str(raw) {
            Ok(v) => v,
            Err(e) => {
                let resp = JsonRpcResponse::parse_error(format!("Parse error: {}", e));
                return Some(serde_json::to_string(&resp).unwrap());
            }
        };

        let req_obj = match req_val.as_object() {
            Some(obj) => obj,
            None => {
                let resp =
                    JsonRpcResponse::invalid_request(None, "Invalid Request: expected JSON object");
                return Some(serde_json::to_string(&resp).unwrap());
            }
        };

        let jsonrpc = req_obj.get("jsonrpc").and_then(|v| v.as_str());
        if jsonrpc != Some("2.0") {
            let resp = JsonRpcResponse::invalid_request(
                req_obj.get("id").cloned(),
                "Invalid Request: missing or invalid 'jsonrpc' version",
            );
            return Some(serde_json::to_string(&resp).unwrap());
        }

        let id = req_obj.get("id").cloned();
        let method = match req_obj.get("method").and_then(|v| v.as_str()) {
            Some(m) => m,
            None => {
                let resp = JsonRpcResponse::invalid_request(id, "Missing 'method'");
                return Some(serde_json::to_string(&resp).unwrap());
            }
        };

        let params = req_obj.get("params").cloned();

        // Handle JSON-RPC notifications (no id -> no response)
        if id.is_none() {
            self.handle_notification(method, params).await;
            return None;
        }

        let resp = self.handle_request(id, method, params).await;
        Some(serde_json::to_string(&resp).unwrap())
    }

    /// Handle JSON-RPC notifications.
    pub async fn handle_notification(&self, method: &str, _params: Option<Value>) {
        if method == "notifications/initialized" {
            self.initialized.store(true, Ordering::SeqCst);
            self.add_log("[MCP] Client initialized acknowledged").await;
        }
    }

    /// Route and handle JSON-RPC requests.
    pub async fn handle_request(
        &self,
        id: Option<Value>,
        method: &str,
        params: Option<Value>,
    ) -> JsonRpcResponse {
        match method {
            "initialize" => {
                self.initialized.store(true, Ordering::SeqCst);
                let requested = params
                    .as_ref()
                    .and_then(|p| p.get("protocolVersion"))
                    .and_then(|v| v.as_str())
                    .map(str::to_string);
                // Capability advertisement choice: de-advertise what is not
                // implemented (`listChanged`, `subscribe`, `logging`) rather
                // than implementing `logging/setLevel` + subscribe thinly.
                // `tools/list`, `tools/call`, `resources/list`, and
                // `resources/read` are the implemented surface, hence the bare
                // `{}` markers below.
                let res = McpInitializeResult {
                    protocol_version: self.protocol_version.clone(),
                    capabilities: ServerCapabilities {
                        tools: Some(serde_json::json!({})),
                        resources: Some(serde_json::json!({})),
                        logging: None,
                    },
                    server_info: ServerInfo {
                        name: self.name.clone(),
                        version: self.version.clone(),
                    },
                };
                let mut result = serde_json::to_value(res).unwrap();
                match requested {
                    Some(v) if SUPPORTED_PROTOCOL_VERSIONS.contains(&v.as_str()) => {}
                    // Version mismatch: echo our version (already in
                    // `protocolVersion`) plus the supported set so the
                    // client can decide. Handshake still succeeds. `data` is
                    // attached ONLY when the client actually requested a
                    // version — a version-less `initialize` gets the bare
                    // result with no `data` key.
                    Some(v) => {
                        result["data"] = serde_json::json!({
                            "supportedVersions": SUPPORTED_PROTOCOL_VERSIONS,
                            "requestedVersion": v,
                        });
                    }
                    None => {}
                }
                JsonRpcResponse::success(id, result)
            }
            "ping" => JsonRpcResponse::success(id, serde_json::json!({})),
            "tools/list" => {
                let tools = all_standard_tools();
                JsonRpcResponse::success(id, serde_json::json!({ "tools": tools }))
            }
            "tools/call" => self.handle_tools_call(id, params).await,
            "resources/list" => self.handle_resources_list(id).await,
            "resources/read" => self.handle_resources_read(id, params).await,
            unknown => {
                JsonRpcResponse::method_not_found(id, format!("Method '{}' not found", unknown))
            }
        }
    }

    async fn handle_tools_call(&self, id: Option<Value>, params: Option<Value>) -> JsonRpcResponse {
        let p = match params {
            Some(Value::Object(map)) => map,
            _ => return JsonRpcResponse::invalid_params(id, "Missing 'name' in tools/call"),
        };

        let tool_name = match p.get("name").and_then(|v| v.as_str()) {
            Some(n) => n,
            None => return JsonRpcResponse::invalid_params(id, "Missing 'name' in tools/call"),
        };

        let args = p.get("arguments").cloned().unwrap_or(serde_json::json!({}));

        match crate::tools::dispatch_tool(
            self.engine.as_ref(),
            &self.logs,
            &self.dropped_logs,
            tool_name,
            args,
        )
        .await {
            Ok(tool_result) => {
                JsonRpcResponse::success(id, serde_json::to_value(tool_result).unwrap())
            }
            Err(crate::tools::ToolDispatchError::NotFound(name)) => {
                JsonRpcResponse::method_not_found(id, format!("Tool '{}' not found", name))
            }
            Err(crate::tools::ToolDispatchError::InvalidParams(msg)) => {
                JsonRpcResponse::invalid_params(id, msg)
            }
            Err(crate::tools::ToolDispatchError::Internal(msg)) => {
                JsonRpcResponse::internal_error(id, msg)
            }
        }
    }

    async fn handle_resources_list(&self, id: Option<Value>) -> JsonRpcResponse {
        let resources = crate::resources::list_resources();
        JsonRpcResponse::success(id, serde_json::json!({ "resources": resources }))
    }

    async fn handle_resources_read(
        &self,
        id: Option<Value>,
        params: Option<Value>,
    ) -> JsonRpcResponse {
        let uri = match params
            .as_ref()
            .and_then(|p| p.get("uri"))
            .and_then(|v| v.as_str())
        {
            Some(u) => u,
            None => return JsonRpcResponse::invalid_params(id, "Missing 'uri' parameter"),
        };

        match crate::resources::read_resource(
            self.engine.as_ref(),
            &self.logs,
            uri,
            &self.name,
            &self.version,
            self.dropped_log_count(),
        )
        .await {
            Ok(content) => {
                JsonRpcResponse::success(id, serde_json::json!({ "contents": [content] }))
            }
            Err(crate::resources::ResourceError::NotFound(uri)) => {
                JsonRpcResponse::invalid_params(id, format!("Resource '{}' not found", uri))
            }
            Err(crate::resources::ResourceError::Internal(msg)) => {
                JsonRpcResponse::internal_error(id, msg)
            }
        }
    }
    // NOTE: the dead `run_stream`/`run_duplex` loop was deleted here.
    // `transport::run_line_transport` is the single server loop (queue 1024,
    // broadcast shutdown); all transports use it.
}
