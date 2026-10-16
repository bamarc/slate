/// File / Directory Dialog controller, virtual & local filesystem providers, and MCP integration.
module slate.components.file_dialog;

import std.algorithm : canFind, sort, splitter;
import std.array : array;
import std.json : JSONType, JSONValue;
import std.path : baseName, buildNormalizedPath, dirName, extension;
import std.string : startsWith, strip, toLower;

import slint.model : ArrayModel;
import slint.value : SlintField;
import slate.agent.error : AgentError;
import slate.agent.traits;
import slate.components.dropzone : formatByteSize;

/// Single file/directory row mapped to `SlateFileEntry`.
struct FileEntryData
{
    @SlintField("name") string name;
    @SlintField("path") string path;
    @SlintField("is-dir") bool isDir = false;
    @SlintField("size-label") string sizeLabel = "--";
    @SlintField("modified-label") string modifiedLabel = "2026-10-15";
    @SlintField("selected") bool selected = false;
}

/// Bookmark entry mapped to `SlateBookmarkItem`.
struct BookmarkData
{
    @SlintField("id") string id;
    @SlintField("label") string label;
    @SlintField("path") string path;
}

/// Abstract filesystem provider for `FileDialogController` (enables deterministic unit testing).
interface FileSystemProvider
{
    bool isDirectory(string path);
    FileEntryData[] listEntries(string dirPath);
}

/// Deterministic in-memory virtual filesystem for unit and headless UI tests.
class InMemoryFileSystem : FileSystemProvider
{
    private FileEntryData[][string] _dirs;

    this() @safe pure nothrow
    {
        _dirs["/"] = [];
    }

    void addDirectory(string path) @safe pure
    {
        string norm = normalizeVirtualPath(path);
        if (norm !in _dirs)
            _dirs[norm] = [];
        string parent = normalizeVirtualPath(dirName(norm));
        if (parent != norm)
        {
            if (parent !in _dirs)
                _dirs[parent] = [];
            string name = baseName(norm);
            bool exists = false;
            foreach (ref e; _dirs[parent])
                if (e.name == name)
                    exists = true;
            if (!exists)
                _dirs[parent] ~= FileEntryData(name, norm, true, "--", "2026-10-15", false);
        }
    }

    void addFile(string filePath, ulong sizeBytes = 1024, string modified = "2026-10-15") @safe pure
    {
        string norm = normalizeVirtualPath(filePath);
        string parent = normalizeVirtualPath(dirName(norm));
        addDirectory(parent);
        string name = baseName(norm);
        _dirs[parent] ~= FileEntryData(name, norm, false,
                formatByteSize(sizeBytes), modified, false);
    }

    override bool isDirectory(string path) @safe pure
    {
        string norm = normalizeVirtualPath(path);
        return (norm in _dirs) !is null;
    }

    override FileEntryData[] listEntries(string dirPath) @safe pure
    {
        string norm = normalizeVirtualPath(dirPath);
        if (auto p = norm in _dirs)
            return (*p).dup;
        throw AgentError.invalidParams("path", "Directory does not exist: " ~ norm);
    }
}

/// Local OS filesystem provider with sandbox root validation.
class LocalFileSystem : FileSystemProvider
{
    override bool isDirectory(string path)
    {
        import std.file : exists, isDir, isSymlink;

        try
        {
            if (isSymlink(path))
                return false;
            return exists(path) && isDir(path);
        }
        catch (Exception)
        {
            return false;
        }
    }

    override FileEntryData[] listEntries(string dirPath)
    {
        import std.file : dirEntries, SpanMode, isDir, isSymlink, getSize;

        if (!isDirectory(dirPath))
            throw AgentError.invalidParams("path", "Directory does not exist: " ~ dirPath);

        FileEntryData[] list;
        try
        {
            foreach (de; dirEntries(dirPath, SpanMode.shallow))
            {
                if (de.isSymlink)
                    continue;
                bool d = de.isDir;
                ulong sz = d ? 0 : de.size;
                list ~= FileEntryData(baseName(de.name), de.name, d, d
                        ? "--" : formatByteSize(sz), "recent", false);
            }
        }
        catch (Exception e)
        {
            throw AgentError.invalidParams("path", "Failed to read directory: " ~ e.msg);
        }
        return list;
    }
}

