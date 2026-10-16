/// Dynamically-typed Slint values and their D-side type mappings.
///
/// Mirrors `slint_interpreter::Value` / `ValueType` (upstream
/// `internal/interpreter/...`) and the conversion layers of both official
/// bindings: `api/node/rust/interpreter/value.rs` (`to_js_unknown` /
/// `to_value`) and `api/python/slint/value.rs` (`SlintToPyValue`).
///
/// Type mapping (same table as the Node README and the Python docs):
///
/// | `.slint` type | D type |
/// |---|---|
/// | `int`, `float`, `length`, `duration`, `angle`, ... | `double` (`number`) |
/// | `string` | `string` (`text`) |
/// | `bool` | `bool` (`boolean`) |
/// | `color` | `Color` |
/// | `brush` | `Brush` |
/// | `image` | `ImageData` (pixel payload lives in native memory) |
/// | `styled-text` | `StyledText` |
/// | `data-transfer` | `DataTransfer` (opaque native handle) |
/// | structure | `SlintStruct` (`Value[string]`) |
/// | array | `Model!T` (`slint.model`) |
/// | enumeration | `string` (variant name) or `EnumValue` |
/// | `keys` | `Keys` |
module slint.value;

/// Discriminant of a dynamically-typed Slint value.
///
/// Same variants as `slint_interpreter::ValueType`, plus `Enumeration`,
/// `StyledText`, `Keys`, and `DataTransfer`, which the interpreter's
/// `ValueType` folds into `Void` but both official bindings surface
/// explicitly (`JsValueType`, `PyValueType`).
enum ValueType
{
    Void,
    Number,
    String,
    Bool,
    Model,
    Struct,
    Brush,
    Image,
    Enumeration,
    StyledText,
    Keys,
    DataTransfer,
}

/// 8-bit RGBA color, mirroring `slint_interpreter::Color`.
///
/// Node exposes this as `RgbaColor`; Python as `Color`. Both names exist
/// here with `Color` canonical.
struct Color
{
    ubyte red;
    ubyte green;
    ubyte blue;
    ubyte alpha = 255;

    static Color fromRgb(ubyte r, ubyte g, ubyte b) @safe pure nothrow @nogc
    {
        return Color(r, g, b, 255);
    }

    static Color fromArgb(ubyte a, ubyte r, ubyte g, ubyte b) @safe pure nothrow @nogc
    {
        return Color(r, g, b, a);
    }

    /// Packed `0xAARRGGBB`, matching `Color::as_argb_u32` byte order.
    uint toArgbU32() const @safe pure nothrow @nogc
    {
        return (cast(uint) alpha << 24) | (cast(uint) red << 16) | (cast(uint) green << 8) | blue;
    }

    static Color fromArgbU32(uint argb) @safe pure nothrow @nogc
    {
        return Color(cast(ubyte)(argb >> 16), cast(ubyte)(argb >> 8),
                cast(ubyte) argb, cast(ubyte)(argb >> 24));
    }

    bool opEquals(Color rhs) const @safe pure nothrow @nogc
    {
        return red == rhs.red && green == rhs.green && blue == rhs.blue && alpha == rhs.alpha;
    }
}

/// Node-compat alias (`RgbaColor` is the name used in `slint-ui`).
alias RgbaColor = Color;

/// How a shape or text fill is painted. Mirrors `slint_interpreter::Brush`.
struct Brush
{
    enum Kind
    {
        Transparent,
        Solid,
        LinearGradient,
    }

    Kind kind = Kind.Transparent;
    Color color;

    static Brush transparent() @safe pure nothrow @nogc
    {
        return Brush(Kind.Transparent, Color(0, 0, 0, 0));
    }

    static Brush solid(Color c) @safe pure nothrow @nogc
    {
        return Brush(Kind.Solid, c);
    }

    bool isTransparent() const @safe pure nothrow @nogc
    {
        return kind == Kind.Transparent;
    }
}

/// Position in logical pixels. Mirrors `slint_interpreter::LogicalPosition`.
struct LogicalPosition
{
    float x;
    float y;
}

