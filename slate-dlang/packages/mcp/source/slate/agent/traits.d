/// Trait and interface abstractions for declarative MCP component control.
///
/// Combines standalone domain capability traits from `slate.traits` with
/// opt-out dynamic compile-time reflection (`@McpIgnore`), zero-intrusion class
/// and struct adapters (`ClassMcpAdapter!T`, `StructMcpAdapter!T`), and the
/// `mixin template McpControllableMixin`.
module slate.agent.traits;

import std.json : JSONValue, JSONType;
import std.traits : hasUDA, isCallable, Parameters, ReturnType, Unqual, getUDAs;
import slate.agent.error : AgentError;
import slate.utils.json : toJsonValue, fromJsonValue;
public import slate.traits;

// Backwards-compatible aliases for legacy Mcp* traits
alias McpPaginated = Paginated;
alias McpSeekable = Seekable;
alias McpSortable = Sortable;
alias McpFilterable = Filterable;
alias McpExpandable = Expandable;
alias McpDropReceiver = DropReceiver;
alias McpSelectable = Selectable;
alias isMcpPaginated = isPaginated;
alias isMcpSeekable = isSeekable;
alias isMcpSortable = isSortable;
alias isMcpFilterable = isFilterable;
alias isMcpExpandable = isExpandable;
alias isMcpDropReceiver = isDropReceiver;
alias isMcpSelectable = isSelectable;
alias isMcpBindable = isBindable;

/// Marks a field or getter method as explicitly exported in MCP snapshots with an alias.
struct McpState
{
    string key;
}

/// Marks a field or 1-parameter setter method as mutable via MCP with an alias.
struct McpWritable
{
    string key;
}

/// Marks a method as invokable via MCP actions with an alias.
struct McpAction
{
    string name;
}

/// Opt-out UDA: marks any public member that should be excluded from MCP snapshots,
/// property mutations, and action invocations.
struct McpIgnore
{
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

    /// Capture a JSON object of all state properties on this controller.
    JSONValue mcpSnapshot();

    /// Mutate a property by relative key (e.g. `"volume"`).
    /// Returns `true` if the key matched a writable property, `false` if unknown.
    /// Throws `AgentError` or `Exception` if validation fails.
    bool mcpSetProperty(string key, JSONValue value);

    /// Restore a previously captured snapshot (used by transactional rollback).
    void mcpRestoreSnapshot(JSONValue snapshot);

    /// Invoke an action method by name.
    JSONValue mcpInvokeAction(string action, JSONValue params);
}

// -- Compile-Time Design-by-Introspection (DbI) Traits --------------------

