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
    text       = 0, /// Informational human-readable text line
    headerIn   = 1, /// Header data received from peer
    headerOut  = 2, /// Header data sent to peer
    dataIn     = 3, /// Body protocol data received from peer
    dataOut    = 4, /// Body protocol data sent to peer
    sslDataIn  = 5, /// Raw SSL/TLS encrypted protocol data received
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

/// Native C debug callback invoked by libcurl when `CURLOPT_DEBUGFUNCTION` is set.
extern (C) int curlDebugCb(CURL* handle, int type, char* data, size_t size, void* userptr) @nogc nothrow
{
    if (userptr is null)
        return 0;
    auto ctx = cast(DebugContext*) userptr;
    if (ctx.sink !is null && data !is null && size > 0)
    {
        ctx.sink(cast(CurlInfoType) type, data[0 .. size], ctx.userdata);
    }
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
    // Best practice: verify curlDebugCb forwards data slice and info type to @nogc DebugSink
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
                scope (exit) client.close();
                char[512] buf;
                client.receive(buf[]);
                string resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
                client.send(resp);
            }
            catch (Exception) {}
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
