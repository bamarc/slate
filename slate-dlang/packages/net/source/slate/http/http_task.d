/// Background HTTP task execution integrated with Slate UI event loop and tasks.
///
/// This module bridges `slate.http` transfers with `slate.tasks` (`spawnCompute` and `runCompute`),
/// forwarding download progress to UI components and marshaling completion callbacks to the
/// Slint UI event loop or caller dispatch thread without blocking UI rendering.
module slate.http.http_task;

import slate.http.c_bind;
import slate.http.client;
import slate.http.error;
import slate.http.request;
import slate.http.response;
import slate.tasks : TaskCancellation, runCompute, dispatchToUiEventLoop;

version (unittest)
{
    import slate.http.test_server : HttpStubServer;
}

import std.typecons : Nullable;
import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdlib : malloc, free;
import core.thread : Thread;

/// Progress context tracking transferred bytes and cancellation status across the C ABI boundary.
private struct HttpProgressContext
{
    shared(curl_off_t) dlnow;
    shared(curl_off_t) dltotal;
    TaskCancellation cancellation;
}

/// Native C xferinfo progress callback recording download telemetry under `@nogc nothrow` (UN-1, EV-4).
private extern (C) int httpTaskXferInfoCb(void* clientp, curl_off_t dltotal,
        curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow) @nogc nothrow
{
    if (clientp is null)
        return 0;
    auto ctx = cast(HttpProgressContext*) clientp;
    atomicStore(ctx.dlnow, dlnow);
    atomicStore(ctx.dltotal, dltotal);
    if (ctx.cancellation !is null && ctx.cancellation.isCancelled())
        return 1; // Aborts libcurl with CURLE_ABORTED_BY_CALLBACK
    return 0;
}

