//! `slate-mcp`: Embedded Model Context Protocol (MCP) server adapter and transports
//! for Slate Agent.
//!
//! Exposes JSON-RPC 2.0 routing, standard automation tools (`get_screenshot`, `inspect_tree`,
//! `click_element`, `send_keys`, `get_state`), MCP resources (`slate://app/context`, `slate://logs/live`),
//! dual transports (stdio and in-memory duplex), and `AgentBuilder` integration.

pub mod adapter;
pub mod client;
pub mod error;
pub mod resources;
pub mod schema;
pub mod server;
pub mod tools;
pub mod transport;

pub use client::{
    ClientError, InMemoryMcpClient, McpClient, ProcessMcpClient, DEFAULT_CLIENT_TIMEOUT,
};

pub use adapter::{
    AgentBuilderMcpExt, McpAdapter, McpAdapterConfig, McpServerHandle, McpTransportMode,
};
pub use error::{
    McpError, McpResult, INTERNAL_ERROR, INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND,
    PARSE_ERROR,
};
pub use resources::{list_resources, read_resource, ResourceError};
pub use schema::{
    all_standard_tools, click_element_schema, get_screenshot_schema, get_state_schema,
    inspect_tree_schema, send_keys_schema, McpInitializeResult, McpToolDefinition, Resource,
    ResourceContent, ServerCapabilities, ServerInfo, Tool, ToolCallResult, ToolContent,
    ToolInputSchema,
};
pub use server::{JsonRpcError, JsonRpcRequest, JsonRpcResponse, McpServer};
pub use tools::{dispatch_tool, ToolDispatchError};
pub use transport::{
    create_in_memory_session, ensure_stderr_logging, run_line_transport, run_stdio,
    spawn_in_memory_transport, spawn_stdio_transport, InMemoryTransportHandle, McpTransportError,
    StdioTransportHandle,
};