/// Check whether a candidate path stays strictly within the sandbox root, preventing sibling prefix collision.
bool isPathWithinSandbox(string candidatePath, string sandboxRoot) @safe pure
{
    string normRoot = normalizeVirtualPath(sandboxRoot);
    string normCand = normalizeVirtualPath(candidatePath);
    if (normRoot == "/")
        return true;
    return normCand == normRoot || normCand.startsWith(normRoot ~ "/");
}

/// Normalize a POSIX-style path and reject null bytes.
string normalizeVirtualPath(string rawPath) @safe pure
{
    foreach (ch; rawPath)
    {
        if (ch == '\0')
            throw AgentError.invalidParams("path", "Path must not contain null bytes");
    }
    string trimmed = rawPath.strip();
    if (trimmed.length == 0)
        return "/";
    string norm = buildNormalizedPath("/", trimmed);
    return norm.length == 0 ? "/" : norm;
}

import slate.traits;

/// File / Directory Dialog controller implementing `McpControllable`, `Filterable`, and `Selectable`.
class FileDialogController : McpControllable, Filterable, Selectable
{
    mixin McpControllableMixin!"file_dialog";

    private FileSystemProvider _fs;
    private string _sandboxRoot = "/";
    private string _currentPath = "/";
    private string _mode = "open-file"; // "open-file" | "open-multiple" | "select-directory" | "save-file"
    private string _searchQuery = "";
    private string _extensionFilter = "*"; // e.g. "*" or ".slint,.d"
    private string _filenameInput = "";
    private string _errorMessage = "";
    private ptrdiff_t _selectedIndex = -1;
    private string[] _confirmedPaths;

    private FileEntryData[] _rawEntries;
    private FileEntryData[] _visibleEntries;
    private ArrayModel!FileEntryData _entriesModel;
    private ArrayModel!string _breadcrumbsModel;

    this(FileSystemProvider fs = null, string initialPath = "/", string sandboxRoot = "/")
    {
        _fs = fs !is null ? fs : new InMemoryFileSystem();
        _sandboxRoot = normalizeVirtualPath(sandboxRoot);
        _entriesModel = new ArrayModel!FileEntryData();
        _breadcrumbsModel = new ArrayModel!string();
        navigateTo(initialPath);
    }

    @McpIgnore ArrayModel!FileEntryData entriesModel() @safe pure nothrow
    {
        return _entriesModel;
    }

    @McpIgnore ArrayModel!string breadcrumbsModel() @safe pure nothrow
    {
        return _breadcrumbsModel;
    }

    @McpIgnore const(FileEntryData)[] visibleEntries() const @safe pure nothrow
    {
        return _visibleEntries;
    }

    string errorMessage() const @safe pure nothrow
    {
        return _errorMessage;
    }

    string mode() const @safe pure nothrow
    {
        return _mode;
    }

    void setMode(string m)
    {
        if (m != "open-file" && m != "open-multiple" && m != "select-directory" && m != "save-file")
            throw AgentError.invalidParams("mode", "Invalid file dialog mode: " ~ m);
        _mode = m;
    }

    string currentPath() const @safe pure nothrow
    {
        return _currentPath;
    }

    string filenameInput() const @safe pure nothrow
    {
        return _filenameInput;
    }

    @McpAction("set_filename")
    void setFilenameInput(string name)
    {
        foreach (ch; name)
        {
            if (ch == '\0' || ch == '/' || ch == '\\')
                throw AgentError.invalidParams("filename_input",
                        "Filename must not contain path separators or null bytes");
        }
        if (name.canFind(".."))
            throw AgentError.invalidParams("filename_input",
                    "Filename must not contain directory traversal sequences");
        _filenameInput = name.strip();
    }

    string extensionFilter() const @safe pure nothrow
    {
        return _extensionFilter;
    }

    void setExtensionFilter(string filterStr)
    {
        _extensionFilter = filterStr.strip().length > 0 ? filterStr.strip() : "*";
        recompute();
    }

    @McpState("search_query")
    override string filterQuery() const @safe pure nothrow
    {
        return _searchQuery;
    }

