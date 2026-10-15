/// Automation engine: subsystem interfaces, defaults, and composition.
///
/// Port of `slate_agent::{traits, engine}`. Adaptation notes (all
/// documented at the use site):
/// - Rust uses `#[async_trait]` + tokio throughout. D has no async/await;
///   the canonical mapping is synchronous interfaces — composition that
///   needs concurrency uses fibers (`slate.fiber`) or worker threads, and
///   Slint-thread dispatch goes through `SlintUiBridge` (`slate.agent.bridge`).
/// - D interfaces cannot carry default bodies (as with `slate.plugin`);
///   trait defaults become free functions invoked through UFCS, so call
///   sites keep method syntax: `inspector.findElement("#ok")`.
/// - `Arc<dyn Trait>` becomes a plain interface reference (D is GC'd);
///   `RwLock` state becomes `synchronized` methods.
module slate.agent.engine;

import core.sync.mutex : Mutex;
import std.json : JSONValue;
import std.typecons : Nullable, nullable, Tuple, tuple;

import slate.agent.error : AgentError;
import slate.agent.model;

// -- subsystem interfaces -----------------------------------------------

/// Inspect the component tree and element geometry.
interface UiInspector
{
    UiTree inspectTree();
}

/// Find an element by selector (default: search the inspected tree).
UiElementNode findElement(UiInspector self, string target)
{
    auto tree = self.inspectTree();
    auto found = tree.findBySelector(target);
    if (found is null)
        throw AgentError.elementNotFound(target, "Element not present in UI tree");
    return found;
}

/// Bounding rectangle of an element (default: via `findElement`).
Rect elementBounds(UiInspector self, string target)
{
    return self.findElement(target).bounds;
}

/// Dispatch user-interaction events to UI elements.
interface ElementController
{
    ActionResult clickElement(string target);
    ActionResult clickAt(Point point, MouseButton button);
    ActionResult sendKeys(Nullable!string target, string text);
    ActionResult setValue(string target, string value);
    ActionResult toggleElement(string target);
}

/// Toggle with explicit target state (default: plain toggle, like Rust).
ActionResult toggleElementState(ElementController self, string target, Nullable!bool state)
{
    return self.toggleElement(target);
}

/// Query and mutate application state and diagnostics.
interface StateProvider
{
    AppState getState(Nullable!string query);
    DiagnosticMetrics getDiagnostics();
    void setProperty(string key, JSONValue value);
}

/// Capture visual frames and viewport dimensions (logical px contract:
/// inputs arrive in logical coordinates, so viewports must be logical too).
interface VisualRenderer
{
    Screenshot getScreenshot();
    Tuple!(uint, "width", uint, "height") viewportSize();
}

/// Unified facade composing the four subsystems (GC references replace
/// Rust's `Arc<dyn …>`).
interface AutomationEngine
{
    UiInspector inspector();
    ElementController controller();
    StateProvider state();
    VisualRenderer renderer();
}

// UFCS facade defaults (mirror the trait's provided methods).
UiTree inspectTree(AutomationEngine e)
{
    return e.inspector().inspectTree();
}

ActionResult clickElement(AutomationEngine e, string target)
{
    return e.controller().clickElement(target);
}

ActionResult sendKeys(AutomationEngine e, Nullable!string target, string text)
{
    return e.controller().sendKeys(target, text);
}

AppState getState(AutomationEngine e, Nullable!string query)
{
    return e.state().getState(query);
}

Screenshot getScreenshot(AutomationEngine e)
{
    return e.renderer().getScreenshot();
}

// -- facade implementation ----------------------------------------------

/// Engine facade delegating to four subsystem instances.
class DefaultAutomationEngine : AutomationEngine
{
    private UiInspector _inspector;
    private ElementController _controller;
    private StateProvider _state;
    private VisualRenderer _renderer;

    this(UiInspector inspector, ElementController controller,
        StateProvider state, VisualRenderer renderer) @safe pure nothrow
    {
        _inspector = inspector;
        _controller = controller;
        _state = state;
        _renderer = renderer;
    }

    static AutomationEngineBuilder builder()
    {
        return new AutomationEngineBuilder();
    }

    override UiInspector inspector()
    {
        return _inspector;
    }

    override ElementController controller()
    {
        return _controller;
    }

    override StateProvider state()
    {
        return _state;
    }

    override VisualRenderer renderer()
    {
        return _renderer;
    }
}

/// Fluent builder; `build` throws `AgentError.internal` naming the first
/// missing component, exactly like Rust.
class AutomationEngineBuilder
{
    private UiInspector _inspector;
    private ElementController _controller;
    private StateProvider _state;
    private VisualRenderer _renderer;

