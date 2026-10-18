module slate.http.error_test;

import slate.http.error;

// Spec: Exception propagation and code preservation for CurlException
/// Example:
/// ---
/// import slate.http.error;
/// try {
///     enforceCurl(CurlCode.CURLE_COULDNT_CONNECT);
/// } catch (CurlException e) {
///     assert(e.code == CurlCode.CURLE_COULDNT_CONNECT);
/// }
/// ---
unittest
{
    // Verify throw and catch preserves the error code
    bool caught = false;
    try
    {
        enforceCurl(CurlCode.CURLE_COULDNT_CONNECT);
    }
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_COULDNT_CONNECT, "CurlException must preserve error code");
        assert(e.msg.length > 0, "CurlException msg should be non-empty");
    }
    assert(caught, "enforceCurl must throw on error");

    // Success code should not throw
    enforceCurl(CurlCode.CURLE_OK);
}

// Spec: verify preallocated @nogc exception throwing without GC allocation
/// Example:
/// ---
/// import slate.http.error;
/// @nogc void riskyCall() {
///     enforceCurlNogc(CurlCode.CURLE_OPERATION_TIMEDOUT);
/// }
/// ---
unittest
{
    @nogc void performNogcCheck(CurlCode code)
    {
        enforceCurlNogc(code);
    }

    // Success path under @nogc does not throw
    performNogcCheck(CurlCode.CURLE_OK);

    // Failure path under @nogc throws preallocated exception
    bool caught = false;
    try
    {
        performNogcCheck(CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
        assert(e.msg == curlCodeDescription(CurlCode.CURLE_OPERATION_TIMEDOUT));
    }
    assert(caught, "enforceCurlNogc must throw on non-OK code");
}

// Spec: Thread safety of @nogc preallocated exceptions in worker threads
/// Example:
/// ---
/// import slate.http.error;
/// import core.thread : Thread;
/// auto t = new Thread({
///     enforceCurlNogc(CurlCode.CURLE_OPERATION_TIMEDOUT);
/// });
/// t.start();
/// t.join();
/// ---
unittest
{
    import core.thread : Thread;

    bool threadCaught = false;
    CurlCode caughtCode;

    auto t = new Thread({
        try
        {
            enforceCurlNogc(CurlCode.CURLE_OPERATION_TIMEDOUT);
        }
        catch (CurlException e)
        {
            threadCaught = true;
            caughtCode = e.code;
        }
    });
    t.start();
    t.join();

    assert(threadCaught,
            "Worker thread must successfully throw and catch preallocated CurlException");
    assert(caughtCode == CurlCode.CURLE_OPERATION_TIMEDOUT);
}

// Spec: RFC 9110 HTTP Semantics status code classification and HttpStatusException contracts
/// Example:
/// ---
/// import slate.http.error;
/// assert(isSuccess(200));
/// assert(isClientError(404));
/// try {
///     enforceSuccessStatus(500);
/// } catch (HttpStatusException e) {
///     assert(e.statusCode == 500);
/// }
/// ---
unittest
{
    // Status classification tests
    assert(isInformational(101));
    assert(!isInformational(200));

    assert(isSuccess(200));
    assert(isSuccess(204));
    assert(!isSuccess(404));

    assert(isRedirection(301));
    assert(isRedirection(302));

    assert(isClientError(400));
    assert(isClientError(404));
    assert(isClientError(429));

    assert(isServerError(500));
    assert(isServerError(502));
    assert(isServerError(503));

    // HttpStatusException throw/catch test
    bool caught = false;
    try
    {
        enforceSuccessStatus(404);
    }
    catch (HttpStatusException e)
    {
        caught = true;
        assert(e.statusCode == 404);
        assert(e.statusText == "Not Found");
    }
    assert(caught, "enforceSuccessStatus must throw for 404");

    // Success does not throw
    enforceSuccessStatus(200);

    // Verify @nogc constructor and reason phrase mapping
    auto ex = new HttpStatusException(503, "Service Unavailable");
    assert(ex.statusCode == 503);
    assert(ex.statusText == "Service Unavailable");

    // Negative contract tests: invalid status codes and CURLE_OK must trigger AssertError
    import std.exception : assertThrown;
    import core.exception : AssertError;

    assertThrown!AssertError(new CurlException(CurlCode.CURLE_OK));
    assertThrown!AssertError(new HttpStatusException(99));
    assertThrown!AssertError(new HttpStatusException(600));
}

// Spec: libcurl progress callback cancellation and error mapping (EV-4)
/// Example:
/// ---
/// import slate.http.error;
/// try {
///     throwCancelledNogc();
/// } catch (CancelledException e) {
///     assert(e.code == CurlCode.CURLE_ABORTED_BY_CALLBACK);
/// }
/// ---
unittest
{
    // Spec: verify CancelledException preserves CURLE_ABORTED_BY_CALLBACK under @nogc
    @nogc void checkCancel()
    {
        throwCancelledNogc();
    }

    bool caught = false;
    try
    {
        checkCancel();
    }
    catch (CancelledException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_ABORTED_BY_CALLBACK);
        assert(e.msg == "Transfer was cancelled");
    }
    assert(caught, "CancelledException must be caught as CancelledException");
}

