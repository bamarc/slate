/// Slint-backed implementations of `UiInspector`, `ElementController`, and `VisualRenderer`.
///
/// Bridges `ComponentInstance` (and optionally `ComponentBridge` for cross-thread
/// event-loop dispatch) to the `slate.agent.engine` subsystem interfaces.
module slate.agent.slint_backend;

import std.json : JSONType, JSONValue, parseJSON;
import std.typecons : Nullable, nullable, Tuple, tuple;

import slint.instance : ComponentInstance, ElementInfo, SlintCallError;
import slint.png : encodePngRgba;
import slint.window : KeyEvent, PointerButton, WindowHandle;

import slate.agent.bridge : ComponentBridge;
import slate.agent.engine : ElementController, UiInspector, VisualRenderer;
import slate.agent.error : AgentError;
import slate.agent.model : ActionResult, ElementSelector, MouseButton, Point,
    Rect, Screenshot, UiElementNode, UiTree, mouseButtonName;

/// Strip `#`, `id:`, `label:`, `text:`, or `role:` selector prefixes for direct C-ABI lookup.
string normalizeSelectorTarget(string target) @safe pure
{
    import std.string : strip, startsWith;

    auto t = target.strip();
    if (t.startsWith("#"))
        return t[1 .. $];
    if (t.startsWith("id:"))
        return t[3 .. $];
    if (t.startsWith("text:"))
        return t[5 .. $];
    if (t.startsWith("label:"))
        return t[6 .. $];
    if (t.startsWith("role:"))
        return t[5 .. $];
    return t;
}

/// Convert a JSON node from `ComponentInstance.dumpUiTree()` into `UiElementNode`.
UiElementNode parseSlintDumpNode(const JSONValue j)
{
    import std.algorithm : max;
    import slate.utils.json : fromJsonValue;

    if (j.type != JSONType.object)
        return null;

    auto n = new UiElementNode();
    if (auto p = "id" in j)
        if (p.type == JSONType.string)
            n.id = p.str;
    if (auto p = "role" in j)
        if (p.type == JSONType.string)
            n.role = p.str;
    if (auto p = "type_name" in j)
    {
        if (p.type == JSONType.string)
            n.typeName = p.str;
    }
    if (n.typeName.length == 0)
        n.typeName = n.role;

    if (auto p = "bounds" in j)
    {
        if (p.type == JSONType.object)
        {
            float bx = 0, by = 0, bw = 0, bh = 0;
            if (auto px = "x" in *p)
                bx = fromJsonValue!float(*px);
            if (auto py = "y" in *p)
                by = fromJsonValue!float(*py);
            if (auto pw = "width" in *p)
                bw = max(0.0f, fromJsonValue!float(*pw));
            if (auto ph = "height" in *p)
                bh = max(0.0f, fromJsonValue!float(*ph));
            n.bounds = Rect(bx, by, bw, bh);
        }
    }
    if (auto p = "label" in j)
        if (p.type == JSONType.string && p.str.length > 0)
            n.label = p.str;
    if (auto p = "value" in j)
        if (p.type == JSONType.string && p.str.length > 0)
            n.value = p.str;
    if (auto p = "enabled" in j)
        n.enabled = fromJsonValue!bool(*p);
    if (auto p = "focused" in j)
        n.focused = fromJsonValue!bool(*p);
    if (auto p = "visible" in j)
        n.visible = fromJsonValue!bool(*p);

    if (auto p = "id_stable" in j)
        n.properties["id_stable"] = *p;
    if (auto p = "description" in j)
        if (p.type == JSONType.string && p.str.length > 0)
            n.properties["description"] = *p;

    if (auto p = "children" in j)
    {
        if (p.type == JSONType.array)
        {
            foreach (k; p.array)
            {
                auto child = parseSlintDumpNode(k);
                if (child !is null)
                    n.children ~= child;
            }
        }
    }
    return n;
}

/// Live Slint `UiInspector` backed by a `ComponentInstance` or `ComponentBridge`.
class SlintUiInspector : UiInspector
{
    private ComponentInstance _window;
    private ComponentBridge _bridge;

    this(ComponentInstance window)
    {
        _window = window;
    }

    this(ComponentBridge bridge)
    {
        _bridge = bridge;
    }

    private T withWindow(T)(T delegate(ComponentInstance w) work)
    {
        if (_bridge !is null)
            return _bridge.runWithWindow!T(work);
        if (_window is null)
            throw AgentError.windowClosed();
        return work(_window);
    }

