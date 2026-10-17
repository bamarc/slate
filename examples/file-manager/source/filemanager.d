/// Tabbed dual-pane file-manager controller (pure-D, no Slint runtime needed).
///
/// Spec: tabs hold independent (middlePath, rightPath) pairs; the left tree
/// drives the focused pane; drag-and-drop / move buttons relocate an entry
/// from one pane directory into the other within a single window.
module filemanager;

/// Single directory entry surfaced to the `.slint` file lists.
struct Entry
{
    string name;
    string path;
    bool isDir;
}

/// Flattened tree row surfaced to the `.slint` directory tree.
struct TreeRow
{
    string id; // absolute directory path
    string label;
    int depth;
}

/// Minimal filesystem abstraction so unit tests run on memory.
interface FileManagerFs
{
    bool isDirectory(string path);
    Entry[] listEntries(string dirPath);
    void moveEntry(string srcPath, string dstDir);
}

/// Deterministic in-memory filesystem with move support.
class MemFs : FileManagerFs
{
    private bool[string] _dirs;
    private Entry[][string] _files; // dir -> direct children

    this()
    {
        _dirs["/"] = true;
        _files["/"] = [];
    }

    void mkdir(string path)
    {
        string p = norm(path);
        if (p in _dirs)
            return;
        string parent = parentOf(p);
        mkdir(parent);
        _dirs[p] = true;
        _files[p] = [];
        _files[parent] ~= Entry(base(p), p, true);
    }

    void touch(string path)
    {
        string p = norm(path);
        string parent = parentOf(p);
        mkdir(parent);
        _files[parent] ~= Entry(base(p), p, false);
    }

    override bool isDirectory(string path)
    {
        return (norm(path) in _dirs) !is null;
    }

    override Entry[] listEntries(string dirPath)
    {
        string p = norm(dirPath);
        if (p !in _dirs)
            throw new Exception("Directory does not exist: " ~ p);
        return _files[p].dup;
    }

    override void moveEntry(string srcPath, string dstDir)
    {
        string s = norm(srcPath);
        string d = norm(dstDir);
        if (d !in _dirs)
            throw new Exception("Destination is not a directory: " ~ d);
        string srcParent = parentOf(s);
        if (srcParent !in _dirs)
            throw new Exception("Source does not exist: " ~ s);
        bool found = false;
        string name;
        bool wasDir = false;
        foreach (i, e; _files[srcParent])
        {
            if (e.path == s)
            {
                name = e.name;
                wasDir = e.isDir;
                _files[srcParent] = _files[srcParent][0 .. i] ~ _files[srcParent][i + 1 .. $];
                found = true;
                break;
            }
        }
        if (!found)
            throw new Exception("Source does not exist: " ~ s);
        if (srcParent == d)
        {
            // Moving onto itself: restore and report.
            _files[srcParent] ~= Entry(name, s, wasDir);
            throw new Exception("Source and destination are the same directory");
        }
        string np = d == "/" ? "/" ~ name : d ~ "/" ~ name;
        _files[d] ~= Entry(name, np, wasDir);
        if (wasDir)
            _relocateDir(s, np);
    }

    TreeRow[] treeRows(string root = "/") const
    {
        TreeRow[] rows;
        _collect(root, 0, rows);
        return rows;
    }

    private void _collect(string dir, int depth, ref TreeRow[] rows) const
    {
        rows ~= TreeRow(dir, dir == "/" ? "/" : base(dir), depth);
        foreach (e; _files[dir])
            if (e.isDir)
                _collect(e.path, depth + 1, rows);
    }

    private void _relocateDir(string oldBase, string newBase)
    {
        // Move subtree bookkeeping after a directory rename.
        string[] keys = _dirs.keys;
        foreach (k; keys)
        {
            if (k.length > oldBase.length && k[0 .. oldBase.length] == oldBase
                    && (k.length == oldBase.length || k[oldBase.length] == '/'))
            {
                string suffix = k[oldBase.length .. $];
                string nk = newBase ~ suffix;
                _dirs[nk] = true;
                _files[nk] = _files[k];
                foreach (ref e; _files[nk])
                    e.path = nk == "/" ? "/" ~ e.name : nk ~ "/" ~ e.name;
                _dirs.remove(k);
                _files.remove(k);
            }
        }
        _dirs.remove(oldBase);
        auto keep = _files[newBase]; // already updated above
        _files.remove(oldBase);
        _files[newBase] = keep;
    }

    private static string norm(string p)
    {
        import std.path : buildNormalizedPath;

        if (p.length == 0)
            return "/";
        string n = buildNormalizedPath("/", p);
        return n.length == 0 ? "/" : n;
    }

    private static string parentOf(string p)
    {
        import std.path : dirName;

        if (p == "/")
            return "/";
        string d = dirName(p);
        return d.length == 0 ? "/" : d;
    }

    private static string base(string p)
    {
        import std.path : baseName;

        return p == "/" ? "/" : baseName(p);
    }
}

/// One tab: independent locations for pane 0 (middle) and pane 1 (right).
struct TabSession
{
    string name;
    string middlePath = "/";
    string rightPath = "/";
}

/// Single-window controller: N tabs x (tree + 2 panes) + drag payload.
class FileManagerController
{
    private FileManagerFs _fs;
    private TabSession[] _tabs;
    private size_t _current;
    private string _dragPayload = "";
    private string _status = "Ready";

    this(FileManagerFs fs)
    {
        _fs = fs;
        _tabs ~= TabSession("Tab 1", "/", "/");
    }

    FileManagerFs fs() @safe pure nothrow
    {
        return _fs;
    }

