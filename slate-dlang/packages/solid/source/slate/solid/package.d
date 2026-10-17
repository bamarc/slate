/++
    Slate SolidJS Cross-Compiler and Runtime Generator.

    Compiles `.slint` declarative UI files into SolidJS `.tsx` components,
    and transpiles Dlang controllers, models, and MCP runtime into executable TypeScript.
+/
module slate.solid;

public import slate.solid.ast;
public import slate.solid.lexer;
public import slate.solid.parser;
public import slate.solid.sema;
public import slate.solid.codegen_tsx;
public import slate.solid.d_to_ts;
public import slate.solid.codegen_controller;
public import slate.solid.compiler;
