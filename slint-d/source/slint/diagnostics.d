/// Compiler diagnostics: severity levels and messages.
///
/// Mirrors `slint_interpreter::Diagnostic` / `DiagnosticLevel` and the
/// diagnostic wrappers in `api/node/rust/interpreter/diagnostic.rs`
/// (`JsDiagnostic`) and `api/python/slint/interpreter.rs`
/// (`PyDiagnostic`).
module slint.diagnostics;

/// Severity of a compiler diagnostic message.
enum DiagnosticLevel
{
    Error,
    Warning,
    Note,
}

/// A single message emitted while compiling `.slint` markup.
struct Diagnostic
{
    DiagnosticLevel level;
    string message;
    /// 1-based line number in the source file.
    size_t lineNumber;
    /// 1-based column number in the source file.
    size_t columnNumber;

    string toString() const @safe pure
    {
        import std.format : format;

        return format!"%s:%s: %s: %s"(lineNumber, columnNumber, level, message);
    }

    bool isError() const @safe pure nothrow @nogc
    {
        return level == DiagnosticLevel.Error;
    }
}

/// True when any diagnostic in the range is an error.
bool hasErrors(const(Diagnostic)[] diagnostics) @safe pure nothrow @nogc
{
    foreach (ref d; diagnostics)
        if (d.isError())
            return true;
    return false;
}

///
unittest
{
    Diagnostic[] ds = [
        Diagnostic(DiagnosticLevel.Warning, "unused", 1, 2),
        Diagnostic(DiagnosticLevel.Error, "unknown type", 3, 4),
    ];
    assert(hasErrors(ds));
    assert(!hasErrors(ds[0 .. 1]));
    assert(!Diagnostic(DiagnosticLevel.Note, "x", 0, 0).isError());
}
