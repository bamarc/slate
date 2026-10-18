/// HTTP transfer debug and observability hooks (OPT-1).
///
/// This module provides zero-allocation `@nogc nothrow` debug callbacks
/// for capturing verbose protocol trace, TLS handshake info, and headers.
module slate.http.debug_;

import slate.http.c_bind;

/// Type of informational debug data passed to `DebugSink` (OPT-1).
/// Corresponds to libcurl's `curl_infotype`.
enum CurlInfoType : int
{
    text = 0, /// Informational human-readable text line
    headerIn = 1, /// Header data received from peer
    headerOut = 2, /// Header data sent to peer
    dataIn = 3, /// Body protocol data received from peer
    dataOut = 4, /// Body protocol data sent to peer
    sslDataIn = 5, /// Raw SSL/TLS encrypted protocol data received
    sslDataOut = 6, /// Raw SSL/TLS encrypted protocol data sent
}

/// `@nogc nothrow` callback receiving verbose protocol messages and tracing (OPT-1).
///
/// The provided `data` slice borrows caller memory and is only valid for
/// the duration of the callback invocation.
alias DebugSink = void function(CurlInfoType type, const(char)[] data, void* userdata) @nogc nothrow;

/// Context paired with `curlDebugCb` bridging C ABI to `DebugSink`.
struct DebugContext
{
    DebugSink sink;
    void* userdata;
}

private bool startsWithCaseInsensitive(const(char)[] s, const(char)[] prefix) @nogc nothrow pure
{
    if (s.length < prefix.length)
        return false;
    foreach (i; 0 .. prefix.length)
    {
        char c1 = s[i];
        char c2 = prefix[i];
        if (c1 >= 'A' && c1 <= 'Z')
            c1 += ('a' - 'A');
        if (c2 >= 'A' && c2 <= 'Z')
            c2 += ('a' - 'A');
        if (c1 != c2)
            return false;
    }
    return true;
}

private bool containsAuthHeader(const(char)[] s) @nogc nothrow pure
{
    const auth = "authorization:";
    if (s.length < auth.length)
        return false;
    foreach (i; 0 .. s.length - auth.length + 1)
    {
        if (startsWithCaseInsensitive(s[i .. $], auth))
            return true;
    }
    return false;
}

/// Native C debug callback invoked by libcurl when `CURLOPT_DEBUGFUNCTION` is set.
extern (C) int curlDebugCb(CURL* handle, int type, char* data, size_t size, void* userptr) @nogc nothrow
{
    if (userptr is null)
        return 0;
    auto ctx = cast(DebugContext*) userptr;
    if (ctx.sink is null || data is null || size == 0)
        return 0;

    const(char)[] raw = data[0 .. size];
    if ((type == CurlInfoType.headerIn || type == CurlInfoType.headerOut) && containsAuthHeader(raw))
    {
        // Redact Authorization and Proxy-Authorization headers (F-68)
        char[2048] stackBuf;
        char* outBuf = stackBuf.ptr;
        size_t outCap = stackBuf.length;
        char* heapBuf = null;

        if (size + 128 > outCap)
        {
            import core.stdc.stdlib : malloc;

            heapBuf = cast(char*) malloc(size + 128);
            if (heapBuf !is null)
            {
                outBuf = heapBuf;
                outCap = size + 128;
            }
        }
        scope (exit)
        {
            if (heapBuf !is null)
            {
                import core.stdc.stdlib : free;

                free(heapBuf);
            }
        }

        size_t outLen = 0;
        size_t i = 0;
        while (i < raw.length)
        {
            size_t lineEnd = i;
            while (lineEnd < raw.length && raw[lineEnd] != '\n')
                lineEnd++;
            if (lineEnd < raw.length && raw[lineEnd] == '\n')
                lineEnd++;

            const(char)[] line = raw[i .. lineEnd];
            i = lineEnd;

            size_t start = 0;
            while (start < line.length && (line[start] == ' ' || line[start] == '\t'))
                start++;

            const(char)[] effective = line[start .. $];
            const(char)[] toAppend = line;

            if (startsWithCaseInsensitive(effective, "proxy-authorization:"))
            {
                toAppend = (line.length >= 2 && line[$ - 2 .. $] == "\r\n") ? "Proxy-Authorization: [REDACTED]\r\n"
                    : "Proxy-Authorization: [REDACTED]\n";
            }
            else if (startsWithCaseInsensitive(effective, "authorization:"))
            {
                toAppend = (line.length >= 2 && line[$ - 2 .. $] == "\r\n") ? "Authorization: [REDACTED]\r\n"
                    : "Authorization: [REDACTED]\n";
            }

            if (outLen + toAppend.length <= outCap)
            {
                outBuf[outLen .. outLen + toAppend.length] = toAppend[];
                outLen += toAppend.length;
            }
        }

        if (outLen > 0)
            ctx.sink(cast(CurlInfoType) type, outBuf[0 .. outLen], ctx.userdata);
        return 0;
    }

    ctx.sink(cast(CurlInfoType) type, raw, ctx.userdata);
    return 0;
}

