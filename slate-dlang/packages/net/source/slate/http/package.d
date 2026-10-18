/// HTTP networking module for Slate built directly on modern libcurl.
///
/// This package provides idiomatic, memory-safe D abstractions over libcurl 8.6+,
/// featuring pure `@nogc` execution paths, version and protocol negotiation
/// for HTTP/2 and HTTP/3 (QUIC), and typed exceptions without relying on `etc.c.curl`.
module slate.http;

public import slate.http.version_;
public import slate.http.error;
public import slate.http.request;
public import slate.http.response;
public import slate.http.client;
public import slate.http.multi;
public import slate.http.http_task;
public import slate.http.debug_;

private import slate.http.c_bind;

/// RAII helper for libcurl global initialization and cleanup.
struct CurlGlobal
{
    import core.sync.mutex : Mutex;

    private __gshared int _initCount = 0;
    private __gshared Mutex _mutex;

    shared static this()
    {
        _mutex = new Mutex();
        CurlGlobal.initialize();
    }

    shared static ~this()
    {
        CurlGlobal.cleanup();
    }

    /// Initializes libcurl globally with specified flags if not already initialized.
    /// Uses reference counting to support nested initializations safely.
    static void initialize(long flags = CURL_GLOBAL_DEFAULT) @trusted
    {
        synchronized (_mutex)
        {
            _initCount++;
            scope (failure)
                _initCount--;
            if (_initCount == 1)
            {
                auto res = curl_global_init(flags);
                enforceCurl(cast(CurlCode) res, "Failed to initialize libcurl globally");
            }
        }
    }

    /// Decrements the reference count and cleans up libcurl when it reaches 0.
    static void cleanup() @trusted
    {
        synchronized (_mutex)
        {
            if (_initCount > 0)
            {
                _initCount--;
                if (_initCount == 0)
                {
                    curl_global_cleanup();
                }
            }
        }
    }

    /// Returns true if libcurl has been initialized globally.
    static bool isInitialized() @trusted
    {
        synchronized (_mutex)
        {
            return _initCount > 0;
        }
    }
}

/// RAII guard managing `CurlGlobal` initialization and cleanup scope.
struct CurlGlobalGuard
{
    @disable this(this); // Non-copyable

    /// Initializes libcurl with specified flags.
    this(long flags) @trusted
    {
        CurlGlobal.initialize(flags);
    }

    /// Creates an RAII guard with default global flags.
    static CurlGlobalGuard create(long flags = CURL_GLOBAL_DEFAULT) @trusted
    {
        return CurlGlobalGuard(flags);
    }

    ~this() @trusted
    {
        CurlGlobal.cleanup();
    }
}

// --- Unittests for slate.http facade package ---

// Spec: curl_global_init(3) and curl_global_cleanup(3) lifecycle
/// Example:
/// ---
/// import slate.http;
/// auto guard = CurlGlobalGuard.create();
/// bool h2 = hasHttp2();
/// auto info = getVersionInfo();
/// assert(info.hasHttp2 == h2);
/// ---
unittest
{
    // Spec: manage global initialization with RAII guard
    auto guard = CurlGlobalGuard.create();
    assert(CurlGlobal.isInitialized());

    // Verify re-exported symbols from version_ and error
    bool h2 = hasHttp2();
    bool h3 = hasHttp3();
    auto info = getVersionInfo();
    assert(info.versionString.length > 0);
    assert(info.hasHttp2 == h2, "VersionInfo.hasHttp2 must match top-level hasHttp2()");
    assert(info.hasHttp3 == h3, "VersionInfo.hasHttp3 must match top-level hasHttp3()");

    // Verify error symbols are accessible through the facade
    CurlCode code = CurlCode.CURLE_OK;
    assert(curlCodeToString(code) == "CURLE_OK");

    // Verify exception hierarchy
    auto ex = new HttpStatusException(404);
    assert(ex.statusCode == 404);

    // Verify reference counting behavior
    assert(CurlGlobal.isInitialized());
    CurlGlobal.initialize();
    assert(CurlGlobal.isInitialized());
    CurlGlobal.cleanup();
    assert(CurlGlobal.isInitialized()); // Still initialized because outer guard holds a reference
}
