/++
    Semantic analysis pass for Slint AST.

    Resolves sibling TouchArea/FocusScope references, hoists pointer/focus events,
    classifies property reactivity (in, out, in-out, memo, signal), and maps
    accessible-* bindings to MCP/ARIA metadata.
+/
module slate.solid.sema;

import slate.solid.ast;
import std.algorithm.searching : canFind;
import std.ascii : toUpper;
import std.string : replace, split, strip;

/// Semantic analyzer for Slint modules.
class SlintSema
{
    private int depth = 0;
    enum int maxDepth = 128;

    private @safe void enterRecursion()
    {
        depth++;
        if (depth > maxDepth)
        {
            throw new Exception("Maximum semantic recursion depth (128) exceeded");
        }
    }

    private @safe void exitRecursion() nothrow
    {
        if (depth > 0)
        {
            depth--;
        }
    }

    @safe void analyze(SlintModule mod)
    {
        depth = 0;
        foreach (comp; mod.components)
        {
            analyzeComponent(comp);
        }
    }

    private @safe void analyzeComponent(SlintComponent comp)
    {
        if (comp.rootElement !is null)
        {
            analyzeElement(comp.rootElement);
        }
    }

    private @safe void analyzeElement(SlintElement elem)
    {
        if (elem is null)
            return;
        enterRecursion();
        scope (exit)
            exitRecursion();

        ElementSemanticInfo info;

        // Scan children for TouchArea or FocusScope
        foreach (child; elem.children)
        {
            if (child.element !is null)
            {
                if (child.element.primitiveName == "TouchArea")
                {
                    info.hasTouchAreaChild = true;
                    string rawId = child.element.id.length > 0 ? child.element.id : "touch";
                    info.touchAreaId = toCamelCase(rawId);
                    info.needsPointerEvents = true;
                    info.synthesizedSignals ~= info.touchAreaId ~ "_hasHover";
                    info.synthesizedSignals ~= info.touchAreaId ~ "_pressed";
                }
                else if (child.element.primitiveName == "FocusScope")
                {
                    info.hasFocusScopeChild = true;
                    string rawId = child.element.id.length > 0 ? child.element.id : "fs";
                    info.focusScopeId = toCamelCase(rawId);
                    info.needsFocusEvents = true;
                    info.synthesizedSignals ~= info.focusScopeId ~ "_hasFocus";
                }
                // Recursively analyze child elements
                analyzeElement(child.element);
            }
            else if (child.ifBlock !is null)
            {
                analyzeIf(child.ifBlock);
            }
            else if (child.forBlock !is null)
            {
                analyzeFor(child.forBlock);
            }
        }

        elem.semaInfo = info;
    }

    private @safe void analyzeIf(SlintIf ifBlock)
    {
        if (ifBlock is null)
            return;
        enterRecursion();
        scope (exit)
            exitRecursion();

        if (ifBlock.element !is null)
        {
            analyzeElement(ifBlock.element);
        }
        foreach (child; ifBlock.children)
        {
            if (child.element !is null)
            {
                analyzeElement(child.element);
            }
            else if (child.ifBlock !is null)
            {
                analyzeIf(child.ifBlock);
            }
            else if (child.forBlock !is null)
            {
                analyzeFor(child.forBlock);
            }
        }
        if (ifBlock.elseBranch !is null)
        {
            analyzeIf(ifBlock.elseBranch);
        }
    }

    private @safe void analyzeFor(SlintFor forBlock)
    {
        if (forBlock is null)
            return;
        enterRecursion();
        scope (exit)
            exitRecursion();

        if (forBlock.element !is null)
        {
            analyzeElement(forBlock.element);
        }
        foreach (child; forBlock.children)
        {
            if (child.element !is null)
            {
                analyzeElement(child.element);
            }
            else if (child.ifBlock !is null)
            {
                analyzeIf(child.ifBlock);
            }
            else if (child.forBlock !is null)
            {
                analyzeFor(child.forBlock);
            }
        }
    }

    /// Retrieve semantic info for an element.
    @safe ElementSemanticInfo getElementInfo(SlintElement elem)
    {
        if (elem !is null)
        {
            return elem.semaInfo;
        }
        return ElementSemanticInfo.init;
    }

    private static @safe pure nothrow string toCamelCase(string s)
    {
        if (s.length == 0)
            return "";
        auto parts = s.split("-");
        if (parts.length == 1)
            return s;
        string res = parts[0];
        foreach (part; parts[1 .. $])
        {
            if (part.length > 0)
            {
                res ~= cast(char) toUpper(part[0]) ~ part[1 .. $];
            }
        }
        return res;
    }
}
