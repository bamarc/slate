/// Slate MCP: embedded JSON-RPC 2.0 / Model Context Protocol endpoint.
///
/// D port of `slate_mcp`: protocol router (`server`), wire schemas
/// (`schema`), the five automation tools (`tools`), resources with bounded
/// logging (`resources`), transports (`transport`), and engine attachment
/// (`adapter`). The interactive client and stdio binary follow next.
module slate.mcp;

public import slate.mcp.schema;
public import slate.mcp.error;
public import slate.mcp.resources;
public import slate.mcp.tools;
public import slate.mcp.server;
public import slate.mcp.transport;
public import slate.mcp.adapter;
