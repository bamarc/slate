/// Cooperative coroutine fibers for multi-step agent UI automation.
///
/// Implements `AutomationFiber` using D's native `core.thread.fiber.Fiber` to
/// execute sequential UI automation actions (e.g. click, wait, assert, type)
/// that yield (`Fiber.yield()`) and resume across event loop ticks without
/// allocating OS kernel threads or adopting viral async/await function coloring.
module slate.agent.fiber;

import core.thread.fiber : Fiber;

/// Conservative default fiber stack size (64 KB), allowing thousands of concurrent
/// automation coroutines to reside within the process memory limit.
enum size_t defaultFiberStackSize = 64 * 1024;

/// Minimum allowable fiber stack size (16 KB).
enum size_t minFiberStackSize = 16 * 1024;

/// Maximum allowable fiber stack size (16 MB), guarding the process memory limit.
enum size_t maxFiberStackSize = 16 * 1024 * 1024;

/// Cooperative stackful coroutine for multi-step agent automation.
class AutomationFiber
{
    private Fiber _fiber;
    private void delegate()[] _steps;
    private size_t _currentStep;
    private size_t _completedSteps;
    private void delegate() _singleAction;

    private size_t calcTotalSteps() const @safe pure nothrow @nogc
    {
        return _steps.length > 0 ? _steps.length : 1;
    }

    invariant
    {
        assert(_completedSteps <= calcTotalSteps(), "Completed steps count exceeds total steps");
        assert(_currentStep <= calcTotalSteps(), "Current step index exceeds total steps");
    }

    /// Construct a fiber with a single continuous action delegate that explicitly yields
    /// via `AutomationFiber.yield()` or `Fiber.yield()`.
    this(void delegate() action, size_t stackSize = defaultFiberStackSize)
    in
    {
        assert(action !is null, "Action delegate must not be null");
        assert(stackSize >= minFiberStackSize, "Stack size must be at least 16 KB");
        assert(stackSize <= maxFiberStackSize, "Stack size must not exceed 16 MB");
    }
    do
    {
        _singleAction = action;
        _fiber = new Fiber(&runSingle, stackSize);
    }

    /// Construct a fiber from a discrete sequence of automation steps.
    /// Each step automatically executes and yields execution to the caller until the last step.
    this(void delegate()[] steps, size_t stackSize = defaultFiberStackSize)
    in
    {
        assert(steps.length > 0, "Steps array must not be empty");
        assert(stackSize >= minFiberStackSize, "Stack size must be at least 16 KB");
        assert(stackSize <= maxFiberStackSize, "Stack size must not exceed 16 MB");
        foreach (s; steps)
            assert(s !is null, "Step delegate must not be null");
    }
    do
    {
        _steps = steps.dup;
        _fiber = new Fiber(&runSteps, stackSize);
    }

    private void runSingle()
    {
        _singleAction();
        _completedSteps = 1;
    }

    private void runSteps()
    {
        for (size_t i = 0; i < _steps.length; i++)
        {
            _currentStep = i;
            _steps[i]();
            _completedSteps++;
            // Yield execution after each step if further steps remain
            if (i + 1 < _steps.length)
                Fiber.yield();
        }
    }

    /// Resume or start execution of this fiber until the next yield or completion.
    void call()
    in
    {
        assert(!isCompleted(), "Cannot call terminated AutomationFiber");
    }
    do
    {
        _fiber.call();
    }

    /// Current execution state of the underlying fiber.
    Fiber.State state() const @safe nothrow
    {
        return _fiber.state;
    }

    /// Direct access to the underlying `core.thread.fiber.Fiber` instance.
    Fiber fiber() @safe pure nothrow @nogc
    {
        return _fiber;
    }

    /// Current step index being executed or most recently completed (0-based).
    size_t currentStep() const @safe pure nothrow @nogc
    {
        return _currentStep;
    }

    /// Total number of configured sequential steps.
    size_t totalSteps() const @safe pure nothrow @nogc
    out (tot)
    {
        assert(tot > 0, "Total steps must be at least 1");
    }
    do
    {
        return _steps.length > 0 ? _steps.length : 1;
    }

    /// Number of completed steps.
    size_t completedSteps() const @safe pure nothrow @nogc
    {
        return _completedSteps;
    }

