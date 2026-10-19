module slate.http.client_test;

import slate.http.client;
import slate.http.request;
import slate.http.response;
import slate.http.error;

import slate.http.test_server : HttpStubServer;
import slate.http.version_ : hasHttp3;
import slate.http.multi : CancellationToken;

// Spec: @nogc callbacks + no GC delegates across C ABI (UB-4, UN-1)
// Scenario: TC-03 hot path is nogc
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.request;
/// import slate.http.response;
/// @nogc void runRequest(Client* client, const ref Request req) {
///     ubyte[1024] buf;
///     ubyte[128] chunkBuf;
///     auto res = client.perform(req, buf[]);
///     foreach (chunk; res.byChunk(chunkBuf[])) {
///         // consume chunks under @nogc
///     }
/// }
/// ---
unittest
{
    auto stub = new HttpStubServer("Hello Nogc World!");
    scope (exit)
        stub.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/test", stub.port);
    auto req = Request.get(url);

    auto client = Client.create();

    @nogc void performAndIterate(Client* c, const ref Request r)
    {
        ubyte[256] bodyBuf;
        ubyte[4] chunkBuf;
        auto res = c.perform(r, bodyBuf[]);
        assert(res.status == 200);
        assert(res.bodyData == "Hello Nogc World!");

        size_t total = 0;
        foreach (chunk; res.byChunk(chunkBuf[]))
        {
            total += chunk.length;
        }
        assert(total == res.bodyData.length);
    }

    performAndIterate(&client, req);
}

// Spec: RFC 9110 framing and chunked streaming transfer (EV-3a)
// Scenario: TC-04a streaming single body
/// Example:
/// ---
/// import std.format : format;
///
/// static extern (C) void countChunk(const(ubyte)[] chunk, void* ctx) @nogc nothrow
/// {
///     *cast(size_t*) ctx += chunk.length;
/// }
///
/// auto stub = new HttpStubServer("0123456789ABCDEF");
/// scope (exit)
///     stub.close();
/// size_t totalBytes = 0;
/// auto client = Client.create();
/// auto res = client.performStream(Request.get(format("http://127.0.0.1:%d/stream", stub.port)),
///         &countChunk, &totalBytes);
/// assert(res.status == 200 && totalBytes == 16);   // the chunks arrived in the callback
/// ---
unittest
{
    import std.array : replicate;

    string bigBody = "0123456789ABCDEF".replicate(2048); // 32 KB payload
    auto stub = new HttpStubServer(bigBody);
    scope (exit)
        stub.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/stream", stub.port);
    auto req = Request.get(url);

    auto client = Client.create();

    struct StreamState
    {
        size_t chunkCount;
        size_t totalBytes;
    }

    StreamState state;

    extern (C) void onChunkReceived(const(ubyte)[] chunk, void* ctx) @nogc nothrow
    {
        auto s = cast(StreamState*) ctx;
        s.chunkCount++;
        s.totalBytes += chunk.length;
    }

    auto res = client.performStream(req, &onChunkReceived, &state);
    assert(res.status == 200);
    assert(state.totalBytes == 32768);
    assert(state.chunkCount >= 1, "Transfer should receive streamed chunks");
}

// Spec: handle reuse without method pollution across transfers (CRIT-1)
/// Example:
/// ---
/// import std.algorithm : startsWith;
/// import std.format : format;
///
/// auto server = new HttpStubServer("ok");
/// scope (exit)
///     server.close();
/// const url = format("http://127.0.0.1:%d/api", server.port);
/// auto client = Client.create();
/// // a PUT followed by a GET on the same client: the method of the first does not leak into the second
/// client.perform(Request.put(url).withBody("data"));
/// auto res = client.perform(Request.get(url));
/// assert(res.status == 200);
/// synchronized (server)
///     assert(server.rawRequests[1].startsWith("GET /api"));
/// ---
unittest
{
    auto server = new HttpStubServer("method-test-ok");
    scope (exit)
        server.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/method", server.port);

    auto client = Client.create();

    // 1. Perform PUT with payload
    auto putRes = client.perform(Request.put(url).withBody("test-put-body"));
    assert(putRes.status == 200);
    assert(server.lastMethod == "PUT", "Expected server to receive PUT");

    // 2. Perform GET on the same client handle - MUST NOT send PUT!
    auto getRes = client.perform(Request.get(url));
    assert(getRes.status == 200);
    assert(server.lastMethod == "GET",
            "Reused handle must send GET, not previous PUT (CRIT-1): actual=" ~ server.lastMethod);
}

// Spec: EV-2b fast failure on h3Only without HTTP/3 support (ST-2)
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.request;
/// import slate.http.version_;
/// import slate.http.error;
/// if (!hasHttp3()) {
///     auto client = Client.create();
///     try {
///         client.perform(Request.get("http://127.0.0.1:1/").withVersion(HttpVersion.h3Only));
///     } catch (CurlException e) {
///         assert(e.code == CurlCode.CURLE_NOT_BUILT_IN);
///     }
/// }
/// ---
unittest
{
    if (!hasHttp3())
    {
        auto client = Client.create();
        bool caught = false;
        try
        {
            client.perform(Request.get("http://127.0.0.1:1/").withVersion(HttpVersion.h3Only));
        }
        catch (CurlException e)
        {
            caught = true;
            assert(e.code == CurlCode.CURLE_NOT_BUILT_IN,
                    "Requesting h3Only without HTTP/3 support must fail with CURLE_NOT_BUILT_IN (EV-2b, ST-2)");
        }
        assert(caught, "h3Only must throw when H3 is absent");
    }
}

