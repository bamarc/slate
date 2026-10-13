/// `get_state` tool: strict `keys`/`query` validation, engine delegation.
module slate.mcp.tools.state;

import std.json : JSONValue;

import slate.agent.engine : AutomationEngine;
import slate.mcp.schema : ToolCallResult;

ToolCallResult handleGetState(AutomationEngine engine, JSONValue args)
{
    import std.json : JSONType;

    // Explicit null counts as absent (JSON-RPC convention).
    bool hasKeys = "keys" in args && args["keys"].type != JSONType.null_;
    bool hasQuery = "query" in args && args["query"].type != JSONType.null_;
    if (hasKeys && hasQuery)
        return ToolCallResult.failureText(
            "get_state accepts either 'keys' or legacy 'query', not both");

    string[] filter;
    bool filtered;
    if (hasKeys)
    {
        auto v = args["keys"];
        if (v.type != JSONType.array)
            return ToolCallResult.failureText("'keys' must be an array of property name strings");
        filtered = true;
        foreach (item; v.array)
        {
            if (item.type != JSONType.string)
                return ToolCallResult.failureText(
                    "'keys' must be an array of property name strings");
            filter ~= item.get!string;
        }
    }
    else if (hasQuery)
    {
        auto v = args["query"];
        if (v.type != JSONType.string)
            return ToolCallResult.failureText(
                "'query' must be a single property name string (prefer 'keys')");
        filtered = true;
        filter = [v.get!string];
    }

    try
    {
        import slate.agent.engine : getState;
        import std.typecons : Nullable;

        auto state = engine.state().getState(Nullable!string.init);
        if (filtered)
        {
            JSONValue[string] kept;
            foreach (k; filter)
                if (auto p = k in state.properties)
                    kept[k] = *p;
            state.properties = kept;
        }
        return ToolCallResult.successText(state.toJson().toString());
    }
    catch (Throwable t)
        return ToolCallResult.failureText(t.msg);
}
