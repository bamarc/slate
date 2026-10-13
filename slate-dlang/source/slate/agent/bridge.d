/// UI-thread dispatch bridge for agent automation.
///
/// Port of `slate_agent::bridge` (`SlintUiBridge`, `ComponentBridge`,
/// `DEFAULT_UI_TIMEOUT`): run work on the Slint UI thread, wait with a
/// timeout, and map thread failures to `AgentError`. Adaptation:
/// - Rust serializes commands with an async mutex + oneshot channels over
///   tokio. D uses `core.sync` (`Mutex` + `Condition`) with blocking wait —
///   the canonical mapping, since agent calls are synchronous here.
/// - Native builds post through `slint.invokeFromEventLoop`; pure builds
///   execute inline (same test strategy as `slate.tasks`).
/// - Rust's generic `ComponentBridge<T: ComponentHandle>` (weak upgrade)
///   becomes a nullable `slint-d` instance: null means destroyed, and
///   `invalidate()` models the weak-expiry path explicitly.
module slate.agent.bridge;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.time : Duration, msecs, seconds;

import slate.agent.error : AgentError;
import slint.instance : ComponentInstance;

/// Default UI round-trip budget (mirrors `DEFAULT_UI_TIMEOUT` = 5 s).
enum Duration defaultUiTimeout = 5.seconds;

/// Runs closures on the Slint UI thread with timeout and panic capture.
final class SlintUiBridge
{
    private Duration _timeout;
    private Mutex _mtx;
    private Condition _cond;

    this(Duration timeout = defaultUiTimeout)
    {
        _timeout = timeout;
        _mtx = new Mutex();
        _cond = new Condition(_mtx);
    }

    Duration timeout() const @safe pure nothrow
    {
        return _timeout;
    }

    /// Run `work` on the UI thread and return its result. Throws
    /// `AgentError.timeout` when the budget lapses and `AgentError.uiPanic`
    /// when the work itself throws.
    T runOnUi(T)(T delegate() work)
    in
    {
        assert(work !is null, "work delegate must not be null");
    }
    do
    {
        version (SlintNative)
        {
            import slint : invokeFromEventLoop;

            auto slot = new UiSlot!T();
            try
                invokeFromEventLoop(() {
                    try
                    {
                        static if (is(T == void))
                        {
                            work();
                            slot.complete();
                        }
                        else
                        {
                            slot.complete(work());
                        }
                    }
                    catch (Throwable t)
                        slot.fail(t.msg);
                });
            catch (Throwable t)
            {
                // Posting itself failed (no loop, shut down, ...).
                throw AgentError.eventLoopUnavailable(t.msg);
            }
            static if (is(T == void))
                slot.wait(_timeout);
            else
                return slot.wait(_timeout);
        }
        else
        {
            try
            {
                static if (is(T == void))
                    work();
                else
                    return work();
            }
            catch (AgentError e)
            {
                throw e;
            }
            catch (Throwable t)
            {
                throw AgentError.uiPanic(t.msg);
            }
        }
    }

    /// Run `action` transactionally on the UI thread. If `action` fails (throws Throwable),
    /// the `scope(failure)` guard executes `rollback` to restore the pre-action UI state.
    T runTransactional(T)(T delegate() action, void delegate() rollback)
    in
    {
        assert(action !is null, "action delegate must not be null");
    }
    do
    {
        scope (failure)
        {
            if (rollback !is null)
                rollback();
        }
        static if (is(T == void))
            runOnUi!void(action);
        else
            return runOnUi!T(action);
    }

    /// Run `action` transactionally with an explicit state snapshot.
    /// If `action` fails, `rollback` is invoked with `stateSnapshot`.
    T runTransactional(T, S)(S stateSnapshot, T delegate() action, void delegate(S) rollback)
    in
    {
        assert(action !is null, "action delegate must not be null");
    }
    do
    {
        scope (failure)
        {
            if (rollback !is null)
                rollback(stateSnapshot);
        }
        static if (is(T == void))
            runOnUi!void(action);
        else
            return runOnUi!T(action);
    }
}

