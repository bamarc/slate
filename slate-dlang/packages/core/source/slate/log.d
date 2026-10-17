/// OpenTelemetry-style central structured logger and RAII trace/span context.
///
/// Features:
/// - **Ultra-easy `slog` facade**: `slog.info("msg", "key", value, ...)` with
///   automatic caller metadata (`code.function`, `code.filepath`, `code.lineno`).
/// - **RAII Scoped Spans**: `auto _s = slog.span("op_name", "k", v);` automatically
///   generates W3C TraceContext `trace_id` (32-hex) and `span_id` (16-hex),
///   propagates them to all nested logs on the thread, and emits span duration on scope exit.
/// - **Multi-sink fan-out**: Bridges `std.logger` (`infof`, `warningf`, `errorf`)
///   and fans out every `OtelLogRecord` to `stderr`, MCP `BoundedLog` (`slate://logs/live`),
///   and UI `RingBufferLogModel` (`SlateLogViewer`).
module slate.log;

import core.sync.mutex : Mutex;
import core.time : MonoTime, Duration;
import std.conv : to;
import std.datetime.systime : Clock;
import std.json : JSONValue;
import std.logger : Logger, LogLevel;

/// OpenTelemetry severity numbers (1..24).
enum OtelSeverity : int
{
    trace = 1,
    debug_ = 5,
    info = 9,
    warn = 13,
    error = 17,
    fatal = 21
}

/// Convert `OtelSeverity` to its canonical OpenTelemetry `SeverityText`.
string severityText(OtelSeverity sev) @safe pure nothrow @nogc
{
    final switch (sev)
    {
    case OtelSeverity.trace:
        return "TRACE";
    case OtelSeverity.debug_:
        return "DEBUG";
    case OtelSeverity.info:
        return "INFO";
    case OtelSeverity.warn:
        return "WARN";
    case OtelSeverity.error:
        return "ERROR";
    case OtelSeverity.fatal:
        return "FATAL";
    }
}

/// Map `OtelSeverity` to `SlateLogViewer`'s lowercase level filter (`"info"`, `"warn"`, `"error"`, `"debug"`).
string uiLevelTag(OtelSeverity sev) @safe pure nothrow @nogc
{
    final switch (sev)
    {
    case OtelSeverity.trace:
    case OtelSeverity.debug_:
        return "debug";
    case OtelSeverity.info:
        return "info";
    case OtelSeverity.warn:
        return "warn";
    case OtelSeverity.error:
    case OtelSeverity.fatal:
        return "error";
    }
}

/// OpenTelemetry Log Data Model record.
struct OtelLogRecord
{
    long timestampUnixMs;
    OtelSeverity severity = OtelSeverity.info;
    string body_;
    string traceId;
    string spanId;
    string parentSpanId;
    string serviceName = "slate";
    string serviceVersion = "0.1.0";
    string codeFunction;
    string codeFilepath;
    size_t codeLineno;
    JSONValue[string] attributes;

    /// Serialize to a single-line OpenTelemetry JSON record.
    JSONValue toOtelJson() const @safe
    {
        JSONValue[string] root;
        root["timestamp_unix_ms"] = JSONValue(timestampUnixMs);
        root["severity_number"] = JSONValue(cast(int) severity);
        root["severity_text"] = JSONValue(severityText(severity));
        root["body"] = JSONValue(body_);
        if (traceId.length > 0)
            root["trace_id"] = JSONValue(traceId);
        if (spanId.length > 0)
            root["span_id"] = JSONValue(spanId);
        if (parentSpanId.length > 0)
            root["parent_span_id"] = JSONValue(parentSpanId);

        JSONValue[string] res;
        res["service.name"] = JSONValue(serviceName);
        res["service.version"] = JSONValue(serviceVersion);
        root["resource"] = JSONValue(res);

        JSONValue[string] attrs;
        foreach (k, v; attributes)
            attrs[k] = v;
        if (codeFunction.length > 0)
            attrs["code.function"] = JSONValue(codeFunction);
        if (codeFilepath.length > 0)
            attrs["code.filepath"] = JSONValue(codeFilepath);
        if (codeLineno > 0)
            attrs["code.lineno"] = JSONValue(cast(long) codeLineno);
        root["attributes"] = JSONValue(attrs);

        return JSONValue(root);
    }

    string toOtelJsonLine() const @safe
    {
        return toOtelJson().toString();
    }