// Spec: curl_multi_strerror(3) and CurlMultiException code preservation
/// Example:
/// ---
/// import slate.http.error;
/// try {
///     enforceCurlMulti(CurlMCode.CURLM_BAD_HANDLE);
/// } catch (CurlMultiException e) {
///     assert(e.code == CurlMCode.CURLM_BAD_HANDLE);
/// }
/// ---
unittest
{
    // Spec: verify CurlMultiException preserves code and @nogc preallocated throw
    assert(curlMCodeToString(CurlMCode.CURLM_OK) == "CURLM_OK");
    assert(curlMCodeToString(CurlMCode.CURLM_BAD_HANDLE) == "CURLM_BAD_HANDLE");
    assert(curlMultiStrerror(CurlMCode.CURLM_OK) !is null);

    bool caught = false;
    try
    {
        enforceCurlMulti(CurlMCode.CURLM_BAD_HANDLE);
    }
    catch (CurlMultiException e)
    {
        caught = true;
        assert(e.code == CurlMCode.CURLM_BAD_HANDLE);
    }
    assert(caught, "enforceCurlMulti must throw on error code");

    @nogc void checkMultiNogc()
    {
        enforceCurlMultiNogc(CurlMCode.CURLM_OUT_OF_MEMORY);
    }

    bool caughtNogc = false;
    try
    {
        checkMultiNogc();
    }
    catch (CurlMultiException e)
    {
        caughtNogc = true;
        assert(e.code == CurlMCode.CURLM_OUT_OF_MEMORY);
    }
    assert(caughtNogc, "enforceCurlMultiNogc must throw under @nogc");

    // Success code must not throw
    enforceCurlMulti(CurlMCode.CURLM_OK);
    enforceCurlMultiNogc(CurlMCode.CURLM_OK);
}

// Spec: CURLE_OPERATION_TIMEDOUT and CURLE_TOO_MANY_REDIRECTS typed exception mapping (TC-11)
/// Example:
/// ---
/// import slate.http.error;
/// try {
///     enforceCurl(CurlCode.CURLE_OPERATION_TIMEDOUT);
/// } catch (TimeoutException e) {
///     assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
/// }
/// ---
unittest
{
    // Spec: verify TimeoutException and TooManyRedirectsException in both GC and @nogc paths
    bool caughtTimeout = false;
    try
    {
        enforceCurl(CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    catch (TimeoutException e)
    {
        caughtTimeout = true;
        assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    assert(caughtTimeout);

    bool caughtTimeoutNogc = false;
    @nogc void checkTimeoutNogc()
    {
        throwCurlErrorNogc(CurlCode.CURLE_OPERATION_TIMEDOUT);
    }

    try
    {
        checkTimeoutNogc();
    }
    catch (TimeoutException e)
    {
        caughtTimeoutNogc = true;
        assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    assert(caughtTimeoutNogc);

    bool caughtRedir = false;
    try
    {
        enforceCurl(CurlCode.CURLE_TOO_MANY_REDIRECTS);
    }
    catch (TooManyRedirectsException e)
    {
        caughtRedir = true;
        assert(e.code == CurlCode.CURLE_TOO_MANY_REDIRECTS);
    }
    assert(caughtRedir);

    bool caughtRedirNogc = false;
    @nogc void checkRedirNogc()
    {
        throwCurlErrorNogc(CurlCode.CURLE_TOO_MANY_REDIRECTS);
    }

    try
    {
        checkRedirNogc();
    }
    catch (TooManyRedirectsException e)
    {
        caughtRedirNogc = true;
        assert(e.code == CurlCode.CURLE_TOO_MANY_REDIRECTS);
    }
    assert(caughtRedirNogc);
}
