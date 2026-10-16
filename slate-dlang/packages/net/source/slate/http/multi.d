/// HTTP Multi Client, connection reuse, HTTP/2 multiplexing, and cooperative cancellation.
///
/// This module provides the `MultiClient` (ST-1), `MultiConfig`, and `CancellationToken` (EV-4)
/// value types. It implements pooled connection reuse across transfers, HTTP/2 multiplexing,
/// Alt-Svc cache management (ST-3), and cooperative cancellation with zero handle leaks (UN-3).
module slate.http.multi;

import slate.http.c_bind;
import slate.http.client;
import slate.http.error;
import slate.http.request;
import slate.http.response;
import slate.http.version_ : hasHttp3;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdlib : malloc, free, realloc;

/// Thread-safe cooperative cancellation token for in-flight HTTP transfers (EV-4).
struct CancellationToken
{
    private shared(bool)* _flag;
    private shared bool _localFlag = false;

    /// Constructs a CancellationToken referring to an external shared atomic flag.
    this(shared(bool)* externalFlag) @safe @nogc nothrow
    {
        _flag = externalFlag;
    }

    /// Signals cancellation to in-flight transfers.
    void cancel() scope @trusted @nogc nothrow
    {
        if (_flag !is null)
            atomicStore(*_flag, true);
        else
            atomicStore(_localFlag, true);
    }

    /// Returns true if cancellation has been signalled.
    bool isCancelled() const scope @trusted @nogc nothrow
    {
        if (_flag !is null)
            return atomicLoad(*_flag);
        return atomicLoad(_localFlag);
    }
}

/// Native C xferinfo progress callback checking CancellationToken (EV-4).
extern (C) int xferInfoCancellationCb(void* clientp, curl_off_t dltotal,
        curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow) @nogc nothrow
{
    if (clientp is null)
        return 0;
    auto token = cast(const(CancellationToken)*) clientp;
    if (token.isCancelled())
        return 1; // Non-zero return aborts libcurl transfer with CURLE_ABORTED_BY_CALLBACK
    return 0;
}

/// Configuration settings for MultiClient and connection pool management (ST-1, ST-3).
struct MultiConfig
{
    ClientConfig clientConfig;
    long maxHostConnections = 0; /// 0 = unlimited / libcurl default (CURLMOPT_MAX_HOST_CONNECTIONS)
    long maxTotalConnections = 0; /// 0 = unlimited / libcurl default (CURLMOPT_MAX_TOTAL_CONNECTIONS)
    long maxConcurrentStreams = 100; /// HTTP/2 max concurrent multiplex streams (CURLMOPT_MAX_CONCURRENT_STREAMS)
    long pipelining = CURLPIPE_MULTIPLEX; /// Enable HTTP/2 multiplexing (CURLMOPT_PIPELINING)
    string altSvcCachePath = null; /// Path to persistent Alt-Svc cache file (ST-3)
    long altSvcCtrl = CURLALTSVC_H1 | CURLALTSVC_H2 | CURLALTSVC_H3; /// Alt-Svc bitmask (ST-3)
    int pollTimeoutMs = 1000; /// Timeout in ms for curl_multi_poll/wait
}

/// Slot structure tracking an in-flight transfer attached to a multi handle.
private struct TransferSlot
{
    CURL* handle;
    char* dynUrl;
    char[1024] staticUrl;
    curl_slist* headerList;
    BufferWriteCtx writeCtx;
    bool done;
    bool inMulti;
    CURLcode result;
}

/// Asynchronous/Concurrent HTTP Client driving native libcurl multi handles (ST-1, ST-2, ST-3).
///
/// Manages connection pooling, HTTP/2 multiplexing, Alt-Svc routing, and batch execution.
struct MultiClient
{
    private CURLM* _multi;
    private MultiConfig _config;
    private int _activeHandles;
    private long _lastNumConnects;

    @disable this(this); // Non-copyable value type (move semantics, UN-3)

