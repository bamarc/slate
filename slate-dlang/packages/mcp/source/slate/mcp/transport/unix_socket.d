/// Secure, opt-in Unix Domain Socket transport for MCP (`slate.mcp.transport.unix_socket`).
///
/// Designed so that MCP access to a running Slate GUI application is strictly
/// opt-in (e.g. toggled via an in-app switch) and protected against snooping by
/// unauthorized local processes or other agents running under the same user:
///
/// 1. **Filesystem Isolation**: Socket parent directory is restricted to `0700`
///    and the socket file itself is bound with `umask(0077)` and `chmod 0600`.
/// 2. **Kernel Peer Credentials (`SO_PEERCRED`)**: On Linux, every accepted
///    connection's kernel `ucred.uid` is verified against `geteuid()`.
/// 3. **256-bit Capability Token (CSPRNG)**: A 32-byte (64-hex-char) secret token
///    is generated from `/dev/urandom` per session. Clients must present this token
///    via `slate/authenticate` or `initialize.params.authToken` (verified in
///    constant time) before any MCP method or resource can be accessed.
///    Unauthenticated snooping attempts receive `-32001 Unauthorized`, emit a
///    structured `slog.warn` audit log, and are disconnected immediately.
module slate.mcp.transport.unix_socket;

import core.atomic : atomicLoad, atomicStore, cas;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.json : JSONValue, JSONType, parseJSON;
import std.socket : AddressFamily, Socket, SocketShutdown, SocketType, UnixAddress;

import slate.log : slog;
import slate.mcp.server : JsonRpcResponse, McpServer;
import slate.mcp.transport.io : McpTransportError, runLineTransport;
import slate.mcp.transport.memory : SocketLines;

/// JSON-RPC error code returned when a client fails capability token authentication.
enum long unauthorizedErrorCode = -32001;

/// Generate a cryptographically random 256-bit (64-hex-character) capability token
/// from `/dev/urandom` (with fallback to `generateHexId` if `/dev/urandom` is unavailable).
string generateMcpAuthToken(size_t numBytes = 32) @trusted
{
    import std.stdio : File;
    import slate.log : generateHexId;

    immutable char[16] hexDigits = "0123456789abcdef";
    try
    {
        auto f = File("/dev/urandom", "rb");
        ubyte[] raw = new ubyte[](numBytes);
        auto slice = f.rawRead(raw);
        if (slice.length == numBytes)
        {
            char[] outBuf = new char[](numBytes * 2);
            foreach (i, b; slice)
            {
                outBuf[i * 2] = hexDigits[(b >> 4) & 0x0F];
                outBuf[i * 2 + 1] = hexDigits[b & 0x0F];
            }
            return cast(immutable) outBuf;
        }
    }
    catch (Throwable)
    {
    }
    return generateHexId(numBytes);
}

/// Constant-time string comparison to prevent timing side-channel attacks on capability tokens.
bool constantTimeEquals(string a, string b) @safe pure nothrow @nogc
{
    if (a.length != b.length || a.length == 0)
        return false;
    ubyte diff = 0;
    foreach (i; 0 .. a.length)
    {
        diff |= cast(ubyte)(a[i] ^ b[i]);
    }
    return diff == 0;
}

/// Compute a secure default Unix socket path for the current user and process:
/// `$XDG_RUNTIME_DIR/slate/<appName>-<pid>.sock` or `/tmp/slate-<uid>/<appName>-<pid>.sock`.
string defaultMcpUnixSocketPath(string appName = "slate") @trusted
{
    import core.sys.posix.unistd : geteuid, getpid;
    import std.conv : to;
    import std.file : exists, mkdirRecurse;
    import std.path : buildPath;
    import std.process : environment;
    import core.sys.posix.sys.stat : chmod;
    import std.string : toStringz;

    string runtimeDir = environment.get("XDG_RUNTIME_DIR", "");
    string baseDir;
    if (runtimeDir.length > 0)
        baseDir = buildPath(runtimeDir, "slate");
    else
        baseDir = "/tmp/slate-" ~ geteuid().to!string;

    if (!exists(baseDir))
        mkdirRecurse(baseDir);
    chmod(baseDir.toStringz, 0x1C0); // 0700 (rwx------)

    return buildPath(baseDir, appName ~ "-" ~ getpid().to!string ~ ".sock");
}

