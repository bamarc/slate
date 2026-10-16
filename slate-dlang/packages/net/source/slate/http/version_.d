/// libcurl version inspection and HTTP/2 + HTTP/3 protocol feature detection.
///
/// This module provides `@trusted @nogc nothrow` wrappers over libcurl's
/// `curl_version_info` API, query functions for HTTP/2 (`hasHttp2`) and
/// HTTP/3 (`hasHttp3`), and diagnostics for required backend capabilities (UB-3, EV-2a).
module slate.http.version_;

import slate.http.c_bind;

/// Minimum requirements for HTTP/2 support in libcurl.
enum string http2Requirements = "HTTP/2 requires libcurl >= 7.66 built with nghttp2.";

/// Minimum requirements for HTTP/3 and QUIC support in libcurl.
enum string http3Requirements = "HTTP/3 requires libcurl >= 8.6 built with ngtcp2+nghttp3 or quictls/OpenSSL 3.2+/BoringSSL/msh3.";

/// Snapshot of libcurl runtime version and feature information.
struct VersionInfo
{
    const(char)[] versionString;
    uint versionNumber;
    const(char)[] host;
    int features;
    const(char)[] sslVersion;
    const(char)[] libzVersion;
    const(char)[] brotliVersion;
    const(char)[] zstdVersion;
    const(char)[] nghttp2Version;
    const(char)[] quicVersion;
    const(char)[] cainfo;
    const(char)[] capath;

    /// Checks if HTTP/2 is supported.
    pure @safe @nogc nothrow bool hasHttp2() const
    {
        return (features & CURL_VERSION_HTTP2) != 0;
    }

    /// Checks if HTTP/3 is supported.
    pure @safe @nogc nothrow bool hasHttp3() const
    {
        return (features & CURL_VERSION_HTTP3) != 0;
    }

    /// Checks if Brotli compression is supported.
    pure @safe @nogc nothrow bool hasBrotli() const
    {
        return (features & CURL_VERSION_BROTLI) != 0;
    }

    /// Checks if Zstandard compression is supported.
    pure @safe @nogc nothrow bool hasZstd() const
    {
        return (features & CURL_VERSION_ZSTD) != 0;
    }

    /// Checks if SSL/TLS is supported.
    pure @safe @nogc nothrow bool hasSsl() const
    {
        return (features & CURL_VERSION_SSL) != 0;
    }

    /// Checks if Alt-Svc is supported.
    pure @safe @nogc nothrow bool hasAltSvc() const
    {
        return (features & CURL_VERSION_ALTSVC) != 0;
    }
}

/// Helper to safely create a slice from a null-terminated C string without GC allocation.
private pure const(char)[] fromCString(const(char)* p) @trusted @nogc nothrow
{
    if (p is null)
        return null;
    import core.stdc.string : strlen;

    return p[0 .. strlen(p)];
}

/// Retrieves the raw `curl_version_info_data` from libcurl.
private const(curl_version_info_data)* getRawVersionData() @trusted @nogc nothrow
{
    return curl_version_info(CURLVERSION_NOW);
}

/// Retrieves the runtime version information snapshot from libcurl.
VersionInfo getVersionInfo() @trusted @nogc nothrow
{
    auto data = getRawVersionData();
    if (data is null)
        return VersionInfo.init;

    VersionInfo info;
    info.versionString = fromCString(data.version_);
    info.versionNumber = data.version_num;
    info.host = fromCString(data.host);
    info.features = data.features;
    info.sslVersion = fromCString(data.ssl_version);
    info.libzVersion = fromCString(data.libz_version);

    // Guard extended fields by struct age to avoid out-of-bounds reads on older libcurl versions
    if (data.age >= CURLversion.CURLVERSION_FIFTH)
        info.brotliVersion = fromCString(data.brotli_version);
    if (data.age >= CURLversion.CURLVERSION_SIXTH)
    {
        info.nghttp2Version = fromCString(data.nghttp2_version);
        info.quicVersion = fromCString(data.quic_version);
    }
    if (data.age >= CURLversion.CURLVERSION_SEVENTH)
    {
        info.cainfo = fromCString(data.cainfo);
        info.capath = fromCString(data.capath);
    }
    if (data.age >= CURLversion.CURLVERSION_EIGHTH)
        info.zstdVersion = fromCString(data.zstd_version);

    return info;
}

/// Pure helper to test if an arbitrary features bitmask has HTTP/2 enabled.
pure @nogc nothrow bool hasHttp2(int features)
{
    return (features & CURL_VERSION_HTTP2) != 0;
}