    /// Creates a MultiClient with the specified configuration.
    this(MultiConfig config) @trusted @nogc
    {
        _config = config;
        _multi = curl_multi_init();
        if (_multi !is null)
        {
            curl_multi_setopt(_multi, CURLMoption.CURLMOPT_PIPELINING, _config.pipelining);
            if (_config.maxHostConnections > 0)
                curl_multi_setopt(_multi, CURLMoption.CURLMOPT_MAX_HOST_CONNECTIONS,
                        _config.maxHostConnections);
            if (_config.maxTotalConnections > 0)
                curl_multi_setopt(_multi, CURLMoption.CURLMOPT_MAX_TOTAL_CONNECTIONS,
                        _config.maxTotalConnections);
            if (_config.maxConcurrentStreams > 0)
                curl_multi_setopt(_multi, CURLMoption.CURLMOPT_MAX_CONCURRENT_STREAMS,
                        _config.maxConcurrentStreams);
        }
    }

    /// Factory method for MultiClient.
    static MultiClient create(MultiConfig config = MultiConfig.init) @safe @nogc
    {
        return MultiClient(config);
    }

    /// Cleans up the native multi handle.
    ~this() @trusted @nogc nothrow
    {
        if (_multi !is null)
        {
            curl_multi_cleanup(_multi);
            _multi = null;
        }
    }

    private void ensureHandle() @trusted @nogc
    {
        if (_multi is null)
        {
            _multi = curl_multi_init();
            if (_multi !is null)
            {
                curl_multi_setopt(_multi, CURLMoption.CURLMOPT_PIPELINING, _config.pipelining);
                if (_config.maxHostConnections > 0)
                    curl_multi_setopt(_multi, CURLMoption.CURLMOPT_MAX_HOST_CONNECTIONS,
                            _config.maxHostConnections);
                if (_config.maxTotalConnections > 0)
                    curl_multi_setopt(_multi, CURLMoption.CURLMOPT_MAX_TOTAL_CONNECTIONS,
                            _config.maxTotalConnections);
                if (_config.maxConcurrentStreams > 0)
                    curl_multi_setopt(_multi, CURLMoption.CURLMOPT_MAX_CONCURRENT_STREAMS,
                            _config.maxConcurrentStreams);
            }
        }
    }

    /// Returns the number of currently active easy handles attached to this multi client.
    int activeHandleCount() const @safe @nogc nothrow
    {
        return _activeHandles;
    }

    /// Returns the total new connections created across the most recent execution (ST-1).
    long lastNumConnects() const @safe @nogc nothrow
    {
        return _lastNumConnects;
    }

    /// Returns the underlying native CURLM* handle.
    CURLM* handle() @safe @nogc nothrow
    {
        return _multi;
    }

    // --- Hot-Path Batch Execution (@nogc, caller-provided buffers) ---