version (linux)
{
    private extern (C) int getsockopt(int sockfd, int level, int optname,
            void* optval, uint* optlen) nothrow @nogc;

    private struct UCred
    {
        int pid;
        uint uid;
        uint gid;
    }

    private enum int SOL_SOCKET_LINUX = 1;
    private enum int SO_PEERCRED_LINUX = 17;
}

/// Verify via `SO_PEERCRED` (on Linux) that the accepted Unix socket peer belongs
/// to the same effective UID as this process.
bool verifyPeerUid(Socket clientSocket) @trusted nothrow
{
    version (linux)
    {
        import core.sys.posix.unistd : geteuid;

        if (clientSocket is null)
            return false;
        UCred cred;
        uint len = cast(uint) UCred.sizeof;
        int fd = cast(int) clientSocket.handle();
        if (getsockopt(fd, SOL_SOCKET_LINUX, SO_PEERCRED_LINUX, &cred, &len) != 0)
            return false;
        return cred.uid == geteuid();
    }
    else
    {
        return clientSocket !is null;
    }
}

/// Configuration for the secure Unix Domain Socket MCP transport.
struct UnixSocketConfig
{
    /// Filesystem path for the Unix domain socket (`.sock`).
    string socketPath;
    /// 256-bit capability token required from every connecting client.
    /// If empty, a fresh 256-bit CSPRNG token is generated automatically.
    string authToken;
}

/// Lifecycle handle for a running Unix Domain Socket MCP server.
final class UnixSocketTransportHandle
{
    private string _socketPath;
    private string _authToken;
    private Socket _listener;
    private Thread _acceptThread;
    private Mutex _clientsMtx;
    private SocketLines[] _activeClients;
    private shared bool _running;

    this(string socketPath, string authToken, Socket listener, Thread acceptThread,
            Mutex clientsMtx, ref SocketLines[] activeClientsRef)
    {
        _socketPath = socketPath;
        _authToken = authToken;
        _listener = listener;
        _acceptThread = acceptThread;
        _clientsMtx = clientsMtx;
        atomicStore(_running, true);
    }

    /// Filesystem path of the bound `.sock` file.
    string socketPath() const @safe pure nothrow @nogc
    {
        return _socketPath;
    }

    /// Secret capability token required to authenticate with this socket.
    string authToken() const @safe pure nothrow @nogc
    {
        return _authToken;
    }

    /// True while the listener is accepting connections.
    bool isRunning() const @safe nothrow @nogc
    {
        return atomicLoad(_running);
    }

    package void registerClient(SocketLines client) @trusted nothrow
    {
        _clientsMtx.lock_nothrow();
        scope (exit)
            _clientsMtx.unlock_nothrow();
        _activeClients ~= client;
    }

    package void markStopped() @safe nothrow @nogc
    {
        atomicStore(_running, false);
    }

    /// Stop accepting connections, disconnect any active clients, and unlink the socket file.
    void stop() @trusted
    {
        if (!cas(&_running, true, false))
            return;

        if (_listener !is null)
        {
            try
                _listener.shutdown(SocketShutdown.BOTH);
            catch (Throwable)
            {
            }
            try
                _listener.close();
            catch (Throwable)
            {
            }
        }

        {
            _clientsMtx.lock_nothrow();
            scope (exit)
                _clientsMtx.unlock_nothrow();
            foreach (c; _activeClients)
            {
                if (c !is null)
                    c.close();
            }
            _activeClients = null;
        }

        if (_acceptThread !is null)
        {
            try
                _acceptThread.join();
            catch (Throwable)
            {
            }
        }

        unlinkSocketFile(_socketPath);
        slog.info("Stopped secure MCP Unix socket server", "socket_path", _socketPath);
    }
}

private void unlinkSocketFile(string path) @trusted nothrow
{
    import std.file : exists, remove;

    try
    {
        if (path.length > 0 && exists(path))
            remove(path);
    }
    catch (Throwable)
    {
    }
}