/// True if `T` has any `@McpState`, `@McpWritable`, or `@McpAction` annotations.
template hasMcpAnnotations(T)
{
    private static bool check()
    {
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

enum bool isMcpControllable(T) = is(T : McpControllable)
    || hasMcpAnnotations!T || is(T == class) || is(T == struct);

/// Compile-time capability discovery for any controller type `T`.
string[] detectMcpCapabilities(T)() @safe pure nothrow
{
    return detectCapabilities!T(true);
}

// -- Compile-Time Member Filtering & Reflection Helpers ------------------

/// Checks whether `member` of `T` is an internal, built-in, private, or ignored symbol.
template isExcludedMcpMember(T, string member)
{
    private static bool check()
    {
        if (member.length == 0)
            return true;
        if (member[0] == '_')
            return true;

        static immutable string[] excluded = [
            "this", "__ctor", "__dtor", "__postblit", "toString", "toHash",
            "opCmp", "opEquals", "Monitor", "factory", "mcpNamespace",
            "setMcpNamespace", "mcpCapabilities", "mcpSnapshot",
            "mcpSetProperty", "mcpRestoreSnapshot", "mcpInvokeAction",
            "onMcpPropertyChanged", "onMcpRestoreSnapshot", "bindToSlint",
            "syncToSlint", "rowModel", "entriesModel", "filteredModel",
            "queueModel", "tracksModel", "markersModel"
        ];
        foreach (ex; excluded)
        {
            if (member == ex)
                return true;
        }

        static if (!__traits(compiles, __traits(getMember, T, member)))
        {
            return true;
        }
        else static if (!__traits(compiles, __traits(getProtection,
                __traits(getMember, T, member))))
        {
            return true;
        }
        else static if (__traits(getProtection, __traits(getMember, T, member)) != "public")
        {
            return true;
        }
        else static if (__traits(compiles, hasUDA!(__traits(getMember, T,
                member), McpIgnore)) && hasUDA!(__traits(getMember, T, member), McpIgnore))
        {
            return true;
        }
        else
        {
            return false;
        }
    }

    enum bool isExcludedMcpMember = check();
}

/// Checks if a member is a zero-arg const getter that returns a non-void type.
template isConstZeroArgGetter(T, string member)
{
    private static bool check()
    {
        static if (!__traits(compiles, __traits(getMember, T.init, member)))
            return false;
        else static if (!isCallable!(__traits(getMember, T, member)))
            return false;
        else static if (Parameters!(__traits(getMember, T, member)).length != 0)
            return false;
        else static if (is(ReturnType!(__traits(getMember, T, member)) == void))
            return false;
        else
        {
            static if (is(T == class))
            {
                return __traits(compiles, (const(T) obj) {
                    auto r = __traits(getMember, obj, member)();
                });
            }
            else
            {
                return __traits(compiles, (const ref T obj) {
                    auto r = __traits(getMember, obj, member)();
                });
            }
        }
    }

    enum bool isConstZeroArgGetter = check();
}

private template resolveMcpStateKey(alias symbol, string fallback)
{
    alias udas = getUDAs!(symbol, McpState);
    static if (udas.length > 0 && udas[0].key.length > 0)
        enum string resolveMcpStateKey = udas[0].key;
    else
        enum string resolveMcpStateKey = fallback;
}

private template resolveMcpWritableKey(alias symbol, string fallback)
{
    alias udas = getUDAs!(symbol, McpWritable);
    static if (udas.length > 0 && udas[0].key.length > 0)
        enum string resolveMcpWritableKey = udas[0].key;
    else
        enum string resolveMcpWritableKey = fallback;
}

private template resolveMcpActionName(alias symbol, string fallback)
{
    alias udas = getUDAs!(symbol, McpAction);
    static if (udas.length > 0 && udas[0].name.length > 0)
        enum string resolveMcpActionName = udas[0].name;
    else
        enum string resolveMcpActionName = fallback;
}

/// Introspect all state properties (fields and zero-arg const getters) on `target`.
JSONValue introspectMcpSnapshot(T)(auto ref T target)
{
    JSONValue[string] obj;
    static foreach (member; __traits(allMembers, T))
    {
        static if (!isExcludedMcpMember!(T, member) && __traits(compiles,
                __traits(getMember, target, member)))
        {
            static if (hasUDA!(__traits(getMember, T, member), McpState))
            {
                {
                    enum string key = resolveMcpStateKey!(__traits(getMember,
                                T, member), camelToSnake(member));
                    static if (isCallable!(__traits(getMember, T, member)))
                    {
                        static if (Parameters!(__traits(getMember, T, member))
                                .length == 0 && !is(ReturnType!(__traits(getMember,
                                    T, member)) == void))
                        {
                            static if (__traits(compiles,
                                    toJsonValue(__traits(getMember, target, member)())))
                                obj[key] = toJsonValue(__traits(getMember, target, member)());
                        }
                    }
                    else
                    {
                        static if (__traits(compiles,
                                toJsonValue(__traits(getMember, target, member))))
                            obj[key] = toJsonValue(__traits(getMember, target, member));
                    }
                }
            }
            else static if (!isCallable!(__traits(getMember, T, member)))
            {
                {
                    static if (__traits(compiles, toJsonValue(__traits(getMember, target, member))))
                    {
                        enum string key = camelToSnake(member);
                        obj[key] = toJsonValue(__traits(getMember, target, member));
                    }
                }
            }
            else static if (isConstZeroArgGetter!(T, member))
            {
                {
                    static if (__traits(compiles,
                            toJsonValue(__traits(getMember, target, member)())))
                    {
                        enum string key = camelToSnake(member);
                        obj[key] = toJsonValue(__traits(getMember, target, member)());
                    }
                }
            }
        }
    }
    return JSONValue(obj);
}

/// Mutate a field or 1-arg setter on `target`.
bool introspectMcpSetProperty(T)(auto ref T target, string key, JSONValue value)
{
    // Pass 1: Prefer callable 1-parameter methods (setters, actions, @McpWritable)
    static foreach (member; __traits(allMembers, T))
    {
        static if (!isExcludedMcpMember!(T, member) && __traits(compiles,
                __traits(getMember, target, member)) && isCallable!(__traits(getMember, T,
                member)) && Parameters!(__traits(getMember, T, member)).length == 1)
        {
            {
                static if (hasUDA!(__traits(getMember, T, member), McpWritable))
                {
                    enum string writableKey = resolveMcpWritableKey!(__traits(getMember,
                                T, member), camelToSnake(member));
                    if (key == writableKey || key == camelToSnake(member) || key == member)
                    {
                        alias Params = Parameters!(__traits(getMember, T, member));
                        auto parsed = fromJsonValue!(Params[0])(value);
                        __traits(getMember, target, member)(parsed);
                        static if (__traits(hasMember, T, "onMcpPropertyChanged"))
                            target.onMcpPropertyChanged(writableKey);
                        return true;
                    }
                }
                else static if (member == "goToPage")
                {
                    if (key == "current_page" || key == "go_to_page" || key == "goToPage")
                    {
                        alias Params = Parameters!(__traits(getMember, T, member));
                        auto parsed = fromJsonValue!(Params[0])(value);
                        __traits(getMember, target, member)(parsed);
                        static if (__traits(hasMember, T, "onMcpPropertyChanged"))
                            target.onMcpPropertyChanged("current_page");
                        return true;
                    }
                }
                else static if (member == "seekTo")
                {
                    if (key == "position_seconds" || key == "seek_to" || key == "seekTo")
                    {
                        alias Params = Parameters!(__traits(getMember, T, member));
                        auto parsed = fromJsonValue!(Params[0])(value);
                        __traits(getMember, target, member)(parsed);
                        static if (__traits(hasMember, T, "onMcpPropertyChanged"))
                            target.onMcpPropertyChanged("position_seconds");
                        return true;
                    }
                }
                else static if (member == "selectIndex")
                {
                    if (key == "selected_index" || key == "select_index" || key == "selectIndex")
                    {
                        alias Params = Parameters!(__traits(getMember, T, member));
                        if ((value.type == JSONType.integer
                                && value.integer < 0) || value.type == JSONType.null_)
                        {
                            static if (__traits(hasMember, T, "clearSelection"))
                                target.clearSelection();
                        }
                        else
                        {
                            auto parsed = fromJsonValue!(Params[0])(value);
                            __traits(getMember, target, member)(parsed);
                        }
                        static if (__traits(hasMember, T, "onMcpPropertyChanged"))
                            target.onMcpPropertyChanged("selected_index");
                        return true;
                    }
                }
                else static if (member.length > 3 && member[0 .. 3] == "set"
                        && member[3] >= 'A' && member[3] <= 'Z')
                {
                    enum string propKey = setterToPropertyKey(member);
                    if (key == propKey || key == ("is_" ~ propKey)
                            || key == camelToSnake(member) || key == member)
                    {
                        alias Params = Parameters!(__traits(getMember, T, member));
                        auto parsed = fromJsonValue!(Params[0])(value);
                        __traits(getMember, target, member)(parsed);
                        static if (__traits(hasMember, T, "onMcpPropertyChanged"))
                            target.onMcpPropertyChanged(propKey);
                        return true;
                    }
                }
            }
        }
    }

    // Pass 2: Fall back to mutable fields
    static foreach (member; __traits(allMembers, T))
    {
        static if (!isExcludedMcpMember!(T, member) && __traits(compiles,
                __traits(getMember, target, member))
                && !isCallable!(__traits(getMember, T, member)) && __traits(compiles, {
                    __traits(getMember, target, member) = __traits(getMember, target, member);
                }))
        {
            {
                enum string writableKey = resolveMcpWritableKey!(__traits(getMember,
                            T, member), camelToSnake(member));
                static if (hasUDA!(__traits(getMember, T, member), McpWritable))
                {
                    if (key == writableKey || key == camelToSnake(member) || key == member)
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
                else
                {
                    enum string setterName = "set" ~ cast(char)(member[0] >= 'a'
                                && member[0] <= 'z' ? member[0] - ('a' - 'A') : member[0])
                        ~ member[1 .. $];
                    static if (!__traits(hasMember, T, setterName))
                    {
                        if (key == writableKey || key == camelToSnake(member) || key == member)
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
                }
            }
        }
    }
    return false;
}

/// Restore fields and 1-arg setters from `snapshot` on `target`.
void introspectMcpRestoreSnapshot(T)(auto ref T target, JSONValue snapshot)
{
    if (snapshot.type != JSONType.object)
        return;

    static if (__traits(hasMember, T, "onMcpRestoreSnapshot"))
    {
        target.onMcpRestoreSnapshot(snapshot);
        return;
    }
    else
    {
        // Pass 1: Restore via 1-arg methods
        static foreach (member; __traits(allMembers, T))
        {
            static if (!isExcludedMcpMember!(T, member) && __traits(compiles,
                    __traits(getMember, target, member)) && isCallable!(__traits(getMember, T,
                    member)) && Parameters!(__traits(getMember, T, member)).length == 1)
            {
                {
                    static if (hasUDA!(__traits(getMember, T, member),
                            McpWritable) || (member.length > 3 && member[0 .. 3] == "set"
                            && member[3] >= 'A' && member[3] <= 'Z') || (member == "goToPage")
                            || (member == "seekTo") || (member == "selectIndex"))
                    {
                        enum string propKey = (member == "goToPage") ? "current_page" : (member == "seekTo"
                                    ? "position_seconds" : (member == "selectIndex"
                                        ? "selected_index" : setterToPropertyKey(member)));
                        enum string writableKey = resolveMcpWritableKey!(__traits(getMember,
                                    T, member), propKey);
                        enum string stateKey = resolveMcpStateKey!(__traits(getMember,
                                    T, member), propKey);

                        const(JSONValue)* valPtr = (propKey in snapshot.object);
                        if (valPtr is null)
                            valPtr = (writableKey in snapshot.object);
                        if (valPtr is null)
                            valPtr = (stateKey in snapshot.object);
                        if (valPtr is null)
                            valPtr = (camelToSnake(member) in snapshot.object);
                        if (valPtr is null)
                            valPtr = (member in snapshot.object);
                        if (valPtr is null)
                            valPtr = (("is_" ~ propKey) in snapshot.object);

                        if (valPtr !is null)
                        {
                            alias Params = Parameters!(__traits(getMember, T, member));
                            try
                            {
                                static if (member == "selectIndex")
                                {
                                    if (valPtr.type == JSONType.integer && valPtr.integer < 0)
                                    {
                                        static if (__traits(hasMember, T, "clearSelection"))
                                            target.clearSelection();
                                    }
                                    else if (valPtr.type == JSONType.null_)
                                    {
                                        static if (__traits(hasMember, T, "clearSelection"))
                                            target.clearSelection();
                                    }
                                    else
                                    {
                                        auto parsed = fromJsonValue!(Params[0])(*valPtr);
                                        __traits(getMember, target, member)(parsed);
                                    }
                                }
                                else
                                {
                                    auto parsed = fromJsonValue!(Params[0])(*valPtr);
                                    __traits(getMember, target, member)(parsed);
                                }
                            }
                            catch (Exception)
                            {
                            }
                        }
                    }
                }
            }
        }

        // Pass 2: Restore via fields
        static foreach (member; __traits(allMembers, T))
        {
            static if (!isExcludedMcpMember!(T, member) && __traits(compiles,
                    __traits(getMember, target, member))
                    && !isCallable!(__traits(getMember, T, member)) && __traits(compiles, {
                        __traits(getMember, target, member) = __traits(getMember, target, member);
                    }))
            {
                {
                    enum string setterName = "set" ~ cast(char)(member[0] >= 'a'
                                && member[0] <= 'z' ? member[0] - ('a' - 'A') : member[0])
                        ~ member[1 .. $];
                    static if (hasUDA!(__traits(getMember, T, member),
                            McpWritable) || !__traits(hasMember, T, setterName))
                    {
                        enum string stateKey = resolveMcpStateKey!(__traits(getMember,
                                    T, member), camelToSnake(member));
                        enum string writableKey = resolveMcpWritableKey!(__traits(getMember,
                                    T, member), camelToSnake(member));

                        const(JSONValue)* valPtr = (stateKey in snapshot.object);
                        if (valPtr is null)
                            valPtr = (writableKey in snapshot.object);
                        if (valPtr is null)
                            valPtr = (camelToSnake(member) in snapshot.object);
                        if (valPtr is null)
                            valPtr = (member in snapshot.object);

                        if (valPtr !is null)
                        {
                            alias FieldType = typeof(__traits(getMember, target, member));
                            try
                            {
                                __traits(getMember, target, member) = fromJsonValue!FieldType(
                                        *valPtr);
                            }
                            catch (Exception)
                            {
                            }
                        }
                    }
                }
            }
        }

        static if (__traits(hasMember, T, "onMcpPropertyChanged"))
        {
            target.onMcpPropertyChanged("*");
        }
    }
}

/// Invoke a callable action method on `target`.
JSONValue introspectMcpInvokeAction(T)(auto ref T target, string action, JSONValue params)
{
    static foreach (member; __traits(allMembers, T))
    {
        static if (!isExcludedMcpMember!(T, member) && __traits(compiles,
                __traits(getMember, target, member)) && isCallable!(__traits(getMember, T, member)))
        {
            {
                enum string actName = resolveMcpActionName!(__traits(getMember,
                            T, member), camelToSnake(member));
                if (action == actName || action == camelToSnake(member) || action == member)
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
                        else static if (__traits(compiles,
                                toJsonValue(__traits(getMember, target, member)())))
                        {
                            return toJsonValue(__traits(getMember, target, member)());
                        }
                    }
                    else static if (Params.length == 1)
                    {
                        Params[0] arg0;
                        if (params.type == JSONType.array && params.array.length >= 1)
                        {
                            arg0 = fromJsonValue!(Params[0])(params.array[0]);
                        }
                        else if (params.type == JSONType.object)
                        {
                            import std.traits : ParameterIdentifierTuple;

                            alias ParamNames = ParameterIdentifierTuple!(__traits(getMember,
                                    T, member));
                            static if (ParamNames.length > 0 && ParamNames[0].length > 0)
                            {
                                if (auto p = ParamNames[0] in params.object)
                                    arg0 = fromJsonValue!(Params[0])(*p);
                                else if (auto pSnake = camelToSnake(ParamNames[0]) in params.object)
                                    arg0 = fromJsonValue!(Params[0])(*pSnake);
                                else if (auto p0 = "arg0" in params.object)
                                    arg0 = fromJsonValue!(Params[0])(*p0);
                                else if (params.object.length == 1)
                                {
                                    foreach (_, v; params.object)
                                        arg0 = fromJsonValue!(Params[0])(v);
                                }
                                else
                                    arg0 = fromJsonValue!(Params[0])(params);
                            }
                            else
                            {
                                arg0 = fromJsonValue!(Params[0])(params);
                            }
                        }
                        else
                        {
                            arg0 = fromJsonValue!(Params[0])(params);
                        }

                        static if (is(Ret == void))
                        {
                            __traits(getMember, target, member)(arg0);
                            return JSONValue(["status": JSONValue("ok")]);
                        }
                        else static if (__traits(compiles,
                                toJsonValue(__traits(getMember, target, member)(arg0))))
                        {
                            return toJsonValue(__traits(getMember, target, member)(arg0));
                        }
                    }
                    else static if (Params.length == 2)
                    {
                        Params[0] arg0;
                        Params[1] arg1;
                        if (params.type == JSONType.array && params.array.length >= 2)
                        {
                            arg0 = fromJsonValue!(Params[0])(params.array[0]);
                            arg1 = fromJsonValue!(Params[1])(params.array[1]);
                        }
                        else if (params.type == JSONType.object)
                        {
                            import std.traits : ParameterIdentifierTuple;

                            alias ParamNames = ParameterIdentifierTuple!(__traits(getMember,
                                    T, member));
                            bool found0 = false;
                            bool found1 = false;

                            static if (ParamNames.length >= 2)
                            {
                                if (auto p0 = ParamNames[0] in params.object)
                                {
                                    arg0 = fromJsonValue!(Params[0])(*p0);
                                    found0 = true;
                                }
                                else if (auto p0Snake = camelToSnake(ParamNames[0]) in params
                                        .object)
                                {
                                    arg0 = fromJsonValue!(Params[0])(*p0Snake);
                                    found0 = true;
                                }
                                if (auto p1 = ParamNames[1] in params.object)
                                {
                                    arg1 = fromJsonValue!(Params[1])(*p1);
                                    found1 = true;
                                }
                                else if (auto p1Snake = camelToSnake(ParamNames[1]) in params
                                        .object)
                                {
                                    arg1 = fromJsonValue!(Params[1])(*p1Snake);
                                    found1 = true;
                                }
                            }
                            if (!found0)
                            {
                                if (auto p = "arg0" in params.object)
                                {
                                    arg0 = fromJsonValue!(Params[0])(*p);
                                    found0 = true;
                                }
                            }
                            if (!found1)
                            {
                                if (auto p = "arg1" in params.object)
                                {
                                    arg1 = fromJsonValue!(Params[1])(*p);
                                    found1 = true;
                                }
                            }
                            if (!found0 || !found1)
                                throw AgentError.invalidParams(action,
                                        "2-argument action requires parameters or array of 2 elements");
                        }
                        else
                        {
                            throw AgentError.invalidParams(action,
                                    "2-argument action requires parameters object or array");
                        }

                        static if (is(Ret == void))
                        {
                            __traits(getMember, target, member)(arg0, arg1);
                            return JSONValue(["status": JSONValue("ok")]);
                        }
                        else static if (__traits(compiles,
                                toJsonValue(__traits(getMember, target, member)(arg0, arg1))))
                        {
                            return toJsonValue(__traits(getMember, target, member)(arg0, arg1));
                        }
                    }
                }
            }
        }
    }
    throw AgentError.actionNotFound(action);
}

/// Mixin template injecting the full `McpControllable` implementation into
/// any class or struct using compile-time member introspection.
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

    std.json.JSONValue mcpInvokeAction(string action,
            std.json.JSONValue params = std.json.JSONValue.init)
    {
        import slate.agent.traits : introspectMcpInvokeAction;

        return introspectMcpInvokeAction(this, action, params);
    }
}

/// Adapter wrapping a plain D `class` instance into a heap-allocated `McpControllable`.
final class ClassMcpAdapter(T) : McpControllable
        if (is(T == class) && !is(T : McpControllable))
{
    private T _target;
    private string _namespace;

    this(T target, string namespace) @safe pure nothrow
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
        return introspectMcpSnapshot(_target);
    }

    override bool mcpSetProperty(string key, JSONValue value)
    {
        return introspectMcpSetProperty(_target, key, value);
    }

    override void mcpRestoreSnapshot(JSONValue snapshot)
    {
        introspectMcpRestoreSnapshot(_target, snapshot);
    }

    override JSONValue mcpInvokeAction(string action, JSONValue params)
    {
        return introspectMcpInvokeAction(_target, action, params);
    }
}

