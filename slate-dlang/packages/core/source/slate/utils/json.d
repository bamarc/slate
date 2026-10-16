/// Declarative compile-time introspection-based JSON serialization.
///
/// Provides `mixin template JsonSerializable`, `@JsonKey("...")`, and
/// `@jsonIgnore` for zero-boilerplate model serialization matching MCP
/// wire formats.
module slate.utils.json;

import std.conv : to;
import std.json : JSONType, JSONValue, JSONException;
import std.range : ElementType;
import std.traits : FieldNameTuple, isAssociativeArray, isArray, isStaticArray, isFloatingPoint,
    isIntegral, isSomeString, isUnsigned, KeyType, ValueType, OriginalType, Unqual;
import std.typecons : Nullable, nullable;

/// Remaps a struct field to a custom JSON object key name.
struct JsonKey
{
    string name;
}

/// Convenience factory for `@JsonKey("...")`.
JsonKey jsonKey(string name) @safe pure nothrow @nogc
{
    return JsonKey(name);
}

/// Marks a struct field to be omitted from JSON serialization and deserialization.
struct JsonIgnore
{
}

/// UDA instance for `@jsonIgnore`.
enum jsonIgnore = JsonIgnore();

pragma(inline, true) private auto trustedObject()(ref const(JSONValue) jv) @trusted
{
    return jv.object;
}

/// Converts a typed value to its corresponding `JSONValue` representation.
JSONValue toJsonValue(T)(const auto ref T val)
{
    static if (is(T == JSONValue))
    {
        return cast(JSONValue) val;
    }
    else static if (is(T == Nullable!U, U))
    {
        if (val.isNull)
            return JSONValue(null);
        return toJsonValue(val.get);
    }
    else static if (__traits(hasMember, T, "toJson"))
    {
        static if (is(T == class) || is(T == interface))
        {
            if (val is null)
                return JSONValue(null);
        }
        return val.toJson();
    }
    else static if (is(T == string))
    {
        return JSONValue(val);
    }
    else static if (is(T == bool))
    {
        return JSONValue(val);
    }
    else static if (is(T == enum))
    {
        static if (isSomeString!(OriginalType!T))
            return JSONValue(cast(string) val);
        else static if (isIntegral!(OriginalType!T))
        {
            static if (isUnsigned!(OriginalType!T))
                return JSONValue(cast(ulong) val);
            else
                return JSONValue(cast(long) val);
        }
        else static if (isFloatingPoint!(OriginalType!T))
        {
            import std.math : isNaN, isInfinity;

            auto fv = cast(OriginalType!T) val;
            if (isNaN(fv) || isInfinity(fv))
                return JSONValue(null);
            return JSONValue(cast(double) fv);
        }
        else static if (is(OriginalType!T == bool))
        {
            return JSONValue(cast(bool) val);
        }
        else
            return JSONValue(to!string(val));
    }
    else static if (is(T == char) || is(T == wchar) || is(T == dchar))
    {
        return JSONValue(to!string(val));
    }
    else static if (isFloatingPoint!T)
    {
        import std.math : isNaN, isInfinity;

        if (isNaN(val) || isInfinity(val))
            return JSONValue(null);
        return JSONValue(cast(double) val);
    }
    else static if (isIntegral!T)
    {
        static if (isUnsigned!T)
            return JSONValue(cast(ulong) val);
        else
            return JSONValue(cast(long) val);
    }
    else static if (isArray!T && !isSomeString!T)
    {
        JSONValue[] arr;
        foreach (ref item; val)
            arr ~= toJsonValue(item);
        return JSONValue(arr);
    }
    else static if (isAssociativeArray!T)
    {
        JSONValue[string] aa;
        foreach (k, ref v; val)
        {
            aa[to!string(k)] = toJsonValue(v);
        }
        return JSONValue(aa);
    }
    else
    {
        static assert(0, "Unsupported type for toJsonValue: " ~ T.stringof);
    }
}

