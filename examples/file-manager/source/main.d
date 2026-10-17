/// File Manager example entrypoint.
///
/// Modes:
/// - pure-D (`dub run`): seeds an in-memory filesystem, drives the
///   FileManagerController through a tab + drag-and-drop script, prints it.
/// - native window (`dub run --config=native`): loads `app.slint` and wires
///   callbacks to the same controller (needs a display).
/// - native headless shot (`--check` / `--shot [out.png]` with
///   `SLINT_BACKEND=software`): compile-checks `app.slint`; `--shot` additionally
///   opens both panes, drives the UI through the MCP automation backend
///   (`SlintUiInspector` + `SlintElementController` — the same classes the
///   `click_element` / `get_state` MCP tools dispatch through), performs a
///   drag-and-drop across panes, and saves an offscreen PNG snapshot.
module main;

import std.stdio : writeln, writefln;

import filemanager;

import slint;
import slint.codegen : Prop, SlintProps, SlintCallbacks;
import slint.model : ArrayModel;
import slint.png : encodePngRgba;
import slint.value : SlintField, Value;

struct MainWindow
{
    ComponentInstance _instance;
    mixin SlintProps!(Prop!("currentTab", double), Prop!("status", string),
            Prop!("middleTitle", string), Prop!("rightTitle", string), Prop!("treeSelected", string),
            Prop!("draggedPayload", string), Prop!("selectedMiddle", double),
            Prop!("selectedRight", double));
    mixin SlintCallbacks!("tabSelected", "addTab", "closeTab", "treeSelectedChanged",
            "paneNavigate", "fileActivated", "filePressed", "dropOnPane", "moveRequested");
    alias _instance this;
}

/// D mirror of the `FileRow` struct in `app.slint`.
struct FileRowD
{
    @SlintField("name") string name;
    @SlintField("path") string path;
    @SlintField("isDir") bool isDir;
}

/// D mirror of the `TreeRow` struct in `app.slint`.
struct TreeRowD
{
    @SlintField("id") string id;
    @SlintField("label") string label;
    @SlintField("depth") int depth;
}

FileManagerController seedController()
{
    auto fs = new MemFs();
    fs.mkdir("/docs");
    fs.mkdir("/media");
    fs.touch("/docs/notes.txt");
    fs.touch("/docs/plan.md");
    fs.touch("/media/song.mp3");
    auto fm = new FileManagerController(fs);
    fm.navigatePane(0, "/docs"); // location 1
    fm.navigatePane(1, "/media"); // location 2
    return fm;
}

void pushModels(ref MainWindow w, ComponentInstance inst, FileManagerController fm)
{
    string[] tabNames;
    foreach (t; fm.tabs())
        tabNames ~= t.name;
    inst.setModel("tabs", new ArrayModel!string(tabNames));

    auto mem = cast(MemFs) fm.fs();
    TreeRowD[] tree;
    if (mem !is null)
    {
        foreach (r; mem.treeRows("/"))
            tree ~= TreeRowD(r.id, r.label, r.depth);
    }
    inst.setModel("treeNodes", new ArrayModel!TreeRowD(tree));

    FileRowD[] mid, right;
    foreach (e; fm.paneEntries(0))
        mid ~= FileRowD(e.name, e.path, e.isDir);
    foreach (e; fm.paneEntries(1))
        right ~= FileRowD(e.name, e.path, e.isDir);
    inst.setModel("middleFiles", new ArrayModel!FileRowD(mid));
    inst.setModel("rightFiles", new ArrayModel!FileRowD(right));

    w.currentTab = cast(double) fm.currentTab();
    w.status = fm.status();
    w.middleTitle = fm.active().middlePath;
    w.rightTitle = fm.active().rightPath;
    w.treeSelected = fm.active().middlePath;
    w.draggedPayload = fm.dragPayload();
}