    @safe pure nothrow const(TabSession)[] tabs() const
    {
        return _tabs;
    }

    @safe pure nothrow size_t currentTab() const
    {
        return _current;
    }

    @safe pure nothrow string status() const
    {
        return _status;
    }

    @safe pure nothrow string dragPayload() const
    {
        return _dragPayload;
    }

    TabSession active() const
    {
        return _tabs[_current];
    }

    void addTab()
    {
        import std.conv : to;

        auto a = active();
        _tabs ~= TabSession("Tab " ~ to!string(_tabs.length + 1), a.middlePath, a.rightPath);
        _current = _tabs.length - 1;
        _status = "Tab added";
    }

    void closeTab()
    {
        if (_tabs.length <= 1)
        {
            _status = "Cannot close the last tab";
            return;
        }
        _tabs = _tabs[0 .. _current] ~ _tabs[_current + 1 .. $];
        if (_current >= _tabs.length)
            _current = _tabs.length - 1;
        // Renumber for stable labels.
        foreach (i, ref t; _tabs)
        {
            import std.conv : to;

            t.name = "Tab " ~ to!string(i + 1);
        }
        _status = "Tab closed";
    }

    void selectTab(size_t idx)
    {
        if (idx >= _tabs.length)
            throw new Exception("Tab index out of range");
        _current = idx;
        _dragPayload = "";
        _status = "Switched to " ~ _tabs[idx].name;
    }

    void navigatePane(size_t pane, string path)
    {
        if (pane > 1)
            throw new Exception("Pane index must be 0 or 1");
        if (!_fs.isDirectory(path))
        {
            _status = "Not a directory: " ~ path;
            return;
        }
        if (pane == 0)
            _tabs[_current].middlePath = path;
        else
            _tabs[_current].rightPath = path;
        _status = "Navigated pane " ~ (pane == 0 ? "1" : "2") ~ " to " ~ path;
    }

    Entry[] paneEntries(size_t pane)
    {
        if (pane > 1)
            throw new Exception("Pane index must be 0 or 1");
        string p = pane == 0 ? _tabs[_current].middlePath : _tabs[_current].rightPath;
        return _fs.listEntries(p);
    }

    /// Tree click navigates the last-focused pane (middle by default).
    void selectTreeNode(string dirPath, size_t focusedPane = 0)
    {
        navigatePane(focusedPane, dirPath);
    }

    /// Press-and-hold on a file stages it as the drag payload.
    void pressFile(size_t pane, size_t index)
    {
        auto entries = paneEntries(pane);
        if (index >= entries.length)
            throw new Exception("File index out of range");
        _dragPayload = entries[index].path;
        _status = "Dragging " ~ entries[index].name;
    }

    /// Dropping a payload onto a pane moves it there.
    void dropOnPane(size_t pane, string payload)
    {
        if (pane > 1)
            throw new Exception("Pane index must be 0 or 1");
        if (payload.length == 0)
            throw new Exception("Empty drag payload");
        string dst = pane == 0 ? _tabs[_current].middlePath : _tabs[_current].rightPath;
        try
        {
            _fs.moveEntry(payload, dst);
            _status = "Moved to " ~ dst;
        }
        catch (Exception e)
        {
            _status = "Move failed: " ~ e.msg;
            throw e;
        }
        finally
        {
            _dragPayload = "";
        }
    }

    /// Button fallback: move the staged payload (or explicit path) to the other pane.
    void moveSelectedToOther(size_t fromPane)
    {
        if (_dragPayload.length == 0)
            throw new Exception("Nothing staged for move: press a file first");
        dropOnPane(fromPane == 0 ? 1 : 0, _dragPayload);
    }
}

// Spec: tabs isolate pane locations; tree drives focused pane; staged drag
// payload moves an entry across panes in one window.
/// Example:
unittest
{
    auto fs = new MemFs();
    fs.mkdir("/docs");
    fs.mkdir("/media");
    fs.touch("/docs/a.txt");
    fs.touch("/docs/b.txt");
    fs.touch("/media/song.mp3");

    auto fm = new FileManagerController(fs);
    assert(fm.tabs().length == 1);
    assert(fm.active().middlePath == "/");

    // Navigate panes independently.
    fm.navigatePane(0, "/docs");
    fm.navigatePane(1, "/media");
    assert(fm.paneEntries(0).length == 2);
    assert(fm.paneEntries(1).length == 1);

    // Tree selection drives the focused pane.
    fm.selectTreeNode("/media", 0);
    assert(fm.active().middlePath == "/media");

    // Drag middle -> right via payload staging.
    fm.navigatePane(0, "/docs");
    fm.pressFile(0, 0);
    assert(fm.dragPayload().length > 0);
    string payload = fm.dragPayload();
    fm.dropOnPane(1, payload);
    assert(fm.paneEntries(1).length == 2);
    assert(fm.dragPayload() == "");

    // Tabs isolate locations.
    fm.addTab();
    assert(fm.tabs().length == 2);
    fm.navigatePane(0, "/media");
    fm.selectTab(0);
    assert(fm.active().middlePath == "/docs");
    fm.selectTab(1);
    assert(fm.active().middlePath == "/media");

    // Cannot close the last tab; same-directory move rejected.
    auto fm2 = new FileManagerController(new MemFs());
    fm2.closeTab();
    assert(fm2.tabs().length == 1);
    assert(fm2.status() == "Cannot close the last tab");

    import std.exception : assertThrown;

    assertThrown!Exception(fm2.selectTab(5));
    assertThrown!Exception(fm2.pressFile(0, 0)); // "/" is empty in fresh MemFs
}
