/// HTTP Client, execution engine, and @nogc transfer boundaries over libcurl easy handles.
///
/// This module provides the value-type `Client` (UB-1) and configuration model `ClientConfig`.
/// It implements a clean architectural memory split:
///
/// - **Cold Configuration Path (GC Allowed):** Creating `ClientConfig`, parsing URLs,
///   configuring headers, and high-level string helpers may allocate memory via D's GC.
/// - **Hot Execution Path (Strictly `@nogc`):** Single-transfer execution (`perform(req, buffer)`
///   and `performStream`), C callbacks, and range consumption operate with `@safe @nogc`
///   guarantees, never allocating heap memory or invoking GC runtime (UB-4, UN-1).
///
/// All C ABI callbacks are defined as `extern(C) function ... @nogc nothrow` receiving
/// typed context pointers (`void* userdata`), ensuring no D GC delegates cross the C boundary.
/// Handle lifecycles and error recovery are strictly guarded by RAII `scope(exit)` cleanup
/// semantics to prevent handle and memory leaks (UN-3).
module slate.http.client;

import slate.http.c_bind;
import slate.http.error;
import slate.http.request;
import slate.http.response;
import slate.http : CurlGlobal;
import slate.http.version_ : hasHttp3;
import slate.http.multi : CancellationToken, xferInfoCancellationCb;

import core.stdc.stdlib : malloc, realloc, free;
import slate.http.debug_ : DebugSink, CurlInfoType, curlDebugCb, DebugContext;

/// TLS certificate verification mode (TC-10).
enum TlsMode
{
    verify,         /// Verification ON: strict certificate checking (default)
    insecureOptIn   /// Insecure opt-in: disables peer/host verification and logs/audits
}

private __gshared shared(size_t) _insecureOptInAuditCount = 0;

/// Returns the total number of times insecure TLS verification was opted into (TC-10).
size_t insecureOptInAuditCount() @trusted @nogc nothrow
{
    import core.atomic : atomicLoad;
    return atomicLoad(_insecureOptInAuditCount);
}

/// Increments the audit count for insecure TLS opt-in.
void recordInsecureTlsAudit() @trusted @nogc nothrow
{
    import core.atomic : atomicOp;
    atomicOp!"+="(_insecureOptInAuditCount, 1);
}

/// Connect and transfer timeouts in milliseconds (TC-11).
struct Timeouts
{
    long connectMs = 10_000; /// Connection timeout in milliseconds (default 10s)
    long totalMs = 30_000;   /// Overall transfer timeout in milliseconds (default 30s)

    invariant
    {
        assert(connectMs >= 0, "connectMs must be non-negative");
        assert(totalMs >= 0, "totalMs must be non-negative");
    }
}

/// Mode for automatic HTTP 3xx redirect following.
enum RedirectMode
{
    off,    /// Do not follow redirects (default)
    follow  /// Follow 3xx redirects up to configured maximum
}

/// Policy for automatic HTTP 3xx redirect following (TC-11).
struct RedirectPolicy
{
    RedirectMode mode = RedirectMode.off;       /// Opt-in redirect following (default off)
    int maxRedirects = 5;                       /// Maximum redirect hops (default 5)
    bool allowHttpsToHttpDowngrade = false;     /// Refuse HTTPS -> HTTP downgrade redirects by default

    invariant
    {
        assert(maxRedirects >= 0, "maxRedirects must be non-negative");
    }
}

/// Signature for `@nogc nothrow` streaming chunk receiver callbacks (UN-1, EV-3a).
alias ChunkStreamHandler = extern (C) void function(const(ubyte)[] chunk, void* userdata) @nogc nothrow;

/// Configuration options for the HTTP `Client` (UB-1).
///
/// Maps directly to libcurl options without exposing raw `CURLOPT_*` constants.
struct ClientConfig
{
    Timeouts timeouts;               /// Connect and transfer timeout configuration (TC-11)
    RedirectPolicy redirects;        /// HTTP redirect handling policy (TC-11)
    TlsMode tlsMode = TlsMode.verify;/// TLS certificate verification mode (TC-10)
    bool verifyPeer = true;          /// Verify peer SSL certificate (CURLOPT_SSL_VERIFYPEER)
    bool verifyHost = true;          /// Verify hostname matches SSL certificate (CURLOPT_SSL_VERIFYHOST)
    string caInfo = null;            /// Path to custom CA certificate bundle file
    string altSvcCachePath = null;   /// Path to persistent Alt-Svc cache file (OPT-2, ST-3)
    long altSvcCtrl = CURLALTSVC_H1 | CURLALTSVC_H2 | CURLALTSVC_H3; /// Alt-Svc bitmask (ST-3)
    bool acceptEncoding = true;      /// Enable automatic decompression (gzip, deflate, br, zstd)
    HttpVersion defaultHttpVersion = HttpVersion.auto_; /// Default HTTP protocol version
    bool verbose = false;            /// Enable libcurl internal debug logging
    DebugContext debugContext;       /// Internal debug context for CURLOPT_DEBUGDATA (OPT-1)