    @McpWritable("search_query") @McpAction("set_filter")
    override void setFilterQuery(string query)
    {
        _searchQuery = query;
        recompute();
    }

    override ptrdiff_t selectedIndex() const @safe pure nothrow
    {
        return _selectedIndex;
    }

    @McpAction("select_entry")
    override void selectIndex(size_t index)
    {
        if (index >= _visibleEntries.length)
            throw AgentError.invalidParams("selected_index", "File entry index out of range");
        _selectedIndex = cast(ptrdiff_t) index;
        foreach (i, ref e; _visibleEntries)
            e.selected = (i == index);
        if (!_visibleEntries[index].isDir)
            _filenameInput = _visibleEntries[index].name;
        syncModels();
    }

    /// Navigate to a directory path, enforcing sandbox root traversal rules (U2).
    @McpWritable("current_path")
    void navigateTo(string targetPath)
    {
        foreach (ch; targetPath)
        {
            if (ch == '\0')
                throw AgentError.invalidParams("current_path", "Path must not contain null bytes");
        }
        // Resolve relative or absolute paths against _currentPath
        string combined = targetPath.startsWith("/")
            ? buildNormalizedPath(targetPath) : buildNormalizedPath(_currentPath, targetPath);
        if (combined.length == 0)
            combined = "/";

        // Check sandbox boundary (U2)
        if (!isPathWithinSandbox(combined, _sandboxRoot))
            throw AgentError.invalidParams("current_path",
                    "Path traversal outside sandbox root is forbidden");

        if (!_fs.isDirectory(combined))
        {
            _errorMessage = "Directory does not exist: " ~ combined;
            return;
        }

        try
        {
            auto newEntries = _fs.listEntries(combined);
            _currentPath = combined;
            _selectedIndex = -1;
            _errorMessage = "";
            _rawEntries = newEntries;
            recompute();
        }
        catch (Exception e)
        {
            _errorMessage = "Failed to read directory: " ~ e.msg;
        }
    }

    /// Navigate to parent directory.
    string navigateUp()
    {
        string parent = buildNormalizedPath(dirName(_currentPath));
        if (parent.length == 0)
            parent = "/";
        if (!isPathWithinSandbox(parent, _sandboxRoot))
            parent = _sandboxRoot;
        navigateTo(parent);
        return _currentPath;
    }

    /// Navigate to a breadcrumb segment by index.
    string navigateBreadcrumb(size_t crumbIndex)
    {
        auto crumbs = breadcrumbPaths();
        if (crumbIndex >= crumbs.length)
            throw AgentError.invalidParams("crumb_index", "Breadcrumb index out of range");
        navigateTo(crumbs[crumbIndex]);
        return _currentPath;
    }

    /// Activate (double-click) an entry: directories navigate into them; files select & confirm.
    string activateEntry(size_t index)
    {
        if (index >= _visibleEntries.length)
            throw AgentError.invalidParams("index", "Entry index out of range");
        auto entry = _visibleEntries[index];
        if (entry.isDir)
        {
            navigateTo(entry.path);
            return _currentPath;
        }
        else
        {
            selectIndex(index);
            return confirmSelection();
        }
    }

