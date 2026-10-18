/// End-to-end integration tests for HTTP/2, TLS certificate verification, Alt-Svc, and HTTP/3.
///
/// This module provides loopback integration test harnesses (TC-09) validating real HTTP/2 framing,
/// connection reuse, TLS verification and CA bundle handling, file-backed Alt-Svc persistence (OPT-2),
/// and fast-fail HTTP/3 capability gating.
module slate.http.integration_test;

version (IntegrationTest)  : import slate.http.client;
import slate.http.c_bind;
import slate.http.error;
import slate.http.request;
import slate.http.response;
import slate.http.version_;
import slate.http.multi;
import slate.http.http_task;
import slate.http.debug_;

import std.socket;
import core.thread;
import core.atomic : atomicLoad, atomicStore, atomicOp;
import core.sys.posix.unistd : getpid;
import std.file : exists, remove;
import std.process : execute, spawnProcess, wait, kill;
import std.format : format;

/// In-process HTTP/2 loopback server speaking native binary HTTP/2 framing (RFC 7540 / RFC 9113).
package class H2LoopbackServer
{
    TcpSocket listener;
    ushort port;
    Thread thread;
    shared bool running = true;
    shared int requestCount;

    this()
    {
        listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(8);
        port = (cast(InternetAddress) listener.localAddress).port;

        thread = new Thread(&run);
        thread.start();
    }

    void run()
    {
        import core.time : dur;

        while (atomicLoad(running))
        {
            try
            {
                Socket client = listener.accept();
                if (!atomicLoad(running))
                {
                    client.close();
                    break;
                }
                scope (exit)
                    client.close();
                client.setOption(SocketOptionLevel.SOCKET,
                        SocketOption.RCVTIMEO, dur!"seconds"(3));

                // 1. Read 24-byte client connection preface: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
                ubyte[24] preface;
                size_t readSoFar = 0;
                while (readSoFar < 24)
                {
                    auto n = client.receive(preface[readSoFar .. 24]);
                    if (n <= 0)
                        break;
                    readSoFar += n;
                }
                if (readSoFar < 24 || cast(string) preface != "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
                    break;

                // 2. Send initial server SETTINGS frame (length 0, type 4, flags 0, stream 0)
                ubyte[9] serverSettings = [
                    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00
                ];
                client.send(serverSettings[]);

                // 3. Frame processing loop on this connection
                while (atomicLoad(running))
                {
                    ubyte[9] hdr;
                    readSoFar = 0;
                    while (readSoFar < 9)
                    {
                        auto n = client.receive(hdr[readSoFar .. 9]);
                        if (n <= 0)
                            break;
                        readSoFar += n;
                    }
                    if (readSoFar < 9)
                        break;

                    uint len = (cast(uint) hdr[0] << 16) | (cast(uint) hdr[1] << 8) | cast(
                            uint) hdr[2];
                    ubyte ftype = hdr[3];
                    ubyte flags = hdr[4];
                    uint streamId = ((cast(uint) hdr[5] << 24) | (cast(
                            uint) hdr[6] << 16) | (cast(uint) hdr[7] << 8) | cast(uint) hdr[8]) & 0x7FFFFFFF;

                    // Read frame payload
                    if (len > 0)
                    {
                        ubyte[] payload = new ubyte[len];
                        size_t pRead = 0;
                        while (pRead < len)
                        {
                            auto n = client.receive(payload[pRead .. len]);
                            if (n <= 0)
                                break;
                            pRead += n;
                        }
                        if (pRead < len)
                            break;
                    }

                    if (ftype == 4) // SETTINGS
                    {
                        if ((flags & 1) == 0) // Not an ACK
                        {
                            // Send SETTINGS ACK (length 0, type 4, flags 1, stream 0)
                            ubyte[9] ack = [
                                0x00, 0x00, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00,
                                0x00
                            ];
                            client.send(ack[]);
                        }
                    }
                    else if (ftype == 1) // HEADERS
                    {
                        atomicOp!"+="(requestCount, 1);
                        // Send HEADERS: :status: 200 (static table index 8 = 0x88)
                        // length 1, type 1, flags END_HEADERS (0x04), streamId
                        ubyte[10] respHeaders;
                        respHeaders[0 .. 3] = [0x00, 0x00, 0x01];
                        respHeaders[3] = 0x01; // HEADERS
                        respHeaders[4] = 0x04; // END_HEADERS
                        respHeaders[5] = cast(ubyte)((streamId >> 24) & 0xFF);
                        respHeaders[6] = cast(ubyte)((streamId >> 16) & 0xFF);
                        respHeaders[7] = cast(ubyte)((streamId >> 8) & 0xFF);
                        respHeaders[8] = cast(ubyte)(streamId & 0xFF);
                        respHeaders[9] = 0x88; // :status: 200
                        client.send(respHeaders[]);

                        // Send DATA: 'H2 OK' (5 bytes), flags END_STREAM (0x01), streamId
                        ubyte[14] respData;
                        respData[0 .. 3] = [0x00, 0x00, 0x05];
                        respData[3] = 0x00; // DATA
                        respData[4] = 0x01; // END_STREAM
                        respData[5] = cast(ubyte)((streamId >> 24) & 0xFF);
                        respData[6] = cast(ubyte)((streamId >> 16) & 0xFF);
                        respData[7] = cast(ubyte)((streamId >> 8) & 0xFF);
                        respData[8] = cast(ubyte)(streamId & 0xFF);
                        respData[9 .. 14] = cast(ubyte[]) "H2 OK";
                        client.send(respData[]);
                    }
                }
            }
            catch (Exception)
            {
                break;
            }
        }
    }

    void close()
    {
        atomicStore(running, false);
        try
        {
            auto s = new TcpSocket();
            s.connect(new InternetAddress("127.0.0.1", port));
            s.close();
        }
        catch (Exception)
        {
        }
        try
        {
            listener.close();
        }
        catch (Exception)
        {
        }
        if (thread !is null)
        {
            thread.join();
        }
    }
}

/// Simple HTTP/1.1 loopback server for testing timeouts, redirects, and leak soak (TC-11, TC-12).
package class Http1LoopbackServer
{
    TcpSocket listener;
    ushort port;
    Thread thread;
    shared bool running = true;

    this()
    {
        listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(16);
        port = (cast(InternetAddress) listener.localAddress).port;

        thread = new Thread(&run);
        thread.start();
    }

    void run()
    {
        import core.time : msecs;

        while (atomicLoad(running))
        {
            try
            {
                Socket client = listener.accept();
                if (!atomicLoad(running))
                {
                    client.close();
                    break;
                }
                char[2048] buf;
                auto n = client.receive(buf[]);
                if (n <= 0)
                {
                    client.close();
                    continue;
                }
                string req = cast(string) buf[0 .. n];

                if (req.length >= 12 && req[0 .. 12] == "GET /timeout")
                {
                    Thread.sleep(500.msecs);
                    client.close();
                }
                else if (req.length >= 13 && req[0 .. 13] == "GET /redirect")
                {
                    string resp = "HTTP/1.1 302 Found\r\nLocation: /redirect\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    client.send(resp);
                    client.close();
                }
                else if (req.length >= 4 && req[0 .. 4] == "POST")
                {
                    import std.string : indexOf;

                    auto bodyIdx = req.indexOf("\r\n\r\n");
                    string posted = bodyIdx >= 0 ? req[bodyIdx + 4 .. $] : "";
                    string bodyText = "POST OK: " ~ posted;
                    string resp = format("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Received-Method: POST\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
                            bodyText.length, bodyText);
                    client.send(resp);
                    client.close();
                }
                else
                {
                    string bodyText = "HTTP1 OK";
                    string resp = format("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
                            bodyText.length, bodyText);
                    client.send(resp);
                    client.close();
                }
            }
            catch (Exception)
            {
                break;
            }
        }
    }

    void close()
    {
        atomicStore(running, false);
        try
        {
            auto s = new TcpSocket();
            s.connect(new InternetAddress("127.0.0.1", port));
            s.close();
        }
        catch (Exception)
        {
        }
        try
        {
            listener.close();
        }
        catch (Exception)
        {
        }
        if (thread !is null)
        {
            thread.join();
        }
    }
}

// Spec: RFC 7540 / RFC 9113 HTTP/2 binary framing and connection multiplexing reuse (ST-1, EV-1)
// Scenario: TC-09 HTTP/2 transfer and connection reuse
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.request;
/// auto client = Client.create();
/// auto res1 = client.perform(Request.get("http://127.0.0.1:8080/").withVersion(HttpVersion.h2PriorKnowledge));
/// assert(res1.status == 200);
/// assert(client.lastNumConnects() == 1);
/// auto res2 = client.perform(Request.get("http://127.0.0.1:8080/").withVersion(HttpVersion.h2PriorKnowledge));
/// assert(client.lastNumConnects() == 0);
/// ---
unittest
{
    // Spec: verify real HTTP/2 binary framing negotiation and pooled connection reuse
    auto server = new H2LoopbackServer();
    scope (exit)
        server.close();

    string url = format("http://127.0.0.1:%d/h2_test", server.port);

    auto client = Client.create();

    // First request: establishes HTTP/2 connection (numConnects == 1)
    auto res1 = client.perform(Request.get(url).withVersion(HttpVersion.h2PriorKnowledge));
    assert(res1.status == 200);
    assert(res1.bodyAsString() == "H2 OK");
    assert(res1.httpVersion == HttpVersion.h2, "Negotiated protocol must be HTTP/2");
    assert(client.lastNumConnects() == 1, "First HTTP/2 transfer must make 1 connection");

    // Second request: reuses open HTTP/2 multiplex connection (numConnects == 0)
    auto res2 = client.perform(Request.get(url).withVersion(HttpVersion.h2PriorKnowledge));
    assert(res2.status == 200);
    assert(res2.bodyAsString() == "H2 OK");
    assert(res2.httpVersion == HttpVersion.h2, "Subsequent transfer must remain HTTP/2");
    assert(client.lastNumConnects() == 0,
            "Second HTTP/2 transfer must reuse connection without reconnecting (ST-1)");
}

// Spec: TLS 1.3 / RFC 8446 Certificate verification and custom CA bundle (TC-10)
// Scenario: TC-10 TLS defaults and verification
/// Example:
/// ---
/// import slate.http.client;
/// auto client = Client.create();
/// assert(client.config.tlsMode == TlsMode.verify);
/// assert(client.config.verifyPeer == true);
/// ---
unittest
{
    // Spec: verify default TLS verification rejects untrusted cert, caInfo succeeds, missing CA bundle fails fast with actionable message, and insecureOptIn logs audit count
    string certPath = format("/tmp/slate_test_tls_cert_%d.pem", getpid());
    string keyPath = format("/tmp/slate_test_tls_key_%d.pem", getpid());

    // Generate self-signed test certificate using openssl
    execute([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout",
        keyPath, "-out", certPath, "-days", "1", "-subj", "/CN=127.0.0.1"
    ]);
    scope (exit)
    {
        if (exists(certPath))
            remove(certPath);
        if (exists(keyPath))
            remove(keyPath);
    }

    // Launch loopback Python TLS server
    string pythonScript = format(`
import ssl, http.server, socketserver, threading, sys

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        body = b'TLS OK'
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
    def log_message(self, *args): pass

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('%s', '%s')

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, addr, handler, ctx):
        self.ctx = ctx
        super().__init__(addr, handler)
    def get_request(self):
        while True:
            sock, addr = self.socket.accept()
            try:
                return self.ctx.wrap_socket(sock, server_side=True), addr
            except Exception:
                try: sock.close()
                except Exception: pass

server = Server(('127.0.0.1', 0), Handler, ctx)
sys.stdout.write(f'{server.server_address[1]}\n')
sys.stdout.flush()
server.serve_forever()
`, certPath, keyPath);

    import std.process : Pipe, pipeProcess, Redirect, Pid;

    void safeKill(Pid p)
    {
        try
        {
            kill(p);
            wait(p);
        }
        catch (Exception)
        {
        }
    }

    auto pipes = pipeProcess(["python3", "-c", pythonScript], Redirect.stdout | Redirect.stderr);
    scope (exit)
        safeKill(pipes.pid);

    import std.string : strip;
    import std.conv : to;

    string portStr = pipes.stdout.readln().strip();
    ushort tlsPort = to!ushort(portStr);
    string httpsUrl = format("https://127.0.0.1:%d/tls_test", tlsPort);

    // 1. Default Client MUST have TLS verification ON and reject self-signed cert (TC-10)
    auto defaultClient = Client.create();
    assert(defaultClient.config.tlsMode == TlsMode.verify);
    assert(defaultClient.config.verifyPeer == true);
    assert(defaultClient.config.verifyHost == true);
    bool caughtVerificationError = false;
    try
    {
        defaultClient.get(httpsUrl);
    }
    catch (CurlException e)
    {
        caughtVerificationError = true;
        assert(e.code == CurlCode.CURLE_PEER_FAILED_VERIFICATION
                || e.code == CurlCode.CURLE_SSL_CACERT || e.code == CurlCode.CURLE_SSL_CERTPROBLEM,
                "Expected TLS verification error for untrusted self-signed certificate");
    }
    assert(caughtVerificationError, "verifyPeer=true must reject untrusted self-signed certificate");

    // 2. verifyPeer = true WITH caInfo pointing to test cert MUST succeed (200 OK)
    ClientConfig caCfg;
    caCfg.verifyPeer = true;
    caCfg.caInfo = certPath;
    auto caClient = Client.create(caCfg);
    auto caRes = caClient.get(httpsUrl);
    assert(caRes.status == 200);
    assert(caRes.bodyAsString() == "TLS OK");

    // 3. caInfo pointing to missing file MUST fail fast with CURLE_SSL_CACERT and actionable message (TC-10)
    string missingCaPath = "/nonexistent/test_ca_bundle.pem";
    ClientConfig missingCaCfg;
    missingCaCfg.caInfo = missingCaPath;
    auto missingCaClient = Client.create(missingCaCfg);
    bool caughtMissingCa = false;
    try
    {
        missingCaClient.get(httpsUrl);
    }
    catch (CurlException e)
    {
        caughtMissingCa = true;
        assert(e.code == CurlCode.CURLE_SSL_CACERT, "Missing CA must fail with CURLE_SSL_CACERT");
        import std.algorithm.searching : canFind;

        assert(e.msg.canFind(missingCaPath), "Exception message must name missing bundle: " ~ e.msg);
    }
    assert(caughtMissingCa, "Missing CA bundle must fail fast");

    // 4. Insecure opt-in MUST succeed and increment insecureOptInAuditCount (TC-10)
    size_t beforeAudit = insecureOptInAuditCount();
    ClientConfig insecureCfg;
    insecureCfg.tlsMode = TlsMode.insecureOptIn;
    auto insecureClient = Client.create(insecureCfg);
    auto insecRes = insecureClient.get(httpsUrl);
    assert(insecRes.status == 200);
    assert(insecRes.bodyAsString() == "TLS OK");
    assert(insecureOptInAuditCount() > beforeAudit,
            "insecureOptInAuditCount must increment on insecure TLS opt-in");
}

// Spec: RFC 9110 HTTP Redirects and Transfer Timeouts (TC-11)
// Scenario: TC-11 timeouts and redirects
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.request;
/// auto client = Client.create();
/// try {
///     client.perform(Request.get("http://127.0.0.1:8080/timeout").withTimeout(50));
/// } catch (TimeoutException e) {
///     assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
/// }
/// ---
unittest
{
    // Spec: verify per-request timeouts throw TimeoutException, redirect loops throw TooManyRedirectsException, and HTTPS->HTTP downgrade is blocked by default
    auto h1Server = new Http1LoopbackServer();
    scope (exit)
        h1Server.close();

    string certPath = format("/tmp/slate_test_redir_cert_%d.pem", getpid());
    string keyPath = format("/tmp/slate_test_redir_key_%d.pem", getpid());

    execute([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout",
        keyPath, "-out", certPath, "-days", "1", "-subj", "/CN=127.0.0.1"
    ]);
    scope (exit)
    {
        if (exists(certPath))
            remove(certPath);
        if (exists(keyPath))
            remove(keyPath);
    }

    string pythonScript = format(`
import ssl, http.server, socketserver, threading, sys

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/downgrade':
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:%d/ok')
            self.send_header('Content-Length', '0')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            return
        body = b'HTTPS OK'
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
    def log_message(self, *args): pass

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('%s', '%s')

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, addr, handler, ctx):
        self.ctx = ctx
        super().__init__(addr, handler)
    def get_request(self):
        while True:
            sock, addr = self.socket.accept()
            try:
                return self.ctx.wrap_socket(sock, server_side=True), addr
            except Exception:
                try: sock.close()
                except Exception: pass

server = Server(('127.0.0.1', 0), Handler, ctx)
sys.stdout.write(f'{server.server_address[1]}\n')
sys.stdout.flush()
server.serve_forever()
`, h1Server.port, certPath, keyPath);

    import std.process : Pipe, pipeProcess, Redirect, Pid;

    void safeKill(Pid p)
    {
        try
        {
            kill(p);
            wait(p);
        }
        catch (Exception)
        {
        }
    }

    auto pipes = pipeProcess(["python3", "-c", pythonScript], Redirect.stdout | Redirect.stderr);
    scope (exit)
        safeKill(pipes.pid);

    import std.string : strip;
    import std.conv : to;

    string portStr = pipes.stdout.readln().strip();
    ushort tlsPort = to!ushort(portStr);

    auto client = Client.create();

    // 1. Per-request timeout override triggers TimeoutException (TC-11)
    bool caughtTimeout = false;
    try
    {
        client.perform(Request.get(format("http://127.0.0.1:%d/timeout",
                h1Server.port)).withTimeout(100));
    }
    catch (TimeoutException e)
    {
        caughtTimeout = true;
        assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    assert(caughtTimeout, "Per-request timeout override must throw TimeoutException");

    // 2. Redirect limit triggers TooManyRedirectsException (TC-11)
    ClientConfig redirCfg;
    redirCfg.redirects.mode = RedirectMode.follow;
    redirCfg.redirects.maxRedirects = 2;
    auto redirClient = Client.create(redirCfg);
    bool caughtRedir = false;
    try
    {
        redirClient.get(format("http://127.0.0.1:%d/redirect", h1Server.port));
    }
    catch (TooManyRedirectsException e)
    {
        caughtRedir = true;
        assert(e.code == CurlCode.CURLE_TOO_MANY_REDIRECTS);
    }
    assert(caughtRedir, "Exceeding maxRedirects must throw TooManyRedirectsException");

    // 3. HTTPS -> HTTP downgrade redirect blocked by default (TC-11)
    ClientConfig downCfg;
    downCfg.verifyPeer = false;
    downCfg.verifyHost = false;
    downCfg.redirects.mode = RedirectMode.follow;
    downCfg.redirects.allowHttpsToHttpDowngrade = false;
    auto downClient = Client.create(downCfg);
    bool caughtDowngrade = false;
    try
    {
        downClient.get(format("https://127.0.0.1:%d/downgrade", tlsPort));
    }
    catch (CurlException e)
    {
        caughtDowngrade = true;
        assert(e.code == CurlCode.CURLE_UNSUPPORTED_PROTOCOL);
    }
    assert(caughtDowngrade, "Downgrade redirect from HTTPS to HTTP must be blocked by default");

    // 4. HTTPS -> HTTP downgrade succeeds when explicitly permitted
    downCfg.redirects.allowHttpsToHttpDowngrade = true;
    auto allowDownClient = Client.create(downCfg);
    auto allowRes = allowDownClient.get(format("https://127.0.0.1:%d/downgrade", tlsPort));
    assert(allowRes.status == 200);
    assert(allowRes.bodyAsString() == "HTTP1 OK");
}

// Spec: Handle lifecycle RAII and fault-injection soak test (TC-12, UN-3)
// Scenario: TC-12 leak soak and fault injection
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.multi;
/// auto client = Client.create();
/// for (int i = 0; i < 100; i++) client.get("http://127.0.0.1:8080/ok");
/// ---
unittest
{
    // Spec: verify zero handle or resource leaks over pooled high-iteration fault injection
    auto h1Server = new Http1LoopbackServer();
    scope (exit)
        h1Server.close();

    string goodUrl = format("http://127.0.0.1:%d/ok", h1Server.port);
    string timeoutUrl = format("http://127.0.0.1:%d/timeout", h1Server.port);

    // Soak test over pooled Client
    auto client = Client.create();
    foreach (i; 0 .. 100)
    {
        switch (i % 5)
        {
        case 0:
            auto res = client.get(goodUrl);
            assert(res.status == 200);
            break;
        case 1:
            try
            {
                client.perform(Request.get(timeoutUrl).withTimeout(15));
            }
            catch (TimeoutException)
            {
            }
            break;
        case 2:
            ClientConfig badCaCfg;
            badCaCfg.caInfo = "/nonexistent/soak_ca.pem";
            auto badClient = Client.create(badCaCfg);
            try
            {
                badClient.get(goodUrl);
            }
            catch (CurlException)
            {
            }
            break;
        case 3:
            try
            {
                client.perform(Request.get(goodUrl).withVersion(HttpVersion.h3Only));
            }
            catch (CurlException)
            {
            }
            break;
        case 4:
            CancellationToken cancel;
            cancel.cancel();
            try
            {
                client.perform(Request.get(goodUrl), &cancel);
            }
            catch (CancelledException)
            {
            }
            break;
        default:
            break;
        }
    }

    // Soak test over MultiClient
    MultiConfig multiCfg;
    auto multi = MultiClient.create(multiCfg);
    foreach (i; 0 .. 50)
    {
        Request[] batch = [
            Request.get(goodUrl), Request.get(timeoutUrl).withTimeout(15),
            Request.get(goodUrl).withVersion(HttpVersion.h3Only)
        ];
        try
        {
            multi.performAll(batch);
        }
        catch (CurlException)
        {
        }
        assert(multi.activeHandleCount == 0, "activeHandleCount must be 0 after batch completion");
    }
    assert(multi.activeHandleCount == 0);
}

// Spec: RFC 7838 Alt-Svc cache file persistence across separate Client instances (OPT-2, ST-3)
// Scenario: TC-09 Alt-Svc cache persistence
/// Example:
/// ---
/// import slate.http.client;
/// ClientConfig cfg;
/// cfg.altSvcCachePath = "/tmp/altsvc.txt";
/// auto client1 = Client.create(cfg);
/// client1.get("https://example.com/");
/// // client1 destroyed, flushing cache to disk
/// auto client2 = Client.create(cfg);
/// // client2 reads cached Alt-Svc entries from disk
/// ---
unittest
{
    // Spec: verify Alt-Svc cache writes to disk upon Client teardown and is readable by subsequent Client
    string certPath = format("/tmp/slate_test_altsvc_cert_%d.pem", getpid());
    string keyPath = format("/tmp/slate_test_altsvc_key_%d.pem", getpid());
    string altSvcPath = format("/tmp/slate_test_altsvc_cache_%d.txt", getpid());

    if (exists(altSvcPath))
        remove(altSvcPath);
    execute([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout",
        keyPath, "-out", certPath, "-days", "1", "-subj", "/CN=127.0.0.1"
    ]);
    scope (exit)
    {
        if (exists(certPath))
            remove(certPath);
        if (exists(keyPath))
            remove(keyPath);
        if (exists(altSvcPath))
            remove(altSvcPath);
    }

    string pythonScript = format(`
import ssl, http.server, socketserver, threading, sys

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        body = b'Alt-Svc OK'
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Alt-Svc', f'h1="127.0.0.1:{self.server.server_address[1]}"; ma=3600')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
    def log_message(self, *args): pass

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('%s', '%s')

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, addr, handler, ctx):
        self.ctx = ctx
        super().__init__(addr, handler)
    def get_request(self):
        while True:
            sock, addr = self.socket.accept()
            try:
                return self.ctx.wrap_socket(sock, server_side=True), addr
            except Exception:
                try: sock.close()
                except Exception: pass

server = Server(('127.0.0.1', 0), Handler, ctx)
sys.stdout.write(f'{server.server_address[1]}\n')
sys.stdout.flush()
server.serve_forever()
`, certPath, keyPath);

    import std.process : pipeProcess, Redirect, Pid;

    void safeKill(Pid p)
    {
        try
        {
            kill(p);
            wait(p);
        }
        catch (Exception)
        {
        }
    }

    auto pipes = pipeProcess(["python3", "-c", pythonScript], Redirect.stdout | Redirect.stderr);
    scope (exit)
        safeKill(pipes.pid);

    import std.string : strip;
    import std.conv : to;

    string portStr = pipes.stdout.readln().strip();
    ushort tlsPort = to!ushort(portStr);
    string httpsUrl = format("https://127.0.0.1:%d/altsvc_test", tlsPort);

    ClientConfig cfg;
    cfg.verifyPeer = false;
    cfg.verifyHost = false;
    cfg.altSvcCachePath = altSvcPath;

    // 1. First Client receives Alt-Svc header and flushes to disk upon destruction
    {
        auto client1 = Client.create(cfg);
        auto res = client1.get(httpsUrl);
        assert(res.status == 200);
        assert(res.bodyAsString() == "Alt-Svc OK");
    } // client1 destroyed here, libcurl flushes Alt-Svc cache file to disk

    assert(exists(altSvcPath),
            "Alt-Svc cache file must be written to disk on client cleanup (OPT-2)");
    import std.file : readText;
    import std.algorithm.searching : canFind;

    string cacheContent = readText(altSvcPath);
    assert(cacheContent.canFind("127.0.0.1"), "Alt-Svc cache file must contain host entry");

    // 2. Second Client loads the persisted cache file
    {
        auto client2 = Client.create(cfg);
        auto res2 = client2.get(httpsUrl);
        assert(res2.status == 200);
        assert(res2.bodyAsString() == "Alt-Svc OK");
    }
}

// Spec: RFC 9114 HTTP/3 capability gating and explicit unavailability explanation (ST-2, EV-2b)
// Scenario: TC-09 HTTP/3 capability check
/// Example:
/// ---
/// import slate.http.version_;
/// import slate.http.client;
/// import slate.http.request;
/// if (!hasHttp3()) {
///     assert(http3UnavailableExplanation().length > 0);
/// }
/// ---
unittest
{
    // Spec: verify hasHttp3 reports clear diagnostics and h3Only fails fast when unavailable
    if (!hasHttp3())
    {
        string reason = http3UnavailableExplanation();
        assert(reason.length > 0, "Explicit skip/unavailability reason must be provided");

        auto client = Client.create();
        bool caught = false;
        try
        {
            client.perform(Request.get("http://127.0.0.1:1/").withVersion(HttpVersion.h3Only));
        }
        catch (CurlException e)
        {
            caught = true;
            assert(e.code == CurlCode.CURLE_NOT_BUILT_IN);
        }
        assert(caught, "h3Only must fail fast with CURLE_NOT_BUILT_IN when H3 is disabled");
    }
}

// Spec: CLI end-to-end integration test with durl against real loopback servers
// Scenario: durl CLI against HTTP/1.1, HTTP/2, and TLS servers
/// Example:
/// ---
/// import slate.bin.durl;
/// int rc = runDurl(["durl", "--version"]);
/// assert(rc == 0);
/// ---
unittest
{
    // Spec: verify durl against Http1LoopbackServer, H2LoopbackServer, and TLS servers
    import std.algorithm.searching : canFind;
    import std.file : exists, remove, readText;
    import std.process : execute;

    // 1. Ensure ./bin/durl executable is built for process-level CLI tests
    string durlBin = "bin/durl";
    if (!exists(durlBin))
    {
        auto buildRes = execute(["dub", "build", "--config=durl"]);
        assert(buildRes.status == 0, "Building durl failed: " ~ buildRes.output);
    }
    assert(exists(durlBin), "bin/durl must exist");

    // Test --version and --help via binary
    auto vRes = execute([durlBin, "--version"]);
    assert(vRes.status == 0);
    assert(vRes.output.canFind("durl 0.1.0"));
    assert(vRes.output.canFind("libcurl/"));

    auto hRes = execute([durlBin, "--help"]);
    assert(hRes.status == 0);
    assert(hRes.output.canFind("Usage: durl"));

    // 2. Test against Http1LoopbackServer
    auto h1Server = new Http1LoopbackServer();
    scope (exit)
        h1Server.close();

    string h1Url = format("http://127.0.0.1:%d/", h1Server.port);
    string redirUrl = format("http://127.0.0.1:%d/redirect", h1Server.port);

    // GET
    auto getRes = execute([durlBin, h1Url]);
    assert(getRes.status == 0);
    assert(getRes.output.canFind("HTTP1 OK"));

    // POST with -d (defaults method to POST)
    auto postRes = execute([durlBin, "-d", "hello_durl_payload", h1Url]);
    assert(postRes.status == 0);
    assert(postRes.output.canFind("POST OK: hello_durl_payload"));

    // Custom header with -H and include headers with -i
    auto incRes = execute([durlBin, "-i", "-H", "X-Custom: SlateTest", h1Url]);
    assert(incRes.status == 0);
    assert(incRes.output.canFind("HTTP/1.1 200"));
    assert(incRes.output.canFind("Content-Type: text/plain"));
    assert(incRes.output.canFind("HTTP1 OK"));

    // HEAD with -I
    auto headRes = execute([durlBin, "-I", h1Url]);
    assert(headRes.status == 0);
    assert(headRes.output.canFind("HTTP/1.1 200"));
    assert(!headRes.output.canFind("HTTP1 OK"), "HEAD response must not include body");

    // Output to file with -o
    string outPath = format("/tmp/slate_durl_test_out_%d.txt", getpid());
    scope (exit)
    {
        if (exists(outPath))
            remove(outPath);
    }
    auto fileRes = execute([durlBin, "-o", outPath, h1Url]);
    assert(fileRes.status == 0);
    assert(exists(outPath));
    assert(readText(outPath) == "HTTP1 OK");

    // Redirect loop with -L and --max-redirs
    auto redirRes = execute([durlBin, "-L", "--max-redirs", "3", redirUrl]);
    assert(redirRes.status != 0, "Redirect loop must exit with non-zero status");
    assert(redirRes.output.canFind("CURLE_TOO_MANY_REDIRECTS") || redirRes.output.canFind("47"));

    // Zero-allocation --nogc mode
    auto nogcRes = execute([durlBin, "--nogc", h1Url]);
    assert(nogcRes.status == 0);
    assert(nogcRes.output.canFind("HTTP1 OK"));

    // Parallel requests with multiple URLs
    auto parallelRes = execute([durlBin, "--parallel", h1Url, h1Url]);
    assert(parallelRes.status == 0);
    assert(parallelRes.output.canFind("HTTP1 OK"));

    // 3. Test against H2LoopbackServer
    auto h2Server = new H2LoopbackServer();
    scope (exit)
        h2Server.close();

    string h2Url1 = format("http://127.0.0.1:%d/h2_1", h2Server.port);
    string h2Url2 = format("http://127.0.0.1:%d/h2_2", h2Server.port);

    auto h2Res = execute([durlBin, "--http2-prior-knowledge", h2Url1]);
    assert(h2Res.status == 0);
    assert(h2Res.output.canFind("H2 OK"));

    auto h2ParRes = execute([
        durlBin, "--http2-prior-knowledge", "--parallel", h2Url1, h2Url2
    ]);
    assert(h2ParRes.status == 0);
    assert(h2ParRes.output.canFind("H2 OK"));

    // 4. Test against Python TLS self-signed server
    string certPath = format("/tmp/slate_durl_tls_cert_%d.pem", getpid());
    string keyPath = format("/tmp/slate_durl_tls_key_%d.pem", getpid());

    execute([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout",
        keyPath, "-out", certPath, "-days", "1", "-subj", "/CN=127.0.0.1"
    ]);
    scope (exit)
    {
        if (exists(certPath))
            remove(certPath);
        if (exists(keyPath))
            remove(keyPath);
    }

    string pyScript = format(`
import ssl, http.server, socketserver, threading, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', '6')
        self.end_headers()
        self.wfile.write(b'TLS OK')
    def log_message(self, format, *args): pass

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile='%s', keyfile='%s')

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    def __init__(self, addr, handler, ssl_ctx):
        super().__init__(addr, handler)
        self.ssl_ctx = ssl_ctx
    def get_request(self):
        sock, addr = super().get_request()
        try:
            return self.ssl_ctx.wrap_socket(sock, server_side=True), addr
        except Exception:
            return sock, addr

server = Server(('127.0.0.1', 0), Handler, ctx)
sys.stdout.write(f'{server.server_address[1]}\n')
sys.stdout.flush()
server.serve_forever()
`, certPath, keyPath);

    import std.process : Pipe, pipeProcess, Redirect, Pid;

    void safeKill(Pid p)
    {
        try
        {
            kill(p);
            wait(p);
        }
        catch (Exception)
        {
        }
    }

    auto pipes = pipeProcess(["python3", "-c", pyScript], Redirect.stdout | Redirect.stderr);
    scope (exit)
        safeKill(pipes.pid);

    import std.string : strip;
    import std.conv : to;

    string portStr = pipes.stdout.readln().strip();
    ushort tlsPort = to!ushort(portStr);
    string httpsUrl = format("https://127.0.0.1:%d/", tlsPort);

    // 4a. Default fails without -k due to untrusted self-signed certificate
    auto insecFail = execute([durlBin, httpsUrl]);
    assert(insecFail.status != 0, "Default TLS verification must fail for untrusted certificate");

    // 4b. Succeeds with -k (insecure opt-in)
    auto insecOk = execute([durlBin, "-k", httpsUrl]);
    assert(insecOk.status == 0, "durl -k must succeed on self-signed cert");
    assert(insecOk.output.canFind("TLS OK"));

    // 4c. Succeeds with --cacert pointing to certPath
    auto cacertOk = execute([durlBin, "--cacert", certPath, httpsUrl]);
    assert(cacertOk.status == 0, "durl --cacert must succeed with valid CA bundle");
    assert(cacertOk.output.canFind("TLS OK"));

    // 4d. Fails with bad --cacert
    auto badCa = execute([
        durlBin, "--cacert", "/nonexistent/bundle.pem", httpsUrl
    ]);
    assert(badCa.status != 0, "durl --cacert with missing bundle must fail fast");
    assert(badCa.output.canFind("CURLE_SSL_CACERT") || badCa.output.canFind("77"));
}
