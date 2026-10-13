/// Live component instances: properties, callbacks, and windows.
///
/// Mirrors `JsComponentInstance` in
/// `api/node/rust/interpreter/component_instance.rs` and
/// `ComponentInstance` in `api/python/slint/interpreter.rs`:
/// typed property getters/setters, callback handlers and invocation
/// (including with arguments), globals access, `show` / `hide` / `run`,
/// and access to the owning definition.
///
/// D handlers are plain delegates registered through `slint.callback`
/// (see its docs for the registry design). Prefer the compile-time
/// wrappers from `slint.codegen` over raw stringly-typed access.
module slint.instance;

import slint.capi;
import slint.value;
import slint.model : Model, ArrayModel;

/// Re-exported so callers get handler types alongside the instance.
public import slint.callback : SlintHandler;

/// A live instance of a compiled Slint component.
class ComponentInstance
{
    version (SlintNative)
    {
    private SlintInstance* _handle;
    private size_t[string] _cbIds;

        /// Wrap a native instance handle (takes ownership).
        this(SlintInstance* handle) @system
        {
            _handle = handle;
        }

        package @property SlintInstance* handle() const @trusted pure nothrow
        {
            return cast(SlintInstance*) _handle;
        }

        ~this() @system
        {
            if (_handle !is null)
            {
                slint_instance_free(_handle);
                _handle = null;
            }
        }

        private void checkError(char* err) @system
        {
            import std.string : fromStringz;

            if (err !is null)
            {
                scope (exit)
                    slint_string_free(err);
                string msg = fromStringz(err).idup;
                throw new SlintCallError(msg);
            }
        }

        private void requireHandle() @system
        {
            import slint : NativeUnavailable;

            if (_handle is null)
                throw new NativeUnavailable("ComponentInstance handle is null");
        }
    }
    else
    {
        /// Metadata-only instance for pure-D builds (tests, tooling).
        this() @safe pure
        {
        }
    }

