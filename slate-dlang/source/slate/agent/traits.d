/// Trait and interface abstractions for declarative MCP component control.
///
/// Combines Dlang's runtime capability interfaces (`McpControllable`,
/// `McpSeekable`, `McpSortable`, `McpFilterable`, `McpExpandable`,
/// `McpDropReceiver`, `McpSelectable`), compile-time Design-by-Introspection
/// (DbI) traits (`isMcpControllable!T`, `isMcpSeekable!T`, ...), and a
/// `mixin template McpControllableMixin` that automatically implements
/// `McpControllable` by reflecting over `@McpState`, `@McpWritable`, and
/// `@McpAction` UDAs.
module slate.agent.traits;

import std.json : JSONValue, JSONType;
import slint.instance : ComponentInstance;
import slate.agent.bridge : SlintUiBridge;
import slate.agent.error : AgentError;
import slate.utils.json : toJsonValue, fromJsonValue;

/// Marks a field or getter method as exported in MCP `get_state` snapshots.
struct McpState
{
    string key;
}

/// Marks a field or 1-parameter setter method as mutable via MCP `setProperty`.
struct McpWritable
{
    string key;
}

/// Marks a method as invokable via MCP controller actions.
struct McpAction
{
    string name;
}

// -- Runtime Capability Interfaces ----------------------------------------

/// Core interface every MCP-controllable component controller implements.
interface McpControllable
{
    /// Namespace prefix under which properties are exposed (e.g. `"media"`).
    string mcpNamespace() const @safe pure nothrow;

    /// List of capability trait names satisfied by this controller
    /// (e.g. `["controllable", "seekable"]`).
    string[] mcpCapabilities() const @safe pure nothrow;

    /// Capture a JSON object of all `@McpState` properties on this controller.
    JSONValue mcpSnapshot();

    /// Mutate a `@McpWritable` property by relative key (e.g. `"volume"`).
    /// Returns `true` if the key matched a writable property, `false` if unknown.
    /// Throws `AgentError` or `Exception` if validation fails.
    bool mcpSetProperty(string key, JSONValue value);

    /// Restore a previously captured snapshot (used by transactional rollback).
    void mcpRestoreSnapshot(JSONValue snapshot);

    /// Invoke a `@McpAction` method by name.
    JSONValue mcpInvokeAction(string action, JSONValue params);
}

/// Optional lifecycle interface for controllers binding to a Slint `ComponentInstance`.
interface McpBindable
{
    void bindToSlint(ComponentInstance instance, SlintUiBridge bridge = null);
}

/// Media/timeline seek capability trait.
interface McpSeekable
{
    void seekTo(double seconds);
    double positionSeconds() const @safe pure nothrow;
    double durationSeconds() const @safe pure nothrow;
}

/// Tabular / list sorting capability trait.
interface McpSortable
{
    void sortByColumn(size_t columnIndex, string direction);
}

/// Search / query filtering capability trait.
interface McpFilterable
{
    void setFilterQuery(string query);
    string filterQuery() const @safe pure nothrow;
}

/// Hierarchical / collapsible expansion capability trait.
interface McpExpandable
{
    void toggleExpand(size_t index);
    void expandAll();
    void collapseAll();
}

/// File / payload drop receiver capability trait.
interface McpDropReceiver
{
    bool dropFiles(const(string)[] paths);
}

/// Single/multi item selection capability trait.
interface McpSelectable
{
    void selectIndex(size_t index);
    ptrdiff_t selectedIndex() const @safe pure nothrow;
}

// -- Compile-Time Design-by-Introspection (DbI) Traits --------------------

/// True if `T` has any `@McpState`, `@McpWritable`, or `@McpAction` annotations.
template hasMcpAnnotations(T)
{
    private static bool check()
    {
        import std.traits : hasUDA;

        static foreach (member; __traits(allMembers, T))
        {
            static if (__traits(compiles, __traits(getMember, T.init, member)))
            {
                static if (hasUDA!(__traits(getMember, T, member), McpState)
                    || hasUDA!(__traits(getMember, T, member), McpWritable)
                    || hasUDA!(__traits(getMember, T, member), McpAction))
                {
                    return true;
                }
            }
        }
        return false;
    }

    enum bool hasMcpAnnotations = check();
}