/// Authenticate the initial client line and return:
/// - `authenticated = true` if valid token was presented
/// - `replyLine` to send immediately to the client
private bool handleClientAuthHandshake(McpServer server, string firstLine,
        string expectedToken, out string replyLine) @trusted
{
    JSONValue parsed;
    try
    {
        parsed = parseJSON(firstLine);
    }
    catch (Exception)
    {
        replyLine = JsonRpcResponse.parseError("Invalid JSON: expected JSON-RPC request").toLine();
        return false;
    }

    if (parsed.type != JSONType.object)
    {
        replyLine = JsonRpcResponse.invalidRequest(JSONValue.init, false,
                "Invalid Request: top-level JSON value must be an object").toLine();
        return false;
    }

    JSONValue idVal = JSONValue.init;
    bool hasId = false;
    if (auto idPtr = "id" in parsed)
    {
        idVal = *idPtr;
        hasId = true;
    }

    auto methodPtr = "method" in parsed;
    if (methodPtr is null || methodPtr.type != JSONType.string)
    {
        replyLine = JsonRpcResponse.failure(idVal, hasId, unauthorizedErrorCode,
                "Unauthorized: valid MCP capability token required").toLine();
        return false;
    }

    string method = methodPtr.str;
    string candidateToken = "";
    if (auto paramsPtr = "params" in parsed)
    {
        if (paramsPtr.type == JSONType.object)
        {
            if (auto tokPtr = "token" in *paramsPtr)
            {
                if (tokPtr.type == JSONType.string)
                    candidateToken = tokPtr.str;
            }
            else if (auto authTokPtr = "authToken" in *paramsPtr)
            {
                if (authTokPtr.type == JSONType.string)
                    candidateToken = authTokPtr.str;
            }
        }
    }

    if (!constantTimeEquals(candidateToken, expectedToken))
    {
        slog.warn("Rejected unauthenticated MCP Unix socket client", "method",
                method, "reason", "invalid_or_missing_token");
        replyLine = JsonRpcResponse.failure(idVal, hasId, unauthorizedErrorCode,
                "Unauthorized: valid MCP capability token required").toLine();
        return false;
    }

    // Method 1: Dedicated `slate/authenticate` handshake
    if (method == "slate/authenticate")
    {
        JSONValue[string] resObj;
        resObj["authenticated"] = JSONValue(true);
        replyLine = JsonRpcResponse.success(idVal, hasId, JSONValue(resObj)).toLine();
        return true;
    }

    // Method 2: Token embedded in `initialize.params.authToken` (or any valid MCP request)
    replyLine = server.handleLine(firstLine);
    return true;
}

/// Pump a single Unix socket client connection: enforce `SO_PEERCRED` + capability token
/// authentication on the first non-empty line, then delegate to `runLineTransport`.
private void serveAuthenticatedClient(McpServer server, Socket clientSock,
        SocketLines lines, string expectedToken) @trusted
{
    import std.string : strip;

    scope (exit)
        lines.close();

    if (!verifyPeerUid(clientSock))
    {
        slog.warn("Rejected MCP Unix socket connection from foreign UID");
        return;
    }

    // Read first non-empty frame for capability token verification
    for (;;)
    {
        string line;
        try
            line = lines.readLine();
        catch (Throwable)
        {
            return;
        }
        if (line is null)
            return; // EOF before auth

        auto trimmed = line.strip();
        if (trimmed.length == 0)
            continue;

        string replyLine;
        bool ok = handleClientAuthHandshake(server, trimmed, expectedToken, replyLine);
        if (replyLine.length > 0)
        {
            try
            {
                lines.writeLine(replyLine);
                lines.flush();
            }
            catch (Throwable)
            {
                return;
            }
        }
        if (!ok)
            return; // Immediately disconnect unauthorized snooper
        break;
    }

    slog.info("Authenticated MCP Unix socket client session");
    try
        runLineTransport(server, lines, lines);
    catch (Throwable)
    {
    }
}

