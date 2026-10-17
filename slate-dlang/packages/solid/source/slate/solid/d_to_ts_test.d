/++
    Unit and integration tests for Dlang to TypeScript transpiler (slate:solid).
+/
module slate.solid.d_to_ts_test;

import slate.solid.d_to_ts;
import std.algorithm.searching : canFind;
import std.file : exists, mkdirRecurse, readText, write;
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

// Spec: T4 - Compile Dlang controller and chart utility bodies to executable TypeScript (covers U3, E3, G3)
/// Example:
/// ---
/// auto transpiler = new DToTsTranspiler();
/// string tsCode = transpiler.transpileFile("../packages/core/source/slate/utils/chart.d");
/// assert(tsCode.canFind("export function buildSparklinePath"));
/// ---
@safe unittest
{
    auto transpiler = new DToTsTranspiler();

    // 1. Transpile chart.d
    string chartPath = findSourcePath("packages/core/source/slate/utils/chart.d");
    string chartTs = transpiler.transpileFile(chartPath);
    assert(chartTs.canFind("buildSparklinePath"));
    assert(chartTs.canFind("buildDonutArcPath"));
    assert(chartTs.canFind("normalizeSeries"));

    // 2. Transpile datagrid.d
    string gridPath = findSourcePath("packages/ui/source/slate/components/datagrid.d");
    string gridTs = transpiler.transpileFile(gridPath);
    assert(gridTs.canFind("DataGridController"));
    assert(gridTs.canFind("recompute"));
    assert(gridTs.canFind("cycleSortColumn"));
    assert(gridTs.canFind("compareCellValues"));

    // 3. Transpile file_dialog.d
    string fileDialogPath = findSourcePath("packages/ui/source/slate/components/file_dialog.d");
    string fileDialogTs = transpiler.transpileFile(fileDialogPath);
    assert(fileDialogTs.canFind("FileDialogController"));
    assert(fileDialogTs.canFind("InMemoryFileSystem"));
    assert(fileDialogTs.canFind("normalizeVirtualPath"));
    assert(fileDialogTs.canFind("isPathWithinSandbox"));
    // Host OS LocalFileSystem should be stripped in browser bundle
    assert(!fileDialogTs.canFind("class LocalFileSystem"));

    // 4. Transpile media.d
    string mediaPath = findSourcePath("packages/ui/source/slate/components/media.d");
    string mediaTs = transpiler.transpileFile(mediaPath);
    assert(mediaTs.canFind("MediaPlayerController"));
    assert(mediaTs.canFind("formatMediaTime"));

    // 5. Transpile layouts.d
    string layoutsPath = findSourcePath("packages/ui/source/slate/components/layouts.d");
    string layoutsTs = transpiler.transpileFile(layoutsPath);
    assert(layoutsTs.canFind("WorkspaceDockController"));
    assert(layoutsTs.canFind("WizardController"));
    assert(layoutsTs.canFind("MasterDetailController"));

    // 6. Runtime execution in Node / tsx
    string testDir = "/tmp/slate_ts_test";
    mkdirRecurse(testDir);

    write(buildPath(testDir, "chart.ts"), chartTs);
    write(buildPath(testDir, "datagrid.ts"), gridTs);
    write(buildPath(testDir, "file_dialog.ts"), fileDialogTs);
    write(buildPath(testDir, "media.ts"), mediaTs);
    write(buildPath(testDir, "layouts.ts"), layoutsTs);
    write(buildPath(testDir, "runtime.ts"), getTestRuntimeShim());

    string testRunner = q"{
import { buildSparklinePath, buildDonutArcPath } from "./chart";
import { DataGridController, compareCellValues } from "./datagrid";
import { InMemoryFileSystem, FileDialogController, normalizeVirtualPath, isPathWithinSandbox } from "./file_dialog";
import { MediaPlayerController, formatMediaTime } from "./media";
import { WorkspaceDockController, WizardController, MasterDetailController } from "./layouts";

// ── Chart Tests ──
const pEmpty = buildSparklinePath([], 100, 30);
if (pEmpty !== "M 0 15.00 L 100.00 15.00") throw new Error(`Sparkline empty mismatch: ${pEmpty}`);

const pFlat = buildSparklinePath([5, 5, 5], 100, 30);
if (pFlat !== "M 0.00 15.00 L 50.00 15.00 L 100.00 15.00") throw new Error(`Sparkline flat mismatch: ${pFlat}`);

const arc = buildDonutArcPath(0.75, 50, 50, 40);
if (!arc.startsWith("M ") || !arc.includes(" A ")) throw new Error(`Donut arc mismatch: ${arc}`);

// ── DataGrid Tests: Sorting & Pagination ──
const grid = new DataGridController([
    { id: "1", col0: "100", col1: "Beta", col2: "A", col3: "Z", badge: "", badgeVariant: "default", selected: false },
    { id: "2", col0: "25", col1: "Alpha", col2: "B", col3: "Y", badge: "", badgeVariant: "default", selected: false },
    { id: "3", col0: "5", col1: "Gamma", col2: "C", col3: "X", badge: "", badgeVariant: "default", selected: false }
], 2);

// Numeric sort ascending
grid.sortByColumn(0, "asc");
const rowsAsc = grid.visibleRows();
if (rowsAsc[0].col0 !== "5" || rowsAsc[1].col0 !== "25") {
    throw new Error(`DataGrid numeric sort asc failed: ${rowsAsc.map(r => r.col0).join(", ")}`);
}

// Numeric sort descending
grid.sortByColumn(0, "desc");
const rowsDesc = grid.visibleRows();
if (rowsDesc[0].col0 !== "100" || rowsDesc[1].col0 !== "25") {
    throw new Error(`DataGrid numeric sort desc failed: ${rowsDesc.map(r => r.col0).join(", ")}`);
}

// Alpha sort ascending
grid.sortByColumn(1, "asc");
const rowsAlpha = grid.visibleRows();
if (rowsAlpha[0].col1 !== "Alpha") {
    throw new Error(`DataGrid alpha sort failed: ${rowsAlpha[0].col1}`);
}

// Pagination
if (grid.totalPages() !== 2) throw new Error(`DataGrid totalPages: ${grid.totalPages()}`);
grid.goToPage(2);
if (grid.currentPage() !== 2) throw new Error(`DataGrid currentPage: ${grid.currentPage()}`);

// ── FileDialog & Path Tests ──
if (normalizeVirtualPath("/foo/bar/../baz") !== "/foo/baz") throw new Error("normalizeVirtualPath dotdot failed");
if (normalizeVirtualPath("/foo/./bar") !== "/foo/bar") throw new Error("normalizeVirtualPath dot failed");
if (!isPathWithinSandbox("/foo/bar", "/foo")) throw new Error("isPathWithinSandbox inside failed");
if (isPathWithinSandbox("/foo/bar", "/bar")) throw new Error("isPathWithinSandbox outside failed");

const fs = new InMemoryFileSystem();
fs.addDirectory("/home/user");
fs.addFile("/home/user/test.txt", 1024, "2026-10-16");
const dlg = new FileDialogController(fs, "/home/user", "/home");
if (dlg.currentPath() !== "/home/user") throw new Error(`FileDialog currentPath: ${dlg.currentPath()}`);
if (dlg.visibleEntries().length !== 1 || dlg.visibleEntries()[0].name !== "test.txt") throw new Error("FileDialog entry listing failed");

// ── Media Time Formatting Tests ──
if (formatMediaTime(3661) !== "01:01:01") throw new Error(`formatMediaTime(3661): ${formatMediaTime(3661)}`);
if (formatMediaTime(125) !== "02:05") throw new Error(`formatMediaTime(125): ${formatMediaTime(125)}`);
if (formatMediaTime(0) !== "00:00") throw new Error(`formatMediaTime(0): ${formatMediaTime(0)}`);

// ── Layout Controllers Tests ──
const dock = new WorkspaceDockController();
if (dock.leftOpen !== true) throw new Error("Dock leftOpen initial");
dock.togglePanel("left");
if (dock.leftOpen !== false) throw new Error("Dock leftOpen after toggle");

const wiz = new WizardController(3);
if (wiz.currentStep() !== 0) throw new Error("Wizard currentStep initial");
wiz.nextStep();
if (wiz.currentStep() !== 1) throw new Error("Wizard currentStep after next");

const md = new MasterDetailController(["id-1", "id-2"]);
if (md.selectedId !== "") throw new Error("MasterDetail initial selectedId");
md.selectIndex(1);
if (md.selectedId !== "id-2") throw new Error(`MasterDetail selectedId: ${md.selectedId}`);

console.log("ALL_D_TO_TS_EXECUTION_TESTS_OK");
}";
    write(buildPath(testDir, "run_all_d_tests.ts"), testRunner);

    auto res = execute(["npx", "tsx", buildPath(testDir, "run_all_d_tests.ts")]);
    assert(res.status == 0, "Node tsx execution failed: " ~ res.output);
    assert(res.output.canFind("ALL_D_TO_TS_EXECUTION_TESTS_OK"));
}