    AutomationEngineBuilder inspector(UiInspector v)
    {
        _inspector = v;
        return this;
    }

    AutomationEngineBuilder controller(ElementController v)
    {
        _controller = v;
        return this;
    }

    AutomationEngineBuilder stateProvider(StateProvider v)
    {
        _state = v;
        return this;
    }

    AutomationEngineBuilder renderer(VisualRenderer v)
    {
        _renderer = v;
        return this;
    }

    DefaultAutomationEngine build()
    {
        if (_inspector is null)
            throw AgentError.internal_("Missing inspector in AutomationEngineBuilder");
        if (_controller is null)
            throw AgentError.internal_("Missing controller in AutomationEngineBuilder");
        if (_state is null)
            throw AgentError.internal_("Missing state_provider in AutomationEngineBuilder");
        if (_renderer is null)
            throw AgentError.internal_("Missing renderer in AutomationEngineBuilder");
        return new DefaultAutomationEngine(_inspector, _controller, _state, _renderer);
    }
}

// -- built-in implementations -------------------------------------------

/// In-memory state provider (explicit mutex; D `synchronized` methods do
/// not satisfy interface overrides, so the lock is a member).
class DefaultStateProvider : StateProvider
{
    private Mutex _mtx;
    private string _view;
    private JSONValue[string] _properties;
    private DiagnosticMetrics _diagnostics;

    this(string initialView = "main")
    {
        _mtx = new Mutex();
        _view = initialView;
    }