/// Drives an HTTP transfer on a background worker thread, reporting throttled progress (TC-08).
private Nullable!Response performTaskTransfer(const Request req,
        ClientConfig config, TaskCancellation cancellation, void delegate(float) progress) @trusted
{
    if (cancellation !is null && cancellation.isCancelled())
        return Nullable!Response.init;

    DynamicBufferCtx bodyCtx;
    bodyCtx.maxAllowed = config.maxResponseBytes;
    DynamicBufferCtx headerCtx;
    headerCtx.maxAllowed = config.maxHeaderBytes;

    scope (exit)
    {
        if (bodyCtx.ptr !is null)
            free(bodyCtx.ptr);
        if (headerCtx.ptr !is null)
            free(headerCtx.ptr);
    }

    CURLM* multi = curl_multi_init();
    if (multi is null)
        return Nullable!Response.init;
    scope (exit)
    {
        curl_multi_cleanup(multi);
    }

    CURL* easy = curl_easy_init();
    if (easy is null)
        return Nullable!Response.init;

    bool inMulti = false;
    scope (exit)
    {
        if (inMulti)
            curl_multi_remove_handle(multi, easy);
        version (SlateHttpDebug)
        {
            if (config.debugSink !is null)
            {
                curl_easy_setopt(easy, CURLoption.CURLOPT_VERBOSE, 0L);
                curl_easy_setopt(easy, CURLoption.CURLOPT_DEBUGFUNCTION, cast(void*) null);
                curl_easy_setopt(easy, CURLoption.CURLOPT_DEBUGDATA, cast(void*) null);
            }
        }
        curl_easy_cleanup(easy);
    }

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
            return Nullable!Response.init;
        dynUrl[0 .. req.url.length] = req.url[];
        dynUrl[req.url.length] = '\0';
        cUrl = dynUrl;
    }
    scope (exit)
    {
        if (cUrl != urlBuf.ptr && cUrl !is null)
            free(cast(void*) cUrl);
    }

    char[512] altSvcBuf;
    const(char)* altSvcCStr = null;
    if (config.altSvcCachePath.length > 0)
    {
        if (config.altSvcCachePath.length + 1 <= altSvcBuf.length)
        {
            altSvcBuf[0 .. config.altSvcCachePath.length] = config.altSvcCachePath[];
            altSvcBuf[config.altSvcCachePath.length] = '\0';
            altSvcCStr = altSvcBuf.ptr;
        }
        else
        {
            char* dynAltSvc = cast(char*) malloc(config.altSvcCachePath.length + 1);
            if (dynAltSvc !is null)
            {
                dynAltSvc[0 .. config.altSvcCachePath.length] = config.altSvcCachePath[];
                dynAltSvc[config.altSvcCachePath.length] = '\0';
                altSvcCStr = dynAltSvc;
            }
        }
    }
    scope (exit)
    {
        if (altSvcCStr !is null && altSvcCStr != altSvcBuf.ptr)
            free(cast(void*) altSvcCStr);
    }

    curl_slist* headerList = null;
    scope (exit)
    {
        if (headerList !is null)
            curl_slist_free_all(headerList);
    }

    try
    {
        applyRequestOptions(easy, config, req, cUrl, headerList, altSvcCStr, config.altSvcCtrl);
    }
    catch (Throwable)
    {
        return Nullable!Response.init;
    }

    curl_easy_setopt(easy, CURLoption.CURLOPT_WRITEFUNCTION, &clientDynamicWriteCb);
    curl_easy_setopt(easy, CURLoption.CURLOPT_WRITEDATA, &bodyCtx);
    curl_easy_setopt(easy, CURLoption.CURLOPT_HEADERFUNCTION, &clientHeaderCollectCb);
    curl_easy_setopt(easy, CURLoption.CURLOPT_HEADERDATA, &headerCtx);

    HttpProgressContext progCtx;
    progCtx.cancellation = cancellation;
    curl_easy_setopt(easy, CURLoption.CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(easy, CURLoption.CURLOPT_XFERINFOFUNCTION, &httpTaskXferInfoCb);
    curl_easy_setopt(easy, CURLoption.CURLOPT_XFERINFODATA, &progCtx);

    auto addRes = curl_multi_add_handle(multi, easy);
    if (addRes != CURLMcode.CURLM_OK)
        return Nullable!Response.init;
    inMulti = true;

    int running = 0;
    auto mc = curl_multi_perform(multi, &running);
    if (mc != CURLMcode.CURLM_OK && mc != CURLMcode.CURLM_CALL_MULTI_PERFORM)
        return Nullable!Response.init;

    while (running > 0)
    {
        if (cancellation !is null && cancellation.isCancelled())
            return Nullable!Response.init;

        // Telemetry is read on D thread outside C callback (UN-1)
        curl_off_t dlnow = atomicLoad(progCtx.dlnow);
        curl_off_t dltotal = atomicLoad(progCtx.dltotal);
        if (dltotal > 0 && progress !is null)
        {
            float pct = cast(float) dlnow / cast(float) dltotal;
            if (pct < 0.0f)
                pct = 0.0f;
            if (pct > 1.0f)
                pct = 1.0f;
            progress(pct);
        }

        int numfds = 0;
        mc = curl_multi_poll(multi, null, 0, 50, &numfds);
        if (mc != CURLMcode.CURLM_OK)
            return Nullable!Response.init;
        mc = curl_multi_perform(multi, &running);
        if (mc != CURLMcode.CURLM_OK && mc != CURLMcode.CURLM_CALL_MULTI_PERFORM)
            return Nullable!Response.init;
    }

    int msgsInQueue = 0;
    CURLMsg* msg = curl_multi_info_read(multi, &msgsInQueue);
    CURLcode result = CURLcode.CURLE_OK;
    while (msg !is null)
    {
        if (msg.msg == CURLMSG.CURLMSG_DONE)
        {
            result = msg.data.result;
            break;
        }
        msg = curl_multi_info_read(multi, &msgsInQueue);
    }

    if (result != CURLcode.CURLE_OK || (cancellation !is null && cancellation.isCancelled()))
        return Nullable!Response.init;

    if (bodyCtx.oom || headerCtx.oom || bodyCtx.overflow || headerCtx.overflow)
        return Nullable!Response.init;

    if (progress !is null)
        progress(1.0f);

    long statusCode = 0;
    curl_easy_getinfo(easy, CURLINFO.CURLINFO_RESPONSE_CODE, &statusCode);
    long rawVer = 0;
    curl_easy_getinfo(easy, CURLINFO.CURLINFO_HTTP_VERSION, &rawVer);

    if (statusCode < 100 || statusCode > 599)
        return Nullable!Response.init; // not a valid HTTP status (R-24)
    const int finalStatus = cast(int) statusCode;

    Header[] headers;
    if (headerCtx.len > 0)
        headers = parseHeaders(cast(const(char)[]) headerCtx.ptr[0 .. headerCtx.len]);

    const(ubyte)[] bodyPayload = null;
    if (bodyCtx.len > 0)
        bodyPayload = bodyCtx.ptr[0 .. bodyCtx.len].dup;

    return Nullable!Response(Response(finalStatus, headers, bodyPayload,
            mapCurlHttpVersion(rawVer)));
}