/// Handoff cell between the posting thread and the UI thread.
private final class UiSlot(T)
{
    private Mutex _mtx;
    private Condition _cond;
    private bool _done;
    static if (!is(T == void))
        private T _value;
    private string _error;
    private bool _failed;

    invariant
    {
        if (_done && _failed)
            assert(_error.length > 0, "Failed UiSlot must carry an error message");
        if (_failed)
            assert(_done, "Failed UiSlot must be marked done");
    }

    this()
    {
        _mtx = new Mutex();
        _cond = new Condition(_mtx);
    }

    static if (is(T == void))
    {
        void complete()
        {
            synchronized (_mtx)
            {
                if (_done)
                    return;
                scope (exit)
                    _cond.notifyAll();
                _done = true;
            }
        }
    }
    else
    {
        void complete(T value)
        {
            synchronized (_mtx)
            {
                if (_done)
                    return;
                scope (exit)
                    _cond.notifyAll();
                scope (failure)
                {
                    _failed = true;
                    _error = "value assignment failed";
                    _done = true;
                }
                _value = value;
                _done = true;
            }
        }
    }

    void fail(string message)
    in
    {
        assert(message.length > 0, "Failure message must not be empty");
    }
    do
    {
        synchronized (_mtx)
        {
            if (_done)
                return;
            scope (exit)
                _cond.notifyAll();
            _error = message;
            _failed = true;
            _done = true;
        }
    }

    static if (is(T == void))
    {
        void wait(Duration budget)
        in
        {
            assert(budget > Duration.zero, "Wait budget must be greater than zero");
        }
        out
        {
            assert(_done, "UiSlot must be completed after successful wait");
        }
        do
        {
            import core.time : MonoTime;

            auto deadline = MonoTime.currTime + budget;
            synchronized (_mtx)
            {
                while (!_done)
                {
                    auto now = MonoTime.currTime;
                    if (now >= deadline)
                    {
                        if (_done)
                            break;
                        throw AgentError.timeout("ui-dispatch",
                            cast(ulong) budget.total!"msecs");
                    }
                    auto signaled = _cond.wait(deadline - now);
                    if (!_done && (!signaled || MonoTime.currTime >= deadline))
                        throw AgentError.timeout("ui-dispatch",
                            cast(ulong) budget.total!"msecs");
                }
                if (_failed)
                    throw AgentError.uiPanic(_error);
            }
        }
    }
    else
    {
        T wait(Duration budget)
        in
        {
            assert(budget > Duration.zero, "Wait budget must be greater than zero");
        }
        out
        {
            assert(_done, "UiSlot must be completed after successful wait");
        }
        do
        {
            import core.time : MonoTime;

            auto deadline = MonoTime.currTime + budget;
            synchronized (_mtx)
            {
                while (!_done)
                {
                    auto now = MonoTime.currTime;
                    if (now >= deadline)
                    {
                        if (_done)
                            break;
                        throw AgentError.timeout("ui-dispatch",
                            cast(ulong) budget.total!"msecs");
                    }
                    auto signaled = _cond.wait(deadline - now);
                    if (!_done && (!signaled || MonoTime.currTime >= deadline))
                        throw AgentError.timeout("ui-dispatch",
                            cast(ulong) budget.total!"msecs");
                }
                if (_failed)
                    throw AgentError.uiPanic(_error);
                return _value;
            }
        }
    }
}

/// Window-bound bridge: a nullable `slint-d` instance plus dispatch.
/// `invalidate()` models Rust's expired `Weak` upgrade.
final class ComponentBridge
{
    private SlintUiBridge _bridge;
    private ComponentInstance _window;

    this(SlintUiBridge bridge, ComponentInstance window)
    in
    {
        assert(bridge !is null, "SlintUiBridge must not be null");
    }
    do
    {
        _bridge = bridge;
        _window = window;
    }

    SlintUiBridge bridge()
    {
        return _bridge;
    }

