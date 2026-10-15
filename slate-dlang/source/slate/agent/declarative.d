/// Declarative MCP state registry composing `McpControllable` controllers
/// into a transactional `StateProvider`.
///
/// Satisfies requirements `U2` and `W2` (`Scenario T1`):
/// - Registers any `McpControllable` (or struct with `@McpState` via `asMcpControllable`)
///   under its namespace prefix (e.g. `"media"`, `"file_dialog"`, `"datagrid"`).
/// - Exposes both `<namespace>.<key>` flat properties and `<namespace>` object
///   subtrees in `getState`.
/// - Executes `setProperty("<namespace>.<key>", value)` transactionally over
///   `SlintUiBridge.runTransactional`, rolling back the controller's snapshot
///   if validation or UI synchronization throws.
module slate.agent.declarative;

import core.sync.mutex : Mutex;
import std.json : JSONValue, JSONType;
import std.string : indexOf;
import std.typecons : Nullable;

import slate.agent.bridge : SlintUiBridge;
import slate.agent.engine : StateProvider;
import slate.agent.error : AgentError;
import slate.agent.model : AppState, DiagnosticMetrics;
import slate.agent.traits : McpControllable, asMcpControllable;

/// Registry aggregating `McpControllable` component controllers and custom properties.
final class McpStateRegistry : StateProvider
{
    private Mutex _mtx;
    private SlintUiBridge _bridge;
    private string _activeView;
    private McpControllable[string] _controllers;
    private JSONValue[string] _customProperties;
    private DiagnosticMetrics _diagnostics;

    this(string initialView = "main", SlintUiBridge bridge = null)
    {
        _mtx = new Mutex();
        _activeView = initialView;
        _bridge = bridge;
    }

    private T executeTransactional(T, S)(S stateSnapshot, T delegate() action, void delegate(S) rollback)
    {
        if (_bridge !is null)
            return _bridge.runTransactional!(T, S)(stateSnapshot, action, rollback);

        scope (failure)
        {
            if (rollback !is null)
            {
                try
                    rollback(stateSnapshot);
                catch (Throwable)
                {
                }
            }
        }
        static if (is(T == void))
            action();
        else
            return action();
    }

    /// Register a `McpControllable` controller under its `mcpNamespace()` (or an explicit override).
    McpStateRegistry registerController(McpControllable controller, string namespaceOverride = "")
    in
    {
        assert(controller !is null, "controller must not be null");
    }
    do
    {
        string ns = namespaceOverride.length > 0 ? namespaceOverride : controller.mcpNamespace();
        if (ns.length == 0)
            throw AgentError.invalidParams("namespace", "Controller namespace must not be empty");
        synchronized (_mtx)
        {
            _controllers[ns] = controller;
        }
        return this;
    }

    /// Register a value-type `struct` controller pointer under `namespace`.
    McpStateRegistry registerStruct(T)(T* target, string namespace)
    if (is(T == struct))
    {
        return registerController(asMcpControllable(target, namespace), namespace);
    }

    /// Look up a registered controller by namespace.
    McpControllable findController(string namespace)
    {
        synchronized (_mtx)
        {
            if (auto p = namespace in _controllers)
                return *p;
            return null;
        }
    }

    /// Update the active view identifier reported in `AppState`.
    void setActiveView(string view)
    {
        synchronized (_mtx)
            _activeView = view;
    }

    /// Update diagnostic metrics reported by `getDiagnostics()`.
    void setDiagnostics(DiagnosticMetrics metrics)
    {
        synchronized (_mtx)
            _diagnostics = metrics;
    }