void wireCallbacks(ref MainWindow w, ComponentInstance inst,
        FileManagerController fm, ref double selMid, ref double selRight)
{
    void sync()
    {
        pushModels(w, inst, fm);
        w.selectedMiddle = selMid;
        w.selectedRight = selRight;
    }

    w.onTabSelected((const(Value)[] args) {
        if (args.length > 0)
        {
            fm.selectTab(cast(size_t) args[0].number);
            selMid = -1;
            selRight = -1;
        }
        sync();
        return Value.nil();
    });
    w.onAddTab(() { fm.addTab(); sync(); });
    w.onCloseTab(() { fm.closeTab(); sync(); });
    w.onTreeSelectedChanged((const(Value)[] args) {
        if (args.length > 0)
            fm.selectTreeNode(args[0].text, 0);
        sync();
        return Value.nil();
    });
    w.onFilePressed((const(Value)[] args) {
        try
        {
            if (args.length > 1)
            {
                size_t pane = cast(size_t) args[0].number;
                size_t idx = cast(size_t) args[1].number;
                fm.pressFile(pane, idx);
                if (pane == 0)
                {
                    selMid = cast(double) idx;
                    selRight = -1;
                }
                else
                {
                    selRight = cast(double) idx;
                    selMid = -1;
                }
            }
        }
        catch (Exception)
        {
        }
        sync();
        return Value.nil();
    });
    w.onFileActivated((const(Value)[] args) {
        try
        {
            if (args.length > 1)
            {
                size_t pane = cast(size_t) args[0].number;
                fm.pressFile(pane, cast(size_t) args[1].number);
                fm.moveSelectedToOther(pane);
                selMid = -1;
                selRight = -1;
            }
        }
        catch (Exception)
        {
        }
        sync();
        return Value.nil();
    });
    w.onDropOnPane((const(Value)[] args) {
        try
        {
            if (args.length > 1)
            {
                fm.dropOnPane(cast(size_t) args[0].number, args[1].text);
                selMid = -1;
                selRight = -1;
            }
        }
        catch (Exception)
        {
        }
        sync();
        return Value.nil();
    });
    w.onMoveRequested((const(Value)[] args) {
        try
        {
            if (args.length > 0)
            {
                fm.moveSelectedToOther(cast(size_t) args[0].number);
                selMid = -1;
                selRight = -1;
            }
        }
        catch (Exception)
        {
        }
        sync();
        return Value.nil();
    });
    w.onPaneNavigate((const(Value)[] args) {
        try
        {
            if (args.length > 1)
                fm.navigatePane(cast(size_t) args[0].number, args[1].text);
        }
        catch (Exception)
        {
        }
        sync();
        return Value.nil();
    });
}

void main(string[] args)
{
    import std.algorithm : canFind;

    auto shotIdx = -1;
    foreach (i, a; args)
        if (a == "--shot")
            shotIdx = cast(int) i;
    if (shotIdx >= 0)
    {
        string outPath = "../../renders/file-manager-two-panes.png";
        if (shotIdx + 1 < args.length && args[shotIdx + 1].length > 2
                && args[shotIdx + 1][0 .. 2] != "--")
            outPath = args[shotIdx + 1];
        try
        {
            runShot(outPath);
        }
        catch (NativeUnavailable e)
        {
            writeln("file-manager --shot needs the native runtime:");
            writeln("  " ~ e.msg);
            writeln("  Build it with:  cd slint-d/bridge && cargo build");
            writeln("  Then run with:  SLINT_BACKEND=software dub run --config=native -- --shot");
        }
        return;
    }

    auto fm = seedController();
    if (args.canFind("--check"))
    {
        import slint.compiler : Compiler;

        auto compiler = new Compiler();
        auto built = compiler.buildFromPath("app.slint");
        foreach (d; built.diagnostics)
            writeln(d.toString());
        writeln("components: ", built.componentNames);
        return;
    }

    try
    {
        runNative(fm);
    }
    catch (NativeUnavailable e)
    {
        writeln("file-manager: native runtime not linked.");
        writeln("  " ~ e.msg);
        writeln("  Build it with:  cd slint-d/bridge && cargo build");
        writeln("  Then run with:  cd examples/file-manager && dub run --config=native");
        writeln();
        runPureDemo(fm);
    }
}