    /// Performs multiple HTTP transfers concurrently under `@safe @nogc` writing into `buffers` (ST-1, EV-4).
    void performAll(const(Request)[] requests, ubyte[][] buffers,
            Response[] responses, CancellationToken* cancel = null) @trusted @nogc
    in (requests.length == buffers.length, "requests and buffers must have equal length")
    in (requests.length == responses.length, "requests and responses must have equal length")
    {
        if (requests.length == 0)
            return;

        if (cancel !is null && cancel.isCancelled())
            throwCancelledNogc();

        ensureHandle();

        // Prepare Alt-Svc C-string if configured (ST-3)
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

        // Allocate slots
        TransferSlot[16] staticSlots;
        TransferSlot* slotsPtr = null;
        if (requests.length <= staticSlots.length)
        {
            slotsPtr = staticSlots.ptr;
        }
        else
        {
            slotsPtr = cast(TransferSlot*) malloc(requests.length * TransferSlot.sizeof);
            if (slotsPtr is null)
                throwCurlErrorNogc(CurlCode.CURLE_OUT_OF_MEMORY);
        }
        TransferSlot[] slots = slotsPtr[0 .. requests.length];
        foreach (ref s; slots)
        {
            s = TransferSlot.init;
        }

        // Cleanup guarantee (UN-3, EV-4): all easy handles added to _multi MUST be removed and cleaned up
        scope (exit)
        {
            if (altSvcCStr !is null && altSvcCStr != altSvcBuf.ptr)
                free(cast(void*) altSvcCStr);

            foreach (ref s; slots)
            {
                if (s.inMulti)
                {
                    curl_multi_remove_handle(_multi, s.handle);
                    _activeHandles--;
                    s.inMulti = false;
                }
                if (s.handle !is null)
                {
                    curl_easy_cleanup(s.handle);
                    s.handle = null;
                }
                if (s.headerList !is null)
                {
                    curl_slist_free_all(s.headerList);
                    s.headerList = null;
                }
                if (s.dynUrl !is null)
                {
                    free(s.dynUrl);
                    s.dynUrl = null;
                }
            }
            if (slotsPtr != staticSlots.ptr && slotsPtr !is null)
                free(slotsPtr);
        }

        // Configure and attach easy handles
        foreach (i, ref req; requests)
        {
            auto easy = curl_easy_init();
            if (easy is null)
                throwCurlErrorNogc(CurlCode.CURLE_FAILED_INIT);
            slots[i].handle = easy;

            const(char)* cUrl;
            if (req.url.length + 1 <= slots[i].staticUrl.length)
            {
                slots[i].staticUrl[0 .. req.url.length] = req.url[];
                slots[i].staticUrl[req.url.length] = '\0';
                cUrl = slots[i].staticUrl.ptr;
            }
            else
            {
                slots[i].dynUrl = cast(char*) malloc(req.url.length + 1);
                if (slots[i].dynUrl is null)
                    throwCurlErrorNogc(CurlCode.CURLE_OUT_OF_MEMORY);
                slots[i].dynUrl[0 .. req.url.length] = req.url[];
                slots[i].dynUrl[req.url.length] = '\0';
                cUrl = slots[i].dynUrl;
            }

            applyRequestOptions(easy, _config.clientConfig, req, cUrl,
                    slots[i].headerList, altSvcCStr, _config.altSvcCtrl);

            slots[i].writeCtx = BufferWriteCtx(buffers[i], 0, false);
            curl_easy_setopt(easy, CURLoption.CURLOPT_WRITEFUNCTION, &clientBufferWriteCb);
            curl_easy_setopt(easy, CURLoption.CURLOPT_WRITEDATA, &slots[i].writeCtx);

            if (cancel !is null)
            {
                curl_easy_setopt(easy, CURLoption.CURLOPT_NOPROGRESS, 0L);
                curl_easy_setopt(easy, CURLoption.CURLOPT_XFERINFOFUNCTION,
                        &xferInfoCancellationCb);
                curl_easy_setopt(easy, CURLoption.CURLOPT_XFERINFODATA, cast(void*) cancel);
            }

            curl_easy_setopt(easy, CURLoption.CURLOPT_PIPEWAIT, 1L);
            curl_easy_setopt(easy, CURLoption.CURLOPT_QUICK_EXIT, 1L);

            auto addRes = curl_multi_add_handle(_multi, easy);
            enforceCurlMultiNogc(cast(CurlMCode) addRes);
            slots[i].inMulti = true;
            _activeHandles++;
        }

        // Event loop driving all transfers
        int running = 0;
        auto mc = curl_multi_perform(_multi, &running);
        enforceCurlMultiNogc(cast(CurlMCode) mc);

        while (running > 0)
        {
            if (cancel !is null && cancel.isCancelled())
                throwCancelledNogc();

            int numfds = 0;
            mc = curl_multi_poll(_multi, null, 0, _config.pollTimeoutMs, &numfds);
            enforceCurlMultiNogc(cast(CurlMCode) mc);

            mc = curl_multi_perform(_multi, &running);
            enforceCurlMultiNogc(cast(CurlMCode) mc);

            int msgsInQueue = 0;
            CURLMsg* msg;
            while ((msg = curl_multi_info_read(_multi, &msgsInQueue)) !is null)
            {
                if (msg.msg == CURLMSG.CURLMSG_DONE)
                {
                    foreach (ref s; slots)
                    {
                        if (s.handle == msg.easy_handle)
                        {
                            s.done = true;
                            s.result = msg.data.result;
                            break;
                        }
                    }
                }
            }
        }

        // Final message drain
        int msgsInQueue = 0;
        CURLMsg* msg;
        while ((msg = curl_multi_info_read(_multi, &msgsInQueue)) !is null)
        {
            if (msg.msg == CURLMSG.CURLMSG_DONE)
            {
                foreach (ref s; slots)
                {
                    if (s.handle == msg.easy_handle)
                    {
                        s.done = true;
                        s.result = msg.data.result;
                        break;
                    }
                }
            }
        }

        // Verify outcomes and populate responses
        long totalConnects = 0;
        foreach (i, ref s; slots)
        {
            if (s.result != CURLcode.CURLE_OK)
            {
                if (s.result == CURLcode.CURLE_ABORTED_BY_CALLBACK
                        || (cancel !is null && cancel.isCancelled()))
                    throwCancelledNogc();
                throwCurlErrorNogc(cast(CurlCode) s.result);
            }

            if (s.writeCtx.overflow)
                throwCurlErrorNogc(CurlCode.CURLE_WRITE_ERROR);

            long statusCode = 200;
            curl_easy_getinfo(s.handle, CURLINFO.CURLINFO_RESPONSE_CODE, &statusCode);
            long rawVer = 0;
            curl_easy_getinfo(s.handle, CURLINFO.CURLINFO_HTTP_VERSION, &rawVer);
            long connects = 0;
            curl_easy_getinfo(s.handle, CURLINFO.CURLINFO_NUM_CONNECTS, &connects);
            totalConnects += connects;

            int finalStatus = cast(int) statusCode;
            if (finalStatus < 100 || finalStatus > 599)
                finalStatus = 200;

            responses[i] = Response(finalStatus, null,
                    buffers[i][0 .. s.writeCtx.written], mapCurlHttpVersion(rawVer));
        }

        _lastNumConnects = totalConnects;
    }

