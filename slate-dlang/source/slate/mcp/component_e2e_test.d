/// End-to-End MCP protocol verification (`Scenario T10`) across Slate's
/// default layouts, data representations, media player, dropzone, and file dialog.
module slate.mcp.component_e2e_test;

import std.json : JSONValue, parseJSON;
import std.algorithm : canFind;

import slate.agent.builder : AgentBuilder;
import slate.agent.declarative : McpStateRegistry;
import slate.components;
import slate.mcp.server : McpServer;

// Spec: Scenario T10 (Pure-D): Multi-controller MCP JSON-RPC `get_state` round-trip across Slate components
/// Example:
unittest
{
    auto registry = new McpStateRegistry();

    auto grid = new DataGridController!GridRowData([
        GridRowData("1", "Node-A", "Compute", "95", "Healthy", "Active", "success"),
        GridRowData("2", "Node-B", "Storage", "40", "Idle", "Standby", "default"),
    ]);
    auto media = new MediaPlayerController([
        MediaTrackData("t1", "Telemetry Stream", "Slate", 240.0f),
    ]);
    auto dropzone = new UploadQueueController([".png", ".json"]);
    auto vfs = new InMemoryFileSystem();
    vfs.addFile("/workspace/config.json", 512);
    auto fileDlg = new FileDialogController(vfs, "/workspace", "/workspace");
    auto wizard = new WizardController(3);
    auto logs = new RingBufferLogModel("logs", 50);
    logs.append("INFO", "mcp", "E2E test initialized", "12:00:00");

    registry.registerController(grid);
    registry.registerController(media);
    registry.registerController(dropzone);
    registry.registerController(fileDlg);
    registry.registerController(wizard);
    registry.registerController(logs);

    // Mutate controllers via trait interfaces
    media.play();
    media.seekTo(60.0);
    dropzone.dropFiles(["/workspace/config.json"]);
    wizard.nextStep();

    auto handle = AgentBuilder.forWindow(null, registry).build();
    auto server = new McpServer(handle.engine());

    // Initialize MCP session
    auto initResp = parseJSON(server.handleLine(
        `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}`
    ));
    assert("result" in initResp);

    // Call get_state with query="media"
    auto stateResp = parseJSON(server.handleLine(
        `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_state","arguments":{"query":"media"}}}`
    ));
    assert("result" in stateResp);
    string contentText = stateResp["result"]["content"][0]["text"].str;
    assert(contentText.canFind(`"media.playing":true`) || contentText.canFind(`"playing":true`));
    assert(contentText.canFind("60"));
}

