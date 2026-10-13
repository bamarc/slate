/// Data models for UI automation, inspection, snapshotting, and diagnostics.
///
/// Exact port of `slate_agent::model`: geometry, selectors, tree nodes,
/// screenshots, state, and action results — including the serde wire shapes
/// (externally-tagged selector enum, `skip_serializing_if` omissions),
/// re-expressed with `std.json`. Async-free: pure data, fully unit-tested.
module slate.agent.model;

import std.json : JSONValue;
import std.typecons : Nullable, nullable, Tuple;
import slate.utils.json : JsonSerializable, JsonKey, jsonIgnore, fromJsonValue, toJsonValue;

/// Current Unix time in milliseconds (0 when the clock is unreadable).
ulong currentTimeMs() nothrow
{
    import std.datetime.systime : Clock, SysTime;
    import std.datetime.date : DateTime;

    try
    {
        auto epoch = SysTime(DateTime(1970, 1, 1));
        return cast(ulong)(Clock.currTime() - epoch).total!"msecs";
    }
    catch (Throwable)
    {
        return 0;
    }
}

/// 2D point in logical window coordinates.
struct Point
{
    float x = 0;
    float y = 0;

    static immutable Point zero = Point(0, 0);

    this(float x, float y) @safe pure nothrow @nogc
    in
    {
        import std.math : isFinite;

        assert(isFinite(x), "Point x must be finite (not NaN or infinity)");
        assert(isFinite(y), "Point y must be finite (not NaN or infinity)");
    }
    do
    {
        this.x = x;
        this.y = y;
    }

    invariant
    {
        import std.math : isFinite;

        assert(isFinite(x), "Point x must be finite (not NaN or infinity)");
        assert(isFinite(y), "Point y must be finite (not NaN or infinity)");
    }

    static Point create(float x, float y) @safe pure nothrow @nogc
    in
    {
        import std.math : isFinite;

        assert(isFinite(x), "Point x must be finite (not NaN or infinity)");
        assert(isFinite(y), "Point y must be finite (not NaN or infinity)");
    }
    do
    {
        return Point(x, y);
    }

    void validate() const @safe pure nothrow @nogc
    {
        import std.math : isFinite;

        assert(isFinite(x), "Point x must be finite (not NaN or infinity)");
        assert(isFinite(y), "Point y must be finite (not NaN or infinity)");
    }

    float distanceTo(const Point other) const @safe pure nothrow @nogc
    in
    {
        import std.math : isFinite;

        assert(isFinite(other.x), "other Point x must be finite (not NaN or infinity)");
        assert(isFinite(other.y), "other Point y must be finite (not NaN or infinity)");
    }
    out (result)
    {
        import std.math : isFinite;

        assert(isFinite(result), "distanceTo result must be finite (not NaN or infinity)");
        assert(result >= 0.0f, "distanceTo result must be non-negative");
    }
    do
    {
        import std.math : sqrt;

        auto dx = x - other.x;
        auto dy = y - other.y;
        return sqrt(dx * dx + dy * dy);
    }

    string toString() const @safe pure
    out (result)
    {
        assert(result.length > 0, "Point string representation must not be empty");
    }
    do
    {
        import std.format : format;

        return format!"(%s, %s)"(x, y);
    }

    mixin JsonSerializable;
}

/// 2D bounding rectangle in logical window coordinates.
struct Rect
{
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;

    static immutable Rect zero = Rect(0, 0, 0, 0);

    this(float x, float y, float w, float h) @safe pure nothrow @nogc
    in
    {
        import std.math : isFinite;

        assert(isFinite(x), "Rect x must be finite (not NaN or infinity)");
        assert(isFinite(y), "Rect y must be finite (not NaN or infinity)");
        assert(isFinite(w), "Rect width must be finite (not NaN or infinity)");
        assert(isFinite(h), "Rect height must be finite (not NaN or infinity)");
        assert(w >= 0.0f, "Rect width must be non-negative");
        assert(h >= 0.0f, "Rect height must be non-negative");
    }
    do
    {
        this.x = x;
        this.y = y;
        this.width = w;
        this.height = h;
    }

    invariant
    {
        import std.math : isFinite;

        assert(isFinite(x), "Rect x must be finite (not NaN or infinity)");
        assert(isFinite(y), "Rect y must be finite (not NaN or infinity)");
        assert(isFinite(width), "Rect width must be finite (not NaN or infinity)");
        assert(isFinite(height), "Rect height must be finite (not NaN or infinity)");
        assert(width >= 0.0f, "Rect width must be non-negative");
        assert(height >= 0.0f, "Rect height must be non-negative");
    }

    static Rect create(float x, float y, float w, float h) @safe pure nothrow @nogc
    in
    {
        import std.math : isFinite;

        assert(isFinite(x), "Rect x must be finite (not NaN or infinity)");
        assert(isFinite(y), "Rect y must be finite (not NaN or infinity)");
        assert(isFinite(w), "Rect width must be finite (not NaN or infinity)");
        assert(isFinite(h), "Rect height must be finite (not NaN or infinity)");
        assert(w >= 0.0f, "Rect width must be non-negative");
        assert(h >= 0.0f, "Rect height must be non-negative");
    }
    do
    {
        return Rect(x, y, w, h);
    }

    void validate() const @safe pure nothrow @nogc
    {
        import std.math : isFinite;

        assert(isFinite(x), "Rect x must be finite (not NaN or infinity)");
        assert(isFinite(y), "Rect y must be finite (not NaN or infinity)");
        assert(isFinite(width), "Rect width must be finite (not NaN or infinity)");
        assert(isFinite(height), "Rect height must be finite (not NaN or infinity)");
        assert(width >= 0.0f, "Rect width must be non-negative");
        assert(height >= 0.0f, "Rect height must be non-negative");
    }