/// Size in logical pixels. Mirrors `slint_interpreter::LogicalSize`.
struct LogicalSize
{
    float width;
    float height;
}

/// Image payload descriptor. Pixel bytes live in native memory behind
/// `handle` (like Node's `ImageData` / Python's `Image`); `path` is set
/// when the image was loaded from disk.
struct ImageData
{
    string path;
    uint width;
    uint height;
    const(ubyte)[] data;
    void* handle;
}

/// Rich text value. Mirrors `slint_interpreter::StyledText`.
struct StyledText
{
    string text;
    bool markdown;

    static StyledText fromPlainText(string t) @safe pure nothrow
    {
        return StyledText(t, false);
    }

    static StyledText fromMarkdown(string t) @safe pure nothrow
    {
        return StyledText(t, true);
    }
}

/// Keyboard shortcut value. Mirrors `slint_interpreter::Keys`.
struct Keys
{
    string text;
}

/// Drag-and-drop / clipboard payload. Payload details stay behind the
/// native `handle` (cf. `SlintDataTransfer` in Node, `PyDataTransfer`
/// in Python); `userData` anchors D-side state.
struct DataTransfer
{
    void* handle;
    string userData;
}

/// Enumerated value: enum name plus selected variant, e.g.
/// `EnumValue("Position", "top")`. Both official bindings transfer enums
/// as bare strings; the name is kept so D can validate against
/// `ComponentDefinition` metadata.
struct EnumValue
{
    string enumName;
    string value;
}

/// A Slint struct value: field name (dashes normalized to underscores,
/// as in both official bindings) to field value.
alias SlintStruct = Value[string];

/// Dynamically-typed Slint value.
///
/// Scalar payloads (`number`, `text`, `boolean`, `color`, `brush`, ...)
/// are stored inline in D memory. Native-backed payloads (models,
/// structs, images, styled text, keys, data transfer) are referenced via
/// `handle` until the bridge materializes them; `structFields` carries a
/// materialized struct when the compiler metadata is available in-D.
struct Value
{
    ValueType type = ValueType.Void;
    double number;
    string text;
    bool boolean;
    Color color;
    Brush brush;
    ImageData image;
    StyledText styledText;
    Keys keys;
    DataTransfer dataTransfer;
    EnumValue enumValue;
    SlintStruct structFields;
    void* handle;

    static Value nil() @safe pure nothrow
    {
        return Value(ValueType.Void);
    }

    static Value of(double v) @safe pure nothrow
    {
        Value r;
        r.type = ValueType.Number;
        r.number = v;
        return r;
    }

    static Value of(long v) @safe pure nothrow
    {
        return Value.of(cast(double) v);
    }

    static Value of(string v) @safe pure nothrow
    {
        Value r;
        r.type = ValueType.String;
        r.text = v;
        return r;
    }

    static Value of(bool v) @safe pure nothrow
    {
        Value r;
        r.type = ValueType.Bool;
        r.boolean = v;
        return r;
    }

    static Value of(Color v) @safe pure nothrow
    {
        Value r;
        r.type = ValueType.Brush;
        r.brush = Brush.solid(v);
        r.color = v;
        return r;
    }

    static Value of(Brush v) @safe pure nothrow
    {
        Value r;
        r.type = ValueType.Brush;
        r.brush = v;
        if (v.kind == Brush.Kind.Solid)
            r.color = v.color;
        return r;
    }

    static Value of(EnumValue v) @safe pure nothrow
    {
        Value r;
        r.type = ValueType.Enumeration;
        r.enumValue = v;
        return r;
    }

    static Value of(SlintStruct v) @safe pure nothrow
    {
        Value r;
        r.type = ValueType.Struct;
        r.structFields = v;
        return r;
    }

    bool isVoid() const @safe pure nothrow @nogc
    {
        return type == ValueType.Void;
    }
}

import slint.capi : SlintValue, SlintTag;

/// Convert a D `Color` to its FFI form.
SlintValue toSlintValue(Color c) @safe pure nothrow @nogc
{
    SlintValue r;
    r.tag = SlintTag.Brush;
    r.brushKind = 1;
    r.colorArgb = c.toArgbU32();
    return r;
}