enum bool isMcpControllable(T) = is(T : McpControllable) || hasMcpAnnotations!T;
enum bool isMcpBindable(T)     = is(T : McpBindable) || __traits(compiles, (T t, ComponentInstance i, SlintUiBridge b) { t.bindToSlint(i, b); });
enum bool isMcpSeekable(T)     = is(T : McpSeekable) || __traits(compiles, (T t) { t.seekTo(0.0); double p = t.positionSeconds(); double d = t.durationSeconds(); });
enum bool isMcpSortable(T)     = is(T : McpSortable) || __traits(compiles, (T t) { t.sortByColumn(size_t(0), "asc"); });
enum bool isMcpFilterable(T)   = is(T : McpFilterable) || __traits(compiles, (T t) { t.setFilterQuery(""); string q = t.filterQuery(); });
enum bool isMcpExpandable(T)   = is(T : McpExpandable) || __traits(compiles, (T t) { t.toggleExpand(size_t(0)); });
enum bool isMcpDropReceiver(T) = is(T : McpDropReceiver) || __traits(compiles, (T t) { bool ok = t.dropFiles(["a"]); });
enum bool isMcpSelectable(T)   = is(T : McpSelectable) || __traits(compiles, (T t) { t.selectIndex(size_t(0)); });

/// Compile-time capability discovery for any controller type `T`.
string[] detectMcpCapabilities(T)() @safe pure nothrow
{
    import std.traits : Unqual;

    alias U = Unqual!T;
    string[] caps = ["controllable"];
    static if (isMcpBindable!U)
        caps ~= "bindable";
    static if (isMcpSeekable!U)
        caps ~= "seekable";
    static if (isMcpSortable!U)
        caps ~= "sortable";
    static if (isMcpFilterable!U)
        caps ~= "filterable";
    static if (isMcpExpandable!U)
        caps ~= "expandable";
    static if (isMcpDropReceiver!U)
        caps ~= "drop-receiver";
    static if (isMcpSelectable!U)
        caps ~= "selectable";
    return caps;
}

// -- Compile-Time Reflection Helpers for McpControllableMixin -------------

private template resolveMcpStateKey(alias symbol, string fallback)
{
    import std.traits : getUDAs;

    alias udas = getUDAs!(symbol, McpState);
    static if (udas.length > 0 && udas[0].key.length > 0)
        enum string resolveMcpStateKey = udas[0].key;
    else
        enum string resolveMcpStateKey = fallback;
}

private template resolveMcpWritableKey(alias symbol, string fallback)
{
    import std.traits : getUDAs;

    alias udas = getUDAs!(symbol, McpWritable);
    static if (udas.length > 0 && udas[0].key.length > 0)
        enum string resolveMcpWritableKey = udas[0].key;
    else static if (getUDAs!(symbol, McpState).length > 0 && getUDAs!(symbol, McpState)[0].key.length > 0)
        enum string resolveMcpWritableKey = getUDAs!(symbol, McpState)[0].key;
    else
        enum string resolveMcpWritableKey = fallback;
}

private template resolveMcpActionName(alias symbol, string fallback)
{
    import std.traits : getUDAs;

    alias udas = getUDAs!(symbol, McpAction);
    static if (udas.length > 0 && udas[0].name.length > 0)
        enum string resolveMcpActionName = udas[0].name;
    else
        enum string resolveMcpActionName = fallback;
}

/// Introspect all `@McpState` fields and zero-arg methods on `target`.
JSONValue introspectMcpSnapshot(T)(auto ref T target)
{
    import std.traits : hasUDA, isCallable, Parameters, ReturnType;

    JSONValue[string] obj;
    static foreach (member; __traits(allMembers, T))
    {
        static if (member != "this" && member != "__ctor" && member != "__dtor"
            && __traits(compiles, __traits(getMember, target, member)))
        {
            static if (hasUDA!(__traits(getMember, T, member), McpState))
            {{
                enum string key = resolveMcpStateKey!(__traits(getMember, T, member), member);
                static if (isCallable!(__traits(getMember, T, member)))
                {
                    static if (Parameters!(__traits(getMember, T, member)).length == 0
                        && !is(ReturnType!(__traits(getMember, T, member)) == void))
                    {
                        obj[key] = toJsonValue(__traits(getMember, target, member)());
                    }
                }
                else
                {
                    obj[key] = toJsonValue(__traits(getMember, target, member));
                }
            }}
        }
    }
    return JSONValue(obj);
}

