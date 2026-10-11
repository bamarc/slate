//! Typed error definitions for the `slate-agent` crate.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// A candidate element listed in an [`AgentError::AmbiguousTarget`] error.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Candidate {
    pub reference: String,
    pub role: String,
    pub name: String,
}

/// Core error type representing all failure modes in agent inspection, execution,
/// Slint event loop synchronization, and protocol dispatch.
#[derive(Error, Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentError {
    #[error("Element not found: target '{target}', reason: {reason}")]
    ElementNotFound { target: String, reason: String },

    #[error("Operation timed out: {0}")]
    Timeout(String),

    #[error("Window or component handle is unavailable: {reason}")]
    WindowUnavailable { reason: String },

    #[error("Window or component has been closed / destroyed")]
    WindowClosed,

    #[error("Slint event loop is unavailable: {0}")]
    EventLoopUnavailable(String),

    #[error("UI response channel was dropped unexpectedly")]
    UiChannelClosed,

    #[error("UI thread panic intercepted: {0}")]
    UiPanic(String),

    #[error("UI event dispatch failed: {reason}")]
    DispatchFailed { reason: String },

    #[error("Render or snapshot error: {reason}")]
    RenderError { reason: String },

    #[error("State query or mutation failed: {reason}")]
    StateError { reason: String },

    #[error("Invalid operation: {reason}")]
    InvalidOperation { reason: String },

    #[error("Serialization error: {reason}")]
    SerializationError { reason: String },

    #[error("Protocol error: {reason}")]
    ProtocolError { reason: String },

    #[error("Internal agent error: {0}")]
    Internal(String),

    #[error("Stale element ref '{reference}': {reason}")]
    StaleRef { reference: String, reason: String },

    #[error("Selector matched {count} elements")]
    AmbiguousTarget { count: usize, candidates: Vec<Candidate> },

    #[error("Element '{reference}' is not interactable: {reason}")]
    NotInteractable { reference: String, reason: String },

    #[error("Action '{action}' unsupported on '{reference}'; supported: {supported:?}")]
    UnsupportedAction {
        reference: String,
        action: String,
        supported: Vec<String>,
    },

    #[error("Invalid params at '{path}': {message}")]
    InvalidParams { path: String, message: String },

    #[error("Action not found: {name}")]
    ActionNotFound { name: String },

    #[error("Action '{name}' failed: {reason}")]
    ActionFailed { name: String, reason: String },
}

impl AgentError {
    /// Creates an `ElementNotFound` error.
    pub fn element_not_found(target: impl Into<String>, reason: impl Into<String>) -> Self {
        Self::ElementNotFound {
            target: target.into(),
            reason: reason.into(),
        }
    }

    /// Creates a `Timeout` error with an operation name and duration in milliseconds.
    pub fn timeout(operation: impl Into<String>, duration_ms: u64) -> Self {
        Self::Timeout(format!(
            "Operation '{}' timed out after {}ms",
            operation.into(),
            duration_ms
        ))
    }

    /// Creates a `WindowUnavailable` error.
    pub fn window_unavailable(reason: impl Into<String>) -> Self {
        Self::WindowUnavailable {
            reason: reason.into(),
        }
    }

    /// Creates a `WindowClosed` error.
    pub fn window_closed() -> Self {
        Self::WindowClosed
    }

    /// Creates an `EventLoopUnavailable` error.
    pub fn event_loop_unavailable(reason: impl Into<String>) -> Self {
        Self::EventLoopUnavailable(reason.into())
    }

    /// Creates a `UiChannelClosed` error.
    pub fn ui_channel_closed() -> Self {
        Self::UiChannelClosed
    }

    /// Creates a `UiPanic` error.
    pub fn ui_panic(reason: impl Into<String>) -> Self {
        Self::UiPanic(reason.into())
    }

    /// Creates a `DispatchFailed` error.
    pub fn dispatch_failed(reason: impl Into<String>) -> Self {
        Self::DispatchFailed {
            reason: reason.into(),
        }
    }

    /// Creates a `RenderError`.
    pub fn render_error(reason: impl Into<String>) -> Self {
        Self::RenderError {
            reason: reason.into(),
        }
    }

    /// Creates a `StateError`.
    pub fn state_error(reason: impl Into<String>) -> Self {
        Self::StateError {
            reason: reason.into(),
        }
    }

