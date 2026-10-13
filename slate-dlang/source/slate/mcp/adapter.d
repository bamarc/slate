/// MCP adapter: engine ↔ protocol attachment plus builder integration.
///
/// Port of `slate_mcp::adapter`: `McpTransportMode` (stdio or an owned
/// socket for the in-memory session), `McpAdapterConfig`, the `McpAdapter`
/// itself, the `McpServerHandle` union, and builder helpers. Rust expresses
/// the helpers as an extension trait on the generic `AgentBuilder<T>`; D
/// uses free functions taking the builder (same call shape through UFCS).
module slate.mcp.adapter;

import std.socket : Socket;

import slate.agent.builder : AgentBuilder;
import slate.agent.engine : AutomationEngine;
import slate.agent.error : AgentError;
import slate.agent.protocol : AgentProtocolAdapter, ProtocolServerHandle;
import slate.mcp.server : McpServer;
import slate.mcp.transport : InMemoryTransportHandle, StdioTransportHandle,
    spawnInMemoryTransport, spawnStdioTransport;
import std.typecons : Nullable;

/// Transport selection for `McpAdapter`.
struct McpTransportMode
{
    enum Kind
    {
        stdio,
        inMemory
    }

    Kind kind = Kind.stdio;
    Socket socket;

    static McpTransportMode stdio() @safe pure nothrow
    {
        return McpTransportMode(Kind.stdio);
    }

    static McpTransportMode inMemory(Socket socket) @safe pure nothrow
    {
        return McpTransportMode(Kind.inMemory, socket);
    }
}

/// Adapter configuration: mode plus server identity.
struct McpAdapterConfig
{
    McpTransportMode mode;
    string serverName = "slate-mcp";
    string serverVersion = "0.1.0";

    static McpAdapterConfig stdio()
    {
        McpAdapterConfig c;
        c.mode = McpTransportMode.stdio();
        return c;
    }

    static McpAdapterConfig inMemory(Socket socket)
    {
        McpAdapterConfig c;
        c.mode = McpTransportMode.inMemory(socket);
        return c;
    }

    McpAdapterConfig withInfo(string name, string version_)
    {
        auto c = this;
        c.serverName = name;
        c.serverVersion = version_;
        return c;
    }
}

/// Unified server handle (stdio or in-memory leg).
struct McpServerHandle
{
    enum Kind
    {
        stdio,
        inMemory
    }

    Kind kind;
    StdioTransportHandle stdioHandle;
    InMemoryTransportHandle memoryHandle;

    bool isRunning()
    {
        final switch (kind)
        {
        case Kind.stdio:
            return stdioHandle.isRunning();
        case Kind.inMemory:
            return memoryHandle.isRunning();
        }
    }

    void stop()
    {
        final switch (kind)
        {
        case Kind.stdio:
            stdioHandle.stop();
            break;
        case Kind.inMemory:
            memoryHandle.stop();
            break;
        }
    }

    Nullable!string localAddr()
    {
        return Nullable!string.init;
    }
}

private ProtocolServerHandle wrapHandle(McpServerHandle handle)
{
    static final class Wrap : ProtocolServerHandle
    {
        McpServerHandle inner;
        this(McpServerHandle inner)
        {
            this.inner = inner;
        }

        override bool isRunning()
        {
            return inner.isRunning();
        }

        override void stop()
        {
            inner.stop();
        }

        override Nullable!string localAddr()
        {
            return inner.localAddr();
        }
    }

    return new Wrap(handle);
}

/// Attaches MCP (stdio or in-memory) to an automation engine.
class McpAdapter : AgentProtocolAdapter!(McpAdapterConfig, ProtocolServerHandle)
{
    override ProtocolServerHandle attach(AutomationEngine engine, McpAdapterConfig config)
    {
        auto server = new McpServer(engine, config.serverName, config.serverVersion);
        final switch (config.mode.kind)
        {
        case McpTransportMode.Kind.stdio:
            {
                McpServerHandle h;
                h.kind = McpServerHandle.Kind.stdio;
                h.stdioHandle = spawnStdioTransport(server);
                return wrapHandle(h);
            }
        case McpTransportMode.Kind.inMemory:
            {
                if (config.mode.socket is null)
                    throw AgentError.internal_("in-memory MCP needs a session socket");
                McpServerHandle h;
                h.kind = McpServerHandle.Kind.inMemory;
                h.memoryHandle = spawnInMemoryTransport(server, config.mode.socket);
                return wrapHandle(h);
            }
        }
    }
}

/// Attach an in-memory MCP session to the builder (UFCS: `builder.withMcp(...)`).
AgentBuilder withMcp(AgentBuilder builder, McpAdapterConfig config)
{
    return builder.withProtocolAdapter!(McpAdapter, McpAdapterConfig, ProtocolServerHandle)(
        new McpAdapter(), config);
}

/// Attach the stdio MCP server to the builder.
AgentBuilder withMcpStdio(AgentBuilder builder)
{
    return builder.withMcp(McpAdapterConfig.stdio());
}

///
unittest
{
    import slate.agent.engine : DefaultAutomationEngine, DefaultElementController,
        DefaultStateProvider, DefaultUiInspector, DefaultVisualRenderer;
    import slate.agent.builder : AgentBuilder;
    import slate.mcp.transport : createInMemorySession, SocketLines;
    import std.json : parseJSON;

    auto engine = new DefaultAutomationEngine(new DefaultUiInspector(),
        new DefaultElementController(), new DefaultStateProvider(),
        new DefaultVisualRenderer());

    // Direct adapter attach over a socket pair, end to end.
    auto session = createInMemorySession();
    auto adapter = new McpAdapter();
    auto handle = adapter.attach(engine,
        McpAdapterConfig.inMemory(session.server).withInfo("t", "1"));
    assert(handle.isRunning());
    assert(handle.localAddr().isNull);

    auto client = new SocketLines(session.client);
    client.writeLine(`{"jsonrpc":"2.0","id":1,"method":"initialize",` ~
        `"params":{"protocolVersion":"2024-11-05"}}`);
    assert(parseJSON(client.readLine())["result"]["serverInfo"]["name"].get!string == "t");
    handle.stop();
    assert(!handle.isRunning());
    client.close();

    // Builder integration through the same seam the MCP client will use.
    auto session2 = createInMemorySession();
    auto agent = new AgentBuilder()
        .withInspector(new DefaultUiInspector())
        .withController(new DefaultElementController())
        .withStateProvider(new DefaultStateProvider())
        .withRenderer(new DefaultVisualRenderer())
        .withMcp(McpAdapterConfig.inMemory(session2.server))
        .start();
    assert(agent.isRunning() && agent.serverHandles().length == 1);
    agent.stop();
    session2.client.close(); // server ends already closed by stop()
}