/// Deserializes a `JSONValue` into target type `T`.
T fromJsonValue(T)(const JSONValue jv)
{
    static if (is(T == JSONValue))
    {
        return cast(JSONValue) jv;
    }
    else static if (is(T == Nullable!U, U))
    {
        if (jv.type == JSONType.null_)
            return Nullable!U.init;
        return nullable(fromJsonValue!U(jv));
    }
    else
    {
        if (jv.type == JSONType.null_)
            return T.init;

        static if (__traits(hasMember, T, "fromJson"))
        {
            return T.fromJson(jv);
        }
        else static if (is(Unqual!T == string) || isSomeString!T)
        {
            if (jv.type == JSONType.string)
                return cast(T) jv.str;
            if (jv.type == JSONType.integer)
                return cast(T) to!string(jv.integer);
            if (jv.type == JSONType.uinteger)
                return cast(T) to!string(jv.uinteger);
            if (jv.type == JSONType.float_)
                return cast(T) to!string(jv.floating);
            if (jv.type == JSONType.true_)
                return cast(T) "true";
            if (jv.type == JSONType.false_)
                return cast(T) "false";
            return T.init;
        }
        else static if (is(T == bool))
        {
            if (jv.type == JSONType.true_)
                return true;
            if (jv.type == JSONType.false_)
                return false;
            if (jv.type == JSONType.integer)
                return jv.integer != 0;
            if (jv.type == JSONType.uinteger)
                return jv.uinteger != 0;
            if (jv.type == JSONType.string)
                return jv.str == "true" || jv.str == "1";
            return false;
        }
        else static if (is(T == enum))
        {
            import std.traits : EnumMembers;

            static if (isSomeString!(OriginalType!T))
            {
                if (jv.type == JSONType.string)
                {
                    static foreach (member; EnumMembers!T)
                    {
                        if (jv.str == cast(OriginalType!T) member)
                            return member;
                    }
                    throw new JSONException(
                            "Invalid enum string '" ~ jv.str ~ "' for enum " ~ T.stringof);
                }
                throw new JSONException(
                        "Expected string for enum " ~ T.stringof ~ ", got " ~ to!string(jv.type));
            }
            else static if (isIntegral!(OriginalType!T))
            {
                long val;
                if (jv.type == JSONType.integer)
                    val = jv.integer;
                else if (jv.type == JSONType.uinteger)
                {
                    if (jv.uinteger > long.max)
                        throw new JSONException("Enum value out of range for " ~ T.stringof);
                    val = cast(long) jv.uinteger;
                }
                else if (jv.type == JSONType.float_)
                {
                    import std.math : isFinite;

                    if (!isFinite(jv.floating) || jv.floating < long.min || jv.floating > long.max)
                        throw new JSONException("Float value out of range for enum " ~ T.stringof);
                    val = cast(long) jv.floating;
                }
                else if (jv.type == JSONType.string)
                {
                    static foreach (member; EnumMembers!T)
                    {
                        if (jv.str == to!string(member)
                                || jv.str == to!string(cast(OriginalType!T) member))
                            return member;
                    }
                    try
                        val = to!long(jv.str);
                    catch (Exception)
                        throw new JSONException(
                                "Invalid enum string '" ~ jv.str ~ "' for enum " ~ T.stringof);
                }
                else
                    throw new JSONException(
                            "Expected integer or string for enum " ~ T.stringof ~ ", got " ~ to!string(
                            jv.type));

                static foreach (member; EnumMembers!T)
                {
                    if (val == cast(OriginalType!T) member)
                        return member;
                }
                throw new JSONException(
                        "Invalid enum value " ~ to!string(val) ~ " for enum " ~ T.stringof);
            }
            else static if (isFloatingPoint!(OriginalType!T))
            {
                double val;
                if (jv.type == JSONType.float_)
                    val = jv.floating;
                else if (jv.type == JSONType.integer)
                    val = cast(double) jv.integer;
                else if (jv.type == JSONType.uinteger)
                    val = cast(double) jv.uinteger;
                else
                    throw new JSONException(
                            "Expected float for enum " ~ T.stringof ~ ", got " ~ to!string(jv.type));

                static foreach (member; EnumMembers!T)
                {
                    if (val == cast(OriginalType!T) member)
                        return member;
                }
                throw new JSONException(
                        "Invalid enum value " ~ to!string(val) ~ " for enum " ~ T.stringof);
            }
            else static if (is(OriginalType!T == bool))
            {
                if (jv.type == JSONType.true_)
                    return cast(T) true;
                if (jv.type == JSONType.false_)
                    return cast(T) false;
                throw new JSONException(
                        "Expected boolean for enum " ~ T.stringof ~ ", got " ~ to!string(jv.type));
            }
            else
            {
                throw new JSONException("Unsupported enum type: " ~ T.stringof);
            }
        }
        else static if (is(T == char) || is(T == wchar) || is(T == dchar))
        {
            if (jv.type == JSONType.string && jv.str.length > 0)
                return cast(T) jv.str[0];
            return T.init;
        }
        else static if (isFloatingPoint!T)
        {
            if (jv.type == JSONType.float_)
                return cast(T) jv.floating;
            if (jv.type == JSONType.integer)
                return cast(T) jv.integer;
            if (jv.type == JSONType.uinteger)
                return cast(T) jv.uinteger;
            if (jv.type == JSONType.string)
            {
                try
                    return to!T(jv.str);
                catch (Exception)
                    throw new JSONException("Failed to parse string '" ~ jv.str
                            ~ "' as " ~ T.stringof);
            }
            throw new JSONException(
                    "Expected number for " ~ T.stringof ~ ", got " ~ to!string(jv.type));
        }
        else static if (isIntegral!T)
        {
            if (jv.type == JSONType.integer)
            {
                long val = jv.integer;
                static if (isUnsigned!T)
                {
                    if (val < 0 || cast(ulong) val > T.max)
                        throw new JSONException("Value " ~ to!string(
                                val) ~ " out of bounds for " ~ T.stringof);
                    return cast(T) val;
                }
                else
                {
                    if (val < T.min || val > T.max)
                        throw new JSONException("Value " ~ to!string(
                                val) ~ " out of bounds for " ~ T.stringof);
                    return cast(T) val;
                }
            }
            else if (jv.type == JSONType.uinteger)
            {
                ulong uval = jv.uinteger;
                static if (isUnsigned!T)
                {
                    if (uval > T.max)
                        throw new JSONException("Value " ~ to!string(
                                uval) ~ " out of bounds for " ~ T.stringof);
                    return cast(T) uval;
                }
                else
                {
                    if (uval > cast(ulong) T.max)
                        throw new JSONException("Value " ~ to!string(
                                uval) ~ " out of bounds for " ~ T.stringof);
                    return cast(T) uval;
                }
            }
            else if (jv.type == JSONType.float_)
            {
                import std.math : isFinite;

                if (!isFinite(jv.floating) || jv.floating < cast(double) T.min
                        || jv.floating > cast(double) T.max)
                    throw new JSONException("Float " ~ to!string(
                            jv.floating) ~ " out of bounds or not finite for " ~ T.stringof);
                return cast(T) jv.floating;
            }
            else if (jv.type == JSONType.string)
            {
                try
                    return to!T(jv.str);
                catch (Exception)
                    throw new JSONException("Failed to parse string '" ~ jv.str
                            ~ "' as " ~ T.stringof);
            }
            else
            {
                throw new JSONException(
                        "Expected integer for " ~ T.stringof ~ ", got " ~ to!string(jv.type));
            }
        }
        else static if (isStaticArray!T)
        {
            if (jv.type != JSONType.array)
                return T.init;
            alias E = ElementType!T;
            T arr;
            size_t count = jv.array.length < T.length ? jv.array.length : T.length;
            foreach (i; 0 .. count)
                arr[i] = fromJsonValue!E(jv.array[i]);
            return arr;
        }
        else static if (isArray!T && !isSomeString!T)
        {
            if (jv.type != JSONType.array)
                return T.init;
            alias E = ElementType!T;
            T arr;
            foreach (ref elem; jv.array)
                arr ~= fromJsonValue!E(elem);
            return arr;
        }
        else static if (isAssociativeArray!T)
        {
            if (jv.type != JSONType.object)
                return T.init;
            alias Key = KeyType!T;
            alias Val = ValueType!T;
            T aa;
            foreach (k, ref v; trustedObject(jv))
            {
                static if (is(Key == string))
                    aa[k] = fromJsonValue!Val(v);
                else
                {
                    try
                        aa[to!Key(k)] = fromJsonValue!Val(v);
                    catch (Exception)
                    {
                    }
                }
            }
            return aa;
        }
        else
        {
            static assert(0, "Unsupported type for fromJsonValue: " ~ T.stringof);
        }
    }
}

