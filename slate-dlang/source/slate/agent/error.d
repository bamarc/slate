/// Typed errors for the Slate agent layer.
///
/// Port of `slate_agent::error`: all 22 failure modes with identical
/// human messages, stable snake_case codes, and the MCP error JSON shape
/// (`{code, message, details}`). D adaptation: one exception class with a
/// `Kind` discriminant and static factories (mirroring Rust's constructors),
/// instead of a 22-variant enum — `catch (AgentError)` stays exhaustive and
/// `kind` switches stay total via `final switch`.
module slate.agent.error;

import std.json : JSONValue;
import slate.utils.json : JsonSerializable;

/// Element candidate listed in an ambiguous-target error.
struct Candidate
{
    string reference;
    string role;
    string name;

    mixin JsonSerializable;
}

/// All agent failure modes (inspection, execution, event-loop sync, dispatch).
class AgentError : Exception
{
    enum Kind
    {
        elementNotFound,
        timeout,
        windowUnavailable,
        windowClosed,
        eventLoopUnavailable,
        uiChannelClosed,
        uiPanic,
        dispatchFailed,
        renderError,
        stateError,
        invalidOperation,
        serialization,
        protocol,
        internal,
        staleRef,
        ambiguousTarget,
        notInteractable,
        unsupportedAction,
        invalidParams,
        actionNotFound,
        actionFailed
    }

    Kind kind;
    string target;
    string reason;
    string reference;
    string action;
    string path;
    string name;
    string[] supported;
    Candidate[] candidates;
    size_t count;

    private this(Kind kind, string message) @safe pure
    {
        super(message);
        this.kind = kind;
    }

    static AgentError elementNotFound(string target, string reason) @safe pure
    {
        import std.format : format;

        auto e = new AgentError(Kind.elementNotFound,
            format!"Element not found: target '%s', reason: %s"(target, reason));
        e.target = target;
        e.reason = reason;
        return e;
    }

    static AgentError timeout(string operation, ulong durationMs) @safe pure
    {
        import std.format : format;

        return new AgentError(Kind.timeout, format!"Operation timed out: Operation '%s' timed out after %sms"(
                operation, durationMs));
    }

    static AgentError windowUnavailable(string reason) @safe pure
    {
        auto e = new AgentError(Kind.windowUnavailable,
            "Window or component handle is unavailable: " ~ reason);
        e.reason = reason;
        return e;
    }

    static AgentError windowClosed() @safe pure
    {
        return new AgentError(Kind.windowClosed, "Window or component has been closed / destroyed");
    }

    static AgentError eventLoopUnavailable(string reason) @safe pure
    {
        return new AgentError(Kind.eventLoopUnavailable, "Slint event loop is unavailable: " ~ reason);
    }

    static AgentError uiChannelClosed() @safe pure
    {
        return new AgentError(Kind.uiChannelClosed, "UI response channel was dropped unexpectedly");
    }

    static AgentError uiPanic(string reason) @safe pure
    {
        return new AgentError(Kind.uiPanic, "UI thread panic intercepted: " ~ reason);
    }

    static AgentError dispatchFailed(string reason) @safe pure
    {
        auto e = new AgentError(Kind.dispatchFailed, "UI event dispatch failed: " ~ reason);
        e.reason = reason;
        return e;
    }

    static AgentError renderError(string reason) @safe pure
    {
        auto e = new AgentError(Kind.renderError, "Render or snapshot error: " ~ reason);
        e.reason = reason;
        return e;
    }

    static AgentError stateError(string reason) @safe pure
    {
        auto e = new AgentError(Kind.stateError, "State query or mutation failed: " ~ reason);
        e.reason = reason;
        return e;
    }

    static AgentError invalidOperation(string reason) @safe pure
    {
        auto e = new AgentError(Kind.invalidOperation, "Invalid operation: " ~ reason);
        e.reason = reason;
        return e;
    }

    static AgentError serialization(string reason) @safe pure
    {
        auto e = new AgentError(Kind.serialization, "Serialization error: " ~ reason);
        e.reason = reason;
        return e;
    }

    static AgentError protocol(string reason) @safe pure
    {
        auto e = new AgentError(Kind.protocol, "Protocol error: " ~ reason);
        e.reason = reason;
        return e;
    }

