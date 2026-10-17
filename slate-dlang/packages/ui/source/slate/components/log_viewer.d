/// Bounded ring-buffer log model and MCP controller for SlateLogViewer.
module slate.components.log_viewer;

import std.algorithm : canFind;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import std.string : toLower;

import slint.model : ArrayModel;
import slint.value : Value, SlintField;
import slate.agent.error : AgentError;
import slate.agent.traits;
import slate.traits;

/// Represents a single structured log entry.
struct LogEntryData
{
    @SlintField("id") string id;
    @SlintField("timestamp") string timestamp;
    @SlintField("severity") string severity;
    @SlintField("source") string source;
    @SlintField("message") string message;
}

/// Bounded ring-buffer log model implementing McpControllable, Filterable, and Selectable.
class RingBufferLogModel : McpControllable, Filterable, Selectable
{
    mixin McpControllableMixin!"log_viewer";

    private LogEntryData[] _buffer;
    private ArrayModel!LogEntryData _model;
    private size_t _capacity;
    private size_t _nextId = 1;
    private string _severityFilter = "all";
    private string _searchQuery = "";
    private ptrdiff_t _selectedIndex = -1;

    this(string id = "log_viewer", size_t capacity = 500)
    {
        assert(capacity > 0, "RingBufferLogModel capacity must be > 0");
        setMcpNamespace(id);
        _capacity = capacity;
        _model = new ArrayModel!LogEntryData();
    }

    /// Underlying `ArrayModel!LogEntryData` for binding to `SlateLogViewer.entries`.
    @McpIgnore ArrayModel!LogEntryData model() @safe pure nothrow
    {
        return _model;
    }

    size_t capacity() const @safe pure nothrow
    {
        return _capacity;
    }

    size_t totalCount() const @safe pure nothrow
    {
        return _buffer.length;
    }

    size_t visibleCount() const
    {
        return visibleEntries().length;
    }

    string severityFilter() const @safe pure nothrow
    {
        return _severityFilter;
    }

    private void syncModel()
    {
        _model.clear();
        foreach (e; visibleEntries())
            _model.push(e);
    }

    /// Append a log line, evicting the oldest entry if capacity is exceeded.
    @McpIgnore void append(string severity, string source, string message,
            string timestamp = "00:00:00")
    {
        auto entry = LogEntryData(_nextId.to!string, timestamp,
                toLower(severity), source, message);
        _nextId++;

        if (_buffer.length >= _capacity)
        {
            _buffer = _buffer[1 .. $] ~ entry;
        }
        else
        {
            _buffer ~= entry;
        }
        syncModel();
    }

    /// Clear all buffered log entries.
    void clear()
    {
        _buffer = [];
        _selectedIndex = -1;
        syncModel();
    }

    /// Subscribe this `RingBufferLogModel` to the central OpenTelemetry logger (`slog`).
    @McpIgnore void attachToCentralLogger()
    {
        import slate.log : OtelLogRecord, slog, uiLevelTag;

        slog.addSink("ui:" ~ mcpNamespace(), (OtelLogRecord rec) {
            string src = rec.codeFunction.length > 0 ? rec.codeFunction : rec.serviceName;
            this.append(uiLevelTag(rec.severity), src, rec.toCompactLine());
        });
    }

    /// Unsubscribe this `RingBufferLogModel` from `slog`.
    @McpIgnore void detachFromCentralLogger()
    {
        import slate.log : slog;

        slog.removeSink("ui:" ~ mcpNamespace());
    }

    /// Set the active severity filter ("all", "info", "warn", "error", "debug").
    void setSeverityFilter(string severity)
    {
        auto norm = toLower(severity);
        if (norm == "" || norm == "all")
            _severityFilter = "all";
        else
            _severityFilter = norm;
        _selectedIndex = -1;
        syncModel();
    }

    /// McpFilterable implementation.
    @McpWritable("search_query") @McpAction("set_filter")
    override void setFilterQuery(string query)
    {
        _searchQuery = query;
        _selectedIndex = -1;
        syncModel();
    }

    void setFilter(string query)
    {
        setFilterQuery(query);
    }

    @McpState("search_query")
    override string filterQuery() const @safe pure nothrow
    {
        return _searchQuery;
    }

    override ptrdiff_t selectedIndex() const @safe pure nothrow
    {
        return _selectedIndex;
    }

    override void selectIndex(size_t index)
    {
        auto vis = visibleEntries();
        if (index >= vis.length)
            throw AgentError.invalidParams("selected_index", "Index out of range");
        _selectedIndex = cast(ptrdiff_t) index;
    }

