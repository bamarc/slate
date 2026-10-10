//! Agent Communication Protocol (ACP) extension traits, message structures,
//! performative routing, and reference adapter implementation.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use serde::{Deserialize, Serialize};

use crate::error::AgentError;
use crate::protocol::{AgentProtocolAdapter, ProtocolServerHandle};
use crate::traits::AutomationEngine;

// ============================================================================
// 1. ACP Performatives & Envelopes
// ============================================================================

/// Communicative speech act / performative in the Agent Communication Protocol (ACP).
///
/// Models communicative intent based on multi-agent communication standards (FIPA-ACL / ACP).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AcpPerformative {
    /// Request an agent to perform an action or computation and return the outcome.
    #[serde(rename = "request", alias = "Request")]
    Request,

    /// Query application or UI state without inducing state mutations or side effects.
    #[serde(rename = "query", alias = "Query")]
    Query,

    /// Imperative command to alter UI or application state (click, input, toggle).
    #[serde(rename = "command", alias = "Command")]
    Command,

    /// Unidirectional notification or statement of fact (event notification, status).
    #[serde(rename = "inform", alias = "Inform")]
    Inform,

    /// Subscription request for continuous state updates or event notifications.
    #[serde(rename = "subscribe", alias = "Subscribe")]
    Subscribe,
}

impl AcpPerformative {
    /// Returns `true` if this performative is strictly read-only.
    pub fn is_read_only(&self) -> bool {
        matches!(self, Self::Query)
    }

    /// Returns `true` if this performative permits side effects / state mutations.
    pub fn allows_mutation(&self) -> bool {
        matches!(self, Self::Request | Self::Command)
    }

    /// Returns `true` if this performative expects an informative response data payload.
    pub fn expects_response(&self) -> bool {
        matches!(self, Self::Request | Self::Query | Self::Command | Self::Subscribe)
    }
}

/// Standard ACP message envelope for agent-to-agent remote control and communication.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AcpMessage {
    /// Unique message identifier (e.g. UUID v4 or generated ID).
    pub message_id: String,

    /// The communicative performative (Request, Query, Command, Inform, Subscribe).
    pub performative: AcpPerformative,

    /// Target action or topic name (e.g. "inspect_tree", "click", "send_keys", "get_state", "screenshot").
    pub action: String,

    /// Identity / address of the sending agent.
    pub sender: String,

    /// Structured parameters or payload as a JSON value.
    #[serde(default)]
    pub payload: serde_json::Value,

    /// Optional conversation or correlation identifier for multi-turn interactions.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,

    /// Optional UTC timestamp in milliseconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp_ms: Option<u64>,
}

static MESSAGE_COUNTER: AtomicU64 = AtomicU64::new(1);

impl AcpMessage {
    /// Creates a new ACP message with an auto-generated unique identifier.
    pub fn new(
        performative: AcpPerformative,
        action: impl Into<String>,
        sender: impl Into<String>,
        payload: serde_json::Value,
    ) -> Self {
        let count = MESSAGE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let message_id = format!("acp-msg-{ts}-{count}");

        Self {
            message_id,
            performative,
            action: action.into(),
            sender: sender.into(),
            payload,
            conversation_id: None,
            timestamp_ms: Some(ts),
        }
    }

    /// Helper constructor for a `Request` performative.
    pub fn request(
        action: impl Into<String>,
        sender: impl Into<String>,
        payload: serde_json::Value,
    ) -> Self {
        Self::new(AcpPerformative::Request, action, sender, payload)
    }

    /// Helper constructor for a `Query` performative.
    pub fn query(
        action: impl Into<String>,
        sender: impl Into<String>,
        payload: serde_json::Value,
    ) -> Self {
        Self::new(AcpPerformative::Query, action, sender, payload)
    }

    /// Helper constructor for a `Command` performative.
    pub fn command(
        action: impl Into<String>,
        sender: impl Into<String>,
        payload: serde_json::Value,
    ) -> Self {
        Self::new(AcpPerformative::Command, action, sender, payload)
    }

    /// Helper constructor for an `Inform` performative.
    pub fn inform(
        action: impl Into<String>,
        sender: impl Into<String>,
        payload: serde_json::Value,
    ) -> Self {
        Self::new(AcpPerformative::Inform, action, sender, payload)
    }

    /// Helper constructor for a `Subscribe` performative.
    pub fn subscribe(
        action: impl Into<String>,
        sender: impl Into<String>,
        payload: serde_json::Value,
    ) -> Self {
        Self::new(AcpPerformative::Subscribe, action, sender, payload)
    }

