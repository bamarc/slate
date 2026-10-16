/// D callback handlers: registry, FFI shim, and scoped lifetimes.
///
/// Slint invokes UI callbacks on the event-loop thread. A D delegate cannot
/// cross the Rust bridge directly, so handlers live in a process-wide
/// registry keyed by id: D passes `&slintDCallbackShim` plus the id to the
/// bridge (no dynamic symbol export needed), and the shim dispatches back
/// into the registry. This mirrors how Node anchors JS functions on the
/// owning instance (`JsAnchorOwner`) and how Python keeps `Py<PyAny>`
/// callables alive behind its native module.
///
/// Threading follows the Slint rule: register, deregister, and fire only on
/// the event-loop thread, so the registry is deliberately unsynchronized.
/// Lifetime management uses RAII (`ScopedCallback`, D's answer to `defer`)
/// plus `scope(failure)` guards on the registration path.
module slint.callback;

import slint.capi : SlintValue, SlintTag;
import slint.value : Value, fromSlint, toSlint;

/// A callback handler: invoked arguments, returns the callback result.
alias SlintHandler = Value delegate(const(Value)[] args);

private struct Entry
{
    SlintHandler handler;
    bool oneShot;
    string error;
}

final class CallbackRegistry
{
    private Entry[size_t] _entries;
    private size_t _next = 1;

    /// Store a handler; returns its id for the bridge `ctx` parameter.
    size_t put(SlintHandler handler, bool oneShot = false) @safe pure nothrow
    {
        auto id = _next++;
        _entries[id] = Entry(handler, oneShot, null);
        return id;
    }

    /// Store a plain delegate as a void callback.
    size_t putVoid(void delegate() handler, bool oneShot = false) @safe
    {
        return put((const(Value)[]) { handler(); return Value.nil(); }, oneShot);
    }

    void remove(size_t id) @safe pure nothrow
    {
        _entries.remove(id);
    }

    bool has(size_t id) const @safe pure nothrow
    {
        return (id in _entries) !is null;
    }

    /// Last handler error for `id`, cleared on read.
    string takeError(size_t id) @safe pure nothrow
    {
        if (auto e = id in _entries)
        {
            auto msg = e.error;
            e.error = null;
            return msg;
        }
        return null;
    }

    size_t length() const @safe pure nothrow
    {
        return _entries.length;
    }
}

/// Process-wide handler table, same-thread use only (see module docs).
__gshared CallbackRegistry callbacks;

shared static this()
{
    callbacks = new CallbackRegistry();
}

/// FFI entry point called by the bridge. Never throws across the boundary:
/// handler failures are captured per id and the callback yields void.
extern (C) SlintValue slintDCallbackShim(size_t id, const(SlintValue)* args, size_t nargs) nothrow
{
    try
    {
        if (auto e = id in callbacks._entries)
        {
            Value[] argv;
            foreach (i; 0 .. nargs)
                argv ~= fromSlint(args[i]);
            scope (exit)
            {
                if (e.oneShot)
                    callbacks._entries.remove(id);
            }
            return toSlint(e.handler(argv));
        }
        return SlintValue.voidValue();
    }
    catch (Throwable t)
    {
        try
        {
            if (auto e = id in callbacks._entries)
                e.error = t.msg;
        }
        catch (Throwable)
        {
        }
        return SlintValue.voidValue();
    }
}

///
unittest
{
    auto start = callbacks.length;
    size_t seen;
    auto id = callbacks.put((const(Value)[] a) {
        seen = a.length;
        return Value.of(a[0].number + 1);
    });
    assert(callbacks.has(id));

    SlintValue[2] cargs;
    cargs[0] = toSlint(Value.of(41.0));
    cargs[1] = toSlint(Value.of("ignored"));
    auto ret = slintDCallbackShim(id, cargs.ptr, cargs.length);
    assert(seen == 2);
    assert(ret.tag == SlintTag.Number && ret.number == 42);

    // Handler throwing surfaces void + captured error, never escapes.
    auto boom = callbacks.put((const(Value)[]) {
        throw new Exception("kaput");
        return Value.nil();
    });
    assert(slintDCallbackShim(boom, null, 0).tag == SlintTag.Void);
    assert(callbacks.takeError(boom) == "kaput");

    // Unknown id degrades to void.
    assert(slintDCallbackShim(size_t.max, null, 0).tag == SlintTag.Void);

    // One-shot entries deregister after firing.
    auto once = callbacks.put((const(Value)[]) { return Value.nil(); }, true);
    slintDCallbackShim(once, null, 0);
    assert(!callbacks.has(once));

    callbacks.remove(id);
    callbacks.remove(boom);
    assert(callbacks.length == start);
}
