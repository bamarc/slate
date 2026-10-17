/++
    Unit and integration tests for Slint semantic analysis and SolidJS TSX code generator.
+/
module slate.solid.codegen_test;

import slate.solid.ast;
import slate.solid.codegen_tsx;
import slate.solid.parser;
import slate.solid.sema;
import std.file : readText;
import std.path : buildPath;
import std.algorithm.searching : canFind;

// Spec: T1 - Parse and compile core Slint primitives, globals, and enums to SolidJS TSX (covers U1, U2, E1, E2)
/// Example:
/// ---
/// auto parser = new SlintParser(readText("ui/components/theme.slint"));
/// auto mod = parser.parseModule("theme.slint");
/// auto sema = new SlintSema();
/// sema.analyze(mod);
/// auto gen = new SolidTsxGenerator();
/// string tsx = gen.generateModule(mod);
/// assert(tsx.canFind("createSignal"));
/// ---
@safe unittest
{
    string themePath = "../ui/components/theme.slint";
    string themeSrc = readText(themePath);
    auto themeParser = new SlintParser(themeSrc, themePath);
    auto themeMod = themeParser.parseModule(themePath);

    auto sema = new SlintSema();
    sema.analyze(themeMod);

    auto gen = new SolidTsxGenerator();
    string themeTsx = gen.generateModule(themeMod);

    assert(themeTsx.canFind("export const SlateTheme"));
    assert(themeTsx.canFind("isDark"));
    assert(themeTsx.canFind("setIsDark"));
    assert(themeTsx.canFind("get background()"));

    string buttonPath = "../ui/components/button.slint";
    string buttonSrc = readText(buttonPath);
    auto buttonParser = new SlintParser(buttonSrc, buttonPath);
    auto buttonMod = buttonParser.parseModule(buttonPath);

    sema.analyze(buttonMod);
    string buttonTsx = gen.generateModule(buttonMod);

    assert(buttonTsx.canFind("export enum SlateButtonVariant"));
    assert(buttonTsx.canFind("export enum SlateButtonSize"));
    assert(buttonTsx.canFind("export const SlateButton"));
    assert(buttonTsx.canFind("touch_hasHover"));
    assert(buttonTsx.canFind("touch_pressed"));
    assert(buttonTsx.canFind("onPointerEnter") || buttonTsx.canFind("onMouseEnter"));
    assert(buttonTsx.canFind("onPointerLeave") || buttonTsx.canFind("onMouseLeave"));
}

// Spec: T2 - Compile complex Slint data components with loops, conditionals, and two-way bindings (covers U1, U2, E2)
/// Example:
/// ---
/// auto parser = new SlintParser(readText("ui/components/data_grid.slint"));
/// auto mod = parser.parseModule("data_grid.slint");
/// auto sema = new SlintSema();
/// sema.analyze(mod);
/// auto gen = new SolidTsxGenerator();
/// string tsx = gen.generateModule(mod);
/// assert(tsx.canFind("<For each="));
/// ---
@safe unittest
{
    string gridPath = "../ui/components/data_grid.slint";
    string gridSrc = readText(gridPath);
    auto parser = new SlintParser(gridSrc, gridPath);
    auto mod = parser.parseModule(gridPath);

    auto sema = new SlintSema();
    sema.analyze(mod);

    auto gen = new SolidTsxGenerator();
    string tsx = gen.generateModule(mod);

    assert(tsx.canFind("export interface SlateGridColumn"));
    assert(tsx.canFind("export interface SlateGridRow"));
    assert(tsx.canFind("export const SlateDataGrid"));
    assert(tsx.canFind("<Show when="));
    assert(tsx.canFind("<For each="));
    assert(tsx.canFind("filterText") || tsx.canFind("filter_text"));
    assert(tsx.canFind("sortColumn") || tsx.canFind("sort_column"));
    assert(tsx.canFind("sortDirection") || tsx.canFind("sort_direction"));
    assert(tsx.canFind("currentPage") || tsx.canFind("current_page"));
}

// Spec: T2b - Ensure two-way in-out property bindings generate createInOutProp accessor and updater (covers E2)
/// Example:
/// ---
/// string src = "export component Counter { in-out property <int> count: 0; }";
/// auto parser = new SlintParser(src);
/// auto mod = parser.parseModule();
/// auto gen = new SolidTsxGenerator();
/// string tsx = gen.generateModule(mod);
/// assert(tsx.canFind("createInOutProp"));
/// ---
@safe unittest
{
    string src = "export component Counter {\n" ~ "    in-out property <int> count: 0;\n" ~ "}\n";

    auto parser = new SlintParser(src, "counter.slint");
    auto mod = parser.parseModule("counter.slint");

    auto sema = new SlintSema();
    sema.analyze(mod);

    auto gen = new SolidTsxGenerator();
    string tsx = gen.generateModule(mod);

    assert(tsx.canFind("createInOutProp"));
    assert(tsx.canFind("count"));
    assert(tsx.canFind("onChangeCount"));
}
