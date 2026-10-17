/++
    Batch workspace compiler for Slate .slint UI files and D controllers.
+/
module slate.solid.compiler;

import slate.solid.ast;
import slate.solid.codegen_controller;
import slate.solid.codegen_tsx;
import slate.solid.d_to_ts;
import slate.solid.lexer;
import slate.solid.parser;
import slate.solid.sema;
import std.algorithm.sorting : sort;
import std.array : Appender, appender;
import std.conv : to;
import std.file : dirEntries, exists, isFile, mkdirRecurse, readText, SpanMode, write;
import std.path : baseName, buildPath, dirName, extension, stripExtension;
import std.string : strip;

/// Result of a batch workspace compilation.
struct WorkspaceCompileResult
{
    size_t compiledCount;
    size_t errorCount;
    string[] errorMessages;
}

/// Target definition for controller compilation.
struct ControllerTarget
{
    string subPath;
    string[] classNames;
    string outFileName;
}

/// Batch compiler for .slint and D controller directories.
class WorkspaceCompiler
{
    private SlintSema sema;
    private SolidTsxGenerator tsxGen;
    private DToTsTranspiler dTranspiler;
    private ControllerCompiler ctrlCompiler;

    @safe this()
    {
        this.sema = new SlintSema();
        this.tsxGen = new SolidTsxGenerator(sema);
        this.dTranspiler = new DToTsTranspiler();
        this.ctrlCompiler = new ControllerCompiler();
    }

    private @trusted string[] collectSlintFiles(string dir)
    {
        string[] files;
        // Do not follow symlinks (prevent directory traversal out of ui workspace)
        foreach (entry; dirEntries(dir, SpanMode.depth, false))
        {
            if (!entry.isSymlink && entry.isFile && entry.name.extension == ".slint")
            {
                files ~= entry.name;
            }
        }
        return files;
    }

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

    /// Compile all .slint files in uiDir and controllers into outDir.
    @safe WorkspaceCompileResult compileWorkspace(string uiDir, string outDir)
    {
        WorkspaceCompileResult result;
        mkdirRecurse(outDir);

        string[] slintFiles = collectSlintFiles(uiDir);
        string showcaseDir = findSourcePath("reference/slate-rust/examples/showcase/ui");
        if (exists(showcaseDir))
        {
            foreach (f; collectSlintFiles(showcaseDir))
            {
                slintFiles ~= f;
            }
        }
        slintFiles.sort();

        string[] emittedModules;

        // 1. Compile all .slint files
        foreach (filePath; slintFiles)
        {
            string fileName = baseName(filePath);
            string baseModName = fileName.stripExtension();

            try
            {
                string source = readText(filePath);
                auto parser = new SlintParser(source, filePath);
                auto mod = parser.parseModule(filePath);

                string tsx = tsxGen.generateModule(mod);
                string outPath = buildPath(outDir, baseModName ~ ".tsx");
                write(outPath, tsx);

                emittedModules ~= baseModName;
                result.compiledCount++;
            }
            catch (Exception e)
            {
                result.errorCount++;
                result.errorMessages ~= filePath ~ ": " ~ e.msg;
            }
        }

        // 2. Emit runtime shims
        write(buildPath(outDir, "runtime.ts"), getTestRuntimeShim());
        write(buildPath(outDir, "slate-runtime.tsx"), getSlateRuntimeSource());
        write(buildPath(outDir, "mcp-runtime.ts"), ctrlCompiler.generateMcpRuntime());

        // 3. Compile all 7 D controllers and chart utilities
        ControllerTarget[] targets = [
            ControllerTarget("packages/core/source/slate/utils/chart.d",
                    [], "chart.ts"),
            ControllerTarget("packages/ui/source/slate/components/datagrid.d",
                    ["DataGridController"], "datagrid.ts"),
            ControllerTarget("packages/ui/source/slate/components/media.d",
                    ["MediaPlayerController"], "media.ts"),
            ControllerTarget("packages/ui/source/slate/components/file_dialog.d",
                    ["FileDialogController"], "file_dialog.ts"),
            ControllerTarget("packages/ui/source/slate/components/dropzone.d",
                    ["UploadQueueController"], "dropzone.ts"),
            ControllerTarget("packages/ui/source/slate/components/log_viewer.d",
                    ["RingBufferLogModel"], "log_viewer.ts"),
            ControllerTarget("packages/ui/source/slate/components/layouts.d",
                    [
                        "WorkspaceDockController", "WizardController",
                        "MasterDetailController"
            ], "layouts.ts"),
        ];

        foreach (tgt; targets)
        {
            string fullPath = findSourcePath(tgt.subPath);
            if (exists(fullPath))
            {
                try
                {
                    string code;
                    if (tgt.classNames.length > 0)
                    {
                        code = ctrlCompiler.compileControllers(fullPath, tgt.classNames);
                    }
                    else
                    {
                        code = dTranspiler.transpileFile(fullPath);
                    }
                    write(buildPath(outDir, tgt.outFileName), code);
                }
                catch (Exception e)
                {
                    result.errorCount++;
                    result.errorMessages ~= fullPath ~ ": " ~ e.msg;
                }
            }
        }

        // 4. Emit index.ts barrel
        auto indexBuf = appender!string();
        indexBuf.put(
                "// Auto-generated by slate:solid workspace compiler. DO NOT EDIT DIRECTLY.\n\n");
        indexBuf.put("export * from \"./runtime\";\n");
        indexBuf.put("export * from \"./slate-runtime\";\n");
        indexBuf.put("export * from \"./mcp-runtime\";\n");
        indexBuf.put("export * from \"./chart\";\n");
        indexBuf.put("export * from \"./datagrid\";\n");
        indexBuf.put("export * from \"./media\";\n");
        indexBuf.put("export * from \"./file_dialog\";\n");
        indexBuf.put("export * from \"./dropzone\";\n");
        indexBuf.put("export * from \"./log_viewer\";\n");
        indexBuf.put("export * from \"./layouts\";\n\n");

        foreach (mod; emittedModules)
        {
            indexBuf.put("export * from \"./" ~ mod ~ "\";\n");
        }
        write(buildPath(outDir, "index.ts"), indexBuf.data);

        // 5. Emit package.json
        string pkgJson = q"{
{
  "name": "@slate/solid",
  "version": "0.1.0",
  "description": "Slate Declarative UI Framework compiled to SolidJS and TypeScript",
  "main": "index.ts",
  "types": "index.ts",
  "dependencies": {
    "solid-js": "^1.8.0"
  },
  "devDependencies": {
    "@babel/core": "^7.26.0",
    "@babel/preset-typescript": "^7.26.0",
    "babel-preset-solid": "^1.9.0",
    "esbuild": "^0.25.0",
    "puppeteer-core": "^24.0.0"
  }
}
}";
        write(buildPath(outDir, "package.json"), pkgJson.strip() ~ "\n");

