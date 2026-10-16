/// Upload Dropzone queue controller and MCP drop-receiver integration.
module slate.components.dropzone;

import std.algorithm : canFind, splitter;
import std.conv : to;
import std.format : format;
import std.path : baseName, extension;
import std.string : strip, toLower;

import slint.model : ArrayModel;
import slint.value : SlintField;
import slate.agent.error : AgentError;
import slate.agent.traits;

/// Upload queue entry mapped to `SlateUploadItem`.
struct UploadItemData
{
    @SlintField("id") string id;
    @SlintField("name") string name;
    @SlintField("path") string path;
    @SlintField("size-label") string sizeLabel = "0 KB";
    @SlintField("progress") float progress = 0.0f;
    @SlintField("status") string status = "queued"; // "queued" | "uploading" | "completed" | "rejected"
    @SlintField("error-message") string errorMessage = "";
}

/// Format byte size into human-readable label.
string formatByteSize(ulong bytes) @safe pure nothrow
{
    try
    {
        if (bytes >= 1024UL * 1024UL)
            return format("%.1f MB", cast(double) bytes / (1024.0 * 1024.0));
        if (bytes >= 1024UL)
            return format("%.1f KB", cast(double) bytes / 1024.0);
        return format("%d B", bytes);
    }
    catch (Exception)
    {
        return "0 B";
    }
}

import slate.traits;

/// Upload queue controller implementing `McpControllable`, `DropReceiver`, and `Selectable`.
class UploadQueueController : McpControllable, DropReceiver, Selectable
{
    mixin McpControllableMixin!"dropzone";

    private UploadItemData[] _items;
    private ArrayModel!UploadItemData _model;
    private string[] _allowedExtensions; // lower-case with leading dot, e.g. [".png", ".pdf"]
    private ulong _maxFileSizeBytes;
    private size_t _nextId = 1;
    private ptrdiff_t _selectedIndex = -1;

    this(string[] allowedExtensions = [], ulong maxFileSizeBytes = 25UL * 1024UL * 1024UL)
    {
        foreach (ext; allowedExtensions)
        {
            string e = ext.toLower().strip();
            if (e.length > 0 && e[0] != '.')
                e = "." ~ e;
            if (e.length > 0)
                _allowedExtensions ~= e;
        }
        _maxFileSizeBytes = maxFileSizeBytes;
        _model = new ArrayModel!UploadItemData();
    }

    @McpIgnore ArrayModel!UploadItemData model() @safe pure nothrow
    {
        return _model;
    }

    @McpIgnore const(UploadItemData)[] items() const @safe pure nothrow
    {
        return _items;
    }

    override ptrdiff_t selectedIndex() const @safe pure nothrow
    {
        return _selectedIndex;
    }

    override void selectIndex(size_t index)
    {
        if (index >= _items.length)
            throw AgentError.invalidParams("index", "Upload item index out of range");
        _selectedIndex = cast(ptrdiff_t) index;
    }

    void clearSelection() @safe pure nothrow
    {
        _selectedIndex = -1;
    }

    size_t itemCount() const @safe pure nothrow
    {
        return _items.length;
    }

    size_t queuedCount() const @safe pure nothrow
    {
        size_t cnt = 0;
        foreach (ref const item; _items)
            if (item.status == "queued" || item.status == "uploading")
                cnt++;
        return cnt;
    }

    size_t rejectedCount() const @safe pure nothrow
    {
        size_t cnt = 0;
        foreach (ref const item; _items)
            if (item.status == "rejected")
                cnt++;
        return cnt;
    }

    size_t completedCount() const @safe pure nothrow
    {
        size_t cnt = 0;
        foreach (ref const item; _items)
            if (item.status == "completed")
                cnt++;
        return cnt;
    }

    private void syncModel()
    {
        _model.clear();
        foreach (item; _items)
            _model.push(item);
    }

    /// Add a single file with optional explicit byte size.
    /// Validates extension and max size (W4). Returns `true` if accepted, `false` if rejected.
    @McpIgnore bool addFile(string filePath, ulong sizeBytes = 1024)
    {
        import std.algorithm.searching : canFind;

        if (filePath.canFind('\0'))
            return false;

        string cleanPath = filePath.strip();
        if (cleanPath.length == 0)
            return false;

        string name = baseName(cleanPath);
        string ext = extension(name).toLower();

        string status = "queued";
        string errorMsg = "";

        if (_allowedExtensions.length > 0 && !_allowedExtensions.canFind(ext))
        {
            status = "rejected";
            errorMsg = "Unsupported file type: " ~ (ext.length > 0 ? ext : "none");
        }
        else if (_maxFileSizeBytes > 0 && sizeBytes > _maxFileSizeBytes)
        {
            status = "rejected";
            errorMsg = "File exceeds max size (" ~ formatByteSize(_maxFileSizeBytes) ~ ")";
        }

        auto item = UploadItemData(_nextId.to!string, name, cleanPath,
                formatByteSize(sizeBytes), status == "rejected" ? 0.0f : 0.0f, status, errorMsg);
        _nextId++;
        _items ~= item;
        syncModel();
        return status != "rejected";
    }

    /// `McpDropReceiver` implementation: accepts an array of file paths.
    /// Returns `true` if all non-empty paths were accepted, `false` if any were rejected or empty.
    override bool dropFiles(const(string)[] paths)
    {
        if (paths.length == 0)
            return false;
        bool allAccepted = true;
        foreach (p; paths)
        {
            if (!addFile(p))
                allAccepted = false;
        }
        return allAccepted;
    }