    override UiTree inspectTree()
    {
        return withWindow!UiTree((ComponentInstance w) {
            string rawJson;
            try
            {
                rawJson = w.dumpUiTree();
            }
            catch (SlintCallError e)
            {
                import std.algorithm.searching : canFind;

                if (e.msg.canFind("duplicate accessible-id"))
                    throw AgentError.duplicateAccessibleId(e.msg);
                throw AgentError.internal_("dumpUiTree failed: " ~ e.msg);
            }
            catch (Exception e)
            {
                import std.algorithm.searching : canFind;

                if (e.msg.canFind("duplicate accessible-id"))
                    throw AgentError.duplicateAccessibleId(e.msg);
                throw AgentError.internal_("dumpUiTree failed: " ~ e.msg);
            }

            auto j = parseJSON(rawJson);
            auto root = parseSlintDumpNode(j);
            if (root is null)
                throw AgentError.internal_("dumpUiTree returned invalid root JSON");

            auto sz = w.window.size;
            string title = root.label !is null ? root.label : "Slate Window";
            return UiTree.create(root).withWindowInfo(
                title,
                cast(float) sz.width,
                cast(float) sz.height
            );
        });
    }
}

/// Live Slint `ElementController` dispatching semantic accessibility actions
/// (`Default`, `SetValue`, `Increment`, `Decrement`, `Expand`) and pointer/key events.
class SlintElementController : ElementController
{
    private ComponentInstance _window;
    private ComponentBridge _bridge;

    this(ComponentInstance window)
    {
        _window = window;
    }

    this(ComponentBridge bridge)
    {
        _bridge = bridge;
    }

    private T withWindow(T)(T delegate(ComponentInstance w) work)
    {
        if (_bridge !is null)
            return _bridge.runWithWindow!T(work);
        if (_window is null)
            throw AgentError.windowClosed();
        return work(_window);
    }

    override ActionResult clickElement(string target)
    {
        import std.format : format;

        auto sel = ElementSelector.parse(target);
        if (sel.kind == ElementSelector.Kind.coordinate)
            return clickAt(sel.point, MouseButton.left);

        auto norm = normalizeSelectorTarget(target);
        return withWindow!ActionResult((ComponentInstance w) {
            try
            {
                w.invokeElementAction(norm);
                return ActionResult.succeeded(format!"Clicked '%s'"(target))
                    .withElementId(norm);
            }
            catch (SlintCallError e)
            {
                throw AgentError.elementNotFound(target, e.msg);
            }
        });
    }

    override ActionResult clickAt(Point point, MouseButton button)
    {
        import std.format : format;

        PointerButton pb = PointerButton.left;
        final switch (button)
        {
        case MouseButton.left:
            pb = PointerButton.left;
            break;
        case MouseButton.right:
            pb = PointerButton.right;
            break;
        case MouseButton.middle:
            pb = PointerButton.middle;
            break;
        }

        return withWindow!ActionResult((ComponentInstance w) {
            try
            {
                w.window.click(point.x, point.y, pb);
                return ActionResult.succeeded(format!"Clicked at (%s, %s) with %s"(
                    point.x, point.y, mouseButtonName(button)));
            }
            catch (Exception e)
            {
                throw AgentError.actionFailed("clickAt", e.msg);
            }
        });
    }

    override ActionResult sendKeys(Nullable!string target, string text)
    {
        import std.format : format;

        return withWindow!ActionResult((ComponentInstance w) {
            if (!target.isNull && target.get.length > 0)
            {
                auto norm = normalizeSelectorTarget(target.get);
                // First attempt semantic SetValue accessibility action
                try
                {
                    w.setElementValue(norm, text);
                    return ActionResult.succeeded(format!"Sent keys '%s' to '%s'"(text, target.get))
                        .withElementId(norm)
                        .withValue(JSONValue(text));
                }
                catch (SlintCallError)
                {
                    // Fallback: focus element via default action and dispatch key events
                    try
                    {
                        w.invokeElementAction(norm);
                    }
                    catch (SlintCallError e)
                    {
                        throw AgentError.elementNotFound(target.get, e.msg);
                    }
                }
            }

            try
            {
                foreach (dchar ch; text)
                {
                    import std.utf : toUTF8;
                    string s = toUTF8([ch]);
                    w.window.dispatchKey(KeyEvent.pressed, s);
                    w.window.dispatchKey(KeyEvent.released, s);
                }
                auto res = target.isNull
                    ? ActionResult.succeeded(format!"Sent keys '%s' to active element"(text))
                    : ActionResult.succeeded(format!"Sent keys '%s' to '%s'"(text, target.get))
                        .withElementId(normalizeSelectorTarget(target.get));
                return res;
            }
            catch (Exception e)
            {
                throw AgentError.actionFailed("sendKeys", e.msg);
            }
        });
    }