// Spec: RFC 9110 Section 15 Response parsing and Client convenience facade (EV-1)
/// Example:
/// ---
/// import std.format : format;
///
/// auto server = new HttpStubServer(`{"status":"ok"}`);
/// scope (exit)
///     server.close();
/// auto client = Client.create();
/// auto res = client.get(format("http://127.0.0.1:%d/api", server.port));
/// assert(res.status == 200);
/// assert(res.hasHeader("content-type"));
/// assert(res.bodyAsString() == `{"status":"ok"}`);
/// ---
unittest
{
    auto server = new HttpStubServer(`{"status":"ok"}`);
    scope (exit)
        server.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/dynamic", server.port);

    auto client = Client.create();
    auto res = client.get(url);

    assert(res.status == 200);
    assert(res.hasHeader("content-type"));
    assert(res.header("Content-Type") == "text/plain");
    assert(res.bodyAsString() == `{"status":"ok"}`);
}

// Spec: RFC 9110 keep-alive connection reuse and lastNumConnects (ST-1)
// Scenario: TC-02 easy handle reuse
/// Example:
/// ---
/// import std.format : format;
///
/// auto stub = new HttpStubServer("Client KeepAlive OK", true);
/// scope (exit)
///     stub.close();
/// const url = format("http://127.0.0.1:%d/", stub.port);
/// auto client = Client.create();
/// auto res1 = client.get(url);
/// auto res2 = client.get(url);
/// assert(client.lastNumConnects() == 0);           // the second request reused the connection
/// ---
unittest
{
    // Spec: verify sequential Client reuse preserves keep-alive and numConnects == 0
    auto stub = new HttpStubServer("Client KeepAlive OK", true);
    scope (exit)
        stub.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/reuse_client", stub.port);

    auto client = Client.create();

    // 1. First GET - connects once
    auto res1 = client.get(url);
    assert(res1.status == 200);
    assert(client.lastNumConnects() == 1, "First Client transfer must make 1 connection");

    // 2. Second GET - reuses connection
    auto res2 = client.get(url);
    assert(res2.status == 200);
    assert(client.lastNumConnects() == 0, "Second Client transfer must reuse connection (ST-1)");
}

// Spec: libcurl progress callback cancellation for Client (EV-4)
// Scenario: TC-07 cancellation on Client
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.multi : CancellationToken;
/// import slate.http.error;
/// auto client = Client.create();
/// CancellationToken cancel;
/// cancel.cancel();
/// try {
///     client.get("http://example.com/slow", &cancel);
/// } catch (CancelledException e) {
///     assert(e.code == CurlCode.CURLE_ABORTED_BY_CALLBACK);
/// }
/// ---
unittest
{
    // Spec: verify in-flight cancellation terminates Client transfer promptly
    auto stub = new HttpStubServer("Delayed client", false, 500);
    scope (exit)
        stub.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/slow_client", stub.port);

    auto client = Client.create();
    CancellationToken cancel;

    import core.thread : Thread;
    import core.time : dur;

    auto cancelThread = new Thread({
        Thread.sleep(dur!"msecs"(50));
        cancel.cancel();
    });
    cancelThread.start();

    bool caught = false;
    try
    {
        client.get(url, &cancel);
    }
    catch (CancelledException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_ABORTED_BY_CALLBACK);
    }
    cancelThread.join();

    assert(caught, "Client transfer must be aborted via CancelledException (EV-4)");
}

// Spec: RFC 9110 Section 6.3 Large Header Fields (>512 bytes)
// Scenario: TC-08 large header preservation without truncation
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.request;
/// import std.array : replicate;
///
/// auto client = Client.create();
/// string bigToken = "Bearer " ~ "x".replicate(700);
/// auto req = Request.get("http://example.com/").withHeader("Authorization", bigToken);
/// auto res = client.perform(req);
/// ---
unittest
{
    // Spec: verify headers >512 bytes (such as large JWT bearer tokens) are not silently dropped
    import std.array : replicate;
    import std.algorithm.searching : canFind;

    auto server = new HttpStubServer("header-ok");
    scope (exit)
        server.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/large_header", server.port);

    string tokenPayload = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.".replicate(20); // > 700 bytes
    string authHeaderVal = "Bearer " ~ tokenPayload;
    assert(authHeaderVal.length > 600, "Header value must exceed 600 bytes");

    auto client = Client.create();
    auto req = Request.get(url).withHeader("Authorization", authHeaderVal);
    auto res = client.perform(req);

    assert(res.status == 200);
    assert(server.lastRawRequest.canFind("Authorization: " ~ authHeaderVal),
            "Server must receive complete untruncated >600-byte header");
}

/// Example:
/// ---
/// import std.format : format;
///
/// auto server = new HttpStubServer("x");
/// scope (exit)
///     server.close();
/// server.statusCode = 600;
/// const url = format("http://127.0.0.1:%d/weird", server.port);
/// auto client = Client.create();
/// try
///     client.perform(Request.get(url));            // throws, instead of tripping Response's invariant
/// catch (CurlException e)
///     assert(e.code == CurlCode.CURLE_WEIRD_SERVER_REPLY);
/// ---
// Spec: RFC 9110 Section 15 - "All valid status codes are within the range of 100 to 599,
// inclusive." A status outside that range is a malformed reply: every perform variant throws
// CURLE_WEIRD_SERVER_REPLY before a Response is built (R-24, W9, D8)
unittest
{
    import std.format : format;

    auto server = new HttpStubServer("body");
    scope (exit)
        server.close();
    server.statusCode = 600;
    const url = format("http://127.0.0.1:%d/weird", server.port);
    auto client = Client.create();

    bool caught = false;
    try
        client.perform(Request.get(url));
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_WEIRD_SERVER_REPLY);
    }
    assert(caught, "GC perform must reject status 600");

    ubyte[64] buf;
    caught = false;
    try
        client.perform(Request.get(url), buf[]);
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_WEIRD_SERVER_REPLY);
    }
    assert(caught, "buffer perform must reject status 600");

    static extern (C) void ignoreChunk(const(ubyte)[] chunk, void* ctx) @nogc nothrow
    {
    }

    caught = false;
    try
        client.performStream(Request.get(url), &ignoreChunk);
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_WEIRD_SERVER_REPLY);
    }
    assert(caught, "stream perform must reject status 600");

    assertValidStatus();
}

