/// Cooperative UI tasks and lazy models on D fibers.
///
/// Python bridges Slint's loop with `asyncio` (`slint/loop.py`); Node rides
/// libuv. D's native answer is `core.thread.fiber.Fiber`: stackful,
/// allocation-cheap coroutines with no event-loop dependency, so task
/// logic stays testable with a plain step driver and runs unchanged on the
/// real loop (pumped by timers or `invokeFromEventLoop`).
///
/// ```d
/// auto task = spawnTask({
///     foreach (i; 0 .. 3) {
///         updateModel(i);     // UI work, same thread
///         UiTask.yield();     // cooperatively wait for the next pump
///     }
/// });
/// while (!task.done) task.step();  // test driver; the loop pumps live
/// ```
module slint.fiber;

import core.thread.fiber : Fiber;

/// A cooperative task. `step()` resumes until the next `yield()` or until
/// the body returns; a throwing body is captured in `error` rather than
/// escaping across the C boundary of a timer/callback trampoline.
final class UiTask
{
    private Fiber _fiber;
    private bool _done;
    private Throwable _error;

    this(void delegate() fn)
    {
        _fiber = new Fiber(fn);
    }

    @property bool done() const @safe pure nothrow
    {
        return _done;
    }

    @property Throwable error() @safe pure nothrow
    {
        return _error;
    }

    void step()
    {
        if (_done)
            return;
        try
        {
            _fiber.call();
        }
        catch (Throwable t)
        {
            _done = true;
            _error = t;
            return;
        }
        if (_fiber.state == Fiber.State.TERM)
            _done = true;
    }

    /// Yield control back to the pumper from inside task code.
    static void yield()
    {
        Fiber.yield();
    }
}

/// Spawn a cooperative task (see module docs).
UiTask spawnTask(void delegate() fn)
{
    return new UiTask(fn);
}

///
unittest
{
    // Interleaved tasks resume in order, preserving locals across yields.
    int[] log;
    auto a = spawnTask({
        log ~= 1;
        UiTask.yield();
        log ~= 3;
    });
    auto b = spawnTask({
        log ~= 2;
        UiTask.yield();
        log ~= 4;
    });
    assert(!a.done && !b.done);
    a.step();
    b.step();
    a.step();
    b.step();
    assert(log == [1, 2, 3, 4]);
    assert(a.done && b.done);
    a.step(); // stepping a finished task is a no-op
    assert(a.done);

    // Throwing bodies are captured, not propagated.
    auto boom = spawnTask({ throw new Exception("task-fail"); });
    boom.step();
    assert(boom.done && boom.error.msg == "task-fail");

    // Tasks compose with models: build rows cooperatively.
    import slint.model : ArrayModel;

    auto model = new ArrayModel!int();
    auto fill = spawnTask({
        foreach (i; 0 .. 5)
        {
            model.push(i);
            UiTask.yield();
        }
    });
    fill.step();
    assert(model.length == 1);
    while (!fill.done)
        fill.step();
    assert(model.length == 5);
}