    /// Optional @nogc callback for verbose/qlog protocol tracing (OPT-1)
    @property DebugSink debugSink() const pure @safe @nogc nothrow { return cast(DebugSink) debugContext.sink; }
    /// Sets the debug callback (OPT-1)
    @property void debugSink(DebugSink s) pure @safe @nogc nothrow { debugContext.sink = s; }
    /// Userdata passed to debugSink (OPT-1)
    @property void* debugUserdata() const pure @safe @nogc nothrow { return cast(void*) debugContext.userdata; }
    /// Sets userdata passed to debugSink (OPT-1)
    @property void debugUserdata(void* u) pure @safe @nogc nothrow { debugContext.userdata = u; }

    // Backward-compatibility properties
    @property bool followRedirects() const pure @safe @nogc nothrow
    {
        return redirects.mode == RedirectMode.follow;
    }

    @property void followRedirects(bool enable) pure @safe @nogc nothrow
    {
        redirects.mode = enable ? RedirectMode.follow : RedirectMode.off;
    }

    @property long maxRedirects() const pure @safe @nogc nothrow
    {
        return redirects.maxRedirects;
    }

    @property void maxRedirects(long max) pure @safe @nogc nothrow
    {
        redirects.maxRedirects = cast(int) max;
    }

    @property long timeoutMs() const pure @safe @nogc nothrow
    {
        return timeouts.totalMs;
    }

    @property void timeoutMs(long v) pure @safe @nogc nothrow
    {
        timeouts.totalMs = v;
    }

    @property long connectTimeoutMs() const pure @safe @nogc nothrow
    {
        return timeouts.connectMs;
    }

    @property void connectTimeoutMs(long v) pure @safe @nogc nothrow
    {
        timeouts.connectMs = v;
    }
}

/// Internal context passed to write callback for caller-buffer execution.
package struct BufferWriteCtx
{
    ubyte[] dest;
    size_t written;
    bool overflow;
}

/// Write callback writing directly into a caller-provided fixed buffer (UB-4, UN-1).
package extern (C) size_t clientBufferWriteCb(char* ptr, size_t size, size_t nmemb, void* userdata) @nogc nothrow
{
    if (userdata is null)
        return 0;
    size_t total = size * nmemb;
    if (total == 0)
        return 0;

    auto ctx = cast(BufferWriteCtx*) userdata;
    if (ctx.written + total > ctx.dest.length)
    {
        ctx.overflow = true;
        return 0; // Abort transfer on buffer overflow
    }
    (cast(ubyte*) ctx.dest.ptr)[ctx.written .. ctx.written + total] = (cast(ubyte*) ptr)[0 .. total];
    ctx.written += total;
    return total;
}

/// Internal context for streaming chunk delivery without buffering (EV-3a, UN-1).
private struct StreamWriteCtx
{
    ChunkStreamHandler onChunk;
    void* userdata;
}

/// Write callback streaming each received chunk directly to caller handler (EV-3a, UN-1).
private extern (C) size_t clientStreamWriteCb(char* ptr, size_t size, size_t nmemb, void* userdata) @nogc nothrow
{
    if (userdata is null)
        return 0;
    size_t total = size * nmemb;
    if (total == 0)
        return 0;

    auto ctx = cast(StreamWriteCtx*) userdata;
    if (ctx.onChunk !is null)
    {
        ctx.onChunk(cast(const(ubyte)[]) ptr[0 .. total], ctx.userdata);
    }
    return total;
}

/// Internal context for dynamic C heap accumulation (used by convenient GC perform).
package struct DynamicBufferCtx
{
    ubyte* ptr;
    size_t len;
    size_t cap;
    bool oom;
}

/// Write callback accumulating data onto the C heap using malloc/realloc without D GC (UN-1).
package extern (C) size_t clientDynamicWriteCb(char* ptr, size_t size, size_t nmemb, void* userdata) @nogc nothrow
{
    if (userdata is null)
        return 0;
    size_t total = size * nmemb;
    if (total == 0)
        return 0;

    auto ctx = cast(DynamicBufferCtx*) userdata;
    if (ctx.len + total > ctx.cap)
    {
        size_t newCap = (ctx.cap == 0) ? 4096 : ctx.cap * 2;
        while (ctx.len + total > newCap)
            newCap *= 2;
        ubyte* newPtr = cast(ubyte*) realloc(ctx.ptr, newCap);
        if (newPtr is null)
        {
            ctx.oom = true;
            return 0; // Abort on OOM
        }
        ctx.ptr = newPtr;
        ctx.cap = newCap;
    }
    ctx.ptr[ctx.len .. ctx.len + total] = (cast(ubyte*) ptr)[0 .. total];
    ctx.len += total;
    return total;
}

/// Header callback collecting raw header lines in C heap buffer.
package extern (C) size_t clientHeaderCollectCb(char* buffer, size_t size, size_t nitems, void* userdata) @nogc nothrow
{
    return clientDynamicWriteCb(buffer, size, nitems, userdata);
}

