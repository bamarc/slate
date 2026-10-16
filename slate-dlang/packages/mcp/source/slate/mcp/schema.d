/// MCP tool schemas and protocol data models (protocol `2024-11-05`).
///
/// Exact port of `slate_mcp::schema`: the five standard tool definitions
/// (verbatim descriptions and shapes), capability/result/resource wire
/// types with serde-compatible JSON (camelCase renames, omissions).
module slate.mcp.schema;

import std.json : JSONValue;

/// Tool definition (`inputSchema` keeps its wire name via explicit key).
struct Tool
{
    string name;
    string description;
    JSONValue inputSchema;

    static Tool create(string name, string description, JSONValue schema) @safe
    {
        return Tool(name, description, schema);
    }

    JSONValue toJson() const @trusted
    {
        JSONValue[string] o;
        o["name"] = JSONValue(name);
        o["description"] = JSONValue(description);
        o["inputSchema"] = cast() inputSchema;
        return JSONValue(o);
    }
}

alias McpToolDefinition = Tool;
alias ToolInputSchema = JSONValue;

private JSONValue obj(JSONValue[string] fields) @trusted
{
    return JSONValue(fields);
}

Tool getScreenshotSchema() @safe
{
    return Tool.create("get_screenshot", "Captures the current rendered window frame and returns PNG image data",
            obj([
                "type": JSONValue("object"),
                "properties": obj([
                    "mime_type": obj([
                        "type": JSONValue("string"),
                        "default": JSONValue("image/png"),
                        "description": JSONValue("Image MIME type (default: image/png)"),
                    
                ])
    ])]));
}

Tool inspectTreeSchema() @safe
{
    return Tool.create("inspect_tree",
            "Returns the hierarchical UI tree of components, labels, IDs, and bounding rectangles",
            obj([
                "type": JSONValue("object"),
                "properties": obj([
                    "root_id": obj([
                        "type": JSONValue("string"),
                        "description": JSONValue(
                            "Optional element ID to inspect a specific subtree")
                    ]),
                    "max_depth": obj([
                        "type": JSONValue("integer"),
                        "minimum": JSONValue(1),
                        "description": JSONValue("Maximum depth for tree traversal (minimum: 1)")
                    ]),
                
    ])]));
}

Tool clickElementSchema() @safe
{
    return Tool.create("click_element",
            "Dispatches click events to specific elements by ID, text label, or coordinates. "
            ~ "Pass either an element selector ('id'/'label') or coordinates ('x'/'y'), not both.",
            obj([
                "type": JSONValue("object"),
                "properties": obj([
                    "id": obj([
                        "type": JSONValue("string"),
                        "description": JSONValue(
                            "Target element unique ID (mutually exclusive with coordinates)")
                    ]),
                    "label": obj([
                        "type": JSONValue("string"),
                        "description": JSONValue(
                            "Target element accessible label or text (mutually exclusive with coordinates)")
                    ]),
                    "x": obj([
                        "type": JSONValue("number"),
                        "description": JSONValue("Horizontal logical window coordinate")
                    ]),
                    "y": obj([
                        "type": JSONValue("number"),
                        "description": JSONValue("Vertical logical window coordinate")
                    ]),
                    "button": obj([
                        "type": JSONValue("string"),
                        "enum": JSONValue([
                            JSONValue("left"), JSONValue("right"),
                            JSONValue("middle")
                        ]),
                        "default": JSONValue("left"),
                        "description": JSONValue("Mouse button to click with")
                    ]),
                    "click_count": obj([
                        "type": JSONValue("integer"),
                        "enum": JSONValue([JSONValue(1), JSONValue(2)]),
                        "default": JSONValue(1),
                        "description": JSONValue(
                            "Number of clicks (1 for single click, 2 for two sequential single clicks)")
                    ]),
                    "point": obj([
                        "type": JSONValue("object"),
                        "description": JSONValue(
                            "Legacy alias for coordinates ({x, y}); prefer top-level 'x'/'y'")
                    ]),
                
    ])]));
}

Tool sendKeysSchema() @safe
{
    return Tool.create("send_keys", "Types text into active or targeted text inputs",
            obj([
                "type": JSONValue("object"),
                "properties": obj([
                    "text": obj([
                        "type": JSONValue("string"),
                        "description": JSONValue("Text to type into the target element")
                    ]),
                    "element_id": obj([
                        "type": JSONValue("string"),
                        "description": JSONValue(
                            "Target element ID (falls back to active element if omitted)")
                    ]),
                    "clear_first": obj([
                        "type": JSONValue("boolean"),
                        "default": JSONValue(false),
                        "description": JSONValue(
                            "Whether to clear existing text before typing (requires 'element_id')")
                    ]),
                
    ]), "required" : JSONValue([JSONValue("text")])]));
}

Tool getStateSchema() @safe
{
    return Tool.create("get_state", "Reads application properties, active view, or diagnostic metrics",
            obj([
                "type": JSONValue("object"),
                "properties": obj([
                    "keys": obj([
                        "type": JSONValue("array"),
                        "items": obj(["type": JSONValue("string")]),
                        "description": JSONValue("Optional list of state property keys to filter")
                    ]),
                    "query": obj([
                        "type": JSONValue("string"),
                        "description": JSONValue(
                            "Deprecated: single property key filter. Prefer `keys`. Mutually exclusive with `keys`.")
                    ]),
                
    ])]));
}

/// All five standard Slate remote-control tools, in Rust order.
Tool[] allStandardTools() @safe
{
    return [
        getScreenshotSchema(), inspectTreeSchema(), clickElementSchema(),
        sendKeysSchema(), getStateSchema()
    ];
}