    /// Single transfer execution under `@safe @nogc` reusing the MultiClient connection pool (ST-1).
    Response perform(const Request req, ubyte[] buffer, CancellationToken* cancel = null) @trusted @nogc
    {
        Response[1] resp;
        ubyte[][1] bufs = [buffer];
        const(Request)[1] reqs = [req];
        performAll(reqs[], bufs[], resp[], cancel);
        return resp[0];
    }

    // --- Dynamic Execution (GC Allowed, Cold Path) ---

    /// Performs multiple HTTP transfers dynamically accumulating responses with headers and body.
    Response[] performAll(const(Request)[] requests, CancellationToken* cancel = null) @trusted
    {
        if (requests.length == 0)
            return null;

        if (cancel !is null && cancel.isCancelled())
            throw new CancelledException();

        ensureHandle();

        // Prepare Alt-Svc C-string if configured (ST-3)
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
                    enforceCurl(CurlCode.CURLE_OUT_OF_MEMORY);
                dynAltSvc[0 .. _config.altSvcCachePath.length] = _config.altSvcCachePath[];
                dynAltSvc[_config.altSvcCachePath.length] = '\0';
                altSvcCStr = dynAltSvc;
            }
        }

        struct DynSlot
        {
            CURL* handle;
            char* dynUrl;
            char[1024] staticUrl;
            curl_slist* headerList;
            DynamicBufferCtx bodyCtx;
            DynamicBufferCtx headerCtx;
            bool done;
            bool inMulti;
            CURLcode result;
        }

        DynSlot[] slots = new DynSlot[requests.length];

        scope (exit)
        {
            if (altSvcCStr !is null && altSvcCStr != altSvcBuf.ptr)
                free(cast(void*) altSvcCStr);

            foreach (ref s; slots)
            {
                if (s.inMulti)
                {
                    curl_multi_remove_handle(_multi, s.handle);
                    _activeHandles--;
                    s.inMulti = false;
                }
                if (s.handle !is null)
                {
                    curl_easy_cleanup(s.handle);
                    s.handle = null;
                }
                if (s.headerList !is null)
                {
                    curl_slist_free_all(s.headerList);
                    s.headerList = null;
                }
                if (s.dynUrl !is null)
                {
                    free(s.dynUrl);
                    s.dynUrl = null;
                }
                if (s.bodyCtx.ptr !is null)
                {
                    free(s.bodyCtx.ptr);
                    s.bodyCtx.ptr = null;
                }
                if (s.headerCtx.ptr !is null)
                {
                    free(s.headerCtx.ptr);
                    s.headerCtx.ptr = null;
                }
            }
        }

        foreach (i, ref req; requests)
        {
            auto easy = curl_easy_init();
            if (easy is null)
                enforceCurl(CurlCode.CURLE_FAILED_INIT);
            slots[i].handle = easy;

            const(char)* cUrl;
            if (req.url.length + 1 <= slots[i].staticUrl.length)
            {
                slots[i].staticUrl[0 .. req.url.length] = req.url[];
                slots[i].staticUrl[req.url.length] = '\0';
                cUrl = slots[i].staticUrl.ptr;
            }
            else
            {
                slots[i].dynUrl = cast(char*) malloc(req.url.length + 1);
                if (slots[i].dynUrl is null)
                    enforceCurl(CurlCode.CURLE_OUT_OF_MEMORY);
                slots[i].dynUrl[0 .. req.url.length] = req.url[];
                slots[i].dynUrl[req.url.length] = '\0';
                cUrl = slots[i].dynUrl;
            }

            applyRequestOptions(easy, _config.clientConfig, req, cUrl,
                    slots[i].headerList, altSvcCStr, _config.altSvcCtrl);

            curl_easy_setopt(easy, CURLoption.CURLOPT_WRITEFUNCTION, &clientDynamicWriteCb);
            curl_easy_setopt(easy, CURLoption.CURLOPT_WRITEDATA, &slots[i].bodyCtx);
            curl_easy_setopt(easy, CURLoption.CURLOPT_HEADERFUNCTION, &clientHeaderCollectCb);
            curl_easy_setopt(easy, CURLoption.CURLOPT_HEADERDATA, &slots[i].headerCtx);

            if (cancel !is null)
            {
                curl_easy_setopt(easy, CURLoption.CURLOPT_NOPROGRESS, 0L);
                curl_easy_setopt(easy, CURLoption.CURLOPT_XFERINFOFUNCTION,
                        &xferInfoCancellationCb);
                curl_easy_setopt(easy, CURLoption.CURLOPT_XFERINFODATA, cast(void*) cancel);
            }

            curl_easy_setopt(easy, CURLoption.CURLOPT_PIPEWAIT, 1L);
            curl_easy_setopt(easy, CURLoption.CURLOPT_QUICK_EXIT, 1L);

            auto addRes = curl_multi_add_handle(_multi, easy);
            enforceCurlMulti(cast(CurlMCode) addRes);
            slots[i].inMulti = true;
            _activeHandles++;
        }

        int running = 0;
        auto mc = curl_multi_perform(_multi, &running);
        enforceCurlMulti(cast(CurlMCode) mc);

        while (running > 0)
        {
            if (cancel !is null && cancel.isCancelled())
                throw new CancelledException();

            int numfds = 0;
            mc = curl_multi_poll(_multi, null, 0, _config.pollTimeoutMs, &numfds);
            enforceCurlMulti(cast(CurlMCode) mc);

            mc = curl_multi_perform(_multi, &running);
            enforceCurlMulti(cast(CurlMCode) mc);

            int msgsInQueue = 0;
            CURLMsg* msg;
            while ((msg = curl_multi_info_read(_multi, &msgsInQueue)) !is null)
            {
                if (msg.msg == CURLMSG.CURLMSG_DONE)
                {
                    foreach (ref s; slots)
                    {
                        if (s.handle == msg.easy_handle)
                        {
                            s.done = true;
                            s.result = msg.data.result;
                            break;
                        }
                    }
                }
            }
        }

        int msgsInQueue = 0;
        CURLMsg* msg;
        while ((msg = curl_multi_info_read(_multi, &msgsInQueue)) !is null)
        {
            if (msg.msg == CURLMSG.CURLMSG_DONE)
            {
                foreach (ref s; slots)
                {
                    if (s.handle == msg.easy_handle)
                    {
                        s.done = true;
                        s.result = msg.data.result;
                        break;
                    }
                }
            }
        }

        Response[] results = new Response[requests.length];
        long totalConnects = 0;
        foreach (i, ref s; slots)
        {
            if (s.result != CURLcode.CURLE_OK)
            {
                if (s.result == CURLcode.CURLE_ABORTED_BY_CALLBACK
                        || (cancel !is null && cancel.isCancelled()))
                    throw new CancelledException();
                enforceCurl(cast(CurlCode) s.result);
            }

            if (s.bodyCtx.oom || s.headerCtx.oom)
                enforceCurl(CurlCode.CURLE_OUT_OF_MEMORY);

            long statusCode = 200;
            curl_easy_getinfo(s.handle, CURLINFO.CURLINFO_RESPONSE_CODE, &statusCode);
            long rawVer = 0;
            curl_easy_getinfo(s.handle, CURLINFO.CURLINFO_HTTP_VERSION, &rawVer);
            long connects = 0;
            curl_easy_getinfo(s.handle, CURLINFO.CURLINFO_NUM_CONNECTS, &connects);
            totalConnects += connects;

            int finalStatus = cast(int) statusCode;
            if (finalStatus < 100 || finalStatus > 599)
                finalStatus = 200;

            Header[] headers;
            if (s.headerCtx.len > 0)
                headers = parseHeaders(cast(const(char)[]) s.headerCtx.ptr[0 .. s.headerCtx.len]);

            const(ubyte)[] bodyPayload = null;
            if (s.bodyCtx.len > 0)
                bodyPayload = s.bodyCtx.ptr[0 .. s.bodyCtx.len].dup;

            results[i] = Response(finalStatus, headers, bodyPayload, mapCurlHttpVersion(rawVer));
        }

        _lastNumConnects = totalConnects;
        return results;
    }

    /// Single transfer dynamic execution reusing the MultiClient connection pool (ST-1).
    Response perform(const Request req, CancellationToken* cancel = null) @trusted
    {
        auto res = performAll([req], cancel);
        return res[0];
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
}