    /// Read a numeric property. (Node: `getProperty`, Python: attribute read.)
    double getNumber(string name)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            double v;
            checkError(slint_instance_get_number(_handle, name.toStringz, &v));
            return v;
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("getNumber"));
        }
    }

    /// Write a numeric property.
    void setNumber(string name, double value)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            checkError(slint_instance_set_number(_handle, name.toStringz, value));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setNumber"));
        }
    }

    /// Read a string property.
    string getString(string name)
    {
        version (SlintNative)
        {
            import std.string : toStringz, fromStringz;

            requireHandle();
            char* raw;
            checkError(slint_instance_get_string(_handle, name.toStringz, &raw));
            if (raw is null)
                return null;
            scope (exit)
                slint_string_free(raw);
            return fromStringz(raw).idup;
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("getString"));
        }
    }

    /// Write a string property.
    void setString(string name, string value)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            checkError(slint_instance_set_string(_handle, name.toStringz, value.toStringz));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setString"));
        }
    }

    /// Read a boolean property.
    bool getBool(string name)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            int v;
            checkError(slint_instance_get_bool(_handle, name.toStringz, &v));
            return v != 0;
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("getBool"));
        }
    }

    /// Write a boolean property.
    void setBool(string name, bool value)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            checkError(slint_instance_set_bool(_handle, name.toStringz, value ? 1 : 0));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setBool"));
        }
    }

    /// Read an arbitrary property as a dynamically-typed `Value`.
    Value getProperty(string name)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            SlintValue outVal;
            checkError(slint_instance_get_property(_handle, name.toStringz, &outVal));
            scope (exit)
                freeSlint(&outVal);
            return fromSlintValue(outVal);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("getProperty"));
        }
    }

    /// Write an arbitrary property from a dynamically-typed `Value`.
    void setProperty(string name, Value value)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            SlintValue sv = toSlintValue(value);
            scope (exit)
                freeSlint(&sv);
            checkError(slint_instance_set_property(_handle, name.toStringz, &sv));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setProperty"));
        }
    }

    /// Read a color property.
    Color getColor(string name)
    {
        auto v = getProperty(name);
        return v.color;
    }

    /// Write a color property.
    void setColor(string name, Color color)
    {
        setProperty(name, Value.of(color));
    }

    /// Read a brush property.
    Brush getBrush(string name)
    {
        auto v = getProperty(name);
        return v.brush;
    }

    /// Write a brush property.
    void setBrush(string name, Brush brush)
    {
        setProperty(name, Value.of(brush));
    }

    /// Read a struct property.
    SlintStruct getStruct(string name)
    {
        auto v = getProperty(name);
        return v.structFields;
    }

    /// Write a struct property.
    void setStruct(string name, SlintStruct s)
    {
        setProperty(name, Value.of(s));
    }

    /// Read a model property as a typed `ArrayModel!T`.
    ArrayModel!T getModel(T)(string name)
    {
        version (SlintNative)
        {
            import std.string : toStringz;
            import slint.capi : slint_instance_get_property, SlintValue, SlintTag, SlintModelRaw;
            import slint.model : Model, ArrayModel;

            requireHandle();
            SlintValue outVal;
            checkError(slint_instance_get_property(_handle, name.toStringz, &outVal));
            if (outVal.tag != SlintTag.Model || outVal.handle is null)
            {
                scope (exit)
                    freeSlint(&outVal);
                throw new Exception("Property '" ~ name ~ "' is not a model");
            }
            auto raw = cast(SlintModelRaw*) outVal.handle;
            outVal.handle = null;
            scope (exit)
                freeSlint(&outVal);
            return new ArrayModel!T(raw, true);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("getModel"));
        }
    }

    /// Write a model property from a `Model!T`.
    void setModel(T)(string name, Model!T model)
    {
        version (SlintNative)
        {
            import std.string : toStringz;
            import slint.capi : slint_instance_set_property, SlintValue;
            import slint.value : toSlintValue;

            requireHandle();
            SlintValue sv = toSlintValue!T(model);
            scope (exit)
                freeSlint(&sv);
            checkError(slint_instance_set_property(_handle, name.toStringz, &sv));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setModel"));
        }
    }

    /// Write a model property from an array of items.
    void setModel(T)(string name, T[] items)
    {
        version (SlintNative)
        {
            import std.string : toStringz;
            import slint.capi : slint_instance_set_property, SlintValue;
            import slint.value : toSlintValue;

            requireHandle();
            SlintValue sv = toSlintValue!T(items);
            scope (exit)
                freeSlint(&sv);
            checkError(slint_instance_set_property(_handle, name.toStringz, &sv));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setModel"));
        }
    }

    /// Read an array property as a D array.
    T[] getArray(T)(string name)
    {
        version (SlintNative)
        {
            auto m = getModel!T(name);
            T[] result;
            auto n = m.rowCount();
            result.reserve(n);
            foreach (i; 0 .. n)
                result ~= m.rowData(i);
            return result;
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("getArray"));
        }
    }



    /// Emit a callback, passing arguments and returning its result.
    /// (Node: calling the callback property; Python: calling the callback
    /// attribute.) The no-argument form `invoke("clicked")` keeps working
    /// through the default argument.
    Value invoke(string name, Value[] args = [])
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            if (args.length == 0)
            {
                checkError(slint_instance_invoke(_handle, name.toStringz));
                return Value.nil();
            }
            SlintValue[] cargs;
            cargs.length = args.length;
            foreach (i, ref a; args)
                cargs[i] = toSlint(a);
            SlintValue ret = SlintValue.voidValue();
            scope (exit)
            {
                freeSlint(&ret);
                foreach (ref c; cargs)
                    freeSlint(&c);
            }
            checkError(slint_instance_invoke_values(_handle, name.toStringz,
                cargs.ptr, cargs.length, &ret));
            return fromSlint(ret);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("invoke"));
        }
    }

    /// Handle a callback with a D delegate receiving the callback
    /// arguments and returning its result. Re-registering replaces the
    /// previous handler. (Python: assigning the callback attribute /
    /// `@slint.callback`.)
    void setCallback(string name, SlintHandler handler)
    {
        version (SlintNative)
        {
            import std.string : toStringz;
            import slint.callback : callbacks, slintDCallbackShim;

            requireHandle();
            size_t id = callbacks.put(handler);
            scope (failure)
                callbacks.remove(id);
            checkError(slint_instance_set_callback(_handle, name.toStringz,
                &slintDCallbackShim, id));
            _cbIds[name] = id;
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setCallback"));
        }
    }

    /// Convenience overload for handlers ignoring arguments and results.
    void setCallback(string name, void delegate() handler)
    {
        setCallback(name, (const(Value)[]) {
            handler();
            return Value.nil();
        });
    }

    /// Register a handler deregistered automatically when the returned
    /// guard goes out of scope (struct destructor as `defer`). A handler
    /// shadowed this way is *restored* on scope exit, so temporary
    /// overrides compose: tests, dialogs, and modal states can borrow a
    /// callback without disturbing its owner.
    ScopedCallback scopedCallback(string name, SlintHandler handler)
    {
        version (SlintNative)
        {
            import std.string : toStringz;
            import slint.callback : callbacks, slintDCallbackShim;

            requireHandle();
            size_t id = callbacks.put(handler);
            scope (failure)
                callbacks.remove(id);
            checkError(slint_instance_set_callback(_handle, name.toStringz,
                &slintDCallbackShim, id));
            return ScopedCallback(_handle, name, id, _cbIds.get(name, 0));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("scopedCallback"));
        }
    }

    /// Read a numeric property of a global singleton.
    /// (Python: `get_global_property` via generated global classes.)
    double getGlobalNumber(string global, string name)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            double v;
            checkError(slint_instance_get_global_number(_handle, global.toStringz,
                name.toStringz, &v));
            return v;
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("getGlobalNumber"));
        }
    }

    /// Write a numeric property of a global singleton.
    void setGlobalNumber(string global, string name, double value)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            checkError(slint_instance_set_global_number(_handle, global.toStringz,
                name.toStringz, value));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setGlobalNumber"));
        }
    }

    /// Read a string property of a global singleton.
    string getGlobalString(string global, string name)
    {
        version (SlintNative)
        {
            import std.string : toStringz, fromStringz;

            requireHandle();
            char* raw;
            checkError(slint_instance_get_global_string(_handle, global.toStringz,
                name.toStringz, &raw));
            if (raw is null)
                return null;
            scope (exit)
                slint_string_free(raw);
            return fromStringz(raw).idup;
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("getGlobalString"));
        }
    }

    /// Write a string property of a global singleton.
    void setGlobalString(string global, string name, string value)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            checkError(slint_instance_set_global_string(_handle, global.toStringz,
                name.toStringz, value.toStringz));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setGlobalString"));
        }
    }

    /// Read a boolean property of a global singleton.
    bool getGlobalBool(string global, string name)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            int v;
            checkError(slint_instance_get_global_bool(_handle, global.toStringz,
                name.toStringz, &v));
            return v != 0;
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("getGlobalBool"));
        }
    }

    /// Write a boolean property of a global singleton.
    void setGlobalBool(string global, string name, bool value)
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            checkError(slint_instance_set_global_bool(_handle, global.toStringz,
                name.toStringz, value ? 1 : 0));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setGlobalBool"));
        }
    }

    /// Invoke a callback on a global singleton.
    Value invokeGlobal(string global, string name, Value[] args = [])
    {
        version (SlintNative)
        {
            import std.string : toStringz;

            requireHandle();
            SlintValue[] cargs;
            cargs.length = args.length;
            foreach (i, ref a; args)
                cargs[i] = toSlint(a);
            SlintValue ret = SlintValue.voidValue();
            scope (exit)
            {
                freeSlint(&ret);
                foreach (ref c; cargs)
                    freeSlint(&c);
            }
            checkError(slint_instance_invoke_global(_handle, global.toStringz,
                name.toStringz, cargs.ptr, cargs.length, &ret));
            return fromSlint(ret);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("invokeGlobal"));
        }
    }

    /// Handle a callback on a global singleton.
    void setGlobalCallback(string global, string name, SlintHandler handler)
    {
        version (SlintNative)
        {
            import std.string : toStringz;
            import slint.callback : callbacks, slintDCallbackShim;

            requireHandle();
            size_t id = callbacks.put(handler);
            scope (failure)
                callbacks.remove(id);
            checkError(slint_instance_set_global_callback(_handle, global.toStringz,
                name.toStringz, &slintDCallbackShim, id));
            _cbIds[global ~ "::" ~ name] = id;
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("setGlobalCallback"));
        }
    }

    /// Show the component's window.
    void show()
    {
        version (SlintNative)
        {
            requireHandle();
            slint_instance_show(_handle);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("show"));
        }
    }

    /// Hide the component's window.
    void hide()
    {
        version (SlintNative)
        {
            requireHandle();
            slint_instance_hide(_handle);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("hide"));
        }
    }

    /// Show the window, spin the event loop, hide on return.
    /// (Python: `Component.run`.)
    void run()
    {
        version (SlintNative)
        {
            requireHandle();
            checkError(slint_instance_run(_handle));
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("run"));
        }
    }

    /// Offscreen snapshot of the current window content (RGBA8), using the
    /// same technique as Slate's screenshot tool: the software renderer
    /// paints on demand, so no display server or running event loop is
    /// needed. Pair with `slint.png.encodePngRgba` to save the shot.
    Snapshot snapshot()
    {
        version (SlintNative)
        {
            requireHandle();
            ubyte* pixels;
            size_t len;
            uint w;
            uint h;
            checkError(slint_instance_snapshot(_handle, &pixels, &len, &w, &h));
            scope (exit)
                slint_bytes_free(pixels, len);
            if (pixels is null || len != cast(size_t) w * h * 4)
                throw new SlintCallError("snapshot returned a malformed pixel buffer");
            return Snapshot(w, h, pixels[0 .. len].dup);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(nativeOnly("snapshot"));
        }
    }

    /// Returns the window handle associated with this component instance.
    @property auto window() @safe
    {
        import slint.window : WindowHandle;
        return WindowHandle(this);
    }

    /// Dumps the hierarchical UI tree of this component as a JSON string.
    string dumpUiTree()
    {
        version (SlintNative)
        {
            requireHandle();
            char* outJson = null;
            checkError(slint_instance_dump_ui_tree(_handle, &outJson));
            scope (exit)
            {
                if (outJson !is null)
                    slint_string_free(outJson);
            }
            if (outJson is null)
                return "{}";

            import core.stdc.string : strlen;
            return outJson[0 .. strlen(outJson)].idup;
        }
        else
        {
            import slint : NativeUnavailable;
            throw new NativeUnavailable(nativeOnly("dumpUiTree"));
        }
    }

    /// Search for an element by ID, label, or accessible role.
    bool findElement(string target, out ElementInfo info)
    {
        version (SlintNative)
        {
            requireHandle();
            import std.string : toStringz;
            import core.stdc.string : strlen;

            char* outId = null;
            char* outRole = null;
            char* outLabel = null;
            char* outValue = null;
            double outX = 0, outY = 0, outW = 0, outH = 0;
            int outEnabled = 0, outVisible = 0;

            checkError(slint_instance_find_element(
                _handle, target.toStringz,
                &outId, &outRole, &outLabel, &outValue,
                &outX, &outY, &outW, &outH,
                &outEnabled, &outVisible
            ));
            scope (exit)
            {
                if (outId !is null) slint_string_free(outId);
                if (outRole !is null) slint_string_free(outRole);
                if (outLabel !is null) slint_string_free(outLabel);
                if (outValue !is null) slint_string_free(outValue);
            }

            if (outRole is null)
                return false;

            info.id = outId !is null ? outId[0 .. strlen(outId)].idup : "";
            info.role = outRole[0 .. strlen(outRole)].idup;
            info.label = outLabel !is null ? outLabel[0 .. strlen(outLabel)].idup : "";
            info.value = outValue !is null ? outValue[0 .. strlen(outValue)].idup : "";
            info.x = outX;
            info.y = outY;
            info.width = outW;
            info.height = outH;
            info.enabled = outEnabled != 0;
            info.visible = outVisible != 0;

            return true;
        }
        else
        {
            import slint : NativeUnavailable;
            throw new NativeUnavailable(nativeOnly("findElement"));
        }
    }

    /// Triggers the default accessibility action or synthetic click on the target element.
    void invokeElementAction(string target)
    {
        version (SlintNative)
        {
            requireHandle();
            import std.string : toStringz;

            checkError(slint_instance_invoke_element_action(_handle, target.toStringz));
        }
        else
        {
            import slint : NativeUnavailable;
            throw new NativeUnavailable(nativeOnly("invokeElementAction"));
        }
    }

    private static string nativeOnly(string what) @safe pure
    {
        return "ComponentInstance." ~ what ~
            " needs the native Slint runtime; " ~
            "rebuild with -version=SlintNative and link bridge/libslint_d_bridge.";
    }
}