    Point origin() const @safe pure nothrow @nogc
    out (p)
    {
        import std.math : isFinite;

        assert(isFinite(p.x) && isFinite(p.y), "origin coordinates must be finite");
    }
    do
    {
        return Point(x, y);
    }

    Point center() const @safe pure nothrow @nogc
    out (p)
    {
        import std.math : isFinite;

        assert(isFinite(p.x) && isFinite(p.y), "center coordinates must be finite");
    }
    do
    {
        return Point(x + width / 2, y + height / 2);
    }

    bool contains(const Point p) const @safe pure nothrow @nogc
    in
    {
        import std.math : isFinite;

        assert(isFinite(p.x) && isFinite(p.y), "Point p coordinates must be finite");
    }
    do
    {
        return p.x >= x && p.x <= x + width && p.y >= y && p.y <= y + height;
    }

    bool intersects(const Rect other) const @safe pure nothrow @nogc
    in
    {
        import std.math : isFinite;

        assert(isFinite(other.x) && isFinite(other.y), "other Rect coordinates must be finite");
        assert(isFinite(other.width) && isFinite(other.height), "other Rect dimensions must be finite");
        assert(other.width >= 0.0f && other.height >= 0.0f, "other Rect dimensions must be non-negative");
    }
    do
    {
        return x < other.x + other.width && x + width > other.x
            && y < other.y + other.height && y + height > other.y;
    }

    float area() const @safe pure nothrow @nogc
    out (result)
    {
        import std.math : isFinite;

        assert(isFinite(result), "area result must be finite");
        assert(result >= 0.0f, "area result must be non-negative");
    }
    do
    {
        return width * height;
    }

    mixin JsonSerializable;
}

/// Mouse button for click actions.
enum MouseButton
{
    left,
    right,
    middle
}

string mouseButtonName(MouseButton b) @safe pure nothrow
{
    final switch (b)
    {
    case MouseButton.left:
        return "Left";
    case MouseButton.right:
        return "Right";
    case MouseButton.middle:
        return "Middle";
    }
}

MouseButton mouseButtonFromName(string name)
{
    switch (name)
    {
    case "Left":
        return MouseButton.left;
    case "Right":
        return MouseButton.right;
    case "Middle":
        return MouseButton.middle;
    default:
        throw new Exception("unknown mouse button: " ~ name);
    }
}

/// Target selector: id (`#x` / `id:x`), label (`text:` / `label:`),
/// coordinate (`x,y`), role (`role:`), defaulting to id.
struct ElementSelector
{
    enum Kind
    {
        id,
        label,
        coordinate,
        role
    }

    Kind kind = Kind.id;
    string text;
    Point point;

    static ElementSelector byId(string id) @safe pure nothrow
    {
        return ElementSelector(Kind.id, id);
    }

    static ElementSelector byLabel(string label) @safe pure nothrow
    {
        return ElementSelector(Kind.label, label);
    }

    static ElementSelector byCoordinate(Point p) @safe pure nothrow
    in
    {
        p.validate();
    }
    do
    {
        return ElementSelector(Kind.coordinate, null, p);
    }

    static ElementSelector byRole(string role) @safe pure nothrow
    {
        return ElementSelector(Kind.role, role);
    }

    /// Parse a target string with the Rust precedence: coordinates, `#` /
    /// `id:` prefixes, `text:` / `label:`, `role:`, else bare id.
    static ElementSelector parse(string target) @safe pure
    {
        import std.conv : to;
        import std.string : strip, indexOf, startsWith;

        auto t = target.strip();
        auto comma = t.indexOf(',');
        if (comma >= 0)
        {
            try
            {
                auto x = t[0 .. comma].strip().to!float;
                auto y = t[comma + 1 .. $].strip().to!float;
                return byCoordinate(Point(x, y));
            }
            catch (Exception)
            {
            }
        }
        if (t.startsWith("#"))
            return byId(t[1 .. $]);
        if (t.startsWith("id:"))
            return byId(t[3 .. $]);
        if (t.startsWith("text:"))
            return byLabel(t[5 .. $]);
        if (t.startsWith("label:"))
            return byLabel(t[6 .. $]);
        if (t.startsWith("role:"))
            return byRole(t[5 .. $]);
        return byId(t);
    }

    JSONValue toJson() const @safe
    {
        final switch (kind)
        {
        case Kind.id:
            return JSONValue(["Id": JSONValue(text)]);
        case Kind.label:
            return JSONValue(["Label": JSONValue(text)]);
        case Kind.coordinate:
            return JSONValue(["Coordinate": point.toJson()]);
        case Kind.role:
            return JSONValue(["Role": JSONValue(text)]);
        }
    }
}

private auto trustedUnconst(const UiElementNode n) @trusted pure nothrow @nogc
{
    return cast(UiElementNode) n;
}

pragma(inline, true)
private auto trustedObject()(ref const(JSONValue) jv) @trusted
{
    return jv.object;
}

/// Zero-allocation lazy pre-order traversal over a `UiElementNode` hierarchy.
struct ElementRange
{
    private struct Frame
    {
        UiElementNode node;
        size_t nextChild;
    }

    private Frame[256] _stack;
    private size_t _depth = 0;
    private UiElementNode _current = null;
    private bool _empty = true;

    this(const(UiElementNode) root) @safe pure nothrow @nogc
    {
        auto r = trustedUnconst(root);
        if (r !is null)
        {
            _stack[0] = Frame(r, 0);
            _depth = 1;
            _current = r;
            _empty = false;
        }
        else
        {
            _empty = true;
        }
    }

    bool empty() const @safe pure nothrow @nogc
    {
        return _empty;
    }

    UiElementNode front() @safe pure nothrow @nogc
    {
        return _current;
    }