/// Mutate a `@McpWritable` field or 1-arg setter on `target`.
bool introspectMcpSetProperty(T)(auto ref T target, string key, JSONValue value)
{
    import std.traits : hasUDA, isCallable, Parameters;

    static foreach (member; __traits(allMembers, T))
    {
        static if (member != "this" && member != "__ctor" && member != "__dtor"
            && __traits(compiles, __traits(getMember, target, member)))
        {
            static if (hasUDA!(__traits(getMember, T, member), McpWritable))
            {{
                enum string writableKey = resolveMcpWritableKey!(__traits(getMember, T, member), member);
                if (key == writableKey || key == member)
                {
                    static if (isCallable!(__traits(getMember, T, member)))
                    {
                        alias Params = Parameters!(__traits(getMember, T, member));
                        static if (Params.length == 1)
                        {
                            auto parsed = fromJsonValue!(Params[0])(value);
                            __traits(getMember, target, member)(parsed);
                            return true;
                        }
                    }
                    else
                    {
                        alias FieldType = typeof(__traits(getMember, target, member));
                        auto prevVal = __traits(getMember, target, member);
                        __traits(getMember, target, member) = fromJsonValue!FieldType(value);
                        static if (__traits(hasMember, T, "onMcpPropertyChanged"))
                        {
                            scope (failure)
                                __traits(getMember, target, member) = prevVal;
                            target.onMcpPropertyChanged(writableKey);
                        }
                        return true;
                    }
                }
            }}
        }
    }
    return false;
}

/// Restore `@McpWritable` and `@McpState` fields and 1-arg setters from `snapshot` on `target`.
void introspectMcpRestoreSnapshot(T)(auto ref T target, JSONValue snapshot)
{
    import std.traits : hasUDA, isCallable, Parameters;

    if (snapshot.type != JSONType.object)
        return;

    static if (__traits(hasMember, T, "onMcpRestoreSnapshot"))
    {
        target.onMcpRestoreSnapshot(snapshot);
        return;
    }

    static foreach (member; __traits(allMembers, T))
    {
        static if (member != "this" && member != "__ctor" && member != "__dtor"
            && __traits(compiles, __traits(getMember, target, member)))
        {
            static if (hasUDA!(__traits(getMember, T, member), McpState)
                || hasUDA!(__traits(getMember, T, member), McpWritable))
            {{
                enum string stateKey = resolveMcpStateKey!(__traits(getMember, T, member), member);
                enum string writableKey = resolveMcpWritableKey!(__traits(getMember, T, member), member);

                static if (!isCallable!(__traits(getMember, T, member)))
                {
                    const(JSONValue)* valPtr = (stateKey in snapshot.object);
                    if (valPtr is null)
                        valPtr = (writableKey in snapshot.object);
                    if (valPtr !is null)
                    {
                        alias FieldType = typeof(__traits(getMember, target, member));
                        __traits(getMember, target, member) = fromJsonValue!FieldType(*valPtr);
                    }
                }
                else static if (hasUDA!(__traits(getMember, T, member), McpWritable))
                {
                    alias Params = Parameters!(__traits(getMember, T, member));
                    static if (Params.length == 1)
                    {
                        const(JSONValue)* valPtr = (writableKey in snapshot.object);
                        if (valPtr is null)
                            valPtr = (stateKey in snapshot.object);
                        if (valPtr !is null)
                        {
                            try
                            {
                                auto parsed = fromJsonValue!(Params[0])(*valPtr);
                                __traits(getMember, target, member)(parsed);
                            }
                            catch (Exception)
                            {
                            }
                        }
                    }
                }
            }}
        }
    }
    static if (__traits(hasMember, T, "onMcpPropertyChanged"))
    {
        target.onMcpPropertyChanged("*");
    }
}

/// Invoke a `@McpAction` method on `target`.
JSONValue introspectMcpInvokeAction(T)(auto ref T target, string action, JSONValue params)
{
    import std.traits : hasUDA, isCallable, Parameters, ReturnType;

    static foreach (member; __traits(allMembers, T))
    {
        static if (member != "this" && member != "__ctor" && member != "__dtor"
            && __traits(compiles, __traits(getMember, target, member)))
        {
            static if (hasUDA!(__traits(getMember, T, member), McpAction)
                && isCallable!(__traits(getMember, T, member)))
            {{
                enum string actName = resolveMcpActionName!(__traits(getMember, T, member), member);
                if (action == actName || action == member)
                {
                    alias Params = Parameters!(__traits(getMember, T, member));
                    alias Ret = ReturnType!(__traits(getMember, T, member));
                    static if (Params.length == 0)
                    {
                        static if (is(Ret == void))
                        {
                            __traits(getMember, target, member)();
                            return JSONValue(["status": JSONValue("ok")]);
                        }
                        else
                        {
                            return toJsonValue(__traits(getMember, target, member)());
                        }
                    }
                    else static if (Params.length == 1)
                    {
                        auto arg0 = fromJsonValue!(Params[0])(params);
                        static if (is(Ret == void))
                        {
                            __traits(getMember, target, member)(arg0);
                            return JSONValue(["status": JSONValue("ok")]);
                        }
                        else
                        {
                            return toJsonValue(__traits(getMember, target, member)(arg0));
                        }
                    }
                }
            }}
        }
    }
    throw AgentError.actionNotFound(action);
}