    /// Whether all actions and steps have finished execution.
    bool isCompleted() const @safe nothrow
    {
        return _fiber.state == Fiber.State.TERM;
    }

    /// Whether the fiber is currently suspended (yielded) and can be resumed.
    bool isSuspended() const @safe nothrow
    {
        return _fiber.state == Fiber.State.HOLD;
    }

    /// Whether the fiber is currently executing on the calling thread.
    bool isExecuting() const @safe nothrow
    {
        return _fiber.state == Fiber.State.EXEC;
    }

    /// Cooperative yield helper delegating to `core.thread.fiber.Fiber.yield()`.
    static void yield()
    in
    {
        assert(Fiber.getThis() !is null,
                "AutomationFiber.yield() must be called from within an active fiber");
    }
    do
    {
        Fiber.yield();
    }

    /// Reset this fiber to its initial state, allowing the coroutine to be re-run
    /// without reallocating stack memory.
    void reset()
    in
    {
        assert(state() != Fiber.State.EXEC, "Cannot reset currently executing fiber");
    }
    out
    {
        assert(completedSteps() == 0, "Completed steps count must be 0 after reset");
        assert(currentStep() == 0, "Current step index must be 0 after reset");
        assert(!isCompleted(), "Fiber must not be completed after reset");
    }
    do
    {
        _completedSteps = 0;
        _currentStep = 0;
        if (_steps.length > 0)
            _fiber.reset(&runSteps);
        else
            _fiber.reset(&runSingle);
    }

    /// Cooperatively executes all remaining steps to completion.
    /// Returns the total number of calls performed.
    size_t runToCompletion(size_t maxIterations = size_t.max)
    in
    {
        assert(maxIterations > 0, "maxIterations must be greater than zero");
    }
    out
    {
        assert(isCompleted(), "Fiber must be completed after runToCompletion");
    }
    do
    {
        size_t iterations = 0;
        while (!isCompleted())
        {
            if (iterations >= maxIterations)
                throw new Exception("runToCompletion exceeded maxIterations limit");
            call();
            iterations++;
        }
        return iterations;
    }
}

/// Cooperative scheduler that pumps multiple active `AutomationFiber` instances.
class AutomationFiberRunner
{
    private AutomationFiber[] _fibers;

    invariant
    {
        foreach (f; _fibers)
            assert(f !is null, "Scheduled fiber cannot be null");
    }

    /// Add an automation fiber to the scheduler.
    void add(AutomationFiber fiber)
    in
    {
        assert(fiber !is null, "Fiber cannot be null");
        assert(!fiber.isCompleted(), "Cannot schedule an already completed fiber");
    }
    out
    {
        assert(activeCount() > 0, "Active fiber count must be greater than zero after adding");
    }
    do
    {
        _fibers ~= fiber;
    }

    /// Remove a fiber from the scheduler. Returns true if removed, false if not found.
    bool remove(AutomationFiber fiber)
    in
    {
        assert(fiber !is null, "Fiber to remove cannot be null");
    }
    out (removed)
    {
        foreach (f; _fibers)
            assert(f !is fiber, "Removed fiber must not remain in runner");
    }
    do
    {
        bool found = false;
        AutomationFiber[] remaining;
        foreach (f; _fibers)
        {
            if (f is fiber)
                found = true;
            else
                remaining ~= f;
        }
        _fibers = remaining;
        return found;
    }

    /// Clear all scheduled fibers.
    void clear()
    out
    {
        assert(activeCount() == 0, "Runner must be empty after clear");
    }
    do
    {
        _fibers = null;
    }

    /// Pump one step across each active (non-completed) fiber.
    /// Preserves remaining unexecuted fibers in the scheduler if an intermediate fiber throws.
    /// Returns the count of remaining active fibers.
    size_t step()
    out (remainingCount)
    {
        assert(remainingCount == activeCount(), "Return value must equal active fiber count");
    }
    do
    {
        AutomationFiber[] active;
        size_t currentIdx = 0;
        scope (failure)
        {
            // On failure, preserve both fibers stepped prior to failure that remain active
            // AND all subsequent fibers that have not yet had a chance to step
            AutomationFiber[] remaining;
            foreach (f; active)
                if (!f.isCompleted())
                    remaining ~= f;
            if (currentIdx + 1 < _fibers.length)
            {
                foreach (f; _fibers[currentIdx + 1 .. $])
                    if (!f.isCompleted())
                        remaining ~= f;
            }
            _fibers = remaining;
        }

        for (currentIdx = 0; currentIdx < _fibers.length; currentIdx++)
        {
            auto f = _fibers[currentIdx];
            if (!f.isCompleted())
            {
                f.call();
                if (!f.isCompleted())
                    active ~= f;
            }
        }
        _fibers = active;
        return _fibers.length;
    }