    void popFront() @safe pure nothrow @nogc
    {
        if (_empty)
            return;

        while (_depth > 0)
        {
            if (_stack[_depth - 1].nextChild < _stack[_depth - 1].node.children.length)
            {
                auto nextChild = _stack[_depth - 1].node.children[_stack[_depth - 1].nextChild++];
                if (nextChild is null)
                    continue;

                if (_depth < _stack.length)
                {
                    _stack[_depth++] = Frame(nextChild, 0);
                    _current = nextChild;
                    return;
                }
            }
            else
            {
                _depth--;
            }
        }

        _depth = 0;
        _current = null;
        _empty = true;
    }

    ElementRange save() @safe pure nothrow @nogc
    {
        return this;
    }
}

/// A node in the hierarchical UI tree.
class UiElementNode
{
    string id;
    string typeName;
    Rect bounds;
    string label; // null = absent
    string role;
    string value; // null = absent
    bool enabled = true;
    bool focused;
    bool visible = true;
    UiElementNode[] children;
    JSONValue[string] properties;

    /// Zero-allocation lazy pre-order traversal of this subtree.
    ElementRange byElement() const @safe pure nothrow @nogc
    {
        return ElementRange(this);
    }

    /// Convenience opt-in facade for dot-syntax element lookup.
    UiFacade facade() const
    {
        return UiFacade(this);
    }

    /// Pre-order search by id (nodes with empty ids never match, like Rust).
    inout(UiElementNode) findById(string targetId) inout
    {
        if (id.length && id == targetId)
            return this;
        foreach (c; children)
            if (c !is null)
                if (auto f = c.findById(targetId))
                    return f;
        return null;
    }

    /// Pre-order search by accessible label or visible text.
    inout(UiElementNode) findByLabel(string targetLabel) inout
    {
        if (label !is null && label == targetLabel)
            return this;
        foreach (c; children)
            if (c !is null)
                if (auto f = c.findByLabel(targetLabel))
                    return f;
        return null;
    }

    /// Pre-order search by accessible role (case-insensitive).
    inout(UiElementNode) findByRole(string targetRole) inout
    {
        import std.uni : toLower;
        if (role.length && role.toLower() == targetRole.toLower())
            return this;
        foreach (c; children)
            if (c !is null)
                if (auto f = c.findByRole(targetRole))
                    return f;
        return null;
    }

    /// Hit-test: deepest visible child containing the point (reverse =
    /// top-most z-order first); invisible/outside subtrees yield null.
    inout(UiElementNode) findAtPoint(const Point point) inout
    {
        if (!visible || !bounds.contains(point))
            return null;
        foreach_reverse (c; children)
            if (c !is null)
                if (auto f = c.findAtPoint(point))
                    return f;
        return this;
    }

    /// All elements in this subtree, self first (pre-order).
    UiElementNode[] collectElements()
    {
        UiElementNode[] out_ = [this];
        foreach (c; children)
            if (c !is null)
                out_ ~= c.collectElements();
        return out_;
    }

    size_t countElements() const
    {
        size_t n = 1;
        foreach (c; children)
            if (c !is null)
                n += c.countElements();
        return n;
    }

    /// Deep copy (used to snapshot subtrees without aliasing live state).
    UiElementNode dup() const
    {
        auto n = new UiElementNode();
        n.id = id;
        n.typeName = typeName;
        n.bounds = bounds;
        n.label = label;
        n.role = role;
        n.value = value;
        n.enabled = enabled;
        n.focused = focused;
        n.visible = visible;
        foreach (c; children)
            if (c !is null)
                n.children ~= (cast(UiElementNode) c).dup();
        foreach (k, v; properties)
            n.properties[k] = cast(JSONValue) v;
        return n;
    }

    JSONValue toJson() const
    {
        JSONValue[string] o = [
            "id": JSONValue(id), "type_name": JSONValue(typeName),
            "bounds": bounds.toJson(), "role": JSONValue(role),
            "enabled": JSONValue(enabled), "focused": JSONValue(focused),
            "visible": JSONValue(visible),
        ];
        if (label !is null)
            o["label"] = JSONValue(label);
        if (value !is null)
            o["value"] = JSONValue(value);
        if (children.length)
        {
            JSONValue[] kids;
            foreach (c; children)
                if (c !is null)
                    kids ~= (cast(UiElementNode) c).toJson();
            o["children"] = JSONValue(kids);
        }
        if (properties.length)
        {
            JSONValue[string] props;
            foreach (k, v; properties)
                props[k] = v;
            o["properties"] = JSONValue(props);
        }
        return JSONValue(o);
    }

    static UiElementNode fromJson(const JSONValue j)
    {
        if (j.type != JSONType.object)
            return null;
        auto n = new UiElementNode();
        if (auto p = "id" in j)
            if (p.type == JSONType.string) n.id = p.str;
        if (auto p = "type_name" in j)
            if (p.type == JSONType.string) n.typeName = p.str;
        if (auto p = "bounds" in j)
            n.bounds = Rect.fromJson(*p);
        if (auto p = "label" in j)
            if (p.type == JSONType.string) n.label = p.str;
        if (auto p = "role" in j)
            if (p.type == JSONType.string) n.role = p.str;
        if (auto p = "value" in j)
            if (p.type == JSONType.string) n.value = p.str;
        if (auto p = "enabled" in j)
            n.enabled = fromJsonValue!bool(*p);
        if (auto p = "focused" in j)
            n.focused = fromJsonValue!bool(*p);
        if (auto p = "visible" in j)
            n.visible = fromJsonValue!bool(*p);
        if (auto p = "children" in j)
            if (p.type == JSONType.array)
                foreach (k; p.array)
                {
                    auto child = fromJson(k);
                    if (child !is null)
                        n.children ~= child;
                }
        if (auto p = "properties" in j)
            if (p.type == JSONType.object)
                foreach (k, v; trustedObject(*p))
                    n.properties[k] = cast(JSONValue) v;
        return n;
    }