/// Parses raw HTTP headers into an array of `Header` structs (cold path).
package Header[] parseHeaders(const(char)[] raw) @safe pure
{
    Header[] result;
    size_t i = 0;
    while (i < raw.length)
    {
        size_t lineEnd = i;
        while (lineEnd < raw.length && raw[lineEnd] != '\n')
            lineEnd++;

        const(char)[] line = raw[i .. lineEnd];
        if (line.length > 0 && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];

        i = lineEnd + 1;

        if (line.length == 0)
            continue;

        // Skip HTTP status response lines (e.g. "HTTP/1.1 200 OK")
        if (line.length >= 5 && line[0 .. 5] == "HTTP/")
            continue;

        ptrdiff_t colon = -1;
        foreach (idx, c; line)
        {
            if (c == ':')
            {
                colon = idx;
                break;
            }
        }

        if (colon > 0)
        {
            string name = line[0 .. colon].idup;
            const(char)[] val = line[colon + 1 .. $];
            while (val.length > 0 && (val[0] == ' ' || val[0] == '\t'))
                val = val[1 .. $];
            result ~= Header(name, val.idup);
        }
    }
    return result;
}

/// Maps libcurl internal HTTP version code to `HttpVersion`.
package pure @safe @nogc nothrow HttpVersion mapCurlHttpVersion(long rawVer)
{
    switch (rawVer)
    {
        case CURL_HTTP_VERSION_1_1: return HttpVersion.h1_1;
        case CURL_HTTP_VERSION_2_0: return HttpVersion.h2;
        version (HaveCurlHttp3)
        {
            case CURL_HTTP_VERSION_3: return HttpVersion.h3;
        }
        default: return HttpVersion.h1_1;
    }
}

