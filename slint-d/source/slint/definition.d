/// Compiled component definitions: metadata plus instantiation.
///
/// Mirrors `JsComponentDefinition` in
/// `api/node/rust/interpreter/component_definition.rs` and
/// `ComponentDefinition` in `api/python/slint/interpreter.rs`: a compiled
/// component's name, its properties / callbacks / functions (including
/// globals), and `create()` to instantiate it.
///
/// In native builds the metadata lists are populated from the compiled
/// component itself (via the bridge introspection helpers), so handwritten
/// `slint.codegen` specs can be validated against ground truth with
/// `validateSpec`.
module slint.definition;

import slint.capi;
import slint.instance : ComponentInstance;
import slint.value : ValueType;

/// Metadata for one exported Slint component.
class ComponentDefinition
{
    private string _name;
    private string[] _properties;
    private ValueType[] _propertyTypes;
    private string[] _callbacks;
    private string[] _functions;
    private string[] _globals;

    version (SlintNative)
    {
    private SlintDefinition* _handle;

        /// Wrap a native definition handle (takes ownership) and fetch the
        /// exported metadata lists through the bridge.
        this(SlintDefinition* handle) @system
        {
            import std.string : fromStringz;
            import slint : NativeUnavailable;

            _handle = handle;
            if (_handle is null)
                throw new NativeUnavailable("ComponentDefinition handle is null");

            char* raw;
            checkFetch(slint_definition_get_name(_handle, &raw));
            if (raw !is null)
            {
                scope (exit)
                    slint_string_free(raw);
                _name = fromStringz(raw).idup;
            }

            fetchNames(&slint_definition_property_count, &slint_definition_property_name,
                _properties);
            _propertyTypes.length = _properties.length;
            foreach (i, ref t; _propertyTypes)
                t = cast(ValueType) slint_definition_property_type(_handle, i);
            fetchNames(&slint_definition_callback_count, &slint_definition_callback_name,
                _callbacks);
            fetchNames(&slint_definition_function_count, &slint_definition_function_name,
                _functions);
            fetchNames(&slint_definition_global_count, &slint_definition_global_name, _globals);
        }

        ~this() @system
        {
            if (_handle !is null)
            {
                slint_definition_free(_handle);
                _handle = null;
            }
        }

        private void fetchNames(CountFn count, NameFn name, ref string[] into) @system
        {
            import std.string : fromStringz;

            into.length = count(_handle);
            foreach (i, ref s; into)
            {
                char* raw;
                checkFetch(name(_handle, i, &raw));
                if (raw !is null)
                {
                    scope (exit)
                        slint_string_free(raw);
                    s = fromStringz(raw).idup;
                }
            }
        }

        private void checkFetch(char* err) @system
        {
            import std.string : fromStringz;
            import slint : NativeUnavailable;

            if (err !is null)
            {
                scope (exit)
                    slint_string_free(err);
                string msg = fromStringz(err).idup;
                throw new NativeUnavailable(msg);
            }
        }

        /// Global singleton member names, fetched live from the bridge.
        string[] globalProperties(string global) @system
        {
            import std.string : toStringz;

            string[] names;
            auto n = slint_definition_global_property_count(_handle, global.toStringz);
            names.length = n;
            foreach (i, ref s; names)
                s = fetchGlobalName(&slint_definition_global_property_name, global, i);
            return names;
        }

        string[] globalCallbacks(string global) @system
        {
            import std.string : toStringz;

            string[] names;
            auto n = slint_definition_global_callback_count(_handle, global.toStringz);
            names.length = n;
            foreach (i, ref s; names)
                s = fetchGlobalName(&slint_definition_global_callback_name, global, i);
            return names;
        }

        string[] globalFunctions(string global) @system
        {
            import std.string : toStringz;

            string[] names;
            auto n = slint_definition_global_function_count(_handle, global.toStringz);
            names.length = n;
            foreach (i, ref s; names)
                s = fetchGlobalName(&slint_definition_global_function_name, global, i);
            return names;
        }

        private string fetchGlobalName(GlobalNameFn fn, string global, size_t i) @system
        {
            import std.string : fromStringz, toStringz;

            char* raw;
            checkFetch(fn(_handle, global.toStringz, i, &raw));
            if (raw is null)
                return null;
            scope (exit)
                slint_string_free(raw);
            return fromStringz(raw).idup;
        }
    }