    /// Confirm the current selection or save-file name.
    @McpAction("confirm")
    string confirmSelection()
    {
        if (_mode == "select-directory")
        {
            if (_selectedIndex >= 0 && _selectedIndex < cast(ptrdiff_t) _visibleEntries.length
                    && _visibleEntries[cast(size_t) _selectedIndex].isDir)
            {
                string chosen = _visibleEntries[cast(size_t) _selectedIndex].path;
                if (!isPathWithinSandbox(chosen, _sandboxRoot))
                    throw AgentError.invalidParams("selection",
                            "Path traversal outside sandbox root is forbidden");
                _confirmedPaths = [chosen];
                return chosen;
            }
            if (!isPathWithinSandbox(_currentPath, _sandboxRoot))
                throw AgentError.invalidParams("current_path",
                        "Path traversal outside sandbox root is forbidden");
            _confirmedPaths = [_currentPath];
            return _currentPath;
        }
        if (_mode == "save-file")
        {
            if (_filenameInput.length == 0)
                throw AgentError.invalidParams("filename_input",
                        "Filename required in save-file mode");
            foreach (ch; _filenameInput)
            {
                if (ch == '\0' || ch == '/' || ch == '\\')
                    throw AgentError.invalidParams("filename_input",
                            "Filename must not contain path separators or null bytes");
            }
            if (_filenameInput.canFind(".."))
                throw AgentError.invalidParams("filename_input",
                        "Filename must not contain directory traversal sequences");
            string full = buildNormalizedPath(_currentPath, _filenameInput);
            if (!isPathWithinSandbox(full, _sandboxRoot))
                throw AgentError.invalidParams("filename_input",
                        "Path traversal outside sandbox root is forbidden");
            _confirmedPaths = [full];
            return full;
        }
        if (_selectedIndex >= 0 && _selectedIndex < cast(ptrdiff_t) _visibleEntries.length)
        {
            string chosen = _visibleEntries[cast(size_t) _selectedIndex].path;
            if (!isPathWithinSandbox(chosen, _sandboxRoot))
                throw AgentError.invalidParams("selection",
                        "Path traversal outside sandbox root is forbidden");
            _confirmedPaths = [chosen];
            return chosen;
        }
        if (_filenameInput.length > 0)
        {
            foreach (ch; _filenameInput)
            {
                if (ch == '\0' || ch == '/' || ch == '\\')
                    throw AgentError.invalidParams("filename_input",
                            "Filename must not contain path separators or null bytes");
            }
            if (_filenameInput.canFind(".."))
                throw AgentError.invalidParams("filename_input",
                        "Filename must not contain directory traversal sequences");
            string full = buildNormalizedPath(_currentPath, _filenameInput);
            if (!isPathWithinSandbox(full, _sandboxRoot))
                throw AgentError.invalidParams("filename_input",
                        "Path traversal outside sandbox root is forbidden");
            _confirmedPaths = [full];
            return full;
        }
        throw AgentError.invalidParams("selection", "No file selected");
    }

    const(string)[] confirmedPaths() const @safe pure nothrow
    {
        return _confirmedPaths;
    }

    /// Compute cumulative paths for each breadcrumb segment.
    @McpIgnore string[] breadcrumbPaths() const @safe pure
    {
        string[] paths = ["/"];
        if (_currentPath == "/")
            return paths;
        string accum = "";
        foreach (seg; _currentPath.splitter('/'))
        {
            if (seg.length == 0)
                continue;
            accum ~= "/" ~ seg;
            paths ~= accum;
        }
        return paths;
    }

    /// Compute labels for each breadcrumb segment.
    @McpIgnore string[] breadcrumbLabels() const @safe pure
    {
        string[] labels = ["/"];
        if (_currentPath == "/")
            return labels;
        foreach (seg; _currentPath.splitter('/'))
        {
            if (seg.length > 0)
                labels ~= seg;
        }
        return labels;
    }

    private bool matchesExtensionFilter(FileEntryData entry) const @safe pure
    {
        if (entry.isDir || _extensionFilter == "*" || _extensionFilter.length == 0)
            return true;
        string ext = extension(entry.name).toLower();
        foreach (part; _extensionFilter.splitter(','))
        {
            string pat = part.strip().toLower();
            if (pat == "*" || pat == "*.*")
                return true;
            if (pat.startsWith("*."))
                pat = pat[1 .. $];
            else if (pat.length > 0 && pat[0] != '.')
                pat = "." ~ pat;
            if (ext == pat)
                return true;
        }
        return false;
    }

    private void recompute()
    {
        string q = _searchQuery.toLower().strip();
        FileEntryData[] dirs;
        FileEntryData[] files;

        foreach (e; _rawEntries)
        {
            if (q.length > 0 && !e.name.toLower().canFind(q))
                continue;
            if (!matchesExtensionFilter(e))
                continue;
            if (e.isDir)
                dirs ~= e;
            else
                files ~= e;
        }

        dirs.sort!((a, b) => a.name.toLower() < b.name.toLower());
        files.sort!((a, b) => a.name.toLower() < b.name.toLower());
        _visibleEntries = dirs ~ files;
        syncModels();
    }

