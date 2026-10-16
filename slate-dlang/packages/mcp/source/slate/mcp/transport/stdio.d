/// stdio transport: MCP over stdin/stdout with stderr-only logging.
///
/// Port of `slate_mcp::transport::stdio`. The worker thread owns the
/// blocking pump; logs must never touch stdout (framing invariant), hence
/// `ensureStderrLogging`. `runStdio` blocks the caller instead of spawning.
module slate.mcp.transport.stdio;

import core.thread : Thread;

import slate.mcp.server : McpServer;
import slate.mcp.transport.io : LineReader, LineWriter, McpTransportError, runLineTransport;

private __gshared bool _stderrLogging;

private final class StdioLines : LineReader, LineWriter
{
    import std.stdio : stdin, stdout;
    import core.atomic : atomicLoad;

    private shared(bool)* _open;

    this(shared(bool)* openFlag = null)
    {
        _open = openFlag;
    }

    string readLine()
    {
        import std.string : chomp;

        if (_open !is null && !atomicLoad(*_open))
            return null;

        auto line = stdin.readln();
        if (line is null)
            return null;

        if (_open !is null && !atomicLoad(*_open))
            return null;

        return line.chomp();
    }

    void writeLine(string line)
    {
        import core.atomic : atomicLoad;

        if (_open !is null && !atomicLoad(*_open))
            throw McpTransportError.channelClosed();

        stdout.writeln(line);
    }

    void flush()
    {
        stdout.flush();
    }
}

/// Direct stderr logging for transports (stdout carries framing).
/// Idempotent; safe to call from every transport entry point.
void ensureStderrLogging()
{
    synchronized (StdioLines.classinfo)
    {
        if (!_stderrLogging)
        {
            import std.logger : FileLogger, LogLevel, sharedLog;
            import std.stdio : stderr;

            sharedLog(cast(shared) new FileLogger(stderr, LogLevel.all));
            _stderrLogging = true;
        }
    }
}

/// Lifecycle handle for a spawned stdio session.
final class StdioTransportHandle
{
    private Thread _thread;
    private shared bool _open = true;

    this()
    {
    }

    this(Thread thread)
    {
        _thread = thread;
    }

    package void setThread(Thread thread)
    {
        _thread = thread;
    }

    package shared(bool)* openFlag() return
    {
        return &_open;
    }

    bool isRunning()
    {
        import core.atomic : atomicLoad;

        return atomicLoad(_open) && (_thread !is null && _thread.isRunning);
    }

    void stop()
    {
        import core.atomic : atomicStore;

        atomicStore(_open, false);
        // stdin EOF is the peer's business; joining avoids a stray thread.
        // A blocked readln cannot be interrupted portably, so stop() only
        // joins threads that already finished (never blocks the caller).
        if (_thread !is null && !_thread.isRunning)
            _thread.join();
    }
}

/// Block the calling thread serving MCP on stdin/stdout.
void runStdio(McpServer server)
{
    ensureStderrLogging();
    auto io = new StdioLines();
    runLineTransport(server, io, io);
}

/// Serve MCP on stdin/stdout in a background thread.
StdioTransportHandle spawnStdioTransport(McpServer server)
{
    ensureStderrLogging();
    auto handle = new StdioTransportHandle();
    auto openFlag = handle.openFlag();

    auto thread = new Thread({
        try
        {
            auto io = new StdioLines(openFlag);
            runLineTransport(server, io, io);
        }
        catch (Exception e)
        {
            import std.stdio : stderr;

            try
            {
                stderr.writefln("MCP stdio transport error: %s", e.msg);
            }
            catch (Throwable)
            {
            }
        }
    });
    thread.isDaemon = true;
    handle.setThread(thread);
    thread.start();
    return handle;
}

unittest
{
    import std.exception : assertThrown;

    shared bool stopped = false;
    auto io = new StdioLines(&stopped);
    assert(io.readLine() is null);
    assertThrown!McpTransportError(io.writeLine("test"));
}
