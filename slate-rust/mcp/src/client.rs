//! Asynchronous Model Context Protocol (MCP) client implementation.
//!
//! Provides [`McpClient`] for communicating with an MCP server over any asynchronous
//! duplex stream (e.g. in-memory duplex, pipes, or child process stdio), and
//! [`ProcessMcpClient`] for launching and controlling an application binary directly.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{oneshot, Mutex};
use tokio::time::{timeout, Duration};

use crate::server::{JsonRpcRequest, JsonRpcResponse};

/// Default timeout for MCP requests (15 seconds).
pub const DEFAULT_CLIENT_TIMEOUT: Duration = Duration::from_secs(15);

/// Errors encountered by the MCP client.
#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("Request timed out after {0:?}")]
    Timeout(Duration),

    #[error("Server returned JSON-RPC error ({code}): {message}")]
    JsonRpc {
        code: i64,
        message: String,
        data: Option<serde_json::Value>,
    },

    #[error("Server response channel closed unexpectedly")]
    ChannelClosed,

    #[error("Protocol error: {0}")]
    Protocol(String),

    #[error("Child process exited: {0}")]
    ProcessExited(String),
}

/// Generic Asynchronous MCP Client operating over an arbitrary `AsyncRead + AsyncWrite` stream.
pub struct McpClient<W> {
    writer: Arc<Mutex<W>>,
    pending_requests: Arc<Mutex<HashMap<String, oneshot::Sender<JsonRpcResponse>>>>,
    request_counter: AtomicU64,
    timeout_duration: Duration,
    _reader_handle: tokio::task::JoinHandle<()>,
}

impl<W: AsyncWrite + Unpin + Send + 'static> McpClient<W> {
    /// Creates a new `McpClient` from an asynchronous reader and writer pair.
    pub fn new<R: AsyncRead + Unpin + Send + 'static>(reader: R, writer: W) -> Self {
        let writer = Arc::new(Mutex::new(writer));
        let pending_requests: Arc<Mutex<HashMap<String, oneshot::Sender<JsonRpcResponse>>>> =
            Arc::new(Mutex::new(HashMap::new()));

        let pending_clone = pending_requests.clone();

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
            request_counter: AtomicU64::new(1),
            timeout_duration: DEFAULT_CLIENT_TIMEOUT,
            _reader_handle: reader_handle,
        }
    }

    /// Sets custom timeout duration for client requests.
    pub fn set_timeout(&mut self, dur: Duration) {
        self.timeout_duration = dur;
    }

    /// Dispatches a JSON-RPC request and awaits the parsed response.
    pub async fn send_request(
        &self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, ClientError> {
        let id_num = self.request_counter.fetch_add(1, Ordering::SeqCst);
        let id_val = serde_json::json!(id_num);
        let id_key = id_num.to_string();

        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(id_val),
            method: method.to_string(),
            params,
        };

        let mut payload = serde_json::to_string(&req)?;
        payload.push('\n');

        let (tx, rx) = oneshot::channel();
        {
            let mut map = self.pending_requests.lock().await;
            map.insert(id_key.clone(), tx);
        }

        {
            let mut writer = self.writer.lock().await;
            writer.write_all(payload.as_bytes()).await?;
            writer.flush().await?;
        }

        let resp = match timeout(self.timeout_duration, rx).await {
            Ok(Ok(response)) => response,
            Ok(Err(_)) => {
                let mut map = self.pending_requests.lock().await;
                map.remove(&id_key);
                return Err(ClientError::ChannelClosed);
            }
            Err(_) => {
                let mut map = self.pending_requests.lock().await;
                map.remove(&id_key);
                return Err(ClientError::Timeout(self.timeout_duration));
            }
        };

        if let Some(err) = resp.error {
            return Err(ClientError::JsonRpc {
                code: err.code,
                message: err.message,
                data: err.data,
            });
        }

        resp.result
            .ok_or_else(|| ClientError::Protocol("Missing result in JSON-RPC response".to_string()))
    }

    /// Performs the MCP `initialize` handshake.
    pub async fn initialize(
        &self,
        client_name: &str,
        client_version: &str,
    ) -> Result<serde_json::Value, ClientError> {
        let params = serde_json::json!({
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {
                "name": client_name,
                "version": client_version
            }
        });

        self.send_request("initialize", Some(params)).await
    }

    /// Lists all available tools from the server.
    pub async fn list_tools(&self) -> Result<serde_json::Value, ClientError> {
        self.send_request("tools/list", None).await
    }

    /// Invokes a tool by name with arguments.
    pub async fn call_tool(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<serde_json::Value, ClientError> {
        let params = serde_json::json!({
            "name": name,
            "arguments": arguments
        });

        self.send_request("tools/call", Some(params)).await
    }

    /// Inspects the application component tree (`inspect_tree`).
    pub async fn inspect_tree(&self) -> Result<serde_json::Value, ClientError> {
        self.call_tool("inspect_tree", serde_json::json!({})).await
    }

    /// Clicks an element by ID or coordinates (`click_element`).
    ///
    /// Sends a single coordinate form (`x`/`y` only). The legacy duplicated
    /// `point: {x, y}` object is intentionally omitted.
    pub async fn click_element(
        &self,
        id: Option<&str>,
        point: Option<(f32, f32)>,
    ) -> Result<serde_json::Value, ClientError> {
        let mut args = serde_json::Map::new();
        if let Some(elem_id) = id {
            args.insert("id".to_string(), serde_json::json!(elem_id));
        }
        if let Some((x, y)) = point {
            args.insert("x".to_string(), serde_json::json!(x));
            args.insert("y".to_string(), serde_json::json!(y));
        }

        self.call_tool("click_element", serde_json::Value::Object(args))
            .await
    }

    /// Sends keystrokes to active or targeted element (`send_keys`).
    ///
    /// Sends the canonical `element_id` only. The server still accepts the
    /// legacy `target_id` alias for old clients, but new callers must not
    /// send both forms.
    pub async fn send_keys(
        &self,
        text: &str,
        target_id: Option<&str>,
    ) -> Result<serde_json::Value, ClientError> {
        let mut args = serde_json::Map::new();
        args.insert("text".to_string(), serde_json::json!(text));
        if let Some(id) = target_id {
            args.insert("element_id".to_string(), serde_json::json!(id));
        }

        self.call_tool("send_keys", serde_json::Value::Object(args))
            .await
    }

    /// Captures a rendered window snapshot (`get_screenshot`).
    pub async fn get_screenshot(&self) -> Result<serde_json::Value, ClientError> {
        self.call_tool("get_screenshot", serde_json::json!({})).await
    }

    /// Queries application state and metrics (`get_state`).
    ///
    /// Sends the canonical `keys` array filter. The legacy single-`query`
    /// string form is deprecated server-side but still accepted there.
    pub async fn get_state(
        &self,
        keys: Option<Vec<String>>,
    ) -> Result<serde_json::Value, ClientError> {
        let mut args = serde_json::Map::new();
        if let Some(ks) = keys {
            args.insert("keys".to_string(), serde_json::json!(ks));
        }

        self.call_tool("get_state", serde_json::Value::Object(args))
            .await
    }

    /// Lists all exposed MCP resources (`resources/list`).
    pub async fn list_resources(&self) -> Result<serde_json::Value, ClientError> {
        self.send_request("resources/list", None).await
    }

    /// Reads an MCP resource by URI (`resources/read`).
    pub async fn read_resource(&self, uri: &str) -> Result<serde_json::Value, ClientError> {
        let params = serde_json::json!({ "uri": uri });
        self.send_request("resources/read", Some(params)).await
    }
}