private void runPureDemo(FileManagerController fm)
{
    writefln!"tabs: %s  middle=%s  right=%s"(fm.tabs().length, fm.active()
            .middlePath, fm.active().rightPath);
    foreach (e; fm.paneEntries(0))
        writefln!"  [L1] %s"(e.name);
    foreach (e; fm.paneEntries(1))
        writefln!"  [L2] %s"(e.name);
    // Drag first middle entry to the right pane.
    fm.pressFile(0, 0);
    fm.dropOnPane(1, fm.dragPayload());
    writeln("after drag-and-drop:");
    foreach (e; fm.paneEntries(1))
        writefln!"  [L2] %s"(e.name);
    writeln("status: " ~ fm.status());
}

private void runNative(FileManagerController fm)
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
    auto inst = def.create();
    auto w = MainWindow(inst);
    double selMid = -1, selRight = -1;
    pushModels(w, inst, fm);
    w.selectedMiddle = selMid;
    w.selectedRight = selRight;
    wireCallbacks(w, inst, fm, selMid, selRight);
    w.run();
}

/// Headless MCP-driven run: open both panes, operate the UI exclusively
/// through the MCP automation backend, and snapshot the window to PNG.
private void runShot(string outPath)
{
    import slate.agent.slint_backend : SlintElementController, SlintUiInspector;

    auto fm = seedController();
    auto result = loadFile("app.slint");
    foreach (d; result.diagnostics)
        writeln(d.toString());
    auto def = result.component("MainWindow");
    if (def is null)
    {
        writeln("component MainWindow not found");
        return;
    }
    auto inst = def.create();
    auto w = MainWindow(inst);
    double selMid = -1, selRight = -1;
    pushModels(w, inst, fm);
    wireCallbacks(w, inst, fm, selMid, selRight);

    // Both panes are open: location 1 = /docs, location 2 = /media.
    writefln!"panes: middle=%s (%s entries)  right=%s (%s entries)"(fm.active()
            .middlePath, fm.paneEntries(0).length, fm.active().rightPath,
            fm.paneEntries(1).length);

    // MCP automation backend: the same inspector + element controller the
    // `inspect_tree` / `click_element` MCP tools dispatch through.
    auto inspector = new SlintUiInspector(inst);
    auto controller = new SlintElementController(inst);

    auto tree = inspector.inspectTree();
    foreach (id; [
        "fm-tab-0", "fm-tree-row-1", "fm-pane-0", "fm-pane-1", "fm-mid-file-0",
        "fm-send-right"
    ])
    {
        auto node = tree.findById(id);
        writefln!"mcp inspect: %-14s %s (%s)"(id, node !is null
                ? "found" : "MISSING", node !is null ? node.label : "-");
    }

    // Drag-and-drop via MCP: press the first file in location 1 ...
    auto r1 = controller.clickElement("#fm-mid-file-0");
    writefln!"mcp click_element #fm-mid-file-0 -> %s"(r1.message);
    // ... then drop it onto location 2.
    auto payload = fm.dragPayload();
    writefln!"mcp staged payload: %s"(payload);
    auto r2 = controller.clickElement("#fm-pane-1");
    writefln!"mcp click_element #fm-pane-1 -> %s"(r2.message);
    writefln!"mcp status: %s"(fm.status());
    writefln!"after MCP drop: right pane now has %s entries"(fm.paneEntries(1).length);

    auto shot = inst.snapshot();
    auto png = encodePngRgba(shot.width, shot.height, shot.pixels);
    import std.file : mkdirRecurse;
    import std.path : dirName;

    mkdirRecurse(dirName(outPath));
    import std.file : write;

    write(outPath, png);
    writefln!"saved %s (%sx%s)"(outPath, shot.width, shot.height);
}