    static AgentError internal_(string reason) @safe pure
    {
        return new AgentError(Kind.internal, "Internal agent error: " ~ reason);
    }

    static AgentError staleRef(string reference, string reason) @safe pure
    {
        import std.format : format;

        auto e = new AgentError(Kind.staleRef,
            format!"Stale element ref '%s': %s"(reference, reason));
        e.reference = reference;
        e.reason = reason;
        return e;
    }

    static AgentError ambiguousTarget(size_t count, Candidate[] candidates) @safe pure
    {
        import std.format : format;

        auto e = new AgentError(Kind.ambiguousTarget,
            format!"Selector matched %s elements"(count));
        e.count = count;
        e.candidates = candidates.dup;
        return e;
    }

    static AgentError notInteractable(string reference, string reason) @safe pure
    {
        import std.format : format;

        auto e = new AgentError(Kind.notInteractable,
            format!"Element '%s' is not interactable: %s"(reference, reason));
        e.reference = reference;
        e.reason = reason;
        return e;
    }

    static AgentError unsupportedAction(string reference, string action, string[] supported) @safe pure
    {
        import std.format : format;

        auto e = new AgentError(Kind.unsupportedAction,
            format!"Action '%s' unsupported on '%s'; supported: %s"(action, reference, supported));
        e.reference = reference;
        e.action = action;
        e.supported = supported.dup;
        return e;
    }

    static AgentError invalidParams(string path, string message) @safe pure
    {
        import std.format : format;

        auto e = new AgentError(Kind.invalidParams,
            format!"Invalid params at '%s': %s"(path, message));
        e.path = path;
        e.reason = message;
        return e;
    }

    static AgentError actionNotFound(string name) @safe pure
    {
        auto e = new AgentError(Kind.actionNotFound, "Action not found: " ~ name);
        e.name = name;
        return e;
    }

    static AgentError actionFailed(string name, string reason) @safe pure
    {
        import std.format : format;

        auto e = new AgentError(Kind.actionFailed,
            format!"Action '%s' failed: %s"(name, reason));
        e.name = name;
        e.reason = reason;
        return e;
    }

    /// Stable machine-readable code (snake_case), identical to Rust.
    string code() const @safe pure nothrow
    {
        final switch (kind)
        {
        case Kind.elementNotFound:
            return "element_not_found";
        case Kind.timeout:
            return "timeout";
        case Kind.windowUnavailable:
            return "window_unavailable";
        case Kind.windowClosed:
            return "window_closed";
        case Kind.eventLoopUnavailable:
            return "event_loop_unavailable";
        case Kind.uiChannelClosed:
            return "ui_channel_closed";
        case Kind.uiPanic:
            return "ui_panic";
        case Kind.dispatchFailed:
            return "dispatch_failed";
        case Kind.renderError:
            return "render_error";
        case Kind.stateError:
            return "state_error";
        case Kind.invalidOperation:
            return "invalid_operation";
        case Kind.serialization:
            return "serialization_error";
        case Kind.protocol:
            return "protocol_error";
        case Kind.internal:
            return "internal";
        case Kind.staleRef:
            return "stale_ref";
        case Kind.ambiguousTarget:
            return "ambiguous_target";
        case Kind.notInteractable:
            return "not_interactable";
        case Kind.unsupportedAction:
            return "unsupported_action";
        case Kind.invalidParams:
            return "invalid_params";
        case Kind.actionNotFound:
            return "action_not_found";
        case Kind.actionFailed:
            return "action_failed";
        }
    }

