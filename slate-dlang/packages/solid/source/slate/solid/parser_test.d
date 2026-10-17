/++
    Unit tests for Slint lexer and parser in slate:solid.
+/
module slate.solid.parser_test;

import slate.solid.ast;
import slate.solid.lexer;
import slate.solid.parser;

// Spec: T6 - Structured syntax error reporting on malformed Slint input (covers W1)
/// Example:
/// ---
/// auto parser = new SlintParser("component Broken {\n  Rectangle {\n    width: 10px;\n");
/// assertThrown!SlintParseError(parser.parseModule("test.slint"));
/// ---
@safe unittest
{
    import std.exception : assertThrown;

    string malformed = "component Broken {\n" ~ "  Rectangle {\n"
        ~ "    width: 10px;\n" ~ "  // unclosed brace\n";

    auto parser = new SlintParser(malformed);
    try
    {
        parser.parseModule("broken.slint");
        assert(false, "Should have thrown SlintParseError");
    }
    catch (SlintParseError err)
    {
        assert(err.file == "broken.slint");
        assert(err.line >= 4);
        assert(err.msg.length > 0);
    }
}

// Spec: T1 - Tokenize and parse Slint enums, structs, and globals (covers U1)
/// Example:
/// ---
/// auto parser = new SlintParser("export enum Variant { primary, secondary }\n" ~
///     "export global Theme { in-out property <bool> is-dark: true; }\n");
/// auto mod = parser.parseModule("theme.slint");
/// assert(mod.enums.length == 1);
/// assert(mod.globals.length == 1);
/// ---
@safe unittest
{
    string src = "export enum SlateButtonVariant { primary, secondary, outline, ghost, danger }\n"
        ~ "export struct SlateGridColumn { title: string, width: length, sortable: bool }\n"
        ~ "export global SlateTheme {\n" ~ "    in-out property <bool> is-dark: true;\n"
        ~ "    out property <color> surface: #0f1117;\n" ~ "}\n";

    auto parser = new SlintParser(src);
    SlintModule mod = parser.parseModule("theme.slint");

    assert(mod.enums.length == 1);
    assert(mod.enums[0].name == "SlateButtonVariant");
    assert(mod.enums[0].variants.length == 5);
    assert(mod.enums[0].variants[0] == "primary");

    assert(mod.structs.length == 1);
    assert(mod.structs[0].name == "SlateGridColumn");
    assert(mod.structs[0].fields.length == 3);
    assert(mod.structs[0].fields[0].name == "title");
    assert(mod.structs[0].fields[0].typeName == "string");

    assert(mod.globals.length == 1);
    assert(mod.globals[0].name == "SlateTheme");
    assert(mod.globals[0].properties.length == 2);
    assert(mod.globals[0].properties[0].name == "is-dark");
    assert(mod.globals[0].properties[0].direction == PropertyDirection.InOut);
    assert(mod.globals[0].properties[0].typeName == "bool");
    assert(mod.globals[0].properties[1].name == "surface");
    assert(mod.globals[0].properties[1].direction == PropertyDirection.Out);
}

// Spec: T2 - Parse Slint components with properties, conditionals, and loops (covers U1, U2)
/// Example:
/// ---
/// auto parser = new SlintParser("export component Box { in property <string> text; Rectangle { Text { text: root.text; } } }");
/// auto mod = parser.parseModule("box.slint");
/// assert(mod.components.length == 1);
/// ---
@safe unittest
{
    string src = "import { SlateTheme } from \"theme.slint\";\n" ~ "export component SlateCard {\n" ~ "    in property <string> title: \"\";\n" ~ "    in-out property <bool> expanded: false;\n" ~ "    callback clicked();\n" ~ "    \n" ~ "    Rectangle {\n" ~ "        background: SlateTheme.surface;\n" ~ "        border-radius: 8px;\n" ~ "        \n" ~ "        touch := TouchArea {\n" ~ "            clicked => { root.clicked(); root.expanded = !root.expanded; }\n" ~ "        }\n" ~ "        \n" ~ "        if root.expanded : VerticalLayout {\n" ~ "            @children\n" ~ "        }\n" ~ "    }\n" ~ "}\n";

    auto parser = new SlintParser(src);
    SlintModule mod = parser.parseModule("card.slint");

    assert(mod.imports.length == 1);
    assert(mod.imports[0].symbols == ["SlateTheme"]);
    assert(mod.imports[0].fromPath == "theme.slint");

    assert(mod.components.length == 1);
    auto comp = mod.components[0];
    assert(comp.name == "SlateCard");
    assert(comp.properties.length == 2);
    assert(comp.properties[0].name == "title");
    assert(comp.properties[0].direction == PropertyDirection.In);
    assert(comp.properties[1].name == "expanded");
    assert(comp.properties[1].direction == PropertyDirection.InOut);
    assert(comp.callbacks.length == 1);
    assert(comp.callbacks[0].name == "clicked");

    assert(comp.rootElement !is null);
    assert(comp.rootElement.children.length == 1);
    auto rect = comp.rootElement.children[0].element;
    assert(rect !is null);
    assert(rect.primitiveName == "Rectangle");
    assert(rect.children.length == 2);
    assert(rect.children[0].element !is null);
    assert(rect.children[0].element.id == "touch");
    assert(rect.children[0].element.primitiveName == "TouchArea");
    assert(rect.children[1].ifBlock !is null);
}

// Spec: T2c - Bounded recursion depth prevents stack-overflow DoS on deeply nested input (covers G2)
/// Example:
/// ---
/// auto parser = new SlintParser("((((((((...))))))))");
/// assertThrown!SlintParseError(parser.parseModule("overflow.slint"));
/// ---
@safe unittest
{
    import std.array : replicate;
    import std.exception : assertThrown;

    // Create 150 nested parentheses to exceed maxParseDepth (128)
    string deep = "component Deep { property <int> x: " ~ "(".replicate(
            150) ~ "1" ~ ")".replicate(150) ~ "; }\n";
    auto parser = new SlintParser(deep);
    assertThrown!SlintParseError(parser.parseModule("deep.slint"));
}
