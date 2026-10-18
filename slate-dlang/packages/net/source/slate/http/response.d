/// HTTP Response value type, status inspection, headers, and @nogc byChunk streaming.
///
/// This module provides the value-type `Response` (UB-1), status code invariant
/// enforcement (`100..599`), and the `byChunk` input range operating over caller-provided
/// buffers without garbage collector allocation (UB-4, EV-3a).
module slate.http.response;

import slate.http.request : Header, HttpVersion;

/// Helper for case-insensitive ASCII comparison of header names (RFC 9110 Section 5.1).
pure @safe @nogc nothrow bool asciiCaseEquals(string a, string b)
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char c1 = a[i];
        char c2 = b[i];
        if (c1 >= 'A' && c1 <= 'Z')
            c1 += 32;
        if (c2 >= 'A' && c2 <= 'Z')
            c2 += 32;
        if (c1 != c2)
            return false;
    }
    return true;
}

/// Input range streaming chunks of response body data over a caller-provided buffer (EV-3a, UB-4).
///
/// Guarantees `@safe @nogc nothrow` execution with zero heap allocation.
struct ByChunk
{
    private const(ubyte)[] _source;
    private ubyte[] _chunkBuffer;
    private const(ubyte)[] _current;

@safe @nogc nothrow:

    /// Initializes the chunk streaming range over `source` using `chunkBuffer`.
    this(const(ubyte)[] source, ubyte[] chunkBuffer)
    in (chunkBuffer.length > 0, "chunkBuffer length must be greater than zero")
    {
        _source = source;
        _chunkBuffer = chunkBuffer;
        popFront();
    }

    /// Returns `true` when all chunks have been consumed.
    bool empty() const pure
    {
        return _current.length == 0;
    }

    /// Returns the current chunk slice residing in the caller buffer.
    const(ubyte)[] front() const pure
    {
        return _current;
    }

    /// Advances to the next chunk in the source body.
    void popFront()
    {
        if (_source.length == 0 || _chunkBuffer.length == 0)
        {
            _current = null;
            _source = null;
            return;
        }
        size_t n = _source.length < _chunkBuffer.length ? _source.length : _chunkBuffer.length;
        _chunkBuffer[0 .. n] = _source[0 .. n];
        _current = _chunkBuffer[0 .. n];
        _source = _source[n .. $];
    }
}

/// Value-type HTTP response representation (UB-1).
///
/// Preserves status code, headers, body payload, and negotiated HTTP version.
/// Enforces RFC 9110 status code validity via struct invariants.
struct Response
{
    int status = 200;
    Header[] headers;
    const(ubyte)[] bodyData;
    HttpVersion httpVersion = HttpVersion.h1_1;

    invariant
    {
        assert(status >= 100 && status <= 599, "HTTP status must be in range 100..599");
    }

    /// Primary constructor validating status code in range 100..599.
    this(int status, Header[] headers = null, const(ubyte)[] bodyData = null,
            HttpVersion httpVersion = HttpVersion.h1_1) @safe @nogc pure nothrow
    in (status >= 100 && status <= 599, "HTTP status code must be between 100 and 599")
    {
        this.status = status;
        this.headers = headers;
        this.bodyData = bodyData;
        this.httpVersion = httpVersion;
    }

    /// Returns the response body interpreted as a UTF-8 character slice.
    const(char)[] bodyAsString() const @trusted @nogc pure nothrow
    {
        return cast(const(char)[]) bodyData;
    }

    /// Checks if a header is present using case-insensitive matching.
    bool hasHeader(string name) const @safe pure nothrow
    {
        foreach (ref h; headers)
        {
            if (asciiCaseEquals(h.name, name))
                return true;
        }
        return false;
    }

    /// Returns the value of the first matching header, or null if not found.
    string header(string name) const @safe pure nothrow
    {
        foreach (ref h; headers)
        {
            if (asciiCaseEquals(h.name, name))
                return h.value;
        }
        return null;
    }

    /// Returns an input range streaming `bodyData` in slices up to `buffer.length` (UB-4, EV-3a).
    ByChunk byChunk(ubyte[] buffer) const @safe @nogc nothrow
    in (buffer.length > 0, "Buffer length must be greater than zero")
    {
        return ByChunk(bodyData, buffer);
    }
}

// --- Unittests for slate.http.response ---

// Spec: RFC 9110 Section 15 Response Status Codes and Value Representation
/// Example:
/// ---
/// import slate.http.response;
/// import slate.http.request : Header, HttpVersion;
/// auto res = Response(200, [Header("Content-Type", "application/json")], cast(const(ubyte)[]) `{"ok":true}`);
/// assert(res.status == 200);
/// assert(res.hasHeader("content-type"));
/// assert(res.header("CONTENT-TYPE") == "application/json");
/// assert(res.bodyAsString() == `{"ok":true}`);
/// ---
unittest
{
    // Spec: verify response status invariant and header case insensitivity
    auto res = Response(200, [
        Header("Content-Type", "application/json"),
        Header("X-Request-Id", "req-abc-123")
    ], cast(const(ubyte)[]) "hello world", HttpVersion.h2);

    assert(res.status == 200);
    assert(res.httpVersion == HttpVersion.h2);
    assert(res.hasHeader("content-type"));
    assert(res.hasHeader("Content-Type"));
    assert(res.hasHeader("CONTENT-TYPE"));
    assert(!res.hasHeader("Authorization"));
    assert(res.header("content-type") == "application/json");
    assert(res.header("X-Request-ID") == "req-abc-123");
    assert(res.header("non-existent") is null);
    assert(res.bodyAsString() == "hello world");

    // Negative contract test: out of range status code must trigger AssertError
    import std.exception : assertThrown;
    import core.exception : AssertError;

    assertThrown!AssertError(Response(99));
    assertThrown!AssertError(Response(600));
}

// Spec: RFC 9110 Framing & Chunked Stream Processing (EV-3a, UB-4)
/// Example:
/// ---
/// import slate.http.response;
/// auto res = Response(200, null, cast(const(ubyte)[]) "ABCDEFGHIJ");
/// ubyte[4] buf;
/// size_t totalBytes = 0;
/// foreach (chunk; res.byChunk(buf[])) {
///     totalBytes += chunk.length;
/// }
/// assert(totalBytes == 10);
/// ---
unittest
{
    // Spec: verify @nogc byChunk consumption across chunk boundaries
    @nogc void testNogcByChunk()
    {
        static immutable ubyte[10] payload = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        auto res = Response(200, null, payload[]);

        ubyte[3] buf;
        auto range = res.byChunk(buf[]);

        assert(!range.empty);
        assert(range.front == [1, 2, 3]);
        range.popFront();

        assert(!range.empty);
        assert(range.front == [4, 5, 6]);
        range.popFront();

        assert(!range.empty);
        assert(range.front == [7, 8, 9]);
        range.popFront();

        assert(!range.empty);
        assert(range.front == [10]);
        range.popFront();

        assert(range.empty);
    }

    testNogcByChunk();

    // Verify empty body yields empty range immediately
    auto emptyRes = Response(204);
    ubyte[16] buf;
    auto emptyRange = emptyRes.byChunk(buf[]);
    assert(emptyRange.empty);
}