private void spawnClientWorker(McpServer server, Socket clientSock,
        SocketLines clientLines, string token) @trusted
{
    auto worker = new Thread({
        serveAuthenticatedClient(server, clientSock, clientLines, token);
    });
    worker.isDaemon = true;
    worker.start();
}

/// Bind and spawn a secure, authenticated Unix Domain Socket MCP server.
UnixSocketTransportHandle spawnUnixSocketTransport(McpServer server,
        UnixSocketConfig config = UnixSocketConfig.init)
in
{
    assert(server !is null, "McpServer must not be null");
}
out (handle)
{
    assert(handle !is null, "UnixSocketTransportHandle must not be null");
}
do
{
    import core.sys.posix.sys.stat : chmod, umask;
    import std.file : exists, mkdirRecurse;
    import std.path : dirName;
    import std.string : toStringz;

    string sockPath = config.socketPath.length > 0 ? config.socketPath
        : defaultMcpUnixSocketPath(server.name());
    string token = config.authToken.length > 0 ? config.authToken : generateMcpAuthToken();

    string parentDir = dirName(sockPath);
    if (parentDir.length > 0 && !exists(parentDir))
    {
        mkdirRecurse(parentDir);
        chmod(parentDir.toStringz, 0x1C0); // 0700
    }

    // Remove any stale socket file at the target path before binding
    unlinkSocketFile(sockPath);

    auto listener = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    auto oldMask = umask(0x03F); // 0077: owner-only socket creation
    scope (exit)
        umask(oldMask);

    listener.bind(new UnixAddress(sockPath));
    chmod(sockPath.toStringz, 0x180); // 0600 (rw-------)
    listener.listen(8);

    auto clientsMtx = new Mutex();
    SocketLines[] dummyClients;
    UnixSocketTransportHandle handle;

    auto acceptThread = new Thread({
        scope (exit)
        {
            if (handle !is null)
                handle.markStopped();
        }
        for (;;)
        {
            Socket clientSock;
            try
            {
                clientSock = listener.accept();
            }
            catch (Throwable)
            {
                break;
            }
            if (clientSock is null)
                break;

            auto clientLines = new SocketLines(clientSock);
            if (handle !is null)
                handle.registerClient(clientLines);

            spawnClientWorker(server, clientSock, clientLines, token);
        }
    });

    handle = new UnixSocketTransportHandle(sockPath, token, listener,
            acceptThread, clientsMtx, dummyClients);
    acceptThread.isDaemon = true;
    acceptThread.start();

    slog.info("Started secure MCP Unix socket server", "socket_path", sockPath);
    return handle;
}

/// Connect to a running Slate Unix Domain Socket MCP server and complete the
/// `slate/authenticate` capability token handshake, returning the ready `SocketLines` session.
SocketLines connectAuthenticatedUnixSocket(string socketPath, string authToken)
{
    auto sock = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    sock.connect(new UnixAddress(socketPath));
    auto lines = new SocketLines(sock);

    JSONValue[string] params;
    params["token"] = JSONValue(authToken);
    JSONValue[string] req;
    req["jsonrpc"] = JSONValue("2.0");
    req["id"] = JSONValue(0);
    req["method"] = JSONValue("slate/authenticate");
    req["params"] = JSONValue(params);

    lines.writeLine(JSONValue(req).toString());
    lines.flush();

    auto respLine = lines.readLine();
    if (respLine is null)
    {
        lines.close();
        throw McpTransportError.io("Unix socket closed during authentication handshake");
    }

    auto parsed = parseJSON(respLine);
    if ("error" in parsed)
    {
        lines.close();
        throw McpTransportError.io(
                "Unix socket authentication rejected: " ~ parsed["error"]["message"].str);
    }
    return lines;
}

