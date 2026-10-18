/// HTTP Request value types, HTTP methods, versions, and builder helpers.
///
/// This module provides value-type `Request`, `Method`, `Header`, and `HttpVersion`
/// models (UB-1). Request validation uses `in` contracts to guarantee non-empty URLs
/// and valid methods. Builder methods provide a convenient, expressive API.
module slate.http.request;

import slate.http.c_bind;

/// HTTP request method conforming to RFC 9110 Section 9.
enum Method : string
{
    GET = "GET",
    POST = "POST",
    PUT = "PUT",
    DELETE = "DELETE",
    HEAD = "HEAD",
    PATCH = "PATCH",
    OPTIONS = "OPTIONS",
}

/// HTTP protocol version selection for request transfers (UB-1).
enum HttpVersion
{
    auto_, /// Negotiate highest supported protocol automatically via ALPN/Alt-Svc.
    h1_1, /// HTTP/1.1 strictly.
    h2, /// HTTP/2 (cleartext or TLS).
    h2Tls, /// HTTP/2 over TLS with HTTP/1.1 fallback on non-TLS.
    h2PriorKnowledge, /// HTTP/2 cleartext direct connection without HTTP/1.1 Upgrade (prior knowledge).
    h3, /// HTTP/3 (QUIC) with fallback to HTTP/2 or HTTP/1.1.
    h3Only, /// HTTP/3 (QUIC) strictly without silent downgrade (ST-2).
}

/// Maps an `HttpVersion` enum value to libcurl's `CURLOPT_HTTP_VERSION` integer constant.
pure @safe @nogc nothrow long toCurlHttpVersion(HttpVersion v)
{
    switch (v)
    {
    case HttpVersion.auto_:
        return CURL_HTTP_VERSION_NONE;
    case HttpVersion.h1_1:
        return CURL_HTTP_VERSION_1_1;
    case HttpVersion.h2:
        return CURL_HTTP_VERSION_2_0;
    case HttpVersion.h2Tls:
        return CURL_HTTP_VERSION_2TLS;
    case HttpVersion.h2PriorKnowledge:
        return CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE;
        version (HaveCurlHttp3)
        {
    case HttpVersion.h3:
            return CURL_HTTP_VERSION_3;
    case HttpVersion.h3Only:
            return CURL_HTTP_VERSION_3ONLY;
        }
        else
        {
    case HttpVersion.h3:
    case HttpVersion.h3Only:
            return CURL_HTTP_VERSION_NONE;
        }
    default:
        return CURL_HTTP_VERSION_NONE;
    }
}

/// Returns true if a string contains CR, LF, or NUL characters (F-62).
private bool containsCrlfOrNul(const(char)[] s) @safe pure @nogc nothrow
{
    foreach (c; s)
    {
        if (c == '\r' || c == '\n' || c == '\0')
            return true;
    }
    return false;
}

/// An HTTP header name-value pair.
struct Header
{
    string name;
    string value;
}

/// Immutable value-type HTTP request specification (UB-1).
///
/// Constructed with a non-empty URL and HTTP method. Fluent builder methods
/// operate on the cold configuration path and may allocate arrays for headers.
struct Request
{
    string url;
    Method method = Method.GET;
    Header[] headers;
    const(ubyte)[] bodyData;
    HttpVersion httpVersion = HttpVersion.auto_;
    long connectTimeoutMs = 0; /// Per-request connect timeout override in ms (0 = use client default)
    long timeoutMs = 0; /// Per-request total transfer timeout override in ms (0 = use client default)

    invariant
    {
        assert(url.length > 0, "Request URL cannot be empty");
        assert(!containsCrlfOrNul(url), "Request URL cannot contain CR, LF, or NUL");
    }

    /// Primary constructor enforcing non-empty URL.
    this(string url, Method method = Method.GET, HttpVersion httpVersion = HttpVersion.auto_) @safe pure @nogc nothrow
    in (url.length > 0, "Request URL must not be empty")
    in (!containsCrlfOrNul(url), "Request URL must not contain CR, LF, or NUL")
    {
        this.url = url;
        this.method = method;
        this.httpVersion = httpVersion;
    }

    /// Factory for a GET request.
    static Request get(string url) @safe pure @nogc nothrow
    in (url.length > 0, "Request URL must not be empty")
    in (!containsCrlfOrNul(url), "Request URL must not contain CR, LF, or NUL")
    {
        return Request(url, Method.GET);
    }

