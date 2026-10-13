/// Component compiler: the entry point of the bindings.
///
/// Mirrors `ComponentCompiler` in `api/node/rust/interpreter/component_compiler.rs`
/// and `Compiler` in `api/python/slint/interpreter.rs`. Both wrap
/// `slint_interpreter::Compiler` and expose `include_paths`,
/// `library_paths`, `style`, `translation_domain`, `build_from_path` /
/// `build_from_source`, and per-build diagnostics.
///
/// D naming follows camelCase (matching Node); the equivalent Python snake_case
/// names are noted per member.
module slint.compiler;

import slint.capi;
import slint.diagnostics;
import slint.definition : ComponentDefinition;

/// Result of one compiler invocation: diagnostics plus the exported
/// components. Mirrors napi's `CompilationResult` handling and Python's
/// `CompilationResult` (`api/python/slint/interpreter.rs`).
class CompilationResult
{
    private Diagnostic[] _diagnostics;
    private string[] _componentNames;

    version (SlintNative)
    {
    private SlintResult* _handle;

        this(SlintResult* handle) @system
        {
            _handle = handle;
            fetchMetadata();
        }

        ~this() @system
        {
            if (_handle !is null)
            {
                slint_result_free(_handle);
                _handle = null;
            }
        }

        private void fetchMetadata() @system
        {
            import std.string : fromStringz;

            _diagnostics.length = slint_result_diagnostic_count(_handle);
            foreach (i, ref d; _diagnostics)
            {
                d = Diagnostic(cast(DiagnosticLevel) slint_result_diagnostic_level(_handle, i),
                    fromStringz(slint_result_diagnostic_message(_handle, i)).idup,
                    slint_result_diagnostic_line(_handle, i),
                    slint_result_diagnostic_column(_handle, i));
            }
            _componentNames.length = slint_result_component_count(_handle);
            foreach (i, ref n; _componentNames)
                n = fromStringz(slint_result_component_name(_handle, i)).idup;
        }
    }
    else
    {
        this(Diagnostic[] diagnostics, string[] componentNames) @safe pure
        {
            _diagnostics = diagnostics;
            _componentNames = componentNames;
        }
    }

    /// Diagnostics emitted by this build (Python: `diagnostics`).
    const(Diagnostic)[] diagnostics() const @safe pure nothrow
    {
        return _diagnostics;
    }

    /// Names of exported components (Python: `component_names`).
    const(string)[] componentNames() const @safe pure nothrow
    {
        return _componentNames;
    }

    /// Look up an exported component by name, or null when absent.
    /// (Python: `component(name)`.)
    ComponentDefinition component(string name)
    {
        version (SlintNative)
        {
            import std.string : toStringz;
            import slint : NativeUnavailable;

            if (_handle is null)
                throw new NativeUnavailable("CompilationResult handle is null");
            auto def = slint_result_component_get(_handle, name.toStringz);
            if (def is null)
                return null;
            return new ComponentDefinition(def);
        }
        else
        {
            return null;
        }
    }
}

/// Compiles `.slint` files or inline source into runnable components.
/// (Python: `Compiler`, `build_from_path` / `build_from_source`.)
class Compiler
{
    private string[] _includePaths;
    private string[string] _libraryPaths;
    private string _style;
    private string _translationDomain;

    version (SlintNative)
    {
    private SlintCompiler* _handle;

        this() @system
        {
            _handle = slint_compiler_new();
            applyConfiguration();
        }

        ~this() @system
        {
            if (_handle !is null)
            {
                slint_compiler_free(_handle);
                _handle = null;
            }
        }

        private void applyConfiguration() @system
        {
            import std.string : toStringz;

            foreach (p; _includePaths)
                slint_compiler_add_include_path(_handle, p.toStringz);
            foreach (name, path; _libraryPaths)
                slint_compiler_set_library_path(_handle, name.toStringz, path.toStringz);
            if (_style.length)
                slint_compiler_set_style(_handle, _style.toStringz);
            if (_translationDomain.length)
                slint_compiler_set_translation_domain(_handle, _translationDomain.toStringz);
        }
    }

    /// Search paths for `@library` / module imports. (Python: `include_paths`.)
    string[] includePaths() const @safe pure nothrow
    {
        return _includePaths.dup;
    }

    void includePaths(string[] paths) @safe pure nothrow
    {
        _includePaths = paths.dup;
    }

    /// Named library paths (`name -> directory`). (Python: `library_paths`.)
    string[string] libraryPaths() const @safe pure nothrow
    {
        return _libraryPaths.dup;
    }

    void libraryPaths(string[string] paths) @safe pure nothrow
    {
        _libraryPaths = paths.dup;
    }

    /// Widget style (`"fluent"`, `"cupertino"`, `"material"`, `"cosmic"`).
    string style() const @safe pure nothrow
    {
        return _style;
    }

    void style(string s) @safe pure nothrow
    {
        _style = s;
    }

    /// Gettext translation domain. (Python: `translation_domain`.)
    string translationDomain() const @safe pure nothrow
    {
        return _translationDomain;
    }

    void translationDomain(string d) @safe pure nothrow
    {
        _translationDomain = d;
    }

    /// Compile a `.slint` file from disk. (Python: `build_from_path`.)
    CompilationResult buildFromPath(string path)
    {
        version (SlintNative)
        {
            import std.string : toStringz, fromStringz;
            import slint : NativeUnavailable;

            applyConfiguration();
            SlintResult* res;
            char* err = slint_compiler_build_from_path(_handle, path.toStringz, &res);
            if (err !is null)
            {
                string msg = fromStringz(err).idup;
                slint_string_free(err);
                throw new NativeUnavailable(msg);
            }
            return new CompilationResult(res);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(
                "Compiler.buildFromPath needs the native Slint runtime; " ~
                "rebuild with -version=SlintNative and link bridge/libslint_d_bridge.");
        }
    }

    /// Compile `.slint` markup from memory. (Python: `build_from_source`.)
    CompilationResult buildFromSource(string source, string path = "<memory>")
    {
        version (SlintNative)
        {
            import std.string : toStringz, fromStringz;
            import slint : NativeUnavailable;

            applyConfiguration();
            SlintResult* res;
            char* err = slint_compiler_build_from_source(_handle, source.toStringz,
                path.toStringz, &res);
            if (err !is null)
            {
                string msg = fromStringz(err).idup;
                slint_string_free(err);
                throw new NativeUnavailable(msg);
            }
            return new CompilationResult(res);
        }
        else
        {
            import slint : NativeUnavailable;

            throw new NativeUnavailable(
                "Compiler.buildFromSource needs the native Slint runtime; " ~
                "rebuild with -version=SlintNative and link bridge/libslint_d_bridge.");
        }
    }
}

///
unittest
{
    auto c = new Compiler();
    assert(c.includePaths().length == 0);
    c.includePaths(["ui/", "examples/"]);
    assert(c.includePaths() == ["ui/", "examples/"]);
    c.style = "fluent";
    assert(c.style == "fluent");
    c.translationDomain = "slate";
    assert(c.translationDomain == "slate");
    c.libraryPaths(["mylib": "/opt/mylib"]);
    assert(c.libraryPaths()["mylib"] == "/opt/mylib");

    version (SlintNative)
    {
    }
    else
    {
        import std.exception : assertThrown;
        import slint : NativeUnavailable;

        assertThrown!NativeUnavailable(c.buildFromSource("export component A inherits Window {}"));
    }
}
