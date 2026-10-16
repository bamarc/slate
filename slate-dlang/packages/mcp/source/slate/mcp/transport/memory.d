/// In-memory transport: MCP over a Unix socket pair.
///
/// Port of `slate_mcp::transport::in_memory`. Rust uses tokio's
/// `DuplexStream`; the canonical D equivalent is a `std.socket.socketPair`
/// (blocking, full-duplex, no network). One end serves the pump in a worker
/// thread; the other is the client's session handle.
module slate.mcp.transport.memory;

import core.thread : Thread;
import std.socket : Socket;

import slate.mcp.server : McpServer;
import slate.mcp.transport.io : LineReader, LineWriter, McpTransportError, runLineTransport;

/// Blocking line framing over one end of a socket pair.
final class SocketLines : LineReader, LineWriter
{
    private Socket _socket;
    private ubyte[] _pending;
    private shared bool _closed;

    this(Socket socket)
    in
    {
        assert(socket !is null, "Socket must not be null");
    }
    do
    {
        _socket = socket;
    }

    string readLine()
    {
        import core.atomic : atomicLoad;
        import std.algorithm : countUntil;

        for (;;)
        {
            if (atomicLoad(_closed))
                return null;

            auto nl = _pending.countUntil('\n');
            if (nl >= 0)
            {
                auto line = cast(string) _pending[0 .. nl].dup;
                _pending = _pending[nl + 1 .. $];
                return line;
            }

            auto s = _socket;
            if (s is null || atomicLoad(_closed))
                return null;

            ubyte[4096] buf;
            auto got = s.receive(buf[]);
            if (got == 0)
                return null; // clean EOF
            if (got == Socket.ERROR)
            {
                if (atomicLoad(_closed))
                    return null;
                throw McpTransportError.io("socket receive failed");
            }
            _pending ~= buf[0 .. got];
        }
    }

    void writeLine(string line)
    {
        import core.atomic : atomicLoad;

        if (atomicLoad(_closed))
            throw McpTransportError.channelClosed();

        auto s = _socket;
        if (s is null)
            throw McpTransportError.channelClosed();

        auto payload = cast(const ubyte[])(line ~ "\n");
        size_t sent;
        while (sent < payload.length)
        {
            if (atomicLoad(_closed))
                throw McpTransportError.channelClosed();
            try
            {
                auto n = s.send(payload[sent .. $]);
                if (n == Socket.ERROR || n == 0)
                    throw McpTransportError.channelClosed();
                sent += n;
            }
            catch (McpTransportError e)
            {
                throw e;
            }
            catch (Throwable)
            {
                throw McpTransportError.channelClosed();
            }
        }
    }

    void flush()
    {
    }

    void close()
    {
        import core.atomic : cas;

        if (!cas(&_closed, false, true))
            return;

        auto s = _socket;
        _socket = null;
        if (s !is null)
            safeCloseSocket(s);
    }
}

import std.socket : SocketShutdown;

private void safeCloseSocket(Socket s) nothrow
{
    if (s !is null)
    {
        try
        {
            s.shutdown(SocketShutdown.BOTH);
        }
        catch (Throwable)
        {
        }
        try
        {
            s.close();
        }
        catch (Throwable)
        {
        }
    }
}

/// Lifecycle handle for an in-memory session's server side.
final class InMemoryTransportHandle
{
    private Thread _thread;
    private SocketLines _lines;

    this(Thread thread, SocketLines lines)
    in
    {
        assert(thread !is null, "Thread must not be null");
        assert(lines !is null, "SocketLines must not be null");
    }
    do
    {
        _thread = thread;
        _lines = lines;
    }

    bool isRunning()
    {
        return _thread.isRunning;
    }

    void stop()
    {
        scope (exit)
            _thread.join();
        _lines.close();
    }
}

/// Connected pair: server end (pump) and client end (session).
struct InMemorySession
{
    Socket server;
    Socket client;

    void close()
    {
        auto c = client;
        auto s = server;
        client = null;
        server = null;
        scope (exit)
            safeCloseSocket(c);
        safeCloseSocket(s);
    }
}

/// Create a connected socket pair for a test or embedded session.
InMemorySession createInMemorySession()
{
    import std.socket : socketPair;

    auto pair = socketPair();
    return InMemorySession(pair[0], pair[1]);
}

/// Serve `server` on `socket` in a background thread.
InMemoryTransportHandle spawnInMemoryTransport(McpServer server, Socket socket)
in
{
    assert(server !is null, "McpServer must not be null");
    assert(socket !is null, "Socket must not be null");
}
out (handle)
{
    assert(handle !is null, "Transport handle must not be null");
}
do
{
    auto lines = new SocketLines(socket);
    auto thread = new Thread({
        scope (exit)
            lines.close();
        try
            runLineTransport(server, lines, lines);
        catch (Throwable)
        {
        }
    });
    thread.isDaemon = true;
    thread.start();
    return new InMemoryTransportHandle(thread, lines);
}

///
unittest
{
    import slate.agent.engine : DefaultAutomationEngine, DefaultElementController,
        DefaultStateProvider, DefaultUiInspector, DefaultVisualRenderer;
    import slate.mcp.server : McpServer;
    import std.json : parseJSON;

    auto engine = new DefaultAutomationEngine(new DefaultUiInspector(),
            new DefaultElementController(), new DefaultStateProvider(), new DefaultVisualRenderer());
    auto session = createInMemorySession();
    auto handle = spawnInMemoryTransport(new McpServer(engine), session.server);
    assert(handle.isRunning());

    auto client = new SocketLines(session.client);
    client.writeLine(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`);
    auto reply = client.readLine();
    assert(reply !is null);
    assert(parseJSON(reply)["result"]["tools"].array.length == 5);

    client.writeLine(`{"jsonrpc":"2.0","id":2,"method":"tools/call",`
            ~ `"params":{"name":"get_state","arguments":{}}}`);
    assert(parseJSON(client.readLine())["result"]["content"][0]["text"].get!string.canFind(
            "active_view"));

    handle.stop();
    assert(!handle.isRunning());
    client.close();
    session.close();

    // Verification of scope(exit) cleanup guarantee on clean exit and thrown exceptions
    auto testSession = createInMemorySession();
    auto testLines = new SocketLines(testSession.server);
    bool exitExecutedClean = false;
    () {
        scope (exit)
        {
            testLines.close();
            exitExecutedClean = true;
        }
    }();
    assert(exitExecutedClean);
    assert(testLines.readLine() is null); // closed socket returns EOF

    auto errSession = createInMemorySession();
    auto errLines = new SocketLines(errSession.server);
    bool exitExecutedOnThrow = false;
    try
    {
        () {
            scope (exit)
            {
                errLines.close();
                exitExecutedOnThrow = true;
            }
            throw new Exception("simulated transport error");
        }();
        assert(false);
    }
    catch (Exception)
    {
    }
    assert(exitExecutedOnThrow);
    assert(errLines.readLine() is null); // closed socket returns EOF

    import std.exception : assertThrown;

    assertThrown!McpTransportError(errLines.writeLine("ping"));
    errSession.close();
    errSession.close(); // double close is idempotent and safe

    // Contract verification
    import core.exception : AssertError;

    assertThrown!AssertError(new SocketLines(null));
    assertThrown!AssertError(spawnInMemoryTransport(null, null));
}

import std.algorithm : canFind;