/// Synchronous core: runs an HTTP request under `runCompute!Response` on the calling thread.
///
/// Progress updates are coalesced and throttled via `slate.tasks.ProgressGate`.
/// Final completion callback is guaranteed to run through `dispatch` (TC-08).
Nullable!Response runHttpTask(const Request req, ClientConfig config, void delegate(float) onProgress = null,
        void delegate(Nullable!Response) onComplete = null,
        TaskCancellation cancellation = null, void delegate(void delegate()) dispatch = null)
{
    if (cancellation is null)
        cancellation = new TaskCancellation();
    if (dispatch is null)
        dispatch = (void delegate() job) { job(); };

    return runCompute!Response((bool delegate() isCancelled, void delegate(float) progress) {
        return performTaskTransfer(req, config, cancellation, progress);
    }, onProgress, onComplete, cancellation, dispatch);
}

/// Convenience overload for `runHttpTask` using default `ClientConfig`.
Nullable!Response runHttpTask(const Request req, void delegate(float) onProgress = null,
        void delegate(Nullable!Response) onComplete = null,
        TaskCancellation cancellation = null, void delegate(void delegate()) dispatch = null)
{
    return runHttpTask(req, ClientConfig.init, onProgress, onComplete, cancellation, dispatch);
}

/// Copies every buffer a `Request` refers to (URL, header names and values, body) onto the GC
/// heap, so the copy stays valid after the caller's stack frame is gone (F-64).
package Request detachRequest(const Request req) @trusted
{
    Request safeReq = Request(req.url.idup, req.method, req.httpVersion);
    if (req.headers.length > 0)
    {
        auto copiedHeaders = new Header[req.headers.length];
        foreach (i, h; req.headers)
            copiedHeaders[i] = Header(h.name.idup, h.value.idup);
        safeReq.headers = copiedHeaders;
    }
    safeReq.bodyData = req.bodyData ? req.bodyData.dup : null;
    safeReq.connectTimeoutMs = req.connectTimeoutMs;
    safeReq.timeoutMs = req.timeoutMs;
    return safeReq;
}

/// Spawns an HTTP request on a dedicated background worker thread.
///
/// Returns a `TaskCancellation` handle allowing cooperative abortion of the transfer (EV-4, TC-08).
/// On native builds, callbacks are dispatched through the Slint event loop (`slint.invokeFromEventLoop`).
TaskCancellation spawnHttpTask(const Request req, ClientConfig config = ClientConfig.init,
        void delegate(float) onProgress = null, void delegate(Nullable!Response) onComplete = null) @trusted
{
    // Deep copy Request data to avoid cross-thread dangling stack references (F-64)
    Request safeReq = detachRequest(req);

    auto cancellation = new TaskCancellation();
    auto worker = new Thread({
        void delegate(void delegate() job) dispatch = (void delegate() job) {
            dispatchToUiEventLoop(job);
        };
        runHttpTask(safeReq, config, onProgress, onComplete, cancellation, dispatch);
    });
    worker.isDaemon = true;
    worker.start();
    return cancellation;
}