    /// Format as a compact, human- and agent-readable structured log line.
    string toCompactLine() const @safe
    {
        import std.algorithm : sort;
        import std.array : appender;
        import std.format : formattedWrite;

        auto buf = appender!string();
        formattedWrite(buf, "[%s] [%s]", severityText(severity), serviceName);
        if (traceId.length >= 8 && spanId.length >= 8)
            formattedWrite(buf, " [trace=%s span=%s]", traceId[0 .. 8], spanId[0 .. 8]);
        if (codeFunction.length > 0)
            formattedWrite(buf, " (%s)", codeFunction);
        formattedWrite(buf, " %s", body_);

        string[] keys = attributes.keys;
        keys.sort();
        foreach (k; keys)
        {
            auto v = attributes[k];
            formattedWrite(buf, " %s=%s", k, v.toString());
        }
        return buf.data;
    }
}

/// Sink callback receiving every emitted `OtelLogRecord`.
alias OtelLogSink = void delegate(OtelLogRecord record);

private struct SpanFrame
{
    string traceId;
    string spanId;
    string parentSpanId;
    string name;
}

/// Thread-local active span stack for zero-argument context propagation.
private SpanFrame[] _activeSpanStack;

/// Generate a random hex string of `numBytes * 2` characters.
string generateHexId(size_t numBytes) @trusted nothrow
{
    import std.random : Mt19937, unpredictableSeed;

    try
    {
        static Mt19937 rng;
        static bool seeded;
        if (!seeded)
        {
            rng.seed(unpredictableSeed);
            seeded = true;
        }

        immutable char[16] hexDigits = "0123456789abcdef";
        char[] outBuf = new char[](numBytes * 2);
        foreach (i; 0 .. numBytes)
        {
            ubyte b = cast(ubyte)(rng.front & 0xFF);
            rng.popFront();
            outBuf[i * 2] = hexDigits[(b >> 4) & 0x0F];
            outBuf[i * 2 + 1] = hexDigits[b & 0x0F];
        }
        return cast(immutable) outBuf;
    }
    catch (Throwable)
    {
        return "0000000000000000";
    }
}

/// RAII OpenTelemetry span guard. Automatically starts a span on construction
/// and logs its duration in microseconds when leaving scope.
struct OtelSpanGuard
{
    private string _name;
    private string _traceId;
    private string _spanId;
    private string _parentSpanId;
    private string _func;
    private string _file;
    private size_t _line;
    private MonoTime _start;
    private JSONValue[string] _initialAttrs;
    private bool _active;

    @disable this(this);

    this(string name, JSONValue[string] attrs, string func, string file, size_t line) @trusted nothrow
    {
        _name = name;
        _func = func;
        _file = file;
        _line = line;
        _start = MonoTime.currTime;
        _initialAttrs = attrs;
        _active = true;

        if (_activeSpanStack.length > 0)
        {
            _traceId = _activeSpanStack[$ - 1].traceId;
            _parentSpanId = _activeSpanStack[$ - 1].spanId;
        }
        else
        {
            _traceId = generateHexId(16); // 128-bit W3C trace_id (32 hex chars)
            _parentSpanId = "";
        }
        _spanId = generateHexId(8); // 64-bit W3C span_id (16 hex chars)

        _activeSpanStack ~= SpanFrame(_traceId, _spanId, _parentSpanId, _name);
    }

    /// Add or update an attribute on the active span before it closes.
    void setAttribute(T)(string key, T value) @trusted nothrow
    {
        try
        {
            _initialAttrs[key] = toJsonAttr(value);
        }
        catch (Throwable)
        {
        }
    }

    string traceId() const @safe pure nothrow @nogc
    {
        return _traceId;
    }

    string spanId() const @safe pure nothrow @nogc
    {
        return _spanId;
    }

    ~this() @trusted nothrow
    {
        if (!_active)
            return;
        _active = false;

        try
        {
            Duration elapsed = MonoTime.currTime - _start;
            long durationUs = elapsed.total!"usecs";

            JSONValue[string] endAttrs;
            foreach (k, v; _initialAttrs)
                endAttrs[k] = v;
            endAttrs["span.name"] = JSONValue(_name);
            endAttrs["span.kind"] = JSONValue("internal");
            endAttrs["duration_us"] = JSONValue(durationUs);

            // Pop from thread-local stack after emitting span completion record
            slog.emitRecord(OtelSeverity.debug_, "span.end: " ~ _name, endAttrs,
                    _func, _file, _line);
        }
        catch (Throwable)
        {
        }

        if (_activeSpanStack.length > 0)
            _activeSpanStack = _activeSpanStack[0 .. $ - 1];
    }
}

