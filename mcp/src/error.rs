//! Error types and standard JSON-RPC 2.0 error codes for `slate-mcp`.

use thiserror::Error;

/// Standard JSON-RPC 2.0 Parse Error (-32700).
pub const PARSE_ERROR: i64 = -32700;
/// Standard JSON-RPC 2.0 Invalid Request (-32600).
pub const INVALID_REQUEST: i64 = -32600;
/// Standard JSON-RPC 2.0 Method Not Found (-32601).
pub const METHOD_NOT_FOUND: i64 = -32601;
/// Standard JSON-RPC 2.0 Invalid Params (-32602).
pub const INVALID_PARAMS: i64 = -32602;
/// Standard JSON-RPC 2.0 Internal Error (-32603).
pub const INTERNAL_ERROR: i64 = -32603;

/// Errors arising during MCP operations.
#[derive(Debug, Error)]
pub enum McpError {
    #[error("JSON-RPC protocol error ({code}): {message}")]
    Protocol { code: i64, message: String },

    #[error("Invalid parameters: {0}")]
    InvalidParams(String),

    #[error("Method not found: {0}")]
    MethodNotFound(String),

    #[error("Tool not found: {0}")]
    ToolNotFound(String),

    #[error("Resource not found: {0}")]
    ResourceNotFound(String),

    #[error("Transport I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("Agent error: {0}")]
    Agent(#[from] slate_agent::error::AgentError),

    #[error("Internal server error: {0}")]
    Internal(String),
}

pub type McpResult<T> = Result<T, McpError>;