    override AppState getState(Nullable!string query)
    {
        synchronized (_mtx)
        {
            auto state = AppState.create(_view).withDiagnostics(_diagnostics);
            if (!query.isNull)
            {
                if (auto v = query.get in _properties)
                    state = state.withProperty(query.get, *v);
            }
            else
            {
                foreach (k, v; _properties)
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
        synchronized (_mtx)
            _properties[key] = value;
    }

    /// Test seam: switch the reported view.
    void setActiveView(string view)
    {
        synchronized (_mtx)
            _view = view;
    }
}

/// Synthetic renderer: fixed size, blank white RGBA8 PNG frame.
/// TEST-ONLY, like Rust: production must attach a real renderer; the kept
/// 800x600 default exists for deterministic tests, never as a measurement.
class DefaultVisualRenderer : VisualRenderer
{
    private uint _width;
    private uint _height;

    this(uint width = 800, uint height = 600) @safe pure nothrow
    {
        _width = width;
        _height = height;
    }

    override Screenshot getScreenshot()
    {
        ubyte[] rgba = new ubyte[_width * _height * 4];
        rgba[] = 255;
        return Screenshot.create(_width, _height, "png", encodePngRgba(_width, _height, rgba));
    }

    override Tuple!(uint, "width", uint, "height") viewportSize() @safe pure nothrow
    {
        return tuple!("width", "height")(_width, _height);
    }
}

/// Minimal RGBA8 PNG encoder (signature + IHDR + IDAT + IEND, CRC32
/// integrity) so the default renderer needs no image dependency.
private ubyte[] encodePngRgba(uint width, uint height, const ubyte[] rgba)
{
    import std.bitmanip : nativeToBigEndian;
    import std.digest.crc : crc32Of;
    import std.zlib : compress;

    if (rgba.length != width * height * 4)
        throw AgentError.renderError("pixel buffer size mismatch");

    ubyte[] png = [137, 80, 78, 71, 13, 10, 26, 10]; // signature
    void chunk(string tag, const ubyte[] payload)
    {
        png ~= nativeToBigEndian(cast(uint) payload.length)[];
        png ~= cast(const ubyte[]) tag;
        png ~= payload;
        // NB: crc32Of yields little-endian bytes; PNG stores big-endian.
        ubyte[4] crc = crc32Of(cast(const ubyte[]) tag ~ payload);
        png ~= [crc[3], crc[2], crc[1], crc[0]];
    }

    ubyte[] ihdr;
    ihdr ~= nativeToBigEndian(width)[];
    ihdr ~= nativeToBigEndian(height)[];
    ihdr ~= [8, 6, 0, 0, 0]; // 8-bit, RGBA, deflate, no filter/interlace
    chunk("IHDR", ihdr);

    ubyte[] raw;
    raw.reserve(height * (1 + width * 4));
    foreach (y; 0 .. height)
    {
        raw ~= 0; // filter type 0 (none)
        raw ~= rgba[y * width * 4 .. (y + 1) * width * 4];
    }
    chunk("IDAT", cast(const ubyte[]) compress(raw, 6));

    chunk("IEND", []);
    return png;
}

/// In-memory tree inspector yielding a single root window node.
class DefaultUiInspector : UiInspector
{
    private string _title;
    private float _width;
    private float _height;

    this(string title = "Slate Window", float width = 800, float height = 600) @safe pure nothrow
    {
        _title = title;
        _width = width;
        _height = height;
    }

    override UiTree inspectTree()
    {
        auto root = new UiElementNode();
        root.id = "root_window";
        root.typeName = "Window";
        root.bounds = Rect(0, 0, _width, _height);
        root.label = _title;
        root.role = "Window";
        root.enabled = true;
        root.focused = true;
        root.visible = true;
        return UiTree.create(root).withWindowInfo(_title, _width, _height);
    }
}

/// Element controller echoing action results (same messages as Rust).
class DefaultElementController : ElementController
{
    override ActionResult clickElement(string target)
    {
        import std.format : format;

        return ActionResult.succeeded(format!"Clicked '%s'"(target)).withElementId(target);
    }

    override ActionResult clickAt(Point point, MouseButton button)
    {
        import std.format : format;

        return ActionResult.succeeded(format!"Clicked at (%s, %s) with %s"(
            point.x, point.y, mouseButtonName(button)));
    }

    override ActionResult sendKeys(Nullable!string target, string text)
    {
        import std.format : format;

        auto res = target.isNull
            ? ActionResult.succeeded(format!"Sent keys '%s' to active element"(text))
            : ActionResult.succeeded(format!"Sent keys '%s' to '%s'"(text, target.get));
        return target.isNull ? res : res.withElementId(target.get);
    }

    override ActionResult setValue(string target, string value)
    {
        import std.format : format;

        return ActionResult.succeeded(format!"Set value '%s' on '%s'"(value, target))
            .withElementId(target)
            .withValue(JSONValue(value));
    }

    override ActionResult toggleElement(string target)
    {
        import std.format : format;

        return ActionResult.succeeded(format!"Toggled '%s'"(target)).withElementId(target);
    }
}

///
unittest
{
    import std.exception : assertThrown;

    // Builder rejects missing components with Rust's messages.
    assertThrown!AgentError(new AutomationEngineBuilder().build());
    try
    {
        new AutomationEngineBuilder().controller(new DefaultElementController()).build();
        assert(false);
    }
    catch (AgentError e)
    {
        assert(e.msg.canFind("Missing inspector"));
    }

    auto engine = new AutomationEngineBuilder()
        .inspector(new DefaultUiInspector())
        .controller(new DefaultElementController())
        .stateProvider(new DefaultStateProvider())
        .renderer(new DefaultVisualRenderer())
        .build();

    // UFCS defaults behave like the trait's provided methods.
    auto tree = engine.inspectTree();
    assert(tree.findById("root_window").label == "Slate Window");
    assert(engine.inspector().findElement("#root_window").id == "root_window");
    assert(engine.inspector().elementBounds("#root_window") == Rect(0, 0, 800, 600));
    assertThrown!AgentError(engine.inspector().findElement("#missing"));

    assert(engine.clickElement("#ok").elementId == "#ok");
    assert(engine.controller().clickAt(Point(1, 2), MouseButton.right).message
        == "Clicked at (1, 2) with Right");
    assert(engine.sendKeys(Nullable!string.init, "hi").message == "Sent keys 'hi' to active element");
    assert(engine.controller().toggleElementState("#s", nullable(true)).success);

    auto state = engine.getState(Nullable!string.init);
    assert(state.activeView == "main" && state.properties.length == 0);
    engine.state().setProperty("tab", JSONValue("compute"));
    assert(engine.getState(nullable("tab")).properties["tab"].get!string == "compute");
    assert(engine.getState(nullable("other")).properties.length == 0);
    assert(engine.state().getDiagnostics().toJson().object.length == 0);

    // Synthetic renderer: valid PNG with the configured dimensions.
    auto shot = engine.getScreenshot();
    assert(shot.width == 800 && shot.height == 600 && shot.formatName == "png");
    immutable ubyte[8] pngSig = [137, 80, 78, 71, 13, 10, 26, 10];
    assert(shot.data[0 .. 8] == pngSig[]);
    assert(shot.data.length > 8);
    auto vp = engine.renderer().viewportSize();
    assert(vp.width == 800 && vp.height == 600);

    // PNG integrity: IHDR carries the dimensions (big-endian).
    import std.bitmanip : bigEndianToNative;

    assert(bigEndianToNative!uint(shot.data[16 .. 20]) == 800);
    assert(bigEndianToNative!uint(shot.data[20 .. 24]) == 600);
}

import std.algorithm : canFind;