/// Applies standard request configuration options to a libcurl easy handle (ST-1, ST-2, ST-3).
package void applyRequestOptions(
    CURL* handle,
    const ref ClientConfig config,
    const ref Request req,
    const(char)* cUrl,
    out curl_slist* headerList,
    const(char)* altSvcPath = null,
    long altSvcCtrl = 0) @trusted @nogc
{
    // 1. URL
    curl_easy_setopt(handle, CURLoption.CURLOPT_URL, cUrl);

    // 2. HTTP Method & Payload (Unconditionally reset custom request to prevent handle pollution)
    switch (req.method)
    {
        case Method.GET:
            curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, cast(const(void)*) null);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POST, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_NOBODY, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_CUSTOMREQUEST, cast(const(char)*) null);
            curl_easy_setopt(handle, CURLoption.CURLOPT_HTTPGET, 1L);
            break;
        case Method.POST:
            curl_easy_setopt(handle, CURLoption.CURLOPT_POST, 1L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_HTTPGET, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_NOBODY, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_CUSTOMREQUEST, cast(const(char)*) null);
            if (req.bodyData.length > 0)
            {
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, req.bodyData.ptr);
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, cast(curl_off_t) req.bodyData.length);
            }
            else
            {
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, "".ptr);
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            }
            break;
        case Method.HEAD:
            curl_easy_setopt(handle, CURLoption.CURLOPT_NOBODY, 1L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POST, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_HTTPGET, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_CUSTOMREQUEST, cast(const(char)*) null);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, cast(const(void)*) null);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            break;
        case Method.PUT:
            curl_easy_setopt(handle, CURLoption.CURLOPT_NOBODY, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POST, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_HTTPGET, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_CUSTOMREQUEST, "PUT\0".ptr);
            if (req.bodyData.length > 0)
            {
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, req.bodyData.ptr);
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, cast(curl_off_t) req.bodyData.length);
            }
            else
            {
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, "".ptr);
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            }
            break;
        case Method.DELETE:
            curl_easy_setopt(handle, CURLoption.CURLOPT_NOBODY, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POST, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_HTTPGET, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_CUSTOMREQUEST, "DELETE\0".ptr);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, cast(const(void)*) null);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            break;
        case Method.PATCH:
            curl_easy_setopt(handle, CURLoption.CURLOPT_NOBODY, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POST, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_HTTPGET, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_CUSTOMREQUEST, "PATCH\0".ptr);
            if (req.bodyData.length > 0)
            {
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, req.bodyData.ptr);
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, cast(curl_off_t) req.bodyData.length);
            }
            else
            {
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, "".ptr);
                curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            }
            break;
        case Method.OPTIONS:
            curl_easy_setopt(handle, CURLoption.CURLOPT_NOBODY, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POST, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_HTTPGET, 0L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_CUSTOMREQUEST, "OPTIONS\0".ptr);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDS, cast(const(void)*) null);
            curl_easy_setopt(handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            break;
        default:
            break;
    }

    // 3. HTTP Version (EV-2b, ST-2: Fail fast on h3Only when H3 is absent)
    HttpVersion targetVer = (req.httpVersion != HttpVersion.auto_) ? req.httpVersion : config.defaultHttpVersion;
    if (targetVer == HttpVersion.h3Only && !hasHttp3())
    {
        throwCurlErrorNogc(CurlCode.CURLE_NOT_BUILT_IN);
    }

    if (targetVer != HttpVersion.auto_)
    {
        long curlVer = toCurlHttpVersion(targetVer);
        if (curlVer != CURL_HTTP_VERSION_NONE)
        {
            auto resVer = curl_easy_setopt(handle, CURLoption.CURLOPT_HTTP_VERSION, curlVer);
            enforceCurlNogc(cast(CurlCode) resVer);
        }
    }

    // 4. Request Headers (allocate dynamically when header exceeds static 512-byte buffer)
    headerList = null;
    foreach (ref h; req.headers)
    {
        char[512] hBuf;
        size_t n = 0;
        if (h.name.length + 2 + h.value.length + 1 <= hBuf.length)
        {
            hBuf[n .. n + h.name.length] = h.name[];
            n += h.name.length;
            hBuf[n .. n + 2] = ": ";
            n += 2;
            hBuf[n .. n + h.value.length] = h.value[];
            n += h.value.length;
            hBuf[n] = '\0';
            headerList = curl_slist_append(headerList, hBuf.ptr);
            if (headerList is null)
                throwCurlErrorNogc(CurlCode.CURLE_OUT_OF_MEMORY);
        }
        else
        {
            const size_t totalLen = h.name.length + 2 + h.value.length + 1;
            char* dynH = cast(char*) malloc(totalLen);
            if (dynH is null)
                throwCurlErrorNogc(CurlCode.CURLE_OUT_OF_MEMORY);
            scope (exit) free(dynH);
            dynH[0 .. h.name.length] = h.name[];
            dynH[h.name.length .. h.name.length + 2] = ": ";
            dynH[h.name.length + 2 .. totalLen - 1] = h.value[];
            dynH[totalLen - 1] = '\0';
            headerList = curl_slist_append(headerList, dynH);
            if (headerList is null)
                throwCurlErrorNogc(CurlCode.CURLE_OUT_OF_MEMORY);
        }
    }
    if (headerList !is null)
        curl_easy_setopt(handle, CURLoption.CURLOPT_HTTPHEADER, headerList);

    // 5. Configured Timeouts & Networking (TC-11)
    long effectiveTimeoutMs = (req.timeoutMs > 0) ? req.timeoutMs : config.timeouts.totalMs;
    curl_easy_setopt(handle, CURLoption.CURLOPT_TIMEOUT_MS, effectiveTimeoutMs);

    long effectiveConnectTimeoutMs = (req.connectTimeoutMs > 0) ? req.connectTimeoutMs : config.timeouts.connectMs;
    curl_easy_setopt(handle, CURLoption.CURLOPT_CONNECTTIMEOUT_MS, effectiveConnectTimeoutMs);

    // Redirects (TC-11)
    bool follow = (config.redirects.mode == RedirectMode.follow);
    curl_easy_setopt(handle, CURLoption.CURLOPT_FOLLOWLOCATION, follow ? 1L : 0L);
    curl_easy_setopt(handle, CURLoption.CURLOPT_MAXREDIRS, cast(long) config.redirects.maxRedirects);

    bool isHttps = false;
    if (req.url.length >= 8)
    {
        char c0 = req.url[0] | 0x20;
        char c1 = req.url[1] | 0x20;
        char c2 = req.url[2] | 0x20;
        char c3 = req.url[3] | 0x20;
        char c4 = req.url[4] | 0x20;
        if (c0 == 'h' && c1 == 't' && c2 == 't' && c3 == 'p' && c4 == 's' &&
            req.url[5] == ':' && req.url[6] == '/' && req.url[7] == '/')
        {
            isHttps = true;
        }
    }
    if (isHttps && !config.redirects.allowHttpsToHttpDowngrade)
    {
        curl_easy_setopt(handle, CURLoption.CURLOPT_REDIR_PROTOCOLS_STR, "https\0".ptr);
    }
    else
    {
        curl_easy_setopt(handle, CURLoption.CURLOPT_REDIR_PROTOCOLS_STR, "http,https\0".ptr);
    }

    // TLS Certificate Verification (TC-10)
    bool isTlsInsecure = (config.tlsMode == TlsMode.insecureOptIn) || (!config.verifyPeer) || (!config.verifyHost);
    if (isTlsInsecure)
    {
        recordInsecureTlsAudit();
        curl_easy_setopt(handle, CURLoption.CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(handle, CURLoption.CURLOPT_SSL_VERIFYHOST, 0L);
    }
    else
    {
        curl_easy_setopt(handle, CURLoption.CURLOPT_SSL_VERIFYPEER, 1L);
        curl_easy_setopt(handle, CURLoption.CURLOPT_SSL_VERIFYHOST, 2L);
    }

    if (config.acceptEncoding)
        curl_easy_setopt(handle, CURLoption.CURLOPT_ACCEPT_ENCODING, "\0".ptr);
    if (config.verbose)
        curl_easy_setopt(handle, CURLoption.CURLOPT_VERBOSE, 1L);

    // 6. Custom CA certificate bundle (CURLOPT_CAINFO) with fast-fail check
    if (config.caInfo !is null && config.caInfo.length > 0)
    {
        import core.sys.posix.unistd : access, R_OK;
        char[512] caBuf;
        const(char)* caCStr = null;
        if (config.caInfo.length + 1 <= caBuf.length)
        {
            caBuf[0 .. config.caInfo.length] = config.caInfo[];
            caBuf[config.caInfo.length] = '\0';
            caCStr = caBuf.ptr;
            if (access(caCStr, R_OK) != 0)
                throwCurlErrorNogc(CurlCode.CURLE_SSL_CACERT);
            curl_easy_setopt(handle, CURLoption.CURLOPT_CAINFO, caCStr);
        }
        else
        {
            char* dynCa = cast(char*) malloc(config.caInfo.length + 1);
            if (dynCa is null)
                throwCurlErrorNogc(CurlCode.CURLE_OUT_OF_MEMORY);
            scope (exit) free(dynCa);
            dynCa[0 .. config.caInfo.length] = config.caInfo[];
            dynCa[config.caInfo.length] = '\0';
            caCStr = dynCa;
            if (access(caCStr, R_OK) != 0)
                throwCurlErrorNogc(CurlCode.CURLE_SSL_CACERT);
            curl_easy_setopt(handle, CURLoption.CURLOPT_CAINFO, caCStr);
        }
    }

    // 7. Optional persistent Alt-Svc cache (ST-3)
    if (altSvcPath !is null)
    {
        curl_easy_setopt(handle, CURLoption.CURLOPT_ALTSVC, altSvcPath);
        if (altSvcCtrl != 0)
            curl_easy_setopt(handle, CURLoption.CURLOPT_ALTSVC_CTRL, altSvcCtrl);
    }

    version (SlateHttpDebug)
    {
        if (config.debugContext.sink !is null)
        {
            curl_easy_setopt(handle, CURLoption.CURLOPT_VERBOSE, 1L);
            curl_easy_setopt(handle, CURLoption.CURLOPT_DEBUGFUNCTION, &curlDebugCb);
            curl_easy_setopt(handle, CURLoption.CURLOPT_DEBUGDATA, cast(void*) &config.debugContext);
        }
    }
}

