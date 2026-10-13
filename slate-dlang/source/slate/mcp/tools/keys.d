/// `send_keys` tool: gated text entry with real clear-first writes.
module slate.mcp.tools.keys;

import std.json : JSONValue;

import slate.agent.engine : AutomationEngine;
import slate.mcp.resources : BoundedLog, pushBoundedLog;
import slate.mcp.schema : ToolCallResult;
import slate.mcp.tools.click : McpActionResult;

/// Editable roles (exact lowercase match on Slint AccessibleRole values).
private bool isEditableRole(string role) @safe pure nothrow
{
    return role == "textbox" || role == "spinbox" || role == "combobox";
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
        import slate.agent.model : UiElementNode;

        UiElementNode node;
        try
            node = engine.inspector().inspectTree().root.findById(elementId);
        catch (Throwable t)
            return ToolCallResult.failureText(
                format!"Unable to verify target element '%s': %s"(elementId, t.msg));
        if (node is null)
            return ToolCallResult.failureText(
                format!"Target element '%s' not found in UI tree"(elementId));
        if (!isEditableRole(node.role.toLower()))
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
