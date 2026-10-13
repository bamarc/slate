/// `click_element` tool: exclusive selector/coordinate targeting,
///
/// viewport bounds-checking against the renderer's logical-px size, left-only
/// element path, repeated dispatch, and MCP-shaped results. All validation
/// messages match the Rust implementation verbatim.
module slate.mcp.tools.click;

import std.json : JSONValue;

import slate.agent.engine : AutomationEngine;
import slate.agent.error : AgentError;
import slate.agent.model : MouseButton, Point;
import slate.mcp.resources : BoundedLog, pushBoundedLog;
import slate.mcp.schema : ToolCallResult;

/// Action result in MCP client shape.
struct McpActionResult
{
    bool success;
    string target;
    string details; // null = absent

    JSONValue toJson() const
    {
        JSONValue[string] o = ["success": JSONValue(success), "target": JSONValue(target)];
        if (details !is null)
            o["details"] = JSONValue(details);
        return JSONValue(o);
    }
}

private MouseButton parseButton(string name, out bool ok)
{
    switch (name)
    {
    case "left":
        ok = true;
        return MouseButton.left;
    case "right":
        ok = true;
        return MouseButton.right;
    case "middle":
        ok = true;
        return MouseButton.middle;
    default:
        ok = false;
        return MouseButton.left;
    }
}

/// Optional JSON number as double (floats and integers; nothing else).
private bool numArg(JSONValue args, string key, out double value)
{
    import std.json : JSONType;

    if (key in args)
    {
        auto v = args[key];
        if (v.type == JSONType.float_)
        {
            value = v.get!double;
            return true;
        }
        if (v.type == JSONType.integer)
        {
            value = cast(double) v.get!long;
            return true;
        }
        if (v.type == JSONType.uinteger)
        {
            value = cast(double) v.get!ulong;
            return true;
        }
    }
    return false;
}

private string strArg(JSONValue args, string key)
{
    import std.json : JSONType;

    if (key in args && args[key].type == JSONType.string)
        return args[key].get!string;
    return null;
}

ToolCallResult handleClickElement(AutomationEngine engine, BoundedLog logs,
    JSONValue args)
{
    import std.format : format;

    string id = strArg(args, "id");
    string label = strArg(args, "label");
    double x;
    double y;
    bool hasX = numArg(args, "x", x);
    bool hasY = numArg(args, "y", y);
    if ("point" in args && args["point"].type == JSONType.object)
    {
        double px;
        double py;
        if (!hasX && numArg(args["point"], "x", px))
        {
            x = px;
            hasX = true;
        }
        if (!hasY && numArg(args["point"], "y", py))
        {
            y = py;
            hasY = true;
        }
    }
    string buttonName = strArg(args, "button");
    if (buttonName is null)
        buttonName = "left";
    ulong clickCount = 1;
    if ("click_count" in args)
    {
        auto v = args["click_count"];
        if (v.type == JSONType.integer && v.get!long >= 0)
            clickCount = cast(ulong) v.get!long;
        else if (v.type == JSONType.uinteger)
            clickCount = v.get!ulong;
    }

    if (id is null && label is null && (!hasX || !hasY))
        return ToolCallResult.failureText(
            "click_element requires 'id', 'label', or coordinates ('x','y')");
    if ((id !is null || label !is null) && (hasX || hasY))
        return ToolCallResult.failureText(
            "click_element accepts either an element selector ('id'/'label') or coordinates ('x','y'), not both");

    bool buttonOk;
    auto button = parseButton(buttonName, buttonOk);
    if (!buttonOk)
        return ToolCallResult.failureText(format!(
            "Unsupported button '%s': expected 'left', 'right', or 'middle'")(buttonName));

    bool takesElementBranch = !hasX || !hasY;
    bool isElementPath = takesElementBranch && (id !is null || label !is null);
    if (isElementPath && button != MouseButton.left)
        return ToolCallResult.failureText(format!(
            "click_element with element id/label only supports button 'left' (got '%s'); use coordinates for '%s' clicks")(
            buttonName, buttonName));

    if (hasX && hasY)
    {
        if (x < 0 || y < 0)
            return ToolCallResult.failureText(
                format!"Coordinates cannot be negative: (%s, %s)"(x, y));
        uint vw;
        uint vh;
        try
        {
            auto vp = engine.renderer().viewportSize();
            vw = vp.width;
            vh = vp.height;
        }
        catch (Throwable t)
            return ToolCallResult.failureText(
                "Viewport unavailable, cannot validate coordinates: " ~ t.msg);
        if (x > vw || y > vh)
            return ToolCallResult.failureText(format!(
                "Coordinates (%s, %s) out of window bounds (%sx%s)")(x, y, vw, vh));
    }

    import slate.agent.model : ActionResult;

    string targetName;
    bool ok;
    ActionResult last;
    AgentError lastErr;
    // Rust always dispatches once, then repeats while succeeding
    // (`1..count` after the first call); `max(..., 1)` keeps that shape.
    import std.algorithm : max;

    if (hasX && hasY)
    {
        auto pt = Point(cast(float) x, cast(float) y);
        targetName = format!"%s,%s"(x, y);
        foreach (_; 0 .. max(clickCount, 1))
        {
            if (_ > 0 && !ok)
                break;
            try
            {
                last = engine.controller().clickAt(pt, button);
                ok = true;
            }
            catch (AgentError e)
            {
                ok = false;
                lastErr = e;
            }
        }
    }
    else
    {
        string target = id !is null ? id : label;
        targetName = target;
        foreach (_; 0 .. max(clickCount, 1))
        {
            if (_ > 0 && !ok)
                break;
            try
            {
                last = engine.controller().clickElement(target);
                ok = true;
            }
            catch (AgentError e)
            {
                ok = false;
                lastErr = e;
            }
        }
    }

    if (ok)
    {
        pushBoundedLog(logs, "[ACTION] Clicked " ~ targetName);
        McpActionResult mcp = {last.success, targetName, last.message};
        return ToolCallResult.successText(mcp.toJson().toString());
    }
    string msg;
    if (lastErr !is null && lastErr.kind == AgentError.Kind.elementNotFound)
        msg = format!"Element not found or not clickable: '%s'"(targetName);
    else if (lastErr !is null && lastErr.msg.canFind("not found"))
        msg = format!"Element not found or not clickable: '%s'"(targetName);
    else if (lastErr !is null)
        msg = lastErr.msg;
    else
        msg = format!"Element not found or not clickable: '%s'"(targetName);
    return ToolCallResult.failureText(msg);
}

import std.algorithm : canFind, max;
import std.json : JSONType;
