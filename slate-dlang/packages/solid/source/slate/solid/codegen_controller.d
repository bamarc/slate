/++
    Hybrid compile-time controller compiler and in-browser MCP runtime generator.
+/
module slate.solid.codegen_controller;

import slate.solid.d_to_ts;
import std.algorithm.searching : canFind;
import std.array : Appender, appender;
import std.conv : to;
import std.string : indexOf, lastIndexOf, replace, split, strip;
import std.traits : getUDAs, hasUDA, isCallable, isFunction;
import std.uni : toUpper;

private @safe string capitalizeFirst(string s)
{
    if (s.length == 0)
        return s;
    return s[0 .. 1].toUpper ~ s[1 .. $];
}

// Real D controller types from slate.components
import slate.components.datagrid : DataGridController, GridRowData;
import slate.components.dropzone : UploadQueueController;
import slate.components.file_dialog : FileDialogController, InMemoryFileSystem;
import slate.components.layouts : MasterDetailController, WizardController,
    WorkspaceDockController;
import slate.components.log_viewer : RingBufferLogModel;
import slate.components.media : MediaPlayerController, SimulatedMediaBackend;
import slate.agent.traits : detectMcpCapabilities, isDropReceiver, isExpandable, isFilterable, isPaginated,
    isSeekable, isSelectable, isSortable, McpAction, McpIgnore, McpState, McpWritable;