version (SlintNative)
{
    // Spec: Scenario T10 (SlintNative): Full E2E MCP JSON-RPC verification across 6-step workflow (Wizard, DataGrid, LogViewer, Media, Dropzone, FileDialog), get_state, and get_screenshot
    /// Example:
    unittest
    {
        import std.base64 : Base64;
        import std.conv : text;
        import slint.compiler : Compiler;

        auto compiler = new Compiler();
        compiler.includePaths = ["../ui"];
        auto built = compiler.buildFromSource(`
            import {
                SlateWizardLayout,
                SlateWizardStep,
                SlateDataGrid,
                SlateGridRow,
                SlateMediaPlayer,
                SlateDropzone,
                SlateUploadItem,
                SlateFileDialog,
                SlateFileEntry,
                SlateLogViewer,
                SlateLogEntry
            } from "index.slint";

            export component ShowcaseE2EWindow inherits Window {
                width: 960px;
                height: 800px;

                in-out property <int> wizard-step <=> wiz.current-step;
                in-out property <string> grid-sort-dir <=> grid.sort-direction;
                in-out property <bool> media-playing <=> player.playing;
                in-out property <float> media-pos <=> player.position-seconds;
                in-out property <string> dropped-files <=> dz.dropped-payload;
                in-out property <string> log-sev <=> logger.severity-filter;
                in-out property <int> fd-selected <=> fd.selected-index;
                in-out property <string> fd-input <=> fd.filename-input;

                wiz := SlateWizardLayout {
                    width: 100%;
                    height: 100%;
                    automation-id: "e2e-wizard";
                    steps: [
                        { id: "s1", title: "Data & Media", subtitle: "Step 1", completed: false },
                        { id: "s2", title: "Files & Logs", subtitle: "Step 2", completed: false }
                    ];

                    VerticalLayout {
                        spacing: 8px;

                        grid := SlateDataGrid {
                            height: 140px;
                            automation-id: "e2e-grid";
                            rows: [
                                { id: "r1", col0: "Alpha", col1: "Core", col2: "10", col3: "OK", badge: "Ready", badge-variant: "success", selected: false },
                                { id: "r2", col0: "Beta", col1: "Edge", col2: "20", col3: "OK", badge: "Active", badge-variant: "info", selected: false }
                            ];
                        }

                        player := SlateMediaPlayer {
                            height: 140px;
                            automation-id: "e2e-media";
                            title: "Demo Stream";
                            duration-seconds: 120.0;
                        }

                        dz := SlateDropzone {
                            height: 120px;
                            automation-id: "e2e-dropzone";
                        }

                        logger := SlateLogViewer {
                            height: 110px;
                            automation-id: "e2e-logs";
                            entries: [
                                { id: "1", timestamp: "12:00:01", severity: "info", source: "sys", message: "Boot complete" }
                            ];
                        }

                        fd := SlateFileDialog {
                            height: 160px;
                            automation-id: "e2e-file-dialog";
                            current-path: "/workspace";
                            entries: [
                                { name: "demo.txt", path: "/workspace/demo.txt", is-dir: false, size-label: "1.0 KB", modified-label: "today", selected: false }
                            ];
                        }
                    }
                }
            }
        `, "");

        auto def = built.component("ShowcaseE2EWindow");
        assert(def !is null, text("ShowcaseE2EWindow failed to compile: ", built.diagnostics));
        auto win = def.create();

        auto registry = new McpStateRegistry();
        auto mediaCtrl = new MediaPlayerController([
            MediaTrackData("t1", "Demo Stream", "Slate", 120.0f),
        ]);
        auto dropCtrl = new UploadQueueController([".png", ".pdf"]);
        auto vfs = new InMemoryFileSystem();
        vfs.addFile("/workspace/demo.txt", 1024);
        auto fileCtrl = new FileDialogController(vfs, "/workspace", "/workspace");
        auto gridCtrl = new DataGridController!GridRowData([
            GridRowData("1", "Alpha", "Core", "10", "Ready", "Ready", "success"),
            GridRowData("2", "Beta", "Edge", "20", "Active", "Active", "info"),
        ]);
        auto logCtrl = new RingBufferLogModel("logs", 50);
        logCtrl.append("info", "sys", "Boot complete", "12:00:01");
        auto wizardCtrl = new WizardController(2);

        registry.registerController(mediaCtrl);
        registry.registerController(dropCtrl);
        registry.registerController(fileCtrl);
        registry.registerController(gridCtrl);
        registry.registerController(logCtrl);
        registry.registerController(wizardCtrl);

        auto handle = AgentBuilder.forWindow(win, registry).build();
        auto server = new McpServer(handle.engine());

        // 1. inspect_tree via MCP JSON-RPC
        auto treeResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"inspect_tree","arguments":{}}}`
        ));
        assert(!treeResp["result"]["isError"].boolean);
        string treeJsonStr = treeResp["result"]["content"][0]["text"].str;
        assert(treeJsonStr.canFind("e2e-wizard"));
        assert(treeJsonStr.canFind("e2e-grid"));
        assert(treeJsonStr.canFind("e2e-media-play-pause"));
        assert(treeJsonStr.canFind("e2e-media-scrubber"));
        assert(treeJsonStr.canFind("e2e-dropzone-drop-target"));
        assert(treeJsonStr.canFind("e2e-logs-sev-error"));
        assert(treeJsonStr.canFind("e2e-file-dialog-entry-0"));

        // Step 1: Wizard navigation via click_element
        auto clickWizResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"click_element","arguments":{"id":"#e2e-wizard-next"}}}`
        ));
        assert(!clickWizResp["result"]["isError"].boolean);
        assert(win.getNumber("wizard-step") == 1);

        // Step 2: DataGrid sorting via click_element
        auto clickSortResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"click_element","arguments":{"id":"#e2e-grid-header-0"}}}`
        ));
        assert(!clickSortResp["result"]["isError"].boolean);
        assert(win.getString("grid-sort-dir") == "asc");

        // Step 3: LogViewer filtering via click_element
        auto clickLogSevResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"click_element","arguments":{"id":"#e2e-logs-sev-error"}}}`
        ));
        assert(!clickLogSevResp["result"]["isError"].boolean);
        assert(win.getString("log-sev") == "error");

        // Step 4: MediaPlayer play toggle (click_element) & seek (send_keys)
        auto clickPlayResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"click_element","arguments":{"id":"#e2e-media-play-pause"}}}`
        ));
        assert(!clickPlayResp["result"]["isError"].boolean);
        assert(win.getBool("media-playing") == true);

        auto seekResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"send_keys","arguments":{"element_id":"#e2e-media-scrubber","text":"75.5"}}}`
        ));
        assert(!seekResp["result"]["isError"].boolean);
        assert(win.getNumber("media-pos") == 75.5);

        // Step 5: Dropzone file drop via send_keys
        auto dropResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"send_keys","arguments":{"element_id":"#e2e-dropzone-drop-target","text":"/tmp/test.png"}}}`
        ));
        assert(!dropResp["result"]["isError"].boolean);
        assert(win.getString("dropped-files") == "/tmp/test.png");
        dropCtrl.dropPayload(win.getString("dropped-files"));

        // Step 6: FileDialog selection via click_element
        auto clickFdResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"click_element","arguments":{"id":"#e2e-file-dialog-entry-0"}}}`
        ));
        assert(!clickFdResp["result"]["isError"].boolean);
        assert(win.getNumber("fd-selected") == 0);
        assert(win.getString("fd-input") == "demo.txt");

        // Verification 7: get_state via MCP JSON-RPC
        auto stateResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"get_state","arguments":{"query":"dropzone"}}}`
        ));
        assert(!stateResp["result"]["isError"].boolean);
        string stateText = stateResp["result"]["content"][0]["text"].str;
        assert(stateText.canFind(`"dropzone.queued_count":1`) || stateText.canFind(`"queued_count":1`));

        // Verification 8: get_screenshot via MCP JSON-RPC
        auto shotResp = parseJSON(server.handleLine(
            `{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"get_screenshot","arguments":{}}}`
        ));
        assert(!shotResp["result"]["isError"].boolean);
        string b64Data = shotResp["result"]["content"][0]["data"].str;
        ubyte[] pngBytes = Base64.decode(b64Data);
        // Verify PNG magic signature: 0x89 'P' 'N' 'G'
        assert(pngBytes.length > 8);
        assert(pngBytes[0] == 0x89 && pngBytes[1] == 'P' && pngBytes[2] == 'N' && pngBytes[3] == 'G');
    }
}