/// Convert a D `Brush` to its FFI form.
SlintValue toSlintValue(Brush b) @safe pure nothrow @nogc
{
    SlintValue r;
    r.tag = SlintTag.Brush;
    if (b.isTransparent())
    {
        r.brushKind = 0;
        r.colorArgb = 0;
    }
    else
    {
        r.brushKind = 1;
        r.colorArgb = b.color.toArgbU32();
    }
    return r;
}

/// Convert an `EnumValue` to its FFI form.
SlintValue toSlintValue(EnumValue e) @trusted pure nothrow @nogc
{
    SlintValue r;
    r.tag = SlintTag.Enumeration;
    r.textPtr = e.value.ptr;
    r.textLen = e.value.length;
    return r;
}

/// Convert a `SlintStruct` to its FFI form.
SlintValue toSlintValue(SlintStruct s) @system nothrow
{
    return toSlintValue(Value.of(s));
}

version (SlintNative)
{
    import slint.model : Model, ArrayModel;

    /// Convert a `Model!T` to its FFI form.
    SlintValue toSlintValue(T)(Model!T model) @system nothrow
    {
        SlintValue r;
        r.tag = SlintTag.Model;
        if (model is null)
            return r;

        auto arr = cast(ArrayModel!T) model;
        if (arr !is null && arr.nativeHandle !is null)
        {
            r.handle = cast(void*) arr.nativeHandle;
            r.owned = 0;
            return r;
        }

        import slint.capi : slint_model_new_vec, slint_model_vec_push,
            slint_model_free, SlintModelRaw;

        try
        {
            auto raw = slint_model_new_vec();
            scope (failure)
                slint_model_free(raw);
            size_t n = model.rowCount();
            for (size_t i = 0; i < n; ++i)
            {
                SlintValue itemVal;
                static if (is(T == int) || is(T == double) || is(T == float)
                        || is(T == long) || is(T == uint) || is(T == ulong))
                {
                    itemVal.tag = SlintTag.Number;
                    itemVal.number = cast(double) model.rowData(i);
                }
                else static if (is(T == string))
                {
                    string s = model.rowData(i);
                    itemVal.tag = SlintTag.String;
                    itemVal.textPtr = s.ptr;
                    itemVal.textLen = s.length;
                }
                else static if (is(T == bool))
                {
                    itemVal.tag = SlintTag.Bool;
                    itemVal.boolean = model.rowData(i) ? 1 : 0;
                }
                else static if (is(T == Color) || is(T == Brush)
                        || is(T == SlintStruct) || is(T == Value))
                {
                    itemVal = toSlintValue(model.rowData(i));
                }
                else static if (is(T == struct))
                {
                    itemVal = toSlintValue(Value.of(toSlintStruct(model.rowData(i))));
                }
                scope (exit)
                    freeSlint(&itemVal);
                slint_model_vec_push(raw, &itemVal);
            }
            r.handle = cast(void*) raw;
            r.owned = 1;
        }
        catch (Throwable)
        {
        }
        return r;
    }

    /// Convert a D array `T[]` to its FFI model form.
    SlintValue toSlintValue(T)(T[] items) @system nothrow
    {
        SlintValue r;
        r.tag = SlintTag.Model;
        import slint.capi : slint_model_new_vec, slint_model_vec_push, slint_model_free;

        try
        {
            auto raw = slint_model_new_vec();
            scope (failure)
                slint_model_free(raw);
            foreach (ref item; items)
            {
                SlintValue itemVal;
                static if (is(T == int) || is(T == double) || is(T == float)
                        || is(T == long) || is(T == uint) || is(T == ulong))
                {
                    itemVal.tag = SlintTag.Number;
                    itemVal.number = cast(double) item;
                }
                else static if (is(T == string))
                {
                    itemVal.tag = SlintTag.String;
                    itemVal.textPtr = item.ptr;
                    itemVal.textLen = item.length;
                }
                else static if (is(T == bool))
                {
                    itemVal.tag = SlintTag.Bool;
                    itemVal.boolean = item ? 1 : 0;
                }
                else static if (is(T == Color) || is(T == Brush)
                        || is(T == SlintStruct) || is(T == Value))
                {
                    itemVal = toSlintValue(item);
                }
                else static if (is(T == struct))
                {
                    itemVal = toSlintValue(Value.of(toSlintStruct(item)));
                }
                scope (exit)
                    freeSlint(&itemVal);
                slint_model_vec_push(raw, &itemVal);
            }
            r.handle = cast(void*) raw;
            r.owned = 1;
        }
        catch (Throwable)
        {
        }
        return r;
    }
}

