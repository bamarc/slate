/// MCP resources (`slate://app/context`, `slate://logs/live`).
///
/// Exact port of `slate_mcp::resources`, including the bounded-log
/// discipline: `BoundedLog` encapsulates the `(Mutex<Vec<String>>,
/// dropped-count)` pair so tools and the server share the single
/// sanctioned write path (direct pushes would bypass the bound and lose
/// the eviction count). Logical-px viewport contract preserved: renderer
/// failure is an error, never a fake fallback size.
module slate.mcp.resources;

import core.sync.mutex : Mutex;

import slate.agent.engine : AutomationEngine;
import slate.mcp.schema : Resource, ResourceContent;

/// Maximum retained live-log lines; older lines drop oldest-first.
enum size_t maxLogLines = 2000;

/// Sanctioned write path for tool/dispatch logging (mirrors Rust's free
/// `push_bounded_log`): bounded, eviction-counted, never silently lost.
void pushBoundedLog(BoundedLog logs, string line)
{
    logs.push(line);
}

/// Bounded live-log buffer with eviction accounting.
final class BoundedLog
{
    private Mutex _mtx;
    private string[] _lines;
    private ulong _dropped;

    this()
    {
        _mtx = new Mutex();
    }

    /// The ONLY sanctioned write path (see module docs).
    void push(string line)
    {
        synchronized (_mtx)
        {
            _lines ~= line;
            if (_lines.length > maxLogLines)
            {
                auto excess = _lines.length - maxLogLines;
                _lines = _lines[excess .. $];
                _dropped += excess;
            }
        }
    }

    string[] snapshot()
    {
        synchronized (_mtx)
            return _lines.dup;
    }

    ulong droppedCount()
    {
        synchronized (_mtx)
            return _dropped;
    }

    size_t length()
    {
        synchronized (_mtx)
            return _lines.length;
    }
}

/// Resource access failures.
class ResourceError : Exception
{
    enum Kind
    {
        notFound,
        internal_
    }

    Kind kind;
    string uri;

    private this(Kind kind, string msg) @safe pure
    {
        super(msg);
        this.kind = kind;
    }

    static ResourceError notFound(string uri) @safe pure
    {
        auto e = new ResourceError(Kind.notFound, "Resource not found: " ~ uri);
        e.uri = uri;
        return e;
    }

    static ResourceError internal_(string message) @safe pure
    {
        return new ResourceError(Kind.internal_, message);
    }
}

/// The two standard Slate resources.
Resource[] listResources() @safe
{
    return [
        Resource("slate://app/context", "Application Context",
                "Current Slate application window metadata and configuration", "application/json"),
        Resource("slate://logs/live", "Live Execution Logs",
                "Real-time logging stream from Slate runtime", "text/plain"),
    ];
}

/// Read a resource. Unknown URIs (including only-slightly-off ones) fail
/// closed; a non-zero drop count heads the live log with a visible header.
ResourceContent readResource(AutomationEngine engine, BoundedLog logs, string uri,
        string appName, string appVersion, ulong droppedLogs)
{
    import std.format : format;

    switch (uri)
    {
    case "slate://app/context":
        uint w;
        uint h;
        try
        {
            auto vp = engine.renderer().viewportSize();
            w = vp.width;
            h = vp.height;
        }
        catch (Throwable t)
        {
            throw ResourceError.internal_("viewport unavailable: " ~ t.msg);
        }
        return ResourceContent("slate://app/context", "application/json",
                format!`{"app":%s,"version":%s,"window_width":%s,"window_height":%s}`(
                    jsonString(appName), jsonString(appVersion), w, h), null);
    case "slate://logs/live":
    case "slate://app/logs":
        string text;
        if (droppedLogs > 0)
            text = format!"[MCP] %s oldest log line(s) dropped (buffer cap %s)\n"(droppedLogs,
                    maxLogLines);
        import std.array : join;

        text ~= logs.snapshot().join("\n");
        return ResourceContent(uri, "text/plain", text, null);
    default:
        throw ResourceError.notFound(uri);
    }
}

private string jsonString(string s) @safe
{
    import std.json : JSONValue;

    return JSONValue(s).toString();
}

///
unittest
{
    import slate.agent.engine : DefaultUiInspector, DefaultElementController,
        DefaultStateProvider, DefaultVisualRenderer, DefaultAutomationEngine;
    import std.exception : assertThrown;

    auto engine = new DefaultAutomationEngine(new DefaultUiInspector(),
            new DefaultElementController(), new DefaultStateProvider(),
            new DefaultVisualRenderer(640, 480));

    assert(listResources().length == 2);
    assert(listResources()[0].uri == "slate://app/context");

    auto ctx = readResource(engine, new BoundedLog(), "slate://app/context", "demo", "1.0", 0);
    assert(ctx.mimeType == "application/json");
    import std.json : parseJSON;

    assert(parseJSON(ctx.text) == parseJSON(
            `{"app":"demo","version":"1.0","window_width":640,"window_height":480}`));

    assertThrown!ResourceError(readResource(engine, new BoundedLog(), "slate://nope", "a", "b", 0));

    // Bounded log: cap, oldest-first eviction, counted drops, header.
    auto logs = new BoundedLog();
    foreach (i; 0 .. maxLogLines + 5)
    {
        import std.conv : to;

        logs.push("line" ~ i.to!string);
    }
    assert(logs.length == maxLogLines);
    assert(logs.droppedCount() == 5);
    assert(logs.snapshot()[0] == "line5");
    auto live = readResource(engine, logs, "slate://logs/live", "a", "b", logs.droppedCount());
    assert(live.text.length > 0);
    import std.algorithm : startsWith;

    assert(live.text.startsWith("[MCP] 5 oldest log line(s) dropped"));
    auto live2 = readResource(engine, new BoundedLog(), "slate://app/logs", "a", "b", 0);
    assert(live2.text == "");
}