/// Information about an introspected UI element.
struct ElementInfo
{
    string id;
    string role;
    string label;
    string value;
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
    bool enabled = true;
    bool visible = true;
}

/// RAII guard for a callback handler: leaving scope deregisters the D
/// delegate and repoints Slint at the previously shadowed handler, if it
/// is still registered. Non-copyable; move it, don't copy it.
/// Do not mix scoped and manual `setCallback` calls on one callback while
/// a guard is live (last writer wins on scope exit).
struct ScopedCallback
{
    @disable this(this);

    private size_t _id;
    private bool _armed;

    version (SlintNative)
    {
        private SlintInstance* _handle;
        private string _name;
        private size_t _old;
    }

    /// Wrap an already-registered handler id (see `setCallback` path).
    this(size_t id) @safe pure nothrow
    {
        _id = id;
        _armed = true;
    }

    version (SlintNative)
    {
        private this(SlintInstance* handle, string name, size_t id, size_t old) @safe pure nothrow
        {
            _handle = handle;
            _name = name;
            _id = id;
            _old = old;
            _armed = true;
        }
    }

    ~this() @system nothrow
    {
        // Same-thread rule (see `slint.callback` docs) makes touching the
        // registry here sound; teardown never throws by construction.
        if (!_armed)
            return;
        _armed = false;
        try
        {
            import slint.callback : callbacks;

            callbacks.remove(_id);
            version (SlintNative)
            {
                if (_old != 0 && _handle !is null && callbacks.has(_old))
                {
                    import std.string : toStringz;
                    import slint.callback : slintDCallbackShim;

                    char* err = slint_instance_set_callback(_handle, _name.toStringz,
                        &slintDCallbackShim, _old);
                    if (err !is null)
                        slint_string_free(err);
                }
            }
        }
        catch (Throwable)
        {
        }
    }

