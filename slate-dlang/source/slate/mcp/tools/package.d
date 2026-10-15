/// MCP standard tool registry and dispatch.
///
/// Mirrors `slate_mcp::tools`: the five tools, `send_keys` argument
/// extraction (with the `target_id` alias), and the three-way dispatch
/// error mapping the server turns into JSON-RPC errors.
module slate.mcp.tools;

public import slate.mcp.tools.click;
public import slate.mcp.tools.keys;
public import slate.mcp.tools.screenshot;
public import slate.mcp.tools.state;
public import slate.mcp.tools.tree;

import std.json : JSONValue;

import slate.agent.engine : AutomationEngine;
import slate.mcp.resources : BoundedLog;
import slate.mcp.schema : ToolCallResult;

/// Lookup/validation failures (the server maps these to JSON-RPC errors).
class ToolDispatchError : Exception
{
    enum Kind
    {
        notFound,
        invalidParams,
        internal_
    }

    Kind kind;
    string detail;

    private this(Kind kind, string msg) @safe pure
    {
        super(msg);
        this.kind = kind;
    }

    static ToolDispatchError notFound(string tool) @safe pure
    {
        auto e = new ToolDispatchError(Kind.notFound, "Tool not found: " ~ tool);
        e.detail = tool;
        return e;
    }

    static ToolDispatchError invalidParams(string message) @safe pure
    {
        auto e = new ToolDispatchError(Kind.invalidParams, message);
        e.detail = message;
        return e;
    }

    static ToolDispatchError internal_(string message) @safe pure
    {
        auto e = new ToolDispatchError(Kind.internal_, message);
        e.detail = message;
        return e;
    }
}

ToolCallResult dispatchTool(AutomationEngine engine, BoundedLog logs,
    string name, JSONValue arguments)
{
    import std.json : JSONType;

    if (arguments.type == JSONType.null_)
        arguments = JSONValue((JSONValue[string]).init);
    else if (arguments.type != JSONType.object)
        throw ToolDispatchError.invalidParams("Tool arguments must be a JSON object");

    switch (name)
    {
    case "get_screenshot":
        return handleScreenshot(engine, arguments);
    case "inspect_tree":
        return handleInspectTree(engine, arguments);
    case "click_element":
        return handleClickElement(engine, logs, arguments);
    case "send_keys":
        if (!("text" in arguments) || arguments["text"].type != JSONType.string)
            throw ToolDispatchError.invalidParams("Missing required argument 'text'");
        string elementId;
        if ("element_id" in arguments && arguments["element_id"].type == JSONType.string)
            elementId = arguments["element_id"].get!string;
        else if ("target_id" in arguments && arguments["target_id"].type == JSONType.string)
            elementId = arguments["target_id"].get!string;
        bool clearFirst;
        if ("clear_first" in arguments && arguments["clear_first"].type == JSONType.true_)
            clearFirst = true;
        return handleSendKeys(engine, logs, arguments["text"].get!string, elementId, clearFirst);
    case "get_state":
        return handleGetState(engine, arguments);
    default:
        throw ToolDispatchError.notFound(name);
    }
}

///
unittest
{
    import slate.agent.engine : DefaultAutomationEngine, DefaultElementController,
        DefaultStateProvider, DefaultUiInspector, DefaultVisualRenderer;
    import std.exception : assertThrown;
    import std.json : parseJSON;

    auto engine = new DefaultAutomationEngine(new DefaultUiInspector(),
        new DefaultElementController(), new DefaultStateProvider(),
        new DefaultVisualRenderer());
    auto logs = new BoundedLog();

    // Unknown tools fail lookup; missing text fails validation.
    assertThrown!ToolDispatchError(dispatchTool(engine, logs, "nope", parseJSON(`{}`)));
    assertThrown!ToolDispatchError(dispatchTool(engine, logs, "send_keys", parseJSON(`{}`)));

    // Malformed non-object arguments throw ToolDispatchError.invalidParams
    assertThrown!ToolDispatchError(dispatchTool(engine, logs, "send_keys", parseJSON(`[]`)));
    assertThrown!ToolDispatchError(dispatchTool(engine, logs, "send_keys", parseJSON(`"a string"`)));
    assertThrown!ToolDispatchError(dispatchTool(engine, logs, "send_keys", parseJSON(`123`)));
    assertThrown!ToolDispatchError(dispatchTool(engine, logs, "send_keys", JSONValue(null)));

    // Screenshot round-trips PNG bytes as base64 image content.
    auto shot = dispatchTool(engine, logs, "get_screenshot", parseJSON(`{}`));
    assert(!shot.isError);
    assert(shot.content[0].contentType == "image");
    assert(shot.content[0].data.length > 0);

    // Tree with rooting, depth pruning, and error paths.
    assert(dispatchTool(engine, logs, "inspect_tree",
        parseJSON(`{"root_id":"root_window"}`)).isError == false);
    assert(dispatchTool(engine, logs, "inspect_tree",
        parseJSON(`{"root_id":"missing"}`)).isError == true);
    assert(dispatchTool(engine, logs, "inspect_tree",
        parseJSON(`{"max_depth":0}`)).isError == true);
    auto pruned = dispatchTool(engine, logs, "inspect_tree", parseJSON(`{"max_depth":1}`));
    assert(!pruned.isError);

    // Click validation cascade (messages verbatim from Rust).
    ToolCallResult click(string args)
    {
        return dispatchTool(engine, logs, "click_element", parseJSON(args));
    }

    assert(click(`{}`).isError);
    assert(click(`{"id":"a","x":1,"y":2}`).content[0].text.canFind("not both"));
    assert(click(`{"id":"a","button":"middle"}`).content[0].text.canFind("only supports button 'left'"));
    assert(click(`{"x":-1,"y":2}`).content[0].text.canFind("cannot be negative"));
    assert(click(`{"x":99999,"y":2}`).content[0].text.canFind("out of window bounds"));
    assert(click(`{"id":"anything","button":"nope"}`).content[0].text.canFind("Unsupported button"));
    auto ok = click(`{"id":"root_window"}`);
    assert(!ok.isError && ok.content[0].text.canFind("root_window"));

    // Keys: unknown id fails closed; active-element typing works.
    auto missing = dispatchTool(engine, logs, "send_keys", parseJSON(`{"text":"hi","element_id":"zzz"}`));
    assert(missing.content[0].text.canFind("not found in UI tree"));
    auto typed = dispatchTool(engine, logs, "send_keys", parseJSON(`{"text":"hi"}`));
    assert(!typed.isError);
    auto clearNoTarget = dispatchTool(engine, logs, "send_keys",
        parseJSON(`{"text":"hi","clear_first":true}`));
    assert(clearNoTarget.content[0].text.canFind("requires 'element_id'"));

    // State: strict keys/query validation, filtering, legacy query.
    assert(dispatchTool(engine, logs, "get_state",
        parseJSON(`{"keys":["a"],"query":"b"}`)).content[0].text.canFind("not both"));
    assert(dispatchTool(engine, logs, "get_state",
        parseJSON(`{"keys":"a"}`)).content[0].text.canFind("must be an array"));
    auto st = dispatchTool(engine, logs, "get_state", parseJSON(`{"keys":[]}`));
    assert(!st.isError && parseJSON(st.content[0].text)["properties"].object.length == 0);
    assert(logs.length > 0); // click + keys actions logged through the bound
}

import std.algorithm : canFind;