    private void syncModels()
    {
        _entriesModel.clear();
        foreach (e; _visibleEntries)
            _entriesModel.push(e);

        _breadcrumbsModel.clear();
        foreach (lbl; breadcrumbLabels())
            _breadcrumbsModel.push(lbl);
    }

    void onMcpRestoreSnapshot(JSONValue snapshot)
    {
        if (snapshot.type != JSONType.object)
            return;
        auto obj = snapshot.object;

        if (auto p = "mode" in obj)
        {
            if (p.type == JSONType.string)
                _mode = p.str;
        }

        if (auto p = "current_path" in obj)
        {
            if (p.type == JSONType.string)
            {
                string targetPath = p.str;
                if (_fs.isDirectory(targetPath))
                {
                    try
                    {
                        _currentPath = targetPath;
                        _rawEntries = _fs.listEntries(targetPath);
                    }
                    catch (Exception)
                    {
                    }
                }
            }
        }

        if (auto p = "extension_filter" in obj)
        {
            if (p.type == JSONType.string)
                _extensionFilter = p.str;
        }

        if (auto p = "search_query" in obj)
        {
            if (p.type == JSONType.string)
                _searchQuery = p.str;
        }

        recompute();

        if (auto p = "filename_input" in obj)
        {
            if (p.type == JSONType.string)
                _filenameInput = p.str;
        }

        if (auto p = "selected_index" in obj)
        {
            if (p.type == JSONType.integer)
            {
                ptrdiff_t sel = cast(ptrdiff_t) p.integer;
                _selectedIndex = sel;
                foreach (i, ref e; _visibleEntries)
                    e.selected = (i == cast(size_t) sel);
            }
        }

        if (auto p = "error_message" in obj)
        {
            if (p.type == JSONType.string)
                _errorMessage = p.str;
        }

        syncModels();
    }
}

// Spec: Scenario T8: SlateFileDialog navigation, filtering, sandbox security, non-existent directory error handling, and confirmation via MCP
/// Example:
unittest
{
    import std.exception : assertThrown;

    static assert(isMcpControllable!FileDialogController);
    static assert(isFilterable!FileDialogController);
    static assert(isSelectable!FileDialogController);
    static assert(isMcpFilterable!FileDialogController);
    static assert(isMcpSelectable!FileDialogController);

    auto vfs = new InMemoryFileSystem();
    vfs.addDirectory("/workspace/project/src");
    vfs.addFile("/workspace/project/README.md", 2048);
    vfs.addFile("/workspace/project/dub.json", 512);
    vfs.addFile("/workspace/project/src/main.d", 4096);
    vfs.addFile("/workspace/project/src/view.slint", 8192);

    auto dlg = new FileDialogController(vfs, "/workspace/project", "/workspace");
    assert(dlg.currentPath() == "/workspace/project");
    assert(dlg.errorMessage() == "");
    // 1 directory ("src") + 2 files ("dub.json", "README.md")
    assert(dlg.visibleEntries().length == 3);
    assert(dlg.visibleEntries()[0].isDir && dlg.visibleEntries()[0].name == "src");

    // Non-existent directory error handling: preserves currentPath, sets errorMessage, retains visibleEntries
    dlg.navigateTo("/workspace/nonexistent");
    assert(dlg.currentPath() == "/workspace/project");
    assert(dlg.errorMessage().length > 0);
    assert(dlg.visibleEntries().length == 3);

    // Activate directory entry 0 -> navigates into /workspace/project/src, clears errorMessage
    dlg.activateEntry(0);
    assert(dlg.currentPath() == "/workspace/project/src");
    assert(dlg.errorMessage() == "");
    assert(dlg.visibleEntries().length == 2);

    // Filter by extension ".slint"
    dlg.setExtensionFilter(".slint");
    assert(dlg.visibleEntries().length == 1);
    assert(dlg.visibleEntries()[0].name == "view.slint");

    // Select and confirm
    dlg.selectIndex(0);
    assert(dlg.confirmSelection() == "/workspace/project/src/view.slint");
    assert(dlg.confirmedPaths() == ["/workspace/project/src/view.slint"]);

    // Sandbox traversal protection (U2) & sibling prefix collision prevention
    assertThrown!AgentError(dlg.navigateTo("/etc/passwd"));
    assertThrown!AgentError(dlg.navigateTo("../../../etc"));
    assertThrown!AgentError(dlg.navigateTo("/workspace-evil"));

    // Malicious filename inputs rejected
    assertThrown!AgentError(dlg.setFilenameInput("../evil.sh"));
    assertThrown!AgentError(dlg.setFilenameInput("sub/evil.sh"));
    assertThrown!AgentError(dlg.setFilenameInput("evil\0.sh"));

    // Snapshot restore test: index -1 and initial directory state restored
    auto snapDlg = new FileDialogController(vfs, "/workspace/project", "/workspace");
    assert(snapDlg.selectedIndex() == -1);
    auto snap = snapDlg.mcpSnapshot();

    snapDlg.selectIndex(0);
    assert(snapDlg.selectedIndex() == 0);
    snapDlg.navigateTo("/workspace/project/src");
    assert(snapDlg.currentPath() == "/workspace/project/src");

    snapDlg.mcpRestoreSnapshot(snap);
    assert(snapDlg.currentPath() == "/workspace/project");
    assert(snapDlg.selectedIndex() == -1);
    assert(!snapDlg.visibleEntries()[0].selected);
}