    /// MCP error payload: `{code, message, details}` with per-kind details
    /// (null for kinds without named fields, exactly like Rust).
    JSONValue toErrorJson() const @safe
    {
        JSONValue details;
        switch (kind)
        {
        case Kind.elementNotFound:
            details = JSONValue(["target": JSONValue(target), "reason": JSONValue(reason)]);
            break;
        case Kind.windowUnavailable:
        case Kind.dispatchFailed:
        case Kind.renderError:
        case Kind.stateError:
        case Kind.invalidOperation:
        case Kind.serialization:
        case Kind.protocol:
            details = JSONValue(["reason": JSONValue(reason)]);
            break;
        case Kind.staleRef:
        case Kind.notInteractable:
            details = JSONValue(
                ["reference": JSONValue(reference), "reason": JSONValue(reason)]);
            break;
        case Kind.ambiguousTarget:
            {
                JSONValue[] cs;
                foreach (c; candidates)
                    cs ~= c.toJson();
                details = JSONValue(
                    ["count": JSONValue(count), "candidates": JSONValue(cs)]);
            }
            break;
        case Kind.unsupportedAction:
            {
                JSONValue[] ss;
                foreach (s; supported)
                    ss ~= JSONValue(s);
                details = JSONValue(["reference": JSONValue(reference),
                    "action": JSONValue(action), "supported": JSONValue(ss)]);
            }
            break;
        case Kind.invalidParams:
            details = JSONValue(["path": JSONValue(path), "message": JSONValue(reason)]);
            break;
        case Kind.actionNotFound:
            details = JSONValue(["name": JSONValue(name)]);
            break;
        case Kind.actionFailed:
            details = JSONValue(["name": JSONValue(name), "reason": JSONValue(reason)]);
            break;
        default:
            break; // stays JSON null, like Rust's `Value::Null`
        }
        return JSONValue(["code": JSONValue(code()), "message": JSONValue(msg),
            "details": details]);
    }
}

///
unittest
{
    import std.algorithm : map, sort, uniq;
    import std.array : array;
    import std.json : parseJSON;

    // Messages, codes, and JSON shapes match the Rust implementation.
    auto e = AgentError.elementNotFound("#x", "gone");
    assert(e.msg == "Element not found: target '#x', reason: gone");
    assert(e.code() == "element_not_found");
    assert(e.toErrorJson() == parseJSON(
        `{"code":"element_not_found","message":"Element not found: target '#x', reason: gone",` ~
        `"details":{"target":"#x","reason":"gone"}}`));

    auto t = AgentError.timeout("click", 5000);
    assert(t.msg == "Operation timed out: Operation 'click' timed out after 5000ms");
    assert(t.code() == "timeout");
    assert(t.toErrorJson()["details"].type == JSONType.null_);

    assert(AgentError.windowClosed().code() == "window_closed");
    assert(AgentError.uiPanic("x").msg == "UI thread panic intercepted: x");
    assert(AgentError.actionFailed("run", "bad").toErrorJson()["details"]
        == parseJSON(`{"name":"run","reason":"bad"}`));
    assert(AgentError.unsupportedAction("b", "drag", ["click"]).msg
        == "Action 'drag' unsupported on 'b'; supported: [\"click\"]");
    assert(AgentError.ambiguousTarget(2,
        [Candidate("a", "Button", "A")]).toErrorJson()["details"]["count"].get!ulong == 2);
    assert(Candidate.fromJson(Candidate("a", "Button", "A").toJson()) == Candidate("a", "Button", "A"));
    assert(AgentError.internal_("x").code() == "internal");

    // Exhaustiveness: every one of the 21 kinds has a distinct code
    // (matching Rust's 21 variants exactly).
    AgentError.Kind[] kinds = [
        AgentError.Kind.elementNotFound, AgentError.Kind.timeout,
        AgentError.Kind.windowUnavailable, AgentError.Kind.windowClosed,
        AgentError.Kind.eventLoopUnavailable, AgentError.Kind.uiChannelClosed,
        AgentError.Kind.uiPanic, AgentError.Kind.dispatchFailed,
        AgentError.Kind.renderError, AgentError.Kind.stateError,
        AgentError.Kind.invalidOperation, AgentError.Kind.serialization,
        AgentError.Kind.protocol, AgentError.Kind.internal,
        AgentError.Kind.staleRef, AgentError.Kind.ambiguousTarget,
        AgentError.Kind.notInteractable, AgentError.Kind.unsupportedAction,
        AgentError.Kind.invalidParams, AgentError.Kind.actionNotFound,
        AgentError.Kind.actionFailed,
    ];
    assert(kinds.length == 21);
    auto all = kinds.map!(k => (new AgentError(k, "")).code()).array;
    assert(all.sort().uniq.array.length == 21);
}

import std.json : JSONType;
import std.algorithm : map;