    override AppState getState(Nullable!string query)
    {
        synchronized (_mtx)
        {
            auto state = AppState.create(_activeView).withDiagnostics(_diagnostics);

            // Collect all flat and grouped controller properties
            JSONValue[string] allProps;
            foreach (k, v; _customProperties)
                allProps[k] = v;

            foreach (ns, ctrl; _controllers)
            {
                auto snap = ctrl.mcpSnapshot();
                allProps[ns] = snap;
                allProps[ns ~ "._capabilities"] = JSONValue(ctrl.mcpCapabilities());
                if (snap.type == JSONType.object)
                {
                    foreach (propKey, propVal; snap.object)
                        allProps[ns ~ "." ~ propKey] = propVal;
                }
            }

            if (!query.isNull && query.get.length > 0)
            {
                string q = query.get;
                if (auto exact = q in allProps)
                {
                    state = state.withProperty(q, *exact);
                }
                else
                {
                    // Prefix match (e.g. "media." or "media")
                    string prefix = (q[$ - 1] == '.') ? q : (q ~ ".");
                    foreach (k, v; allProps)
                    {
                        if (k.length > prefix.length && k[0 .. prefix.length] == prefix)
                            state = state.withProperty(k, v);
                    }
                }
            }
            else
            {
                foreach (k, v; allProps)
                    state = state.withProperty(k, v);
            }
            return state;
        }
    }

    override DiagnosticMetrics getDiagnostics()
    {
        synchronized (_mtx)
            return _diagnostics;
    }

    override void setProperty(string key, JSONValue value)
    {
        ptrdiff_t dot = key.indexOf('.');
        if (dot > 0)
        {
            string ns = key[0 .. dot];
            string relKey = key[dot + 1 .. $];
            McpControllable ctrl;
            synchronized (_mtx)
            {
                if (auto p = ns in _controllers)
                    ctrl = *p;
            }
            if (ctrl !is null)
            {
                JSONValue prevSnapshot = ctrl.mcpSnapshot();
                executeTransactional!(void, JSONValue)(
                    prevSnapshot,
                    () {
                        bool matched = ctrl.mcpSetProperty(relKey, value);
                        if (!matched)
                            throw AgentError.invalidParams(key, "Property is not writable or does not exist");
                    },
                    (JSONValue snap) {
                        ctrl.mcpRestoreSnapshot(snap);
                    }
                );
                return;
            }
        }

        synchronized (_mtx)
        {
            _customProperties[key] = value;
        }
    }

    /// Transactional batch property update: snapshots affected controllers,
    /// applies updates in order, and if any update throws, rolls back all
    /// affected controllers to their pre-batch snapshots before rethrowing.
    void applyProperties(JSONValue[string] updates)
    {
        McpControllable[string] affectedControllers;
        JSONValue[string] originalSnapshots;
        JSONValue[string] originalCustomProps;

        synchronized (_mtx)
        {
            foreach (key, val; updates)
            {
                ptrdiff_t dot = key.indexOf('.');
                if (dot > 0)
                {
                    string ns = key[0 .. dot];
                    if (ns !in affectedControllers)
                    {
                        if (auto p = ns in _controllers)
                        {
                            affectedControllers[ns] = *p;
                            originalSnapshots[ns] = (*p).mcpSnapshot();
                        }
                    }
                }
            }
            originalCustomProps = _customProperties.dup;
        }

        struct BatchSnapshot
        {
            JSONValue[string] controllerSnapshots;
            JSONValue[string] customProps;
        }

        BatchSnapshot snap;
        snap.controllerSnapshots = originalSnapshots;
        snap.customProps = originalCustomProps;

        executeTransactional!(void, BatchSnapshot)(
            snap,
            () {
                foreach (key, val; updates)
                {
                    ptrdiff_t dot = key.indexOf('.');
                    if (dot > 0)
                    {
                        string ns = key[0 .. dot];
                        string relKey = key[dot + 1 .. $];
                        if (auto p = ns in affectedControllers)
                        {
                            bool matched = (*p).mcpSetProperty(relKey, val);
                            if (!matched)
                                throw AgentError.invalidParams(key, "Property is not writable or does not exist");
                        }
                        else
                        {
                            throw AgentError.invalidParams(key, "Namespace does not exist");
                        }
                    }
                    else
                    {
                        synchronized (_mtx)
                        {
                            _customProperties[key] = val;
                        }
                    }
                }
            },
            (BatchSnapshot s) {
                foreach (ns, csnap; s.controllerSnapshots)
                {
                    if (auto p = ns in affectedControllers)
                    {
                        (*p).mcpRestoreSnapshot(csnap);
                    }
                }
                synchronized (_mtx)
                {
                    _customProperties = s.customProps.dup;
                }
            }
        );
    }