    override ActionResult setValue(string target, string value)
    {
        import std.format : format;

        auto norm = normalizeSelectorTarget(target);
        return withWindow!ActionResult((ComponentInstance w) {
            try
            {
                w.setElementValue(norm, value);
                return ActionResult.succeeded(format!"Set value '%s' on '%s'"(value, target))
                    .withElementId(norm)
                    .withValue(JSONValue(value));
            }
            catch (SlintCallError e)
            {
                throw AgentError.actionFailed("setValue", e.msg);
            }
        });
    }

    override ActionResult toggleElement(string target)
    {
        import std.format : format;

        auto norm = normalizeSelectorTarget(target);
        return withWindow!ActionResult((ComponentInstance w) {
            try
            {
                w.expandElement(norm);
                return ActionResult.succeeded(format!"Toggled '%s'"(target))
                    .withElementId(norm);
            }
            catch (SlintCallError)
            {
                try
                {
                    w.invokeElementAction(norm);
                    return ActionResult.succeeded(format!"Toggled '%s'"(target))
                        .withElementId(norm);
                }
                catch (SlintCallError e)
                {
                    throw AgentError.elementNotFound(target, e.msg);
                }
            }
        });
    }

    /// Trigger `AccessibilityAction::Increment` on `target`.
    ActionResult incrementElement(string target)
    {
        import std.format : format;

        auto norm = normalizeSelectorTarget(target);
        return withWindow!ActionResult((ComponentInstance w) {
            try
            {
                w.incrementElement(norm);
                return ActionResult.succeeded(format!"Incremented '%s'"(target))
                    .withElementId(norm);
            }
            catch (SlintCallError e)
            {
                throw AgentError.actionFailed("incrementElement", e.msg);
            }
        });
    }

    /// Trigger `AccessibilityAction::Decrement` on `target`.
    ActionResult decrementElement(string target)
    {
        import std.format : format;

        auto norm = normalizeSelectorTarget(target);
        return withWindow!ActionResult((ComponentInstance w) {
            try
            {
                w.decrementElement(norm);
                return ActionResult.succeeded(format!"Decremented '%s'"(target))
                    .withElementId(norm);
            }
            catch (SlintCallError e)
            {
                throw AgentError.actionFailed("decrementElement", e.msg);
            }
        });
    }
}

/// Live Slint `VisualRenderer` capturing offscreen RGBA8 snapshots as PNG.
class SlintVisualRenderer : VisualRenderer
{
    private ComponentInstance _window;
    private ComponentBridge _bridge;

    this(ComponentInstance window)
    {
        _window = window;
    }

    this(ComponentBridge bridge)
    {
        _bridge = bridge;
    }

    private T withWindow(T)(T delegate(ComponentInstance w) work)
    {
        if (_bridge !is null)
            return _bridge.runWithWindow!T(work);
        if (_window is null)
            throw AgentError.windowClosed();
        return work(_window);
    }

    override Screenshot getScreenshot()
    {
        return withWindow!Screenshot((ComponentInstance w) {
            try
            {
                auto snap = w.snapshot();
                auto png = encodePngRgba(snap.width, snap.height, snap.pixels);
                return Screenshot.create(snap.width, snap.height, "png", png);
            }
            catch (Exception e)
            {
                throw AgentError.renderError("snapshot failed: " ~ e.msg);
            }
        });
    }

    override Tuple!(uint, "width", uint, "height") viewportSize()
    {
        return withWindow!(Tuple!(uint, "width", uint, "height"))((ComponentInstance w) {
            auto sz = w.window.size;
            return tuple!("width", "height")(cast(uint) sz.width, cast(uint) sz.height);
        });
    }
}

// Spec: Scenario T2: Slint inspector and element selector normalization
/// Example:
unittest
{
    import std.exception : assertThrown;

    assert(normalizeSelectorTarget("#play-btn") == "play-btn");
    assert(normalizeSelectorTarget("id:play-btn") == "play-btn");
    assert(normalizeSelectorTarget("label:Play") == "Play");
    assert(normalizeSelectorTarget("text:Play") == "Play");
    assert(normalizeSelectorTarget("role:button") == "button");
    assert(normalizeSelectorTarget("raw-id") == "raw-id");

    // Parse dump JSON node
    auto sample = parseJSON(`{
        "id": "scrubber",
        "id_stable": true,
        "role": "slider",
        "label": "Timeline Scrubber",
        "description": "seekable",
        "value": "42.5",
        "bounds": {"x": 10, "y": 20, "width": 300, "height": 24},
        "enabled": true,
        "visible": true,
        "children": []
    }`);
    auto node = parseSlintDumpNode(sample);
    assert(node !is null);
    assert(node.id == "scrubber");
    assert(node.role == "slider");
    assert(node.typeName == "slider");
    assert(node.label == "Timeline Scrubber");
    assert(node.value == "42.5");
    assert(node.bounds == Rect(10, 20, 300, 24));
    assert(node.properties["id_stable"].boolean == true);
    assert(node.properties["description"].str == "seekable");

    // Null window throws windowClosed
    auto insp = new SlintUiInspector(cast(ComponentInstance) null);
    assertThrown!AgentError(insp.inspectTree());
}