version (SlintNative)
{
    // Spec: Scenario T8 (SlintNative): SlateFileDialog UI navigation & selection via SlintElementController
    /// Example:
    unittest
    {
        import std.typecons : nullable;
        import slint.compiler : Compiler;
        import slate.agent.slint_backend : SlintElementController, SlintUiInspector;

        auto compiler = new Compiler();
        compiler.includePaths = [
            "../ui", "../../../ui", "ui", "../../ui", "../../../../ui"
        ];
        auto built = compiler.buildFromSource(`
            import { SlateFileDialog, SlateFileEntry } from "components/file_dialog.slint";
            export component FileDialogTestWin inherits Window {
                width: 680px;
                height: 440px;
                in-out property <string> current-path <=> fd.current-path;
                in-out property <[string]> breadcrumbs <=> fd.breadcrumbs;
                in-out property <[SlateFileEntry]> entries <=> fd.entries;
                in-out property <int> selected-index <=> fd.selected-index;
                in-out property <string> search-query <=> fd.search-query;
                in-out property <string> filename-input <=> fd.filename-input;
                in-out property <string> error-message <=> fd.error-message;
                in-out property <bool> confirmed: false;

                fd := SlateFileDialog {
                    width: 100%;
                    height: 100%;
                    automation-id: "file-dialog";
                    confirm-requested => { root.confirmed = true; }
                }
            }
        `, "");
        import std.conv : text;

        auto def = built.component("FileDialogTestWin");
        assert(def !is null, text("FileDialogTestWin failed: ", built.diagnostics));
        auto win = def.create();

        auto vfs = new InMemoryFileSystem();
        vfs.addFile("/workspace/alpha.slint", 1024);
        vfs.addFile("/workspace/beta.d", 2048);

        auto dlg = new FileDialogController(vfs, "/workspace", "/workspace");
        win.setString("current-path", dlg.currentPath());
        win.setModel("breadcrumbs", dlg.breadcrumbsModel());
        win.setModel("entries", dlg.entriesModel());

        auto slintCtrl = new SlintElementController(win);
        auto inspector = new SlintUiInspector(win);

        // Click entry 0 ("alpha.slint")
        slintCtrl.clickElement("#file-dialog-entry-0");
        assert(cast(int) win.getNumber("selected-index") == 0);
        assert(win.getString("filename-input") == "alpha.slint");

        // Click confirm button
        slintCtrl.clickElement("#file-dialog-confirm");
        assert(win.getBool("confirmed") == true);

        // Verify UI tree
        auto tree = inspector.inspectTree();
        assert(tree.findById("file-dialog-entry-0") !is null);
        assert(tree.findById("file-dialog-entry-1") !is null);

        // Verify error banner when error-message is set
        win.setString("error-message", "Directory does not exist: /fake");
        auto errTree = inspector.inspectTree();
        auto errNode = errTree.findById("file-dialog-error");
        assert(errNode !is null);
        assert(errNode.role == "text");
        assert(errNode.label == "Directory does not exist: /fake");
    }
}
