//! MCP JSON-RPC 2.0 Server Core, Protocol Router, and Lifecycle State Machine.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
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

#[derive(Clone)]
pub struct McpServer {
    engine: Arc<dyn AutomationEngine>,
    name: String,
    version: String,
    protocol_version: String,
    initialized: Arc<AtomicBool>,
    logs: Arc<Mutex<Vec<String>>>,
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
            logs: Arc::new(Mutex::new(vec![
                "[INFO] Slate application initialized".to_string(),
                "[INFO] MCP agent attached over in-memory transport".to_string(),
            ])),
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
    pub async fn add_log(&self, line: impl Into<String>) {
        self.logs.lock().await.push(line.into());
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
                let res = McpInitializeResult {
                    protocol_version: self.protocol_version.clone(),
                    capabilities: ServerCapabilities {
                        tools: Some(serde_json::json!({ "listChanged": true })),
                        resources: Some(serde_json::json!({ "subscribe": true })),
                        logging: Some(serde_json::json!({})),
                    },
                    server_info: ServerInfo {
                        name: self.name.clone(),
                        version: self.version.clone(),
                    },
                };
                JsonRpcResponse::success(id, serde_json::to_value(res).unwrap())
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

        match crate::tools::dispatch_tool(self.engine.as_ref(), &self.logs, tool_name, args).await {
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

        match crate::resources::read_resource(self.engine.as_ref(), &self.logs, uri).await {
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

    /// Runs the asynchronous duplex server loop over any stream implementing `AsyncRead + AsyncWrite`.
    pub async fn run_stream<S>(&self, stream: S) -> Result<(), std::io::Error>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let (reader, writer) = tokio::io::split(stream);
        self.run_duplex(reader, writer).await
    }

    /// Runs the asynchronous duplex server loop with decoupled reader and writer.
    pub async fn run_duplex<R, W>(&self, reader: R, mut writer: W) -> Result<(), std::io::Error>
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let mut buf_reader = BufReader::new(reader);
        let (resp_tx, mut resp_rx) = tokio::sync::mpsc::channel::<String>(256);

        // Dedicated background writer task ensuring atomic line-flushing
        let writer_handle = tokio::spawn(async move {
            while let Some(mut resp_line) = resp_rx.recv().await {
                resp_line.push('\n');
                if writer.write_all(resp_line.as_bytes()).await.is_err() {
                    break;
                }
                if writer.flush().await.is_err() {
                    break;
                }
            }
        });

        let mut line = String::new();
        loop {
            line.clear();
            match buf_reader.read_line(&mut line).await {
                Ok(0) => break, // EOF reached
                Ok(_) => {
                    let trimmed = line.trim().to_string();
                    if trimmed.is_empty() {
                        continue;
                    }

                    let server = self.clone();
                    let tx = resp_tx.clone();
                    tokio::spawn(async move {
                        if let Some(resp) = server.handle_line(&trimmed).await {
                            let _ = tx.send(resp).await;
                        }
                    });
                }
                Err(e) => {
                    log::debug!("MCP duplex reader ended with error: {}", e);
                    break;
                }
            }
        }

        drop(resp_tx);
        let _ = writer_handle.await;
        Ok(())
    }
}