    void clearSelection() @safe pure nothrow
    {
        _selectedIndex = -1;
    }

    /// Return entries matching both severity filter and text query.
    @McpIgnore LogEntryData[] visibleEntries() const
    {
        LogEntryData[] result;
        auto qLower = toLower(_searchQuery);
        foreach (ref const entry; _buffer)
        {
            if (_severityFilter != "all" && entry.severity != _severityFilter)
                continue;
            if (qLower.length > 0)
            {
                if (!toLower(entry.message).canFind(qLower)
                        && !toLower(entry.source).canFind(qLower)
                        && !toLower(entry.severity).canFind(qLower))
                    continue;
            }
            result ~= LogEntryData(entry.id, entry.timestamp, entry.severity,
                    entry.source, entry.message);
        }
        return result;
    }
}

alias LogViewerController = RingBufferLogModel;

// Spec: Phase 3.8: RingBufferLogModel eviction, severity filtering, search filtering, and MCP state integration
/// Example:
unittest
{
    static assert(isMcpControllable!RingBufferLogModel);
    static assert(isFilterable!RingBufferLogModel);
    static assert(isMcpFilterable!RingBufferLogModel);

    auto logModel = new RingBufferLogModel("app-logs", 3);
    logModel.append("INFO", "auth", "User signed in", "10:00:01");
    logModel.append("WARN", "db", "Slow query detected", "10:00:02");
    logModel.append("ERROR", "api", "Timeout on /v1/orders", "10:00:03");
    assert(logModel.totalCount == 3);
    assert(logModel.model().rowCount() == 3);

    // Ring buffer capacity eviction
    logModel.append("INFO", "worker", "Job completed", "10:00:04");
    assert(logModel.totalCount == 3);
    auto vis = logModel.visibleEntries();
    assert(vis.length == 3);
    assert(vis[0].source == "db"); // "auth" was evicted

    // Severity filter
    logModel.setSeverityFilter("error");
    assert(logModel.visibleEntries().length == 1);
    assert(logModel.visibleEntries()[0].source == "api");
    assert(logModel.model().rowCount() == 1);

    // Search filter
    logModel.setSeverityFilter("all");
    logModel.setFilter("query");
    assert(logModel.visibleEntries().length == 1);
    assert(logModel.visibleEntries()[0].source == "db");

    auto st = logModel.mcpSnapshot();
    assert(st["visible_count"].uinteger == 1);
    assert(st["total_count"].uinteger == 3);
}

version (SlintNative) // Spec: Phase 3.8 (SlintNative): SlateLogViewer UI integration and severity filtering via SlintElementController
/// Example:
unittest
{
    import std.path : buildNormalizedPath, dirName;
    import slint.compiler : Compiler;
    import slint.instance : ComponentInstance;
    import slate.agent.slint_backend : SlintUiInspector, SlintElementController;

    immutable repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "..");
    immutable uiDir = buildNormalizedPath(repoRoot, "ui");

    enum slintSrc = `
import { SlateLogEntry, SlateLogViewer } from "components/log_viewer.slint";

export component TestLogsWindow inherits Window {
    width: 640px;
    height: 360px;
    in-out property <[SlateLogEntry]> entries: [
        { id: "1", timestamp: "10:00:01", severity: "info", source: "auth", message: "Login ok" },
        { id: "2", timestamp: "10:00:02", severity: "error", source: "db", message: "Connection failed" }
    ];
    in-out property <string> active-sev: "all";
    in-out property <string> active-query: "";

    SlateLogViewer {
        width: 100%;
        height: 100%;
        automation-id: "sys-logs";
        entries: root.entries;
        severity-filter <=> root.active-sev;
        search-query <=> root.active-query;
    }
}
`;

    auto compiler = new Compiler();
    compiler.includePaths = [
        uiDir, "../ui", "../../../ui", "ui", "../../ui", "../../../../ui"
    ];
    auto built = compiler.buildFromSource(slintSrc, "");
    import std.conv : text;

    auto def = built.component("TestLogsWindow");
    assert(def !is null, text("TestLogsWindow failed: ", built.diagnostics));
    auto inst = def.create();
    assert(inst !is null);

    import std.typecons : nullable;

    auto ctrl = new SlintElementController(inst);

    ctrl.clickElement("#sys-logs-sev-error");
    assert(inst.getString("active-sev") == "error");

    ctrl.sendKeys(nullable("#sys-logs-search"), "Connection");
    assert(inst.getString("active-query") == "Connection");
}
