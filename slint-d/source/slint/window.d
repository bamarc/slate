/// Window management, sizing, and event dispatching for Slint components.
module slint.window;

import slint.capi;
import slint.instance;
import slint : NativeUnavailable;

/// Represents 2D window dimensions in logical pixels.
struct WindowSize
{
    double width = 0.0;
    double height = 0.0;
}

/// Pointer event type for mouse or touch interaction.
enum PointerEvent
{
    moved = 0,
    pressed = 1,
    released = 2,
    exited = 3,
}

/// Button identifier for pointer press/release events.
enum PointerButton
{
    left = 0,
    right = 1,
    middle = 2,
}

/// Key event type for keyboard input.
enum KeyEvent
{
    pressed = 0,
    released = 1,
}

/// Handle to a component's window for inspection and event dispatching.
struct WindowHandle
{
    private ComponentInstance _instance;

    this(ComponentInstance instance) @safe pure nothrow
    {
        _instance = instance;
    }

    /// Return the logical dimensions of the window.
    @property WindowSize size() const @safe
    {
        version (SlintNative)
        {
            if (_instance is null || _instance.handle is null)
                return WindowSize(0, 0);

            return () @trusted {
                double w = 0.0;
                double h = 0.0;
                char* err = slint_window_get_size(_instance.handle, &w, &h);
                if (err !is null)
                {
                    scope (exit)
                        slint_string_free(err);
                    import core.stdc.string : strlen;
                    string msg = err[0 .. strlen(err)].idup;
                    throw new Exception("slint_window_get_size failed: " ~ msg);
                }
                return WindowSize(w, h);
            }();
        }
        else
        {
            throw new NativeUnavailable("Window operations require native runtime");
        }
    }

    /// Set the logical dimensions of the window.
    @property void size(WindowSize s) @safe
    {
        setSize(s.width, s.height);
    }

    /// Set the logical dimensions of the window.
    void setSize(double width, double height) @safe
    {
        version (SlintNative)
        {
            if (_instance is null || _instance.handle is null)
                return;

            () @trusted {
                char* err = slint_window_set_size(_instance.handle, width, height);
                if (err !is null)
                {
                    scope (exit)
                        slint_string_free(err);
                    import core.stdc.string : strlen;
                    string msg = err[0 .. strlen(err)].idup;
                    throw new Exception("slint_window_set_size failed: " ~ msg);
                }
            }();
        }
        else
        {
            throw new NativeUnavailable("Window operations require native runtime");
        }
    }

    /// Return true if the window is currently visible.
    @property bool isVisible() const @safe
    {
        version (SlintNative)
        {
            if (_instance is null || _instance.handle is null)
                return false;

            return () @trusted {
                int vis = 0;
                char* err = slint_window_is_visible(_instance.handle, &vis);
                if (err !is null)
                {
                    scope (exit)
                        slint_string_free(err);
                    import core.stdc.string : strlen;
                    string msg = err[0 .. strlen(err)].idup;
                    throw new Exception("slint_window_is_visible failed: " ~ msg);
                }
                return vis != 0;
            }();
        }
        else
        {
            throw new NativeUnavailable("Window operations require native runtime");
        }
    }

    /// Dispatch a pointer event to the window at logical coordinate (x, y).
    void dispatchPointer(PointerEvent ev, double x, double y, PointerButton btn = PointerButton.left) @safe
    {
        version (SlintNative)
        {
            if (_instance is null || _instance.handle is null)
                return;

            () @trusted {
                char* err = slint_window_dispatch_pointer(_instance.handle, cast(int) ev, x, y, cast(int) btn);
                if (err !is null)
                {
                    scope (exit)
                        slint_string_free(err);
                    import core.stdc.string : strlen;
                    string msg = err[0 .. strlen(err)].idup;
                    throw new Exception("slint_window_dispatch_pointer failed: " ~ msg);
                }
            }();
        }
        else
        {
            throw new NativeUnavailable("Window operations require native runtime");
        }
    }

