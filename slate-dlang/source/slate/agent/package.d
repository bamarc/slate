/// Slate agent automation: engine, bridge, protocols, and builders.
///
/// D port of `slate_agent` (core engine surface): data models, typed
/// errors, subsystem interfaces with UFCS defaults, built-in
/// implementations, the UI-thread bridge, protocol seams, and assembly.
/// Slint-wired backends, ACP, and semantic helpers follow once `slint-d`
/// exposes element-query APIs.
module slate.agent;

public import slate.agent.model;
public import slate.agent.error;
public import slate.agent.engine;
public import slate.agent.protocol;
public import slate.agent.bridge;
public import slate.agent.builder;
public import slate.agent.fiber;