/// Convert a D `Value` to its FFI form. String payloads borrow D memory
/// (`owned == 0`): the bridge copies them synchronously, so temporaries
/// are safe for the duration of the call.
SlintValue toSlintValue(const Value v) @system nothrow
{
    SlintValue r;
    final switch (v.type)
    {
    case ValueType.Void:
        r.tag = SlintTag.Void;
        break;
    case ValueType.Number:
        r.tag = SlintTag.Number;
        r.number = v.number;
        break;
    case ValueType.String:
        r.tag = SlintTag.String;
        r.textPtr = v.text.ptr;
        r.textLen = v.text.length;
        break;
    case ValueType.Bool:
        r.tag = SlintTag.Bool;
        r.boolean = v.boolean ? 1 : 0;
        break;
    case ValueType.Brush:
        r.tag = SlintTag.Brush;
        if (v.brush.isTransparent())
        {
            r.brushKind = 0;
            r.colorArgb = 0;
        }
        else
        {
            r.brushKind = 1;
            Color c = (v.brush.kind == Brush.Kind.Solid ? v.brush.color : v.color);
            r.colorArgb = c.toArgbU32();
        }
        break;
    case ValueType.Enumeration:
        r.tag = SlintTag.Enumeration;
        r.textPtr = v.enumValue.value.ptr;
        r.textLen = v.enumValue.value.length;
        break;
    case ValueType.Struct:
        r.tag = SlintTag.Struct;
        version (SlintNative)
        {
            if (v.handle !is null)
            {
                r.handle = cast(void*) v.handle;
            }
            else
            {
                import slint.capi : slint_struct_new, slint_struct_set_field,
                    slint_struct_free, SlintStructRaw;
                import std.string : toStringz;

                try
                {
                    auto raw = slint_struct_new();
                    scope (failure)
                        slint_struct_free(raw);
                    foreach (name, val; v.structFields)
                    {
                        SlintValue child = toSlintValue(val);
                        scope (exit)
                            freeSlint(&child);
                        slint_struct_set_field(raw, name.toStringz, &child);
                    }
                    r.handle = raw;
                    r.owned = 1;
                }
                catch (Throwable)
                {
                }
            }
        }
        else
        {
            r.handle = cast(void*) v.handle;
        }
        break;
    case ValueType.Model:
        r.tag = SlintTag.Model;
        r.handle = cast(void*) v.handle;
        break;
    case ValueType.Image:
    case ValueType.StyledText:
    case ValueType.Keys:
    case ValueType.DataTransfer:
        r.tag = SlintTag.Void;
        break;
    }
    return r;
}

/// Backward compatibility alias
alias toSlint = toSlintValue;