// --- Unittests for slate.http.multi ---

// Spec: RFC 9110 keep-alive connection reuse over curl_multi (ST-1)
// Scenario: TC-02 pooled reuse (ST-1)
/// Example:
/// ---
/// import slate.http.multi;
/// import slate.http.request;
/// auto client = MultiClient.create();
/// auto res1 = client.get("http://example.com/api");
/// auto res2 = client.get("http://example.com/api");
/// assert(client.lastNumConnects() == 0, "Second request reuses connection");
/// ---
unittest
{
    // Best practice: verify sequential connection reuse preserves keep-alive and numConnects == 0
    auto stub = new HttpStubServer("KeepAlive OK", true);
    scope (exit)
        stub.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/reuse", stub.port);

    auto client = MultiClient.create();

    // 1. First GET - requires establishing a new TCP connection (numConnects == 1)
    auto res1 = client.get(url);
    assert(res1.status == 200);
    assert(res1.bodyAsString() == "KeepAlive OK");
    assert(client.lastNumConnects() == 1, "First transfer must make 1 connection");

    // 2. Second GET - must reuse open connection (numConnects == 0)
    auto res2 = client.get(url);
    assert(res2.status == 200);
    assert(res2.bodyAsString() == "KeepAlive OK");
    assert(client.lastNumConnects() == 0,
            "Second transfer must reuse connection without reconnecting (ST-1)");
}

