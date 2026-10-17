/++
    CLI entrypoint: compiles `.slint` UI files and D controllers to SolidJS TypeScript.
+/
module slate.bin.slint2solid;

import slate.solid.compiler;
import std.stdio : stderr, writeln;

int main(string[] args)
{
    string uiDir = args.length > 1 ? args[1] : "../ui";
    string outDir = args.length > 2 ? args[2] : "target/solid-ui";

    writeln("Compiling Slint UI workspace from '", uiDir, "' to '", outDir, "'...");

    auto compiler = new WorkspaceCompiler();
    auto res = compiler.compileWorkspace(uiDir, outDir);

    writeln("Compiled ", res.compiledCount, " .slint files.");
    if (res.errorCount > 0)
    {
        stderr.writeln("Encountered ", res.errorCount, " errors:");
        foreach (msg; res.errorMessages)
        {
            stderr.writeln("  ", msg);
        }
        return 1;
    }

    writeln("✓ Standalone SolidJS UI package successfully generated at: ", outDir);
    return 0;
}