/// Synchronous HTTP Client owning a native libcurl easy handle (UB-1).
///
/// Features RAII handle management (UN-3), non-copyable move semantics, and
/// dual-mode execution (convenient dynamic path vs. zero-allocation `@nogc` hot path).
struct Client
{
    private CURL* _handle;
    private ClientConfig _config;

    @disable this(this); // Non-copyable value type (move semantics)

    /// Creates a Client with the given configuration options.
    private void ensureHandle() @trusted @nogc
    {
        if (_handle is null)
        {
            _handle = curl_easy_init();
            if (_handle is null)
                throwCurlErrorNogc(CurlCode.CURLE_FAILED_INIT);
        }
    }

    /// Creates a Client with the given configuration options.
    this(ClientConfig config) @trusted
    {
        _config = config;
        ensureHandle();
    }

    /// Convenience constructor with timeout in milliseconds.
    this(long timeoutMs) @safe
    {
        ClientConfig cfg;
        cfg.timeoutMs = timeoutMs;
        this(cfg);
    }

    /// Static factory creating an initialized `Client` with optional configuration.
    static Client create(ClientConfig config = ClientConfig.init) @trusted
    {
        return Client(config);
    }

    /// RAII destructor cleanly releasing the underlying libcurl easy handle (UN-3).
    ~this() @trusted @nogc nothrow
    {
        if (_handle !is null)
        {
            curl_easy_cleanup(_handle);
            _handle = null;
        }
    }

    /// Read-only access to client configuration.
    const(ClientConfig) config() const @safe pure nothrow
    {
        return _config;
    }

    /// Resets the underlying easy handle to default state for reuse.
    void reset() @trusted @nogc nothrow
    {
        if (_handle !is null)
            curl_easy_reset(_handle);
    }

    /// Returns the number of new successful connections made by the most recent transfer (ST-1).
    ///
    /// If an existing connection was reused from the connection cache, returns 0.
    long lastNumConnects() const @trusted @nogc nothrow
    {
        if (_handle is null)
            return 0;
        long num = 0;
        curl_easy_getinfo(cast(CURL*) _handle, CURLINFO.CURLINFO_NUM_CONNECTS, &num);
        return num;
    }

    // --- Low-level setup helper ---

    private void applyOptions(const Request req, const(char)* cUrl, out curl_slist* headerList) @trusted @nogc
    {
        ensureHandle();
        char[512] altSvcBuf;
        const(char)* altSvcCStr = null;
        if (_config.altSvcCachePath.length > 0)
        {
            if (_config.altSvcCachePath.length + 1 <= altSvcBuf.length)
            {
                altSvcBuf[0 .. _config.altSvcCachePath.length] = _config.altSvcCachePath[];
                altSvcBuf[_config.altSvcCachePath.length] = '\0';
                altSvcCStr = altSvcBuf.ptr;
            }
            else
            {
                char* dynAltSvc = cast(char*) malloc(_config.altSvcCachePath.length + 1);
                if (dynAltSvc is null)
                    throwCurlErrorNogc(CurlCode.CURLE_OUT_OF_MEMORY);
                dynAltSvc[0 .. _config.altSvcCachePath.length] = _config.altSvcCachePath[];
                dynAltSvc[_config.altSvcCachePath.length] = '\0';
                altSvcCStr = dynAltSvc;
            }
        }
        scope (exit)
        {
            if (altSvcCStr !is null && altSvcCStr != altSvcBuf.ptr)
                free(cast(void*) altSvcCStr);
        }
        applyRequestOptions(_handle, _config, req, cUrl, headerList, altSvcCStr, _config.altSvcCtrl);
    }

    // --- Hot-Path Execution (@nogc, caller-provided buffer) ---

