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
    /// Set once the process is shutting down: libcurl is then left initialised.
    private __gshared bool _exiting = false;
    /// Number of `curl_global_cleanup` calls made (observable by tests).
    private __gshared size_t _globalCleanups = 0;

    shared static this()
    {
        _mutex = new Mutex();
        CurlGlobal.initialize();
    }

    /// Runs when the process exits. Daemon worker threads (`HttpTask`, `HttpMulti`) may still be
    /// inside libcurl at that point, and `curl_global_cleanup` is not thread-safe against them,
    /// so the module's own reference is released but libcurl itself is deliberately left
    /// initialised: the operating system reclaims it with the process.
    shared static ~this()
    {
        CurlGlobal.beginProcessExit();
    }

    /// Marks the process as exiting and releases the module's reference without tearing libcurl
    /// down, whatever the count reaches.
    static void beginProcessExit() @trusted
    {
        synchronized (_mutex)
        {
            _exiting = true;
        }
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
                if (_initCount == 0 && !_exiting)
                {
                    curl_global_cleanup();
                    _globalCleanups++;
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

/// Example:
/// ---
/// const cleanups = CurlGlobal._globalCleanups;
/// synchronized (CurlGlobal._mutex)    // one reference held, not yet exiting
/// {
///     CurlGlobal._initCount = 1;
///     CurlGlobal._exiting = false;
/// }
/// CurlGlobal.beginProcessExit();                // as the module destructor does
/// assert(CurlGlobal._globalCleanups == cleanups);   // curl_global_cleanup was not called
/// ---
// Spec: curl_global_cleanup(3) "This function is not thread safe. You must not call it when any
// other thread in the program (i.e. a thread sharing the same memory) is running." - the exit
// path must not tear libcurl down while daemon workers may still run; a normal balanced
// initialize/cleanup still does (R-43, W26)
@system unittest
{
    int savedCount;
    synchronized (CurlGlobal._mutex)
        savedCount = CurlGlobal._initCount;
    const savedCleanups = CurlGlobal._globalCleanups;
    scope (exit)
        synchronized (CurlGlobal._mutex)
        {
            CurlGlobal._initCount = savedCount;
            CurlGlobal._exiting = false;
        }

    // The counters are guarded by `_mutex`; the test takes it like the production code does.
    static void setState(int count, bool exiting) @trusted
    {
        synchronized (CurlGlobal._mutex)
        {
            CurlGlobal._initCount = count;
            CurlGlobal._exiting = exiting;
        }
    }

    static int count() @trusted
    {
        synchronized (CurlGlobal._mutex)
            return CurlGlobal._initCount;
    }

    static bool exiting() @trusted
    {
        synchronized (CurlGlobal._mutex)
            return CurlGlobal._exiting;
    }

    // Process exit: the last reference goes away, libcurl is not cleaned up.
    setState(1, false);
    CurlGlobal.beginProcessExit();
    assert(count == 0);
    assert(CurlGlobal._globalCleanups == savedCleanups, "no curl_global_cleanup at process exit");
    assert(exiting);

    // Nested use still balances and never cleans up below the module's own reference.
    setState(savedCount, false);
    CurlGlobal.initialize();
    assert(count == savedCount + 1);
    CurlGlobal.cleanup();
    assert(count == savedCount);
    assert(CurlGlobal.isInitialized);
    assert(CurlGlobal._globalCleanups == savedCleanups);
}
