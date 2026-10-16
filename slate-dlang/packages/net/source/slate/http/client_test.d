module slate.http.client_test;

import slate.http.client;
import slate.http.request;
import slate.http.response;
import slate.http.error;

import slate.http.test_server : HttpStubServer;
import slate.http.version_ : hasHttp3;
import slate.http.multi : CancellationToken;

// Best practice: @nogc callbacks + no GC delegates across C ABI (UB-4, UN-1)
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
/// import slate.http.client;
/// import slate.http.request;
/// size_t totalBytes = 0;
/// auto client = Client.create();
/// auto res = client.performStream(Request.get("http://example.com/stream"),
///     (const(ubyte)[] chunk, void* ctx) @nogc nothrow {
///         auto total = cast(size_t*) ctx;
///         *total += chunk.length;
///     }, &totalBytes);
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

// Best practice: handle reuse without method pollution across transfers (CRIT-1)
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.request;
/// auto client = Client.create();
/// client.perform(Request.put("http://example.com/api").withBody("data"));
/// auto res = client.perform(Request.get("http://example.com/api"));
/// assert(res.status == 200);
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
/// import slate.http.client;
/// import slate.http.response;
/// auto client = Client.create();
/// auto res = client.get("http://example.com/api");
/// assert(res.status == 200);
/// assert(res.hasHeader("content-type"));
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
/// import slate.http.client;
/// auto client = Client.create();
/// auto res1 = client.get("http://example.com/");
/// auto res2 = client.get("http://example.com/");
/// assert(client.lastNumConnects() == 0);
/// ---
unittest
{
    // Best practice: verify sequential Client reuse preserves keep-alive and numConnects == 0
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
    // Best practice: verify in-flight cancellation terminates Client transfer promptly
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
/// auto client = Client.create();
/// string bigToken = "Bearer " ~ "x".replicate(700);
/// auto req = Request.get("http://example.com/").withHeader("Authorization", bigToken);
/// auto res = client.perform(req);
/// ---
unittest
{
    // Best practice: verify headers >512 bytes (such as large JWT bearer tokens) are not silently dropped
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