/// Pure helper to test if an arbitrary features bitmask has HTTP/3 enabled.
pure @nogc nothrow bool hasHttp3(int features)
{
    return (features & CURL_VERSION_HTTP3) != 0;
}

/// Returns true if the currently linked libcurl supports HTTP/2 (UB-3).
bool hasHttp2() @trusted @nogc nothrow
{
    auto data = getRawVersionData();
    return data !is null && (data.features & CURL_VERSION_HTTP2) != 0;
}

/// Returns true if the currently linked libcurl supports HTTP/3 / QUIC (UB-3).
bool hasHttp3() @trusted @nogc nothrow
{
    auto data = getRawVersionData();
    return data !is null && (data.features & CURL_VERSION_HTTP3) != 0;
}

/// Returns true if the currently linked libcurl supports Alt-Svc.
bool hasAltSvc() @trusted @nogc nothrow
{
    auto data = getRawVersionData();
    return data !is null && (data.features & CURL_VERSION_ALTSVC) != 0;
}

/// Returns true if the currently linked libcurl supports Brotli compression.
bool hasBrotli() @trusted @nogc nothrow
{
    auto data = getRawVersionData();
    return data !is null && (data.features & CURL_VERSION_BROTLI) != 0;
}

/// Returns true if the currently linked libcurl supports Zstandard compression.
bool hasZstd() @trusted @nogc nothrow
{
    auto data = getRawVersionData();
    return data !is null && (data.features & CURL_VERSION_ZSTD) != 0;
}

/// Returns true if the currently linked libcurl supports SSL/TLS.
bool hasSsl() @trusted @nogc nothrow
{
    auto data = getRawVersionData();
    return data !is null && (data.features & CURL_VERSION_SSL) != 0;
}

/// Returns the libcurl full version string directly (e.g. "libcurl/8.18.0 OpenSSL/3.5.5...").
const(char)[] curlVersionString() @trusted @nogc nothrow
{
    const(char)* s = curl_version();
    return fromCString(s);
}

/// Returns the documented requirement message for HTTP/2 (EV-2a).
pure @safe nothrow string http2RequirementsMessage()
{
    return http2Requirements;
}

/// Returns the documented requirement message for HTTP/3 (EV-2a).
pure @safe nothrow string http3RequirementsMessage()
{
    return http3Requirements;
}

/// Returns an explanation when HTTP/3 is unavailable, naming the minimum libcurl and TLS backend (EV-2a).
string http3UnavailableExplanation() @safe
{
    if (hasHttp3())
        return "HTTP/3 is available in the currently linked libcurl.";

    import std.format : format;

    auto vi = getVersionInfo();
    return format("HTTP/3 is not supported by linked libcurl %s (SSL: %s). %s",
            vi.versionString, vi.sslVersion, http3Requirements);
}

/// Returns a human-readable diagnostic description of the libcurl backend and features.
/// GC allocation is permitted in this diagnostic function.
string describeBackend() @safe
{
    import std.format : format;
    import std.array : Appender;

    auto vi = getVersionInfo();
    Appender!string app;
    app.put(format("libcurl/%s (host: %s, ssl: %s, zlib: %s)\n",
            vi.versionString, vi.host, vi.sslVersion, vi.libzVersion));
    app.put(format("  HTTP/2: %s%s\n", vi.hasHttp2() ? "yes" : "no",
            vi.nghttp2Version.length ? format(" (nghttp2/%s)", vi.nghttp2Version) : ""));
    app.put(format("  HTTP/3: %s%s\n", vi.hasHttp3() ? "yes" : "no",
            vi.quicVersion.length ? format(" (%s)", vi.quicVersion) : ""));
    app.put(format("  Alt-Svc: %s, Brotli: %s, Zstd: %s\n", vi.hasAltSvc()
            ? "yes" : "no", vi.hasBrotli() ? (vi.brotliVersion.length
            ? format("%s", vi.brotliVersion) : "yes") : "no", vi.hasZstd()
            ? (vi.zstdVersion.length ? format("%s", vi.zstdVersion) : "yes") : "no"));
    if (vi.cainfo.length)
        app.put(format("  CA bundle: %s\n", vi.cainfo));

    return app.data;
}

// --- Unittests for slate.http.version_ ---

