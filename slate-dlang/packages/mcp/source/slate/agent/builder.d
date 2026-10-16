/// Agent assembly: builder, server lifecycle starters, and lifecycle handle.
///
/// Port of `slate_agent::builder`: `AgentBuilder` wiring (default Slint
/// backends or custom overrides, pluggable server lifecycle handles) returning an
/// `AgentHandle`. Adaptations:
/// - Rust is generic over the Slint window type and leaks a tokio runtime
///   (`ensure_tokio_runtime`). D threads start on demand, so no runtime
///   exists; the builder wires engine components + bridge + servers.
/// - Slint-backed inspector/controller/renderer need element-query APIs
///   that `slint-d` does not expose yet (`slate.agent.slint_backend`,
///   next); until then the builder composes caller-provided or default
///   components, exactly the seam Rust's `with_inspector/...` offers.
/// - MCP servers start via `ServerStarter` callbacks returning `ServerLifecycleHandle`.
module slate.agent.builder;

import core.time : Duration;
import std.typecons : Nullable;

import slate.agent.bridge : ComponentBridge, SlintUiBridge, defaultUiTimeout;
import slate.agent.engine : AutomationEngine, AutomationEngineBuilder,
    DefaultAutomationEngine, ElementController, StateProvider, UiInspector, VisualRenderer;
import slate.agent.error : AgentError;

/// Lifecycle handle for an attached protocol server.
interface ServerLifecycleHandle
{
    /// Whether the server is actively processing requests.
    bool isRunning();

    /// Gracefully stop; throw `AgentError` when shutdown fails.
    void stop();

    /// Local address or endpoint id; null when not applicable.
    Nullable!string localAddr();
}

/// Factory delegate that starts a protocol server attached to an engine.
alias ServerStarter = ServerLifecycleHandle delegate(AutomationEngine engine);

/// Assembles an engine, bridge, and protocol servers into a handle.
class AgentBuilder
{
    private string _name = "slate";
    private string _version = "0.1.0";
    private Duration _timeout = defaultUiTimeout;
    private UiInspector _inspector;
    private ElementController _controller;
    private StateProvider _state;
    private VisualRenderer _renderer;
    private ServerStarter[] _serverStarters;

    AgentBuilder withName(string name)
    {
        _name = name;
        return this;
    }

    AgentBuilder withVersion(string version_)
    {
        _version = version_;
        return this;
    }

    AgentBuilder withTimeout(Duration timeout)
    {
        _timeout = timeout;
        return this;
    }

    AgentBuilder withInspector(UiInspector v)
    {
        _inspector = v;
        return this;
    }

    AgentBuilder withController(ElementController v)
    {
        _controller = v;
        return this;
    }

    AgentBuilder withStateProvider(StateProvider v)
    {
        _state = v;
        return this;
    }

    AgentBuilder withRenderer(VisualRenderer v)
    {
        _renderer = v;
        return this;
    }

    alias WindowWiringFn = void function(AgentBuilder builder, Object window);
    private static __gshared Object _windowWiringLock = new Object();
    private static __gshared WindowWiringFn _windowWiringHook = null;

    static void setAgentWindowWiringHook(WindowWiringFn fn) @trusted
    {
        synchronized (_windowWiringLock)
        {
            _windowWiringHook = fn;
        }
    }

    static WindowWiringFn getAgentWindowWiringHook() @trusted
    {
        synchronized (_windowWiringLock)
        {
            return _windowWiringHook;
        }
    }

    /// Create an `AgentBuilder` pre-wired with inspectors/controllers for `window`
    /// (using the registered UI window wiring hook if present, or no-op inspector/controller/renderer if null/unregistered)
    /// and `state` (defaulting to a new `McpStateRegistry`).
    static AgentBuilder forWindow(Object window, StateProvider state = null)
    {
        import slate.agent.declarative : McpStateRegistry;
        import slate.agent.engine : DefaultUiInspector,
            DefaultElementController, DefaultVisualRenderer;

        auto sp = state !is null ? state : new McpStateRegistry("main");
        auto builder = new AgentBuilder().withStateProvider(sp);

        auto hook = getAgentWindowWiringHook();
        if (window !is null && hook !is null)
        {
            hook(builder, window);
        }
        else
        {
            builder.withInspector(new DefaultUiInspector())
                .withController(new DefaultElementController()).withRenderer(
                    new DefaultVisualRenderer());
        }
        return builder;
    }

    /// Register a protocol server starter; attached on `start`.
    AgentBuilder addServerStarter(ServerStarter starter)
    {
        _serverStarters ~= starter;
        return this;
    }

