/// `send_keys` tool: gated text entry with real clear-first writes.
module slate.mcp.tools.keys;

import std.json : JSONValue;

import slate.agent.engine : AutomationEngine;
import slate.mcp.resources : BoundedLog, pushBoundedLog;
import slate.mcp.schema : ToolCallResult;
import slate.mcp.tools.click : McpActionResult;

import slate.agent.model : UiElementNode;

/// Editable roles (exact lowercase match on Slint AccessibleRole values).
private bool isEditableRole(string role) @safe pure nothrow
{
    return role == "text-input" || role == "textbox" || role == "searchbox"
        || role == "spinbox" || role == "spinbutton" || role == "combobox"
        || role == "slider";
}

private bool isEditableNode(UiElementNode node) @safe
{
    if (node is null)
        return false;
    import std.uni : toLower;
    import std.algorithm.searching : canFind;

    string r = node.role.toLower();
    if (isEditableRole(r))
        return true;
    if (r == "region")
    {
        string desc = node.description;
        if (desc.canFind("drop-receiver") || desc.canFind("value"))
            return true;
    }
    return false;
}

ToolCallResult handleSendKeys(AutomationEngine engine, BoundedLog logs,
    string text, string elementId, bool clearFirst)
{
    import std.format : format;
    import std.uni : toLower;

    string targetName = elementId !is null ? elementId : "active";

    // Fail closed: unknown ids never fall back to the focused element.
    if (elementId !is null)
    {
        string lookupId = (elementId.length > 0 && elementId[0] == '#')
            ? elementId[1 .. $] : elementId;
        UiElementNode node;
        try
            node = engine.inspector().inspectTree().root.findById(lookupId);
        catch (Throwable t)
            return ToolCallResult.failureText(
                format!"Unable to verify target element '%s': %s"(elementId, t.msg));
        if (node is null)
            return ToolCallResult.failureText(
                format!"Target element '%s' not found in UI tree"(elementId));
        if (!isEditableNode(node))
            return ToolCallResult.failureText(
                format!"Target element '%s' is not an editable text input"(elementId));
    }

    // clear_first is a real write: failures propagate, and without a target
    // there is nothing to clear (fail closed).
    if (clearFirst)
    {
        if (elementId is null)
            return ToolCallResult.failureText(
                "send_keys with 'clear_first' requires 'element_id': no target to clear");
        try
            engine.controller().setValue(elementId, "");
        catch (Throwable t)
            return ToolCallResult.failureText(format!(
                "Failed to clear target element '%s': %s")(elementId, t.msg));
    }

    try
    {
        import std.typecons : Nullable;

        Nullable!string target;
        if (elementId !is null)
            target = Nullable!string(elementId);
        auto res = engine.controller().sendKeys(target, text);
        pushBoundedLog(logs, format!"[ACTION] Typed into %s: %s"(targetName, text));
        McpActionResult mcp = {res.success, targetName, res.message};
        return ToolCallResult.successText(mcp.toJson().toString());
    }
    catch (Throwable t)
    {
        if (t.msg.canFind("not an editable"))
            return ToolCallResult.failureText(format!(
                "Target element '%s' is not an editable text input")(targetName));
        return ToolCallResult.failureText(t.msg);
    }
}

import std.algorithm : canFind;

/// Example:
// Spec: Security: send_keys security gate on region nodes vs editable text inputs
unittest
{
    import slate.agent.model : UiElementNode, Rect;
    import std.json : JSONValue;

    // Normal layout region without drop-receiver or value in description
    auto layoutRegion = new UiElementNode();
    layoutRegion.id = "layout-main";
    layoutRegion.role = "region";
    layoutRegion.bounds = Rect(0, 0, 800, 600);
    layoutRegion.properties["description"] = JSONValue("mcp:layout");
    assert(!isEditableNode(layoutRegion), "Normal layout region should not be editable");

    // SlateMcpDropTarget region with drop-receiver in description
    auto dropTarget = new UiElementNode();
    dropTarget.id = "dropzone-target";
    dropTarget.role = "region";
    dropTarget.bounds = Rect(10, 10, 200, 100);
    dropTarget.properties["description"] = JSONValue("mcp:controllable,drop-receiver");
    assert(isEditableNode(dropTarget), "Drop target region with drop-receiver should be editable");

    // Text input roles
    auto textInput = new UiElementNode();
    textInput.id = "search-input";
    textInput.role = "text-input";
    assert(isEditableNode(textInput));

    auto textBox = new UiElementNode();
    textBox.id = "text-box";
    textBox.role = "textbox";
    assert(isEditableNode(textBox));
}
