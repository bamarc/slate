/// Event-loop integration: run, quit, and cross-thread dispatch.
///
/// Mirrors the module-level functions both official bindings expose:
/// Node (`api/node/rust/lib.rs`: `invoke_from_event_loop`,
/// `quit_event_loop`, plus `process_events` for the libuv-driven loop —
/// see the upstream blog post "Slint and the Node.js Event Loop") and
/// Python (`api/python/slint/lib.rs`: `run_event_loop`,
/// `quit_event_loop`, `invoke_from_event_loop`, `set_xdg_app_id`, with
/// asyncio bridged in `slint/loop.py`).
///
/// Threading rule (same as Python's): create and touch components only on
/// the thread running the event loop; from worker threads, schedule work
/// with `invokeFromEventLoop`.
module slint.eventloop;

import slint.capi;

/// Spin the Slint event loop until `quitEventLoop` is called.
/// (Node: driven by libuv; Python: `run_event_loop`, asyncio-compatible.)
void runEventLoop()
{
    version (SlintNative)
    {
        import std.string : fromStringz;

        char* err = slint_run_event_loop();
        if (err !is null)
        {
            import slint.instance : SlintCallError;

            string msg = fromStringz(err).idup;
            slint_string_free(err);
            throw new SlintCallError(msg);
        }
    }
    else
    {
        import slint : NativeUnavailable;

        throw new NativeUnavailable("runEventLoop needs the native Slint runtime; " ~
            "rebuild with -version=SlintNative and link bridge/libslint_d_bridge.");
    }
}

/// Schedule event-loop termination, e.g. from a callback.
/// (Python: `quit_event_loop`.)
void quitEventLoop()
{
    version (SlintNative)
    {
        import std.string : fromStringz;

        char* err = slint_quit_event_loop();
        if (err !is null)
        {
            import slint.instance : SlintCallError;

            string msg = fromStringz(err).idup;
            slint_string_free(err);
            throw new SlintCallError(msg);
        }
    }
    else
    {
        import slint : NativeUnavailable;

        throw new NativeUnavailable("quitEventLoop needs the native Slint runtime; " ~
            "rebuild with -version=SlintNative and link bridge/libslint_d_bridge.");
    }
}

/// Run a D delegate on the event-loop thread, from any thread.
/// (Python: `invoke_from_event_loop`.) The delegate is one-shot: it is
/// deregistered after firing. This is how worker fibers/threads hand UI
/// updates back, instead of touching components off-thread.
void invokeFromEventLoop(void delegate() work)
{
    version (SlintNative)
    {
        import std.string : fromStringz;
        import slint.callback : callbacks, slintDCallbackShim;

        size_t id = callbacks.putVoid(work, true);
        scope (failure)
            callbacks.remove(id);
        char* err = slint_invoke_from_event_loop(&slintDCallbackShim, id);
        if (err !is null)
        {
            import slint.instance : SlintCallError;

            string msg = fromStringz(err).idup;
            slint_string_free(err);
            throw new SlintCallError(msg);
        }
    }
    else
    {
        import slint : NativeUnavailable;

        throw new NativeUnavailable("invokeFromEventLoop needs the native Slint runtime; " ~
            "rebuild with -version=SlintNative and link bridge/libslint_d_bridge.");
    }
}

/// Set the Wayland/X11 application id before the window is shown.
/// (Python: `set_xdg_app_id`.)
void setXdgAppId(string appId)
{
    version (SlintNative)
    {
        import std.string : fromStringz, toStringz;

        char* err = slint_set_xdg_app_id(appId.toStringz);
        if (err !is null)
        {
            import slint.instance : SlintCallError;

            string msg = fromStringz(err).idup;
            slint_string_free(err);
            throw new SlintCallError(msg);
        }
    }
    else
    {
        import slint : NativeUnavailable;

        throw new NativeUnavailable("setXdgAppId needs the native Slint runtime; " ~
            "rebuild with -version=SlintNative and link bridge/libslint_d_bridge.");
    }
}

// Callbacks scheduled from worker threads (`invokeFromEventLoop`) need a
// D-callable function pointer crossing the Rust bridge; that delegate
// trampoline is a later bridge phase. It is intentionally absent here so
// the declared surface never promises what the bridge cannot deliver yet.

///
unittest
{
    version (SlintNative)
    {
    }
    else
    {
        import std.exception : assertThrown;
        import slint : NativeUnavailable;

        assertThrown!NativeUnavailable(runEventLoop());
        assertThrown!NativeUnavailable(quitEventLoop());
        assertThrown!NativeUnavailable(invokeFromEventLoop(() {}));
        assertThrown!NativeUnavailable(setXdgAppId("org.example.app"));
    }
}