private void assertValidStatus()
{
    assert(validatedStatus(100) == 100 && validatedStatus(599) == 599);
    foreach (bad; [-1L, 0, 99, 600, 1000])
    {
        bool caught = false;
        try
            validatedStatus(bad);
        catch (CurlException e)
        {
            caught = true;
            assert(e.code == CurlCode.CURLE_WEIRD_SERVER_REPLY);
        }
        assert(caught);
    }
}

/// Example:
/// ---
/// import std.format : format;
///
/// auto server = new HttpStubServer("0123456789abcdef0123456789abcdef");
/// scope (exit)
///     server.close();
/// const url = format("http://127.0.0.1:%d/big", server.port);
///
/// ClientConfig cfg;
/// cfg.maxResponseBytes = 8;               // the body is larger than the cap
/// auto client = Client.create(cfg);
/// try
///     client.perform(Request.get(url));
/// catch (CurlException e)
///     assert(e.code == CurlCode.CURLE_FILESIZE_EXCEEDED);   // not libcurl's CURLE_WRITE_ERROR
/// ---
// Spec: libcurl CURLOPT_WRITEFUNCTION - a callback that returns less than it was given aborts the
// transfer with CURLE_WRITE_ERROR; the client enforces its own size cap there, so the cap (or an
// out-of-memory condition) is the real cause and must be the reported error (R-25, W10)
unittest
{
    import std.format : format;

    auto server = new HttpStubServer("0123456789abcdef0123456789abcdef");
    scope (exit)
        server.close();
    const url = format("http://127.0.0.1:%d/big", server.port);

    ClientConfig cfg;
    cfg.maxResponseBytes = 8;
    auto client = Client.create(cfg);
    bool caught = false;
    try
        client.perform(Request.get(url));
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_FILESIZE_EXCEEDED);
    }
    assert(caught, "response above maxResponseBytes");

    ubyte[8] small;
    auto plain = Client.create();
    caught = false;
    try
        plain.perform(Request.get(url), small[]);
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_FILESIZE_EXCEEDED);
    }
    assert(caught, "response above the caller's buffer");
}

/// Example:
/// ---
/// import std.format : format;
///
/// auto server = new HttpStubServer("done");
/// scope (exit)
///     server.close();
/// server.redirectStatus = 303;
/// const url = format("http://127.0.0.1:%d/r", server.port);
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// auto client = Client.create(cfg);
/// client.perform(Request.delete_(url));            // DELETE /r -> 303 -> GET /final
/// assert(server.requestLines[0] == "DELETE /r" && server.requestLines[1] == "GET /final");
/// ---
// Spec: RFC 9110 Section 15.4.4 - for a 303 "A user agent can perform a retrieval request
// targeting that URI (a GET or HEAD request if using HTTP)"; Section 15.4.2 - for 301 "a user
// agent MAY change the request method from POST to GET", every other method is kept. libcurl
// keeps a CUSTOMREQUEST on every hop, so a 303 must clear it (R-26, E8)
unittest
{
    import std.format : format;

    foreach (status; [301, 302, 303, 307, 308])
    {
        foreach (method; ["DELETE", "PATCH", "PUT"])
        {
            auto server = new HttpStubServer("done");
            scope (exit)
                server.close();
            server.redirectStatus = status;
            const url = format("http://127.0.0.1:%d/r", server.port);

            ClientConfig cfg;
            cfg.followRedirects = true;
            auto client = Client.create(cfg);
            const Request req = method == "DELETE" ? Request.delete_(url) : method == "PATCH"
                ? Request.patch(url, cast(const(ubyte)[]) "p") : Request.put(url,
                        cast(const(ubyte)[]) "p");
            const res = client.perform(req);
            assert(res.status == 200);
            assert(server.requestLines.length == 2, "one redirect hop");
            assert(server.requestLines[0] == method ~ " /r");
            const expected = status == 303 ? "GET /final" : method ~ " /final";
            assert(server.requestLines[1] == expected, format("%s after %d: sent '%s'",
                    method, status, server.requestLines[1]));

            // Handle reuse: the next plain request is not polluted by the redirect.
            const again = client.perform(Request.get(format("http://127.0.0.1:%d/final",
                    server.port)));
            assert(again.status == 200);
            assert(server.requestLines[$ - 1] == "GET /final");
        }
    }
}

/// Example:
/// ---
/// import std.format : format;
///
/// auto server = new HttpStubServer("done");
/// scope (exit)
///     server.close();
/// server.redirectStatus = 307;
/// server.redirectAlways = true;                    // every hop redirects again
/// const url = format("http://127.0.0.1:%d/r", server.port);
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// cfg.maxRedirects = 2;
/// auto client = Client.create(cfg);
/// try
///     client.perform(Request.delete_(url));
/// catch (CurlException e)
///     assert(e.code == CurlCode.CURLE_TOO_MANY_REDIRECTS);   // after 2 hops
/// ---
// Spec: RFC 9110 Section 15.4 "A client SHOULD detect and intervene in cyclical redirections" - a
// followed redirect chain of a custom method stops at maxRedirects, in the GC, buffer and stream
// performs alike (R-26)
unittest
{
    import std.format : format;

    foreach (variant; 0 .. 3)
    {
        auto server = new HttpStubServer("done");
        scope (exit)
            server.close();
        server.redirectStatus = 307;
        server.redirectAlways = true;
        const url = format("http://127.0.0.1:%d/r", server.port);
        ClientConfig cfg;
        cfg.followRedirects = true;
        cfg.maxRedirects = 2;
        auto client = Client.create(cfg);
        bool caught = false;
        try
        {
            ubyte[64] buf;
            final switch (variant)
            {
            case 0:
                client.perform(Request.delete_(url));
                break;
            case 1:
                client.perform(Request.delete_(url), buf[]);
                break;
            case 2:
                client.performStream(Request.delete_(url), &ignoreChunk);
                break;
            }
        }
        catch (CurlException e)
        {
            caught = e.code == CurlCode.CURLE_TOO_MANY_REDIRECTS;
        }
        assert(caught, "variant must stop with CURLE_TOO_MANY_REDIRECTS");
        synchronized (server)
            assert(server.requestLines.length == 3, "the request plus exactly maxRedirects hops");
    }
}