    static UiElementNode fromJson(string jsonString)
    {
        import std.json : parseJSON;
        try return fromJson(parseJSON(jsonString));
        catch (Exception) return null;
    }
}

import std.json : JSONType;

/// Hierarchical UI tree snapshot of the application window.
struct UiTree
{
    UiElementNode root;
    ulong timestampMs;
    string windowTitle; // null = absent
    Nullable!Point windowSize; // null = absent

    static UiTree create(UiElementNode root)
    {
        return UiTree(root, currentTimeMs());
    }

    UiTree withWindowInfo(string title, float w, float h)
    {
        auto c = this;
        c.windowTitle = title;
        c.windowSize = nullable(Point(w, h));
        return c;
    }

    inout(UiElementNode) findById(string id) inout
    {
        return root ? root.findById(id) : null;
    }

    inout(UiElementNode) findByLabel(string label) inout
    {
        return root ? root.findByLabel(label) : null;
    }

    inout(UiElementNode) findByRole(string role) inout
    {
        return root ? root.findByRole(role) : null;
    }

    inout(UiElementNode) findAtPoint(const Point p) inout
    {
        return root ? root.findAtPoint(p) : null;
    }

    /// Generic selector dispatch (id falls back to label; role matches
    /// case-insensitively, like Rust).
    inout(UiElementNode) findBySelector(string selector) inout
    {
        if (root is null)
            return null;

        auto sel = ElementSelector.parse(selector);
        final switch (sel.kind)
        {
        case ElementSelector.Kind.id:
            auto f = root.findById(sel.text);
            return f is null ? root.findByLabel(sel.text) : f;
        case ElementSelector.Kind.label:
            return root.findByLabel(sel.text);
        case ElementSelector.Kind.coordinate:
            return root.findAtPoint(sel.point);
        case ElementSelector.Kind.role:
            return root.findByRole(sel.text);
        }
    }

    /// Zero-allocation lazy pre-order traversal of all elements in the tree.
    ElementRange byElement() const @safe pure nothrow @nogc
    {
        return ElementRange(root);
    }

    /// Convenience opt-in facade for dot-syntax element lookup.
    UiFacade facade() const
    {
        return UiFacade(this);
    }

    size_t countElements() const
    {
        return root ? root.countElements() : 0;
    }

    JSONValue toJson() const
    {
        JSONValue[string] o = [
            "root": root ? (cast(UiElementNode) root).toJson() : JSONValue(null),
            "timestamp_ms": JSONValue(timestampMs),
        ];
        if (windowTitle !is null)
            o["window_title"] = JSONValue(windowTitle);
        if (!windowSize.isNull)
            o["window_size"] = windowSize.get.toJson();
        return JSONValue(o);
    }

    static UiTree fromJson(const JSONValue j)
    {
        UiTree tree;
        if (j.type != JSONType.object)
            return tree;
        if (auto p = "root" in j)
            if (p.type == JSONType.object)
                tree.root = UiElementNode.fromJson(*p);
        if (auto p = "timestamp_ms" in j)
            tree.timestampMs = fromJsonValue!ulong(*p);
        if (auto p = "window_title" in j)
            if (p.type == JSONType.string)
                tree.windowTitle = p.str;
        if (auto p = "window_size" in j)
            if (p.type == JSONType.object)
                tree.windowSize = nullable(Point.fromJson(*p));
        return tree;
    }

    static UiTree fromJson(string jsonString)
    {
        import std.json : parseJSON;
        try return fromJson(parseJSON(jsonString));
        catch (Exception) return UiTree.init;
    }
}

/// Opt-in facade utilizing `opDispatch` for ergonomic dot-syntax element lookup.
struct UiFacade
{
    UiTree tree;

    this(UiTree tree)
    {
        this.tree = tree;
    }

    this(const UiTree tree)
    {
        this.tree = cast(UiTree) tree;
    }

    this(UiElementNode root)
    {
        this.tree = UiTree.create(root);
    }

    this(const(UiElementNode) root)
    {
        this.tree = UiTree.create(trustedUnconst(root));
    }

    template opDispatch(string name)
    {
        static if (__traits(hasMember, UiTree, name))
        {
            static if (is(typeof(__traits(getMember, tree, name)) == function))
            {
                auto ref opDispatch(Args...)(auto ref Args args) inout
                {
                    return __traits(getMember, tree, name)(args);
                }
            }
            else
            {
                ref auto opDispatch() inout
                {
                    return __traits(getMember, tree, name);
                }
            }
        }
        else
        {
            inout(UiElementNode) opDispatch() inout
            {
                if (tree.root is null)
                    return null;

                // 1. Exact ID match
                if (auto n = tree.root.findById(name))
                    return n;

                // 2. Snake_case to kebab-case (CTFE when possible)
                static if (__traits(compiles, () {
                    import std.string : indexOf;
                    return name.indexOf('_') >= 0;
                }()) && () {
                    import std.string : indexOf;
                    return name.indexOf('_') >= 0;
                }())
                {
                    enum kebab = () {
                        import std.array : replace;
                        return name.replace("_", "-");
                    }();
                    if (auto n = tree.root.findById(kebab))
                        return n;
                }

                // 3. Exact Label match
                if (auto n = tree.root.findByLabel(name))
                    return n;

                // 4. Label with kebab-case
                static if (__traits(compiles, kebab))
                {
                    if (auto n = tree.root.findByLabel(kebab))
                        return n;
                }

                // 5. Selector fallback
                return tree.findBySelector(name);
            }
        }
    }

    inout(UiElementNode) opIndex(string selector) inout
    {
        return tree.findBySelector(selector);
    }
}

