/++
    Typed Abstract Syntax Tree (AST) definitions for `.slint` declarative UI files.
+/
module slate.solid.ast;

import std.conv : to;

/// Exception thrown on syntax errors during Slint lexing and parsing.
class SlintParseError : Exception
{
    string file;
    size_t line;
    size_t column;

    @safe pure nothrow this(string file, size_t line, size_t column, string message)
    {
        super(file ~ "(" ~ to!string(line) ~ "," ~ to!string(column) ~ "): " ~ message);
        this.file = file;
        this.line = line;
        this.column = column;
    }
}

/// Direction for Slint component/global properties.
enum PropertyDirection
{
    None,
    In,
    Out,
    InOut
}

/// A property declaration inside a Slint component or global.
struct SlintProperty
{
    string name;
    string typeName;
    PropertyDirection direction;
    string defaultValue;
    size_t line;
    size_t column;
}

/// A callback declaration (e.g. `callback clicked();` or `callback changed(int) -> bool;`).
struct SlintCallback
{
    string name;
    string[] paramTypes;
    string returnType;
    bool isPure;
    size_t line;
    size_t column;
}

/// An inline function definition inside a component or global.
struct SlintFunction
{
    string name;
    string[][] params; // [[name, type], ...]
    string returnType;
    string bodyCode;
    bool isPure;
    size_t line;
    size_t column;
}

/// An animation block definition (e.g. `animate width { duration: 250ms; }`).
struct SlintAnimate
{
    string propertyName;
    string duration;
    string easing;
}

/// A property binding (e.g. `background: SlateTheme.surface;`).
struct SlintBinding
{
    string name;
    string expr;
    SlintAnimate animate;
    size_t line;
    size_t column;
}

/// A callback handler binding (e.g. `clicked => { root.clicked(); }`).
struct SlintCallbackHandler
{
    string name;
    string[] params;
    string handlerBody;
    size_t line;
    size_t column;
}

/// Forward declaration of element children.
struct SlintChild
{
    SlintElement element;
    SlintIf ifBlock;
    SlintFor forBlock;
    bool isChildrenSlot; // @children
}

/// Metadata collected for an element during semantic analysis.
struct ElementSemanticInfo
{
    bool hasTouchAreaChild;
    string touchAreaId;
    bool hasFocusScopeChild;
    string focusScopeId;
    bool needsPointerEvents;
    bool needsFocusEvents;
    string[] synthesizedSignals; // e.g. ["touch_hasHover", "touch_pressed"]
}

/// An element in the Slint visual tree.
class SlintElement
{
    size_t uniqueId;
    string id;
    string primitiveName;
    SlintProperty[] properties;
    SlintBinding[] bindings;
    SlintCallbackHandler[] callbackHandlers;
    SlintChild[] children;
    ElementSemanticInfo semaInfo;
    size_t line;
    size_t column;

    @safe pure nothrow this(string id, string primitiveName, size_t line = 0, size_t col = 0)
    {
        this.id = id;
        this.primitiveName = primitiveName;
        this.line = line;
        this.column = col;
    }
}

/// A conditional branch in the element tree (e.g. `if condition : Element`).
class SlintIf
{
    string condition;
    SlintElement element;
    SlintChild[] children;
    SlintIf elseBranch;
    size_t line;
    size_t column;

    @safe pure nothrow this(string condition, size_t line = 0, size_t col = 0)
    {
        this.condition = condition;
        this.line = line;
        this.column = col;
    }
}

/// A repeater loop in the element tree (e.g. `for item[idx] in expr : Element`).
class SlintFor
{
    string itemVar;
    string indexVar;
    string iterableExpr;
    SlintElement element;
    SlintChild[] children;
    size_t line;
    size_t column;

    @safe pure nothrow this(string itemVar, string indexVar, string iterableExpr,
            size_t line = 0, size_t col = 0)
    {
        this.itemVar = itemVar;
        this.indexVar = indexVar;
        this.iterableExpr = iterableExpr;
        this.line = line;
        this.column = col;
    }
}

/// An enum declaration (e.g. `export enum ButtonVariant { primary, secondary }`).
struct SlintEnum
{
    string name;
    string[] variants;
    bool isExported;
    size_t line;
    size_t column;
}

/// A field in a Slint struct.
struct SlintStructField
{
    string name;
    string typeName;
    string defaultValue;
}

/// A struct declaration (e.g. `export struct ColumnDef { title: string, width: length }`).
struct SlintStruct
{
    string name;
    SlintStructField[] fields;
    bool isExported;
    size_t line;
    size_t column;
}

/// A global singleton definition (e.g. `export global SlateTheme { ... }`).
struct SlintGlobal
{
    string name;
    bool isExported;
    SlintProperty[] properties;
    SlintCallback[] callbacks;
    SlintFunction[] functions;
    size_t line;
    size_t column;
}

/// A component definition (e.g. `export component SlateButton { ... }`).
class SlintComponent
{
    string name;
    bool isExported;
    SlintProperty[] properties;
    SlintCallback[] callbacks;
    SlintFunction[] functions;
    SlintElement rootElement;
    size_t line;
    size_t column;

    @safe pure nothrow this(string name, bool isExported = false, size_t line = 0, size_t col = 0)
    {
        this.name = name;
        this.isExported = isExported;
        this.line = line;
        this.column = col;
    }
}

/// An import statement (e.g. `import { SlateTheme } from "theme.slint";`).
struct SlintImport
{
    string[] symbols;
    string fromPath;
    size_t line;
    size_t column;
}

/// An export statement.
struct SlintExport
{
    string[] symbols;
    string fromPath;
    size_t line;
    size_t column;
}

/// A complete parsed `.slint` module.
class SlintModule
{
    string filePath;
    SlintImport[] imports;
    SlintExport[] exports;
    SlintEnum[] enums;
    SlintStruct[] structs;
    SlintGlobal[] globals;
    SlintComponent[] components;

    @safe pure nothrow this(string filePath = "")
    {
        this.filePath = filePath;
    }
}