/// Example:
/// ---
/// import std.format : format;
/// import std.string : indexOf;
///
/// auto origin = new HttpStubServer("a");
/// auto other = new HttpStubServer("b");
/// scope (exit)
/// {
///     origin.close();
///     other.close();
/// }
/// origin.redirectStatus = 307;
/// origin.redirectLocation = format("http://127.0.0.1:%d/final", other.port);
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// auto client = Client.create(cfg);
/// const url = format("http://127.0.0.1:%d/r", origin.port);
/// assert(client.perform(Request.delete_(url).withHeader("Authorization", "Bearer s3cret")).status == 200);
/// // the other origin received the redirected request, but never Authorization
/// synchronized (other)
///     assert(other.rawRequests.length == 1 && other.rawRequests[0].indexOf("uthorization") < 0);
/// ---
// Spec: RFC 9110 Section 16.3.2 "If the field ought to be removed when automatically redirecting
// a request due to security concerns (see Section 15.4)." and Section 11.6.2 "The "Authorization"
// header field allows a user agent to authenticate itself with an origin server" - credentials
// belong to the origin they were issued for and are dropped on a redirect to another origin;
// same-origin hops keep them (R-26)
unittest
{
    import std.algorithm : canFind;
    import std.format : format;
    import std.uni : toLower;

    auto origin = new HttpStubServer("a");
    auto other = new HttpStubServer("b");
    scope (exit)
    {
        origin.close();
        other.close();
    }
    origin.redirectStatus = 307;
    origin.redirectLocation = format("http://127.0.0.1:%d/final", other.port);

    ClientConfig cfg;
    cfg.followRedirects = true;
    auto client = Client.create(cfg);
    const req = Request.delete_(format("http://127.0.0.1:%d/r", origin.port)).withHeader("Authorization",
            "Bearer s3cret").withHeader("Cookie", "sid=1").withHeader("X-Keep", "yes");
    assert(client.perform(req).status == 200);
    synchronized (origin)
    {
        assert(origin.rawRequests.length == 1);
        assert(origin.rawRequests[0].toLower.canFind("authorization: bearer s3cret"));
    }
    synchronized (other)
    {
        assert(other.rawRequests.length == 1);
        const raw = other.rawRequests[0].toLower;
        assert(raw.startsWith2("delete /final"), "307 keeps the method");
        assert(!raw.canFind("authorization"), "credentials must not reach another origin");
        assert(!raw.canFind("cookie"));
        assert(raw.canFind("x-keep: yes"), "other headers are kept");
    }

    // Same origin: the credentials stay.
    auto same = new HttpStubServer("c");
    scope (exit)
        same.close();
    same.redirectStatus = 307;
    assert(client.perform(Request.delete_(format("http://127.0.0.1:%d/r",
            same.port)).withHeader("Authorization", "Bearer s3cret")).status == 200);
    synchronized (same)
    {
        assert(same.rawRequests.length == 2);
        assert(same.rawRequests[1].toLower.canFind("authorization: bearer s3cret"));
    }
}

private extern (C) void ignoreChunk(const(ubyte)[] chunk, void* userdata) @nogc nothrow
{
}

private extern (C) void countChunk(const(ubyte)[] chunk, void* userdata) @nogc nothrow
{
    *cast(size_t*) userdata += chunk.length;
}

