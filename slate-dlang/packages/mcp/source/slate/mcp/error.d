/// MCP error types and standard JSON-RPC 2.0 error codes.
///
/// Port of `slate_mcp::error`. `McpError` mirrors the Rust variants with
/// identical messages; `AgentError` chains through as its own kind.
module slate.mcp.error;

/// Standard JSON-RPC 2.0 codes.
enum long parseErrorCode = -32700;
enum long invalidRequestCode = -32600;
enum long methodNotFoundCode = -32601;
enum long invalidParamsCode = -32602;
enum long internalErrorCode = -32603;

class McpError : Exception
{
    enum Kind
    {
        protocol,
        invalidParams,
        methodNotFound,
        toolNotFound,
        resourceNotFound,
        io,
        serialization,
        agent,
        internal_
    }

    Kind kind;
    long code;
    string detail;

    private this(Kind kind, string message) @safe pure
    {
        super(message);
        this.kind = kind;
    }

    static McpError protocol(long code, string message) @safe pure
    {
        import std.format : format;

        auto e = new McpError(Kind.protocol,
                format!"JSON-RPC protocol error (%s): %s"(code, message));
        e.code = code;
        e.detail = message;
        return e;
    }

    static McpError invalidParams(string message) @safe pure
    {
        auto e = new McpError(Kind.invalidParams, "Invalid parameters: " ~ message);
        e.detail = message;
        return e;
    }

    static McpError methodNotFound(string method) @safe pure
    {
        auto e = new McpError(Kind.methodNotFound, "Method not found: " ~ method);
        e.detail = method;
        return e;
    }

    static McpError toolNotFound(string tool) @safe pure
    {
        auto e = new McpError(Kind.toolNotFound, "Tool not found: " ~ tool);
        e.detail = tool;
        return e;
    }

    static McpError resourceNotFound(string uri) @safe pure
    {
        auto e = new McpError(Kind.resourceNotFound, "Resource not found: " ~ uri);
        e.detail = uri;
        return e;
    }

    static McpError io(string message) @safe pure
    {
        auto e = new McpError(Kind.io, "Transport I/O error: " ~ message);
        e.detail = message;
        return e;
    }

    static McpError serialization(string message) @safe pure
    {
        auto e = new McpError(Kind.serialization, "Serialization error: " ~ message);
        e.detail = message;
        return e;
    }

    static McpError agent(string message) @safe pure
    {
        auto e = new McpError(Kind.agent, "Agent error: " ~ message);
        e.detail = message;
        return e;
    }

    static McpError internal_(string message) @safe pure
    {
        auto e = new McpError(Kind.internal_, "Internal server error: " ~ message);
        e.detail = message;
        return e;
    }
}

///
unittest
{
    assert(parseErrorCode == -32700 && invalidRequestCode == -32600);
    assert(methodNotFoundCode == -32601 && invalidParamsCode == -32602);
    assert(internalErrorCode == -32603);
    assert(McpError.toolNotFound("x").msg == "Tool not found: x");
    assert(McpError.protocol(-32600, "bad").msg == "JSON-RPC protocol error (-32600): bad");
    assert(McpError.internal_("boom").kind == McpError.Kind.internal_);
}