/// Convenience helper for spawning a background GET request.
TaskCancellation spawnHttpGet(string url, void delegate(float) onProgress = null,
        void delegate(Nullable!Response) onComplete = null)
{
    return spawnHttpTask(Request.get(url), ClientConfig.init, onProgress, onComplete);
}

// --- Unittests for slate.http.http_task ---

// Spec: Slint UI / Background compute integration with progress and cancellation (TC-08)
// Scenario: TC-08 background fetch completion and progress
/// Example:
/// ---
/// import slate.http.http_task;
/// import slate.http.request;
/// auto cancel = spawnHttpGet("http://example.com/api",
///     (float progress) { /* update UI progress bar */ },
///     (res) { if (!res.isNull) { /* process response on UI thread */ } });
/// ---
unittest
{
    // Spec: verify background HTTP task runs to completion, reports progress, and notifies onComplete
    auto stub = new HttpStubServer("Task Transfer Completed Successfully", false, 0);
    scope (exit)
        stub.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/task_get", stub.port);

    float lastProgress = 0.0f;
    bool completed = false;
    Nullable!Response finalResponse;

    void onProgress(float pct)
    {
        lastProgress = pct;
    }

    void onComplete(Nullable!Response res)
    {
        completed = true;
        finalResponse = res;
    }

    bool dispatchCalled = false;
    void testDispatch(void delegate() job)
    {
        dispatchCalled = true;
        job();
    }

    auto cancellation = new TaskCancellation();
    auto res = runHttpTask(Request.get(url), ClientConfig.init, &onProgress,
            &onComplete, cancellation, &testDispatch);

    assert(!res.isNull, "Expected successful response");
    assert(res.get.status == 200);
    assert(res.get.bodyAsString() == "Task Transfer Completed Successfully");
    assert(completed, "Expected onComplete to be called");
    assert(!finalResponse.isNull);
    assert(dispatchCalled, "Expected dispatch callback to be invoked");
}

// Spec: Slint UI / Background compute cancellation (EV-4, TC-08)
// Scenario: TC-08 background fetch cancellation
/// Example:
/// ---
/// import slate.http.http_task;
/// import slate.http.request;
/// auto cancel = spawnHttpGet("http://example.com/slow");
/// cancel.cancel();
/// ---
unittest
{
    // Spec: verify in-flight task cancellation aborts transfer cleanly and reports null result
    auto stub = new HttpStubServer("Delayed task response", false, 500);
    scope (exit)
        stub.close();

    import std.format : format;

    string url = format("http://127.0.0.1:%d/slow_task", stub.port);

    bool completed = false;
    Nullable!Response finalResponse;

    auto cancel = spawnHttpGet(url, null, (res) {
        completed = true;
        finalResponse = res;
    });

    import core.time : dur;

    Thread.sleep(dur!"msecs"(50));
    cancel.cancel();

    int waited = 0;
    while (!completed && waited < 20)
    {
        Thread.sleep(dur!"msecs"(50));
        waited++;
    }

    assert(completed, "Cancelled task must complete");
    assert(finalResponse.isNull, "Cancelled task result must be null");
}