// Spec: RFC 9114 HTTP/3 and Alt-Svc protocol gating (ST-2, ST-3, EV-2b)
// Scenario: TC-06 no silent H3 downgrade
/// Example:
/// ---
/// import slate.http.multi;
/// import slate.http.request;
/// import slate.http.version_;
/// import slate.http.error;
/// if (!hasHttp3()) {
///     auto client = MultiClient.create();
///     try {
///         client.get("http://127.0.0.1:1/", null);
///     } catch (CurlException e) {
///         assert(e.code == CurlCode.CURLE_NOT_BUILT_IN);
///     }
/// }
/// ---
unittest
{
    // Best practice: verify h3Only fails fast without H3 support and does not silently fall back
    if (!hasHttp3())
    {
        auto client = MultiClient.create();
        bool caught = false;
        try
        {
            client.perform(Request.get("http://127.0.0.1:1/").withVersion(HttpVersion.h3Only));
        }
        catch (CurlException e)
        {
            caught = true;
            assert(e.code == CurlCode.CURLE_NOT_BUILT_IN,
                    "h3Only must throw CURLE_NOT_BUILT_IN (ST-2, EV-2b)");
        }
        assert(caught, "h3Only must fail fast when H3 is absent");
        assert(client.activeHandleCount() == 0, "No handles may leak on h3Only failure (UN-3)");
    }
}

