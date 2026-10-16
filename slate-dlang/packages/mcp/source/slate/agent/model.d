/// Data models for UI automation, inspection, snapshotting, and diagnostics.
///
/// Exact port of `slate_agent::model`: geometry, selectors, tree nodes,
/// screenshots, state, and action results — including the serde wire shapes
/// (externally-tagged selector enum, `skip_serializing_if` omissions),
/// re-expressed with `std.json`. Async-free: pure data, fully unit-tested.
module slate.agent.model;

public import slate.agent.geometry;

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

pragma(inline, true) private auto trustedObject()(ref const(JSONValue) jv) @trusted
{
    return jv.object;
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

    /// Accessible description from properties (empty string when absent).
    string description() const @safe pure nothrow
    {
        import std.json : JSONType;

        if (auto p = "description" in properties)
        {
            if (p.type == JSONType.string)
            {
                try
                    return p.str;
                catch (Exception)
                    return "";
            }
        }
        return "";
    }

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
            if (p.type == JSONType.string)
                n.id = p.str;
        if (auto p = "type_name" in j)
            if (p.type == JSONType.string)
                n.typeName = p.str;
        if (auto p = "bounds" in j)
            n.bounds = Rect.fromJson(*p);
        if (auto p = "label" in j)
            if (p.type == JSONType.string)
                n.label = p.str;
        if (auto p = "role" in j)
            if (p.type == JSONType.string)
                n.role = p.str;
        if (auto p = "value" in j)
            if (p.type == JSONType.string)
                n.value = p.str;
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

        try
            return fromJson(parseJSON(jsonString));
        catch (Exception)
            return null;
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

        try
            return fromJson(parseJSON(jsonString));
        catch (Exception)
            return UiTree.init;
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
            "active_view": JSONValue(activeView), "properties": JSONValue(props),
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

// Spec: UI element tree models and inspection
/// Example:
unittest
{
    auto leaf = new UiElementNode();
    leaf.id = "ok-btn";
    leaf.label = "OK";
    leaf.role = "Button";
    auto root = new UiElementNode();
    root.id = "root";
    root.children = [leaf];
    auto tree = UiTree.create(root);
    assert(tree.findById("ok-btn") is leaf);
}