    /// Factory for a POST request.
    static Request post(string url, const(ubyte)[] bodyData = null) @safe pure @nogc nothrow
    in (url.length > 0, "Request URL must not be empty")
    in (!containsCrlfOrNul(url), "Request URL must not contain CR, LF, or NUL")
    {
        Request req = Request(url, Method.POST);
        req.bodyData = bodyData;
        return req;
    }

    /// Factory for a PUT request.
    static Request put(string url, const(ubyte)[] bodyData = null) @safe pure @nogc nothrow
    in (url.length > 0, "Request URL must not be empty")
    in (!containsCrlfOrNul(url), "Request URL must not contain CR, LF, or NUL")
    {
        Request req = Request(url, Method.PUT);
        req.bodyData = bodyData;
        return req;
    }

    /// Factory for a DELETE request.
    static Request delete_(string url) @safe pure @nogc nothrow
    in (url.length > 0, "Request URL must not be empty")
    in (!containsCrlfOrNul(url), "Request URL must not contain CR, LF, or NUL")
    {
        return Request(url, Method.DELETE);
    }

    /// Factory for a HEAD request.
    static Request head(string url) @safe pure @nogc nothrow
    in (url.length > 0, "Request URL must not be empty")
    in (!containsCrlfOrNul(url), "Request URL must not contain CR, LF, or NUL")
    {
        return Request(url, Method.HEAD);
    }

    /// Factory for a PATCH request.
    static Request patch(string url, const(ubyte)[] bodyData = null) @safe pure @nogc nothrow
    in (url.length > 0, "Request URL must not be empty")
    in (!containsCrlfOrNul(url), "Request URL must not contain CR, LF, or NUL")
    {
        Request req = Request(url, Method.PATCH);
        req.bodyData = bodyData;
        return req;
    }

    private Request clone() @safe pure const
    {
        Request copy = Request(this.url, this.method, this.httpVersion);
        copy.headers = this.headers.dup;
        copy.bodyData = this.bodyData;
        copy.connectTimeoutMs = this.connectTimeoutMs;
        copy.timeoutMs = this.timeoutMs;
        return copy;
    }

    /// Appends an HTTP header to the request (cold builder path, allocates header array).
    Request withHeader(string name, string value) @safe pure const
    in (name.length > 0, "Header name must not be empty")
    in (!containsCrlfOrNul(name), "Header name must not contain CR, LF, or NUL")
    in (!containsCrlfOrNul(value), "Header value must not contain CR, LF, or NUL")
    {
        Request copy = clone();
        copy.headers ~= Header(name, value);
        return copy;
    }

    /// Sets multiple HTTP headers (cold builder path).
    Request withHeaders(Header[] hdrs) @safe pure const
    {
        foreach (ref h; hdrs)
        {
            assert(h.name.length > 0, "Header name must not be empty");
            assert(!containsCrlfOrNul(h.name), "Header name must not contain CR, LF, or NUL");
            assert(!containsCrlfOrNul(h.value), "Header value must not contain CR, LF, or NUL");
        }
        Request copy = clone();
        copy.headers = hdrs.dup;
        return copy;
    }

    /// Attaches raw binary body data to the request.
    Request withBody(const(ubyte)[] data) @safe pure const
    {
        Request copy = clone();
        copy.bodyData = data;
        return copy;
    }

    /// Attaches a UTF-8 string body to the request.
    Request withBody(string text) @safe pure const
    {
        return withBody(cast(const(ubyte)[]) text);
    }

    /// Configures the target HTTP protocol version.
    Request withVersion(HttpVersion v) @safe pure const
    {
        Request copy = clone();
        copy.httpVersion = v;
        return copy;
    }

    /// Overrides connect and total timeouts for this request (TC-11).
    Request withTimeouts(long connectMs, long totalMs) @safe pure const
    in (connectMs >= 0 && totalMs >= 0, "Timeouts must be non-negative")
    {
        Request copy = clone();
        copy.connectTimeoutMs = connectMs;
        copy.timeoutMs = totalMs;
        return copy;
    }

    /// Overrides connect timeout for this request.
    Request withConnectTimeout(long connectMs) @safe pure const
    in (connectMs >= 0, "Connect timeout must be non-negative")
    {
        Request copy = clone();
        copy.connectTimeoutMs = connectMs;
        return copy;
    }

    /// Overrides total transfer timeout for this request.
    Request withTimeout(long totalMs) @safe pure const
    in (totalMs >= 0, "Timeout must be non-negative")
    {
        Request copy = clone();
        copy.timeoutMs = totalMs;
        return copy;
    }
}