/// Mixin template providing compile-time declarative JSON serialization.
///
/// Inspects instance fields and generates `toJson()` and `static fromJson()`.
/// Respects `@JsonKey("name")`, `@jsonIgnore`, and omits empty/null `Nullable!T`.
mixin template JsonSerializable()
{
    import std.conv : to;
    import std.traits : FieldNameTuple, isAssociativeArray;
    import std.typecons : Nullable, nullable;
    import std.json : JSONValue, JSONType, parseJSON, JSONException;
    import slate.utils.json : toJsonValue, fromJsonValue, JsonKey, JsonIgnore;

    JSONValue toJson()() const
    {
        JSONValue[string] obj;
        static foreach (fieldName; FieldNameTuple!(typeof(this)))
        {
            {
                alias FieldType = typeof(__traits(getMember, this, fieldName));
                enum isIgnored = () {
                    bool ig = false;
                    static foreach (uda; __traits(getAttributes,
                            __traits(getMember, typeof(this), fieldName)))
                    {
                        static if (is(typeof(uda) == JsonIgnore) || is(uda == JsonIgnore))
                            ig = true;
                    }
                    return ig;
                }();

                static if (!isIgnored)
                {
                    enum jsonKeyName = () {
                        string key = fieldName;
                        static foreach (uda; __traits(getAttributes,
                                __traits(getMember, typeof(this), fieldName)))
                        {
                            static if (is(typeof(uda) == JsonKey))
                                key = uda.name;
                        }
                        return key;
                    }();

                    auto val = __traits(getMember, this, fieldName);
                    static if (is(FieldType == Nullable!U, U))
                    {
                        if (!val.isNull)
                            obj[jsonKeyName] = toJsonValue(val.get);
                    }
                    else static if (isAssociativeArray!FieldType)
                    {
                        if (val.length > 0)
                            obj[jsonKeyName] = toJsonValue(val);
                    }
                    else
                    {
                        obj[jsonKeyName] = toJsonValue(val);
                    }
                }
            }
        }
        return JSONValue(obj);
    }

    static typeof(this) fromJson()(const JSONValue j)
    {
        if (j.type != JSONType.object)
            throw new JSONException("Expected JSON object for " ~ typeof(this)
                    .stringof ~ ", got " ~ to!string(j.type));

        typeof(this) result;
        static foreach (fieldName; FieldNameTuple!(typeof(this)))
        {
            {
                alias FieldType = typeof(__traits(getMember, result, fieldName));
                enum isIgnored = () {
                    bool ig = false;
                    static foreach (uda; __traits(getAttributes,
                            __traits(getMember, typeof(this), fieldName)))
                    {
                        static if (is(typeof(uda) == JsonIgnore) || is(uda == JsonIgnore))
                            ig = true;
                    }
                    return ig;
                }();

                static if (!isIgnored)
                {
                    enum jsonKeyName = () {
                        string key = fieldName;
                        static foreach (uda; __traits(getAttributes,
                                __traits(getMember, typeof(this), fieldName)))
                        {
                            static if (is(typeof(uda) == JsonKey))
                                key = uda.name;
                        }
                        return key;
                    }();

                    if (auto pVal = jsonKeyName in j)
                    {
                        auto jv = *pVal;
                        if (jv.type == JSONType.null_)
                        {
                            static if (is(FieldType == Nullable!U, U))
                                __traits(getMember, result, fieldName) = Nullable!U.init;
                            else
                                __traits(getMember, result, fieldName) = FieldType.init;
                        }
                        else
                        {
                            static if (is(FieldType == Nullable!U, U))
                                __traits(getMember, result, fieldName) = nullable(
                                        fromJsonValue!U(jv));
                            else
                                __traits(getMember, result, fieldName) = fromJsonValue!FieldType(jv);
                        }
                    }
                }
            }
        }
        static if (__traits(hasMember, typeof(this), "validate"))
        {
            result.validate();
        }
        return result;
    }

    static typeof(this) fromJson()(string jsonString)
    {
        return fromJson(parseJSON(jsonString));
    }
}