    /// Stop guarding without deregistering (the handler stays live).
    void release() @safe pure nothrow
    {
        _armed = false;
    }
}

/// Error returned by the Slint runtime for a failed property or callback
/// call. Mirrors `GetPropertyError` / `SetPropertyError` / `InvokeError`
/// in `slint_interpreter` (surfaced in Node as napi errors, in Python as
/// `PyGetPropertyError` etc. in `api/python/slint/errors.rs`).
class SlintCallError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(msg, file, line);
    }
}

/// Offscreen window snapshot: dimensions plus RGBA8 pixels, row-major.
struct Snapshot
{
    uint width;
    uint height;
    ubyte[] pixels;
}

///
unittest
{
    // Pure-D: every native path raises NativeUnavailable (now also with
    // argument lists, callback delegates, and globals).
    version (SlintNative)
    {
    }
    else
    {
        import std.exception : assertThrown;
        import slint : NativeUnavailable;

        auto i = new ComponentInstance();
        assertThrown!NativeUnavailable(i.getNumber("counter"));
        assertThrown!NativeUnavailable(i.setNumber("counter", 1));
        assertThrown!NativeUnavailable(i.getString("title"));
        assertThrown!NativeUnavailable(i.setString("title", "x"));
        assertThrown!NativeUnavailable(i.getBool("enabled"));
        assertThrown!NativeUnavailable(i.setBool("enabled", true));
        assertThrown!NativeUnavailable(i.invoke("clicked"));
        assertThrown!NativeUnavailable(i.invoke("add", [Value.of(1.0), Value.of(2.0)]));
        assertThrown!NativeUnavailable(i.setCallback("clicked", (const(Value)[]) {
            return Value.nil();
        }));
        assertThrown!NativeUnavailable(i.setCallback("clicked", () {}));
        assertThrown!NativeUnavailable(i.getGlobalNumber("Theme", "x"));
        assertThrown!NativeUnavailable(i.setGlobalNumber("Theme", "x", 1));
        assertThrown!NativeUnavailable(i.getGlobalString("Theme", "x"));
        assertThrown!NativeUnavailable(i.setGlobalString("Theme", "x", "y"));
        assertThrown!NativeUnavailable(i.getGlobalBool("Theme", "x"));
        assertThrown!NativeUnavailable(i.setGlobalBool("Theme", "x", true));
        assertThrown!NativeUnavailable(i.invokeGlobal("Theme", "reset"));
        assertThrown!NativeUnavailable(i.setGlobalCallback("Theme", "reset",
            (const(Value)[]) { return Value.nil(); }));
        assertThrown!NativeUnavailable(i.show());
        assertThrown!NativeUnavailable(i.hide());
        assertThrown!NativeUnavailable(i.run());

        // Rich property accessors
        assertThrown!NativeUnavailable(i.getProperty("bg"));
        assertThrown!NativeUnavailable(i.setProperty("bg", Value.of(Color.fromRgb(255, 0, 0))));
        assertThrown!NativeUnavailable(i.getColor("bg"));
        assertThrown!NativeUnavailable(i.setColor("bg", Color.fromRgb(255, 0, 0)));
        assertThrown!NativeUnavailable(i.getBrush("fill"));
        assertThrown!NativeUnavailable(i.setBrush("fill", Brush.transparent()));
        assertThrown!NativeUnavailable(i.getStruct("user"));
        assertThrown!NativeUnavailable(i.setStruct("user", SlintStruct.init));

        // Model and array accessors (DEFECT P2.4)
        assertThrown!NativeUnavailable(i.getModel!int("numbers"));
        assertThrown!NativeUnavailable(i.setModel!int("numbers", [1, 2, 3]));
        assertThrown!NativeUnavailable(i.getArray!int("numbers"));

        // Window controls & introspection
        import slint.window : PointerEvent, PointerButton, KeyEvent;
        assertThrown!NativeUnavailable(i.window.size);
        assertThrown!NativeUnavailable(i.window.setSize(100, 100));
        assertThrown!NativeUnavailable(i.window.isVisible);
        assertThrown!NativeUnavailable(i.window.dispatchPointer(PointerEvent.moved, 10, 10));
        assertThrown!NativeUnavailable(i.window.dispatchKey(KeyEvent.pressed, "a"));
        assertThrown!NativeUnavailable(i.dumpUiTree());
        ElementInfo info;
        assertThrown!NativeUnavailable(i.findElement("test", info));
        assertThrown!NativeUnavailable(i.invokeElementAction("test"));
    }
}

