/// MCP JSON-RPC 2.0 server core, protocol router, and lifecycle state.
///
/// Exact port of `slate_mcp::server`: strict request validation
/// (parse/object/version/method/id rules with identical messages),
/// notification handling, the `initialize` handshake (including the
/// version-mismatch `data` echo rules), tool/resource routing, and the
/// bounded-log discipline. Synchronous where Rust is async (the D engine
/// surface is sync); wire behavior is identical.
module slate.mcp.server;

import std.json : JSONValue;

import slate.agent.engine : AutomationEngine;
import slate.mcp.error;
import slate.mcp.resources : BoundedLog, listResources, pushBoundedLog, readResource,
    ResourceError;
import slate.mcp.schema : allStandardTools, McpInitializeResult, ServerCapabilities,
    ServerInfo, ToolCallResult;
import slate.mcp.tools : dispatchTool, ToolDispatchError;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;

/// Protocol versions spoken here. `2025-06-18` is intentionally absent
/// (see the Rust note): mismatch clients get told as much.
immutable string[] supportedProtocolVersions = ["2024-11-05"];

struct JsonRpcRequest
{
    string jsonrpc;
    JSONValue id; // null JSON = absent
    bool hasId;
    string method;
    JSONValue params; // null JSON = absent
    bool hasParams;
}

struct JsonRpcError
{
    long code;
    string message;
    JSONValue data; // null JSON = absent
    bool hasData;

    JSONValue toJson() const
    {
        JSONValue[string] o = ["code": JSONValue(code), "message": JSONValue(message)];
        if (hasData)
            o["data"] = data;
        return JSONValue(o);
    }
}

struct JsonRpcResponse
{
    JSONValue id; // null JSON = absent
    bool hasId;
    JSONValue result; // valid when !isError
    JsonRpcError error;
    bool isError;

    static JsonRpcResponse success(JSONValue id, bool hasId, JSONValue result)
    {
        JsonRpcResponse r;
        r.id = id;
        r.hasId = hasId;
        r.result = result;
        return r;
    }

    static JsonRpcResponse failure(JSONValue id, bool hasId, long code, string message)
    {
        JsonRpcResponse r;
        r.id = id;
        r.hasId = hasId;
        r.isError = true;
        r.error = JsonRpcError(code, message, JSONValue.init, false);
        return r;
    }

    static JsonRpcResponse parseError(string message)
    {
        return failure(JSONValue.init, false, parseErrorCode, message);
    }

    static JsonRpcResponse invalidRequest(JSONValue id, bool hasId, string message)
    {
        return failure(id, hasId, invalidRequestCode, message);
    }

    static JsonRpcResponse methodNotFound(JSONValue id, bool hasId, string message)
    {
        return failure(id, hasId, methodNotFoundCode, message);
    }

    static JsonRpcResponse invalidParams(JSONValue id, bool hasId, string message)
    {
        return failure(id, hasId, invalidParamsCode, message);
    }

    static JsonRpcResponse internalError(JSONValue id, bool hasId, string message)
    {
        return failure(id, hasId, internalErrorCode, message);
    }

    JSONValue toJson() const
    {
        JSONValue[string] o = ["jsonrpc": JSONValue("2.0")];
        if (hasId)
            o["id"] = id;
        if (isError)
            o["error"] = error.toJson();
        else
            o["result"] = result;
        return JSONValue(o);
    }

    string toLine() const
    {
        return toJson().toString();
    }
}

final class McpServer
{
    private AutomationEngine _engine;
    private string _name;
    private string _version;
    private string _protocolVersion = "2024-11-05";
    private shared bool _initialized;
    private BoundedLog _logs;

    this(AutomationEngine engine, string name = "slate-mcp", string version_ = "0.1.0")
    {
        _engine = engine;
        _name = name;
        _version = version_;
        _logs = new BoundedLog();
    }

    AutomationEngine engine()
    {
        return _engine;
    }

    BoundedLog logs()
    {
        return _logs;
    }

    string name() const @safe pure nothrow
    {
        return _name;
    }

    bool isInitialized() const nothrow
    {
        try
            return atomicLoad(_initialized);
        catch (Throwable)
            return false;
    }

    /// Bounded append (the tools' log path shares this implementation).
    void addLog(string line)
    {
        pushBoundedLog(_logs, line);
    }

    ulong droppedLogCount() nothrow
    {
        try
            return _logs.droppedCount();
        catch (Throwable)
            return 0;
    }

