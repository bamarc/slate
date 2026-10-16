/// Geometric primitives, selectors, and range traversals for UI automation.
module slate.agent.geometry;

import std.json : JSONValue;
import slate.utils.json : JsonSerializable;
import slate.agent.model : UiElementNode;

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
        assert(isFinite(other.width) && isFinite(other.height),
                "other Rect dimensions must be finite");
        assert(other.width >= 0.0f && other.height >= 0.0f,
                "other Rect dimensions must be non-negative");
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

package auto trustedUnconst(const UiElementNode n) @trusted pure nothrow @nogc
{
    return cast(UiElementNode) n;
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

// Spec: Geometry models (Point, Rect, MouseButton, ElementSelector) and JSON serialization
/// Example:
unittest
{
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
}
