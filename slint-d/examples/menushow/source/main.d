/// Slate menu gallery: loads the shared Slate menubar component from D.
///
/// Two modes:
/// - `--shot <out.png>`: offscreen direct rendering (Slate screenshot-tool
///   technique — software renderer, no display server, no event loop).
/// - otherwise: show the window and auto-quit after N ms (for scripted
///   on-screen captures).
module main;

import std.stdio : writeln, writefln;
import std.conv : to;
import std.path : buildPath, dirName;

import slint;

void main(string[] args)
{
    string repoRoot = dirName(dirName(dirName(dirName(dirName(__FILE_FULL_PATH__)))));
    string uiDir = buildPath(repoRoot, "ui");
    string shotPath;
    uint quitAfterMs = 6000;
    foreach (i, a; args[1 .. $])
    {
        if (a == "--shot" && i + 1 < args.length - 1)
            shotPath = args[i + 2];
        else if (a != "--shot")
        {
            try
                quitAfterMs = a.to!uint;
            catch (Exception)
            {
            }
        }
    }

    LoadOptions opts;
    opts.includePaths = [uiDir];
    auto result = loadFile("app.slint", opts);
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
    auto instance = def.create();

    if (shotPath.length)
    {
        // Offscreen: show populates the software surface, snapshot reads it.
        instance.show();
        auto shot = instance.snapshot();
        instance.hide();
        std.file.write(shotPath, encodePngRgba(shot.width, shot.height, shot.pixels));
        writefln!"saved %s (%sx%s)"(shotPath, shot.width, shot.height);
        return;
    }

    // Auto-quit so the capture script never hangs.
    auto timer = new Timer();
    timer.singleShot(cast(long) quitAfterMs, () { quitEventLoop(); });
    instance.run();
    writeln("menushow done");
}

import std.file;