    /// Sets the optional conversation ID.
    pub fn with_conversation_id(mut self, conversation_id: impl Into<String>) -> Self {
        self.conversation_id = Some(conversation_id.into());
        self
    }

    /// Sets the explicit timestamp in milliseconds.
    pub fn with_timestamp(mut self, timestamp_ms: u64) -> Self {
        self.timestamp_ms = Some(timestamp_ms);
        self
    }
}

/// Standard ACP response envelope returned by an [`AcpEndpoint`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AcpResponse {
    /// Correlates directly with the `message_id` of the original request.
    pub correlation_id: String,

    /// Indicates whether the requested action succeeded.
    pub success: bool,

    /// Structured result data returned by the operation.
    #[serde(default)]
    pub data: serde_json::Value,

    /// Error message if the operation failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl AcpResponse {
    /// Creates a successful response with structured JSON data.
    pub fn success(correlation_id: impl Into<String>, data: serde_json::Value) -> Self {
        Self {
            correlation_id: correlation_id.into(),
            success: true,
            data,
            error: None,
        }
    }

    /// Creates a failed response with an error description.
    pub fn failure(correlation_id: impl Into<String>, error: impl Into<String>) -> Self {
        Self {
            correlation_id: correlation_id.into(),
            success: false,
            data: serde_json::Value::Null,
            error: Some(error.into()),
        }
    }

    /// Converts a `Result<T, AgentError>` into an `AcpResponse`.
    pub fn from_result<T: Serialize>(
        correlation_id: impl Into<String>,
        result: Result<T, AgentError>,
    ) -> Self {
        let corr = correlation_id.into();
        match result {
            Ok(val) => match serde_json::to_value(val) {
                Ok(data) => Self::success(corr, data),
                Err(err) => Self::failure(corr, format!("Response serialization error: {err}")),
            },
            Err(err) => Self::failure(corr, err.to_string()),
        }
    }
}

// ============================================================================
// 2. AcpEndpoint Trait & DefaultAcpEndpoint Router
// ============================================================================

/// Core ACP extension trait for dispatching messages to an underlying automation engine.
#[async_trait::async_trait]
pub trait AcpEndpoint: Send + Sync {
    /// Dispatches an ACP agent message to the automation engine and returns the response.
    async fn dispatch_acp(&self, message: AcpMessage) -> Result<AcpResponse, AgentError>;
}

/// Default implementation of [`AcpEndpoint`] wrapping an [`AutomationEngine`].
pub struct DefaultAcpEndpoint {
    engine: Arc<dyn AutomationEngine>,
}

impl DefaultAcpEndpoint {
    /// Creates a new ACP endpoint dispatch router wrapping the given automation engine.
    pub fn new(engine: Arc<dyn AutomationEngine>) -> Self {
        Self { engine }
    }
}