    /// Convenience helper to dispatch a complete click (move, press, release).
    void click(double x, double y, PointerButton btn = PointerButton.left) @safe
    {
        dispatchPointer(PointerEvent.moved, x, y, btn);
        dispatchPointer(PointerEvent.pressed, x, y, btn);
        dispatchPointer(PointerEvent.released, x, y, btn);
    }

    /// Dispatch a keyboard event with text.
    void dispatchKey(KeyEvent ev, string text) @safe
    {
        version (SlintNative)
        {
            if (_instance is null || _instance.handle is null)
                return;

            () @trusted {
                import std.string : toStringz;
                char* err = slint_window_dispatch_key(_instance.handle, cast(int) ev, text.toStringz);
                if (err !is null)
                {
                    scope (exit)
                        slint_string_free(err);
                    import core.stdc.string : strlen;
                    string msg = err[0 .. strlen(err)].idup;
                    throw new Exception("slint_window_dispatch_key failed: " ~ msg);
                }
            }();
        }
        else
        {
            throw new NativeUnavailable("Window operations require native runtime");
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

@safe unittest
{
    // Pure D tests for WindowSize, PointerEvent, PointerButton, KeyEvent
    WindowSize sz = WindowSize(800, 600);
    assert(sz.width == 800);
    assert(sz.height == 600);

    assert(cast(int) PointerEvent.moved == 0);
    assert(cast(int) PointerEvent.pressed == 1);
    assert(cast(int) PointerEvent.released == 2);
    assert(cast(int) PointerEvent.exited == 3);

    assert(cast(int) PointerButton.left == 0);
    assert(cast(int) PointerButton.right == 1);
    assert(cast(int) PointerButton.middle == 2);

    assert(cast(int) KeyEvent.pressed == 0);
    assert(cast(int) KeyEvent.released == 1);
}

@safe unittest
{
    // Pure D test: WindowHandle on null instance without native runtime
    version (SlintNative)
    {
    }
    else
    {
        auto wh = WindowHandle(null);
        import std.exception : assertThrown;
        assertThrown!NativeUnavailable(wh.size);
        assertThrown!NativeUnavailable(wh.setSize(100, 100));
        assertThrown!NativeUnavailable(wh.isVisible);
        assertThrown!NativeUnavailable(wh.dispatchPointer(PointerEvent.moved, 10, 10));
        assertThrown!NativeUnavailable(wh.dispatchKey(KeyEvent.pressed, "a"));
    }
}

version (SlintNative)
{
    unittest
    {
        import slint.compiler : Compiler;
        auto c = new Compiler();
        auto res = c.buildFromSource(
            "export component WindowUnitTest inherits Window {\n" ~
            "    width: 350px;\n" ~
            "    height: 250px;\n" ~
            "    in-out property <int> clicks: 0;\n" ~
            "    in-out property <string> key_received: \"\";\n" ~
            "    TouchArea {\n" ~
            "        x: 15px; y: 15px; width: 120px; height: 60px;\n" ~
            "        clicked => { root.clicks += 1; }\n" ~
            "    }\n" ~
            "    forward-focus: ti;\n" ~
            "    ti := TextInput {\n" ~
            "        x: 15px; y: 90px; width: 120px; height: 30px;\n" ~
            "        edited => { root.key_received = self.text; }\n" ~
            "    }\n" ~
            "}\n"
        );
        auto comp = res.component("WindowUnitTest");
        assert(comp !is null);
        auto inst = comp.create();
        assert(inst !is null);

        auto win = inst.window;

        // Size check
        assert(win.size.width == 350.0);
        assert(win.size.height == 250.0);

        // Resize check
        win.size = WindowSize(500, 350);
        assert(win.size.width == 500.0);
        assert(win.size.height == 350.0);

        win.setSize(550, 400);
        assert(win.size.width == 550.0);
        assert(win.size.height == 400.0);

        // Click check
        assert(inst.getNumber("clicks") == 0);
        win.click(30, 30);
        assert(inst.getNumber("clicks") == 1);

        // Key dispatch check
        win.dispatchKey(KeyEvent.pressed, "H");
        win.dispatchKey(KeyEvent.released, "H");
        assert(inst.getString("key_received") == "H");

        // Visibility
        assert(!win.isVisible); // Window is not mapped/shown yet
    }
}