    /// Creates an `InvalidOperation` error.
    pub fn invalid_operation(reason: impl Into<String>) -> Self {
        Self::InvalidOperation {
            reason: reason.into(),
        }
    }

    /// Creates a `SerializationError`.
    pub fn serialization(reason: impl Into<String>) -> Self {
        Self::SerializationError {
            reason: reason.into(),
        }
    }

    /// Creates a `ProtocolError`.
    pub fn protocol(reason: impl Into<String>) -> Self {
        Self::ProtocolError {
            reason: reason.into(),
        }
    }

    /// Creates an `Internal` error.
    pub fn internal(reason: impl Into<String>) -> Self {
        Self::Internal(reason.into())
    }
}

impl AgentError {
    /// Stable machine-readable code (snake_case).
    pub fn code(&self) -> &'static str {
        match self {
            Self::ElementNotFound { .. } => "element_not_found",
            Self::Timeout(_) => "timeout",
            Self::WindowUnavailable { .. } => "window_unavailable",
            Self::WindowClosed => "window_closed",
            Self::EventLoopUnavailable(_) => "event_loop_unavailable",
            Self::UiChannelClosed => "ui_channel_closed",
            Self::UiPanic(_) => "ui_panic",
            Self::DispatchFailed { .. } => "dispatch_failed",
            Self::RenderError { .. } => "render_error",
            Self::StateError { .. } => "state_error",
            Self::InvalidOperation { .. } => "invalid_operation",
            Self::SerializationError { .. } => "serialization_error",
            Self::ProtocolError { .. } => "protocol_error",
            Self::Internal(_) => "internal",
            Self::StaleRef { .. } => "stale_ref",
            Self::AmbiguousTarget { .. } => "ambiguous_target",
            Self::NotInteractable { .. } => "not_interactable",
            Self::UnsupportedAction { .. } => "unsupported_action",
            Self::InvalidParams { .. } => "invalid_params",
            Self::ActionNotFound { .. } => "action_not_found",
            Self::ActionFailed { .. } => "action_failed",
        }
    }

    /// JSON payload used by MCP tool error results:
    /// `{"code": .., "message": self.to_string(), "details": <variant fields or null>}`.
    ///
    /// `details` is an object with the variant's named fields; variants without named fields
    /// (tuple and unit variants) have `details: null`.
    pub fn to_error_json(&self) -> serde_json::Value {
        use serde_json::json;
        let details = match self {
            Self::ElementNotFound { target, reason } => json!({"target": target, "reason": reason}),
            Self::WindowUnavailable { reason }
            | Self::DispatchFailed { reason }
            | Self::RenderError { reason }
            | Self::StateError { reason }
            | Self::InvalidOperation { reason }
            | Self::SerializationError { reason }
            | Self::ProtocolError { reason } => json!({"reason": reason}),
            Self::StaleRef { reference, reason } | Self::NotInteractable { reference, reason } => {
                json!({"reference": reference, "reason": reason})
            }
            Self::AmbiguousTarget { count, candidates } => {
                json!({"count": count, "candidates": candidates})
            }
            Self::UnsupportedAction {
                reference,
                action,
                supported,
            } => json!({"reference": reference, "action": action, "supported": supported}),
            Self::InvalidParams { path, message } => json!({"path": path, "message": message}),
            Self::ActionNotFound { name } => json!({"name": name}),
            Self::ActionFailed { name, reason } => json!({"name": name, "reason": reason}),
            Self::Timeout(_)
            | Self::WindowClosed
            | Self::EventLoopUnavailable(_)
            | Self::UiChannelClosed
            | Self::UiPanic(_)
            | Self::Internal(_) => serde_json::Value::Null,
        };
        json!({"code": self.code(), "message": self.to_string(), "details": details})
    }
}

impl From<serde_json::Error> for AgentError {
    fn from(err: serde_json::Error) -> Self {
        Self::SerializationError {
            reason: err.to_string(),
        }
    }
}

impl From<slint::EventLoopError> for AgentError {
    fn from(err: slint::EventLoopError) -> Self {
        Self::EventLoopUnavailable(err.to_string())
    }
}

impl From<image::ImageError> for AgentError {
    fn from(err: image::ImageError) -> Self {
        Self::RenderError {
            reason: err.to_string(),
        }
    }
}