    /// Parse a newline- or comma-delimited payload dropped via Slint `SlateMcpDropTarget`.
    bool dropPayload(string payload)
    {
        string[] paths;
        foreach (line; payload.splitter('\n'))
        {
            foreach (part; line.splitter(','))
            {
                auto trimmed = part.strip();
                if (trimmed.length > 0)
                    paths ~= trimmed;
            }
        }
        return dropFiles(paths);
    }

    /// Update upload progress for an item by index.
    @McpIgnore void updateProgress(size_t index, float progress)
    {
        import std.math : isFinite;

        if (!isFinite(progress))
            throw AgentError.invalidParams("progress", "Progress must be finite");
        if (index >= _items.length)
            throw AgentError.invalidParams("index", "Upload item index out of range");
        if (_items[index].status == "rejected")
            return;
        float clamped = progress < 0.0f ? 0.0f : (progress > 1.0f ? 1.0f : progress);
        _items[index].progress = clamped;
        _items[index].status = clamped >= 1.0f ? "completed" : "uploading";
        syncModel();
    }

    /// Remove an item by index.
    void removeItem(size_t index)
    {
        if (index >= _items.length)
            throw AgentError.invalidParams("index", "Upload item index out of range");
        _items = _items[0 .. index] ~ _items[index + 1 .. $];
        syncModel();
    }

    /// Clear all completed items from the queue.
    void clearCompleted()
    {
        UploadItemData[] remaining;
        foreach (item; _items)
        {
            if (item.status != "completed")
                remaining ~= item;
        }
        _items = remaining;
        syncModel();
    }
}

// Spec: Scenario T7 / Security: SlateDropzone programmatic file drop and validation via MCP
/// Example:
unittest
{
    import std.exception : assertThrown;

    static assert(isMcpControllable!UploadQueueController);
    static assert(isDropReceiver!UploadQueueController);
    static assert(isMcpDropReceiver!UploadQueueController);
    static assert(isSelectable!UploadQueueController);

    auto ctrl = new UploadQueueController([".png", ".pdf"], 10 * 1024 * 1024);

    // Valid drop
    assert(ctrl.dropFiles(["/tmp/diagram.png", "/tmp/report.pdf"]) == true);
    assert(ctrl.itemCount() == 2);
    assert(ctrl.queuedCount() == 2);
    assert(ctrl.rejectedCount() == 0);

    // Selection tests
    assert(ctrl.selectedIndex() == -1);
    ctrl.selectIndex(1);
    assert(ctrl.selectedIndex() == 1);
    ctrl.clearSelection();
    assert(ctrl.selectedIndex() == -1);
    assertThrown!AgentError(ctrl.selectIndex(99));

    // Reject null bytes
    assert(ctrl.addFile("/tmp/evil\0file.pdf", 1024) == false);

    // Invalid extension rejected (W4)
    assert(ctrl.addFile("/tmp/malware.exe", 2048) == false);
    assert(ctrl.itemCount() == 3);
    assert(ctrl.rejectedCount() == 1);
    assert(ctrl.items()[2].status == "rejected");

    // Oversized file rejected (W4)
    assert(ctrl.addFile("/tmp/huge.pdf", 50 * 1024 * 1024) == false);
    assert(ctrl.rejectedCount() == 2);

    // Progress & completion
    assertThrown!AgentError(ctrl.updateProgress(0, float.nan));
    assertThrown!AgentError(ctrl.updateProgress(0, float.infinity));
    ctrl.updateProgress(0, 0.5f);
    assert(ctrl.items()[0].status == "uploading");
    ctrl.updateProgress(0, 1.0f);
    assert(ctrl.items()[0].status == "completed");
    assert(ctrl.completedCount() == 1);

    ctrl.clearCompleted();
    assert(ctrl.completedCount() == 0);
    assert(ctrl.itemCount() == 3);
}

version (SlintNative)
{
    // Spec: Scenario T7 (SlintNative): SlateDropzone MCP drop via sendKeys on #dropzone-drop-target
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
            import { SlateDropzone, SlateUploadItem } from "components/dropzone.slint";
            export component DropzoneTestWin inherits Window {
                width: 560px;
                height: 360px;
                in-out property <string> dropped-payload <=> dz.dropped-payload;
                in-out property <[SlateUploadItem]> items <=> dz.items;

                dz := SlateDropzone {
                    width: 100%;
                    height: 100%;
                    automation-id: "dropzone";
                }
            }
        `, "");
        import std.conv : text;

        auto def = built.component("DropzoneTestWin");
        assert(def !is null, text("DropzoneTestWin failed: ", built.diagnostics));
        auto win = def.create();

        auto ctrl = new UploadQueueController([".png", ".json"]);
        auto slintCtrl = new SlintElementController(win);
        auto inspector = new SlintUiInspector(win);

        // Simulate MCP drop via sendKeys on #dropzone-drop-target
        slintCtrl.sendKeys(nullable("#dropzone-drop-target"), "/tmp/avatar.png,/tmp/Bad.exe");
        string payload = win.getString("dropped-payload");
        assert(payload == "/tmp/avatar.png,/tmp/Bad.exe");

        ctrl.dropPayload(payload);
        win.setModel("items", ctrl.model());

        assert(ctrl.itemCount() == 2);
        assert(ctrl.queuedCount() == 1);
        assert(ctrl.rejectedCount() == 1);

        auto tree = inspector.inspectTree();
        assert(tree.findById("dropzone-item-0") !is null);
        assert(tree.findById("dropzone-item-1") !is null);
    }
}
