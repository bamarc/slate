/// Timers firing D delegates on the Slint event-loop thread.
///
/// Mirrors `Timer` / `TimerMode` in `api/python/slint/timer.rs`: single-shot
/// or repeated callbacks driven by the event loop. Keep the `Timer` object
/// alive for as long as it should fire; `stop()` (or destruction) disarms.
///
/// In pure-D builds the timer is bookkeeping only (mode/interval/callback
/// are stored and inspectable, nothing fires). Native builds arm a real
/// `i-slint-core` timer whose callback dispatches through the
/// `slint.callback` registry, so D delegates — including fiber resumptions
/// from `slint.fiber` — run on the loop thread.
module slint.timer;

import slint.capi;

/// What happens after a timer fires. (Python: `TimerMode`.)
enum TimerMode
{
    SingleShot,
    Repeated,
}

/// Handle to a scheduled timer.
class Timer
{
    private TimerMode _mode = TimerMode.SingleShot;
    private long _intervalMsecs;
    private void delegate() _callback;
    private bool _running;

    version (SlintNative)
    {
        private size_t _cbId;
    }

    version (SlintNative)
    {
        private SlintTimer* _handle;

        ~this() @system
        {
            stop();
            if (_handle !is null)
            {
                slint_timer_free(_handle);
                _handle = null;
            }
        }

        private SlintTimer* handle() @system
        {
            import slint : NativeUnavailable;

            if (_handle is null)
            {
                _handle = slint_timer_new();
                if (_handle is null)
                    throw new NativeUnavailable("slint_timer_new failed");
            }
            return _handle;
        }
    }

    this() @safe pure nothrow
    {
    }

    /// Arm the timer. (Python: `Timer.start(mode, interval, callback)`.)
    /// Restarting a running timer replaces its schedule and callback.
    void start(TimerMode mode, long intervalMsecs, void delegate() callback)
    {
        version (SlintNative)
        {
            import std.string : fromStringz;
            import slint.callback : callbacks, slintDCallbackShim;
            import slint.instance : SlintCallError;

            stop();
            _mode = mode;
            _intervalMsecs = intervalMsecs;
            _callback = callback;
            size_t id = callbacks.putVoid(callback);
            scope (failure)
            {
                callbacks.remove(id);
                _callback = null;
            }
            char* err = slint_timer_start(handle(), mode == TimerMode.SingleShot
                    ? 1 : 0, cast(ulong) intervalMsecs, &slintDCallbackShim, id);
            if (err !is null)
            {
                string msg = fromStringz(err).idup;
                slint_string_free(err);
                throw new SlintCallError(msg);
            }
            _cbId = id;
            _running = true;
        }
        else
        {
            _mode = mode;
            _intervalMsecs = intervalMsecs;
            _callback = callback;
            _running = true;
        }
    }

    /// Fire once after `intervalMsecs` (single-shot shorthand).
    void singleShot(long intervalMsecs, void delegate() callback)
    {
        start(TimerMode.SingleShot, intervalMsecs, callback);
    }

    /// Disarm the timer and release its callback registration. Stopping an
    /// already-fired single-shot timer is a harmless no-op.
    void stop() @system
    {
        version (SlintNative)
        {
            import slint.callback : callbacks;

            if (_cbId != 0)
            {
                callbacks.remove(_cbId);
                _cbId = 0;
            }
            if (_handle !is null)
                slint_timer_stop(_handle);
        }
        _running = false;
        _callback = null;
    }

    bool running() const @safe pure nothrow
    {
        return _running;
    }

    TimerMode mode() const @safe pure nothrow
    {
        return _mode;
    }

    long intervalMsecs() const @safe pure nothrow
    {
        return _intervalMsecs;
    }
}

///
unittest
{
    auto t = new Timer();
    assert(!t.running);
    t.start(TimerMode.Repeated, 1000, () {});
    assert(t.running && t.mode == TimerMode.Repeated && t.intervalMsecs == 1000);
    t.singleShot(50, () {});
    assert(t.running && t.mode == TimerMode.SingleShot && t.intervalMsecs == 50);
    t.stop();
    assert(!t.running);
}
