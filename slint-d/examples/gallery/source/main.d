/// Slate component gallery, driven from DLang.
///
/// Loads the Rust showcase markup (`slate-rust/examples/showcase/ui/`)
/// in place — relative imports keep working — wires the same callbacks the
/// Rust showcase wires (`increment-counter`, `toggle-theme`,
/// `start-compute` / `cancel-compute` via `slate.controller`), then renders
/// every tab offscreen with Slate's screenshot-tool technique (software
/// renderer, no display server, no event loop):
///
/// ```
/// dub run --config=native -- [out_dir]
/// ```
module main;

import std.stdio : writeln, writefln;
import std.file : mkdirRecurse;
import std.path : buildPath;
import std.typecons : Nullable;

import slint;
import slate.controller : ComputeController;
import slate.demo : monteCarloPiSamples, describeResult;

immutable string[] tabNames =
    ["buttons", "forms", "data", "feedback", "navigation", "overlays", "compute", "settings"];

struct Gallery
{
    ComponentInstance window;
    ComputeController compute;
    string outDir;
    string[] saved;

    void shoot(string file)
    {
        auto shot = window.snapshot();
        auto path = buildPath(outDir, file);
        std.file.write(path, encodePngRgba(shot.width, shot.height, shot.pixels));
        saved ~= path;
        writefln!"saved %s (%sx%s)"(path, shot.width, shot.height);
    }

    void tab(int index, bool dark, string suffix = "")
    {
        window.setNumber("active-tab", index);
        window.setGlobalBool("SlateTheme", "is-dark", dark);
        shoot("dlang-tab-" ~ tabNames[index] ~ (dark ? "-dark" : "-light") ~ suffix ~ ".png");
    }

    void wire()
    {
        // Copy the instance to locals: registry-held delegates must capture
        // GC references, never the Gallery struct's stack frame.
        auto win = window;
        auto controller = compute;
        win.setCallback("increment-counter", () {
            win.setNumber("counter", win.getNumber("counter") + 1);
        });
        win.setCallback("toggle-theme", () {
            bool dark = win.getGlobalBool("SlateTheme", "is-dark");
            win.setGlobalBool("SlateTheme", "is-dark", !dark);
        });
        win.setCallback("start-compute", () {
            win.setBool("compute-running", true);
            win.setNumber("compute-progress", 0.0);
            win.setString("compute-status", "Computing");
            win.setString("compute-result", "Working on 20,000,000 samples...");
            controller.start!double(
                (isCancelled, progress) => monteCarloPiSamples(20_000_000, isCancelled, progress),
                (float pct) { win.setNumber("compute-progress", pct); },
                (Nullable!double r) {
                    auto desc = describeResult(r);
                    win.setBool("compute-running", false);
                    if (!r.isNull)
                        win.setNumber("compute-progress", 1.0);
                    win.setString("compute-status", desc.status);
                    win.setString("compute-result", desc.text);
                });
        });
        win.setCallback("cancel-compute", () { controller.cancel(); });
    }
}

void main(string[] args)
{
    string showcaseUi = "/home/developer/projects/slate/slate-rust/examples/showcase/ui";
    string outDir = args.length > 1 ? args[1] : "/home/developer/projects/slate/renders/dlang-gallery";
    mkdirRecurse(outDir);

    // The showcase markup imports "../../ui/index.slint": like the Rust
    // build's raw `../../../ui` include dir, the join base is the importing
    // file's directory, so the include dir must denote slate-rust/ui (the
    // ".." budget cancels out in the joined path, which the kernel resolves
    // to the real root ui/). It need not exist itself.
    LoadOptions opts;
    opts.includePaths = ["/home/developer/projects/slate/slate-rust/ui", showcaseUi];
    auto result = loadFile(showcaseUi ~ "/app.slint", opts);
    bool failed;
    foreach (d; result.diagnostics)
    {
        writeln(d.toString());
        if (d.isError())
            failed = true;
    }
    if (failed)
        return;
    auto def = result.component("MainWindow");
    if (def is null)
    {
        writeln("component MainWindow not found");
        return;
    }

    auto gallery = Gallery(def.create(), new ComputeController(), outDir);
    gallery.wire();
    gallery.window.show();

    // Every tab, dark (compute tab with staged 72% state like render.rs).
    foreach (i; 0 .. 8)
    {
        if (i == 6)
        {
            gallery.window.setNumber("active-tab", 6);
            gallery.window.setGlobalBool("SlateTheme", "is-dark", true);
            gallery.window.setBool("compute-running", true);
            gallery.window.setNumber("compute-progress", 0.72);
            gallery.window.setString("compute-status", "Computing... (72%)");
            gallery.window.setString("compute-result", "14,400,000 / 20,000,000 samples");
            gallery.shoot("dlang-tab-compute-dark.png");
            gallery.window.setBool("compute-running", false);
        }
        else
            gallery.tab(cast(int) i, true);
    }
    // Light variant, modal, and drawer states.
    gallery.tab(0, false);
    gallery.window.setNumber("active-tab", 5);
    gallery.window.setGlobalBool("SlateTheme", "is-dark", true);
    gallery.window.setBool("modal-open", true);
    gallery.shoot("dlang-modal-open-dark.png");
    gallery.window.setBool("modal-open", false);
    gallery.window.setBool("drawer-open", true);
    gallery.shoot("dlang-drawer-open-dark.png");
    gallery.window.setBool("drawer-open", false);
    // Demo toasts are a public *function*; invoke() may not reach it.
    try
    {
        gallery.window.setNumber("active-tab", 3);
        gallery.window.invoke("show-demo-toasts");
        gallery.shoot("dlang-feedback-toasts-dark.png");
    }
    catch (SlintCallError e)
    {
        writeln("toasts shot skipped: ", e.msg);
    }

    gallery.window.hide();
    writefln!"gallery complete: %s shots in %s"(gallery.saved.length, outDir);
}

import std.file;
import std.path;