private bool startsWith2(const(char)[] s, const(char)[] prefix) @safe pure nothrow @nogc
{
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

/// Example:
/// ---
/// import std.format : format;
///
/// auto server = new HttpStubServer("done");
/// scope (exit)
///     server.close();
/// server.redirectStatus = 302;
/// server.redirectLocation = "file:///etc/passwd";  // only http and https are followed
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// auto client = Client.create(cfg);
/// const url = format("http://127.0.0.1:%d/r", server.port);
/// try
///     client.perform(Request.delete_(url));
/// catch (CurlException e)
///     assert(e.code == CurlCode.CURLE_UNSUPPORTED_PROTOCOL);
/// ---
// Spec: RFC 9110 Section 15.4 "A client SHOULD detect and intervene in cyclical redirections" is
// the loop rule; for the target scheme the client policy "http,https" only (F-63) applies to
// followed redirects as well - a redirect to file:// or ftp:// is rejected, no request is made
// for it (R-26)
unittest
{
    import std.format : format;

    foreach (target; ["file:///etc/passwd", "ftp://127.0.0.1/x", "/final"])
    {
        auto server = new HttpStubServer("done");
        scope (exit)
            server.close();
        server.redirectStatus = 302;
        server.redirectLocation = target;
        ClientConfig cfg;
        cfg.followRedirects = true;
        auto client = Client.create(cfg);
        bool rejected = false;
        try
            client.perform(Request.put(format("http://127.0.0.1:%d/r",
                    server.port), cast(const(ubyte)[]) "p"));
        catch (CurlException e)
            rejected = e.code == CurlCode.CURLE_UNSUPPORTED_PROTOCOL;
        if (target == "/final")
            assert(!rejected, "a relative redirect is followed");
        else
            assert(rejected, "only http and https are followed: " ~ target);
    }
}

/// Example:
/// ---
/// import std.format : format;
///
/// auto server = new HttpStubServer("final-body");
/// scope (exit)
///     server.close();
/// server.redirectStatus = 303;
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// auto client = Client.create(cfg);
/// const url = format("http://127.0.0.1:%d/r", server.port);
/// ubyte[64] buf;
/// const res = client.perform(Request.patch(url, cast(const(ubyte)[]) "p"), buf[]);
/// assert(res.status == 200 && res.bodyData == cast(const(ubyte)[]) "final-body");   // 303 -> GET /final
/// size_t total;
/// client.performStream(Request.put(url, cast(const(ubyte)[]) "p"), &countChunk, &total);
/// assert(total == 10);                             // only the final body was delivered
/// ---
// Spec: RFC 9110 Section 15.4.4 - for a 303 "A user agent can perform a retrieval request targeting
// that URI (a GET or HEAD request if using HTTP)"; the response of the redirect itself is not the
// result: the buffer and stream performs deliver only the final body (R-26, E8)
unittest
{
    import std.format : format;

    auto server = new HttpStubServer("final-body");
    scope (exit)
        server.close();
    server.redirectStatus = 303;
    ClientConfig cfg;
    cfg.followRedirects = true;
    auto client = Client.create(cfg);
    const url = format("http://127.0.0.1:%d/r", server.port);

    ubyte[64] buf;
    const res = client.perform(Request.patch(url, cast(const(ubyte)[]) "p"), buf[]);
    assert(res.status == 200 && res.bodyData.length == 10
            && res.bodyData == cast(const(ubyte)[]) "final-body");
    synchronized (server)
        assert(server.requestLines[$ - 1] == "GET /final");

    size_t total = 0;
    const sres = client.performStream(Request.put(url,
            cast(const(ubyte)[]) "p"), &countChunk, &total);
    assert(sres.status == 200 && total == 10);
    synchronized (server)
        assert(server.requestLines[$ - 1] == "GET /final");
}

/// Example:
/// ---
/// import slate.http.c_bind;
///
/// CURL* h = curl_easy_init();
/// scope (exit)
///     curl_easy_cleanup(h);
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// const(char)* cUrl = "http://127.0.0.1:1/x\0".ptr;
/// curl_slist* list = null;
/// const del = Request.delete_("http://127.0.0.1:1/x");
/// try
///     applyRequestOptions(h, cfg, del, cUrl, list);   // throws: nobody follows manually
/// catch (CurlException e)
///     assert(e.code == CurlCode.CURLE_BAD_FUNCTION_ARGUMENT);
/// applyRequestOptions(h, cfg, del, cUrl, list, null, 0, HOP_MANUAL);   // accepted
/// if (list !is null)
///     curl_slist_free_all(list);
/// ---
// Spec: RFC 9110 Section 15.4.4 - a 303 turns the follow-up into a GET, which libcurl cannot do for
// a custom method. Only `Client` follows such redirects itself; the multi and background-task
// paths, which use `applyRequestOptions` without doing so, reject the combination with
// CURLE_BAD_FUNCTION_ARGUMENT instead of silently sending the wrong method (R-26)
unittest
{
    import slate.http.c_bind;

    CURL* h = curl_easy_init();
    assert(h !is null);
    scope (exit)
        curl_easy_cleanup(h);
    ClientConfig cfg;
    cfg.followRedirects = true;
    const(char)* cUrl = "http://127.0.0.1:1/x\0".ptr;
    curl_slist* list = null;
    scope (exit)
        if (list !is null)
            curl_slist_free_all(list);

    const del = Request.delete_("http://127.0.0.1:1/x");
    const post = Request.post("http://127.0.0.1:1/x");
    bool rejected = false;
    try
        applyRequestOptions(h, cfg, del, cUrl, list);
    catch (CurlException e)
        rejected = e.code == CurlCode.CURLE_BAD_FUNCTION_ARGUMENT;
    assert(rejected, "custom method + followRedirects needs the manual follower");

    // Accepted when the caller follows itself, with redirects off, or for a method libcurl handles.
    applyRequestOptions(h, cfg, del, cUrl, list, null, 0, HOP_MANUAL);
    if (list !is null)
    {
        curl_slist_free_all(list);
        list = null;
    }
    applyRequestOptions(h, cfg, post, cUrl, list);
    cfg.followRedirects = false;
    applyRequestOptions(h, cfg, del, cUrl, list);
}

/// Example:
/// ---
/// import std.algorithm : canFind;
/// import std.format : format;
/// import std.uni : toLower;
///
/// auto origin = new HttpStubServer("a");
/// auto other = new HttpStubServer("b");
/// scope (exit)
/// {
///     origin.close();
///     other.close();
/// }
/// origin.redirectStatus = 307;
/// origin.redirectLocation = format("http://127.0.0.1:%d/final", other.port);
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// auto client = Client.create(cfg);
///
/// // A 307 to another origin: the only request header, Authorization, is dropped for the hop.
/// const req = Request.delete_(format("http://127.0.0.1:%d/r", origin.port)).withHeader("Authorization", "Bearer s3cret");
/// assert(client.perform(req).status == 200);
/// synchronized (other)
///     assert(!other.rawRequests[0].toLower.canFind("authorization"));
/// ---
// Spec: RFC 9110 Section 11.6.2 "The "Authorization" header field allows a user agent to
// authenticate itself with an origin server" - a hop to another origin that strips every request
// header must leave the handle with an empty list, not with the freed one of the previous hop
// (use-after-free) nor with the old credentials (R-26)
unittest
{
    import std.algorithm : canFind;
    import std.format : format;
    import std.uni : toLower;

    auto origin = new HttpStubServer("a");
    auto other = new HttpStubServer("b");
    scope (exit)
    {
        origin.close();
        other.close();
    }
    origin.redirectStatus = 307;
    origin.redirectLocation = format("http://127.0.0.1:%d/final", other.port);
    ClientConfig cfg;
    cfg.followRedirects = true;
    auto client = Client.create(cfg);
    foreach (variant; 0 .. 3)
    {
        const req = Request.delete_(format("http://127.0.0.1:%d/r",
                origin.port)).withHeader("Authorization", "Bearer s3cret");
        ubyte[64] buf;
        size_t total;
        final switch (variant)
        {
        case 0:
            assert(client.perform(req).status == 200);
            break;
        case 1:
            assert(client.perform(req, buf[]).status == 200);
            break;
        case 2:
            assert(client.performStream(req, &countChunk, &total).status == 200);
            break;
        }
    }
    synchronized (origin)
    {
        assert(origin.rawRequests.length == 3);
        foreach (raw; origin.rawRequests)
            assert(raw.toLower.canFind("authorization: bearer s3cret"));
    }
    synchronized (other)
    {
        assert(other.rawRequests.length == 3);
        foreach (raw; other.rawRequests)
            assert(!raw.toLower.canFind("authorization"), "stale credentials must not be resent");
    }
}

/// Example:
/// ---
/// import std.algorithm : canFind, startsWith;
/// import std.format : format;
/// import std.uni : toLower;
///
/// auto server = new HttpStubServer("done");
/// scope (exit)
///     server.close();
/// server.redirectStatus = 303;
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// auto client = Client.create(cfg);
///
/// const req = Request.put(format("http://127.0.0.1:%d/r", server.port), cast(const(ubyte)[]) "payload")
///     .withHeader("Content-Type", "text/plain");
/// assert(client.perform(req).status == 200);
/// synchronized (server)
/// {
///     assert(server.rawRequests[1].startsWith("GET /final"));   // after a 303: a GET ...
///     assert(!server.rawRequests[1].toLower.canFind("content-type"));   // ... without content headers
/// }
/// ---
// Spec: RFC 9110 Section 15.4.4 - after a 303 the follow-up is a GET without content; the
// content headers go with the body. A hop whose list is empty afterwards must not leave the handle
// on the freed list of the previous hop (R-26)
unittest
{
    import std.algorithm : canFind;
    import std.format : format;
    import std.uni : toLower;

    auto server = new HttpStubServer("done");
    scope (exit)
        server.close();
    server.redirectStatus = 303;
    ClientConfig cfg;
    cfg.followRedirects = true;
    auto client = Client.create(cfg);
    const req = Request.put(format("http://127.0.0.1:%d/r", server.port),
            cast(const(ubyte)[]) "payload").withHeader("Content-Type", "text/plain");
    assert(client.perform(req).status == 200);
    synchronized (server)
    {
        assert(server.rawRequests.length == 2);
        assert(server.rawRequests[0].toLower.canFind("content-type: text/plain"));
        assert(server.rawRequests[1].startsWith2("GET /final"));
        assert(!server.rawRequests[1].toLower.canFind("content-type"));
        assert(!server.rawRequests[1].toLower.canFind("content-length: 7"));
    }
}

/// Example:
/// ---
/// import std.array : replicate;
/// import std.format : format;
///
/// auto server = new HttpStubServer("final-body");
/// scope (exit)
///     server.close();
/// server.redirectStatus = 307;
/// server.redirectBody = "r".replicate(1024);   // the redirect response carries 1 KiB
/// const url = format("http://127.0.0.1:%d/r", server.port);
///
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// cfg.maxResponseBytes = 64;
/// auto client = Client.create(cfg);
/// ubyte[64] buf;                                // the caller's buffer holds only 64 bytes
/// const res = client.perform(Request.delete_(url), buf[]);
/// assert(res.status == 200 && res.bodyData == cast(const(ubyte)[]) "final-body");
/// ---
// Spec: RFC 9110 Section 15.4 - the response of a followed redirect is not the result; its body is
// neither written into the caller's buffer nor counted toward maxResponseBytes, as in the stream
// path and in libcurl (R-26)
unittest
{
    import std.array : replicate;
    import std.format : format;

    auto server = new HttpStubServer("final-body");
    scope (exit)
        server.close();
    server.redirectStatus = 307;
    server.redirectBody = "r".replicate(1024);
    const url = format("http://127.0.0.1:%d/r", server.port);

    ClientConfig cfg;
    cfg.followRedirects = true;
    cfg.maxResponseBytes = 64;
    auto client = Client.create(cfg);

    ubyte[64] buf;
    const res = client.perform(Request.delete_(url), buf[]);
    assert(res.status == 200 && res.bodyData == cast(const(ubyte)[]) "final-body");

    const gc = client.perform(Request.delete_(url));
    assert(gc.status == 200 && gc.bodyData == cast(const(ubyte)[]) "final-body");

    // The final body is still limited.
    server.redirectBody = "";
    auto big = new HttpStubServer("x".replicate(1024));
    scope (exit)
        big.close();
    bool caught;
    try
        client.perform(Request.delete_(format("http://127.0.0.1:%d/z", big.port)));
    catch (CurlException e)
        caught = e.code == CurlCode.CURLE_FILESIZE_EXCEEDED;
    assert(caught);
}

/// Example:
/// ---
/// import std.format : format;
///
/// auto server = new HttpStubServer("done");
/// scope (exit)
///     server.close();
/// server.redirectStatus = 307;
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// cfg.maxRedirects = -1;                        // unlimited, like CURLOPT_MAXREDIRS -1
/// auto client = Client.create(cfg);
/// assert(client.perform(Request.delete_(format("http://127.0.0.1:%d/hop60", server.port))).status == 200);
///
/// cfg.maxRedirects = 0;                         // 0 refuses the first hop
/// auto strict = Client.create(cfg);
/// try
///     strict.perform(Request.delete_(format("http://127.0.0.1:%d/hop1", server.port)));
/// catch (CurlException e)
///     assert(e.code == CurlCode.CURLE_TOO_MANY_REDIRECTS);
/// ---
// Spec: RFC 9110 Section 15.4 "A client SHOULD detect and intervene in cyclical redirections" is a
// SHOULD that libcurl leaves to the application: maxRedirects -1 means unlimited there, so the
// client's own chain following does the same, while 0 refuses the first hop (R-26)
unittest
{
    import std.format : format;

    auto server = new HttpStubServer("done");
    scope (exit)
        server.close();
    server.redirectStatus = 307;
    ClientConfig cfg;
    cfg.followRedirects = true;
    cfg.maxRedirects = -1;
    auto client = Client.create(cfg);
    const res = client.perform(Request.delete_(format("http://127.0.0.1:%d/hop60", server.port)));
    assert(res.status == 200);
    synchronized (server)
        assert(server.requestLines.length == 61, "60 hops, far beyond any bounded default");

    cfg.maxRedirects = 0;
    auto strict = Client.create(cfg);
    bool caught;
    try
        strict.perform(Request.delete_(format("http://127.0.0.1:%d/hop1", server.port)));
    catch (CurlException e)
        caught = e.code == CurlCode.CURLE_TOO_MANY_REDIRECTS;
    assert(caught);
}

/// Example:
/// ---
/// import std.array : replicate;
///
/// const longHost = "h".replicate(300);          // an origin that cannot be parsed
/// assert(!redirectPermitted("https://" ~ longHost ~ "/x", "http://a.example/", false));   // fails closed
/// assert(!redirectPermitted("https://a.example/", "http://a.example/", false));           // downgrade refused
/// assert(redirectPermitted("https://a.example/", "http://a.example/", true));             // ... unless allowed
/// assert(redirectPermitted("http://a.example/", "https://b.example/", false));
/// ---
/// import std.algorithm : canFind;
/// import std.format : format;
/// import std.uni : toLower;
///
// Spec: RFC 9110 Section 4.2.2 "Resources made available via the "https" scheme have no shared
// identity with the "http" scheme. They are distinct origins with separate namespaces." - a
// redirect from https to http leaves the origin; the downgrade check must fail closed: a URL whose origin cannot be parsed
// (host over 256 bytes) is never followed, and https -> http needs the explicit opt-in (R-26)
unittest
{
    import std.array : replicate;

    const longHost = "h".replicate(300);
    assert(!redirectPermitted("https://" ~ longHost ~ "/x", "http://a.example/",
            false), "unparsable current origin must not allow a downgrade");
    assert(!redirectPermitted("https://" ~ longHost ~ "/x", "https://a.example/", false));
    assert(!redirectPermitted("https://a.example/", "http://" ~ longHost ~ "/", true));
    assert(!redirectPermitted("https://a.example/", "http://a.example/", false));
    assert(redirectPermitted("https://a.example/", "http://a.example/", true));
    assert(redirectPermitted("http://a.example/", "https://b.example/", false));
    assert(!redirectPermitted("http://a.example/", "ftp://b.example/", true));
}

/// Example:
/// ---
/// import std.algorithm : canFind;
/// import std.format : format;
/// import std.uni : toLower;
///
/// auto a = new HttpStubServer("a");
/// auto b = new HttpStubServer("b");
/// scope (exit)
/// {
///     a.close();
///     b.close();
/// }
/// a.redirectStatus = 307;
/// ClientConfig cfg;
/// cfg.followRedirects = true;
/// auto client = Client.create(cfg);
///
/// // /hop2 -> /hop1 -> /hop0 on A: every request to A carries Authorization.
/// const req = Request.delete_(format("http://127.0.0.1:%d/hop2", a.port)).withHeader("Authorization", "Bearer s3cret");
/// assert(client.perform(req).status == 200);
/// synchronized (a)
///     assert(a.rawRequests[$ - 1].toLower.canFind("authorization: bearer s3cret"));
/// ---
// Spec: RFC 9110 Section 15.4 "Automatic redirection needs to be done with care for methods not
// known to be safe, as defined in Section 9.2.1, since the user might not wish to redirect an
// unsafe request." and Section 11.6.2 - credentials follow the origin: a chain of same-origin
// hops keeps them on every hop, the hop to another origin drops them. The decision reads the URL
// of the hop just finished, which must still be alive (use-after-free found with valgrind, R-26)
unittest
{
    import std.algorithm : canFind;
    import std.format : format;
    import std.uni : toLower;

    auto a = new HttpStubServer("a");
    auto b = new HttpStubServer("b");
    scope (exit)
    {
        a.close();
        b.close();
    }
    a.redirectStatus = 307;
    ClientConfig cfg;
    cfg.followRedirects = true;
    auto client = Client.create(cfg);
    const mk = (string path) => Request.delete_(format("http://127.0.0.1:%d%s", a.port, path))
        .withHeader("Authorization", "Bearer s3cret").withHeader("Cookie", "sid=1");

    // A -> A -> A: every hop keeps the credentials.
    assert(client.perform(mk("/hop3")).status == 200);
    synchronized (a)
    {
        assert(a.rawRequests.length == 4);
        foreach (raw; a.rawRequests)
        {
            assert(raw.toLower.canFind("authorization: bearer s3cret"), "same origin keeps it");
            assert(raw.toLower.canFind("cookie: sid=1"));
        }
    }

    // A -> A -> B: stripped at B, which never sees them; later hops stay stripped.
    a.rawRequests = null;
    a.hopFinalLocation = format("http://127.0.0.1:%d/final", b.port);
    assert(client.perform(mk("/hop2")).status == 200);
    synchronized (a)
    {
        assert(a.rawRequests.length == 3);
        foreach (raw; a.rawRequests)
            assert(raw.toLower.canFind("authorization: bearer s3cret"));
    }
    synchronized (b)
    {
        assert(b.rawRequests.length == 1);
        assert(!b.rawRequests[0].toLower.canFind("authorization"));
        assert(!b.rawRequests[0].toLower.canFind("cookie"));
    }
}

/// Example:
/// ---
/// ClientConfig cfg;
/// cfg.maxRedirects = 0xFFFF_FFFFL;
/// assert(cfg.maxRedirects == int.max);          // clamped, not truncated to -1 (unlimited)
/// cfg.maxRedirects = -2;
/// assert(cfg.maxRedirects == 0);                // below -1: no redirect at all
/// ---
// Spec: RFC 9110 Section 15.4 "A client SHOULD detect and intervene in cyclical redirections" -
// the redirect limit must keep its meaning: a long value is clamped, never truncated into the
// "unlimited" marker -1; below -1 means no redirect at all (R-26)
@safe unittest
{
    ClientConfig cfg;
    cfg.maxRedirects = 0xFFFF_FFFFL;
    assert(cfg.maxRedirects == int.max);
    cfg.maxRedirects = long.max;
    assert(cfg.maxRedirects == int.max);
    cfg.maxRedirects = -1;
    assert(cfg.maxRedirects == -1);
    cfg.maxRedirects = -2;
    assert(cfg.maxRedirects == 0);
    cfg.maxRedirects = long.min;
    assert(cfg.maxRedirects == 0);
    cfg.maxRedirects = 7;
    assert(cfg.maxRedirects == 7);
}

/// Example:
/// ---
/// RedirectProbe p;
/// p.observe("Location: \r\n");       // empty target: not a redirect that is followed
/// assert(!p.location);
/// ---
// Spec: RFC 9110 Section 10.2.2 "The field value consists of a single URI-reference." - a
// Location with no value names no target, so libcurl offers no redirect URL and the client must
// deliver that response's body instead of dropping it (R-26)
unittest
{
    import std.format : format;

    RedirectProbe p;
    p.observe("Location: http://a/x\r\n");
    assert(p.location);
    p.observe("HTTP/1.1 200 OK\r\n");
    assert(!p.location, "a new status line resets");
    p.observe("LOCATION:\thttp://a/x\r\n");
    assert(p.location, "case-insensitive");
    p.observe("HTTP/1.1 307 T\r\n");
    p.observe("Location: \r\n");
    assert(!p.location);
    p.observe("Location:\r\n");
    assert(!p.location);
    p.observe("X-Location: http://a\r\n");
    assert(!p.location);

    // End to end: a 307 with an empty Location is the final response; its body is delivered.
    auto server = new HttpStubServer("ignored");
    scope (exit)
        server.close();
    server.redirectStatus = 307;
    server.redirectLocation = "";
    server.redirectBody = "redirect-body";
    ClientConfig cfg;
    cfg.followRedirects = true;
    auto client = Client.create(cfg);
    const url = format("http://127.0.0.1:%d/r", server.port);
    ubyte[64] buf;
    const res = client.perform(Request.delete_(url), buf[]);
    assert(res.status == 307);
    assert(res.bodyData == cast(const(ubyte)[]) "redirect-body");
    const gc = client.perform(Request.delete_(url));
    assert(gc.status == 307 && gc.bodyData == cast(const(ubyte)[]) "redirect-body");
}

/// Example:
/// ---
/// import slate.http.c_bind;
///
/// CURL* h = curl_easy_init();
/// scope (exit)
///     curl_easy_cleanup(h);
/// ClientConfig cfg;
/// cfg.caInfo = "/nonexistent/slate-test-ca.pem";   // unreadable CA bundle
/// auto req = Request.get("http://127.0.0.1:1/x");
/// req.headers = [Header("X-One", "1"), Header("X-Two", "2")];
/// curl_slist* list = null;
/// try
///     applyRequestOptions(h, cfg, req, "http://127.0.0.1:1/x\0".ptr, list);
/// catch (CurlException e)
///     assert(e.code == CurlCode.CURLE_SSL_CACERT);
/// assert(list is null);      // the header list built before the failure was freed, not leaked
/// ---
// Spec: libcurl curl_slist_append(3) "curl_slist_free_all ... frees the whole list" - the list is
// owned by whoever holds it: a build that fails after the headers were appended (here the
// unreadable CA bundle) must free the partial list and leave `headerList` null, so the hop in
// `performFollowing` (which builds into a fresh list) neither leaks nor double-frees it (PC-2)
unittest
{
    import slate.http.c_bind;

    CURL* h = curl_easy_init();
    assert(h !is null);
    scope (exit)
        curl_easy_cleanup(h);
    ClientConfig cfg;
    cfg.caInfo = "/nonexistent/slate-test-ca.pem";
    auto req = Request.get("http://127.0.0.1:1/x");
    req.headers = [Header("X-One", "1"), Header("X-Two", "2")];
    curl_slist* list = null;
    bool threw = false;
    try
        applyRequestOptions(h, cfg, req, "http://127.0.0.1:1/x\0".ptr, list);
    catch (CurlException e)
        threw = e.code == CurlCode.CURLE_SSL_CACERT;
    assert(threw, "an unreadable CA bundle fails the build after the headers were appended");
    assert(list is null, "the partial list was freed and handed back as null");

    // The same failure through the hop path of a custom-method redirect leaves the caller's
    // previous list untouched (it is released only once the new one is in place).
    cfg.caInfo = null;
    cfg.followRedirects = true;
    const del = Request.delete_("http://127.0.0.1:1/x");
    curl_slist* prev = null;
    applyRequestOptions(h, cfg, del, "http://127.0.0.1:1/x\0".ptr, prev, null, 0, HOP_MANUAL);
    prev = curl_slist_append(prev, "X-Prev: 1");
    assert(prev !is null);
    scope (exit)
        curl_slist_free_all(prev);
    cfg.caInfo = "/nonexistent/slate-test-ca.pem";
    curl_slist* fresh = null;
    threw = false;
    try
        applyRequestOptions(h, cfg, req, "http://127.0.0.1:1/x\0".ptr, fresh, null, 0, HOP_MANUAL);
    catch (CurlException)
        threw = true;
    assert(threw && fresh is null);
    assert(prev.data !is null);
}