    /// One raw line in; serialized response line out, or null for
    /// notifications and unparseable-as-anything input. Messages mirror Rust.
    string handleLine(string raw)
    {
        import std.json : JSONException, JSONType, parseJSON;

        JSONValue reqVal;
        try
            reqVal = parseJSON(raw);
        catch (JSONException e)
            return JsonRpcResponse.parseError("Parse error: " ~ e.msg).toLine();
        catch (Throwable t)
            return JsonRpcResponse.parseError("Parse error: " ~ t.msg).toLine();

        if (reqVal.type != JSONType.object)
            return JsonRpcResponse.invalidRequest(JSONValue.init, false,
                "Invalid Request: expected JSON object").toLine();

        auto obj = reqVal;
        if (!("jsonrpc" in obj) || obj["jsonrpc"].type != JSONType.string
            || obj["jsonrpc"].get!string != "2.0")
        {
            JSONValue id;
            bool hasId = ("id" in obj) !is null;
            if (hasId)
                id = obj["id"];
            return JsonRpcResponse.invalidRequest(id, hasId,
                "Invalid Request: missing or invalid 'jsonrpc' version").toLine();
        }

        bool hasId = ("id" in obj) !is null;
        JSONValue id = hasId ? obj["id"] : JSONValue.init;
        if (!("method" in obj) || obj["method"].type != JSONType.string)
            return JsonRpcResponse.invalidRequest(id, hasId, "Missing 'method'").toLine();
        string method = obj["method"].get!string;
        JSONValue params = ("params" in obj) ? obj["params"] : JSONValue.init;

        if (!hasId)
        {
            handleNotification(method, params);
            return null;
        }
        try
        {
            return handleRequest(id, method, params).toJson().toString();
        }
        catch (JSONException e)
        {
            return JsonRpcResponse.invalidParams(id, hasId, e.msg).toLine();
        }
        catch (Exception e)
        {
            return JsonRpcResponse.internalError(id, hasId, e.msg).toLine();
        }
    }

    void handleNotification(string method, JSONValue params)
    {
        if (method == "notifications/initialized")
        {
            atomicStore(_initialized, true);
            addLog("[MCP] Client initialized acknowledged");
        }
    }

    JsonRpcResponse handleRequest(JSONValue id, string method, JSONValue params)
    {
        import std.json : JSONType;

        bool hasParams = params.type != JSONType.null_;
        switch (method)
        {
        case "initialize":
            atomicStore(_initialized, true);
            string requested;
            bool hasRequested;
            if (hasParams)
            {
                if (params.type != JSONType.object)
                    return JsonRpcResponse.invalidParams(id, true, "Invalid params: expected object");
                if ("protocolVersion" in params && params["protocolVersion"].type == JSONType.string)
                {
                    requested = params["protocolVersion"].get!string;
                    hasRequested = true;
                }
            }
            auto init = McpInitializeResult(_protocolVersion,
                ServerCapabilities.bare(), ServerInfo(_name, _version));
            auto result = init.toJson();
            if (hasRequested)
            {
                bool supported;
                foreach (v; supportedProtocolVersions)
                    if (v == requested)
                        supported = true;
                if (!supported)
                {
                    JSONValue[] versions;
                    foreach (v; supportedProtocolVersions)
                        versions ~= JSONValue(v);
                    result["data"] = JSONValue(["supportedVersions": JSONValue(versions),
                        "requestedVersion": JSONValue(requested)]);
                }
            }
            return JsonRpcResponse.success(id, true, result);
        case "ping":
            return JsonRpcResponse.success(id, true,
                JSONValue((JSONValue[string]).init));
        case "tools/list":
            {
                JSONValue[] tools;
                foreach (t; allStandardTools())
                    tools ~= t.toJson();
                return JsonRpcResponse.success(id, true, JSONValue(["tools": JSONValue(tools)]));
            }
        case "tools/call":
            return handleToolsCall(id, params, hasParams);
        case "resources/list":
            {
                JSONValue[] res;
                foreach (r; listResources())
                    res ~= r.toJson();
                return JsonRpcResponse.success(id, true,
                    JSONValue(["resources": JSONValue(res)]));
            }
        case "resources/read":
            return handleResourcesRead(id, params, hasParams);
        default:
            {
                import std.format : format;

                return JsonRpcResponse.methodNotFound(id, true,
                    format!"Method '%s' not found"(method));
            }
        }
    }

