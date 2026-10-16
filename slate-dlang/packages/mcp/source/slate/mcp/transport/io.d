/// Line-framing pump and endpoint seams shared by all MCP transports.
///
/// `runLineTransport` reads line-delimited JSON-RPC, dispatches through
/// `McpServer.handleLine`, and writes newline-terminated responses with an
/// immediate flush — the synchronous equivalent of Rust's
/// `run_line_transport` (whose writer task, per-line spawn, and broadcast
/// shutdown exist to serve concurrent clients; sequential sessions observe
/// the same bytes).
module slate.mcp.transport.io;

import slate.mcp.server : McpServer;

/// Blocking line source; null marks clean EOF.
interface LineReader
{
    /// Next line without its terminator, or null at EOF. Throws on I/O error.
    string readLine();
}

/// Blocking line sink with immediate flush per line.
interface LineWriter
{
    void writeLine(string line);
    void flush();
}

/// Transport framing/I/O failures.
class McpTransportError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(msg, file, line);
    }

    static McpTransportError channelClosed() @safe pure
    {
        return new McpTransportError("Transport write channel closed prematurely");
    }

    static McpTransportError io(string message) @safe pure
    {
        return new McpTransportError("I/O transport error: " ~ message);
    }

    static McpTransportError internal_(string message) @safe pure
    {
        return new McpTransportError("Server internal error: " ~ message);
    }
}

/// Pump lines until EOF; returns when the peer closes cleanly.
void runLineTransport(McpServer server, LineReader reader, LineWriter writer)
{
    import std.string : strip;

    for (;;)
    {
        string line;
        try
            line = reader.readLine();
        catch (McpTransportError e)
        {
            throw e;
        }
        catch (Throwable t)
        {
            throw McpTransportError.io(t.msg);
        }
        if (line is null)
            return; // EOF: clean session end
        auto trimmed = line.strip();
        if (trimmed.length == 0)
            continue; // blank lines / keep-alive pulses
        string response = server.handleLine(trimmed);
        if (response is null)
            continue; // notification: no reply
        try
        {
            writer.writeLine(response);
            writer.flush();
        }
        catch (Throwable t)
        {
            throw McpTransportError.io(t.msg);
        }
    }
}

///
unittest
{
    import slate.agent.engine : DefaultAutomationEngine, DefaultElementController,
        DefaultStateProvider, DefaultUiInspector, DefaultVisualRenderer;
    import slate.mcp.server : McpServer;

    static class Script : LineReader, LineWriter
    {
        string[] input;
        string[] output;
        bool failWrite;
        string readLine()
        {
            if (input.length == 0)
                return null;
            auto line = input[0];
            input = input[1 .. $];
            return line;
        }

        void writeLine(string line)
        {
            if (failWrite)
                throw new Exception("sink broken");
            output ~= line;
        }

        void flush()
        {
        }
    }

    auto engine = new DefaultAutomationEngine(new DefaultUiInspector(),
            new DefaultElementController(), new DefaultStateProvider(), new DefaultVisualRenderer());
    auto server = new McpServer(engine);

    // Ping round-trips; blanks are skipped; notifications are silent.
    auto io = new Script();
    io.input = [
        "", `{"jsonrpc":"2.0","id":1,"method":"ping"}`,
        `{"jsonrpc":"2.0","method":"notifications/initialized"}`, "   "
    ];
    runLineTransport(server, io, io);
    assert(io.output.length == 1);
    import std.json : parseJSON;

    assert(parseJSON(io.output[0])["result"] == parseJSON(`{}`));
    assert(server.isInitialized());

    // Writer failures surface as transport errors.
    auto bad = new Script();
    bad.input = [`{"jsonrpc":"2.0","id":1,"method":"ping"}`];
    bad.failWrite = true;
    import std.exception : assertThrown;

    assertThrown!McpTransportError(runLineTransport(server, bad, bad));
}
