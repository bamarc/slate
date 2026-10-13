/// D bindings for Slint: public package root.
///
/// Mirrors the module surface of the official bindings:
/// Node (`api/node/typescript/index.ts`) re-exports compiler, components,
/// models, and platform helpers from one entry point; Python
/// (`api/python/slint/slint/__init__.py`) exposes `Compiler`,
/// `Component`, `ListModel`, `Timer`, `Color`/`Brush`, and event-loop
/// functions from `slint`. Importing `slint` in D gives the same surface.
///
/// Idiomatic D layer (this package) talks to the Slint runtime through
/// `slint.capi`, whose symbols are implemented by the Rust cdylib bridge
/// in `bridge/` (built on `slint-interpreter`, exactly like the napi and
/// pyo3 native modules). Builds without `-version=SlintNative` (the
/// default `dub build` / `dub test`) compile and run the pure-D subset;
/// any call that needs the native runtime throws `NativeUnavailable`.
module slint;

public import slint.value;
public import slint.diagnostics;
public import slint.compiler;
public import slint.definition;
public import slint.instance;
public import slint.callback;
public import slint.codegen;
public import slint.model;
public import slint.fiber;
public import slint.eventloop;
public import slint.timer;
public import slint.loader;
public import slint.png;
public import slint.window;
public import slint.capi;

/// Thrown when a binding call requires the native Slint runtime but this
/// build does not link the bridge (i.e. no `-version=SlintNative`).
class NativeUnavailable : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(msg, file, line);
    }
}