    private JsonRpcResponse handleToolsCall(JSONValue id, JSONValue params, bool hasParams)
    {
        import std.json : JSONType, JSONException;

        if (!hasParams || params.type != JSONType.object)
            return JsonRpcResponse.invalidParams(id, true, "Missing 'name' in tools/call");
        if (!("name" in params) || params["name"].type != JSONType.string)
            return JsonRpcResponse.invalidParams(id, true, "Missing 'name' in tools/call");
        string toolName = params["name"].get!string;
        JSONValue args = JSONValue((JSONValue[string]).init);
        if ("arguments" in params)
        {
            if (params["arguments"].type == JSONType.null_)
                args = JSONValue((JSONValue[string]).init);
            else if (params["arguments"].type != JSONType.object)
                return JsonRpcResponse.invalidParams(id, true, "'arguments' in tools/call must be an object");
            else
                args = params["arguments"];
        }
        try
        {
            auto result = dispatchTool(_engine, _logs, toolName, args);
            return JsonRpcResponse.success(id, true, result.toJson());
        }
        catch (ToolDispatchError e)
        {
            final switch (e.kind)
            {
            case ToolDispatchError.Kind.notFound:
                {
                    import std.format : format;

                    return JsonRpcResponse.methodNotFound(id, true,
                        format!"Tool '%s' not found"(e.detail));
                }
            case ToolDispatchError.Kind.invalidParams:
                return JsonRpcResponse.invalidParams(id, true, e.detail);
            case ToolDispatchError.Kind.internal_:
                return JsonRpcResponse.internalError(id, true, e.detail);
            }
        }
        catch (JSONException e)
        {
            return JsonRpcResponse.invalidParams(id, true, e.msg);
        }
    }

    private JsonRpcResponse handleResourcesRead(JSONValue id, JSONValue params, bool hasParams)
    {
        import std.json : JSONType;
        import std.format : format;

        if (!hasParams || params.type != JSONType.object)
            return JsonRpcResponse.invalidParams(id, true, "Missing or invalid 'params': expected object");
        string uri;
        if ("uri" in params && params["uri"].type == JSONType.string)
            uri = params["uri"].get!string;
        else
            return JsonRpcResponse.invalidParams(id, true, "Missing 'uri' parameter");
        try
        {
            auto content = readResource(_engine, _logs, uri, _name, _version, droppedLogCount());
            JSONValue[] contents = [content.toJson()];
            return JsonRpcResponse.success(id, true, JSONValue(["contents": JSONValue(contents)]));
        }
        catch (ResourceError e)
        {
            final switch (e.kind)
            {
            case ResourceError.Kind.notFound:
                return JsonRpcResponse.invalidParams(id, true,
                    format!"Resource '%s' not found"(uri));
            case ResourceError.Kind.internal_:
                return JsonRpcResponse.internalError(id, true, e.msg);
            }
        }
    }
}