struct ServerInfo
{
    string name;
    /// D keyword avoidance: wire key stays `"version"`.
    string version_;

    JSONValue toJson() const @safe
    {
        return JSONValue([
            "name": JSONValue(name),
            "version": JSONValue(version_)
        ]);
    }
}

struct ServerCapabilities
{
    JSONValue tools; // null = absent
    JSONValue resources; // null = absent
    JSONValue logging; // null = absent

    static ServerCapabilities bare() @safe
    {
        // Implemented surface only: tools + resources as `{}` markers,
        // logging de-advertised (mirrors the Rust initialize handler).
        ServerCapabilities c;
        c.tools = JSONValue((JSONValue[string]).init);
        c.resources = JSONValue((JSONValue[string]).init);
        return c;
    }

    JSONValue toJson() const @safe
    {
        JSONValue[string] o;
        if (tools.type != JSONType.null_)
            o["tools"] = tools;
        if (resources.type != JSONType.null_)
            o["resources"] = resources;
        if (logging.type != JSONType.null_)
            o["logging"] = logging;
        return JSONValue(o);
    }
}

import std.json : JSONType;

struct McpInitializeResult
{
    string protocolVersion;
    ServerCapabilities capabilities;
    ServerInfo serverInfo;

    JSONValue toJson() const @safe
    {
        return JSONValue([
            "protocolVersion": JSONValue(protocolVersion),
            "capabilities": capabilities.toJson(),
            "serverInfo": serverInfo.toJson()
        ]);
    }
}

struct ToolContent
{
    string contentType; // wire key "type"
    string text; // null = absent
    string data; // null = absent
    string mimeType; // null = absent (wire key "mimeType")

    static ToolContent ofText(string t) @safe pure nothrow
    {
        ToolContent c;
        c.contentType = "text";
        c.text = t;
        return c;
    }

    static ToolContent ofImage(string data, string mimeType) @safe pure nothrow
    {
        ToolContent c;
        c.contentType = "image";
        c.data = data;
        c.mimeType = mimeType;
        return c;
    }

    JSONValue toJson() const @safe
    {
        JSONValue[string] o = ["type": JSONValue(contentType)];
        if (text !is null)
            o["text"] = JSONValue(text);
        if (data !is null)
            o["data"] = JSONValue(data);
        if (mimeType !is null)
            o["mimeType"] = JSONValue(mimeType);
        return JSONValue(o);
    }
}

struct ToolCallResult
{
    ToolContent[] content;
    bool isError;

    static ToolCallResult success(ToolContent[] content) @safe pure nothrow
    {
        return ToolCallResult(content, false);
    }

    static ToolCallResult successText(string text) @safe pure
    {
        ToolContent[] c = [ToolContent.ofText(text)];
        return ToolCallResult(c, false);
    }

    static ToolCallResult failureText(string err) @safe pure
    {
        ToolContent[] c = [ToolContent.ofText(err)];
        return ToolCallResult(c, true);
    }

    JSONValue toJson() const @safe
    {
        JSONValue[] cs;
        foreach (c; content)
            cs ~= c.toJson();
        return JSONValue([
            "content": JSONValue(cs),
            "isError": JSONValue(isError)
        ]);
    }
}

struct Resource
{
    string uri;
    string name;
    string description; // null = absent
    string mimeType; // null = absent

    JSONValue toJson() const @safe
    {
        JSONValue[string] o = ["uri": JSONValue(uri), "name": JSONValue(name)];
        if (description !is null)
            o["description"] = JSONValue(description);
        if (mimeType !is null)
            o["mimeType"] = JSONValue(mimeType);
        return JSONValue(o);
    }
}

struct ResourceContent
{
    string uri;
    string mimeType; // null = absent
    string text; // null = absent
    string blob; // null = absent

    JSONValue toJson() const @safe
    {
        JSONValue[string] o = ["uri": JSONValue(uri)];
        if (mimeType !is null)
            o["mimeType"] = JSONValue(mimeType);
        if (text !is null)
            o["text"] = JSONValue(text);
        if (blob !is null)
            o["blob"] = JSONValue(blob);
        return JSONValue(o);
    }
}

///
unittest
{
    import std.json : parseJSON;

    // Five tools in order with verbatim names.
    auto tools = allStandardTools();
    assert(tools.length == 5);
    assert(tools[0].name == "get_screenshot" && tools[4].name == "get_state");
    assert(tools[2].toJson()["inputSchema"]["properties"]["button"]["enum"] == parseJSON(
            `["left","right","middle"]`));
    assert(tools[2].toJson()["inputSchema"]["properties"]["click_count"]["default"].get!long == 1);
    assert(tools[3].toJson()["inputSchema"]["required"] == parseJSON(`["text"]`));

    // Initialize result wire shape (camelCase renames, bare {} markers).
    McpInitializeResult r = McpInitializeResult("2024-11-05",
            ServerCapabilities.bare(), ServerInfo("slate-mcp", "0.1.0"));
    assert(r.toJson() == parseJSON(`{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"resources":{}},`
            ~ `"serverInfo":{"name":"slate-mcp","version":"0.1.0"}}`));

    // Content/result/resource shapes with omissions.
    assert(ToolContent.ofText("hi").toJson() == parseJSON(`{"type":"text","text":"hi"}`));
    assert(ToolContent.ofImage("d", "image/png")
            .toJson() == parseJSON(`{"type":"image","data":"d","mimeType":"image/png"}`));
    assert(ToolCallResult.failureText("bad").toJson()["isError"].get!bool == true);
    assert(Resource("u", "n", null, null).toJson() == parseJSON(`{"uri":"u","name":"n"}`));
}