    /// Performs an HTTP transfer strictly under `@safe @nogc` writing into `buffer` (UB-4, UN-1, EV-4).
    ///
    /// Throws a preallocated `CurlException` or `CancelledException` on error without invoking D garbage collection.
    Response perform(const Request req, ubyte[] buffer, CancellationToken* cancel = null) @trusted @nogc
        in (buffer.length > 0, "Buffer length must be greater than zero")
    {
        char[1024] urlBuf;
        const(char)* cUrl;
        if (req.url.length + 1 <= urlBuf.length)
        {
            urlBuf[0 .. req.url.length] = req.url[];
            urlBuf[req.url.length] = '\0';
            cUrl = urlBuf.ptr;
        }
        else
        {
            char* dynUrl = cast(char*) malloc(req.url.length + 1);
            if (dynUrl is null)
                throwCurlErrorNogc(CurlCode.CURLE_OUT_OF_MEMORY);
            dynUrl[0 .. req.url.length] = req.url[];
            dynUrl[req.url.length] = '\0';
            cUrl = dynUrl;
        }
        scope (exit)
        {
            if (cUrl != urlBuf.ptr && cUrl !is null)
                free(cast(void*) cUrl);
        }

        curl_slist* headerList = null;
        applyOptions(req, cUrl, headerList);

        BufferWriteCtx writeCtx = {buffer, 0, false};
        curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEFUNCTION, &clientBufferWriteCb);
        curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEDATA, &writeCtx);

        if (cancel !is null)
        {
            curl_easy_setopt(_handle, CURLoption.CURLOPT_NOPROGRESS, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFOFUNCTION, &xferInfoCancellationCb);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFODATA, cast(void*) cancel);
        }

        // Enforce cleanup on all return and throw paths (UN-3)
        scope (exit)
        {
            if (cancel !is null)
            {
                curl_easy_setopt(_handle, CURLoption.CURLOPT_NOPROGRESS, 1L);
                curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFOFUNCTION, null);
                curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFODATA, null);
            }
            curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEFUNCTION, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEDATA, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_HTTPHEADER, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_POSTFIELDS, cast(const(void)*) null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_CUSTOMREQUEST, cast(const(char)*) null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_POST, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_NOBODY, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_HTTPGET, 1L);
            if (headerList !is null)
                curl_slist_free_all(headerList);
            version (SlateHttpDebug)
            {
                if (_config.debugSink !is null)
                {
                    curl_easy_setopt(_handle, CURLoption.CURLOPT_VERBOSE, 0L);
                    curl_easy_setopt(_handle, CURLoption.CURLOPT_DEBUGFUNCTION, cast(void*) null);
                    curl_easy_setopt(_handle, CURLoption.CURLOPT_DEBUGDATA, cast(void*) null);
                }
            }
        }

        auto res = curl_easy_perform(_handle);
        if (res != CURLcode.CURLE_OK)
        {
            throwCurlErrorNogc(cast(CurlCode) res);
        }

        if (writeCtx.overflow)
        {
            throwCurlErrorNogc(CurlCode.CURLE_WRITE_ERROR);
        }

        long statusCode = 200;
        curl_easy_getinfo(_handle, CURLINFO.CURLINFO_RESPONSE_CODE, &statusCode);
        long rawVer = 0;
        curl_easy_getinfo(_handle, CURLINFO.CURLINFO_HTTP_VERSION, &rawVer);

        int finalStatus = cast(int) statusCode;
        if (finalStatus < 100 || finalStatus > 599)
            finalStatus = 200;

        return Response(finalStatus, null, buffer[0 .. writeCtx.written], mapCurlHttpVersion(rawVer));
    }

    /// Performs an HTTP transfer streaming response chunks via `onChunk` without full buffering (EV-3a, UB-4).
    ///
    /// Calls `onChunk` for each received network chunk strictly under `@safe @nogc`.
    Response performStream(const Request req, scope ChunkStreamHandler onChunk, void* userdata = null, CancellationToken* cancel = null) @trusted @nogc
    {
        char[1024] urlBuf;
        const(char)* cUrl;
        if (req.url.length + 1 <= urlBuf.length)
        {
            urlBuf[0 .. req.url.length] = req.url[];
            urlBuf[req.url.length] = '\0';
            cUrl = urlBuf.ptr;
        }
        else
        {
            char* dynUrl = cast(char*) malloc(req.url.length + 1);
            if (dynUrl is null)
                throwCurlErrorNogc(CurlCode.CURLE_OUT_OF_MEMORY);
            dynUrl[0 .. req.url.length] = req.url[];
            dynUrl[req.url.length] = '\0';
            cUrl = dynUrl;
        }
        scope (exit)
        {
            if (cUrl != urlBuf.ptr && cUrl !is null)
                free(cast(void*) cUrl);
        }

        curl_slist* headerList = null;
        applyOptions(req, cUrl, headerList);

        StreamWriteCtx streamCtx = {onChunk, userdata};
        curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEFUNCTION, &clientStreamWriteCb);
        curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEDATA, &streamCtx);

        if (cancel !is null)
        {
            curl_easy_setopt(_handle, CURLoption.CURLOPT_NOPROGRESS, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFOFUNCTION, &xferInfoCancellationCb);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFODATA, cast(void*) cancel);
        }

        scope (exit)
        {
            if (cancel !is null)
            {
                curl_easy_setopt(_handle, CURLoption.CURLOPT_NOPROGRESS, 1L);
                curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFOFUNCTION, null);
                curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFODATA, null);
            }
            curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEFUNCTION, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEDATA, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_HTTPHEADER, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_POSTFIELDS, cast(const(void)*) null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_CUSTOMREQUEST, cast(const(char)*) null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_POST, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_NOBODY, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_HTTPGET, 1L);
            if (headerList !is null)
                curl_slist_free_all(headerList);
            version (SlateHttpDebug)
            {
                if (_config.debugSink !is null)
                {
                    curl_easy_setopt(_handle, CURLoption.CURLOPT_VERBOSE, 0L);
                    curl_easy_setopt(_handle, CURLoption.CURLOPT_DEBUGFUNCTION, cast(void*) null);
                    curl_easy_setopt(_handle, CURLoption.CURLOPT_DEBUGDATA, cast(void*) null);
                }
            }
        }

        auto res = curl_easy_perform(_handle);
        if (res != CURLcode.CURLE_OK)
        {
            throwCurlErrorNogc(cast(CurlCode) res);
        }

        long statusCode = 200;
        curl_easy_getinfo(_handle, CURLINFO.CURLINFO_RESPONSE_CODE, &statusCode);
        long rawVer = 0;
        curl_easy_getinfo(_handle, CURLINFO.CURLINFO_HTTP_VERSION, &rawVer);

        int finalStatus = cast(int) statusCode;
        if (finalStatus < 100 || finalStatus > 599)
            finalStatus = 200;

        return Response(finalStatus, null, null, mapCurlHttpVersion(rawVer));
    }

    // --- Convenient Dynamic Execution (GC Allowed, Cold Path) ---

    /// Performs an HTTP transfer dynamically accumulating headers and body into a `Response` (EV-1).
    Response perform(const Request req, CancellationToken* cancel = null) @trusted
    {
        char[1024] urlBuf;
        const(char)* cUrl;
        if (req.url.length + 1 <= urlBuf.length)
        {
            urlBuf[0 .. req.url.length] = req.url[];
            urlBuf[req.url.length] = '\0';
            cUrl = urlBuf.ptr;
        }
        else
        {
            char* dynUrl = cast(char*) malloc(req.url.length + 1);
            if (dynUrl is null)
                enforceCurl(CurlCode.CURLE_OUT_OF_MEMORY);
            dynUrl[0 .. req.url.length] = req.url[];
            dynUrl[req.url.length] = '\0';
            cUrl = dynUrl;
        }
        scope (exit)
        {
            if (cUrl != urlBuf.ptr && cUrl !is null)
                free(cast(void*) cUrl);
        }

        curl_slist* headerList = null;
        try
        {
            applyOptions(req, cUrl, headerList);
        }
        catch (CurlException e)
        {
            if (e.code == CurlCode.CURLE_SSL_CACERT && _config.caInfo.length > 0)
            {
                import std.format : format;
                throw new CurlException(CurlCode.CURLE_SSL_CACERT,
                    format("Custom CA certificate bundle path is missing or unreadable: '%s'", _config.caInfo));
            }
            throw e;
        }

        DynamicBufferCtx bodyCtx;
        DynamicBufferCtx headerCtx;

        curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEFUNCTION, &clientDynamicWriteCb);
        curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEDATA, &bodyCtx);
        curl_easy_setopt(_handle, CURLoption.CURLOPT_HEADERFUNCTION, &clientHeaderCollectCb);
        curl_easy_setopt(_handle, CURLoption.CURLOPT_HEADERDATA, &headerCtx);

        if (cancel !is null)
        {
            curl_easy_setopt(_handle, CURLoption.CURLOPT_NOPROGRESS, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFOFUNCTION, &xferInfoCancellationCb);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFODATA, cast(void*) cancel);
        }

        scope (exit)
        {
            if (cancel !is null)
            {
                curl_easy_setopt(_handle, CURLoption.CURLOPT_NOPROGRESS, 1L);
                curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFOFUNCTION, null);
                curl_easy_setopt(_handle, CURLoption.CURLOPT_XFERINFODATA, null);
            }
            curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEFUNCTION, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_WRITEDATA, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_HEADERFUNCTION, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_HEADERDATA, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_HTTPHEADER, null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_POSTFIELDS, cast(const(void)*) null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_POSTFIELDSIZE_LARGE, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_CUSTOMREQUEST, cast(const(char)*) null);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_POST, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_NOBODY, 0L);
            curl_easy_setopt(_handle, CURLoption.CURLOPT_HTTPGET, 1L);
            if (headerList !is null)
                curl_slist_free_all(headerList);
            if (bodyCtx.ptr !is null)
                free(bodyCtx.ptr);
            if (headerCtx.ptr !is null)
                free(headerCtx.ptr);
            version (SlateHttpDebug)
            {
                if (_config.debugSink !is null)
                {
                    curl_easy_setopt(_handle, CURLoption.CURLOPT_VERBOSE, 0L);
                    curl_easy_setopt(_handle, CURLoption.CURLOPT_DEBUGFUNCTION, cast(void*) null);
                    curl_easy_setopt(_handle, CURLoption.CURLOPT_DEBUGDATA, cast(void*) null);
                }
            }
        }

        auto res = curl_easy_perform(_handle);
        if (res != CURLcode.CURLE_OK)
        {
            if (res == CURLcode.CURLE_SSL_CACERT && _config.caInfo.length > 0)
            {
                import std.format : format;
                throw new CurlException(CurlCode.CURLE_SSL_CACERT,
                    format("Custom CA certificate bundle path is missing or unreadable: '%s'", _config.caInfo));
            }
            enforceCurl(cast(CurlCode) res);
        }

        if (bodyCtx.oom || headerCtx.oom)
        {
            enforceCurl(CurlCode.CURLE_OUT_OF_MEMORY);
        }

        long statusCode = 200;
        curl_easy_getinfo(_handle, CURLINFO.CURLINFO_RESPONSE_CODE, &statusCode);
        long rawVer = 0;
        curl_easy_getinfo(_handle, CURLINFO.CURLINFO_HTTP_VERSION, &rawVer);

        int finalStatus = cast(int) statusCode;
        if (finalStatus < 100 || finalStatus > 599)
            finalStatus = 200;

        Header[] headers;
        if (headerCtx.len > 0)
        {
            headers = parseHeaders(cast(const(char)[]) headerCtx.ptr[0 .. headerCtx.len]);
        }

        const(ubyte)[] bodyPayload = null;
        if (bodyCtx.len > 0)
        {
            bodyPayload = bodyCtx.ptr[0 .. bodyCtx.len].dup;
        }

        return Response(finalStatus, headers, bodyPayload, mapCurlHttpVersion(rawVer));
    }

    /// Convenience helper for executing a GET request.
    Response get(string url, CancellationToken* cancel = null) @safe
    {
        return perform(Request.get(url), cancel);
    }

    /// Convenience helper for executing a POST request.
    Response post(string url, const(ubyte)[] bodyData = null, CancellationToken* cancel = null) @safe
    {
        return perform(Request.post(url, bodyData), cancel);
    }

    /// Convenience helper for executing any request specification.
    Response request(const Request req, CancellationToken* cancel = null) @safe
    {
        return perform(req, cancel);
    }
}