/// Run a synchronous stdio-to-Unix-socket bridge (`--mcp-attach <sock> --mcp-token <token>`).
/// Allows standard stdio MCP clients (Claude Desktop, Cursor, Antigravity) to connect
/// to a running opt-in Slate GUI instance only when configured with its capability token.
void runUnixSocketStdioBridge(string socketPath, string authToken)
{
    import std.stdio : stdin, stdout;
    import std.string : chomp, strip;

    auto remote = connectAuthenticatedUnixSocket(socketPath, authToken);
    scope (exit)
        remote.close();

    for (;;)
    {
        auto line = stdin.readln();
        if (line is null)
            break;
        auto trimmed = line.chomp().strip();
        if (trimmed.length == 0)
            continue;
        remote.writeLine(trimmed);
        remote.flush();

        // Notifications do not produce a response line
        try
        {
            auto reqJson = parseJSON(trimmed);
            if (reqJson.type == JSONType.object && ("id" !in reqJson))
                continue;
        }
        catch (Exception)
        {
        }

        auto reply = remote.readLine();
        if (reply is null)
            break;
        stdout.writeln(reply);
        stdout.flush();
    }
}

// Spec: Unix socket MCP server rejects unauthenticated snoopers (-32001), accepts clients
// presenting the valid 256-bit capability token, enforces 0600 permissions, and unlinks on stop.
/// Example:
unittest
{
    import core.sys.posix.unistd : getpid;
    import std.algorithm : canFind;
    import std.conv : to;
    import std.exception : assertThrown;
    import std.file : exists, getAttributes;
    import slate.agent.engine : DefaultAutomationEngine, DefaultElementController,
        DefaultStateProvider, DefaultUiInspector, DefaultVisualRenderer;

    auto engine = new DefaultAutomationEngine(new DefaultUiInspector(),
            new DefaultElementController(), new DefaultStateProvider(), new DefaultVisualRenderer());
    auto server = new McpServer(engine, "test-unix-mcp", "0.1.0");

    string sockPath = "/tmp/slate-test-unix-" ~ getpid().to!string ~ ".sock";
    UnixSocketConfig cfg;
    cfg.socketPath = sockPath;

    auto handle = spawnUnixSocketTransport(server, cfg);
    scope (exit)
        handle.stop();

    assert(handle.isRunning());
    assert(handle.socketPath() == sockPath);
    assert(handle.authToken().length == 64); // 256-bit hex capability token
    assert(exists(sockPath));

    // Verify 0600 permissions (no group or world access bits set)
    uint mode = getAttributes(sockPath) & 0x1FF;
    assert(mode == 0x180, "Socket permissions must be 0600 (owner rw only)");

    // 1. Snooping client WITHOUT token is rejected with -32001 and disconnected
    {
        auto snooperSock = new Socket(AddressFamily.UNIX, SocketType.STREAM);
        snooperSock.connect(new UnixAddress(sockPath));
        auto snooper = new SocketLines(snooperSock);
        scope (exit)
            snooper.close();

        snooper.writeLine(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`);
        auto errLine = snooper.readLine();
        assert(errLine !is null);
        auto errJson = parseJSON(errLine);
        assert(errJson["error"]["code"].integer == unauthorizedErrorCode);
        assert(errJson["error"]["message"].str.canFind("Unauthorized"));

        // Subsequent reads return EOF because the server immediately disconnected the snooper
        assert(snooper.readLine() is null);
    }

    // 2. Snooping client with WRONG token via connectAuthenticatedUnixSocket throws McpTransportError
    assertThrown!McpTransportError(connectAuthenticatedUnixSocket(sockPath, "deadbeef"));

    // 3. Authorized client with valid token succeeds and can invoke MCP tools
    {
        auto client = connectAuthenticatedUnixSocket(sockPath, handle.authToken());
        scope (exit)
            client.close();

        client.writeLine(
                `{"jsonrpc":"2.0","id":1,"method":"initialize",`
                ~ `"params":{"protocolVersion":"2024-11-05"}}`);
        auto initReply = parseJSON(client.readLine());
        assert(initReply["result"]["serverInfo"]["name"].str == "test-unix-mcp");

        client.writeLine(`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`);
        auto toolsReply = parseJSON(client.readLine());
        assert(toolsReply["result"]["tools"].array.length == 5);
    }

    // 4. Stopping the handle closes the server and unlinks the socket file from disk
    handle.stop();
    assert(!handle.isRunning());
    assert(!exists(sockPath));
}
