use crate::types::*;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, WriteHalf};
use tokio::sync::{oneshot, Mutex};
use tokio::time::{timeout, Duration};

/// Asynchronous In-Memory MCP Test Client operating over an in-memory duplex channel.
pub struct InMemoryMcpClient {
    writer: Arc<Mutex<WriteHalf<tokio::io::DuplexStream>>>,
    pending_requests: Arc<Mutex<HashMap<String, oneshot::Sender<JsonRpcResponse>>>>,
    raw_response_tx: Arc<Mutex<Option<oneshot::Sender<String>>>>,
    request_counter: AtomicU64,
    _reader_handle: tokio::task::JoinHandle<()>,
}

impl InMemoryMcpClient {
    /// Creates a new `InMemoryMcpClient` attached to a `DuplexStream`.
    pub fn new(stream: tokio::io::DuplexStream) -> Self {
        let (reader, writer) = tokio::io::split(stream);
        let writer = Arc::new(Mutex::new(writer));
        let pending_requests: Arc<Mutex<HashMap<String, oneshot::Sender<JsonRpcResponse>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let raw_response_tx: Arc<Mutex<Option<oneshot::Sender<String>>>> = Arc::new(Mutex::new(None));

        let pending_clone = pending_requests.clone();
        let raw_clone = raw_response_tx.clone();

        let reader_handle = tokio::spawn(async move {
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

                        // Check if someone is waiting for raw line response
                        {
                            let mut raw_guard = raw_clone.lock().await;
                            if let Some(sender) = raw_guard.take() {
                                let _ = sender.send(trimmed.to_string());
                                continue;
                            }
                        }

                        // Try parsing as JsonRpcResponse
                        if let Ok(response) = serde_json::from_str::<JsonRpcResponse>(trimmed) {
                            if let Some(id) = &response.id {
                                let id_key = match id {
                                    serde_json::Value::Number(n) => n.to_string(),
                                    serde_json::Value::String(s) => s.clone(),
                                    other => other.to_string(),
                                };
                                let mut map = pending_clone.lock().await;
                                if let Some(sender) = map.remove(&id_key) {
                                    let _ = sender.send(response);
                                }
                            }
                        }
                    }
                    Err(_) => break,
                }
            }
        });

        Self {
            writer,
            pending_requests,
            raw_response_tx,
            request_counter: AtomicU64::new(1),
            _reader_handle: reader_handle,
        }
    }

    /// Generates next sequential request ID.
    fn next_id(&self) -> u64 {
        self.request_counter.fetch_add(1, Ordering::SeqCst)
    }

    /// Dispatches a raw JSON string and awaits raw line response.
    pub async fn raw_json_rpc(&self, payload: &str) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        {
            let mut raw_guard = self.raw_response_tx.lock().await;
            *raw_guard = Some(tx);
        }

        let mut data = payload.trim().to_string();
        data.push('\n');

        {
            let mut writer = self.writer.lock().await;
            writer
                .write_all(data.as_bytes())
                .await
                .map_err(|e| format!("Failed to write raw payload: {}", e))?;
            writer
                .flush()
                .await
                .map_err(|e| format!("Failed to flush raw payload: {}", e))?;
        }

        match timeout(Duration::from_secs(5), rx).await {
            Ok(Ok(response_line)) => Ok(response_line),
            Ok(Err(_)) => Err("Raw response channel dropped".to_string()),
            Err(_) => Err("Raw response timed out after 5s".to_string()),
        }
    }

    /// Dispatches a typed JSON-RPC request and awaits the correlated response.
    pub async fn request(
        &self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<JsonRpcResponse, String> {
        let id = self.next_id();
        let id_key = id.to_string();

        let (tx, rx) = oneshot::channel();
        {
            let mut map = self.pending_requests.lock().await;
            map.insert(id_key.clone(), tx);
        }

        let rpc_req = JsonRpcRequest::new(id, method, params);
        let mut json_str = serde_json::to_string(&rpc_req)
            .map_err(|e| format!("Failed to serialize request: {}", e))?;
        json_str.push('\n');

        {
            let mut writer = self.writer.lock().await;
            writer
                .write_all(json_str.as_bytes())
                .await
                .map_err(|e| format!("Write failed: {}", e))?;
            writer
                .flush()
                .await
                .map_err(|e| format!("Flush failed: {}", e))?;
        }

        match timeout(Duration::from_secs(5), rx).await {
            Ok(Ok(response)) => Ok(response),
            Ok(Err(_)) => {
                let mut map = self.pending_requests.lock().await;
                map.remove(&id_key);
                Err("Response channel closed prematurely".to_string())
            }
            Err(_) => {
                let mut map = self.pending_requests.lock().await;
                map.remove(&id_key);
                Err(format!("Request '{}' timed out after 5s", method))
            }
        }
    }

    /// Dispatches a JSON-RPC notification (no response expected).
    pub async fn notify(
        &self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<(), String> {
        let rpc_notif = JsonRpcRequest::notification(method, params);
        let mut json_str = serde_json::to_string(&rpc_notif)
            .map_err(|e| format!("Serialization failed: {}", e))?;
        json_str.push('\n');

        let mut writer = self.writer.lock().await;
        writer
            .write_all(json_str.as_bytes())
            .await
            .map_err(|e| format!("Write failed: {}", e))?;
        writer
            .flush()
            .await
            .map_err(|e| format!("Flush failed: {}", e))?;
        Ok(())
    }

    // ========================================================================
    // MCP Protocol Methods
    // ========================================================================

    /// Performs the MCP `initialize` handshake.
    pub async fn initialize(&self) -> Result<McpInitializeResult, String> {
        let params = serde_json::json!({
            "protocolVersion": "2024-11-05",
            "capabilities": {
                "roots": { "listChanged": true },
                "sampling": {}
            },
            "clientInfo": {
                "name": "slate-e2e-test-client",
                "version": "0.1.0"
            }
        });

        let resp = self.request("initialize", Some(params)).await?;
        if let Some(err) = resp.error {
            return Err(format!("Initialize error {}: {}", err.code, err.message));
        }

        let result = resp
            .result
            .ok_or_else(|| "Initialize missing result".to_string())?;
        serde_json::from_value::<McpInitializeResult>(result)
            .map_err(|e| format!("Failed to parse initialize result: {}", e))
    }

    /// Sends the `notifications/initialized` notification.
    pub async fn initialized(&self) -> Result<(), String> {
        self.notify("notifications/initialized", None).await
    }

    /// Dispatches `ping` request.
    pub async fn ping(&self) -> Result<(), String> {
        let resp = self.request("ping", None).await?;
        if let Some(err) = resp.error {
            return Err(format!("Ping error {}: {}", err.code, err.message));
        }
        Ok(())
    }

    /// Lists all registered tools via `tools/list`.
    pub async fn list_tools(&self) -> Result<Vec<Tool>, String> {
        let resp = self.request("tools/list", None).await?;
        if let Some(err) = resp.error {
            return Err(format!("tools/list error {}: {}", err.code, err.message));
        }

        let res = resp.result.ok_or_else(|| "Missing result".to_string())?;
        let tools_val = res
            .get("tools")
            .ok_or_else(|| "Missing 'tools' field".to_string())?;
        serde_json::from_value::<Vec<Tool>>(tools_val.clone())
            .map_err(|e| format!("Failed to deserialize tools: {}", e))
    }

    /// Invokes a tool via `tools/call`.
    pub async fn call_tool(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<ToolCallResult, String> {
        let params = serde_json::json!({
            "name": name,
            "arguments": arguments
        });

        let resp = self.request("tools/call", Some(params)).await?;
        if let Some(err) = resp.error {
            return Err(format!("tools/call error {}: {}", err.code, err.message));
        }

        let res = resp.result.ok_or_else(|| "Missing result".to_string())?;
        serde_json::from_value::<ToolCallResult>(res)
            .map_err(|e| format!("Failed to deserialize tool result: {}", e))
    }

    // ========================================================================
    // High-Level Standard Tool Helpers
    // ========================================================================

    /// Calls `get_screenshot`.
    pub async fn get_screenshot(&self, mime_type: Option<&str>) -> Result<Screenshot, String> {
        let mut args = serde_json::Map::new();
        if let Some(mt) = mime_type {
            args.insert("mime_type".to_string(), serde_json::Value::String(mt.to_string()));
        }

        let res = self.call_tool("get_screenshot", serde_json::Value::Object(args)).await?;
        if res.is_error {
            return Err("get_screenshot reported error".to_string());
        }

        let content = res
            .content
            .first()
            .ok_or_else(|| "Empty content in get_screenshot".to_string())?;

        let base64_data = content
            .data
            .as_ref()
            .ok_or_else(|| "Missing data in screenshot content".to_string())?;

        use base64::Engine;
        let png_bytes = base64::prelude::BASE64_STANDARD
            .decode(base64_data)
            .map_err(|e| format!("Invalid base64 in screenshot: {}", e))?;

        // Extract width and height from PNG header if valid
        let (width, height) = if png_bytes.len() >= 24
            && &png_bytes[0..8] == &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        {
            let w = u32::from_be_bytes([png_bytes[16], png_bytes[17], png_bytes[18], png_bytes[19]]);
            let h = u32::from_be_bytes([png_bytes[20], png_bytes[21], png_bytes[22], png_bytes[23]]);
            (w, h)
        } else {
            (0, 0)
        };

        Ok(Screenshot {
            width,
            height,
            format: content.mime_type.clone().unwrap_or_else(|| "image/png".to_string()),
            data: png_bytes,
        })
    }

    /// Calls `inspect_tree`.
    pub async fn inspect_tree(
        &self,
        root_id: Option<&str>,
        max_depth: Option<u32>,
    ) -> Result<UiTree, String> {
        let mut args = serde_json::Map::new();
        if let Some(rid) = root_id {
            args.insert("root_id".to_string(), serde_json::Value::String(rid.to_string()));
        }
        if let Some(md) = max_depth {
            args.insert("max_depth".to_string(), serde_json::json!(md));
        }

        let res = self.call_tool("inspect_tree", serde_json::Value::Object(args)).await?;
        if res.is_error {
            let details = res
                .content
                .first()
                .and_then(|c| c.text.clone())
                .unwrap_or_else(|| "inspect_tree reported error".to_string());
            return Err(details);
        }

        let text = res
            .content
            .first()
            .and_then(|c| c.text.as_ref())
            .ok_or_else(|| "Missing text content in inspect_tree".to_string())?;

        serde_json::from_str::<UiTree>(text)
            .map_err(|e| format!("Failed to parse inspect_tree JSON: {}", e))
    }

    /// Calls `click_element`.
    pub async fn click_element(&self, args: serde_json::Value) -> Result<ActionResult, String> {
        let res = self.call_tool("click_element", args).await?;
        if res.is_error {
            let details = res.content.first().and_then(|c| c.text.clone());
            return Err(format!("click_element failed: {:?}", details));
        }

        let text = res
            .content
            .first()
            .and_then(|c| c.text.as_ref())
            .ok_or_else(|| "Missing text content in click_element".to_string())?;

        serde_json::from_str::<ActionResult>(text)
            .map_err(|e| format!("Failed to parse click_element result: {}", e))
    }

    /// Calls `send_keys`.
    pub async fn send_keys(
        &self,
        text: &str,
        element_id: Option<&str>,
        clear_first: bool,
    ) -> Result<ActionResult, String> {
        let mut args = serde_json::json!({
            "text": text,
            "clear_first": clear_first
        });
        if let Some(eid) = element_id {
            args["element_id"] = serde_json::Value::String(eid.to_string());
        }

        let res = self.call_tool("send_keys", args).await?;
        if res.is_error {
            let details = res.content.first().and_then(|c| c.text.clone());
            return Err(format!("send_keys failed: {:?}", details));
        }

        let text_content = res
            .content
            .first()
            .and_then(|c| c.text.as_ref())
            .ok_or_else(|| "Missing text in send_keys response".to_string())?;

        serde_json::from_str::<ActionResult>(text_content)
            .map_err(|e| format!("Failed to parse send_keys response: {}", e))
    }

    /// Calls `get_state`.
    pub async fn get_state(&self, keys: Option<Vec<&str>>) -> Result<AppState, String> {
        let mut args = serde_json::Map::new();
        if let Some(k) = keys {
            let arr = k.into_iter().map(|s| serde_json::Value::String(s.to_string())).collect();
            args.insert("keys".to_string(), serde_json::Value::Array(arr));
        }

        let res = self.call_tool("get_state", serde_json::Value::Object(args)).await?;
        if res.is_error {
            return Err("get_state reported error".to_string());
        }

        let text = res
            .content
            .first()
            .and_then(|c| c.text.as_ref())
            .ok_or_else(|| "Missing text in get_state response".to_string())?;

        serde_json::from_str::<AppState>(text)
            .map_err(|e| format!("Failed to parse get_state JSON: {}", e))
    }

    // ========================================================================
    // MCP Resources Methods
    // ========================================================================

    /// Lists exposed resources via `resources/list`.
    pub async fn list_resources(&self) -> Result<Vec<Resource>, String> {
        let resp = self.request("resources/list", None).await?;
        if let Some(err) = resp.error {
            return Err(format!("resources/list error {}: {}", err.code, err.message));
        }

        let res = resp.result.ok_or_else(|| "Missing result".to_string())?;
        let res_arr = res
            .get("resources")
            .ok_or_else(|| "Missing 'resources' array".to_string())?;
        serde_json::from_value::<Vec<Resource>>(res_arr.clone())
            .map_err(|e| format!("Failed to parse resources: {}", e))
    }

    /// Reads a resource via `resources/read`.
    pub async fn read_resource(&self, uri: &str) -> Result<ResourceContent, String> {
        let params = serde_json::json!({ "uri": uri });
        let resp = self.request("resources/read", Some(params)).await?;
        if let Some(err) = resp.error {
            return Err(format!("resources/read error {}: {}", err.code, err.message));
        }

        let res = resp.result.ok_or_else(|| "Missing result".to_string())?;
        let contents = res
            .get("contents")
            .and_then(|c| c.as_array())
            .ok_or_else(|| "Missing 'contents' array in resources/read".to_string())?;

        let first = contents
            .first()
            .ok_or_else(|| "Empty contents in resources/read".to_string())?;

        serde_json::from_value::<ResourceContent>(first.clone())
            .map_err(|e| format!("Failed to parse resource content: {}", e))
    }
}