    void applyProperties(JSONValue updatesObject)
    {
        if (updatesObject.type != JSONType.object)
            throw AgentError.invalidParams("updates", "Expected a JSON object of key-value property updates");
        applyProperties(updatesObject.object);
    }

    /// Invoke a named `@McpAction` on a registered controller transactionally.
    JSONValue invokeAction(string namespace, string action, JSONValue params = JSONValue.init)
    {
        McpControllable ctrl;
        synchronized (_mtx)
        {
            if (auto p = namespace in _controllers)
                ctrl = *p;
        }
        if (ctrl is null)
            throw AgentError.elementNotFound(namespace, "No MCP controller registered under namespace");

        JSONValue prevSnapshot = ctrl.mcpSnapshot();
        return executeTransactional!(JSONValue, JSONValue)(
            prevSnapshot,
            () => ctrl.mcpInvokeAction(action, params),
            (JSONValue snap) {
                ctrl.mcpRestoreSnapshot(snap);
            }
        );
    }
}

// Spec: Scenario T1 / W2 / Security: Declarative MCP controller traits, mixin reflection, batch applyProperties, and transactional mutation rollback
/// Example:
unittest
{
    import std.exception : assertThrown;
    import std.typecons : Nullable, nullable;
    import slate.agent.traits : McpControllable, McpSeekable, McpControllableMixin,
        McpState, McpWritable, McpAction, isMcpControllable, isMcpSeekable;

    static final class TestMediaController : McpControllable, McpSeekable
    {
        mixin McpControllableMixin!"media";

        @McpState("state") @McpWritable("state")
        string state = "stopped";

        @McpState("volume")
        double volume = 0.5;

        @McpState("position_seconds")
        double pos = 0.0;

        @McpState("duration_seconds")
        double dur = 180.0;

        @McpWritable("volume")
        void setVolume(double v)
        {
            if (v < 0.0 || v > 1.0)
                throw AgentError.invalidParams("media.volume", "Volume must be in [0.0, 1.0]");
            volume = v;
        }

        @McpWritable("position_seconds") @McpAction("seek")
        override void seekTo(double seconds)
        {
            if (seconds < 0.0 || seconds > dur)
                throw AgentError.invalidParams("media.position_seconds", "Seek out of bounds");
            pos = seconds;
        }

        override double positionSeconds() const @safe pure nothrow { return pos; }
        override double durationSeconds() const @safe pure nothrow { return dur; }
    }

    static struct TestFileDialogState
    {
        @McpState("current_dir") @McpWritable("current_dir")
        string currentDir = "/workspace";
    }

    static assert(isMcpControllable!TestMediaController);
    static assert(isMcpSeekable!TestMediaController);
    static assert(isMcpControllable!TestFileDialogState);

    auto media = new TestMediaController();
    TestFileDialogState fileDlg;

    auto registry = new McpStateRegistry("showcase");
    registry.registerController(media);
    registry.registerStruct(&fileDlg, "file_dialog");

    // Query state keys
    auto st1 = registry.getState(nullable("media.state"));
    assert(st1.properties["media.state"].str == "stopped");

    auto st2 = registry.getState(nullable("file_dialog.current_dir"));
    assert(st2.properties["file_dialog.current_dir"].str == "/workspace");

    // Valid mutation
    registry.setProperty("media.volume", JSONValue(0.75));
    assert(media.volume == 0.75);

    // Invalid mutation rolls back state via SlintUiBridge.runTransactional
    media.state = "playing";
    try
    {
        registry.setProperty("media.volume", JSONValue(-5.0));
        assert(false, "Expected invalidParams");
    }
    catch (AgentError e)
    {
        assert(e.kind == AgentError.Kind.invalidParams);
    }
    assert(media.volume == 0.75);

    // Action invocation
    registry.invokeAction("media", "seek", JSONValue(60.0));
    assert(media.positionSeconds() == 60.0);

    // Batch applyProperties: valid updates mutate properties
    registry.applyProperties([
        "media.volume": JSONValue(0.9),
        "media.position_seconds": JSONValue(30.0)
    ]);
    assert(media.volume == 0.9);
    assert(media.positionSeconds() == 30.0);

    // Batch applyProperties: when a subsequent property in batch fails validation,
    // earlier mutated setter-backed properties are rolled back!
    try
    {
        registry.applyProperties([
            "media.volume": JSONValue(0.2),
            "media.position_seconds": JSONValue(-5.0)
        ]);
        assert(false, "Expected invalidParams");
    }
    catch (AgentError e)
    {
        assert(e.kind == AgentError.Kind.invalidParams);
    }
    assert(media.volume == 0.9);
    assert(media.positionSeconds() == 30.0);

    // Custom property deletion and rollback on batch failure
    registry.setProperty("custom_existing", JSONValue("initial_val"));
    try
    {
        registry.applyProperties([
            "custom_new": JSONValue("transient_val"),
            "custom_existing": JSONValue("mutated_val"),
            "media.volume": JSONValue(999.0) // Invalid!
        ]);
        assert(false, "Expected invalidParams");
    }
    catch (AgentError e)
    {
        assert(e.kind == AgentError.Kind.invalidParams);
    }
    auto customCheck = registry.getState(Nullable!string.init);
    assert("custom_new" !in customCheck.properties, "New custom property must be discarded on rollback");
    assert(customCheck.properties["custom_existing"].str == "initial_val", "Existing custom property must be restored");

    // Multi-controller exact rollback (media, file_dialog, datagrid)
    import slate.components.media : MediaPlayerController, SimulatedMediaBackend, MediaTrackData;
    import slate.components.file_dialog : FileDialogController, InMemoryFileSystem;
    import slate.components.datagrid : DataGridController, GridRowData;

    auto regFull = new McpStateRegistry("full_rollback_test");
    auto simBackend = new SimulatedMediaBackend(200.0);
    auto fullMedia = new MediaPlayerController([MediaTrackData("t1", "Track 1", "Artist 1", 200.0f)], simBackend);
    fullMedia.seekTo(50.0);
    assert(fullMedia.positionSeconds() == 50.0);
    regFull.registerController(fullMedia, "media");

    auto vfs = new InMemoryFileSystem();
    vfs.addFile("/workspace/item.txt", 100);
    auto fullFile = new FileDialogController(vfs, "/workspace", "/workspace");
    assert(fullFile.selectedIndex() == -1);
    regFull.registerController(fullFile, "file_dialog");

    auto fullGrid = new DataGridController!GridRowData([GridRowData("1", "A", "", "", "", "", "")], 10);
    assert(fullGrid.sortColumn() == -1);
    regFull.registerController(fullGrid, "datagrid");

    try
    {
        regFull.applyProperties([
            "media.volume": JSONValue(0.1),
            "media.position_seconds": JSONValue(80.0),
            "file_dialog.selected_index": JSONValue(0),
            "datagrid.current_page": JSONValue(1),
            "media.volume": JSONValue(-50.0) // Invalid!
        ]);
        assert(false, "Expected invalidParams");
    }
    catch (AgentError e)
    {
        assert(e.kind == AgentError.Kind.invalidParams);
    }

    // Media position preserved at 50.0, volume at initial 0.8
    assert(fullMedia.positionSeconds() == 50.0);
    assert(fullMedia.volume() == 0.8);
    // File dialog selection restored to -1
    assert(fullFile.selectedIndex() == -1);
    // DataGrid sort column restored to -1
    assert(fullGrid.sortColumn() == -1);
}