private JSONValue toJsonAttr(T)(T val) @trusted
{
    static if (is(T : JSONValue))
        return val;
    else static if (is(T == bool))
        return JSONValue(val);
    else static if (is(T : long))
        return JSONValue(cast(long) val);
    else static if (is(T : double))
        return JSONValue(cast(double) val);
    else static if (is(T : const(char)[]))
        return JSONValue(val.idup);
    else
        return JSONValue(val.to!string);
}

/// Convert variadic `(key1, val1, key2, val2, ...)` arguments into `JSONValue[string]`.
JSONValue[string] buildOtelAttributes(Args...)(auto ref Args args) @trusted
{
    JSONValue[string] attrs;
    static assert(Args.length % 2 == 0,
            "slog key-value arguments must be passed in (string key, value) pairs");
    static foreach (int i; 0 .. Args.length / 2)
    {
        static assert(is(typeof(args[i * 2]) : const(char)[]),
                "slog attribute key at index " ~ (i * 2).stringof ~ " must be a string");
        attrs[args[i * 2].idup] = toJsonAttr(args[i * 2 + 1]);
    }
    return attrs;
}

/// Central thread-safe OpenTelemetry logger hub.
final class SlateCentralLogger
{
    private Mutex _mtx;
    private string _serviceName = "slate";
    private string _serviceVersion = "0.1.0";
    private OtelSeverity _minSeverity = OtelSeverity.info;
    private bool _stderrEnabled = false;
    private bool _jsonStderr = false;
    private OtelLogSink[string] _sinks;
    private OtelLogRecord[] _history;
    private size_t _maxHistory = 500;

    this() @trusted nothrow
    {
        try
        {
            _mtx = new Mutex();
        }
        catch (Throwable)
        {
        }
    }

    void configure(string serviceName, string serviceVersion = "0.1.0",
            OtelSeverity minSeverity = OtelSeverity.info,
            bool stderrEnabled = false, bool jsonStderr = false) @trusted nothrow
    {
        _mtx.lock_nothrow();
        scope (exit)
            _mtx.unlock_nothrow();

        if (serviceName.length > 0)
            _serviceName = serviceName;
        if (serviceVersion.length > 0)
            _serviceVersion = serviceVersion;
        _minSeverity = minSeverity;
        _stderrEnabled = stderrEnabled;
        _jsonStderr = jsonStderr;
    }

    void setMinSeverity(OtelSeverity minSeverity) @trusted nothrow
    {
        _mtx.lock_nothrow();
        scope (exit)
            _mtx.unlock_nothrow();

        _minSeverity = minSeverity;
    }

    void setStderrEnabled(bool enabled, bool jsonFormat = false) @trusted nothrow
    {
        _mtx.lock_nothrow();
        scope (exit)
            _mtx.unlock_nothrow();

        _stderrEnabled = enabled;
        _jsonStderr = jsonFormat;
    }

    /// Register a named sink (e.g. `"mcp"`, `"ui_log_viewer"`).
    void addSink(string id, OtelLogSink sink) @trusted nothrow
    {
        _mtx.lock_nothrow();
        scope (exit)
            _mtx.unlock_nothrow();

        if (sink !is null)
            _sinks[id] = sink;
    }

    /// Unregister a named sink.
    void removeSink(string id) @trusted nothrow
    {
        _mtx.lock_nothrow();
        scope (exit)
            _mtx.unlock_nothrow();

        _sinks.remove(id);
    }

    /// Clear all sinks and history (useful in isolated tests).
    void resetForTest() @trusted nothrow
    {
        _mtx.lock_nothrow();
        scope (exit)
            _mtx.unlock_nothrow();

        _sinks.clear();
        _history = null;
        _minSeverity = OtelSeverity.trace;
        _stderrEnabled = false;
    }

    /// Snapshot recent structured records.
    OtelLogRecord[] recentRecords() @trusted nothrow
    {
        _mtx.lock_nothrow();
        scope (exit)
            _mtx.unlock_nothrow();

        return _history.dup;
    }