/// Convenience factory for `UiFacade`.
UiFacade uiFacade(UiTree tree)
{
    return UiFacade(tree);
}

/// Convenience factory for `UiFacade`.
UiFacade uiFacade(const UiTree tree)
{
    return UiFacade(tree);
}

/// Convenience factory for `UiFacade`.
UiFacade uiFacade(UiElementNode root)
{
    return UiFacade(root);
}

/// Convenience factory for `UiFacade`.
UiFacade uiFacade(const(UiElementNode) root)
{
    return UiFacade(root);
}

/// Visual snapshot of the rendered window (PNG bytes).
struct Screenshot
{
    uint width;
    uint height;
    /// Image format (e.g. "png"). Named `formatName` because a `format`
    /// member would shadow `std.format` in method scopes; the JSON key
    /// stays `"format"` for wire fidelity.
    string formatName;
    ubyte[] data;
    ulong timestampMs;

    static Screenshot create(uint w, uint h, string fmt, ubyte[] bytes)
    {
        return Screenshot(w, h, fmt, bytes, currentTimeMs());
    }

    /// Base64 payload for MCP tool results.
    string toBase64() const
    {
        import std.base64 : Base64;

        return Base64.encode(data).idup;
    }

    string toBase64Png() const
    {
        return toBase64();
    }

    string dataUrl() const
    {
        import std.format : format;

        return format!"data:image/%s;base64,%s"(formatName, toBase64());
    }

    size_t byteLen() const @safe pure nothrow
    {
        return data.length;
    }
}

/// Diagnostic and performance metrics snapshot.
struct DiagnosticMetrics
{
    Nullable!float fps;
    @JsonKey("memory_bytes") Nullable!ulong memoryBytes;
    @JsonKey("event_loop_lag_ms") Nullable!double eventLoopLagMs;
    @JsonKey("active_background_tasks") Nullable!size_t activeBackgroundTasks;
    JSONValue[string] extra;

    mixin JsonSerializable;
}

/// High-level application state snapshot.
struct AppState
{
    string activeView;
    JSONValue[string] properties;
    ulong timestampMs;
    Nullable!DiagnosticMetrics diagnostics;

    static AppState create(string view)
    {
        AppState s;
        s.activeView = view;
        s.timestampMs = currentTimeMs();
        return s;
    }

    AppState withProperty(string key, JSONValue value)
    {
        auto c = this;
        c.properties[key] = value;
        return c;
    }

    const(JSONValue)* getProperty(string key) const
    {
        return key in properties;
    }

    AppState withDiagnostics(DiagnosticMetrics d)
    {
        auto c = this;
        c.diagnostics = nullable(d);
        return c;
    }

    JSONValue toJson() const
    {
        JSONValue[string] props;
        foreach (k, v; properties)
            props[k] = v;
        JSONValue[string] o = [
            "active_view": JSONValue(activeView),
            "properties": JSONValue(props),
            "timestamp_ms": JSONValue(timestampMs),
        ];
        if (!diagnostics.isNull)
            o["diagnostics"] = diagnostics.get.toJson();
        return JSONValue(o);
    }
}

/// Result of an element interaction command.
struct ActionResult
{
    bool success;
    string message;
    bool targetFound;
    ulong timestampMs;
    string elementId; // null = absent
    Nullable!JSONValue updatedValue;
    JSONValue[string] details;

    static ActionResult succeeded(string msg)
    {
        ActionResult r;
        r.success = true;
        r.message = msg;
        r.targetFound = true;
        r.timestampMs = currentTimeMs();
        return r;
    }

    static ActionResult failure(string msg)
    {
        ActionResult r;
        r.success = false;
        r.message = msg;
        r.targetFound = true;
        r.timestampMs = currentTimeMs();
        return r;
    }

    static ActionResult notFound(string target)
    {
        import std.format : format;

        ActionResult r;
        r.success = false;
        r.message = format!"Target element '%s' not found"(target);
        r.targetFound = false;
        r.timestampMs = currentTimeMs();
        return r;
    }

    ActionResult withElementId(string id)
    {
        auto c = this;
        c.elementId = id;
        return c;
    }

    ActionResult withValue(JSONValue v)
    {
        auto c = this;
        c.updatedValue = nullable(v);
        return c;
    }

    ActionResult withDetail(string key, JSONValue v)
    {
        auto c = this;
        c.details[key] = v;
        return c;
    }

    JSONValue toJson() const
    {
        JSONValue[string] det;
        foreach (k, v; details)
            det[k] = v;
        JSONValue[string] o = [
            "success": JSONValue(success), "message": JSONValue(message),
            "target_found": JSONValue(targetFound),
            "timestamp_ms": JSONValue(timestampMs),
        ];
        if (elementId !is null)
            o["element_id"] = JSONValue(elementId);
        if (!updatedValue.isNull)
            o["updated_value"] = updatedValue.get;
        if (details.length)
            o["details"] = JSONValue(det);
        return JSONValue(o);
    }
}

