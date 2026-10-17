/// Slate: declarative desktop UI framework in DLang, on Slint.
///
/// D port of the `slate` Rust facade (`slate-rust/lib`): theme modes,
/// background tasks, utilities, platform integration, plugins, the
/// application builder, the compute controller, and the demo workload —
/// against `slint-d` the way `slate` builds on the `slint` crate.
/// Agent automation and MCP (`slate.agent`, `slate.mcp`) follow as the next
/// layer; see the repository README for the layer map.
module slate;

public import slate.log;
public import slate.theme;
public import slate.tasks;
public import slate.utils;
public import slate.platform;
public import slate.plugin;
public import slate.app;
public import slate.controller;
public import slate.demo;
public import slate.agent;
public import slate.agent.slint_backend;
public import slate.mcp;
public import slate.http;
public import slate.quic;
public import slate.components;
public import slate.traits;
public import slate.core;
public import slate.net;
public import slate.ui;

/// Convenience initialization (idempotent logging setup).
alias init = slate.app.slateInit;