/// Mixin template injecting the full `McpControllable` implementation into
/// any class or struct using compile-time UDA introspection.
mixin template McpControllableMixin(string defaultNamespace = "component")
{
    static import std.json;
    private string _mcpNamespace = defaultNamespace;

    void setMcpNamespace(string ns) @safe pure nothrow
    {
        _mcpNamespace = ns;
    }

    string mcpNamespace() const @safe pure nothrow
    {
        return _mcpNamespace;
    }

    string[] mcpCapabilities() const @safe pure nothrow
    {
        import slate.agent.traits : detectMcpCapabilities;

        return detectMcpCapabilities!(typeof(this))();
    }

    std.json.JSONValue mcpSnapshot()
    {
        import slate.agent.traits : introspectMcpSnapshot;

        return introspectMcpSnapshot(this);
    }

    bool mcpSetProperty(string key, std.json.JSONValue value)
    {
        import slate.agent.traits : introspectMcpSetProperty;

        return introspectMcpSetProperty(this, key, value);
    }

    void mcpRestoreSnapshot(std.json.JSONValue snapshot)
    {
        import slate.agent.traits : introspectMcpRestoreSnapshot;

        introspectMcpRestoreSnapshot(this, snapshot);
    }

    std.json.JSONValue mcpInvokeAction(string action, std.json.JSONValue params = std.json.JSONValue.init)
    {
        import slate.agent.traits : introspectMcpInvokeAction;

        return introspectMcpInvokeAction(this, action, params);
    }
}

/// Adapter wrapping a pointer to a value-type `struct` with MCP annotations
/// into a heap-allocated `McpControllable` interface reference.
final class StructMcpAdapter(T) : McpControllable
if (is(T == struct))
{
    private T* _target;
    private string _namespace;

    this(T* target, string namespace) @safe pure nothrow
    {
        _target = target;
        _namespace = namespace;
    }

    override string mcpNamespace() const @safe pure nothrow
    {
        return _namespace;
    }

    override string[] mcpCapabilities() const @safe pure nothrow
    {
        return detectMcpCapabilities!T();
    }

    override JSONValue mcpSnapshot()
    {
        return introspectMcpSnapshot(*_target);
    }

    override bool mcpSetProperty(string key, JSONValue value)
    {
        return introspectMcpSetProperty(*_target, key, value);
    }

    override void mcpRestoreSnapshot(JSONValue snapshot)
    {
        introspectMcpRestoreSnapshot(*_target, snapshot);
    }

    override JSONValue mcpInvokeAction(string action, JSONValue params)
    {
        return introspectMcpInvokeAction(*_target, action, params);
    }
}

/// Wrap a struct pointer into `McpControllable`.
McpControllable asMcpControllable(T)(T* target, string namespace)
if (is(T == struct))
{
    return new StructMcpAdapter!T(target, namespace);
}

// Spec: Scenario T1: Declarative MCP controller traits, mixin reflection, and snapshot restore
/// Example:
unittest
{
    static final class SampleSeekableController : McpControllable, McpSeekable
    {
        mixin McpControllableMixin!"sample_player";

        @McpState("playing") @McpWritable("playing")
        bool playing = false;

        private double _pos = 0.0;
        private double _dur = 120.0;

        @McpState("position_seconds")
        override double positionSeconds() const @safe pure nothrow
        {
            return _pos;
        }

        @McpState("duration_seconds")
        override double durationSeconds() const @safe pure nothrow
        {
            return _dur;
        }

        @McpWritable("position_seconds") @McpAction("seek")
        override void seekTo(double seconds)
        {
            if (seconds < 0.0 || seconds > _dur)
                throw AgentError.invalidParams("position_seconds", "out of range");
            _pos = seconds;
        }

        @McpAction("toggle_play")
        bool togglePlay()
        {
            playing = !playing;
            return playing;
        }
    }

    static assert(isMcpControllable!SampleSeekableController);
    static assert(isMcpSeekable!SampleSeekableController);
    static assert(!isMcpSortable!SampleSeekableController);

    auto c = new SampleSeekableController();
    assert(c.mcpNamespace() == "sample_player");
    assert(c.mcpCapabilities() == ["controllable", "seekable"]);

    auto snap = c.mcpSnapshot();
    assert(snap["playing"].boolean == false);
    assert(snap["position_seconds"].floating == 0.0);
    assert(snap["duration_seconds"].floating == 120.0);

    assert(c.mcpSetProperty("position_seconds", JSONValue(45.5)));
    assert(c.positionSeconds() == 45.5);

    auto res = c.mcpInvokeAction("toggle_play", JSONValue.init);
    assert(res.boolean == true && c.playing);

    // Restore snapshot
    c.mcpRestoreSnapshot(snap);
    assert(!c.playing);
    assert(c.positionSeconds() == 0.0);
}