///
unittest
{
    import std.algorithm : canFind;
    import std.json : parseJSON;
    assert(Point.zero == Point(0, 0));
    assert(Point(0, 0).distanceTo(Point(3, 4)) == 5);
    assert(Point(1.5f, 2.0f).toString() == "(1.5, 2)");
    assert(Rect.zero.area == 0);
    assert(Rect(0, 0, 10, 10).center == Point(5, 5));
    assert(Rect(0, 0, 10, 10).contains(Point(10, 10)));
    assert(!Rect(0, 0, 10, 10).contains(Point(10.5f, 5)));
    assert(Rect(0, 0, 10, 10).intersects(Rect(5, 5, 10, 10)));
    assert(!Rect(0, 0, 10, 10).intersects(Rect(11, 0, 2, 2)));
    assert(Point.fromJson(Point(1, 2).toJson()) == Point(1, 2));
    assert(Rect.fromJson(Rect(1, 2, 3, 4).toJson()) == Rect(1, 2, 3, 4));

    // Buttons round-trip with Rust's exact variant names.
    assert(mouseButtonName(MouseButton.left) == "Left");
    assert(mouseButtonFromName("Middle") == MouseButton.middle);
    import std.exception : assertThrown;

    assertThrown(mouseButtonFromName("left"));

    // Selectors (Rust precedence).
    assert(ElementSelector.parse("10, 20").kind == ElementSelector.Kind.coordinate);
    assert(ElementSelector.parse("#submit").text == "submit");
    assert(ElementSelector.parse("id:x").text == "x");
    assert(ElementSelector.parse("text:Hello").kind == ElementSelector.Kind.label);
    assert(ElementSelector.parse("label:Hello").text == "Hello");
    assert(ElementSelector.parse("role:Button").kind == ElementSelector.Kind.role);
    assert(ElementSelector.parse("plain").kind == ElementSelector.Kind.id);
    assert(ElementSelector.parse("a,b").kind == ElementSelector.Kind.id); // not numbers

    // Tree search semantics.
    auto leaf = new UiElementNode();
    leaf.id = "ok-btn";
    leaf.typeName = "SlateButton";
    leaf.bounds = Rect(10, 10, 80, 30);
    leaf.label = "OK";
    leaf.role = "Button";
    auto hidden = new UiElementNode();
    hidden.id = "ghost";
    hidden.typeName = "Text";
    hidden.bounds = Rect(10, 10, 80, 30);
    hidden.visible = false;
    auto root = new UiElementNode();
    root.id = "root_window";
    root.typeName = "Window";
    root.bounds = Rect(0, 0, 800, 600);
    root.role = "Window";
    root.children = [leaf, hidden];
    auto tree = UiTree.create(root).withWindowInfo("Demo", 800, 600);

    assert(tree.findById("ok-btn") is leaf);
    assert(tree.findById("") is null);
    assert(tree.findByLabel("OK") is leaf);
    assert(tree.findAtPoint(Point(20, 20)) is leaf); // hidden loses hit-test
    assert(tree.findAtPoint(Point(700, 500)) is root);
    assert(tree.findAtPoint(Point(900, 900)) is null);
    assert(tree.findBySelector("#ok-btn") is leaf);
    assert(tree.findBySelector("OK") is leaf); // id fallback → label
    assert(tree.findBySelector("text:OK") is leaf);
    assert(tree.findBySelector("15,15") is leaf);
    assert(tree.findBySelector("role:button") is leaf); // case-insensitive
    assert(tree.findBySelector("#missing") is null);
    assert(tree.countElements() == 3);
    assert(root.collectElements().length == 3);

    // Tree JSON round-trip preserves searchability.
    auto tree2 = UiTree.create(UiElementNode.fromJson(root.toJson()));
    assert(tree2.findById("ok-btn").label == "OK");

    // Selector wire shape matches serde's externally-tagged enum.
    assert(ElementSelector.byId("x").toJson() == parseJSON(`{"Id":"x"}`));
    assert(ElementSelector.byCoordinate(Point(1, 2)).toJson()
        == parseJSON(`{"Coordinate":{"x":1,"y":2}}`));

    // Screenshots and data URLs.
    auto shot = Screenshot.create(2, 2, "png", [0, 1, 2, 3]);
    assert(shot.byteLen == 4);
    assert(shot.formatName == "png");
    assert(shot.dataUrl().canFind("data:image/png;base64,"));
    assert(shot.toBase64Png() == shot.toBase64());

    // State and results.
    auto st = AppState.create("Compute").withProperty("k", JSONValue(1));
    assert(st.getProperty("k") !is null && st.getProperty("missing") is null);
    assert(st.withDiagnostics(DiagnosticMetrics()).diagnostics.get.toJson().object.length == 0);
    auto ok = ActionResult.succeeded("done").withElementId("b").withDetail("t", JSONValue(1));
    assert(ok.success && ok.targetFound && ok.elementId == "b");
    assert(ActionResult.notFound("zzz").targetFound == false);
    auto j = ActionResult.failure("bad").toJson();
    assert(j["success"].get!bool == false && ("element_id" in j) is null);

    // Range traversal (byElement) matches collectElements order without heap arrays
    UiElementNode[] rangeNodes;
    foreach (e; tree.byElement)
        rangeNodes ~= e;
    assert(rangeNodes == root.collectElements());

    UiElementNode[] rootRangeNodes;
    foreach (e; root.byElement)
        rootRangeNodes ~= e;
    assert(rootRangeNodes == root.collectElements());

    // byElement @nogc pure nothrow check
    void testRangeNogc(UiTree t) @safe pure nothrow @nogc
    {
        auto r = t.byElement;
        size_t count = 0;
        while (!r.empty)
        {
            auto node = r.front;
            count++;
            r.popFront();
        }
        assert(count == 3);
    }
    testRangeNogc(tree);

    // UiFacade dot-syntax element lookup
    auto ui = tree.facade;
    assert(ui.ok_btn is leaf); // snake_case maps to kebab-case id "ok-btn"
    assert(ui.root_window is root); // exact id "root_window"
    assert(ui.OK is leaf); // label match
    assert(ui.missing_element is null); // not found yields null
    assert(ui["#ok-btn"] is leaf); // opIndex selector
    assert(ui["text:OK"] is leaf);
    assert(ui.windowTitle == "Demo"); // field forwarding
    assert(ui.findById("ok-btn") is leaf); // method forwarding

    auto nodeUi = root.facade;
    assert(nodeUi.ok_btn is leaf);

    // DiagnosticMetrics round-trip with @JsonKey remapping and Nullable omissions
    DiagnosticMetrics dm;
    dm.fps = nullable(60.0f);
    dm.memoryBytes = nullable(1048576UL);
    dm.eventLoopLagMs = nullable(1.5);
    dm.activeBackgroundTasks = nullable(cast(size_t) 2);
    dm.extra["gc_pause_ms"] = JSONValue(0.4);

    auto dmj = dm.toJson();
    assert(dmj["fps"].floating == 60.0);
    assert(dmj["memory_bytes"].uinteger == 1048576);
    assert(dmj["event_loop_lag_ms"].floating == 1.5);
    assert(dmj["active_background_tasks"].uinteger == 2);
    assert(dmj["extra"]["gc_pause_ms"].floating == 0.4);

    auto dmRoundTrip = DiagnosticMetrics.fromJson(dmj);
    assert(!dmRoundTrip.fps.isNull && dmRoundTrip.fps.get == 60.0f);
    assert(!dmRoundTrip.memoryBytes.isNull && dmRoundTrip.memoryBytes.get == 1048576);
    assert(!dmRoundTrip.eventLoopLagMs.isNull && dmRoundTrip.eventLoopLagMs.get == 1.5);
    assert(!dmRoundTrip.activeBackgroundTasks.isNull && dmRoundTrip.activeBackgroundTasks.get == 2);
    assert(dmRoundTrip.extra["gc_pause_ms"].floating == 0.4);

    // Edge cases: ElementRange on null root and single-leaf node
    auto nullRange = ElementRange(null);
    assert(nullRange.empty);
    auto soloNode = new UiElementNode();
    soloNode.id = "solo";
    auto soloRange = soloNode.byElement;
    assert(!soloRange.empty && soloRange.front.id == "solo");
    soloRange.popFront();
    assert(soloRange.empty);

    // Edge cases: UiFacade on null root
    auto emptyUi = UiFacade(UiTree(null));
    assert(emptyUi.any_element is null);
    assert(emptyUi["#missing"] is null);

    // Edge cases: Point and Rect round-trip with zero and negative coordinates
    assert(Point.fromJson(Point.zero.toJson()) == Point.zero);
    assert(Point.fromJson(Point(-10.5f, -20.5f).toJson()) == Point(-10.5f, -20.5f));
    assert(Rect.fromJson(Rect.zero.toJson()) == Rect.zero);
    assert(Rect.fromJson(Rect(-5, -5, 10, 10).toJson()) == Rect(-5, -5, 10, 10));

    // Const UiFacade dot-syntax, index, countElements, and byElement lookup
    const constUi = tree.facade;
    assert(constUi.ok_btn is leaf);
    assert(constUi["#ok-btn"] is leaf);
    assert(constUi.OK is leaf);
    assert(constUi.windowTitle == "Demo");
    assert(constUi.countElements() == 3);
    size_t constRangeCount = 0;
    foreach (e; constUi.byElement)
        constRangeCount++;
    assert(constRangeCount == 3);

    // UiTree and UiElementNode findByRole
    assert(tree.findByRole("button") is leaf);
    assert(root.findByRole("button") is leaf);
    assert(tree.findByRole("nonexistent") is null);

    // UiTree(null) toJson does not crash and produces null root
    auto emptyTree = UiTree(null);
    auto emptyTreeJson = emptyTree.toJson();
    assert(emptyTreeJson["root"].type == JSONType.null_);
    auto treeRoundTrip = UiTree.fromJson(tree.toJson());
    assert(treeRoundTrip.findById("ok-btn") !is null);
    assert(treeRoundTrip.findById("ok-btn").label == "OK");

    // UiElementNode fromJson on incomplete JSON recovers safely
    auto partialNodeJson = parseJSON(`{"id":"p1","type_name":"Panel"}`);
    auto partialNode = UiElementNode.fromJson(partialNodeJson);
    assert(partialNode.id == "p1");
    assert(partialNode.typeName == "Panel");
    assert(partialNode.enabled == true && partialNode.visible == true);
    assert(partialNode.bounds == Rect.zero);

    // Default Point and Rect zero initialization and stringify
    Point pDef;
    assert(pDef.x == 0 && pDef.y == 0);
    assert(pDef.toJson().toString().length > 0);
    Rect rDef;
    assert(rDef.x == 0 && rDef.width == 0);
    assert(rDef.toJson().toString().length > 0);

    // Deep tree traversal (> 128 levels) completely traversed without truncation
    auto deepRoot = new UiElementNode();
    deepRoot.id = "deep_0";
    auto currDeep = deepRoot;
    foreach (i; 1 .. 140)
    {
        import std.conv : to;
        auto nextDeep = new UiElementNode();
        nextDeep.id = "deep_" ~ i.to!string;
        currDeep.children = [nextDeep];
        currDeep = nextDeep;
    }
    size_t deepCount = 0;
    string lastDeepId;
    foreach (e; deepRoot.byElement)
    {
        deepCount++;
        lastDeepId = e.id;
    }
    assert(deepCount == 140);
    assert(lastDeepId == "deep_139");

    // ElementRange safely skips null children without crashing or yielding null
    auto nullChildRoot = new UiElementNode();
    nullChildRoot.id = "r";
    auto c1 = new UiElementNode();
    c1.id = "c1";
    auto c2 = new UiElementNode();
    c2.id = "c2";
    nullChildRoot.children = [cast(UiElementNode) null, c1, cast(UiElementNode) null, c2];
    string[] visitedIds;
    foreach (e; nullChildRoot.byElement)
        visitedIds ~= e.id;
    assert(visitedIds == ["r", "c1", "c2"]);

    // findByLabel on null or empty search does not match elements with absent label
    auto noLabelNode = new UiElementNode();
    noLabelNode.id = "no_label";
    assert(noLabelNode.findByLabel("") is null);
    assert(noLabelNode.findByLabel(null) is null);

    // UiElementNode fromJson on null/invalid JSON returns null
    assert(UiElementNode.fromJson(JSONValue(null)) is null);
    assert(UiElementNode.fromJson(JSONValue(42)) is null);
    assert(UiElementNode.fromJson("not json") is null);

    // toJsonValue on null UiElementNode returns JSON null
    UiElementNode nullNodeRef = null;
    assert(toJsonValue(nullNodeRef).type == JSONType.null_);

    // Native Design-by-Contract: Point and Rect invariants
    import core.exception : AssertError;

    // Point invariants: NaN coordinates rejected on construction
    assertThrown!AssertError(Point(float.nan, 0));
    assertThrown!AssertError(Point(0, float.nan));
    assertThrown!AssertError(Point(float.nan, float.nan));

    // Point invariants: NaN coordinates rejected when calling member functions after mutation
    Point pMut = Point(10, 20);
    pMut.validate(); // valid
    pMut.x = float.nan;
    assertThrown!AssertError(pMut.validate());
    assertThrown!AssertError(pMut.distanceTo(Point(0, 0)));
    assertThrown!AssertError(pMut.toString());

    Point pMutY = Point(10, 20);
    pMutY.y = float.nan;
    assertThrown!AssertError(pMutY.validate());
    assertThrown!AssertError(pMutY.distanceTo(Point(0, 0)));

    // Rect invariants: negative dimensions and NaN rejected on construction
    assertThrown!AssertError(Rect(0, 0, -1, 10));
    assertThrown!AssertError(Rect(0, 0, 10, -1));
    assertThrown!AssertError(Rect(0, 0, -5, -5));
    assertThrown!AssertError(Rect(float.nan, 0, 10, 10));
    assertThrown!AssertError(Rect(0, float.nan, 10, 10));
    assertThrown!AssertError(Rect(0, 0, float.nan, 10));
    assertThrown!AssertError(Rect(0, 0, 10, float.nan));

    // Rect invariants: negative dimensions and NaN rejected when calling member functions after mutation
    Rect rMut = Rect(0, 0, 100, 50);
    rMut.validate(); // valid
    assert(rMut.area() == 5000.0f);

    rMut.width = -1.0f;
    assertThrown!AssertError(rMut.validate());
    assertThrown!AssertError(rMut.area());
    assertThrown!AssertError(rMut.origin());
    assertThrown!AssertError(rMut.center());
    assertThrown!AssertError(rMut.contains(Point(10, 10)));
    assertThrown!AssertError(rMut.intersects(Rect(0, 0, 10, 10)));

    Rect rMutH = Rect(0, 0, 100, 50);
    rMutH.height = -0.5f;
    assertThrown!AssertError(rMutH.validate());
    assertThrown!AssertError(rMutH.area());
    assertThrown!AssertError(rMutH.center());

    Rect rMutNan = Rect(0, 0, 100, 50);
    rMutNan.x = float.nan;
    assertThrown!AssertError(rMutNan.validate());
    assertThrown!AssertError(rMutNan.area());

    // Point and Rect create() factory preconditions
    assertThrown!AssertError(Point.create(float.nan, 0));
    assertThrown!AssertError(Point.create(0, float.nan));
    assertThrown!AssertError(Point.create(float.infinity, 0));
    assertThrown!AssertError(Point.create(0, -float.infinity));
    assertThrown!AssertError(Rect.create(0, 0, -1, 10));
    assertThrown!AssertError(Rect.create(0, 0, 10, -1));
    assertThrown!AssertError(Rect.create(float.nan, 0, 10, 10));
    assertThrown!AssertError(Rect.create(float.infinity, 0, 10, 10));
    assertThrown!AssertError(Rect.create(0, 0, float.infinity, 10));
    assertThrown!AssertError(Rect.create(0, 0, 10, float.infinity));

    // Preconditions on method calls with invalid external parameters
    auto validRect = Rect(0, 0, 100, 50);
    assertThrown!AssertError(validRect.contains(Point(float.nan, 20)));
    assertThrown!AssertError(validRect.contains(Point(20, float.nan)));
    assertThrown!AssertError(validRect.contains(Point(float.infinity, 20)));
    assertThrown!AssertError(validRect.intersects(Rect(0, 0, -10, 20)));
    assertThrown!AssertError(validRect.intersects(Rect(0, 0, 10, -20)));
    assertThrown!AssertError(validRect.intersects(Rect(float.nan, 0, 10, 20)));
    assertThrown!AssertError(validRect.intersects(Rect(float.infinity, 0, 10, 20)));

    auto validPoint = Point(10, 20);
    assertThrown!AssertError(validPoint.distanceTo(Point(float.nan, 0)));
    assertThrown!AssertError(validPoint.distanceTo(Point(0, float.nan)));
    assertThrown!AssertError(validPoint.distanceTo(Point(float.infinity, 0)));

    // Deserialization contract validation: invalid JSON bounds or points actively trigger AssertError
    assertThrown!AssertError(Rect.fromJson(parseJSON(`{"x": 0, "y": 0, "width": -5, "height": 10}`)));
    assertThrown!AssertError(Rect.fromJson(parseJSON(`{"x": 0, "y": 0, "width": 10, "height": -5}`)));
    assertThrown!AssertError(Rect.fromJson(JSONValue(["x": JSONValue(double.nan), "y": JSONValue(0.0), "width": JSONValue(10.0), "height": JSONValue(10.0)])));
    assertThrown!AssertError(Point.fromJson(JSONValue(["x": JSONValue(double.nan), "y": JSONValue(0.0)])));
    assertThrown!AssertError(Point.fromJson(JSONValue(["x": JSONValue(0.0), "y": JSONValue(double.nan)])));

    // ElementSelector byCoordinate contract validation
    assertThrown!AssertError(ElementSelector.byCoordinate(Point(float.nan, 0)));
}
