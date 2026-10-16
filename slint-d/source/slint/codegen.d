/// Compile-time component wrappers: typed, IDE-friendly accessors.
///
/// Python generates per-component classes at runtime (`slint.loader`, built
/// in `slint/__init__.py` from `ComponentDefinition` metadata); Node ships
/// hand-written `.d.ts` declarations. D does better: string mixins plus
/// template mixins generate the same accessors **at compile time**, fully
/// type-checked, with zero runtime cost.
///
/// A wrapper is any struct/class holding a `ComponentInstance _instance`
/// member. Mixing in a spec generates `@property` getters/setters (D's
/// idiomatic property syntax, mirroring Python attribute access) and
/// callback helpers:
///
/// ```d
/// struct MainWindow {
///     ComponentInstance _instance;
///     mixin SlintProps!(Prop!("counter", double), Prop!("headline", string));
///     mixin SlintCallbacks!"clicked";
///     alias _instance this; // forward everything else (show/run/loader...)
/// }
/// auto w = MainWindow(result.component("MainWindow").create());
/// w.counter = w.counter + 1;   // typed, checked at compile time
/// w.onClicked((args) { writeln("click"); return Value.nil(); });
/// ```
///
/// `SlintProps` is a template mixin; each property expands through a string
/// mixin (`mixin(propCode!S)`), composing both of D's code-generation
/// mechanisms. Use `slintPropNames` / `slintCallbackNames` with
/// `validateAgainst` to check a spec against live compiler metadata.
module slint.codegen;

import std.array : replace;
import std.traits : isArray, ForeachType;
import slint.model : Model;
import slint.value : Value, Color, Brush, SlintStruct;

/// Compile-time property spec: D accessor name, D value type, and the
/// `.slint` property name (defaults to the D name; pass explicitly when the
/// markup uses dashes, e.g. `Prop!("myProp", double, "my-prop")`).
struct Prop(string DName, T, string SlintName = DName)
{
    enum dName = DName;
    enum slintName = SlintName;
    alias Type = T;
}

/// Generate the getter/setter pair for one `Prop` spec as source text.
/// Numeric D types ride `getNumber`/`setNumber` (Slint stores one `Number`
/// for `int`/`float`/`length`/…); `string` and `bool` map directly.
/// Anything else is a compile-time error, not a runtime surprise.
/// Public only because template mixins resolve helpers at the
/// instantiation site.
string propCode(S)()
{
    static if (is(S.Type == double) || is(S.Type == float) || is(S.Type == int)
            || is(S.Type == long) || is(S.Type == uint) || is(S.Type == ulong))
    {
        return `@property TYPE DNAME() { return cast(TYPE) _instance.getNumber("SLINT"); }
@property void DNAME(TYPE v) { _instance.setNumber("SLINT", cast(double) v); }
`.replace("TYPE", S.Type.stringof).replace("DNAME", S.dName).replace("SLINT", S.slintName);
    }
    else static if (is(S.Type == string))
    {
        return `@property string DNAME() { return _instance.getString("SLINT"); }
@property void DNAME(string v) { _instance.setString("SLINT", v); }
`.replace("DNAME", S.dName).replace("SLINT", S.slintName);
    }
    else static if (is(S.Type == bool))
    {
        return `@property bool DNAME() { return _instance.getBool("SLINT"); }
@property void DNAME(bool v) { _instance.setBool("SLINT", v); }
`.replace("DNAME", S.dName).replace("SLINT", S.slintName);
    }
    else static if (is(S.Type == Color))
    {
        return `@property Color DNAME() { return _instance.getColor("SLINT"); }
@property void DNAME(Color v) { _instance.setColor("SLINT", v); }
`.replace("DNAME", S.dName).replace("SLINT", S.slintName);
    }
    else static if (is(S.Type == Brush))
    {
        return `@property Brush DNAME() { return _instance.getBrush("SLINT"); }
@property void DNAME(Brush v) { _instance.setBrush("SLINT", v); }
`.replace("DNAME", S.dName).replace("SLINT", S.slintName);
    }
    else static if (is(S.Type == SlintStruct))
    {
        return `@property SlintStruct DNAME() { return _instance.getStruct("SLINT"); }
@property void DNAME(SlintStruct v) { _instance.setStruct("SLINT", v); }
`.replace("DNAME", S.dName).replace("SLINT", S.slintName);
    }
    else static if (is(S.Type : Model!E, E))
    {
        return `@property Model!ELEM DNAME() { return _instance.getModel!ELEM("SLINT"); }
@property void DNAME(Model!ELEM v) { _instance.setModel!ELEM("SLINT", v); }
@property void DNAME(ELEM[] v) { _instance.setModel!ELEM("SLINT", v); }
`.replace("ELEM", E.stringof).replace("DNAME", S.dName).replace("SLINT", S.slintName);
    }
    else static if (isArray!(S.Type) && !is(S.Type == string))
    {
        alias E = ForeachType!(S.Type);
        return `@property ELEM[] DNAME() { return _instance.getArray!ELEM("SLINT"); }
@property void DNAME(ELEM[] v) { _instance.setModel!ELEM("SLINT", v); }
@property void DNAME(Model!ELEM v) { _instance.setModel!ELEM("SLINT", v); }
`.replace("ELEM", E.stringof).replace("DNAME", S.dName).replace("SLINT", S.slintName);
    }
    else
    {
        static assert(false, "SlintProps: unsupported property type " ~ S.Type.stringof ~ " for `" ~ S.dName
                ~ "` (use double, string, bool, Color, Brush, SlintStruct, Model!T, or T[])");
    }
}

