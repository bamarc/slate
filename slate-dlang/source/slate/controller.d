/// Start/cancel coordination for a single background computation.
///
/// Port of `slate::controller::ComputeController`: at most one run in
/// flight; starting cancels the previous run, and a run-generation id
/// suppresses callbacks from superseded runs so stale results cannot
/// overwrite newer UI state. `start`/`cancel` are UI-thread calls.
module slate.controller;

import std.typecons : Nullable;

import core.atomic : atomicOp;
import core.sync.mutex : Mutex;

import slate.tasks : TaskCancellation, spawnCompute;

final class ComputeController
{
    private Mutex _slotMtx;
    private TaskCancellation _current;
    private shared ulong _generation;

    this()
    {
        _slotMtx = new Mutex();
    }

    /// Cancel any running task and start a new one. Progress/completion run
    /// on the UI thread and only for the current run. Returns the run id.
    ulong start(T)(
        Nullable!T delegate(bool delegate() isCancelled, void delegate(float) progress) computeFn,
        void delegate(float) onProgress,
        void delegate(Nullable!T) onComplete)
    {
        synchronized (_slotMtx)
        {
            if (_current !is null)
                _current.cancel();
        }
        ulong runId = atomicOp!"+="(_generation, 1UL);

        auto self = this;
        void guardedProgress(float pct)
        {
            import core.atomic : atomicLoad;

            if (atomicLoad(self._generation) == runId)
                onProgress(pct);
        }

        void guardedComplete(Nullable!T result)
        {
            import core.atomic : atomicLoad;

            if (atomicLoad(self._generation) != runId)
                return;
            synchronized (self._slotMtx)
                self._current = null;
            onComplete(result);
        }

        auto cancellation = spawnCompute!T(computeFn, &guardedProgress, &guardedComplete);
        synchronized (_slotMtx)
            _current = cancellation;
        return runId;
    }

    /// Request cancellation of the current run, if any. Its completion
    /// still fires (with null) so the UI can leave the running state.
    void cancel()
    {
        synchronized (_slotMtx)
        {
            if (_current !is null)
                _current.cancel();
        }
    }

    /// Whether a run is in flight.
    bool isRunning()
    {
        synchronized (_slotMtx)
            return _current !is null;
    }
}

///
unittest
{
    auto c = new ComputeController();
    assert(!c.isRunning());
    c.cancel(); // no-op when idle

    // Starting supersedes: the first run observes cancellation.
    import core.atomic : atomicLoad, atomicStore;

    shared bool firstSawCancel;
    ulong id1 = c.start!bool((isCancelled, progress) {
        import core.thread : Thread;
        import core.time : msecs;

        while (!isCancelled())
            Thread.sleep(1.msecs);
        atomicStore(firstSawCancel, true);
        return Nullable!bool.init;
    }, (float p) {}, (Nullable!bool v) {});
    ulong id2 = c.start!bool((isCancelled, progress) {
        return Nullable!bool(true);
    }, (float p) {}, (Nullable!bool v) {});
    assert(id2 > id1);
    assert(c.isRunning());

    import core.thread : Thread;
    import core.time : msecs;

    foreach (_; 0 .. 2000)
    {
        if (atomicLoad(firstSawCancel))
            break;
        Thread.sleep(1.msecs);
    }
    assert(atomicLoad(firstSawCancel), "previous run was not cancelled");
}
