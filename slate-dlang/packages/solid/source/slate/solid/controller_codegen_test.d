/++
    Unit and integration tests for hybrid controller codegen and in-browser MCP runtime.
+/
module slate.solid.controller_codegen_test;

import slate.solid.codegen_controller;
import slate.solid.d_to_ts;
import std.algorithm.searching : canFind;
import std.file : exists, mkdirRecurse, write;
import std.path : buildPath;
import std.process : execute;

private @safe string findSourcePath(string subPath)
{
    string[] prefixes = ["", "../", "../../", "slate-dlang/"];
    foreach (p; prefixes)
    {
        string candidate = p ~ subPath;
        if (exists(candidate))
            return candidate;
    }
    return subPath;
}

// Spec: T5 - Hybrid __traits MCP reflection, @McpIgnore exclusion, and in-browser JSON-RPC 2.0 execution across all 8 controllers (covers U4, U5, W2, G1, G3)
/// Example:
/// ---
/// auto compiler = new ControllerCompiler();
/// string tsCode = compiler.compileControllers("packages/ui/source/slate/components/layouts.d", ["WorkspaceDockController", "WizardController", "MasterDetailController"]);
/// assert(tsCode.canFind("WorkspaceDockController"));
/// ---
@safe unittest
{
    auto compiler = new ControllerCompiler();

    string gridPath = findSourcePath("packages/ui/source/slate/components/datagrid.d");
    string mediaPath = findSourcePath("packages/ui/source/slate/components/media.d");
    string dialogPath = findSourcePath("packages/ui/source/slate/components/file_dialog.d");
    string dropzonePath = findSourcePath("packages/ui/source/slate/components/dropzone.d");
    string logViewerPath = findSourcePath("packages/ui/source/slate/components/log_viewer.d");
    string layoutsPath = findSourcePath("packages/ui/source/slate/components/layouts.d");

    string gridTs = compiler.compileController(gridPath, "DataGridController");
    string mediaTs = compiler.compileController(mediaPath, "MediaPlayerController");
    string dialogTs = compiler.compileController(dialogPath, "FileDialogController");
    string dropzoneTs = compiler.compileController(dropzonePath, "UploadQueueController");
    string logViewerTs = compiler.compileController(logViewerPath, "RingBufferLogModel");
    string layoutsTs = compiler.compileControllers(layoutsPath,
            [
                "WorkspaceDockController", "WizardController",
                "MasterDetailController"
    ]);

    assert(gridTs.canFind("mcpSnapshot"));
    assert(gridTs.canFind("mcpSetProperty"));
    assert(gridTs.canFind("mcpRestoreSnapshot"));
    assert(gridTs.canFind("mcpInvokeAction"));
    assert(gridTs.canFind("mcpCapabilities"));
    assert(gridTs.canFind("paginated"));
    assert(gridTs.canFind("sortable"));
    assert(gridTs.canFind("filterable"));
    assert(gridTs.canFind("selectable"));

    // Ensure @McpIgnore members (such as setItems, model, visibleRows) are excluded from mcpSetProperty
    assert(!gridTs.canFind("case \"setItems\":"));
    assert(!gridTs.canFind("case \"model\":"));

    assert(mediaTs.canFind("MediaPlayerController"));
    assert(mediaTs.canFind("mcpSnapshot"));
    assert(dialogTs.canFind("FileDialogController"));
    assert(dropzoneTs.canFind("UploadQueueController"));
    assert(logViewerTs.canFind("RingBufferLogModel"));
    assert(layoutsTs.canFind("WorkspaceDockController"));
    assert(layoutsTs.canFind("WizardController"));
    assert(layoutsTs.canFind("MasterDetailController"));

    // Write out files and run in Node tsx to verify JSON-RPC 2.0 in-browser execution
    string testDir = "/tmp/slate_mcp_test";
    mkdirRecurse(testDir);

    write(buildPath(testDir, "runtime.ts"), getTestRuntimeShim());
    write(buildPath(testDir, "mcp-runtime.ts"), compiler.generateMcpRuntime());
    write(buildPath(testDir, "datagrid.ts"), gridTs);
    write(buildPath(testDir, "media.ts"), mediaTs);
    write(buildPath(testDir, "file_dialog.ts"), dialogTs);
    write(buildPath(testDir, "dropzone.ts"), dropzoneTs);
    write(buildPath(testDir, "log_viewer.ts"), logViewerTs);
    write(buildPath(testDir, "layouts.ts"), layoutsTs);

    string rpcScript = q"{
import { McpStateRegistry, McpServer } from "./mcp-runtime";
import { DataGridController } from "./datagrid";
import { MediaPlayerController } from "./media";
import { FileDialogController, InMemoryFileSystem } from "./file_dialog";
import { UploadQueueController } from "./dropzone";
import { RingBufferLogModel } from "./log_viewer";
import { WorkspaceDockController, WizardController, MasterDetailController } from "./layouts";

async function run() {
    // 1. DataGridController
    const grid = new DataGridController([
        { id: "1", col0: "Alice", col1: "Engineering", col2: "100", col3: "Active", badge: "OK", badgeVariant: "default", selected: false },
        { id: "2", col0: "Bob", col1: "Marketing", col2: "50", col3: "Active", badge: "OK", badgeVariant: "default", selected: false },
        { id: "3", col0: "Charlie", col1: "Design", col2: "75", col3: "Active", badge: "OK", badgeVariant: "default", selected: false }
    ], 2);
    const gridSnap = grid.mcpSnapshot();
    if (gridSnap.total_rows !== 3) throw new Error(`Grid total_rows mismatch: ${gridSnap.total_rows}`);
    grid.cycleSortColumn(0);
    if (grid.sortColumn() !== 0 || grid.sortDirection() !== "asc") {
        throw new Error(`Grid sort mismatch: col=${grid.sortColumn()} dir=${grid.sortDirection()}`);
    }

    // 2. MediaPlayerController - verify method non-clobbering: setVolume / volume
    const media = new MediaPlayerController();
    media.setVolume(0.8);
    if (Math.abs(media.volume() - 0.8) > 0.001) throw new Error("Media volume mismatch");
    media.seekTo(42.5);
    if (Math.abs(media.positionSeconds() - 42.5) > 0.001) throw new Error("Media position mismatch");
    const mediaSnap = media.mcpSnapshot();
    if (Math.abs(mediaSnap.volume - 0.8) > 0.001) throw new Error(`Media snapshot volume mismatch: ${mediaSnap.volume}`);

    // 3. FileDialogController & InMemoryFileSystem
    const fs = new InMemoryFileSystem();
    fs.addDirectory("/home/user");
    fs.addFile("/home/user/document.txt", 2048, "2026-10-16");
    const dialog = new FileDialogController(fs, "/home/user", "/home");
    const dialogSnap = dialog.mcpSnapshot();
    if (dialogSnap.current_path !== "/home/user") throw new Error(`Dialog current_path mismatch: ${dialogSnap.current_path}`);

    // 4. UploadQueueController
    const queue = new UploadQueueController();
    const qSnap = queue.mcpSnapshot();
    if (queue.itemCount() !== 0 || qSnap.selected_index !== -1) throw new Error("Upload queue state mismatch");

    // 5. RingBufferLogModel
    const logs = new RingBufferLogModel(100);
    logs.append("info", "test", "Hello world", "12:00:00");
    if (logs.totalCount() !== 1) throw new Error("Log length mismatch");

    // 6. WorkspaceDockController
    const dock = new WorkspaceDockController();
    const dockSnap = dock.mcpSnapshot();
    if (dockSnap.left_open !== true) throw new Error("Dock left_open mismatch");

    // 7. WizardController
    const wiz = new WizardController(3);
    if (wiz.currentStep() !== 0) throw new Error("Wiz currentStep mismatch");

    // 8. MasterDetailController
    const md = new MasterDetailController(["item-a", "item-b"]);
    if (md.selectedId !== "") throw new Error("MD selectedId mismatch");

    // ── McpServer & McpStateRegistry integration across all 8 controllers ──
    const registry = new McpStateRegistry();
    registry.register("grid", grid);
    registry.register("media", media);
    registry.register("dialog", dialog);
    registry.register("queue", queue);
    registry.register("log", logs);
    registry.register("dock", dock);
    registry.register("wiz", wiz);
    registry.register("md", md);

    const server = new McpServer(registry);

    // Test list_targets: all 8 controllers registered
    const listRes = await server.handleJsonRpc({
        jsonrpc: "2.0",
        id: 1,
        method: "list_targets",
        params: {}
    });
    if (listRes.error) throw new Error("list_targets failed: " + JSON.stringify(listRes.error));
    if (!listRes.result?.targets || listRes.result.targets.length !== 8) {
        throw new Error("Invalid list_targets count: " + JSON.stringify(listRes.result));
    }

    // Test get_state for DataGrid
    const stateRes = await server.handleJsonRpc({
        jsonrpc: "2.0",
        id: 2,
        method: "get_state",
        params: { target_id: "grid" }
    });
    if (stateRes.error) throw new Error("get_state failed: " + JSON.stringify(stateRes.error));
    if (stateRes.result.total_rows !== 3 || stateRes.result.total_pages !== 2) {
        throw new Error("Invalid state: " + JSON.stringify(stateRes.result));
    }

    // Test invoke_action next on WizardController
    const wizNextRes = await server.handleJsonRpc({
        jsonrpc: "2.0",
        id: 3,
        method: "invoke_action",
        params: { target_id: "wiz", action: "next", payload: {} }
    });
    if (wizNextRes.error) throw new Error("wiz next failed: " + JSON.stringify(wizNextRes.error));
    if (wiz.currentStep() !== 1) throw new Error(`wiz currentStep: ${wiz.currentStep()}`);

    // Test invoke_action set_filter on MasterDetailController
    const mdFilterRes = await server.handleJsonRpc({
        jsonrpc: "2.0",
        id: 4,
        method: "invoke_action",
        params: { target_id: "md", action: "set_filter", payload: "search-query" }
    });
    if (mdFilterRes.error) throw new Error("md set_filter failed: " + JSON.stringify(mdFilterRes.error));
    if (md.filterQuery() !== "search-query") throw new Error(`md filterQuery: ${md.filterQuery()}`);

    // Test set_property with transactional rollback on invalid property: returns code -32602
    const dockBefore = JSON.stringify(registry.getState("dock"));
    const setFailRes = await server.handleJsonRpc({
        jsonrpc: "2.0",
        id: 5,
        method: "set_property",
        params: { target_id: "dock", property: "left_width", value: -50 }
    });
    if (!setFailRes.error || setFailRes.error.code !== -32602) {
        throw new Error("Expected -32602 error on invalid property: " + JSON.stringify(setFailRes));
    }
    const dockAfter = JSON.stringify(registry.getState("dock"));
    if (dockBefore !== dockAfter) {
        throw new Error("Transactional rollback failed: dock state changed after error: " + dockAfter);
    }

    // Test fine-grained reactivity via .subscribe(fn)
    let notified = false;
    let notifiedSnap: any = null;
    const unsub = dock.subscribe((snap: any) => {
        notified = true;
        notifiedSnap = snap;
    });

    const setValidRes = await server.handleJsonRpc({
        jsonrpc: "2.0",
        id: 6,
        method: "set_property",
        params: { target_id: "dock", property: "left_open", value: false }
    });
    if (setValidRes.error) throw new Error("Expected valid set_property: " + JSON.stringify(setValidRes.error));
    if (!notified || !notifiedSnap || notifiedSnap.left_open !== false) {
        throw new Error("Reactivity subscription failed to notify updated state");
    }
    unsub();

    console.log("ALL_CONTROLLER_AND_MCP_TESTS_OK");
}

run().catch((e) => {
    console.error("Test failed:", e);
    process.exit(1);
});
}";
    write(buildPath(testDir, "test_mcp_rpc.ts"), rpcScript);

    auto res = execute(["npx", "tsx", buildPath(testDir, "test_mcp_rpc.ts")]);
    assert(res.status == 0, "MCP RPC test execution failed: " ~ res.output);
    assert(res.output.canFind("ALL_CONTROLLER_AND_MCP_TESTS_OK"));
}

// Spec: T5b - ControllerCompiler emits valid MCP runtime shim and fine-grained reactivity subscriber hooks (covers U5, G1)
/// Example:
/// ---
/// auto compiler = new ControllerCompiler();
/// string mcpRuntime = compiler.generateMcpRuntime();
/// assert(mcpRuntime.canFind("export class McpStateRegistry"));
/// ---
@safe unittest
{
    auto compiler = new ControllerCompiler();
    string mcpRuntime = compiler.generateMcpRuntime();

    assert(mcpRuntime.canFind("export interface McpControllable"));
    assert(mcpRuntime.canFind("export interface Paginated"));
    assert(mcpRuntime.canFind("export interface Sortable"));
    assert(mcpRuntime.canFind("export interface Filterable"));
    assert(mcpRuntime.canFind("export interface Selectable"));
    assert(mcpRuntime.canFind("export class McpStateRegistry"));
    assert(mcpRuntime.canFind("export class McpServer"));
    assert(mcpRuntime.canFind("list_targets"));
    assert(mcpRuntime.canFind("get_state"));
    assert(mcpRuntime.canFind("set_property"));
    assert(mcpRuntime.canFind("invoke_action"));
}
