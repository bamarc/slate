//! Typed error definitions for the `slate-agent` crate.

use serde::{Deserialize, Serialize};
use thiserror::Error;

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
