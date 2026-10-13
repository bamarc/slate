/// One-call `.slint` loading, mirroring the helpers newcomers reach for.
///
/// Node: `loadFile(url, options?)` in `api/node/README.md` (plus the
/// `--import slint-ui/register` auto-loader in `register.mjs`);
/// Python: `load_file(path)` and the `slint.loader` auto-importer in
/// `api/python/slint/slint/__init__.py`.
module slint.loader;

import slint.compiler : Compiler, CompilationResult;

/// Compiler options accepted by `loadFile`, mirroring Node's
/// `loadFile(url, { style?, includePaths?, libraryPaths? })`.
struct LoadOptions
{
    string style;
    string[] includePaths;
    string[string] libraryPaths;
}

/// Load and compile a `.slint` file in one call.
/// Throws `NativeUnavailable` on pure-D builds (see `slint.compiler`).
CompilationResult loadFile(string path, LoadOptions options = LoadOptions.init)
{
    auto compiler = new Compiler();
    if (options.style.length)
        compiler.style = options.style;
    if (options.includePaths.length)
        compiler.includePaths = options.includePaths;
    if (options.libraryPaths.length)
        compiler.libraryPaths = options.libraryPaths;
    return compiler.buildFromPath(path);
}

///
unittest
{
    LoadOptions o;
    o.style = "fluent";
    o.includePaths = ["ui/"];
    assert(o.style == "fluent");
    assert(o.includePaths == ["ui/"]);

    version (SlintNative)
    {
    }
    else
    {
        import std.exception : assertThrown;
        import slint : NativeUnavailable;

        assertThrown!NativeUnavailable(loadFile("app.slint"));
    }
}