version (SlintNative)
{
    /// Native integration test for rich properties on ComponentInstance
    unittest
    {
        import slint.compiler : Compiler;

        auto c = new Compiler();
        auto res = c.buildFromSource(
            "export struct UserData {\n" ~
            "    name: string,\n" ~
            "    age: int,\n" ~
            "}\n" ~
            "export component RichInstanceTest inherits Window {\n" ~
            "    in-out property <color> bg: #ff0000;\n" ~
            "    in-out property <brush> fill: #00000000;\n" ~
            "    in-out property <UserData> user: { name: \"init\", age: 20 };\n" ~
            "    callback add(int, int) -> int;\n" ~
            "}\n"
        );
        auto comp = res.component("RichInstanceTest");
        assert(comp !is null);
        auto inst = comp.create();
        assert(inst !is null);

        // Color property
        auto col = inst.getColor("bg");
        assert(col.red == 255 && col.green == 0 && col.blue == 0 && col.alpha == 255);
        inst.setColor("bg", Color.fromRgb(0, 255, 0));
        assert(inst.getColor("bg") == Color.fromRgb(0, 255, 0));
        assert(inst.getProperty("bg").color == Color.fromRgb(0, 255, 0));

        // Brush property (transparent and solid)
        auto b = inst.getBrush("fill");
        assert(b.isTransparent());
        inst.setBrush("fill", Brush.solid(Color.fromRgb(0, 0, 255)));
        assert(!inst.getBrush("fill").isTransparent());
        assert(inst.getBrush("fill").color == Color.fromRgb(0, 0, 255));

        // Struct property
        auto u = inst.getStruct("user");
        assert(u["name"].text == "init");
        assert(u["age"].number == 20);

        SlintStruct updated;
        updated["name"] = Value.of("alice");
        updated["age"] = Value.of(35.0);
        inst.setStruct("user", updated);

        auto u2 = inst.getStruct("user");
        assert(u2["name"].text == "alice");
        assert(u2["age"].number == 35);

        // Generic getProperty / setProperty
        auto propVal = inst.getProperty("user");
        assert(propVal.type == ValueType.Struct);
        assert(propVal.structFields["name"].text == "alice");

        inst.setProperty("bg", Value.of(Color.fromArgb(128, 10, 20, 30)));
        assert(inst.getColor("bg") == Color.fromArgb(128, 10, 20, 30));

        // Callback with arguments and return value
        inst.setCallback("add", (const(Value)[] args) {
            assert(args.length == 2);
            return Value.of(args[0].number + args[1].number);
        });
        auto addRet = inst.invoke("add", [Value.of(15.0), Value.of(27.0)]);
        assert(addRet.number == 42.0);

        // Invalid property access raises SlintCallError
        import std.exception : assertThrown;

        assertThrown!SlintCallError(inst.getProperty("non_existent_property"));
        assertThrown!SlintCallError(inst.setProperty("non_existent_property", Value.of(1.0)));
    }
}

