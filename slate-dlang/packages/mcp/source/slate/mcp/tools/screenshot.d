/// `get_screenshot` tool: PNG frame as base64 image content.
module slate.mcp.tools.screenshot;

import std.json : JSONValue;

import slate.agent.engine : AutomationEngine;
import slate.agent.model : Screenshot;
import slate.mcp.schema : ToolCallResult, ToolContent;

ToolCallResult handleScreenshot(AutomationEngine engine, JSONValue args)
{
    Screenshot shot;
    try
        shot = engine.renderer().getScreenshot();
    catch (Throwable t)
        return ToolCallResult.failureText(t.msg);
    string format = shot.formatName.length ? shot.formatName : "image/png";
    return ToolCallResult.success([
        ToolContent.ofImage(shot.toBase64Png(), format)
    ]);
}