// Spec: CURLOPT_DEBUGFUNCTION and CURLOPT_DEBUGDATA callback invocation (OPT-1)
/// Example:
/// ---
/// import slate.http.debug_;
///
/// static void testSink(CurlInfoType type, const(char)[] data, void* userdata) @nogc nothrow
/// {
///     auto counter = cast(size_t*) userdata;
///     if (counter !is null) (*counter)++;
/// }
///
/// size_t count = 0;
/// DebugContext ctx = DebugContext(&testSink, &count);
/// string msg = "Connected to host\n";
/// curlDebugCb(null, CurlInfoType.text, cast(char*) msg.ptr, msg.length, &ctx);
/// assert(count == 1);
/// ---
unittest
{
    // Spec: verify curlDebugCb forwards data slice and info type to @nogc DebugSink
    static __gshared size_t textCount = 0;
    static __gshared size_t headerCount = 0;

    static void mySink(CurlInfoType type, const(char)[] data, void* userdata) @nogc nothrow
    {
        if (type == CurlInfoType.text)
            textCount++;
        else if (type == CurlInfoType.headerOut)
            headerCount++;
    }

    textCount = 0;
    headerCount = 0;

    DebugContext ctx = DebugContext(&mySink, null);
    string sampleText = "* Connected to 127.0.0.1 port 80\n";
    string sampleHdr = "GET / HTTP/1.1\r\n";

    curlDebugCb(null, CurlInfoType.text, cast(char*) sampleText.ptr, sampleText.length, &ctx);
    curlDebugCb(null, CurlInfoType.headerOut, cast(char*) sampleHdr.ptr, sampleHdr.length, &ctx);

    assert(textCount == 1);
    assert(headerCount == 1);

    // Null checks must not crash
    curlDebugCb(null, CurlInfoType.text, null, 0, &ctx);
    curlDebugCb(null, CurlInfoType.text, cast(char*) sampleText.ptr, sampleText.length, null);
}

// Spec: Authorization and Proxy-Authorization headers redacted in curlDebugCb (F-68)
// Scenario: Sensitive credentials in request or response headers are replaced with [REDACTED]
/// Example:
/// ---
/// import slate.http.debug_;
/// static void sink(CurlInfoType type, const(char)[] data, void* userdata) @nogc nothrow {}
/// DebugContext ctx = DebugContext(&sink, null);
/// ---
unittest
{
    // Spec: verify Authorization and Proxy-Authorization lines are redacted
    static __gshared char[256] captured;
    static __gshared size_t capturedLen = 0;

    static void authSink(CurlInfoType type, const(char)[] data, void* userdata) @nogc nothrow
    {
        if (data.length <= captured.length)
        {
            captured[0 .. data.length] = data[];
            capturedLen = data.length;
        }
    }

    DebugContext ctx = DebugContext(&authSink, null);

    // 1. Authorization header redaction
    string authHdr = "Authorization: Bearer secret-token-12345\r\n";
    capturedLen = 0;
    curlDebugCb(null, CurlInfoType.headerOut, cast(char*) authHdr.ptr, authHdr.length, &ctx);
    assert(captured[0 .. capturedLen] == "Authorization: [REDACTED]\r\n",
            "Authorization header must be redacted");

    // 2. Proxy-Authorization header redaction
    string proxyHdr = "Proxy-Authorization: Basic dXNlcjpwYXNz\r\n";
    capturedLen = 0;
    curlDebugCb(null, CurlInfoType.headerOut, cast(char*) proxyHdr.ptr, proxyHdr.length, &ctx);
    assert(captured[0 .. capturedLen] == "Proxy-Authorization: [REDACTED]\r\n",
            "Proxy-Authorization header must be redacted");

    // 3. Unrelated headers preserved
    string normalHdr = "Content-Type: application/json\r\n";
    capturedLen = 0;
    curlDebugCb(null, CurlInfoType.headerIn, cast(char*) normalHdr.ptr, normalHdr.length, &ctx);
    assert(captured[0 .. capturedLen] == "Content-Type: application/json\r\n",
            "Non-sensitive headers must not be modified");
}

// Spec: End-to-end Client verbose observability via DebugSink under SlateHttpDebug (OPT-1)
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.debug_;
/// ClientConfig cfg;
/// cfg.debugSink = function(CurlInfoType type, const(char)[] data, void* userdata) @nogc nothrow {};
/// auto client = Client.create(cfg);
/// ---
unittest
{
    version (SlateHttpDebug)
    {
        import slate.http.client;
        import slate.http.request;
        import std.socket;
        import core.thread;

        // Stand up quick loopback listener
        auto listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(1);
        ushort port = (cast(InternetAddress) listener.localAddress).port;

        auto t = new Thread({
            try
            {
                auto client = listener.accept();
                scope (exit)
                    client.close();
                char[512] buf;
                client.receive(buf[]);
                string resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
                client.send(resp);
            }
            catch (Exception)
            {
            }
        });
        t.start();
        scope (exit)
        {
            listener.close();
            t.join();
        }

        static __gshared size_t capturedHeaderOut = 0;
        static __gshared size_t capturedHeaderIn = 0;
        static __gshared size_t capturedText = 0;

        static void testObserver(CurlInfoType type, const(char)[] data, void* userdata) @nogc nothrow
        {
            if (type == CurlInfoType.headerOut)
                capturedHeaderOut++;
            else if (type == CurlInfoType.headerIn)
                capturedHeaderIn++;
            else if (type == CurlInfoType.text)
                capturedText++;
        }

        capturedHeaderOut = 0;
        capturedHeaderIn = 0;
        capturedText = 0;

        ClientConfig cfg;
        cfg.debugSink = &testObserver;
        auto client = Client.create(cfg);
        import std.format : format;

        auto res = client.get(format("http://127.0.0.1:%d/", port));
        assert(res.status == 200);
        assert(capturedHeaderOut > 0, "DebugSink must capture headerOut");
        assert(capturedHeaderIn > 0, "DebugSink must capture headerIn");
    }
}