// --- Unittests for slate.http.client ---

version (unittest)
{
    import std.socket;
    import core.thread;

    /// Lightweight local HTTP/1.1 test server stub binding to an ephemeral OS loopback port.
    package class HttpStubServer
    {
        TcpSocket listener;
        ushort port;
        Thread thread;
        string responsePayload;
        bool running = true;
        string lastMethod;
        string lastRawRequest;
        int requestCount;
        bool keepAlive;
        int delayMs;

        this(string responsePayload = "Hello from Slate HTTP!", bool keepAlive = false, int delayMs = 0)
        {
            this.responsePayload = responsePayload;
            this.keepAlive = keepAlive;
            this.delayMs = delayMs;
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
            while (running)
            {
                try
                {
                    Socket client = listener.accept();
                    if (!running)
                    {
                        client.close();
                        break;
                    }
                    scope (exit) client.close();
                    client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(3));

                    while (running)
                    {
                        char[4096] reqBuf;
                        auto n = client.receive(reqBuf[]);
                        if (n <= 0)
                            break;

                        string reqStr = reqBuf[0 .. n].idup;
                        lastRawRequest = reqStr;
                        import std.string : indexOf;
                        auto spaceIdx = reqStr.indexOf(' ');
                        if (spaceIdx > 0)
                        {
                            lastMethod = reqStr[0 .. spaceIdx];
                        }
                        requestCount++;

                        if (delayMs > 0)
                        {
                            import core.thread : Thread, msecs;
                            Thread.sleep(msecs(delayMs));
                        }

                        import std.format : format;
                        string connHeader = keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n";
                        string resp = format("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: text/plain\r\n%s\r\n%s",
                            responsePayload.length, connHeader, responsePayload);
                        client.send(resp);

                        if (!keepAlive)
                            break;
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
            running = false;
            try
            {
                auto s = new TcpSocket();
                s.connect(new InternetAddress("127.0.0.1", port));
                s.close();
            }
            catch (Exception) {}
            try { listener.close(); } catch (Exception) {}
            if (thread !is null) { thread.join(); }
        }
    }
}

// Spec: libcurl error codes and curl_easy_perform failure mapping (EV-1, UN-3)
// Scenario: TC-05 error mapping
/// Example:
/// ---
/// import slate.http.client;
/// import slate.http.request;
/// import slate.http.error;
/// auto client = Client.create();
/// try {
///     auto res = client.perform(Request.get("http://127.0.0.1:1"));
/// } catch (CurlException e) {
///     assert(e.code == CurlCode.CURLE_COULDNT_CONNECT);
/// }
/// ---
unittest
{
    // Best practice: verify error code preservation and handle cleanup on connection failure
    auto client = Client(200); // 200ms timeout
    bool caught = false;
    try
    {
        client.perform(Request.get("http://127.0.0.1:1/"));
    }
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_COULDNT_CONNECT || e.code == CurlCode.CURLE_OPERATION_TIMEDOUT,
            "Expected connection error or timeout for unroutable port");
    }
    assert(caught, "TC-05: perform against closed port must throw CurlException");
}

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
    scope (exit) stub.close();

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
    scope (exit) stub.close();

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
    scope (exit) server.close();

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
    assert(server.lastMethod == "GET", "Reused handle must send GET, not previous PUT (CRIT-1): actual=" ~ server.lastMethod);
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
    scope (exit) server.close();

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
    scope (exit) stub.close();

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
    scope (exit) stub.close();

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
    scope (exit) server.close();

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