    /// Emit a structured OpenTelemetry record across all registered sinks.
    void emitRecord(OtelSeverity severity, string message, JSONValue[string] attrs,
            string func = __FUNCTION__, string file = __FILE__, size_t line = __LINE__) @trusted nothrow
    {
        try
        {
            OtelLogRecord rec;
            rec.timestampUnixMs = Clock.currTime().toUnixTime!long() * 1000;
            rec.severity = severity;
            rec.body_ = message;
            rec.codeFunction = func;
            rec.codeFilepath = file;
            rec.codeLineno = line;
            rec.attributes = attrs;

            if (_activeSpanStack.length > 0)
            {
                rec.traceId = _activeSpanStack[$ - 1].traceId;
                rec.spanId = _activeSpanStack[$ - 1].spanId;
                rec.parentSpanId = _activeSpanStack[$ - 1].parentSpanId;
            }

            OtelLogSink[] activeSinks;
            bool writeErr;
            bool writeJson;

            {
                _mtx.lock_nothrow();
                scope (exit)
                    _mtx.unlock_nothrow();

                if (cast(int) severity < cast(int) _minSeverity)
                    return;

                rec.serviceName = _serviceName;
                rec.serviceVersion = _serviceVersion;

                _history ~= rec;
                if (_history.length > _maxHistory)
                    _history = _history[$ - _maxHistory .. $];

                activeSinks = _sinks.values.dup;
                writeErr = _stderrEnabled;
                writeJson = _jsonStderr;
            }

            if (writeErr)
            {
                import std.stdio : stderr;

                stderr.writeln(writeJson ? rec.toOtelJsonLine() : rec.toCompactLine());
                stderr.flush();
            }

            foreach (sink; activeSinks)
            {
                if (sink !is null)
                {
                    try
                        sink(rec);
                    catch (Throwable)
                    {
                    }
                }
            }
        }
        catch (Throwable)
        {
        }
    }

    // -- Ultra-easy variadic logging methods ---------------------------------

    void trace(string func = __FUNCTION__, string file = __FILE__, size_t line = __LINE__, Args...)(
            string msg, auto ref Args args) @trusted nothrow
    {
        try
            emitRecord(OtelSeverity.trace, msg, buildOtelAttributes(args), func, file, line);
        catch (Throwable)
        {
        }
    }

    void debug_(string func = __FUNCTION__, string file = __FILE__, size_t line = __LINE__,
            Args...)(string msg, auto ref Args args) @trusted nothrow
    {
        try
            emitRecord(OtelSeverity.debug_, msg, buildOtelAttributes(args), func, file, line);
        catch (Throwable)
        {
        }
    }

    void info(string func = __FUNCTION__, string file = __FILE__, size_t line = __LINE__, Args...)(
            string msg, auto ref Args args) @trusted nothrow
    {
        try
            emitRecord(OtelSeverity.info, msg, buildOtelAttributes(args), func, file, line);
        catch (Throwable)
        {
        }
    }

    void warn(string func = __FUNCTION__, string file = __FILE__, size_t line = __LINE__, Args...)(
            string msg, auto ref Args args) @trusted nothrow
    {
        try
            emitRecord(OtelSeverity.warn, msg, buildOtelAttributes(args), func, file, line);
        catch (Throwable)
        {
        }
    }

    void error(string func = __FUNCTION__, string file = __FILE__, size_t line = __LINE__, Args...)(
            string msg, auto ref Args args) @trusted nothrow
    {
        try
            emitRecord(OtelSeverity.error, msg, buildOtelAttributes(args), func, file, line);
        catch (Throwable)
        {
        }
    }

    void fatal(string func = __FUNCTION__, string file = __FILE__, size_t line = __LINE__, Args...)(
            string msg, auto ref Args args) @trusted nothrow
    {
        try
            emitRecord(OtelSeverity.fatal, msg, buildOtelAttributes(args), func, file, line);
        catch (Throwable)
        {
        }
    }

    /// Start an RAII OpenTelemetry span that automatically tags all logs in the current scope.
    OtelSpanGuard span(string func = __FUNCTION__, string file = __FILE__,
            size_t line = __LINE__, Args...)(string name, auto ref Args args) @trusted nothrow
    {
        JSONValue[string] attrs;
        try
            attrs = buildOtelAttributes(args);
        catch (Throwable)
        {
        }
        return OtelSpanGuard(name, attrs, func, file, line);
    }
}

/// Global singleton backing `slog`.
private __gshared SlateCentralLogger _globalSlog;

shared static this()
{
    _globalSlog = new SlateCentralLogger();
}

