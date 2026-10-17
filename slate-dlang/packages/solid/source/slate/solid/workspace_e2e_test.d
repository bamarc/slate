/++
    End-to-End workspace test compiling all 64 Slint UI files and D controllers.
+/
module slate.solid.workspace_e2e_test;

import slate.solid.ast;
import slate.solid.compiler;
import slate.solid.parser;
import slate.solid.d_to_ts;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.exception : assertThrown;
import std.file : dirEntries, exists, isFile, mkdirRecurse, readText,
    rmdirRecurse, SpanMode, write;
import std.path : baseName, buildPath, extension;
import std.process : execute;

private @trusted size_t countTsxFiles(string dir)
{
    size_t count = 0;
    foreach (entry; dirEntries(dir, SpanMode.depth))
    {
        if (entry.isFile && entry.name.extension == ".tsx"
                && baseName(entry.name) != "slate-runtime.tsx")
        {
            count++;
        }
    }
    return count;
}

private @trusted void verifyCleanLowering(string dir)
{
    foreach (entry; dirEntries(dir, SpanMode.depth))
    {
        if (entry.isFile && entry.name.extension == ".tsx")
        {
            string content = readText(entry.name);
            assert(!content.canFind("\\{"),
                    "Found unlowered string interpolation '\\{' in: " ~ entry.name);
            assert(!content.canFind("Math.mod"), "Found unlowered 'Math.mod' in: " ~ entry.name);
            assert(!content.canFind("-touch_"),
                    "Found invalid '-touch_' identifier in: " ~ entry.name);
        }
    }
}