/// Convenience MCP Client for In-Memory Duplex communication.
pub type InMemoryMcpClient = McpClient<tokio::io::WriteHalf<tokio::io::DuplexStream>>;

impl InMemoryMcpClient {
    /// Creates an in-memory client connected to a [`tokio::io::DuplexStream`].
    pub fn connect_duplex(stream: tokio::io::DuplexStream) -> Self {
        let (reader, writer) = tokio::io::split(stream);
        Self::new(reader, writer)
    }
}

/// Managed Child Process MCP Client that spawns and controls a real Slate application binary.
pub struct ProcessMcpClient {
    client: McpClient<ChildStdin>,
    child: Child,
}

impl ProcessMcpClient {
    /// Spawns a child process and attaches the MCP client to its standard input/output.
    pub fn spawn(command: &str, args: &[&str]) -> Result<Self, ClientError> {
        let mut child = Command::new(command)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(ClientError::Io)?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| ClientError::Protocol("Failed to open child process stdin".to_string()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ClientError::Protocol("Failed to open child process stdout".to_string()))?;

        let client = McpClient::new(stdout, stdin);

        Ok(Self { client, child })
    }

    /// Returns a reference to the inner [`McpClient`].
    pub fn client(&self) -> &McpClient<ChildStdin> {
        &self.client
    }

    /// Returns a mutable reference to the inner [`McpClient`].
    pub fn client_mut(&mut self) -> &mut McpClient<ChildStdin> {
        &mut self.client
    }

    /// Shuts down the child process and reaps it.
    ///
    /// `kill` alone would leave a zombie: the child must be `wait`ed on so the
    /// OS releases its exit status. An already-exited child is not an error.
    pub async fn kill(&mut self) -> Result<(), ClientError> {
        match self.child.kill().await {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(ClientError::Io(e)),
        }
        // Reap the child process so no zombie entry is left behind.
        self.child.wait().await.map_err(ClientError::Io)?;
        Ok(())
    }

    /// Waits for the child process to exit.
    pub async fn wait(&mut self) -> Result<std::process::ExitStatus, ClientError> {
        self.child.wait().await.map_err(ClientError::Io)
    }
}

impl std::ops::Deref for ProcessMcpClient {
    type Target = McpClient<ChildStdin>;

    fn deref(&self) -> &Self::Target {
        &self.client
    }
}

impl std::ops::DerefMut for ProcessMcpClient {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.client
    }
}