/// Generate type-checked MCP reflection methods and SolidJS reactivity triggers for type T.
@trusted string generateMcpMethodsFor(T, string mcpNamespaceStr = "")()
{
    import std.traits : getUDAs, hasUDA, isCallable, isFunction;
    import slate.agent.traits : detectMcpCapabilities, isDropReceiver, isExpandable, isFilterable, isPaginated,
        isSeekable, isSelectable, isSortable, McpAction, McpIgnore, McpState, McpWritable;
    import std.array : appender;

    auto buf = appender!string();

    buf.put(
            "\n    // ── Model Context Protocol (MCP) & SolidJS Reactivity (Derived via D __traits reflection) ──\n");

    // 1. mcpNamespace()
    buf.put("    mcpNamespace(): string { return (this as any)._mcpNamespace || \""
            ~ mcpNamespaceStr ~ "\"; }\n");
    buf.put("    setMcpNamespace(ns: string): void { (this as any)._mcpNamespace = ns; }\n\n");

    // 2. mcpCapabilities()
    buf.put("    mcpCapabilities(): string[] { return [");
    static foreach (i, cap; detectMcpCapabilities!T())
    {
        static if (i > 0)
            buf.put(", ");
        buf.put("\"" ~ cap ~ "\"");
    }
    buf.put("]; }\n\n");

    // 3. mcpSnapshot()
    buf.put("    mcpSnapshot(): Record<string, any> {\n");
    buf.put("        return {\n");
    static if (isPaginated!T)
    {
        buf.put(
                "            \"total_pages\": (this as any).totalPages ? (this as any).totalPages() : 1,\n");
        buf.put("            \"total_rows\": (this as any).totalRows ? (this as any).totalRows() : ((this as any).itemCount ? (this as any).itemCount() : 0),\n");
        buf.put(
                "            \"page_size\": (this as any).pageSize ? (this as any).pageSize() : 25,\n");
        buf.put(
                "            \"current_page\": (this as any).currentPage ? (this as any).currentPage() : 1,\n");
    }
    static if (isSortable!T)
    {
        buf.put(
                "            \"sort_column\": (this as any).sortColumn ? (this as any).sortColumn() : -1,\n");
        buf.put(
                "            \"sort_direction\": (this as any).sortDirection ? (this as any).sortDirection() : \"none\",\n");
    }
    static if (isFilterable!T)
    {
        buf.put(
                "            \"filter_query\": (this as any).filterQuery ? (this as any).filterQuery() : \"\",\n");
    }
    static if (isSelectable!T)
    {
        buf.put(
                "            \"selected_index\": (this as any).selectedIndex ? (this as any).selectedIndex() : -1,\n");
    }
    static if (isSeekable!T)
    {
        buf.put(
                "            \"position_seconds\": (this as any).positionSeconds ? (this as any).positionSeconds() : 0,\n");
        buf.put(
                "            \"duration_seconds\": (this as any).durationSeconds ? (this as any).durationSeconds() : 0,\n");
        buf.put(
                "            \"is_playing\": (this as any).isPlaying ? (this as any).isPlaying() : false,\n");
    }
    static foreach (mem; __traits(allMembers, T))
    {
        static if (__traits(compiles, __traits(getMember, T, mem)))
        {
            static if (!hasUDA!(__traits(getMember, T, mem), McpIgnore))
            {
                static if (hasUDA!(__traits(getMember, T, mem), McpState))
                {
                    {
                        enum stateKey = getUDAs!(__traits(getMember, T, mem), McpState)[0].key;
                        buf.put("            \"" ~ stateKey ~ "\": typeof (this as any)." ~ mem
                                ~ " === \"function\" ? (this as any)." ~ mem
                                ~ "() : (this as any)." ~ mem ~ ",\n");
                    }
                }
            }
        }
    }
    buf.put("        };\n");
    buf.put("    }\n\n");

    // 4. mcpSetProperty(prop: string, val: any): void
    buf.put("    mcpSetProperty(prop: string, val: any): void {\n");
    buf.put("        switch (prop) {\n");
    static if (isPaginated!T)
    {
        buf.put("            case \"page_size\": {\n");
        buf.put("                const ps = Number(val);\n");
        buf.put("                if (!Number.isInteger(ps) || ps < 1) throw AgentError.invalidParams(\"page_size\", \"Must be an integer >= 1\");\n");
        static if (__traits(hasMember, T, "setPageSize")
                && isCallable!(__traits(getMember, T, "setPageSize")))
            buf.put("                (this as any).setPageSize(ps);\n");
        else
            buf.put("                (this as any)._pageSize = ps;\n                if (typeof (this as any).clampPage === \"function\") (this as any).clampPage();\n");
        buf.put("                this._notify();\n");
        buf.put("                return;\n");
        buf.put("            }\n");
        buf.put("            case \"current_page\": {\n");
        buf.put("                const p = Number(val);\n");
        buf.put("                if (!Number.isInteger(p) || p < 1) throw AgentError.invalidParams(\"current_page\", \"Must be an integer >= 1\");\n");
        static if (__traits(hasMember, T, "goToPage")
                && isCallable!(__traits(getMember, T, "goToPage")))
            buf.put("                (this as any).goToPage(p);\n");
        else static if (__traits(hasMember, T, "setCurrentPage")
                && isCallable!(__traits(getMember, T, "setCurrentPage")))
            buf.put("                (this as any).setCurrentPage(p);\n");
        else
            buf.put("                (this as any)._currentPage = p;\n");
        buf.put("                this._notify();\n");
        buf.put("                return;\n");
        buf.put("            }\n");
    }
    static if (isFilterable!T)
    {
        buf.put("            case \"filter_query\": {\n");
        buf.put("                (this as any).setFilterQuery(String(val ?? \"\"));\n");
        buf.put("                this._notify();\n");
        buf.put("                return;\n");
        buf.put("            }\n");
    }
    static if (isSelectable!T)
    {
        buf.put("            case \"selected_index\": {\n");
        buf.put("                const idx = Number(val);\n");
        buf.put("                if (!Number.isInteger(idx)) throw AgentError.invalidParams(\"selected_index\", \"Must be an integer\");\n");
        buf.put("                if (idx < 0) {\n");
        buf.put("                    if (typeof (this as any).clearSelection === \"function\") (this as any).clearSelection();\n");
        buf.put("                    else {\n");
        buf.put(
                "                        if (\"_selectedIndex\" in this) (this as any)._selectedIndex = -1;\n");
        buf.put(
                "                        if (\"_selectedIndices\" in this) (this as any)._selectedIndices = [];\n");
        buf.put(
                "                        if (\"_activeTrackIndex\" in this) (this as any)._activeTrackIndex = -1;\n");
        buf.put("                    }\n");
        buf.put("                } else {\n");
        buf.put("                    (this as any).selectIndex(idx);\n");
        buf.put("                }\n");
        buf.put("                this._notify();\n");
        buf.put("                return;\n");
        buf.put("            }\n");
    }
    static if (isSeekable!T)
    {
        buf.put("            case \"position_seconds\": {\n");
        buf.put("                const sec = Number(val);\n");
        buf.put("                if (isNaN(sec) || !Number.isFinite(sec) || sec < 0) throw AgentError.invalidParams(\"position_seconds\", \"Must be a non-negative finite number\");\n");
        static if (__traits(hasMember, T, "seekTo")
                && isCallable!(__traits(getMember, T, "seekTo")))
            buf.put("                (this as any).seekTo(sec);\n");
        else
            buf.put("                (this as any).seek(sec);\n");
        buf.put("                this._notify();\n");
        buf.put("                return;\n");
        buf.put("            }\n");
    }
    static foreach (mem; __traits(allMembers, T))
    {
        static if (__traits(compiles, __traits(getMember, T, mem)))
        {
            static if (!hasUDA!(__traits(getMember, T, mem), McpIgnore))
            {
                static if (hasUDA!(__traits(getMember, T, mem), McpWritable))
                {
                    {
                        enum writeKey = getUDAs!(__traits(getMember, T, mem), McpWritable)[0].key;
                        static if (writeKey != "page_size" && writeKey != "current_page" && writeKey != "filter_query"
                                && writeKey != "selected_index" && writeKey != "position_seconds")
                        {
                            buf.put("            case \"" ~ writeKey ~ "\": {\n");
                            static if (isCallable!(__traits(getMember, T, mem)))
                            {
                                enum capMem = capitalizeFirst(mem);
                                enum setterName = "set" ~ capMem;
                                static if (__traits(hasMember, T, setterName)
                                        && isCallable!(__traits(getMember, T, setterName)))
                                {
                                    buf.put(
                                            "                (this as any)."
                                            ~ setterName ~ "(val);\n");
                                }
                                else
                                {
                                    buf.put("                (this as any)." ~ mem ~ "(val);\n");
                                }
                            }
                            else
                            {
                                static if (is(typeof(__traits(getMember, T, mem)) == bool))
                                {
                                    buf.put("                if (typeof val !== \"boolean\") {\n");
                                    buf.put("                    throw AgentError.invalidParams(\""
                                            ~ writeKey ~ "\", \"Must be a boolean\");\n");
                                    buf.put("                }\n");
                                }
                                else static if (is(typeof(__traits(getMember, T, mem)) : double))
                                {
                                    buf.put(
                                            "                if (typeof val !== \"number\" || !Number.isFinite(val)) {\n");
                                    buf.put("                    throw AgentError.invalidParams(\""
                                            ~ writeKey ~ "\", \"Must be a finite number\");\n");
                                    buf.put("                }\n");
                                }
                                buf.put("                (this as any)." ~ mem ~ " = val;\n");
                                buf.put("                if (typeof (this as any).onMcpPropertyChanged === \"function\") (this as any).onMcpPropertyChanged(\"" ~ writeKey ~ "\");\n");
                            }
                            buf.put("                this._notify();\n");
                            buf.put("                return;\n");
                            buf.put("            }\n");
                        }
                    }
                }
            }
        }
    }
    buf.put("            default:\n");
    buf.put(
            "                throw AgentError.invalidParams(\"property\", `Unknown or read-only property: '${prop}'`);\n");
    buf.put("        }\n");
    buf.put("    }\n\n");

    // 5. mcpRestoreSnapshot(snap: Record<string, any>): void
    buf.put("    mcpRestoreSnapshot(snap: Record<string, any>): void {\n");
    buf.put("        if (!snap || typeof snap !== \"object\") return;\n");
    static if (isPaginated!T)
    {
        buf.put("        if (snap[\"page_size\"] !== undefined) {\n");
        static if (__traits(hasMember, T, "setPageSize")
                && isCallable!(__traits(getMember, T, "setPageSize")))
            buf.put(
                    "            try { (this as any).setPageSize(Number(snap[\"page_size\"])); } catch (_) {}\n");
        else
            buf.put("            (this as any)._pageSize = Number(snap[\"page_size\"]);\n");
        buf.put("        }\n");
        buf.put("        if (snap[\"current_page\"] !== undefined) {\n");
        static if (__traits(hasMember, T, "goToPage")
                && isCallable!(__traits(getMember, T, "goToPage")))
            buf.put(
                    "            try { (this as any).goToPage(Number(snap[\"current_page\"])); } catch (_) {}\n");
        else static if (__traits(hasMember, T, "setCurrentPage")
                && isCallable!(__traits(getMember, T, "setCurrentPage")))
            buf.put(
                    "            try { (this as any).setCurrentPage(Number(snap[\"current_page\"])); } catch (_) {}\n");
        else
            buf.put("            (this as any)._currentPage = Number(snap[\"current_page\"]);\n");
        buf.put("        }\n");
    }
    static if (isFilterable!T)
    {
        buf.put("        if (snap[\"filter_query\"] !== undefined) try { (this as any).setFilterQuery(String(snap[\"filter_query\"])); } catch (_) {}\n");
    }
    static if (isSelectable!T)
    {
        buf.put("        if (snap[\"selected_index\"] !== undefined) {\n");
        buf.put("            const idx = Number(snap[\"selected_index\"]);\n");
        buf.put("            if (idx < 0) {\n");
        buf.put("                if (typeof (this as any).clearSelection === \"function\") (this as any).clearSelection();\n");
        buf.put("                else {\n");
        buf.put(
                "                    if (\"_selectedIndex\" in this) (this as any)._selectedIndex = -1;\n");
        buf.put(
                "                    if (\"_selectedIndices\" in this) (this as any)._selectedIndices = [];\n");
        buf.put(
                "                    if (\"_activeTrackIndex\" in this) (this as any)._activeTrackIndex = -1;\n");
        buf.put("                }\n");
        buf.put("            } else {\n");
        buf.put("                try { (this as any).selectIndex(idx); } catch (_) {}\n");
        buf.put("            }\n");
        buf.put("        }\n");
    }
    static if (isSeekable!T)
    {
        buf.put("        if (snap[\"position_seconds\"] !== undefined) {\n");
        static if (__traits(hasMember, T, "seekTo")
                && isCallable!(__traits(getMember, T, "seekTo")))
            buf.put(
                    "            try { (this as any).seekTo(Number(snap[\"position_seconds\"])); } catch (_) {}\n");
        else
            buf.put(
                    "            try { (this as any).seek(Number(snap[\"position_seconds\"])); } catch (_) {}\n");
        buf.put("        }\n");
    }
    static foreach (mem; __traits(allMembers, T))
    {
        static if (__traits(compiles, __traits(getMember, T, mem)))
        {
            static if (!hasUDA!(__traits(getMember, T, mem), McpIgnore))
            {
                static if (hasUDA!(__traits(getMember, T, mem), McpWritable))
                {
                    {
                        enum writeKey = getUDAs!(__traits(getMember, T, mem), McpWritable)[0].key;
                        static if (writeKey != "page_size" && writeKey != "current_page" && writeKey != "filter_query"
                                && writeKey != "selected_index" && writeKey != "position_seconds")
                        {
                            buf.put("        if (snap[\"" ~ writeKey ~ "\"] !== undefined) {\n");
                            static if (isCallable!(__traits(getMember, T, mem)))
                            {
                                enum capMem = capitalizeFirst(mem);
                                enum setterName = "set" ~ capMem;
                                static if (__traits(hasMember, T, setterName)
                                        && isCallable!(__traits(getMember, T, setterName)))
                                {
                                    buf.put("            try { (this as any)." ~ setterName
                                            ~ "(snap[\"" ~ writeKey ~ "\"]); } catch (_) {}\n");
                                }
                                else
                                {
                                    buf.put("            try { (this as any)." ~ mem
                                            ~ "(snap[\"" ~ writeKey ~ "\"]); } catch (_) {}\n");
                                }
                            }
                            else
                            {
                                buf.put(
                                        "            (this as any)." ~ mem
                                        ~ " = snap[\"" ~ writeKey ~ "\"];\n");
                            }
                            buf.put("        }\n");
                        }
                    }
                }
            }
        }
    }
    buf.put(
            "        if (typeof (this as any).syncToSlint === \"function\") (this as any).syncToSlint();\n");
    buf.put("        this._notify();\n");
    buf.put("    }\n\n");

    // 6. mcpInvokeAction(action: string, payload: any): any
    buf.put("    mcpInvokeAction(action: string, payload: any): any {\n");
    buf.put("        switch (action) {\n");
    static if (isSortable!T)
    {
        buf.put("            case \"sort_by_column\": {\n");
        buf.put("                const col = payload?.column ?? payload?.columnIndex ?? 0;\n");
        buf.put("                const dir = payload?.direction ?? \"asc\";\n");
        buf.put("                (this as any).sortByColumn(Number(col), String(dir));\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
        buf.put("            case \"cycle_sort\": {\n");
        buf.put("                const col = payload?.column ?? payload?.columnIndex ?? 0;\n");
        buf.put("                (this as any).cycleSortColumn(Number(col));\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
    }
    static if (isPaginated!T)
    {
        buf.put("            case \"next_page\": {\n");
        buf.put("                (this as any).nextPage();\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
        buf.put("            case \"prev_page\": {\n");
        buf.put("                (this as any).prevPage();\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
        buf.put("            case \"go_to_page\": {\n");
        buf.put("                const page = payload?.page ?? payload;\n");
        buf.put("                (this as any).goToPage(Number(page));\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
    }
    static if (isFilterable!T)
    {
        buf.put("            case \"set_filter\": {\n");
        buf.put("                const q = payload?.query ?? payload ?? \"\";\n");
        buf.put("                (this as any).setFilterQuery(String(q));\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
    }
    static if (isSelectable!T)
    {
        buf.put("            case \"select_index\": {\n");
        buf.put("                const idx = payload?.index ?? payload;\n");
        buf.put("                (this as any).selectIndex(Number(idx));\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
        buf.put("            case \"clear_selection\": {\n");
        buf.put("                if (typeof (this as any).clearSelection === \"function\") (this as any).clearSelection();\n");
        buf.put("                else {\n");
        buf.put(
                "                    if (\"_selectedIndex\" in this) (this as any)._selectedIndex = -1;\n");
        buf.put(
                "                    if (\"_selectedIndices\" in this) (this as any)._selectedIndices = [];\n");
        buf.put(
                "                    if (\"_activeTrackIndex\" in this) (this as any)._activeTrackIndex = -1;\n");
        buf.put("                }\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
    }
    static if (isSeekable!T)
    {
        buf.put("            case \"play\": {\n");
        buf.put("                (this as any).play();\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
        buf.put("            case \"pause\": {\n");
        buf.put("                (this as any).pause();\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
        buf.put("            case \"stop\": {\n");
        buf.put("                (this as any).stop();\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
        buf.put("            case \"seek\": {\n");
        buf.put("                const sec = payload?.seconds ?? payload;\n");
        static if (__traits(hasMember, T, "seekTo")
                && isCallable!(__traits(getMember, T, "seekTo")))
            buf.put("                (this as any).seekTo(Number(sec));\n");
        else
            buf.put("                (this as any).seek(Number(sec));\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: true };\n");
        buf.put("            }\n");
    }
    static if (isDropReceiver!T)
    {
        buf.put("            case \"drop_files\": {\n");
        buf.put("                const paths = Array.isArray(payload) ? payload : [payload];\n");
        buf.put("                const res = (this as any).dropFiles(paths);\n");
        buf.put("                this._notify();\n");
        buf.put("                return { success: res };\n");
        buf.put("            }\n");
    }
    static foreach (mem; __traits(allMembers, T))
    {
        static if (__traits(compiles, __traits(getMember, T, mem)))
        {
            static if (!hasUDA!(__traits(getMember, T, mem), McpIgnore))
            {
                static if (hasUDA!(__traits(getMember, T, mem), McpAction))
                {
                    {
                        enum actName = getUDAs!(__traits(getMember, T, mem), McpAction)[0].name;
                        static if (actName != "cycle_sort" && actName != "sort_by_column"
                                && actName != "next_page" && actName != "prev_page"
                                && actName != "go_to_page"
                                && actName != "set_filter" && actName != "select_index"
                                && actName != "clear_selection" && actName != "play"
                                && actName != "pause" && actName != "stop"
                                && actName != "seek" && actName != "drop_files")
                        {
                            buf.put("            case \"" ~ actName ~ "\": {\n");
                            enum capMem = capitalizeFirst(mem);
                            enum setterName = "set" ~ capMem;
                            static if (__traits(hasMember, T, setterName)
                                    && isCallable!(__traits(getMember, T, setterName)))
                            {
                                buf.put(
                                        "                const res = (this as any)."
                                        ~ setterName ~ "(payload);\n");
                            }
                            else
                            {
                                buf.put(
                                        "                const res = (this as any)."
                                        ~ mem ~ "(payload);\n");
                            }
                            buf.put("                this._notify();\n");
                            buf.put(
                                    "                return res !== undefined ? res : { success: true };\n");
                            buf.put("            }\n");
                        }
                    }
                }
            }
        }
    }
    buf.put("            default:\n");
    buf.put(
            "                throw AgentError.actionFailed(action, `Unknown action: '${action}'`);\n");
    buf.put("        }\n");
    buf.put("    }\n\n");

    // 7. Reactive SolidJS signals subscription & Mcp notifications
    buf.put("    // Fine-grained SolidJS signal hooks & Mcp reactivity\n");
    buf.put("    private _subscribers: Array<(snap?: any) => void> = [];\n");
    buf.put(
            "    private _sig: any = typeof createSignal === \"function\" ? createSignal(0) : null;\n");
    buf.put("    subscribe(cb: (snap?: any) => void): () => void {\n");
    buf.put("        this._subscribers.push(cb);\n");
    buf.put(
            "        return () => { this._subscribers = this._subscribers.filter(s => s !== cb); };\n");
    buf.put("    }\n");
    buf.put("    private _notify(): void {\n");
    buf.put(
            "        if (this._sig && this._sig[1]) { try { this._sig[1]((v: number) => v + 1); } catch (_) {} }\n");
    buf.put(
            "        const snap = typeof (this as any).mcpSnapshot === \"function\" ? (this as any).mcpSnapshot() : null;\n");
    buf.put("        for (const s of this._subscribers) { try { s(snap); } catch (_) {} }\n");
    buf.put("    }\n");
    buf.put("    private _track(): void {\n");
    buf.put("        if (this._sig && this._sig[0]) { try { this._sig[0](); } catch (_) {} }\n");
    buf.put("    }\n");

    return buf.data;
}

/// Hybrid compiler merging transpiled D method bodies with MCP reflection and SolidJS reactivity.
class ControllerCompiler
{
    private DToTsTranspiler transpiler;

    @safe this()
    {
        this.transpiler = new DToTsTranspiler();
    }

    /// Compile a D controller source file into an executable TypeScript controller class.
    @safe string compileController(string filePath, string className)
    {
        string rawTs = transpiler.transpileFile(filePath);
        return injectMcpMethods(rawTs, className);
    }

    /// Compile a D controller source file containing multiple controllers into an executable TypeScript controller class.
    @safe string compileControllers(string filePath, string[] classNames)
    {
        string ts = transpiler.transpileFile(filePath);
        foreach (cls; classNames)
        {
            ts = injectMcpMethods(ts, cls);
        }
        return ts;
    }

    private @trusted string injectMcpMethods(string tsCode, string className)
    {
        string methods = "";
        if (className == "DataGridController")
            methods = generateMcpMethodsFor!(DataGridController!GridRowData, "datagrid")();
        else if (className == "MediaPlayerController")
            methods = generateMcpMethodsFor!(MediaPlayerController, "media")();
        else if (className == "FileDialogController")
            methods = generateMcpMethodsFor!(FileDialogController, "file_dialog")();
        else if (className == "UploadQueueController")
            methods = generateMcpMethodsFor!(UploadQueueController, "upload_queue")();
        else if (className == "RingBufferLogModel")
            methods = generateMcpMethodsFor!(RingBufferLogModel, "log_viewer")();
        else if (className == "WorkspaceDockController")
            methods = generateMcpMethodsFor!(WorkspaceDockController, "workspace_dock")();
        else if (className == "WizardController")
            methods = generateMcpMethodsFor!(WizardController, "wizard")();
        else if (className == "MasterDetailController")
            methods = generateMcpMethodsFor!(MasterDetailController, "master_detail")();

        if (methods.length == 0)
            return tsCode;

        // Locate class and insert methods before closing brace
        ptrdiff_t classPos = tsCode.indexOf("class " ~ className);
        if (classPos < 0)
            return tsCode ~ "\n" ~ methods;

        ptrdiff_t openBrace = tsCode.indexOf("{", classPos);
        if (openBrace < 0)
            return tsCode;

        int depth = 1;
        size_t closeBrace = openBrace + 1;
        while (closeBrace < tsCode.length && depth > 0)
        {
            if (tsCode[closeBrace] == '{')
                depth++;
            else if (tsCode[closeBrace] == '}')
            {
                depth--;
                if (depth == 0)
                    break;
            }
            closeBrace++;
        }

        if (depth == 0 && closeBrace < tsCode.length)
        {
            return tsCode[0 .. closeBrace] ~ methods ~ tsCode[closeBrace .. $];
        }

        return tsCode ~ "\n" ~ methods;
    }

    /// Generate the full in-browser McpStateRegistry and JSON-RPC 2.0 McpServer runtime.
    @safe string generateMcpRuntime()
    {
        return q"{
// In-Browser Model Context Protocol (MCP) Runtime for Slate SolidJS.

export interface McpControllable {
    mcpNamespace(): string;
    mcpCapabilities(): string[];
    mcpSnapshot(): Record<string, any>;
    mcpSetProperty(prop: string, val: any): void;
    mcpRestoreSnapshot(snap: Record<string, any>): void;
    mcpInvokeAction(action: string, payload: any): any;
}

export interface Paginated {
    pageSize(): number;
    setPageSize(size: number): void;
    currentPage(): number;
    setCurrentPage(page: number): void;
    totalPages(): number;
    totalRows(): number;
}

export interface Sortable {
    sortColumn(): number;
    sortDirection(): string;
    sortByColumn(column: number, direction: string): void;
    cycleSortColumn(column: number): void;
}

export interface Filterable {
    filterQuery(): string;
    setFilterQuery(query: string): void;
}

export interface Selectable {
    selectedIndex(): number;
    selectIndex(index: number): void;
    clearSelection(): void;
}

export interface DropReceiver {
    dropFiles(paths: string[]): boolean;
}

export interface McpBindable {
    bindMcp(instance: any): void;
}

export interface Seekable {
    positionSeconds(): number;
    seekSeconds(seconds: number): void;
    durationSeconds(): number;
    isPlaying(): boolean;
}

export class McpStateRegistry {
    private controllers = new Map<string, McpControllable>();

    register(targetId: string, controller: McpControllable): void {
        this.controllers.set(targetId, controller);
    }

    unregister(targetId: string): void {
        this.controllers.delete(targetId);
    }

    get(targetId: string): McpControllable | undefined {
        return this.controllers.get(targetId);
    }

    list(): string[] {
        return Array.from(this.controllers.keys());
    }

    getState(targetId: string): any {
        const ctrl = this.controllers.get(targetId);
        if (!ctrl) {
            throw new Error(`Target not found in McpStateRegistry: '${targetId}'`);
        }
        return {
            target_id: targetId,
            namespace: ctrl.mcpNamespace(),
            capabilities: ctrl.mcpCapabilities(),
            ...ctrl.mcpSnapshot()
        };
    }

    setProperty(targetId: string, prop: string, val: any): { success: boolean; error?: string } {
        const ctrl = this.controllers.get(targetId);
        if (!ctrl) {
            return { success: false, error: `Target not found: '${targetId}'` };
        }
        // Transactional safety: capture snapshot before applying mutation
        const snapshotBefore = JSON.parse(JSON.stringify(ctrl.mcpSnapshot()));
        try {
            ctrl.mcpSetProperty(prop, val);
            return { success: true };
        } catch (err: any) {
            // Roll back snapshot on any failure
            ctrl.mcpRestoreSnapshot(snapshotBefore);
            return { success: false, error: err.message || String(err) };
        }
    }

    invokeAction(targetId: string, action: string, payload: any): any {
        const ctrl = this.controllers.get(targetId);
        if (!ctrl) {
            throw new Error(`Target not found: '${targetId}'`);
        }
        return ctrl.mcpInvokeAction(action, payload);
    }
}

export class McpServer {
    constructor(private registry: McpStateRegistry) {}

    async handleJsonRpc(req: { jsonrpc: string; id: any; method: string; params: any }): Promise<{ jsonrpc: string; id: any; result?: any; error?: any }> {
        if (req.jsonrpc !== "2.0") {
            return { jsonrpc: "2.0", id: req.id, error: { code: -32600, message: "Invalid JSON-RPC version" } };
        }

        try {
            switch (req.method) {
                case "list_targets": {
                    return { jsonrpc: "2.0", id: req.id, result: { targets: this.registry.list() } };
                }

                case "get_state": {
                    const targetId = req.params?.target_id;
                    const state = this.registry.getState(targetId);
                    return { jsonrpc: "2.0", id: req.id, result: state };
                }

                case "set_property": {
                    const { target_id, property, value } = req.params || {};
                    const res = this.registry.setProperty(target_id, property, value);
                    if (!res.success) {
                        return { jsonrpc: "2.0", id: req.id, error: { code: -32602, message: res.error } };
                    }
                    return { jsonrpc: "2.0", id: req.id, result: { success: true } };
                }

                case "invoke_action": {
                    const { target_id, action, payload } = req.params || {};
                    const res = this.registry.invokeAction(target_id, action, payload);
                    return { jsonrpc: "2.0", id: req.id, result: res !== undefined ? res : { success: true } };
                }

                case "inspect_tree": {
                    // In-browser DOM accessibility tree inspection
                    const elements: any[] = [];
                    if (typeof document !== "undefined") {
                        const mcpNodes = document.querySelectorAll("[data-mcp-id]");
                        mcpNodes.forEach((node) => {
                            elements.push({
                                id: node.getAttribute("data-mcp-id"),
                                role: node.getAttribute("role") || node.tagName.toLowerCase(),
                                label: node.getAttribute("aria-label") || "",
                                disabled: node.hasAttribute("disabled")
                            });
                        });
                    }
                    return { jsonrpc: "2.0", id: req.id, result: { elements } };
                }

                case "click_element": {
                    const targetId = req.params?.target_id;
                    if (typeof document !== "undefined") {
                        const nodes = document.querySelectorAll("[data-mcp-id]");
                        for (let i = 0; i < nodes.length; i++) {
                            const node = nodes[i] as HTMLElement;
                            if (node.getAttribute("data-mcp-id") === String(targetId)) {
                                node.click();
                                return { jsonrpc: "2.0", id: req.id, result: { success: true } };
                            }
                        }
                    }
                    return { jsonrpc: "2.0", id: req.id, error: { code: -32602, message: `Element not found: ${targetId}` } };
                }

                case "send_keys": {
                    const { target_id, text, clear_first } = req.params || {};
                    if (typeof document !== "undefined") {
                        const nodes = document.querySelectorAll("[data-mcp-id]");
                        for (let i = 0; i < nodes.length; i++) {
                            const node = nodes[i] as HTMLInputElement;
                            if (node.getAttribute("data-mcp-id") === String(target_id)) {
                                if (clear_first) {
                                    node.value = "";
                                }
                                node.value = (node.value || "") + (text || "");
                                node.dispatchEvent(new Event("input", { bubbles: true }));
                                node.dispatchEvent(new Event("change", { bubbles: true }));
                                return { jsonrpc: "2.0", id: req.id, result: { success: true } };
                            }
                        }
                    }
                    return { jsonrpc: "2.0", id: req.id, error: { code: -32602, message: `Element not found: ${target_id}` } };
                }

                default:
                    return { jsonrpc: "2.0", id: req.id, error: { code: -32601, message: `Method not found: ${req.method}` } };
            }
        } catch (err: any) {
            return { jsonrpc: "2.0", id: req.id, error: { code: -32603, message: err.message || String(err) } };
        }
    }
}
}";
    }
}