version (SlintNative)
{
    // Spec: Scenario T2: Headless SlintNative + SlintUiInspector + SlintElementController + SlintVisualRenderer
    /// Example:
    unittest
    {
        import slint.compiler : Compiler;
        import slate.agent.declarative : McpStateRegistry;

        // Scenario T2: Headless SlintNative + SlintUiInspector + SlintElementController + SlintVisualRenderer
        auto compiler = new Compiler();
        compiler.includePaths = ["../ui"];
        auto built = compiler.buildFromSource(`
            import { SlateMcpControl, SlateMcpValueTarget, SlateMcpExpandable } from "components/mcp.slint";
            export component BackendTestWin inherits Window {
                width: 320px;
                height: 200px;
                in-out property <bool> playing: false;
                in-out property <string> scrubber-val: "0.0";
                in-out property <bool> expanded: false;

                VerticalLayout {
                    SlateMcpControl {
                        automation-id: "media-play";
                        label: "Play";
                        mcp-capabilities: "clickable";
                        triggered => { root.playing = !root.playing; }
                    }
                    SlateMcpValueTarget {
                        automation-id: "media-scrubber";
                        label: "Scrubber";
                        text-value: root.scrubber-val;
                        numeric-value: 0.0;
                        step: 5.0;
                        value-submitted(v) => { root.scrubber-val = v; }
                        stepped(n) => { root.scrubber-val = "\{n}"; }
                    }
                    SlateMcpExpandable {
                        automation-id: "tree-node-0";
                        label: "Root Folder";
                        expanded <=> root.expanded;
                    }
                }
            }
        `, "");
        auto def = built.component("BackendTestWin");
        assert(def !is null, "BackendTestWin should compile");
        auto win = def.create();

        auto inspector = new SlintUiInspector(win);
        auto controller = new SlintElementController(win);
        auto renderer = new SlintVisualRenderer(win);

        auto tree = inspector.inspectTree();
        assert(tree.findById("media-play") !is null);
        assert(tree.findById("media-play").properties["id_stable"].boolean == true);
        assert(tree.findById("media-play").properties["description"].str == "mcp:clickable");

        auto clickRes = controller.clickElement("#media-play");
        assert(clickRes.success);
        assert(win.getBool("playing") == true);

        auto setValRes = controller.setValue("#media-scrubber", "95.0");
        assert(setValRes.success);
        assert(win.getString("scrubber-val") == "95.0");

        auto incRes = controller.incrementElement("#media-scrubber");
        assert(incRes.success);
        assert(win.getString("scrubber-val") == "100");

        auto decRes = controller.decrementElement("#media-scrubber");
        assert(decRes.success);
        assert(win.getString("scrubber-val") == "95");

        auto togRes = controller.toggleElement("#tree-node-0");
        assert(togRes.success);
        assert(win.getBool("expanded") == true);

        auto shot = renderer.getScreenshot();
        assert(shot.width == 320 && shot.height == 200);
        assert(shot.data.length > 8);
    }

    // Spec: W1: Duplicate explicit accessible-id detection and colliding roles reporting
    /// Example:
    unittest
    {
        import slint.compiler : Compiler;
        import std.algorithm.searching : canFind;

        auto compiler = new Compiler();
        auto built = compiler.buildFromSource(`
            import { Button } from "std-widgets.slint";
            export component DupIdWin inherits Window {
                width: 300px;
                height: 200px;
                VerticalLayout {
                    Text {
                        text: "First";
                        accessible-role: text;
                        accessible-id: "colliding-id";
                    }
                    Button {
                        text: "Second";
                        accessible-role: button;
                        accessible-id: "colliding-id";
                    }
                }
            }
        `, "");
        auto def = built.component("DupIdWin");
        assert(def !is null);
        auto win = def.create();
        auto inspector = new SlintUiInspector(win);

        bool caught = false;
        try
        {
            inspector.inspectTree();
        }
        catch (AgentError e)
        {
            caught = true;
            assert(e.kind == AgentError.Kind.duplicateAccessibleId);
            assert(e.code == "duplicate_accessible_id");
            assert(e.msg.canFind("colliding-id"), "Error message should contain colliding ID");
            assert(e.msg.canFind("text"), "Error message should contain first element role");
            assert(e.msg.canFind("button"), "Error message should contain second element role");
        }
        assert(caught, "inspectTree should throw AgentError.duplicateAccessibleId on duplicate accessible-id");
    }
}
