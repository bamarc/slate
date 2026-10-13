/// Background computation with thread-safe UI updates.
///
/// Port of `slate_core::task`: `TaskCancellation`, `spawnCompute`, and the
/// throttled/coalesced progress pipeline. The Rust version parks worker
/// threads and marshals UI callbacks through `slint::invoke_from_event_loop`;
/// the D port does the same on native builds and calls back directly on the
/// worker in pure builds (the same `immediate` strategy Rust's own tests
/// use). A panic in user code completes with null, exactly like Rust.
module slate.tasks;

import std.typecons : Nullable;

import core.sync.mutex : Mutex;
import core.thread : Thread;

/// Minimum progress delta (fraction) forwarded to the UI.
private enum progressStep = 0.005f;

/// Cooperative cancellation flag. Reference semantics: copies observe the
/// same flag, matching Rust's `Clone` handle.
final class TaskCancellation
{
    import core.atomic : atomicLoad, atomicStore;

    private shared bool _cancelled;

    /// Request the background task to stop.
    void cancel() @safe nothrow @nogc
    {
        atomicStore(_cancelled, true);
    }

    /// Whether cancellation was requested.
    bool isCancelled() const @safe nothrow @nogc
    {
        return atomicLoad(_cancelled);
    }
}

/// Coalesces worker progress into at most one queued UI update at a time.
private final class ProgressGate
{
    private Mutex _mtx;
    private float _latest = 0.0f;
    private bool _pending;
    private float _lastSent = -float.infinity;

    invariant
    {
        import std.math : isInfinity, isNaN, isFinite;

        assert(isFinite(_latest), "ProgressGate._latest must be finite");
        assert(_latest >= 0.0f && _latest <= 1.0f, "ProgressGate._latest must be within [0.0, 1.0]");
        assert(!isNaN(_lastSent), "ProgressGate._lastSent cannot be NaN");
        if (!isInfinity(_lastSent))
            assert(_lastSent >= 0.0f && _lastSent <= 1.0f, "ProgressGate._lastSent must be within [0.0, 1.0]");
    }

    this()
    {
        _mtx = new Mutex();
    }

    /// Worker side: true (plus no snapshot needed — the UI side re-reads
    /// latest) when a UI job should be queued for `pct`.
    bool offer(float pct)
    in
    {
        import std.math : isFinite;

        assert(isFinite(pct), "Progress percentage must be finite (neither NaN nor infinity)");
        assert(pct >= 0.0f && pct <= 1.0f, "Progress percentage must be within [0.0, 1.0]");
    }
    out (result)
    {
        assert(_latest >= 0.0f && _latest <= 1.0f, "Latest progress must be within [0.0, 1.0]");
    }
    do
    {
        import std.math : abs;

        synchronized (_mtx)
        {
            if (abs(pct - _lastSent) < progressStep)
                return false;
            _lastSent = pct;
            _latest = pct;
            if (_pending)
                return false;
            _pending = true;
            return true;
        }
    }

    /// UI side: newest progress value; clears the queued flag.
    float take()
    out (result)
    {
        assert(result >= 0.0f && result <= 1.0f, "Taken progress must be within [0.0, 1.0]");
    }
    do
    {
        synchronized (_mtx)
        {
            _pending = false;
            return _latest;
        }
    }
}

/// Synchronous core: runs `computeFn` on the calling thread, forwarding
/// throttled progress and the final result through `dispatch` (normally the
/// UI thread). Test seam mirroring Rust's injectable `dispatch`.
Nullable!T runCompute(T)(
    Nullable!T delegate(bool delegate() isCancelled, void delegate(float) progress) computeFn,
    void delegate(float) onProgress,
    void delegate(Nullable!T) onComplete,
    TaskCancellation cancellation,
    void delegate(void delegate() job) dispatch)
in
{
    assert(computeFn !is null, "computeFn delegate must not be null");
    assert(cancellation !is null, "cancellation handle must not be null");
    assert(dispatch !is null, "dispatch delegate must not be null");
}
do
{
    import std.logger : error;

    auto gate = new ProgressGate();
    bool isCancelled()
    {
        return cancellation.isCancelled();
    }

    void progress(float pct)
    {
        if (gate.offer(pct))
            dispatch(() {
                if (onProgress !is null)
                    onProgress(gate.take());
            });
    }

    Nullable!T result;
    scope (exit)
    {
        dispatch(() {
            if (onComplete !is null)
                onComplete(result);
        });
    }

    try
        result = computeFn(&isCancelled, &progress);
    catch (Throwable t)
    {
        try
            error("background compute task failed: ", t.msg);
        catch (Throwable)
        {
        }
        result = Nullable!T.init;
    }
    return result;
}

