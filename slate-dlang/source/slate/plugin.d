/// Plugin trait for extending Slate applications.
///
/// Port of `slate_extensions::plugin`, written as canonical D: an
/// `interface` with a default `init` body, exceptions instead of `Result`
/// (`init` throws; duplicates throw `PluginException`), and `cast`-based
/// downcasting instead of `as_any` (D interfaces downcast natively).
module slate.plugin;

/// A named, initializable application extension.
interface Plugin
{
    /// Unique plugin name.
    string name() const;

    /// Called during application initialization; throw to abort.
    /// Mix in `PluginInit` for the no-op default (D interfaces cannot carry
    /// bodies; this is the canonical substitute for Rust's trait default).
    void init();
}

/// Default no-op `init` for plugins without startup work.
mixin template PluginInit()
{
    override void init()
    {
    }
}

/// Thrown by `PluginRegistry.register` for duplicate names.
class PluginException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(msg, file, line);
    }

    static PluginException duplicate(string name, string file = __FILE__, size_t line = __LINE__)
    {
        import std.format : format;

        return new PluginException(format!"plugin '%s' is already registered"(name), file, line);
    }
}

/// Owns initialized plugins by unique name.
class PluginRegistry
{
    private Plugin[] _plugins;

    invariant
    {
        foreach (i; 0 .. _plugins.length)
        {
            assert(_plugins[i] !is null, "Plugin entry in registry must not be null");
            assert(_plugins[i].name().length > 0, "Plugin name must not be empty");
            foreach (j; i + 1 .. _plugins.length)
            {
                assert(_plugins[i].name() != _plugins[j].name(),
                    "Class invariant violated: duplicate plugin name '" ~ _plugins[i].name() ~ "'");
            }
        }
    }

    /// Register after a successful `init`. A duplicate name or a throwing
    /// `init` leaves the registry unchanged.
    void register(P : Plugin)(P plugin)
    in
    {
        assert(plugin !is null, "Cannot register null plugin");
        assert(plugin.name().length > 0, "Plugin name must not be empty");
    }
    out
    {
        assert(getByName(plugin.name()) !is null, "Registered plugin must be retrievable by name");
    }
    do
    {
        auto name = plugin.name();
        if (getByName(name) !is null)
            throw PluginException.duplicate(name);
        // Tentative addition with transactional scope(failure) rollback on init failure
        _plugins ~= plugin;
        scope (failure)
            _plugins = _plugins[0 .. $ - 1];
        plugin.init();
    }

    /// Unregister a plugin by name. Returns true if removed, false if not found.
    bool unregister(string name)
    in
    {
        assert(name.length > 0, "Plugin name to unregister must not be empty");
    }
    out (result)
    {
        assert(getByName(name) is null, "Unregistered plugin must not be present in registry");
    }
    do
    {
        foreach (i, p; _plugins)
        {
            if (p.name() == name)
            {
                _plugins = _plugins[0 .. i] ~ _plugins[i + 1 .. $];
                return true;
            }
        }
        return false;
    }

    /// First plugin of type `P`, or null.
    P get(P : Plugin)()
    {
        foreach (p; _plugins)
            if (auto q = cast(P) p)
                return q;
        return null;
    }

    /// Plugin by name, or null.
    Plugin getByName(string name)
    {
        foreach (p; _plugins)
            if (p.name() == name)
                return p;
        return null;
    }

    size_t length() const @safe pure nothrow
    {
        return _plugins.length;
    }

    bool empty() const @safe pure nothrow
    {
        return _plugins.length == 0;
    }

    /// Clear all registered plugins.
    void clear()
    out
    {
        assert(empty, "Registry must be empty after clear");
    }
    do
    {
        _plugins = null;
    }
}

///
unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;

    static class Counter : Plugin
    {
        mixin PluginInit;

        int n;
        this(int n)
        {
            this.n = n;
        }

        override string name() const
        {
            return "counter";
        }
    }

    static class Failing : Plugin
    {
        override string name() const
        {
            return "failing";
        }

        override void init()
        {
            throw new Exception("nope");
        }
    }

    static class EmptyNamePlugin : Plugin
    {
        mixin PluginInit;

        override string name() const
        {
            return "";
        }
    }

    auto r = new PluginRegistry();
    r.register(new Counter(5));
    assert(r.get!Counter().n == 5);
    assert(r.getByName("counter").name() == "counter");
    assert(r.getByName("zzz") is null);
    assert(r.get!Failing() is null);

    assertThrown!PluginException(r.register(new Counter(2)));
    assert(r.length == 1);
    assert(r.get!Counter().n == 5); // original survives the duplicate

    assertThrown!Exception(r.register(new Failing()));
    assert(r.length == 1); // failed init leaves the registry unchanged
    auto r2 = new PluginRegistry();
    assertThrown!Exception(r2.register(new Failing()));
    assert(r2.empty);
    assert(r2.getByName("failing") is null);

    // Contract verification: null plugin and empty name rejected by preconditions
    assertThrown!AssertError(r.register(cast(Counter) null));
    assertThrown!AssertError(r.register(new EmptyNamePlugin()));

    // Invariant verification: duplicate plugin names actively trigger class invariant
    r._plugins ~= new Counter(99);
    assertThrown!AssertError(r.length);

    // Unregister functionality and contracts
    auto rClean = new PluginRegistry();
    rClean.register(new Counter(10));
    assert(rClean.length == 1);
    assert(rClean.unregister("counter"));
    assert(rClean.empty);
    assert(!rClean.unregister("nonexistent"));
    assertThrown!AssertError(rClean.unregister(""));

    // Clear functionality and contracts
    auto rClear = new PluginRegistry();
    rClear.register(new Counter(42));
    assert(rClear.length == 1);
    rClear.clear();
    assert(rClear.empty);
}
