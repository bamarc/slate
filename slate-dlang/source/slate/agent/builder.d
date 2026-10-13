/// Agent assembly: builder, protocol-adapter slots, and lifecycle handle.
///
/// Port of `slate_agent::builder`: `AgentBuilder` wiring (default Slint
/// backends or custom overrides, pluggable protocol adapters) returning an
/// `AgentHandle`. Adaptations:
/// - Rust is generic over the Slint window type and leaks a tokio runtime
///   (`ensure_tokio_runtime`). D threads start on demand, so no runtime
///   exists; the builder wires engine components + bridge + adapters.
/// - Slint-backed inspector/controller/renderer need element-query APIs
///   that `slint-d` does not expose yet (`slate.agent.slint_backend`,
///   next); until then the builder composes caller-provided or default
///   components, exactly the seam Rust's `with_inspector/...` offers.
/// - Heterogeneous adapters erase to a private slot interface capturing
///   the typed `attach` call (the canonical D substitute for storing
///   distinct `AgentProtocolAdapter` instantiations).
module slate.agent.builder;

import core.time : Duration;

import slate.agent.bridge : ComponentBridge, SlintUiBridge, defaultUiTimeout;
import slate.agent.engine : AutomationEngine, AutomationEngineBuilder, DefaultAutomationEngine,
    ElementController, StateProvider, UiInspector, VisualRenderer;
import slate.agent.error : AgentError;
import slate.agent.protocol : AgentProtocolAdapter, ProtocolServerHandle;

/// Type-erased protocol attachment, captured at registration time.
private interface AdapterSlot
{
    ProtocolServerHandle attachNow(AutomationEngine engine);
}

private final class AdapterSlotImpl(A, C) : AdapterSlot
{
    private A _adapter;
    private C _config;

    this(A adapter, C config)
    {
        _adapter = adapter;
        _config = config;
    }

    override ProtocolServerHandle attachNow(AutomationEngine engine)
    {
        return _adapter.attach(engine, _config);
    }
}

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
    private AdapterSlot[] _adapters;

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

    /// Register a protocol adapter with its config; attached on `start`.
    AgentBuilder withProtocolAdapter(A, C, H : ProtocolServerHandle)(
        AgentProtocolAdapter!(C, H) adapter, C config)
    {
        _adapters ~= new AdapterSlotImpl!(typeof(adapter), C)(adapter, config);
        return this;
    }

    /// Build engine + bridge without starting protocols.
    AgentHandle build()
    {
        auto engine = new AutomationEngineBuilder()
            .inspector(_inspector)
            .controller(_controller)
            .stateProvider(_state)
            .renderer(_renderer)
            .build();
        return new AgentHandle(engine, new SlintUiBridge(_timeout), _name, _version, null);
    }

    /// Build and attach every registered protocol adapter, in order.
    /// A failing attach stops the already-started handles and rethrows.
    AgentHandle start()
    {
        auto handle = build();
        try
        {
            foreach (slot; _adapters)
                handle.attach(slot.attachNow(handle.engine()));
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
    private ProtocolServerHandle[] _handles;
    private bool _stopped;

    this(AutomationEngine engine, SlintUiBridge bridge, string name,
        string version_, ProtocolServerHandle[] handles)
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

    ProtocolServerHandle[] serverHandles()
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
    void attach(ProtocolServerHandle handle)
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

///
unittest
{
    import slate.agent.engine : DefaultElementController, DefaultStateProvider,
        DefaultUiInspector, DefaultVisualRenderer;
    import slate.agent.protocol : ProtocolServerHandle;
    import std.exception : assertThrown;
    import std.typecons : Nullable;

    static class ScriptHandle : ProtocolServerHandle
    {
        bool running = true;
        bool stopped;
        string[] log;
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

    static class ScriptAdapter : AgentProtocolAdapter!(string, ScriptHandle)
    {
        ScriptHandle last;
        override ScriptHandle attach(AutomationEngine engine, string config)
        {
            assert(engine !is null && config == "test");
            last = new ScriptHandle();
            return last;
        }
    }

    // Missing components fail with the engine builder's messages.
    assertThrown!AgentError(new AgentBuilder().build());

    auto adapter = new ScriptAdapter();
    auto handle = new AgentBuilder()
        .withName("demo")
        .withInspector(new DefaultUiInspector())
        .withController(new DefaultElementController())
        .withStateProvider(new DefaultStateProvider())
        .withRenderer(new DefaultVisualRenderer())
        .withProtocolAdapter!(ScriptAdapter, string, ScriptHandle)(adapter, "test")
        .start();

    assert(handle.name == "demo" && handle.isRunning());
    assert(handle.serverHandles().length == 1);
    assert(handle.engine().inspector().inspectTree().countElements() == 1);
    handle.stop();
    assert(!handle.isRunning());
    handle.shutdown(); // idempotent
}