#[async_trait::async_trait]
impl AcpEndpoint for DefaultAcpEndpoint {
    async fn dispatch_acp(&self, message: AcpMessage) -> Result<AcpResponse, AgentError> {
        let correlation_id = message.message_id.clone();

        // 1. Performative Semantics Validation
        if message.performative == AcpPerformative::Query {
            match message.action.as_str() {
                "click" | "click_element" | "send_keys" | "toggle" | "toggle_element" => {
                    return Ok(AcpResponse::failure(
                        correlation_id,
                        format!(
                            "Query performative cannot be used for mutating action '{}'. Use Request or Command instead.",
                            message.action
                        ),
                    ));
                }
                _ => {}
            }
        }

        // 2. Inform Performative (unidirectional acknowledgment)
        if message.performative == AcpPerformative::Inform {
            return Ok(AcpResponse::success(
                correlation_id,
                serde_json::json!({
                    "status": "acknowledged",
                    "action": message.action,
                    "sender": message.sender
                }),
            ));
        }

        // 3. Subscribe Performative (subscription registration)
        if message.performative == AcpPerformative::Subscribe {
            return Ok(AcpResponse::success(
                correlation_id,
                serde_json::json!({
                    "status": "subscribed",
                    "topic": message.action,
                    "subscription_id": format!("sub-{}-{}", message.sender, message.action)
                }),
            ));
        }

        // 4. Action Routing to AutomationEngine
        match message.action.as_str() {
            "inspect_tree" => {
                match self.engine.inspector().inspect_tree().await {
                    Ok(tree) => Ok(AcpResponse::from_result(correlation_id, Ok(tree))),
                    Err(err) => Ok(AcpResponse::failure(correlation_id, err.to_string())),
                }
            }

            "find_element" => {
                let selector = match message.payload.as_str() {
                    Some(s) => s,
                    None => message
                        .payload
                        .get("selector")
                        .and_then(|v| v.as_str())
                        .unwrap_or(""),
                };
                if selector.is_empty() {
                    return Ok(AcpResponse::failure(
                        correlation_id,
                        "Missing 'selector' parameter",
                    ));
                }
                match self.engine.inspector().find_element(selector).await {
                    Ok(node) => Ok(AcpResponse::from_result(correlation_id, Ok(node))),
                    Err(err) => Ok(AcpResponse::failure(correlation_id, err.to_string())),
                }
            }

            "click" | "click_element" => {
                let target = match message.payload.as_str() {
                    Some(s) => s,
                    None => message
                        .payload
                        .get("target")
                        .or_else(|| message.payload.get("selector"))
                        .and_then(|v| v.as_str())
                        .unwrap_or(""),
                };
                if target.is_empty() {
                    return Ok(AcpResponse::failure(
                        correlation_id,
                        "Missing 'target' parameter for click action",
                    ));
                }
                match self.engine.controller().click_element(target).await {
                    Ok(res) => Ok(AcpResponse::from_result(correlation_id, Ok(res))),
                    Err(err) => Ok(AcpResponse::failure(correlation_id, err.to_string())),
                }
            }

            "send_keys" => {
                let text = match message.payload.get("text").and_then(|v| v.as_str()) {
                    Some(t) => t,
                    None => match message.payload.as_str() {
                        Some(t) => t,
                        None => {
                            return Ok(AcpResponse::failure(
                                correlation_id,
                                "Missing 'text' parameter for send_keys action",
                            ));
                        }
                    },
                };
                let target = message.payload.get("target").and_then(|v| v.as_str());
                match self.engine.controller().send_keys(target, text).await {
                    Ok(res) => Ok(AcpResponse::from_result(correlation_id, Ok(res))),
                    Err(err) => Ok(AcpResponse::failure(correlation_id, err.to_string())),
                }
            }

            "toggle" | "toggle_element" => {
                let target = match message.payload.as_str() {
                    Some(s) => s,
                    None => message
                        .payload
                        .get("target")
                        .or_else(|| message.payload.get("selector"))
                        .and_then(|v| v.as_str())
                        .unwrap_or(""),
                };
                if target.is_empty() {
                    return Ok(AcpResponse::failure(
                        correlation_id,
                        "Missing 'target' parameter for toggle action",
                    ));
                }
                let state = message.payload.get("state").and_then(|v| v.as_bool());
                match self
                    .engine
                    .controller()
                    .toggle_element_state(target, state)
                    .await
                {
                    Ok(res) => Ok(AcpResponse::from_result(correlation_id, Ok(res))),
                    Err(err) => Ok(AcpResponse::failure(correlation_id, err.to_string())),
                }
            }

            "get_state" => {
                let query = message
                    .payload
                    .get("query")
                    .and_then(|v| v.as_str())
                    .or_else(|| message.payload.as_str());
                match self.engine.state().get_state(query).await {
                    Ok(state) => Ok(AcpResponse::from_result(correlation_id, Ok(state))),
                    Err(err) => Ok(AcpResponse::failure(correlation_id, err.to_string())),
                }
            }

            "get_diagnostics" => match self.engine.state().get_diagnostics().await {
                Ok(diag) => Ok(AcpResponse::from_result(correlation_id, Ok(diag))),
                Err(err) => Ok(AcpResponse::failure(correlation_id, err.to_string())),
            },

            "get_screenshot" | "screenshot" => {
                match self.engine.renderer().get_screenshot().await {
                    Ok(screenshot) => {
                        let base64_png = screenshot.to_base64_png();
                        let data = serde_json::json!({
                            "width": screenshot.width,
                            "height": screenshot.height,
                            "format": screenshot.format,
                            "data_base64": base64_png,
                            "byte_length": screenshot.data.len()
                        });
                        Ok(AcpResponse::success(correlation_id, data))
                    }
                    Err(err) => Ok(AcpResponse::failure(correlation_id, err.to_string())),
                }
            }

            unknown => Ok(AcpResponse::failure(
                correlation_id,
                format!("Unsupported ACP action: '{unknown}'"),
            )),
        }
    }
}

// ============================================================================
// 3. Reference / Mock ACP Adapter
// ============================================================================

/// Configuration for [`MockAcpAdapter`].
#[derive(Debug, Clone)]
pub struct MockAcpConfig {
    pub agent_id: String,
    pub channel_capacity: usize,
}

impl Default for MockAcpConfig {
    fn default() -> Self {
        Self {
            agent_id: "slate-acp-mock".to_string(),
            channel_capacity: 64,
        }
    }
}