/// Mixin generating typed `@property` accessors for each `Prop` spec.
/// Requires a `ComponentInstance _instance` member in the enclosing scope.
mixin template SlintProps(Specs...)
{
    static foreach (S; Specs)
    {
        mixin(propCode!S());
    }

    /// `.slint` property names covered by this spec (for `validateAgainst`).
    static string[] slintPropNames() @safe pure
    {
        string[] names;
        static foreach (S; Specs)
            names ~= S.slintName;
        return names;
    }
}

/// CTFE helper composing callback emitter/setter source (see
/// `SlintCallbacks`). Public only because template mixins resolve helpers
/// at the instantiation site.
string callbackCode(string name, string onName) @safe pure
{
    return `void NAME() { _instance.invoke("SLINT"); }
void ONNAME(Value delegate(const(Value)[]) handler) { _instance.setCallback("SLINT", handler); }
void ONNAME(void delegate() handler) { _instance.setCallback("SLINT", handler); }
`.replace("ONNAME", onName).replace("SLINT", name).replace("NAME", name);
}

/// CamelCase a callback name for its `onX` setter: `clicked` → `Clicked`,
/// `request-increase-value` → `RequestIncreaseValue`. D method names cannot
/// carry the markup's dashes, and camelCase reads better than underscores.
string capitalize(string s) @safe pure
{
    import std.array : split;

    string[] words;
    foreach (w; s.split("_"))
        foreach (v; w.split("-"))
            if (v.length)
                words ~= v;
    string out_;
    foreach (w; words)
    {
        char[] c = w.dup;
        if (c[0] >= 'a' && c[0] <= 'z')
            c[0] = cast(char)(c[0] - ('a' - 'A'));
        out_ ~= c.idup;
    }
    return out_;
}

/// Mixin generating, per callback name, an emitter (`clicked()`), a typed
/// handler setter (`onClicked(handler)` accepting a `Value` delegate or a
/// plain `void` delegate), mirroring Python's callback attributes.
mixin template SlintCallbacks(Names...)
{
    static foreach (cb; Names)
    {
        mixin(callbackCode(cb, "on" ~ capitalize(cb)));
    }

    static string[] slintCallbackNames() @safe pure
    {
        string[] names;
        static foreach (cb; Names)
            names ~= cb;
        return names;
    }
}

// `validateAgainst` lives on the definition side to avoid a circular import:
// see `slint.definition.validateSpec`.