/// Convert an FFI payload to a D `Value`, copying string bytes. Never
/// frees: pair with `scope(exit) freeSlint(&v)` when the payload may be
/// owned (e.g. invoke returns, property getters).
Value fromSlintValue(const SlintValue v) @system nothrow
{
    switch (v.tag)
    {
    case SlintTag.Number:
        return Value.of(v.number);
    case SlintTag.String:
        string s;
        if (v.textPtr !is null && v.textLen > 0)
        {
            try
                s = v.textPtr[0 .. v.textLen].idup;
            catch (Throwable)
            {
            }
        }
        return Value.of(s);
    case SlintTag.Bool:
        return Value.of(v.boolean != 0);
    case SlintTag.Brush:
        Value r;
        r.type = ValueType.Brush;
        if (v.brushKind == 0)
        {
            r.brush = Brush.transparent();
            r.color = Color(0, 0, 0, 0);
        }
        else
        {
            Color c = Color.fromArgbU32(v.colorArgb);
            r.brush = Brush.solid(c);
            r.color = c;
        }
        return r;
    case SlintTag.Enumeration:
        string s;
        if (v.textPtr !is null && v.textLen > 0)
        {
            try
                s = v.textPtr[0 .. v.textLen].idup;
            catch (Throwable)
            {
            }
        }
        return Value.of(EnumValue("", s));
    case SlintTag.Struct:
        Value r;
        r.type = ValueType.Struct;
        r.handle = null;
        version (SlintNative)
        {
            if (v.handle !is null)
            {
                import slint.capi : SlintStructRaw, slint_struct_field_count,
                    slint_struct_field_name, slint_struct_get_field, slint_string_free;
                import std.string : fromStringz, toStringz;

                try
                {
                    auto raw = cast(SlintStructRaw*) v.handle;
                    size_t count = slint_struct_field_count(raw);
                    for (size_t i = 0; i < count; ++i)
                    {
                        char* nameRaw = null;
                        char* err = slint_struct_field_name(raw, i, &nameRaw);
                        if (err is null && nameRaw !is null)
                        {
                            string fieldName = fromStringz(nameRaw).idup;
                            slint_string_free(nameRaw);

                            SlintValue childVal;
                            err = slint_struct_get_field(raw, fieldName.toStringz, &childVal);
                            if (err is null)
                            {
                                scope (exit)
                                    freeSlint(&childVal);
                                r.structFields[fieldName] = fromSlintValue(childVal);
                            }
                            else
                            {
                                slint_string_free(err);
                            }
                        }
                        else if (err !is null)
                        {
                            slint_string_free(err);
                        }
                    }
                }
                catch (Throwable)
                {
                }
            }
        }
        return r;
    case SlintTag.Model:
        Value r;
        r.type = ValueType.Model;
        r.handle = null;
        return r;
    default:
        return Value.nil();
    }
}

/// Backward compatibility alias
alias fromSlint = fromSlintValue;

version (SlintNative)
{
    /// Release an owned FFI payload. Idempotent; safe on borrowed payloads.
    /// Native-only: it references the bridge symbol `slint_value_free`.
    void freeSlint(SlintValue* v) @system nothrow
    {
        import slint.capi : slint_value_free;

        if (v is null)
            return;
        try
            slint_value_free(v);
        catch (Throwable)
        {
        }
    }
}
else
{
    void freeSlint(SlintValue* v) @safe pure nothrow @nogc
    {
    }
}

// Best practice: C-ABI SlintValue conversion round-trips for numbers, booleans, and strings
/// Example:
unittest
{
    assert(toSlint(Value.of(2.5)).number == 2.5);
    assert(toSlint(Value.of(true)).boolean == 1);
    auto sv = toSlint(Value.of("abc"));
    assert(sv.tag == SlintTag.String && sv.textLen == 3 && sv.owned == 0);
    assert(fromSlint(sv).text == "abc");
    SlintValue empty;
    empty.tag = SlintTag.String;
    assert(fromSlint(empty).text is null);
    assert(fromSlint(SlintValue.voidValue()).isVoid());
}

// Best practice: High-level Value variants, Color, Brush, EnumValue, and SlintStruct manipulation
/// Example:
unittest
{
    assert(Value.nil().isVoid());
    assert(Value.of(42.0).number == 42.0);
    assert(Value.of(42).type == ValueType.Number);
    assert(Value.of("hi").text == "hi");
    assert(Value.of(true).boolean);
    auto c = Color.fromRgb(255, 0, 128);
    assert(c.toArgbU32() == 0xFFFF0080);
    assert(Color.fromArgbU32(0xFFFF0080) == c);
    assert(Value.of(c).type == ValueType.Brush);
    auto e = Value.of(EnumValue("Position", "top"));
    assert(e.enumValue.value == "top");
    SlintStruct s;
    s["name"] = Value.of("Peter");
    s["age"] = Value.of(22);
    auto v = Value.of(s);
    assert(v.structFields["name"].text == "Peter");
    assert(v.structFields["age"].number == 22);
    assert(Brush.transparent().isTransparent());
    assert(!Brush.solid(c).isTransparent());
    assert(StyledText.fromMarkdown("# hi").markdown);
    assert(!StyledText.fromPlainText("hi").markdown);
}