/// Adapter wrapping a pointer to a value-type `struct` into a heap-allocated `McpControllable`.
final class StructMcpAdapter(T) : McpControllable if (is(T == struct))
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

/// Adapt an existing `McpControllable` reference.
McpControllable asMcpControllable(T)(T target, string namespace = "")
        if (is(T : McpControllable))
{
    static if (__traits(hasMember, target, "setMcpNamespace"))
    {
        if (namespace.length > 0)
            target.setMcpNamespace(namespace);
    }
    return target;
}

/// Wrap a plain D class instance into `McpControllable`.
McpControllable asMcpControllable(T)(T target, string namespace)
        if (is(T == class) && !is(T : McpControllable))
{
    return new ClassMcpAdapter!T(target, namespace);
}

/// Wrap a struct pointer into `McpControllable`.
McpControllable asMcpControllable(T)(T* target, string namespace) if (is(T == struct))
{
    return new StructMcpAdapter!T(target, namespace);
}

// Spec: Scenario T1 & T2: Opt-out dynamic MCP introspection, zero-intrusion adaptation, and @McpIgnore
/// Example:
unittest
{
    // Plain class without McpControllable or UDAs
    static class PlainGrid : Paginated, Sortable
    {
        private size_t _page = 1;
        private size_t _sortCol = 0;
        private string _sortDir = "asc";

        // Plain public fields
        int itemCount = 42;

        // @McpIgnore member should be omitted
        @McpIgnore string internalToken = "secret";

        @McpIgnore void resetToken()
        {
            internalToken = "reset";
        }

        // Paginated implementation (const 0-arg getters & mutating actions)
        override size_t currentPage() const @safe pure nothrow
        {
            return _page;
        }

        override size_t totalPages() const @safe pure nothrow
        {
            return 5;
        }

        override size_t pageSize() const @safe pure nothrow
        {
            return 20;
        }

        override void nextPage() @safe
        {
            _page++;
        }

        override void prevPage() @safe
        {
            if (_page > 1)
                _page--;
        }

        override void goToPage(size_t p) @safe
        {
            _page = p;
        }

        // Sortable implementation (2-parameter action)
        override void sortByColumn(size_t columnIndex, string direction)
        {
            _sortCol = columnIndex;
            _sortDir = direction;
        }

        size_t sortColumn() const @safe pure nothrow
        {
            return _sortCol;
        }

        string sortDirection() const @safe pure nothrow
        {
            return _sortDir;
        }

        // Setter for item count
        void setItemCount(int count)
        {
            itemCount = count;
        }
    }

    auto grid = new PlainGrid();
    McpControllable adapted = asMcpControllable(grid, "plain_grid");
    assert(adapted.mcpNamespace() == "plain_grid");
    assert(adapted.mcpCapabilities() == [
        "controllable", "paginated", "sortable"
    ]);

    // Dynamic snapshot
    auto snap = adapted.mcpSnapshot();
    assert("current_page" in snap.object);
    assert(snap["current_page"].uinteger == 1);
    assert(snap["total_pages"].uinteger == 5);
    assert(snap["page_size"].uinteger == 20);
    assert(snap["item_count"].integer == 42);
    assert(snap["sort_column"].uinteger == 0);
    assert(snap["sort_direction"].str == "asc");
    assert("internal_token" !in snap.object);

    // 0-arg mutating action
    adapted.mcpInvokeAction("next_page", JSONValue.init);
    assert(grid.currentPage() == 2);

    // 1-arg action
    adapted.mcpInvokeAction("go_to_page", JSONValue(4));
    assert(grid.currentPage() == 4);

    // 2-arg action via JSON array
    adapted.mcpInvokeAction("sort_by_column", JSONValue([
            JSONValue(3), JSONValue("desc")
    ]));
    assert(grid.sortColumn() == 3);
    assert(grid.sortDirection() == "desc");

    // Dynamic setter mutation via setterToPropertyKey ("item_count" -> setItemCount)
    assert(adapted.mcpSetProperty("item_count", JSONValue(99)));
    assert(grid.itemCount == 99);

    // Restore snapshot
    adapted.mcpRestoreSnapshot(snap);
    assert(grid.currentPage() == 1);
    assert(grid.itemCount == 42);

    // W1: @McpIgnore member cannot be set or invoked
    assert(!adapted.mcpSetProperty("internal_token", JSONValue("hack")));
    bool threw = false;
    try
    {
        adapted.mcpInvokeAction("reset_token", JSONValue.init);
    }
    catch (AgentError)
    {
        threw = true;
    }
    assert(threw);
}

// Spec: Security Defect S-2: Boolean is* getter + set* setter pairing and rollback via McpRestoreSnapshot
/// Example:
unittest
{
    static class PlainAudio
    {
        private bool _muted = false;

        bool isMuted() const @safe pure nothrow
        {
            return _muted;
        }

        void setMuted(bool m)
        {
            _muted = m;
        }
    }

    auto audio = new PlainAudio();
    McpControllable adapted = asMcpControllable(audio, "audio");

    auto snap = adapted.mcpSnapshot();
    assert(snap["is_muted"].boolean == false);

    assert(adapted.mcpSetProperty("is_muted", JSONValue(true)));
    assert(audio.isMuted() == true);

    adapted.mcpRestoreSnapshot(snap);
    assert(audio.isMuted() == false);
}