///
unittest
{
    import slate.agent.engine : DefaultAutomationEngine, DefaultElementController,
        DefaultStateProvider, DefaultUiInspector, DefaultVisualRenderer;
    import std.json : parseJSON;

    auto engine = new DefaultAutomationEngine(new DefaultUiInspector(),
        new DefaultElementController(), new DefaultStateProvider(),
        new DefaultVisualRenderer());
    auto server = new McpServer(engine, "test-srv", "9.9");

    JSONValue rpc(string line)
    {
        auto resp = server.handleLine(line);
        assert(resp !is null);
        return parseJSON(resp);
    }

    // Malformed and non-object input.
    assert(rpc("{oops")["error"]["code"].get!long == parseErrorCode);
    assert(rpc(`[1,2]`)["error"]["code"].get!long == invalidRequestCode);
    assert(rpc(`{"jsonrpc":"1.0","id":1,"method":"ping"}`)["error"]["code"].get!long
        == invalidRequestCode);
    assert(rpc(`{"jsonrpc":"2.0","id":7}`)["error"]["message"].get!string == "Missing 'method'");

    // Notifications answer nothing but flip state + log.
    assert(!server.isInitialized());
    assert(server.handleLine(`{"jsonrpc":"2.0","method":"notifications/initialized"}`) is null);
    assert(server.isInitialized());
    assert(server.logs().length == 1);
    assert(server.handleLine(`{"jsonrpc":"2.0","method":"nope"}`) is null);

    // Handshake: version echo, mismatch data rules, bare ping.
    auto hello = rpc(`{"jsonrpc":"2.0","id":1,"method":"initialize",` ~
        `"params":{"protocolVersion":"2024-11-05"}}`);
    assert(hello["result"]["protocolVersion"].get!string == "2024-11-05");
    assert(("data" in hello["result"]) is null);
    assert(hello["result"]["serverInfo"]["name"].get!string == "test-srv");
    auto mismatch = rpc(`{"jsonrpc":"2.0","id":2,"method":"initialize",` ~
        `"params":{"protocolVersion":"1999-01-01"}}`);
    assert(mismatch["result"]["data"]["requestedVersion"].get!string == "1999-01-01");
    assert(mismatch["result"]["data"]["supportedVersions"][0].get!string == "2024-11-05");
    assert(rpc(`{"jsonrpc":"2.0","id":3,"method":"ping"}`)["result"].object.length == 0);

    // Tool listing, unknown tool/method mapping.
    assert(rpc(`{"jsonrpc":"2.0","id":4,"method":"tools/list"}`)["result"]["tools"]
        .array.length == 5);
    assert(rpc(`{"jsonrpc":"2.0","id":5,"method":"tools/call",` ~
        `"params":{"name":"bogus"}}`)["error"]["code"].get!long == methodNotFoundCode);
    assert(rpc(`{"jsonrpc":"2.0","id":6,"method":"frobnicate"}`)["error"]["code"].get!long
        == methodNotFoundCode);

    // Live tool call through the router (state + bounded logging).
    auto st = rpc(`{"jsonrpc":"2.0","id":7,"method":"tools/call",` ~
        `"params":{"name":"get_state","arguments":{"keys":[]}}}`);
    assert(st["result"]["content"][0]["text"].get!string.canFind("active_view"));
    auto click = rpc(`{"jsonrpc":"2.0","id":8,"method":"tools/call",` ~
        `"params":{"name":"click_element","arguments":{"id":"root_window"}}}`);
    assert(!click["result"]["content"][0]["text"].get!string.canFind("isError"));

    // Resources list + read + errors.
    assert(rpc(`{"jsonrpc":"2.0","id":9,"method":"resources/list"}`)["result"]["resources"]
        .array.length == 2);
    auto ctx = rpc(`{"jsonrpc":"2.0","id":10,"method":"resources/read",` ~
        `"params":{"uri":"slate://app/context"}}`);
    assert(ctx["result"]["contents"][0]["mimeType"].get!string == "application/json");
    assert(rpc(`{"jsonrpc":"2.0","id":11,"method":"resources/read",` ~
        `"params":{"uri":"slate://missing"}}`)["error"]["code"].get!long == invalidParamsCode);
    assert(rpc(`{"jsonrpc":"2.0","id":12,"method":"resources/read",` ~
        `"params":{}}`)["error"]["code"].get!long == invalidParamsCode);

    // Non-object params in initialize and resources/read return invalidParamsCode (-32602)
    assert(rpc(`{"jsonrpc":"2.0","id":13,"method":"initialize","params":"not an object"}`)["error"]["code"].get!long
        == invalidParamsCode);
    assert(rpc(`{"jsonrpc":"2.0","id":14,"method":"initialize","params":[1,2,3]}`)["error"]["code"].get!long
        == invalidParamsCode);
    assert(rpc(`{"jsonrpc":"2.0","id":15,"method":"resources/read","params":"not an object"}`)["error"]["code"].get!long
        == invalidParamsCode);
    assert(rpc(`{"jsonrpc":"2.0","id":16,"method":"resources/read","params":[1,2]}`)["error"]["code"].get!long
        == invalidParamsCode);

    // Non-object or malformed arguments in tools/call return invalidParamsCode (-32602)
    assert(rpc(`{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"send_keys","arguments":[]}}`)["error"]["code"].get!long
        == invalidParamsCode);
    assert(rpc(`{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"send_keys","arguments":"str"}}`)["error"]["code"].get!long
        == invalidParamsCode);
    assert(rpc(`{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"send_keys","arguments":123}}`)["error"]["code"].get!long
        == invalidParamsCode);
    assert(rpc(`{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"send_keys","arguments":null}}`)["error"]["code"].get!long
        == invalidParamsCode);

    assert(server.droppedLogCount() == 0);
}

import std.algorithm : canFind;