    /// Mark the window destroyed; further use throws `windowClosed`.
    void invalidate()
    {
        _window = null;
    }

    /// Run `work` with the live window on the UI thread.
    T runWithWindow(T)(T delegate(ComponentInstance window) work)
    in
    {
        assert(work !is null, "work delegate must not be null");
    }
    do
    {
        auto w = _window;
        if (w is null)
            throw AgentError.windowClosed();
        return _bridge.runOnUi!T(() => work(w));
    }

    /// Run `action` transactionally with the live window on the UI thread.
    T runTransactional(T)(T delegate(ComponentInstance window) action, void delegate() rollback)
    in
    {
        assert(action !is null, "action delegate must not be null");
    }
    do
    {
        auto w = _window;
        if (w is null)
            throw AgentError.windowClosed();
        scope (failure)
        {
            if (rollback !is null)
                rollback();
        }
        static if (is(T == void))
            _bridge.runTransactional!void(() => action(w), null);
        else
            return _bridge.runTransactional!T(() => action(w), null);
    }

    /// Run `action` transactionally with an explicit state snapshot and the live window.
    T runTransactional(T, S)(S stateSnapshot, T delegate(ComponentInstance window) action, void delegate(S) rollback)
    in
    {
        assert(action !is null, "action delegate must not be null");
    }
    do
    {
        auto w = _window;
        if (w is null)
            throw AgentError.windowClosed();
        scope (failure)
        {
            if (rollback !is null)
                rollback(stateSnapshot);
        }
        static if (is(T == void))
            _bridge.runTransactional!(void, S)(stateSnapshot, () => action(w), null);
        else
            return _bridge.runTransactional!(T, S)(stateSnapshot, () => action(w), null);
    }
}