/// Global OpenTelemetry logger accessor (`slog.info(...)`, `slog.span(...)`).
SlateCentralLogger slog() @trusted nothrow
{
    if (_globalSlog is null)
        _globalSlog = new SlateCentralLogger();
    return _globalSlog;
}

/// Bridge `std.logger` (`infof`, `warningf`, `errorf`) into `slog`.
final class StdLoggerOtelBridge : Logger
{
    this(LogLevel lv = LogLevel.info) @safe
    {
        super(lv);
    }

    override protected void writeLogMsg(ref LogEntry payload) @trusted
    {
        OtelSeverity sev = OtelSeverity.info;
        switch (payload.logLevel)
        {
        case LogLevel.trace:
            sev = OtelSeverity.trace;
            break;
        case LogLevel.info:
            sev = OtelSeverity.info;
            break;
        case LogLevel.warning:
            sev = OtelSeverity.warn;
            break;
        case LogLevel.error:
            sev = OtelSeverity.error;
            break;
        case LogLevel.critical:
        case LogLevel.fatal:
            sev = OtelSeverity.fatal;
            break;
        default:
            sev = OtelSeverity.debug_;
            break;
        }
        JSONValue[string] emptyAttrs;
        slog.emitRecord(sev, payload.msg, emptyAttrs, payload.funcName,
                payload.file, payload.line);
    }
}

/// Install `StdLoggerOtelBridge` as `std.logger.sharedLog` so all standard D logs route through `slog`.
void installOtelStdLoggerBridge(string serviceName = "slate",
        OtelSeverity minSeverity = OtelSeverity.info, bool stderrEnabled = true,
        bool jsonStderr = false) @trusted nothrow
{
    import std.logger : sharedLog;

    try
    {
        slog.configure(serviceName, "0.1.0", minSeverity, stderrEnabled, jsonStderr);
        sharedLog(cast(shared) new StdLoggerOtelBridge(LogLevel.all));
    }
    catch (Throwable)
    {
    }
}

// Spec: slog emits OpenTelemetry-structured records with variadic key-value attributes,
// propagates trace_id/span_id across nested RAII spans, and fans out to sinks.
/// Example:
unittest
{
    import std.algorithm : canFind;
    import std.json : parseJSON;

    slog.resetForTest();

    OtelLogRecord[] captured;
    slog.addSink("test_sink", (OtelLogRecord r) { captured ~= r; });
    scope (exit)
        slog.removeSink("test_sink");

    // 1. Key-value structured log outside a span
    slog.info("Server starting", "port", 8080, "tls", true);
    assert(captured.length == 1);
    assert(captured[0].severity == OtelSeverity.info);
    assert(captured[0].body_ == "Server starting");
    assert(captured[0].attributes["port"].integer == 8080);
    assert(captured[0].attributes["tls"].boolean == true);
    assert(captured[0].traceId.length == 0);
    assert(captured[0].codeFunction.canFind("unittest"));

    // 2. Scoped RAII span + nested child span propagation
    string outerTraceId;
    string outerSpanId;
    {
        auto rootSpan = slog.span("http.request", "method", "GET", "path", "/items");
        outerTraceId = rootSpan.traceId;
        outerSpanId = rootSpan.spanId;
        assert(outerTraceId.length == 32);
        assert(outerSpanId.length == 16);

        slog.info("Authenticating user", "user_id", "u-42");
        assert(captured[$ - 1].traceId == outerTraceId);
        assert(captured[$ - 1].spanId == outerSpanId);

        {
            auto childSpan = slog.span("db.query", "table", "items");
            assert(childSpan.traceId == outerTraceId);
            assert(childSpan.spanId != outerSpanId);

            slog.warn("Slow query", "rows", 1200);
            assert(captured[$ - 1].traceId == outerTraceId);
            assert(captured[$ - 1].spanId == childSpan.spanId);
            assert(captured[$ - 1].parentSpanId == outerSpanId);
        }
        // Child span exit emitted a span.end debug record with duration_us
        assert(captured[$ - 1].body_ == "span.end: db.query");
        assert("duration_us" in captured[$ - 1].attributes);
    }
    // Outer span exit emitted span.end: http.request
    assert(captured[$ - 1].body_ == "span.end: http.request");

    // 3. OTel JSON serialization check
    auto json = parseJSON(captured[1].toOtelJsonLine());
    assert(json["trace_id"].str == outerTraceId);
    assert(json["span_id"].str == outerSpanId);
    assert(json["severity_text"].str == "INFO");
    assert(json["attributes"]["user_id"].str == "u-42");
}
