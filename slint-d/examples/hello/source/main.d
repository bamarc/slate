/// Hello-world Slint application in D.
///
/// Native path (built with `-version=SlintNative` and the bridge linked):
/// loads `app.slint` through a compile-time-generated wrapper, bumps the
/// counter from a D callback, and runs the window.
/// Pure-D path (default `dub run`): prints the setup hint and demonstrates
/// the runtime-free API (`Value`, `ArrayModel`, fibers) instead.
module main;

import std.stdio : writeln, writefln;

import slint;
import slint.codegen : Prop, SlintProps, SlintCallbacks;

struct MainWindow
{
    ComponentInstance _instance;
    mixin SlintProps!(Prop!("counter", double));
    mixin SlintCallbacks!"clicked";
    alias _instance this;
}

void main()
{
    try
    {
        runNative();
    }
    catch (NativeUnavailable e)
    {
        writeln("slint-d: native runtime not linked.");
        writeln("  " ~ e.msg);
        writeln("  Build it with:  cd bridge && cargo build");
        writeln("  Then run with:  dub run --config=native");
        writeln();
        runPureDemo();
    }
}

private void runNative()
{
    auto result = loadFile("app.slint");
    foreach (d; result.diagnostics)
        writeln(d.toString());
    auto def = result.component("MainWindow");
    if (def is null)
    {
        writeln("component MainWindow not found");
        return;
    }
    assert(def.validateSpec(MainWindow.slintPropNames(), MainWindow.slintCallbackNames()));
    auto w = MainWindow(def.create());
    writefln!"counter = %s"(w.counter);
    // Same shape as the Node README example: the button drives the counter.
    w.onClicked(() { w.counter = w.counter + 1; });
    w.run();
}

private void runPureDemo()
{
    auto v = Value.of("hello from slint-d");
    writefln!"value: %s (%s)"(v.text, v.type);
    auto model = new ArrayModel!int([1, 2, 3]);
    model.push(4);
    writefln!"model rows: %s"(model.length);

    // Cooperative fiber task filling the model, stepped by hand.
    auto fill = spawnTask({
        foreach (i; 5 .. 8)
        {
            model.push(i);
            UiTask.yield();
        }
    });
    while (!fill.done)
        fill.step();
    writefln!"after fiber: %s rows"(model.length);
}
