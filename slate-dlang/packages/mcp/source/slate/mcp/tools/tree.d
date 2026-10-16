/// `inspect_tree` tool: UI tree JSON with subtree rooting and depth pruning.
module slate.mcp.tools.tree;

import std.json : JSONValue;

import slate.agent.engine : AutomationEngine;
import slate.agent.model : UiElementNode;
import slate.mcp.schema : ToolCallResult;

ToolCallResult handleInspectTree(AutomationEngine engine, JSONValue args)
{
    import std.json : JSONType;

    string rootId;
    bool hasRoot;
    if (args.type == JSONType.object && "root_id" in args && args["root_id"].type == JSONType
            .string)
    {
        rootId = args["root_id"].get!string;
        hasRoot = true;
    }
    bool hasDepth;
    ulong maxDepth;
    // Rust reads `as_u64`: non-integers (floats, strings, ...) mean "absent".
    if (args.type == JSONType.object && "max_depth" in args
            && args["max_depth"].type != JSONType.null_)
    {
        auto v = args["max_depth"];
        if (v.type == JSONType.integer)
        {
            maxDepth = cast(ulong) v.get!long;
            hasDepth = true;
        }
        else if (v.type == JSONType.uinteger)
        {
            maxDepth = v.get!ulong;
            hasDepth = true;
        }
    }
    if (hasDepth && maxDepth == 0)
        return ToolCallResult.failureText("max_depth must be >= 1");

    UiElementNode root;
    try
        root = engine.inspector().inspectTree().root;
    catch (Throwable t)
        return ToolCallResult.failureText(t.msg);

    if (hasRoot)
    {
        auto matched = root.findById(rootId);
        if (matched is null)
        {
            import std.format : format;

            return ToolCallResult.failureText(format!"Root element '%s' not found"(rootId));
        }
        root = matched.dup();
    }
    else
        root = root.dup();

    if (hasDepth)
        pruneDepth(root, 1, cast(uint) maxDepth);
    try
        return ToolCallResult.successText(root.toJson().toString());
    catch (Throwable t)
        return ToolCallResult.failureText("Serialization error: " ~ t.msg);
}

private void pruneDepth(UiElementNode node, uint current, uint max)
{
    if (current >= max)
        node.children.length = 0;
    else
        foreach (c; node.children)
            pruneDepth(c, current + 1, max);
}
