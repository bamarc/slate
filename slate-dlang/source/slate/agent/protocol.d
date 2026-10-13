/// Protocol extension seams for the Slate agent.
///
/// Port of `slate_agent::protocol`: alternative transports (ACP, MCP,
/// gRPC, custom IPC) attach to the engine without touching automation
/// logic. Rust expresses the adapter generically with associated
/// `Config`/`ServerHandle` types; the canonical D mapping is a templated
/// interface with the handle constrained to `ProtocolServerHandle`.
module slate.agent.protocol;

import std.typecons : Nullable;

import slate.agent.engine : AutomationEngine;
import slate.agent.error : AgentError;

/// Lifecycle handle for an attached protocol server.
interface ProtocolServerHandle
{
    /// Whether the server is actively processing requests.
    bool isRunning();

    /// Gracefully stop; throw `AgentError` when shutdown fails.
    void stop();

    /// Local address or endpoint id; null when not applicable.
    Nullable!string localAddr();
}

/// Attaches one protocol to an engine and returns its lifecycle handle.
interface AgentProtocolAdapter(Config, ServerHandle : ProtocolServerHandle)
{
    ServerHandle attach(AutomationEngine engine, Config config);
}

///
unittest
{
    static class DummyHandle : ProtocolServerHandle
    {
        bool stopped;
        override bool isRunning()
        {
            return !stopped;
        }

        override void stop()
        {
            stopped = true;
        }

        override Nullable!string localAddr()
        {
            return Nullable!string.init;
        }
    }

    static class DummyAdapter : AgentProtocolAdapter!(string, DummyHandle)
    {
        string seen;
        override DummyHandle attach(AutomationEngine engine, string config)
        {
            seen = config;
            return new DummyHandle();
        }
    }

    auto adapter = new DummyAdapter();
    auto handle = adapter.attach(null, "cfg");
    assert(adapter.seen == "cfg");
    assert(handle.isRunning());
    assert(handle.localAddr().isNull); // interface default
    handle.stop();
    assert(!handle.isRunning());
}