// Spec: T4b - Bounded recursion depth in D parser prevents stack-overflow DoS (covers G2)
/// Example:
/// ---
/// auto transpiler = new DToTsTranspiler();
/// string deep = "void deep() { " ~ "...150 braces..." ~ " }";
/// assertThrown!DParseError(transpiler.transpileSource(deep, "deep.d"));
/// ---
@safe unittest
{
    import std.array : replicate;
    import std.exception : assertThrown;

    string deep = "void deep() { " ~ "{ ".replicate(150) ~ "int x = 1;"
        ~ " }".replicate(150) ~ " }\n";
    auto transpiler = new DToTsTranspiler();
    assertThrown!DParseError(transpiler.transpileSource(deep, "deep.d"));
}

// Spec: T4c - D contract lowering (`in` conditions) and scope guards execution in Node (covers G1, G3)
/// Example:
/// ---
/// auto transpiler = new DToTsTranspiler();
/// string dSrc = "int divide(int a, int b) in (b != 0) { return a / b; }";
/// string tsSrc = transpiler.transpileSource(dSrc, "contracts.d");
/// assert(tsSrc.canFind("assert(b !== 0);"));
/// ---
@safe unittest
{
    auto transpiler = new DToTsTranspiler();

    string dCode = q"{
module test_contracts;

int divide(int a, int b)
in (b != 0)
{
    return a / b;
}

}";

    string tsCode = transpiler.transpileSource(dCode, "test_contracts.d");
    assert(tsCode.canFind("assert(b != 0);") || tsCode.canFind("assert(b !== 0);"));

    string testDir = "/tmp/slate_contract_test";
    mkdirRecurse(testDir);
    write(buildPath(testDir, "runtime.ts"), getTestRuntimeShim());
    write(buildPath(testDir, "contracts.ts"), tsCode);

    string runner = q"{