// Spec: curl_version_info(3) CURL_VERSION_HTTP2 and CURL_VERSION_HTTP3 feature bit flags
/// Example:
/// ---
/// import slate.http.version_;
/// // Pure @nogc bitmask check
/// enum featuresWithH2 = 1 << 16;
/// assert(hasHttp2(featuresWithH2));
/// assert(!hasHttp3(featuresWithH2));
/// ---
unittest
{
    // Best practice: test bitmask decoding in isolation without side effects
    enum int featuresH2Only = CURL_VERSION_HTTP2;
    enum int featuresH3Only = CURL_VERSION_HTTP3;
    enum int featuresBoth = CURL_VERSION_HTTP2 | CURL_VERSION_HTTP3;
    enum int featuresNone = 0;

    // Verify @nogc pure bitmask decoding
    assert(hasHttp2(featuresH2Only));
    assert(!hasHttp3(featuresH2Only));

    assert(!hasHttp2(featuresH3Only));
    assert(hasHttp3(featuresH3Only));

    assert(hasHttp2(featuresBoth));
    assert(hasHttp3(featuresBoth));

    assert(!hasHttp2(featuresNone));
    assert(!hasHttp3(featuresNone));

    // Test VersionInfo struct methods in @nogc
    VersionInfo mockInfo;
    mockInfo.features = featuresH2Only;
    assert(mockInfo.hasHttp2());
    assert(!mockInfo.hasHttp3());
}

// Spec: curl_version_info(3) and RFC 9114 HTTP/3 requirement verification (UB-3, EV-2a)
/// Example:
/// ---
/// import slate.http.version_;
/// if (!hasHttp3()) {
///     string reason = http3UnavailableExplanation();
///     assert(reason.length > 0);
/// }
/// ---
unittest
{
    // Live query against the linked libcurl
    auto vi = getVersionInfo();
    assert(vi.versionString.length > 0, "Version string should be non-empty");
    assert(vi.versionNumber > 0, "Version number should be greater than 0");
    assert(vi.versionNumber >= 0x080600, "libcurl >= 8.6 required");

    version (HaveCurlHttp3)
    {
        import slate.http.c_bind : CURL_HTTP_VERSION_3, CURL_HTTP_VERSION_3ONLY;

        static assert(CURL_HTTP_VERSION_3 == 30L, "CURL_HTTP_VERSION_3 must equal 30L");
        static assert(CURL_HTTP_VERSION_3ONLY == 31L, "CURL_HTTP_VERSION_3ONLY must equal 31L");
    }

    // The test machine has curl 8.18 with nghttp2 (H2 yes, H3 no)
    // Verify that hasHttp2() matches the feature bitmask
    bool expectedH2 = (vi.features & CURL_VERSION_HTTP2) != 0;
    bool expectedH3 = (vi.features & CURL_VERSION_HTTP3) != 0;

    assert(hasHttp2() == expectedH2, "hasHttp2() must match live feature bit");
    assert(hasHttp3() == expectedH3, "hasHttp3() must match live feature bit");

    // EV-2a: When H3 is missing, verify documented requirements message
    if (!hasHttp3())
    {
        string explanation = http3UnavailableExplanation();
        assert(explanation.length > 0);
        import std.string : indexOf;

        assert(explanation.indexOf("HTTP/3 requires libcurl >= 8.6") != -1,
                "Explanation must document the minimum libcurl version for H3");
        assert(explanation.indexOf("ngtcp2+nghttp3") != -1,
                "Explanation must document the required TLS/QUIC backends");
    }

    // Verify requirements constants
    assert(http2RequirementsMessage().length > 0);
    assert(http3RequirementsMessage().length > 0);
}

// Best practice: verify hot path functions execute strictly under @nogc
/// Example:
/// ---
/// import slate.http.version_;
/// @nogc void checkFeatures() {
///     bool h2 = hasHttp2();
///     bool h3 = hasHttp3();
///     auto info = getVersionInfo();
/// }
/// ---
unittest
{
    @nogc void hotPathCheck()
    {
        bool h2 = hasHttp2();
        bool h3 = hasHttp3();
        bool ssl = hasSsl();
        bool brotli = hasBrotli();
        bool zstd = hasZstd();
        bool altSvc = hasAltSvc();
        auto vi = getVersionInfo();
        const(char)[] verStr = curlVersionString();
        assert(verStr.length > 0);
    }

    hotPathCheck();
}

// Best practice: verify describeBackend returns diagnostic string with details
/// Example:
/// ---
/// import slate.http.version_;
/// string diag = describeBackend();
/// assert(diag.length > 0);
/// ---
unittest
{
    string desc = describeBackend();
    assert(desc.length > 0, "describeBackend should return a non-empty diagnostic string");
    import std.string : indexOf;

    assert(desc.indexOf("libcurl/") != -1, "describeBackend should mention libcurl");
    assert(desc.indexOf("HTTP/2:") != -1, "describeBackend should mention HTTP/2");
    assert(desc.indexOf("HTTP/3:") != -1, "describeBackend should mention HTTP/3");
}