// Spec: Unit tests verifying round-trip, @JsonKey, @jsonIgnore, and Nullable!T omissions.
/// Example:
unittest
{
    import std.json : parseJSON;
    import std.exception : assertThrown;

    // 1. Basic round-trip
    static struct Simple
    {
        int a;
        string b;
        double c;
        bool d;
        mixin JsonSerializable;
    }

    auto s1 = Simple(42, "hello", 3.14, true);
    auto sj = s1.toJson();
    assert(sj["a"].integer == 42);
    assert(sj["b"].str == "hello");
    assert(sj["c"].floating == 3.14);
    assert(sj["d"].type == JSONType.true_);

    auto s2 = Simple.fromJson(sj);
    assert(s2.a == s1.a && s2.b == s1.b && s2.c == s1.c && s2.d == s1.d);

    // 2. @JsonKey remapping
    static struct Remapped
    {
        @JsonKey("custom_id") string id;
        @JsonKey("item_count") int count;
        string normal;
        mixin JsonSerializable;
    }

    auto r1 = Remapped("abc", 5, "norm");
    auto rj = r1.toJson();
    assert("custom_id" in rj && !("id" in rj));
    assert("item_count" in rj && !("count" in rj));
    assert("normal" in rj);
    assert(rj["custom_id"].str == "abc");
    assert(rj["item_count"].integer == 5);

    auto r2 = Remapped.fromJson(rj);
    assert(r2.id == "abc");
    assert(r2.count == 5);
    assert(r2.normal == "norm");

    // 3. @jsonIgnore
    static struct Ignored
    {
        string visible;
        @jsonIgnore string secret = "default_secret";
        @jsonIgnore int internalCount = 99;
        mixin JsonSerializable;
    }

    auto ig1 = Ignored("see-me", "hidden", 123);
    auto igj = ig1.toJson();
    assert("visible" in igj);
    assert("secret" !in igj);
    assert("internalCount" !in igj);

    // Deserialization ignores the field even if present in JSON
    auto mockJson = parseJSON(`{"visible":"new","secret":"hacked","internalCount":999}`);
    auto ig2 = Ignored.fromJson(mockJson);
    assert(ig2.visible == "new");
    assert(ig2.secret == "default_secret");
    assert(ig2.internalCount == 99);

    // 4. Nullable!T omissions and round-trip
    static struct OptModel
    {
        Nullable!float valA;
        @JsonKey("val_b") Nullable!string valB;
        @JsonKey("val_c") Nullable!int valC;
        JSONValue[string] meta;
        mixin JsonSerializable;
    }

    OptModel omEmpty;
    auto omEmptyJson = omEmpty.toJson();
    assert(omEmptyJson.object.length == 0); // All omitted

    OptModel omPopulated;
    omPopulated.valA = nullable(1.5f);
    omPopulated.valC = nullable(100);
    omPopulated.meta["k"] = JSONValue("v");
    auto omPopJson = omPopulated.toJson();

    assert("valA" in omPopJson);
    assert("val_b" !in omPopJson); // Absent Nullable omitted
    assert("val_c" in omPopJson);
    assert("meta" in omPopJson);
    assert(omPopJson["val_c"].integer == 100);

    auto omRoundTrip = OptModel.fromJson(omPopJson);
    assert(!omRoundTrip.valA.isNull && omRoundTrip.valA.get == 1.5f);
    assert(omRoundTrip.valB.isNull);
    assert(!omRoundTrip.valC.isNull && omRoundTrip.valC.get == 100);
    assert(omRoundTrip.meta["k"].str == "v");

    // Nullable explicitly null in JSON
    auto nullJson = parseJSON(`{"valA": null, "val_b": null}`);
    auto omFromNull = OptModel.fromJson(nullJson);
    assert(omFromNull.valA.isNull);
    assert(omFromNull.valB.isNull);

    // 5. Edge cases: non-object JSON input to fromJson throws JSONException
    assertThrown!JSONException(Simple.fromJson(JSONValue(42)));
    assertThrown!JSONException(Simple.fromJson(JSONValue(null)));

    // 6. Unknown extra keys in JSON are safely ignored
    auto withExtra = Simple.fromJson(
            parseJSON(`{"a":99,"b":"ok","c":1.0,"d":false,"unknown_prop":123}`));
    assert(withExtra.a == 99 && withExtra.b == "ok");

    // 7. Nested struct serialization
    static struct Nested
    {
        string tag;
        Simple child;
        mixin JsonSerializable;
    }

    auto nest1 = Nested("outer", Simple(1, "inner", 2.0, true));
    auto nestJson = nest1.toJson();
    assert(nestJson["tag"].str == "outer");
    assert(nestJson["child"]["a"].integer == 1);
    auto nest2 = Nested.fromJson(nestJson);
    assert(nest2.tag == "outer" && nest2.child.b == "inner");

    // 8. Enum serialization (both string-backed and integer-backed)
    enum ColorCode : string
    {
        red = "RED",
        blue = "BLUE"
    }

    enum Priority
    {
        low = 1,
        high = 10
    }

    static struct EnumModel
    {
        ColorCode color;
        Priority prio;
        mixin JsonSerializable;
    }

    auto em = EnumModel(ColorCode.blue, Priority.high);
    auto emj = em.toJson();
    assert(emj["color"].str == "BLUE");
    assert(emj["prio"].integer == 10);

    auto em2 = EnumModel.fromJson(emj);
    assert(em2.color == ColorCode.blue);
    assert(em2.prio == Priority.high);

    // 9. Null values for primitive fields in JSON do not throw and yield default values
    import std.math : isNaN;

    auto nullPrimitiveJson = parseJSON(`{"a": null, "b": null, "c": null, "d": null}`);
    auto simpleFromNull = Simple.fromJson(nullPrimitiveJson);
    assert(simpleFromNull.a == 0);
    assert(simpleFromNull.b is null);
    assert(simpleFromNull.c.isNaN);
    assert(simpleFromNull.d == false);

    // 10. fromJson(string) convenience overload
    auto directStr = Simple.fromJson(`{"a": 123, "b": "parsed", "c": 4.5, "d": true}`);
    assert(directStr.a == 123);
    assert(directStr.b == "parsed");
    assert(directStr.c == 4.5);
    assert(directStr.d == true);

    // 11. Mismatched JSON types throw JSONException
    assertThrown!JSONException(
            Simple.fromJson(parseJSON(`{"a": "hello", "b": 999, "c": 1.0, "d": true}`)));

    // 12. Malformed JSON string to fromJson throws JSONException
    assertThrown!JSONException(Simple.fromJson(`{malformed json...`));

    // 13. NaN and Infinity float values serialize as null and round-trip to NaN
    Simple withNan;
    withNan.a = 7;
    withNan.c = double.nan;
    auto nanJson = withNan.toJson();
    assert(nanJson["c"].type == JSONType.null_);
    assert(nanJson.toString().length > 0); // Does not throw Cannot encode NaN
    auto fromNan = Simple.fromJson(nanJson);
    assert(fromNan.c.isNaN);

    // 14. Associative array of structs
    static struct Item
    {
        string name;
        int qty;
        mixin JsonSerializable;
    }

    static struct Catalog
    {
        Item[string] items;
        mixin JsonSerializable;
    }

    Catalog cat;
    cat.items["prod1"] = Item("Widget", 10);
    auto catJson = cat.toJson();
    assert(catJson["items"]["prod1"]["name"].str == "Widget");
    auto catRoundTrip = Catalog.fromJson(catJson);
    assert("prod1" in catRoundTrip.items);
    assert(catRoundTrip.items["prod1"].name == "Widget");
    assert(catRoundTrip.items["prod1"].qty == 10);

    // 15. Boolean and floating-point enums
    enum Mode : bool
    {
        off = false,
        on = true
    }

    enum Scale : double
    {
        half = 0.5,
        full = 1.0
    }

    static struct ExtendedEnums
    {
        Mode mode;
        Scale scale;
        mixin JsonSerializable;
    }

    auto ee = ExtendedEnums(Mode.on, Scale.half);
    auto eej = ee.toJson();
    assert(eej["mode"].type == JSONType.true_);
    assert(eej["scale"].floating == 0.5);
    auto ee2 = ExtendedEnums.fromJson(eej);
    assert(ee2.mode == Mode.on);
    assert(ee2.scale == Scale.half);

    // 16. Static array serialization and deserialization
    static struct StaticArrayModel
    {
        int[3] nums;
        mixin JsonSerializable;
    }

    StaticArrayModel sam = StaticArrayModel([10, 20, 30]);
    auto samJson = sam.toJson();
    assert(samJson["nums"].array.length == 3);
    assert(samJson["nums"].array[1].integer == 20);
    auto sam2 = StaticArrayModel.fromJson(samJson);
    assert(sam2.nums == [10, 20, 30]);

    // 17. Null class toJsonValue and fromJsonValue
    static class DummyNode
    {
        string tag;
        JSONValue toJson() const
        {
            return JSONValue(["tag": JSONValue(tag)]);
        }

        static DummyNode fromJson(const JSONValue j)
        {
            if (j.type != JSONType.object)
                return null;
            auto d = new DummyNode();
            if (auto p = "tag" in j)
                d.tag = p.str;
            return d;
        }
    }

    DummyNode nullNode = null;
    auto nullNodeJson = toJsonValue(nullNode);
    assert(nullNodeJson.type == JSONType.null_);
    auto deserializedNullNode = fromJsonValue!DummyNode(JSONValue(null));
    assert(deserializedNullNode is null);

    // 18. Integer enum deserialization from JSON float
    auto prioFromFloat = fromJsonValue!Priority(JSONValue(10.0));
    assert(prioFromFloat == Priority.high);

    // 19. Nullable!Model empty serialization does not crash or call get()
    Nullable!Simple nullSimple;
    assert(toJsonValue(nullSimple).type == JSONType.null_);
    auto roundTripNullSimple = fromJsonValue!(Nullable!Simple)(JSONValue(null));
    assert(roundTripNullSimple.isNull);

    // 20. Integer range checks
    static struct RangeModel
    {
        ubyte u8;
        uint u32;
        mixin JsonSerializable;
    }

    assertThrown!JSONException(RangeModel.fromJson(parseJSON(`{"u8": 300, "u32": 10}`)));
    assertThrown!JSONException(RangeModel.fromJson(parseJSON(`{"u8": 10, "u32": -1}`)));

    // 21. Enum validation checks
    assertThrown!JSONException(EnumModel.fromJson(parseJSON(`{"color": "INVALID", "prio": 1}`)));
    assertThrown!JSONException(EnumModel.fromJson(parseJSON(`{"color": "BLUE", "prio": 999}`)));

    // 22. Validate hook exception propagation in fromJson
    static struct Validated
    {
        int count;
        void validate() const
        {
            if (count < 0)
                throw new Exception("Count must be non-negative");
        }

        mixin JsonSerializable;
    }

    assertThrown!Exception(Validated.fromJson(`{"count": -5}`));
    assertThrown!Exception(Validated.fromJson(parseJSON(`{"count": -5}`)));
    auto valOk = Validated.fromJson(`{"count": 5}`);
    assert(valOk.count == 5);
}