    /// Build engine + bridge without starting protocols.
    AgentHandle build()
    {
        auto engine = new AutomationEngineBuilder().inspector(_inspector)
            .controller(_controller).stateProvider(_state).renderer(_renderer).build();
        return new AgentHandle(engine, new SlintUiBridge(_timeout), _name, _version, null);
    }

    /// Build and attach every registered protocol server, in order.
    /// A failing attach stops the already-started handles and rethrows.
    AgentHandle start()
    {
        auto handle = build();
        try
        {
            foreach (starter; _serverStarters)
                handle.attach(starter(handle.engine()));
        }
        catch (Throwable t)
        {
            handle.shutdown();
            if (auto e = cast(AgentError) t)
                throw e;
            throw AgentError.internal_(t.msg);
        }
        return handle;
    }
}

/// Running agent: engine, bridge, and attached protocol servers.
class AgentHandle
{
    private AutomationEngine _engine;
    private SlintUiBridge _bridge;
    private string _name;
    private string _version;
    private ServerLifecycleHandle[] _handles;
    private bool _stopped;

    this(AutomationEngine engine, SlintUiBridge bridge, string name,
            string version_, ServerLifecycleHandle[] handles)
    {
        _engine = engine;
        _bridge = bridge;
        _name = name;
        _version = version_;
        _handles = handles.dup;
    }

    AutomationEngine engine()
    {
        return _engine;
    }

    SlintUiBridge bridge()
    {
        return _bridge;
    }

    string name() const @safe pure nothrow
    {
        return _name;
    }

    string version_() const @safe pure nothrow
    {
        return _version;
    }

    ServerLifecycleHandle[] serverHandles()
    {
        return _handles.dup;
    }

    bool isRunning()
    {
        if (_stopped)
            return false;
        foreach (h; _handles)
            if (!h.isRunning())
                return false;
        return true;
    }

    /// Attach one more server to a live handle (used by `AgentBuilder`).
    void attach(ServerLifecycleHandle handle)
    {
        _handles ~= handle;
    }

    /// Stop every server in reverse order, collecting the first failure.
    void stop()
    {
        AgentError first;
        foreach_reverse (h; _handles)
        {
            try
                h.stop();
            catch (AgentError e)
            {
                if (first is null)
                    first = e;
            }
        }
        _stopped = true;
        if (first !is null)
            throw first;
    }

    /// Stop and release (idempotent).
    void shutdown()
    {
        if (_stopped)
            return;
        try
            stop();
        catch (AgentError)
        {
        }
    }

    ~this()
    {
        shutdown();
    }
}

// Spec: AgentBuilder assembly, protocol server starters, and AgentHandle lifecycle
/// Example:
unittest
{
    import slate.agent.engine : DefaultElementController, DefaultStateProvider,
        DefaultUiInspector, DefaultVisualRenderer;
    import std.exception : assertThrown;
    import std.typecons : Nullable;

    static class ScriptHandle : ServerLifecycleHandle
    {
        bool running = true;
        bool stopped;
        override bool isRunning()
        {
            return running && !stopped;
        }

        override void stop()
        {
            stopped = true;
        }

        override Nullable!string localAddr()
        {
            return Nullable!string.init;
        }
    }

    // Missing components fail with the engine builder's messages.
    assertThrown!AgentError(new AgentBuilder().build());

    auto handle = new AgentBuilder().withName("demo").withInspector(new DefaultUiInspector())
        .withController(new DefaultElementController()).withStateProvider(new DefaultStateProvider())
        .withRenderer(new DefaultVisualRenderer()).addServerStarter(
            (engine) => new ScriptHandle()).start();

    assert(handle.name == "demo" && handle.isRunning());
    assert(handle.serverHandles().length == 1);
    assert(handle.engine().inspector().inspectTree().countElements() == 1);
    handle.stop();
    assert(!handle.isRunning());
    handle.shutdown(); // idempotent

    // Verify forWindow with null wires default components
    auto fw = AgentBuilder.forWindow(null);
    auto fwHandle = fw.build();
    assert(fwHandle !is null);
    assert(fwHandle.engine().inspector().inspectTree().countElements() == 1);
}

// Spec: Defect D-1 - AgentBuilder.forWindow with arbitrary Object or null safely falls back to default components without TOCTOU
/// Example:
unittest
{
    auto prevHook = AgentBuilder.getAgentWindowWiringHook();
    scope (exit)
        AgentBuilder.setAgentWindowWiringHook(prevHook);

    AgentBuilder.setAgentWindowWiringHook(null);
    auto fwObj = AgentBuilder.forWindow(new Object());
    auto handleObj = fwObj.build();
    assert(handleObj !is null);
    assert(handleObj.engine().inspector().inspectTree().countElements() == 1);
    assert(handleObj.engine().controller() !is null);
    assert(handleObj.engine().renderer() !is null);
}