///
unittest
{
    import core.time : msecs;

    // Pure builds execute inline with identical error mapping.
    auto bridge = new SlintUiBridge(100.msecs);
    assert(bridge.timeout == 100.msecs);

    version (SlintNative)
    {
        // Under native config without an active event loop, runOnUi throws eventLoopUnavailable
        try
        {
            bridge.runOnUi!int(() => 42);
            assert(false);
        }
        catch (AgentError e)
        {
            assert(e.kind == AgentError.Kind.eventLoopUnavailable);
        }
    }
    else
    {
        assert(bridge.runOnUi!int(() => 41 + 1) == 42);

        try
        {
            bridge.runOnUi!int(() => throw new Exception("ui-boom"));
            assert(false);
        }
        catch (AgentError e)
        {
            assert(e.kind == AgentError.Kind.uiPanic);
        }

        // AgentError passes through untouched.
        try
        {
            bridge.runOnUi!int(() => throw AgentError.windowClosed());
            assert(false);
        }
        catch (AgentError e)
        {
            assert(e.kind == AgentError.Kind.windowClosed);
        }
    }

    // Null window models the expired weak handle.
    auto cb = new ComponentBridge(bridge, null);
    try
    {
        cb.runWithWindow!int((w) => 1);
        assert(false);
    }
    catch (AgentError e)
    {
        assert(e.kind == AgentError.Kind.windowClosed);
    }
    cb.invalidate(); // idempotent

    // Transactional execution with scope(failure) rollback on action failure
    struct MockUiState
    {
        string currentView = "dashboard";
        int activeTab = 0;
        bool modalOpen = false;
    }

    MockUiState liveState;
    liveState.currentView = "dashboard";
    liveState.activeTab = 0;
    liveState.modalOpen = false;

    version (SlintNative)
    {
        // Under native config without an event loop, runTransactional propagates eventLoopUnavailable
        try
        {
            bridge.runTransactional!void(() {}, () {});
            assert(false);
        }
        catch (AgentError e)
        {
            assert(e.kind == AgentError.Kind.eventLoopUnavailable);
        }
    }
    else
    {
        // Successful transaction commits changes without rollback
        bridge.runTransactional!void(
            () {
                liveState.currentView = "settings";
                liveState.activeTab = 2;
            },
            () {
                liveState.currentView = "dashboard";
                liveState.activeTab = 0;
            }
        );
        assert(liveState.currentView == "settings");
        assert(liveState.activeTab == 2);

        // Failed transaction restores pre-failure UI state via scope(failure)
        auto preFailureSnapshot = liveState;
        try
        {
            bridge.runTransactional!(int, MockUiState)(
                preFailureSnapshot,
                () {
                    // Mutate state during action
                    liveState.currentView = "corrupted_view";
                    liveState.activeTab = 99;
                    liveState.modalOpen = true;
                    // Action throws mid-way
                    throw new Exception("UI mutation crashed");
                    return 42;
                },
                (MockUiState snapshot) {
                    // Pre-failure UI state is restored by scope(failure)
                    liveState = snapshot;
                }
            );
            assert(false, "Should have thrown AgentError");
        }
        catch (AgentError e)
        {
            assert(e.kind == AgentError.Kind.uiPanic);
        }
        // Verify pre-failure UI state was completely restored by scope(failure)
        assert(liveState.currentView == "settings");
        assert(liveState.activeTab == 2);
        assert(!liveState.modalOpen);
    }

    // Direct unit testing of UiSlot cross-thread synchronization and RAII scope guards
    import core.thread : Thread;

    // 1. UiSlot!int complete and wait
    auto intSlot = new UiSlot!int();
    intSlot.complete(42);
    assert(intSlot.wait(100.msecs) == 42);

    // 2. UiSlot!int fail and wait propagates uiPanic
    auto failSlot = new UiSlot!int();
    failSlot.fail("background worker crashed");
    try
    {
        failSlot.wait(100.msecs);
        assert(false, "Should have thrown uiPanic");
    }
    catch (AgentError e)
    {
        assert(e.kind == AgentError.Kind.uiPanic);
    }

    // 3. UiSlot!int timeout when uncompleted
    auto timeoutSlot = new UiSlot!int();
    try
    {
        timeoutSlot.wait(10.msecs);
        assert(false, "Should have timed out");
    }
    catch (AgentError e)
    {
        assert(e.kind == AgentError.Kind.timeout);
    }

    // 4. UiSlot!void complete and wait
    auto voidSlot = new UiSlot!void();
    voidSlot.complete();
    voidSlot.wait(100.msecs); // returns cleanly

    // 5. UiSlot!void fail and wait propagates uiPanic
    auto voidFailSlot = new UiSlot!void();
    voidFailSlot.fail("void worker panic");
    try
    {
        voidFailSlot.wait(100.msecs);
        assert(false, "Should have thrown uiPanic");
    }
    catch (AgentError e)
    {
        assert(e.kind == AgentError.Kind.uiPanic);
    }

    // 6. Cross-thread condition variable signaling via scope(exit) _cond.notifyAll()
    auto threadSlot = new UiSlot!int();
    auto workerThread = new Thread({
        Thread.sleep(15.msecs);
        threadSlot.complete(999);
    });
    workerThread.start();
    assert(threadSlot.wait(500.msecs) == 999);
    workerThread.join();

    auto threadFailSlot = new UiSlot!void();
    auto failWorkerThread = new Thread({
        Thread.sleep(15.msecs);
        threadFailSlot.fail("asynchronous worker error");
    });
    failWorkerThread.start();
    try
    {
        threadFailSlot.wait(500.msecs);
        assert(false, "Should have caught async error");
    }
    catch (AgentError e)
    {
        assert(e.kind == AgentError.Kind.uiPanic);
    }
    failWorkerThread.join();

    // 7. Contract verification: null delegate rejection
    import core.exception : AssertError;
    import std.exception : assertThrown;

    assertThrown!AssertError(bridge.runOnUi!int(null));
    assertThrown!AssertError(bridge.runTransactional!void(null, () {}));
    assertThrown!AssertError(cb.runWithWindow!int(null));
    assertThrown!AssertError(cb.runTransactional!void(null, () {}));
}