///
unittest
{
    import slint.definition : ComponentDefinition;
    import slint.instance : ComponentInstance;

    struct W
    {
        ComponentInstance _instance;
        mixin SlintProps!(Prop!("counter", double), Prop!("headline",
                string), Prop!("on", bool), Prop!("myProp", int, "my-prop"));
        mixin SlintCallbacks!("clicked");
    }

    // Spec metadata is available without an instance.
    assert(W.slintPropNames() == ["counter", "headline", "on", "my-prop"]);
    assert(W.slintCallbackNames() == ["clicked"]);

    // Handler names are camelCased for D call sites.
    assert(capitalize("request-increase-value") == "RequestIncreaseValue");
    assert(capitalize("clicked") == "Clicked");

    // Accessors type-check: wrong types fail to compile, not at runtime.
    static assert(is(typeof(W.counter) == double));
    static assert(is(typeof(W.headline) == string));
    static assert(is(typeof(W.on) == bool));
    static assert(is(typeof(W.myProp) == int));

    // Validation against compiler metadata catches drift.
    auto def = new ComponentDefinition("MainWindow", [
        "counter", "headline", "on", "my-prop"
    ], ["clicked"]);
    assert(def.validateSpec(W.slintPropNames(), W.slintCallbackNames()));

    auto stale = new ComponentDefinition("MainWindow", ["counter"], []);
    assert(!stale.validateSpec(W.slintPropNames(), W.slintCallbackNames()));
}

/// Rich property codegen unittest (Color, Brush, SlintStruct)
unittest
{
    import slint.instance : ComponentInstance;
    import slint.value : Color, Brush, SlintStruct;

    struct RichComponent
    {
        ComponentInstance _instance;
        mixin SlintProps!(Prop!("background", Color), Prop!("fill", Brush),
                Prop!("data", SlintStruct));
    }

    assert(RichComponent.slintPropNames() == ["background", "fill", "data"]);
    static assert(is(typeof(RichComponent.background) == Color));
    static assert(is(typeof(RichComponent.fill) == Brush));
    static assert(is(typeof(RichComponent.data) == SlintStruct));
}

/// Typed numeric property codegen unittest (int, float getters and setters)
unittest
{
    import slint.instance : ComponentInstance;

    struct NumericComponent
    {
        ComponentInstance _instance;
        mixin SlintProps!(Prop!("count", int), Prop!("ratio", float));
    }

    static assert(is(typeof(NumericComponent.count) == int));
    static assert(is(typeof(NumericComponent.ratio) == float));

    version (SlintNative)
    {
        import slint.compiler : Compiler;

        auto c = new Compiler();
        auto res = c.buildFromSource("export component NumericTest inherits Window {\n"
                ~ "    in-out property <int> count: 10;\n"
                ~ "    in-out property <float> ratio: 0.5;\n" ~ "}\n");
        auto compDef = res.component("NumericTest");
        assert(compDef !is null);
        auto inst = compDef.create();
        assert(inst !is null);

        auto comp = NumericComponent(inst);
        assert(comp.count == 10);
        comp.count = 42;
        assert(comp.count == 42);

        assert(comp.ratio > 0.49f && comp.ratio < 0.51f);
        comp.ratio = 1.25f;
        assert(comp.ratio > 1.24f && comp.ratio < 1.26f);
    }
}

/// Model and array property codegen unittest (Model!int, string[])
unittest
{
    import slint.instance : ComponentInstance;
    import slint.model : Model, ArrayModel;

    struct ModelComponent
    {
        ComponentInstance _instance;
        mixin SlintProps!(Prop!("items", Model!int), Prop!("names", string[]));
    }

    assert(ModelComponent.slintPropNames() == ["items", "names"]);
    static assert(is(typeof(ModelComponent.items) == Model!int));
    static assert(is(typeof(ModelComponent.names) == string[]));

    version (SlintNative)
    {
        import slint.compiler : Compiler;

        auto c = new Compiler();
        auto res = c.buildFromSource(
                "export component ModelCodegenTest inherits Window {\n" ~ "    in-out property <[int]> items: [1, 2, 3];\n"
                ~ "    in-out property <[string]> names: [\"alice\", \"bob\"];\n" ~ "}\n");
        auto compDef = res.component("ModelCodegenTest");
        assert(compDef !is null);
        auto inst = compDef.create();
        assert(inst !is null);

        auto comp = ModelComponent(inst);
        assert(comp.items !is null);
        assert(comp.items.rowCount() == 3);
        assert(comp.items.rowData(0) == 1);

        comp.names = ["charlie", "david"];
        assert(comp.names == ["charlie", "david"]);
    }
}