    /// Build a metadata-only definition (used in tests and by tooling
    /// that reads compiler output without instantiating).
    this(string name, string[] properties = [], string[] callbacks = [],
        string[] functions = [], string[] globals = []) @safe pure
    {
        _name = name;
        _properties = properties.dup;
        _propertyTypes.length = _properties.length;
        _callbacks = callbacks.dup;
        _functions = functions.dup;
        _globals = globals.dup;
    }

    /// Exported component name.
    string name() const @safe pure nothrow
    {
        return _name;
    }

    /// Property names (dashes normalized to underscores, as in both
    /// official bindings).
    const(string)[] properties() const @safe pure nothrow
    {
        return _properties;
    }

    /// Declared type of a property, or `ValueType.Void` when unknown
    /// (metadata-only definitions carry names alone).
    ValueType propertyType(string prop) const @safe pure nothrow
    {
        foreach (i, p; _properties)
            if (p == prop && i < _propertyTypes.length)
                return _propertyTypes[i];
        return ValueType.Void;
    }

    /// Callback names.
    const(string)[] callbacks() const @safe pure nothrow
    {
        return _callbacks;
    }

    /// Public function names.
    const(string)[] functions() const @safe pure nothrow
    {
        return _functions;
    }

    /// Exported global singleton names.
    const(string)[] globals() const @safe pure nothrow
    {
        return _globals;
    }

    /// Check a `slint.codegen` spec against this metadata: every spec
    /// property/callback must exist. Catches markup/code drift at startup
    /// instead of at first property access.
    bool validateSpec(const(string)[] props, const(string)[] callbacks) const @safe pure nothrow
    {
        bool has(const(string)[] hay, string needle)
        {
            foreach (s; hay)
                if (s == needle)
                    return true;
            return false;
        }

        foreach (p; props)
            if (!has(_properties, p))
                return false;
        foreach (c; callbacks)
            if (!has(_callbacks, c))
                return false;
        return true;
    }

    /// Instantiate the component. Mirrors `ComponentDefinition::create()`.
    ComponentInstance create()
    {
        version (SlintNative)
        {
            import slint : NativeUnavailable;

            if (_handle is null)
                throw new NativeUnavailable("ComponentDefinition has no native handle");
            auto inst = slint_definition_create(_handle);
            if (inst is null)
                throw new NativeUnavailable("slint_definition_create failed for " ~ _name);
            return new ComponentInstance(inst);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(
                "ComponentDefinition.create needs the native Slint runtime; " ~
                "rebuild with -version=SlintNative and link bridge/libslint_d_bridge.");
        }
    }
}

version (SlintNative)
{
private:
    alias CountFn = extern (C) size_t function(SlintDefinition*);
    alias NameFn = extern (C) char* function(SlintDefinition*, size_t, char**);
    alias GlobalNameFn = extern (C) char* function(SlintDefinition*, const(char)*, size_t, char**);
}

/// Normalize a `.slint` identifier the way both official bindings do:
/// dashes become underscores (`my-property` -> `my_property`).
string normalizeProp(string name) @safe pure
{
    import std.array : replace;

    return name.replace("-", "_");
}

///
unittest
{
    assert(normalizeProp("my-property") == "my_property");
    assert(normalizeProp("counter") == "counter");

    auto d = new ComponentDefinition("MainWindow", ["counter"], ["clicked"], ["doubleIt"], [
            "Theme"
        ]);
    assert(d.name == "MainWindow");
    assert(d.properties() == ["counter"]);
    assert(d.propertyType("counter") == ValueType.Void); // names only, no types
    assert(d.propertyType("missing") == ValueType.Void);
    assert(d.callbacks() == ["clicked"]);
    assert(d.functions() == ["doubleIt"]);
    assert(d.globals() == ["Theme"]);
    assert(d.validateSpec(["counter"], ["clicked"]));
    assert(!d.validateSpec(["counter", "stale"], ["clicked"]));
    assert(!d.validateSpec(["counter"], ["stale-cb"]));

    version (SlintNative)
    {
    }
    else
    {
        import std.exception : assertThrown;
        import slint : NativeUnavailable;

        assertThrown!NativeUnavailable(d.create());
    }
}