    /// Run all scheduled fibers until all reach termination.
    /// Returns the total number of scheduler steps performed.
    size_t runAll(size_t maxSteps = size_t.max)
    in
    {
        assert(maxSteps > 0, "maxSteps must be greater than zero");
    }
    out
    {
        assert(activeCount() == 0, "All fibers must be completed after runAll");
    }
    do
    {
        size_t totalSteps = 0;
        while (activeCount() > 0)
        {
            if (totalSteps >= maxSteps)
                throw new Exception("runAll exceeded maxSteps limit");
            step();
            totalSteps++;
        }
        return totalSteps;
    }

    /// Count of currently active fibers.
    size_t activeCount() const @safe pure nothrow
    {
        return _fibers.length;
    }
}

///
unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;

    // 1. Multi-step AutomationFiber: yields and resumes across frames (Scenario T4)
    string[] log;
    auto stepsFiber = new AutomationFiber([
        cast(void delegate())() { log ~= "step1:focus"; }, cast(void delegate())() {
            log ~= "step2:type";
        }, cast(void delegate())() { log ~= "step3:assert"; },
    ]);

    assert(stepsFiber.totalSteps == 3);
    assert(stepsFiber.completedSteps == 0);
    assert(stepsFiber.isSuspended);
    assert(!stepsFiber.isCompleted);

    // Frame 1
    stepsFiber.call();
    assert(log == ["step1:focus"]);
    assert(stepsFiber.currentStep == 0);
    assert(stepsFiber.completedSteps == 1);
    assert(stepsFiber.isSuspended);
    assert(!stepsFiber.isCompleted);

    // Frame 2
    stepsFiber.call();
    assert(log == ["step1:focus", "step2:type"]);
    assert(stepsFiber.currentStep == 1);
    assert(stepsFiber.completedSteps == 2);
    assert(stepsFiber.isSuspended);
    assert(!stepsFiber.isCompleted);

    // Frame 3 (final step)
    stepsFiber.call();
    assert(log == ["step1:focus", "step2:type", "step3:assert"]);
    assert(stepsFiber.currentStep == 2);
    assert(stepsFiber.completedSteps == 3);
    assert(stepsFiber.isCompleted);
    assert(!stepsFiber.isSuspended);

    // 2. Continuous action with explicit AutomationFiber.yield() and stackful state preservation
    int counter = 0;
    auto continuousFiber = new AutomationFiber({
        int localStackVar = 100;
        counter = localStackVar;
        AutomationFiber.yield();

        localStackVar += 50;
        counter = localStackVar;
        AutomationFiber.yield();

        localStackVar *= 2;
        counter = localStackVar;
    });

    assert(counter == 0);
    continuousFiber.call();
    assert(counter == 100);
    assert(!continuousFiber.isCompleted);

    continuousFiber.call();
    assert(counter == 150);
    assert(!continuousFiber.isCompleted);

    continuousFiber.call();
    assert(counter == 300);
    assert(continuousFiber.isCompleted);

    // 3. runToCompletion helper
    int completionCounter = 0;
    auto completionFiber = new AutomationFiber([
        cast(void delegate())() { completionCounter += 1; },
        cast(void delegate())() { completionCounter += 2; },
        cast(void delegate())() { completionCounter += 3; },
    ]);
    auto iterations = completionFiber.runToCompletion();
    assert(iterations == 3);
    assert(completionCounter == 6);
    assert(completionFiber.isCompleted);

    // 4. Contract verification: preconditions reject invalid parameters
    assertThrown!AssertError(new AutomationFiber(cast(void delegate()) null));
    assertThrown!AssertError(new AutomationFiber((void delegate()[]).init));
    assertThrown!AssertError(new AutomationFiber(() {}, 1024)); // stack size < 16 KB

    // 5. Transactional rollback with scope(failure) inside a fiber
    bool rolledBack = false;
    auto failingFiber = new AutomationFiber({
        scope (failure)
        {
            rolledBack = true;
        }
        AutomationFiber.yield();
        throw new Exception("Fiber step failed");
    });

    failingFiber.call();
    assert(!rolledBack);
    assert(failingFiber.isSuspended);

    try
    {
        failingFiber.call();
        assert(false, "Fiber call should have thrown");
    }
    catch (Exception e)
    {
        assert(e.msg == "Fiber step failed");
    }
    assert(rolledBack);
    assert(failingFiber.isCompleted);

    // 6. AutomationFiberRunner: interleaving multiple concurrent fibers
    string[] interleavedLog;
    auto fiberA = new AutomationFiber([
        cast(void delegate())() { interleavedLog ~= "A1"; },
        cast(void delegate())() { interleavedLog ~= "A2"; },
    ]);
    auto fiberB = new AutomationFiber([
        cast(void delegate())() { interleavedLog ~= "B1"; },
        cast(void delegate())() { interleavedLog ~= "B2"; },
        cast(void delegate())() { interleavedLog ~= "B3"; },
    ]);

    auto runner = new AutomationFiberRunner();
    runner.add(fiberA);
    runner.add(fiberB);
    assert(runner.activeCount == 2);

    runner.step(); // A1, B1
    assert(interleavedLog == ["A1", "B1"]);
    assert(runner.activeCount == 2);

    runner.step(); // A2 (completes), B2
    assert(interleavedLog == ["A1", "B1", "A2", "B2"]);
    assert(runner.activeCount == 1);

    runner.step(); // B3 (completes)
    assert(interleavedLog == ["A1", "B1", "A2", "B2", "B3"]);
    assert(runner.activeCount == 0);

    // 7. Contract verification: yield outside fiber, call terminated, null step delegate
    assertThrown!AssertError(AutomationFiber.yield()); // outside active fiber
    assertThrown!AssertError(stepsFiber.call()); // calling terminated fiber
    assertThrown!AssertError(new AutomationFiber([cast(void delegate()) null]));
    assertThrown!AssertError(runner.add(stepsFiber)); // cannot add terminated fiber

    // Single-action fiber steps accounting and invariants
    auto saFiber = new AutomationFiber({ int a = 1; });
    assert(saFiber.totalSteps == 1);
    assert(saFiber.completedSteps == 0);
    saFiber.call();
    assert(saFiber.totalSteps == 1);
    assert(saFiber.completedSteps == 1);
    assert(saFiber.isCompleted);

    // 8. Long-running fiber: 2,000 cooperative yields verifying stack integrity (OI-4)
    int iterationsSeen = 0;
    auto longFiber = new AutomationFiber({
        foreach (i; 0 .. 2000)
        {
            iterationsSeen++;
            AutomationFiber.yield();
        }
    });
    while (!longFiber.isCompleted())
        longFiber.call();
    assert(iterationsSeen == 2000);

    // 9. Multi-fiber scale: 50 concurrent fibers pumped via runner.runAll()
    auto scaleRunner = new AutomationFiberRunner();
    int[] scaleCounts = new int[50];
    auto makeSteps(size_t idx)
    {
        return [
            cast(void delegate())() { scaleCounts[idx] += 1; },
            cast(void delegate())() { scaleCounts[idx] += 2; },
            cast(void delegate())() { scaleCounts[idx] += 3; },
        ];
    }

    foreach (i; 0 .. 50)
    {
        scaleRunner.add(new AutomationFiber(makeSteps(i)));
    }
    assert(scaleRunner.activeCount == 50);
    auto scaleStepsTaken = scaleRunner.runAll();
    assert(scaleStepsTaken == 3);
    assert(scaleRunner.activeCount == 0);
    foreach (i; 0 .. 50)
        assert(scaleCounts[i] == 6);

    // 10. AutomationFiber.reset() reinitializes coroutine state for reuse without reallocation
    int reusableCount = 0;
    auto reusableFiber = new AutomationFiber([
        cast(void delegate())() { reusableCount += 10; }, cast(void delegate())() {
            reusableCount += 20;
        },
    ]);
    assert(reusableFiber.runToCompletion() == 2);
    assert(reusableCount == 30);
    assert(reusableFiber.isCompleted);

    reusableFiber.reset();
    assert(!reusableFiber.isCompleted);
    assert(reusableFiber.completedSteps == 0);
    assert(reusableFiber.currentStep == 0);
    assert(reusableFiber.runToCompletion() == 2);
    assert(reusableCount == 60);
    assert(reusableFiber.isCompleted);

    // Single-action AutomationFiber.reset() reinitializes cleanly without reallocation
    int singleResetCount = 0;
    auto singleResetFiber = new AutomationFiber({
        singleResetCount += 5;
        AutomationFiber.yield();
        singleResetCount += 5;
    });
    assert(singleResetFiber.runToCompletion() == 2);
    assert(singleResetCount == 10);
    assert(singleResetFiber.isCompleted);
    singleResetFiber.reset();
    assert(!singleResetFiber.isCompleted);
    assert(singleResetFiber.completedSteps == 0);
    assert(singleResetFiber.currentStep == 0);
    assert(singleResetFiber.runToCompletion() == 2);
    assert(singleResetCount == 20);
    assert(singleResetFiber.isCompleted);

    // 11. AutomationFiberRunner.step() preserves unexecuted fibers when intermediate fiber throws
    auto robustRunner = new AutomationFiberRunner();
    int ranA = 0, ranB = 0, ranC = 0;
    auto robustA = new AutomationFiber([
        cast(void delegate())() { ranA++; }, cast(void delegate())() { ranA++; },
    ]);
    auto robustB = new AutomationFiber([
        cast(void delegate())() {
            ranB++;
            throw new Exception("intermediate failure");
        }, cast(void delegate())() { ranB++; },
    ]);
    auto robustC = new AutomationFiber([
        cast(void delegate())() { ranC++; }, cast(void delegate())() { ranC++; },
    ]);
    robustRunner.add(robustA);
    robustRunner.add(robustB);
    robustRunner.add(robustC);
    assert(robustRunner.activeCount == 3);

    try
    {
        robustRunner.step();
        assert(false, "Should have thrown intermediate failure");
    }
    catch (Exception e)
    {
        assert(e.msg == "intermediate failure");
    }

    // Crucial check: failing fiber B is pruned, but prior active fiber A AND subsequent unstepped fiber C survive!
    assert(robustRunner.activeCount == 2);
    assert(ranA == 1);
    assert(ranB == 1);
    assert(ranC == 0); // Not yet stepped, but retained in scheduler

    // Step again: robustA and robustC now both step
    robustRunner.step();
    assert(ranA == 2); // completed
    assert(ranC == 1); // step 1 executed
    assert(robustRunner.activeCount == 1); // only robustC remains

    robustRunner.step();
    assert(ranC == 2);
    assert(robustRunner.activeCount == 0);

    // 12. Stack ceiling preconditions and runner remove/clear
    assertThrown!AssertError(new AutomationFiber(() {}, 32 * 1024 * 1024)); // > maxFiberStackSize (16MB)
    assertThrown!AssertError(new AutomationFiber([cast(void delegate())() {}], 32 * 1024 * 1024));

    auto modRunner = new AutomationFiberRunner();
    auto remA = new AutomationFiber(() {});
    auto remB = new AutomationFiber(() {});
    modRunner.add(remA);
    modRunner.add(remB);
    assert(modRunner.activeCount == 2);
    assert(modRunner.remove(remA) == true);
    assert(modRunner.remove(remA) == false); // idempotent removal
    assert(modRunner.activeCount == 1);
    modRunner.clear();
    assert(modRunner.activeCount == 0);

    // 13. Exact step counting in runAll for single-step and multi-step fibers
    auto exactRunner1 = new AutomationFiberRunner();
    exactRunner1.add(new AutomationFiber(() {}));
    assert(exactRunner1.runAll() == 1);

    auto exactRunner2 = new AutomationFiberRunner();
    exactRunner2.add(new AutomationFiber([
        cast(void delegate())() {}, cast(void delegate())() {},
    ]));
    assert(exactRunner2.runAll() == 2);

    // 13. Iteration ceiling prevents unbounded loops
    auto infFiber = new AutomationFiber({
        while (true)
            AutomationFiber.yield();
    });
    assertThrown!Exception(infFiber.runToCompletion(10));
}