/// Spawn `computeFn` on a worker thread; progress/completion marshal to the
/// UI (event loop on native builds, direct call on pure builds).
TaskCancellation spawnCompute(T)(
    Nullable!T delegate(bool delegate() isCancelled, void delegate(float) progress) computeFn,
    void delegate(float) onProgress,
    void delegate(Nullable!T) onComplete)
in
{
    assert(computeFn !is null, "computeFn delegate must not be null");
}
do
{
    auto cancellation = new TaskCancellation();
    auto worker = new Thread({
        void delegate(void delegate() job) dispatch = (void delegate() job) { job(); };
        version (SlintNative)
        {
            import slint : invokeFromEventLoop;

            dispatch = (void delegate() job) {
                try
                    invokeFromEventLoop(job);
                catch (Throwable)
                    job();
            };
        }
        runCompute!T(computeFn, onProgress, onComplete, cancellation, dispatch);
    });
    worker.isDaemon = true;
    worker.start();
    return cancellation;
}

///
unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;

    // Cancellation flag.
    auto c = new TaskCancellation();
    assert(!c.isCancelled());
    c.cancel();
    assert(c.isCancelled());

    // Synchronous core with immediate dispatch (mirrors Rust's tests).
    void delegate(void delegate() job) immediate = (job) { job(); };

    float[] seen;
    Nullable!int done;
    auto r = runCompute!int((isCancelled, progress) {
        progress(0.5f);
        progress(0.5001f); // throttled away (delta < step)
        progress(1.0f);
        return Nullable!int(7);
    }, (float p) { seen ~= p; }, (Nullable!int v) { done = v; }, new TaskCancellation(),
        immediate);
    assert(!r.isNull && r.get == 7);
    assert(!done.isNull && done.get == 7);
    assert(seen == [0.5f, 1.0f]);

    // Panics complete with null.
    Nullable!int failed;
    runCompute!int((isCancelled, progress) {
        throw new Exception("boom");
        return Nullable!int.init;
    }, (float p) {}, (Nullable!int v) { failed = v; }, new TaskCancellation(), immediate);
    assert(failed.isNull);

    // Cancellation is visible to compute.
    auto cc = new TaskCancellation();
    cc.cancel();
    float[] noProgress;
    auto cr = runCompute!int((isCancelled, progress) {
        if (isCancelled())
            return Nullable!int.init;
        return Nullable!int(1);
    }, (float p) { noProgress ~= p; }, (Nullable!int v) {}, cc, immediate);
    assert(cr.isNull && noProgress.length == 0);

    // ProgressGate preconditions and invariants
    auto pg = new ProgressGate();
    assert(pg.offer(0.0f));
    assert(pg.take() == 0.0f);
    assert(pg.offer(1.0f));
    assert(pg.take() == 1.0f);

    // Out of bounds and NaN progress values must be rejected by precondition
    assertThrown!AssertError(pg.offer(-0.01f));
    assertThrown!AssertError(pg.offer(1.001f));
    assertThrown!AssertError(pg.offer(float.nan));
    assertThrown!AssertError(pg.offer(float.infinity));
    assertThrown!AssertError(pg.offer(-float.infinity));

    // scope(exit) completion dispatch guarantee verified when computeFn throws
    bool completionDispatched = false;
    runCompute!int((isCancelled, progress) {
        throw new Exception("unexpected task error");
        return Nullable!int.init;
    }, (float p) {}, (Nullable!int v) {
        completionDispatched = true;
        assert(v.isNull);
    }, new TaskCancellation(), immediate);
    assert(completionDispatched);

    // Contract verification: runCompute rejects null computeFn, cancellation, or dispatch
    assertThrown!AssertError(runCompute!int(null, (float p) {}, (Nullable!int v) {}, new TaskCancellation(), immediate));
    assertThrown!AssertError(runCompute!int((isCancelled, progress) => Nullable!int(1), (float p) {}, (Nullable!int v) {}, null, immediate));
    assertThrown!AssertError(runCompute!int((isCancelled, progress) => Nullable!int(1), (float p) {}, (Nullable!int v) {}, new TaskCancellation(), null));
    assertThrown!AssertError(spawnCompute!int(null, null, null));

    // runCompute gracefully executes when optional progress and complete callbacks are null
    auto cleanNullRes = runCompute!int((isCancelled, progress) {
        progress(0.5f);
        return Nullable!int(42);
    }, null, null, new TaskCancellation(), immediate);
    assert(!cleanNullRes.isNull && cleanNullRes.get == 42);
}