// Best practice: Color, Brush, EnumValue, SlintStruct <-> SlintValue conversions
/// Example:
unittest
{
    // Color <-> SlintValue (ARGB uint32 0xAARRGGBB)
    auto c = Color.fromArgb(0x80, 0xFF, 0x00, 0x40);
    auto cv = toSlintValue(c);
    assert(cv.tag == SlintTag.Brush);
    assert(cv.brushKind == 1);
    assert(cv.colorArgb == 0x80FF0040);
    auto cBack = fromSlintValue(cv);
    assert(cBack.type == ValueType.Brush);
    assert(cBack.color == c);

    // Brush <-> SlintValue (Transparent and Solid Color)
    auto bt = Brush.transparent();
    auto btv = toSlintValue(bt);
    assert(btv.tag == SlintTag.Brush);
    assert(btv.brushKind == 0);
    auto btBack = fromSlintValue(btv);
    assert(btBack.type == ValueType.Brush);
    assert(btBack.brush.isTransparent());

    auto bs = Brush.solid(c);
    auto bsv = toSlintValue(bs);
    assert(bsv.tag == SlintTag.Brush);
    assert(bsv.brushKind == 1);
    assert(bsv.colorArgb == 0x80FF0040);
    auto bsBack = fromSlintValue(bsv);
    assert(bsBack.type == ValueType.Brush);
    assert(!bsBack.brush.isTransparent());
    assert(bsBack.brush.color == c);

    // EnumValue <-> SlintValue
    auto ev = EnumValue("TextHorizontalAlignment", "center");
    auto esv = toSlintValue(ev);
    assert(esv.tag == SlintTag.Enumeration);
    assert(esv.textLen == 6);
    auto evBack = fromSlintValue(esv);
    assert(evBack.type == ValueType.Enumeration);
    assert(evBack.enumValue.value == "center");

    // SlintStruct <-> SlintValue (Value[string])
    SlintStruct s;
    s["title"] = Value.of("dialog");
    s["count"] = Value.of(42.0);
    auto svVal = Value.of(s);
    auto sv = toSlintValue(svVal);
    assert(sv.tag == SlintTag.Struct);

    version (SlintNative)
    {
        assert(sv.handle !is null);
        assert(sv.owned == 1);
        scope (exit)
            freeSlint(&sv);
        auto sBack = fromSlintValue(sv);
        assert(sBack.type == ValueType.Struct);
        assert(sBack.structFields["title"].text == "dialog");
        assert(sBack.structFields["count"].number == 42.0);
    }
}

/// Optional UDA to override the Slint struct field name for a D struct field.
struct SlintField
{
    string name;
}

/// Convert a camelCase or snake_case identifier into Slint's canonical kebab-case field name.
string camelToKebab(string ident) @safe pure nothrow
{
    char[] buf;
    buf.reserve(ident.length + 4);
    foreach (i, char c; ident)
    {
        if (c == '_')
        {
            buf ~= '-';
        }
        else if (c >= 'A' && c <= 'Z')
        {
            if (i > 0 && ident[i - 1] != '_' && ident[i - 1] != '-')
                buf ~= '-';
            buf ~= cast(char)(c + ('a' - 'A'));
        }
        else
        {
            buf ~= c;
        }
    }
    return (() @trusted => cast(string) buf)();
}

/// Compile-time helper resolving the Slint struct key for field `member` of `T`.
template slintFieldName(T, string member)
{
    import std.traits : getUDAs;

    alias udas = getUDAs!(__traits(getMember, T, member), SlintField);
    static if (udas.length > 0)
        enum string slintFieldName = udas[0].name;
    else
        enum string slintFieldName = camelToKebab(member);
}