        return result;
    }

    private @safe string getSlateRuntimeSource()
    {
        return q"{
// Slate SolidJS Runtime Utilities.

import { createSignal, createEffect, onCleanup, Accessor, JSX } from "solid-js";

export function createInOutProp<T>(
    getProp: () => T | undefined,
    setProp?: (val: T) => void,
    defaultValue?: T
): [Accessor<T>, (val: T) => void] {
    const [local, setLocal] = createSignal<T>(getProp() !== undefined ? getProp()! : defaultValue!);

    createEffect(() => {
        const v = getProp();
        if (v !== undefined) {
            setLocal(() => v);
        }
    });

    const getter = () => local();
    const setter = (val: T) => {
        setLocal(() => val);
        setProp?.(val);
    };

    return [getter, setter];
}

export const transparent = "transparent";
export const Colors = {
    transparent: "transparent",
};

export function transparentize(color: string, amount: number = 0.5): string {
    if (!color) return "transparent";
    if (color.startsWith("#") && (color.length === 7 || color.length === 9)) {
        const hex = Math.round((1 - amount) * 255).toString(16).padStart(2, "0");
        return color.slice(0, 7) + hex;
    }
    return color;
}

export function SlateTimer(props: { interval?: number; running?: boolean; onTriggered?: () => void }): JSX.Element {
    createEffect(() => {
        if (props.running !== false && props.onTriggered) {
            const timer = setInterval(() => {
                props.onTriggered?.();
            }, props.interval ?? 100);
            onCleanup(() => clearInterval(timer));
        }
    });
    return null as any;
}

export function animationTick(): number {
    return typeof performance !== "undefined" ? performance.now() : Date.now();
}

function toKebabCase(str: string): string {
    return str.replace(/[A-Z]/g, (m) => "-" + m.toLowerCase());
}

const NUMERIC_PX_KEYS = new Set([
    "width", "height", "min-width", "max-width", "min-height", "max-height",
    "top", "left", "right", "bottom",
    "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
    "border-radius", "border-top-left-radius", "border-top-right-radius", "border-bottom-left-radius", "border-bottom-right-radius",
    "border-width", "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
    "font-size", "line-height", "letter-spacing",
    "gap", "row-gap", "column-gap"
]);

export function slateStyle(style: Record<string, any> | undefined, ...overrides: (Record<string, any> | undefined)[]): JSX.CSSProperties {
    const combined: Record<string, any> = {};
    const sources = [style, ...overrides];
    for (const src of sources) {
        if (!src) continue;
        for (const [rawK, v] of Object.entries(src)) {
            if (v !== undefined && v !== null && v !== "") {
                const k = toKebabCase(rawK);
                if (k === "spacing") {
                    combined["gap"] = typeof v === "number" ? `${v}px` : v;
                } else if (k === "border-width" && (typeof v === "number" ? v > 0 : (v !== "0px" && v !== "0"))) {
                    combined["border-width"] = typeof v === "number" ? `${v}px` : v;
                    if (!combined["border-style"]) combined["border-style"] = "solid";
                    if (!combined["box-sizing"]) combined["box-sizing"] = "border-box";
                } else if (NUMERIC_PX_KEYS.has(k) && typeof v === "number") {
                    combined[k] = `${v}px`;
                } else {
                    combined[k] = v;
                }
            }
        }
    }
    return combined as JSX.CSSProperties;
}
}";
    }
}