// Spec: libcurl progress callback abort and handle cleanup (EV-4, UN-3)
// Scenario: TC-07 cancellation
/// Example:
/// ---
/// import slate.http.multi;
/// import slate.http.request;
/// import slate.http.error;
/// auto client = MultiClient.create();
/// CancellationToken cancel;
/// cancel.cancel();
/// try {
///     client.get("http://example.com/slow", &cancel);
/// } catch (CancelledException e) {
///     assert(client.activeHandleCount() == 0);
/// }
/// ---
unittest
{
    // Best practice: verify in-flight cancellation terminates transfer promptly and leaves 0 active handles
    auto stub = new HttpStubServer("Delayed response", false, 500); // 500ms delay
    scope (exit)
        stub.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/slow", stub.port);

    auto client = MultiClient.create();
    CancellationToken cancel;

    import core.thread : Thread;
    import core.time : dur;

    // Background thread signals cancellation shortly after transfer starts
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

    assert(caught, "Transfer must be aborted via CancelledException (EV-4)");
    assert(client.activeHandleCount() == 0,
            "activeHandleCount must be 0 after cancelled transfer (UN-3)");
}

// Best practice: zero-allocation batch execution and progress callback under @nogc
// Scenario: Hot-path @nogc batch execution
/// Example:
/// ---
/// import slate.http.multi;
/// import slate.http.request;
/// import slate.http.response;
/// @nogc void runBatch(MultiClient* client, const(Request)[] reqs) {
///     ubyte[1024] b1, b2;
///     ubyte[][2] bufs = [b1[], b2[]];
///     Response[2] resps;
///     client.performAll(reqs, bufs[], resps[]);
/// }
/// ---
unittest
{
    auto stub = new HttpStubServer("Nogc Batch Response", true);
    scope (exit)
        stub.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/nogc_batch", stub.port);

    auto client = MultiClient.create();

    @nogc void runNogcBatch(MultiClient* c, string targetUrl)
    {
        Request[2] reqs;
        reqs[0] = Request.get(targetUrl);
        reqs[1] = Request.get(targetUrl);

        ubyte[256] b1;
        ubyte[256] b2;
        ubyte[][2] bufs = [b1[], b2[]];
        Response[2] resps;

        c.performAll(reqs[], bufs[], resps[]);

        assert(resps[0].status == 200);
        assert(resps[0].bodyData == "Nogc Batch Response");
        assert(resps[1].status == 200);
        assert(resps[1].bodyData == "Nogc Batch Response");
    }

    runNogcBatch(&client, url);
    assert(client.activeHandleCount() == 0);
}

// Spec: Multi handle lifecycle and exception safety during mid-batch setup failure (UN-3, EV-2b)
// Scenario: TC-09 mid-batch setup failure leaves zero active handles
/// Example:
/// ---
/// import slate.http.multi;
/// import slate.http.request;
/// import slate.http.error;
/// auto client = MultiClient.create();
/// Request[2] reqs = [Request.get("http://127.0.0.1/"), Request.get("http://127.0.0.1/").withVersion(HttpVersion.h3Only)];
/// try { client.performAll(reqs); } catch (CurlException e) {}
/// assert(client.activeHandleCount() == 0);
/// ---
unittest
{
    // Best practice: verify activeHandleCount never underflows and handles are cleaned up if setup fails mid-batch
    if (!hasHttp3())
    {
        auto client = MultiClient.create();
        Request[2] reqs;
        reqs[0] = Request.get("http://127.0.0.1:1/first");
        reqs[1] = Request.get("http://127.0.0.1:1/second").withVersion(HttpVersion.h3Only);

        bool caught = false;
        try
        {
            client.performAll(reqs[]);
        }
        catch (CurlException e)
        {
            caught = true;
            assert(e.code == CurlCode.CURLE_NOT_BUILT_IN);
        }
        assert(caught, "Mid-batch h3Only must throw CURLE_NOT_BUILT_IN when H3 is absent");
        assert(client.activeHandleCount() == 0,
                "activeHandleCount must be exactly 0 (no underflow or handle leak) after mid-batch failure");
    }
}