// Spec: T3 - Full 64-file ui/ workspace compilation, esbuild bundle verification, and in-browser MCP execution (covers U1, U2, E4, G3)
/// Example:
/// ---
/// auto compiler = new WorkspaceCompiler();
/// compiler.compileWorkspace("../ui", "/tmp/solid-out");
/// assert(exists("/tmp/solid-out/index.ts"));
/// ---
@safe unittest
{
    string uiDir = exists("ui") ? "ui" : (exists("../ui") ? "../ui" : "../../ui");
    assert(exists(uiDir), "UI directory not found: " ~ uiDir);

    string outDir = "/tmp/slate_solid_workspace_test";
    if (exists(outDir))
    {
        rmdirRecurse(outDir);
    }
    mkdirRecurse(outDir);

    auto compiler = new WorkspaceCompiler();
    WorkspaceCompileResult res = compiler.compileWorkspace(uiDir, outDir);

    assert(res.compiledCount >= 64,
            "Expected at least 64 .slint files compiled, got: " ~ res.compiledCount.to!string);
    assert(res.errorCount == 0, "Encountered compilation errors: " ~ res.errorMessages.to!string);

    assert(exists(buildPath(outDir, "index.ts")));
    assert(exists(buildPath(outDir, "theme.tsx")));
    assert(exists(buildPath(outDir, "mcp.tsx")));
    assert(exists(buildPath(outDir, "button.tsx")));
    assert(exists(buildPath(outDir, "data_grid.tsx")));
    assert(exists(buildPath(outDir, "slate-runtime.tsx")));
    assert(exists(buildPath(outDir, "mcp-runtime.ts")));
    assert(exists(buildPath(outDir, "chart.ts")));
    assert(exists(buildPath(outDir, "layouts.ts")));
    assert(exists(buildPath(outDir, "package.json")));

    // 1. Verify all .tsx files exist
    size_t tsxCount = countTsxFiles(outDir);
    assert(tsxCount >= 64,
            "Expected at least 64 component/layout .tsx files, got: " ~ tsxCount.to!string);

    // 2. Verify clean lowering across all .tsx files: zero \{, zero Math.mod, zero -touch_
    verifyCleanLowering(outDir);

    // 3. Verify bundling with esbuild
    string bundleOut = buildPath(outDir, "bundle.js");
    auto esbuildRes = execute([
        "npx", "esbuild", buildPath(outDir, "index.ts"), "--bundle",
        "--outfile=" ~ bundleOut, "--platform=neutral", "--format=esm",
        "--external:solid-js"
    ]);
    assert(esbuildRes.status == 0, "esbuild bundling failed: " ~ esbuildRes.output);
    assert(exists(bundleOut), "Bundle output file not found: " ~ bundleOut);

    // 4. Test 4 in-browser MCP tools via JSON-RPC 2.0 in Node
    string mcpRunner = q"{
import { McpStateRegistry, McpServer } from "./mcp-runtime";
import { DataGridController } from "./datagrid";
import { WorkspaceDockController, WizardController } from "./layouts";

async function main() {
    const registry = new McpStateRegistry();
    const server = new McpServer(registry);

    const dock = new WorkspaceDockController();
    const wiz = new WizardController(3);
    const grid = new DataGridController([], 10);

    registry.register("dock", dock);
    registry.register("wiz", wiz);
    registry.register("grid", grid);

    // Tool 1: list_targets
    const listRes = await server.handleJsonRpc({ jsonrpc: "2.0", id: 1, method: "list_targets", params: {} });
    if (!listRes.result?.targets || listRes.result.targets.length !== 3) {
        throw new Error("list_targets failed: " + JSON.stringify(listRes));
    }

    // Tool 2: get_state
    const stateRes = await server.handleJsonRpc({ jsonrpc: "2.0", id: 2, method: "get_state", params: { target_id: "dock" } });
    if (stateRes.result?.left_open !== true) {
        throw new Error("get_state failed: " + JSON.stringify(stateRes));
    }

    // Tool 3: set_property with rollback (-32602)
    const setFail = await server.handleJsonRpc({ jsonrpc: "2.0", id: 3, method: "set_property", params: { target_id: "dock", property: "left_width", value: -10 } });
    if (!setFail.error || setFail.error.code !== -32602) {
        throw new Error("set_property rollback failed: " + JSON.stringify(setFail));
    }
    const stateAfterFail = await server.handleJsonRpc({ jsonrpc: "2.0", id: 4, method: "get_state", params: { target_id: "dock" } });
    if (stateAfterFail.result?.left_width !== 220) {
        throw new Error("dock.left_width was not rolled back: " + JSON.stringify(stateAfterFail));
    }

    // Tool 4: invoke_action
    const actionRes = await server.handleJsonRpc({ jsonrpc: "2.0", id: 5, method: "invoke_action", params: { target_id: "wiz", action: "next", payload: {} } });
    if (actionRes.result !== 1) {
        throw new Error("invoke_action failed: " + JSON.stringify(actionRes));
    }

    console.log("WORKSPACE_MCP_4_TOOLS_OK");
}

main().catch((e) => {
    console.error("Test error:", e);
    process.exit(1);
});
}";
    write(buildPath(outDir, "test_workspace_mcp.ts"), mcpRunner);

    auto mcpRes = execute([
        "npx", "tsx", buildPath(outDir, "test_workspace_mcp.ts")
    ]);
    assert(mcpRes.status == 0, "Workspace MCP test failed: " ~ mcpRes.output);
    assert(mcpRes.output.canFind("WORKSPACE_MCP_4_TOOLS_OK"));
}

// Spec: T6c - Diagnostic reporting (W1/T6) for unclosed Slint files and unclosed D files (covers W1, G2)
/// Example:
/// ---
/// auto parser = new SlintParser("component Unclosed { Rectangle {");
/// assertThrown!SlintParseError(parser.parseModule("unclosed.slint"));
/// ---
@safe unittest
{
    // 1. Unclosed Slint file reports SlintParseError with line info
    string unclosedSlint = "export component Broken {\n    Rectangle {\n        width: 100px;\n";
    auto parser = new SlintParser(unclosedSlint, "broken.slint");
    try
    {
        parser.parseModule("broken.slint");
        assert(false, "Should have thrown SlintParseError");
    }
    catch (SlintParseError err)
    {
        assert(err.file == "broken.slint");
        assert(err.line >= 3);
        assert(err.msg.length > 0);
    }

    // 2. Unclosed D controller file reports DParseError with line info
    string unclosedD = "class BrokenController {\n    void foo() {\n        int x = 1;\n";
    auto dTranspiler = new DToTsTranspiler();
    try
    {
        dTranspiler.transpileSource(unclosedD, "broken.d");
        assert(false, "Should have thrown DParseError");
    }
    catch (DParseError err)
    {
        assert(err.file == "broken.d");
        assert(err.line >= 3);
        assert(err.msg.length > 0);
    }
}