// --- Unittests for slate.http.request ---

// Spec: RFC 9110 Section 9 HTTP Methods and Request Construction
/// Example:
/// ---
/// import slate.http.request;
/// auto req = Request.get("https://example.com/api")
///     .withHeader("Accept", "application/json")
///     .withVersion(HttpVersion.h2);
/// assert(req.url == "https://example.com/api");
/// assert(req.method == Method.GET);
/// ---
unittest
{
    // Spec: verify builder methods maintain immutability and valid state
    auto req1 = Request.get("https://api.example.com/items");
    assert(req1.url == "https://api.example.com/items");
    assert(req1.method == Method.GET);
    assert(req1.headers.length == 0);
    assert(req1.bodyData.length == 0);
    assert(req1.httpVersion == HttpVersion.auto_);

    auto req2 = req1.withHeader("Authorization", "Bearer token123")
        .withHeader("Accept", "application/json").withVersion(HttpVersion.h2Tls);

    // Verify req1 was untouched (value semantics)
    assert(req1.headers.length == 0);

    // Verify req2 fields
    assert(req2.headers.length == 2);
    assert(req2.headers[0].name == "Authorization");
    assert(req2.headers[0].value == "Bearer token123");
    assert(req2.headers[1].name == "Accept");
    assert(req2.headers[1].value == "application/json");
    assert(req2.httpVersion == HttpVersion.h2Tls);

    // Test POST with string body
    auto postReq = Request.post("https://api.example.com/items")
        .withBody(`{"name":"item1"}`).withHeader("Content-Type", "application/json");
    assert(postReq.method == Method.POST);
    assert(cast(string) postReq.bodyData == `{"name":"item1"}`);
}

// Spec: RFC 9110 Section 9.1 Method Idempotence and HttpVersion Mapping
/// Example:
/// ---
/// import slate.http.request;
/// import slate.http.c_bind;
/// assert(toCurlHttpVersion(HttpVersion.h2) == CURL_HTTP_VERSION_2_0);
/// assert(toCurlHttpVersion(HttpVersion.h3Only) == CURL_HTTP_VERSION_3ONLY);
/// ---
unittest
{
    // Verify exact mapping to libcurl CURLOPT_HTTP_VERSION constants
    assert(toCurlHttpVersion(HttpVersion.auto_) == CURL_HTTP_VERSION_NONE);
    assert(toCurlHttpVersion(HttpVersion.h1_1) == CURL_HTTP_VERSION_1_1);
    assert(toCurlHttpVersion(HttpVersion.h2) == CURL_HTTP_VERSION_2_0);
    assert(toCurlHttpVersion(HttpVersion.h2Tls) == CURL_HTTP_VERSION_2TLS);
    version (HaveCurlHttp3)
    {
        assert(toCurlHttpVersion(HttpVersion.h3) == CURL_HTTP_VERSION_3);
        assert(toCurlHttpVersion(HttpVersion.h3Only) == CURL_HTTP_VERSION_3ONLY);
    }

    // Verify contract on empty URL triggers assertion failure
    import std.exception : assertThrown;
    import core.exception : AssertError;

    assertThrown!AssertError(Request(""));
    assertThrown!AssertError(Request.get(""));
    assertThrown!AssertError(Request.post(""));
}

// Spec: Per-Request connect and transfer timeout overrides (TC-11)
/// Example:
/// ---
/// import slate.http.request;
/// auto req = Request.get("http://example.com")
///     .withTimeouts(5_000, 15_000);
/// assert(req.connectTimeoutMs == 5_000);
/// assert(req.timeoutMs == 15_000);
/// ---
unittest
{
    // Spec: verify Request timeout overrides maintain value semantics
    auto r1 = Request.get("http://example.com");
    assert(r1.connectTimeoutMs == 0);
    assert(r1.timeoutMs == 0);

    auto r2 = r1.withTimeouts(2_500, 8_000);
    assert(r1.connectTimeoutMs == 0); // r1 untouched
    assert(r2.connectTimeoutMs == 2_500);
    assert(r2.timeoutMs == 8_000);

    auto r3 = r1.withConnectTimeout(1_000);
    assert(r3.connectTimeoutMs == 1_000);
    assert(r3.timeoutMs == 0);

    auto r4 = r1.withTimeout(9_000);
    assert(r4.connectTimeoutMs == 0);
    assert(r4.timeoutMs == 9_000);
}