/// Example:
/// ---
/// char[32] stackUrl;
/// const src = "http://127.0.0.1:1/stack";
/// stackUrl[0 .. src.length] = src[];
/// auto req = Request.get(cast(string) stackUrl[0 .. src.length]);   // built over a stack buffer
/// auto safe = detachRequest(req);
/// assert(safe.url.ptr !is req.url.ptr && safe.url == src);
/// stackUrl[] = 'X';                   // the caller's frame is reused
/// assert(safe.url == "http://127.0.0.1:1/stack");
/// ---
// Spec: spawnHttpTask hands the request to another thread, so every buffer it refers to is
// copied first (F-64): the URL, header names and values, and the body must live in memory that
// no longer aliases the caller's stack, and survive that stack being overwritten (R-45)
unittest
{
    char[32] stackUrl;
    const src = "http://127.0.0.1:1/stack";
    stackUrl[0 .. src.length] = src[];
    char[8] stackName = "X-Stack:"[0 .. 8];
    char[5] stackValue = "value";
    ubyte[4] stackBody = [1, 2, 3, 4];

    auto req = Request.post(cast(string) stackUrl[0 .. src.length], stackBody[]);
    req.headers = [
        Header(cast(string) stackName[0 .. 7], cast(string) stackValue[])
    ];
    req.timeoutMs = 1234;
    req.connectTimeoutMs = 99;

    auto safe = detachRequest(req);
    assert(safe.url.ptr !is req.url.ptr && safe.url == src);
    assert(safe.headers.length == 1);
    assert(safe.headers[0].name.ptr !is req.headers[0].name.ptr);
    assert(safe.headers[0].value.ptr !is req.headers[0].value.ptr);
    assert(safe.bodyData.ptr !is stackBody.ptr);
    assert(safe.method == Method.POST && safe.timeoutMs == 1234 && safe.connectTimeoutMs == 99);

    // The caller's frame is reused: the detached copy is unaffected.
    stackUrl[] = 'X';
    stackName[] = 'Y';
    stackValue[] = 'Z';
    stackBody[] = 0xff;
    assert(safe.url == src);
    assert(safe.headers[0].name == "X-Stack" && safe.headers[0].value == "value");
    assert(safe.bodyData == [1, 2, 3, 4]);

    // spawnHttpTask itself still works on such a request.
    auto cancel = spawnHttpTask(Request.get(src.idup));
    assert(cancel !is null);
    cancel.cancel();
}

/// Example:
/// ---
/// import std.format : format;
///
/// auto stub = new HttpStubServer("body", false, 0);
/// scope (exit)
///     stub.close();
/// stub.statusCode = 600;                           // not a valid HTTP status
/// auto res = runHttpTask(Request.get(format("http://127.0.0.1:%d/weird", stub.port)));
/// assert(res.isNull);                              // no Response is built; onComplete gets null
/// ---
// Spec: RFC 9110 Section 15 - "All valid status codes are within the range of 100 to 599,
// inclusive." The background task reports failure through an empty Nullable (it has no exception
// channel), so a status outside that range completes with Nullable.init instead of building a
// Response whose invariant would fail; the other perform variants throw CURLE_WEIRD_SERVER_REPLY
// (R-24, W9)
unittest
{
    import std.format : format;

    foreach (status; [600, 99])
    {
        auto stub = new HttpStubServer("body", false, 0);
        scope (exit)
            stub.close();
        stub.statusCode = status;
        const url = format("http://127.0.0.1:%d/weird", stub.port);

        bool completed = false;
        Nullable!Response seen;
        auto res = runHttpTask(Request.get(url), ClientConfig.init, null, (Nullable!Response r) {
            completed = true;
            seen = r;
        }, null, (void delegate() job) { job(); });
        assert(res.isNull, "an invalid status must not produce a Response");
        assert(completed && seen.isNull, "onComplete still runs, with no response");

        // `runCompute` turns any Throwable into an empty result, so also check the transfer
        // itself: it must return an empty Nullable and not trip Response's contract.
        auto direct = performTaskTransfer(Request.get(url), ClientConfig.init,
                new TaskCancellation(), (float) {});
        assert(direct.isNull, "the transfer reports an invalid status as no response");
    }

    // A valid status in the same setup does produce one.
    auto ok = new HttpStubServer("body", false, 0);
    scope (exit)
        ok.close();
    ok.statusCode = 599;
    auto res = runHttpTask(Request.get(format("http://127.0.0.1:%d/edge", ok.port)));
    assert(!res.isNull && res.get.status == 599, "599 is the highest valid status");
}