version (SlintNative)
{
    unittest
    {
        import slint.compiler : Compiler;
        import slint.model : Model, ArrayModel;

        auto compiler = new Compiler();
        auto res = compiler.buildFromSource(
            "export component ModelInstanceTest inherits Window {\n" ~
            "    in-out property <[int]> numbers: [1, 2, 3];\n" ~
            "    in-out property <[string]> names: [\"alice\", \"bob\"];\n" ~
            "}\n"
        );
        auto comp = res.component("ModelInstanceTest");
        assert(comp !is null);
        auto inst = comp.create();
        assert(inst !is null);

        // getModel for integers
        auto numModel = inst.getModel!int("numbers");
        assert(numModel !is null);
        assert(numModel.rowCount() == 3);
        assert(numModel.rowData(0) == 1);
        assert(numModel.rowData(1) == 2);
        assert(numModel.rowData(2) == 3);

        // live mutation via model pushes to native Slint model
        numModel.push(42);
        assert(numModel.rowCount() == 4);
        assert(numModel.rowData(3) == 42);

        // re-fetching model reflects mutation
        auto numModel2 = inst.getModel!int("numbers");
        assert(numModel2.rowCount() == 4);
        assert(numModel2.rowData(3) == 42);

        // setModel with ArrayModel
        auto newNums = new ArrayModel!int([10, 20, 30, 40]);
        inst.setModel!int("numbers", newNums);
        auto numModel3 = inst.getModel!int("numbers");
        assert(numModel3.rowCount() == 4);
        assert(numModel3.rowData(0) == 10);
        assert(numModel3.rowData(3) == 40);

        // string model roundtrip & setModel with array
        inst.setModel("names", ["charlie", "david", "eve"]);
        auto nameModel = inst.getModel!string("names");
        assert(nameModel.rowCount() == 3);
        assert(nameModel.rowData(0) == "charlie");
        assert(nameModel.rowData(1) == "david");
        assert(nameModel.rowData(2) == "eve");

        // mutation via setRowData and remove
        nameModel.setRowData(1, "dan");
        assert(nameModel.rowData(1) == "dan");
        nameModel.remove(0);
        assert(nameModel.rowCount() == 2);
        assert(nameModel.rowData(0) == "dan");
        assert(nameModel.rowData(1) == "eve");
    }

    /// Native integration test for Window controls, input dispatch, and Element Introspection
    unittest
    {
        import slint.compiler : Compiler;
        import slint.window : WindowHandle, PointerEvent, PointerButton, KeyEvent;
        import std.string : indexOf;

        auto c = new Compiler();
        auto res = c.buildFromSource(
            "export component WindowAndIntroTest inherits Window {\n" ~
            "    width: 300px;\n" ~
            "    height: 200px;\n" ~
            "    in-out property <int> clicks: 0;\n" ~
            "    in-out property <int> action_count: 0;\n" ~
            "    touch := TouchArea {\n" ~
            "        x: 10px; y: 10px; width: 100px; height: 50px;\n" ~
            "        clicked => { root.clicks += 1; }\n" ~
            "    }\n" ~
            "    btn := TouchArea {\n" ~
            "        x: 10px; y: 70px; width: 100px; height: 50px;\n" ~
            "        accessible-role: button;\n" ~
            "        accessible-label: \"SubmitButton\";\n" ~
            "        accessible-action-default => { root.action_count += 1; }\n" ~
            "        clicked => { root.action_count += 1; }\n" ~
            "    }\n" ~
            "}\n"
        );
        auto comp = res.component("WindowAndIntroTest");
        assert(comp !is null);
        auto inst = comp.create();
        assert(inst !is null);

        // Window size get / set
        auto win = inst.window;
        auto sz = win.size;
        assert(sz.width == 300.0);
        assert(sz.height == 200.0);

        win.setSize(400, 250);
        auto sz2 = win.size;
        assert(sz2.width == 400.0);
        assert(sz2.height == 250.0);

        // Event dispatching via window.click
        assert(inst.getNumber("clicks") == 0);
        win.click(50, 30);
        assert(inst.getNumber("clicks") == 1);

        // Element Introspection: dumpUiTree
        string json = inst.dumpUiTree();
        assert(json.length > 0);
        assert(json.indexOf("button") != -1);
        assert(json.indexOf("SubmitButton") != -1);

        // Element Introspection: findElement
        ElementInfo info;
        bool found = inst.findElement("SubmitButton", info);
        assert(found);
        assert(info.role == "button");
        assert(info.label == "SubmitButton");
        assert(info.width == 100.0);
        assert(info.height == 50.0);

        // Accessibility action execution
        assert(inst.getNumber("action_count") == 0);
        inst.invokeElementAction("SubmitButton");
        assert(inst.getNumber("action_count") == 1);
    }
}