import { divide } from "./contracts";

// Test contract pass
const ok = divide(10, 2);
if (ok !== 5) throw new Error(`divide(10, 2) = ${ok}`);

// Test contract failure throws
let threw = false;
try {
    divide(10, 0);
} catch (e: any) {
    threw = true;
}
if (!threw) throw new Error("Expected divide(10, 0) to throw assertion error");

console.log("D_CONTRACTS_TEST_OK");
}";
    write(buildPath(testDir, "run_contract_test.ts"), runner);

    auto res = execute([
        "npx", "tsx", buildPath(testDir, "run_contract_test.ts")
    ]);
    assert(res.status == 0, "Contracts execution failed: " ~ res.output);
    assert(res.output.canFind("D_CONTRACTS_TEST_OK"));
}

// Spec: T6b - Structured syntax error diagnostics on unclosed comments and delimiters (covers W1)
/// Example:
/// ---
/// auto transpiler = new DToTsTranspiler();
/// assertThrown!DParseError(transpiler.transpileSource("/* unclosed comment", "unclosed.d"));
/// ---
@safe unittest
{
    import std.exception : assertThrown;

    auto transpiler = new DToTsTranspiler();

    // 1. Unclosed block comment
    assertThrown!DParseError(transpiler.transpileSource("/* unclosed block", "unclosed_block.d"));

    // 2. Unclosed nested comment
    assertThrown!DParseError(transpiler.transpileSource("/+ unclosed nested", "unclosed_nested.d"));

    // 3. Unclosed string literal
    assertThrown!DParseError(transpiler.transpileSource("string s = \"unclosed string;\n",
            "unclosed_str.d"));

    // 4. Unclosed block delimiter at EOF
    assertThrown!DParseError(transpiler.transpileSource("void foo() {\n    int a = 1;\n",
            "unclosed_block_eof.d"));
}