/// Reference / Mock ACP Adapter implementing [`AgentProtocolAdapter`].
///
/// Validates attaching an ACP protocol agent to [`Arc<dyn AutomationEngine>`]
/// without touching any Slint or UI internals. Supports in-memory message dispatch
/// and channel-based simulation for testing and embedded agent integration.
#[derive(Debug, Default)]
pub struct MockAcpAdapter;

/// Server lifecycle handle returned by [`MockAcpAdapter::attach`].
pub struct MockAcpServerHandle {
    endpoint: Arc<dyn AcpEndpoint>,
    running: Arc<AtomicBool>,
    tx: tokio::sync::mpsc::Sender<(
        AcpMessage,
        tokio::sync::oneshot::Sender<Result<AcpResponse, AgentError>>,
    )>,
    join_handle: Option<tokio::task::JoinHandle<()>>,
}

impl MockAcpServerHandle {
    /// Dispatches an ACP message directly to the underlying endpoint.
    pub async fn dispatch(&self, message: AcpMessage) -> Result<AcpResponse, AgentError> {
        if !self.running.load(Ordering::SeqCst) {
            return Err(AgentError::internal("ACP adapter is stopped"));
        }
        self.endpoint.dispatch_acp(message).await
    }

    /// Creates an in-memory client for sending messages over the channel queue,
    /// simulating an external network or IPC agent connection.
    pub fn client(&self) -> MockAcpClient {
        MockAcpClient {
            tx: self.tx.clone(),
            sender_id: "mock-acp-client".to_string(),
        }
    }
}

impl ProtocolServerHandle for MockAcpServerHandle {
    fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    fn stop(&self) -> Result<(), AgentError> {
        self.running.store(false, Ordering::SeqCst);
        if let Some(ref handle) = self.join_handle {
            handle.abort();
        }
        Ok(())
    }

    fn local_addr(&self) -> Option<String> {
        Some("inproc://mock-acp".to_string())
    }
}

impl Drop for MockAcpServerHandle {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

/// In-memory client for sending ACP messages over async channels.
#[derive(Clone)]
pub struct MockAcpClient {
    tx: tokio::sync::mpsc::Sender<(
        AcpMessage,
        tokio::sync::oneshot::Sender<Result<AcpResponse, AgentError>>,
    )>,
    sender_id: String,
}

impl MockAcpClient {
    /// Sends an ACP message and asynchronously awaits the response.
    pub async fn send(&self, message: AcpMessage) -> Result<AcpResponse, AgentError> {
        let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
        self.tx
            .send((message, reply_tx))
            .await
            .map_err(|_| AgentError::internal("ACP server channel is closed"))?;
        reply_rx
            .await
            .map_err(|_| AgentError::internal("ACP reply sender dropped without response"))?
    }

    /// Sends a query action convenience helper.
    pub async fn query(
        &self,
        action: &str,
        payload: serde_json::Value,
    ) -> Result<AcpResponse, AgentError> {
        let msg = AcpMessage::query(action, &self.sender_id, payload);
        self.send(msg).await
    }

    /// Sends a command action convenience helper.
    pub async fn command(
        &self,
        action: &str,
        payload: serde_json::Value,
    ) -> Result<AcpResponse, AgentError> {
        let msg = AcpMessage::command(action, &self.sender_id, payload);
        self.send(msg).await
    }
}

impl AgentProtocolAdapter for MockAcpAdapter {
    type Config = MockAcpConfig;
    type ServerHandle = MockAcpServerHandle;

    fn attach(
        &mut self,
        engine: Arc<dyn AutomationEngine>,
        config: Self::Config,
    ) -> Result<Self::ServerHandle, AgentError> {
        let endpoint: Arc<dyn AcpEndpoint> = Arc::new(DefaultAcpEndpoint::new(engine));
        let running = Arc::new(AtomicBool::new(true));

        let (tx, mut rx) = tokio::sync::mpsc::channel::<(
            AcpMessage,
            tokio::sync::oneshot::Sender<Result<AcpResponse, AgentError>>,
        )>(config.channel_capacity);

        let endpoint_clone = endpoint.clone();
        let running_clone = running.clone();

        let join_handle = tokio::spawn(async move {
            while running_clone.load(Ordering::SeqCst) {
                if let Some((msg, reply_tx)) = rx.recv().await {
                    let response = endpoint_clone.dispatch_acp(msg).await;
                    let _ = reply_tx.send(response);
                } else {
                    break;
                }
            }
        });

        Ok(MockAcpServerHandle {
            endpoint,
            running,
            tx,
            join_handle: Some(join_handle),
        })
    }
}