/// Automatically map a D struct `T` into a `SlintStruct` (`Value[string]`),
/// converting camelCase field names to kebab-case (and also storing snake_case
/// aliases when needed by Slint's interpreter).
SlintStruct toSlintStruct(T)(const T record) @safe pure if (is(T == struct))
{
    import std.traits : isIntegral, isFloatingPoint, isBoolean, isSomeString;

    SlintStruct res;
    static foreach (idx, fieldName; T.tupleof)
    {
        {
            enum string memberName = __traits(identifier, T.tupleof[idx]);
            enum string key = slintFieldName!(T, memberName);
            alias F = typeof(T.tupleof[idx]);
            auto v = record.tupleof[idx];

            static if (isBoolean!F)
                res[key] = Value.of(cast(bool) v);
            else static if (isIntegral!F || isFloatingPoint!F)
                res[key] = Value.of(cast(double) v);
            else static if (isSomeString!F)
                res[key] = Value.of(cast(string) v);
            else static if (is(Unqual!F == Color))
                res[key] = Value.of(Color(v.red, v.green, v.blue, v.alpha));
            else static if (is(Unqual!F == Brush))
                res[key] = Value.of(Brush(v.kind, Color(v.color.red,
                        v.color.green, v.color.blue, v.color.alpha)));
            else static if (is(Unqual!F == EnumValue))
                res[key] = Value.of(EnumValue(v.enumName, v.value));
            else static if (is(F == enum))
            {
                import std.conv : to;

                res[key] = Value.of(camelToKebab(v.to!string));
            }
            else static if (is(F == struct))
                res[key] = Value.of(toSlintStruct(v));
        }
    }
    return res;
}

private template Unqual(T)
{
    static if (is(T U == const U))
        alias Unqual = Unqual!U;
    else static if (is(T U == immutable U))
        alias Unqual = Unqual!U;
    else
        alias Unqual = T;
}

/// Reconstruct a D struct `T` from a `SlintStruct` (`Value[string]`),
/// matching either kebab-case, snake_case, or exact D field names.
T fromSlintStruct(T)(const SlintStruct s) @safe pure if (is(T == struct))
{
    import std.traits : isIntegral, isFloatingPoint, isBoolean, isSomeString;

    T result;
    static foreach (idx, _; T.tupleof)
    {
        {
            enum string memberName = __traits(identifier, T.tupleof[idx]);
            enum string kebabKey = slintFieldName!(T, memberName);
            alias F = typeof(T.tupleof[idx]);

            const(Value)* found = (kebabKey in s);
            if (found is null)
                found = (memberName in s);

            if (found !is null)
            {
                static if (isBoolean!F)
                    result.tupleof[idx] = found.boolean;
                else static if (isIntegral!F)
                    result.tupleof[idx] = cast(F) found.number;
                else static if (isFloatingPoint!F)
                    result.tupleof[idx] = cast(F) found.number;
                else static if (isSomeString!F)
                    result.tupleof[idx] = found.text;
                else static if (is(F == Color))
                    result.tupleof[idx] = found.color;
                else static if (is(F == Brush))
                    result.tupleof[idx] = found.brush;
                else static if (is(F == struct))
                    result.tupleof[idx] = fromSlintStruct!F(found.structFields);
            }
        }
    }
    return result;
}

// Spec: Slint Interpreter Property/Struct Naming: camelCase to kebab-case mapping and @SlintField UDA round-trip
/// Example:
unittest
{
    static struct SampleRow
    {
        string id;
        string statusVariant;
        int rowIndex;
        double cpuLoad;
        bool isActive;
        @SlintField("custom-metric")
        string metric;
    }

    auto row = SampleRow("srv-01", "success", 3, 72.5, true, "99.9%");
    auto ss = toSlintStruct(row);
    assert(ss["id"].text == "srv-01");
    assert(ss["status-variant"].text == "success");
    assert(ss["row-index"].number == 3.0);
    assert(ss["cpu-load"].number == 72.5);
    assert(ss["is-active"].boolean == true);
    assert(ss["custom-metric"].text == "99.9%");

    auto roundtrip = fromSlintStruct!SampleRow(ss);
    assert(roundtrip == row);
}
