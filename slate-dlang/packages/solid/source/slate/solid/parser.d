/++
    Recursive-descent parser for `.slint` declarative UI files.
+/
module slate.solid.parser;

import slate.solid.ast;
import slate.solid.lexer;
import std.conv : to;
import std.string : strip;

/// Recursive-descent parser for Slint markup.
class SlintParser
{
    private Token[] tokens;
    private size_t cursor;
    private string filePath;
    private int parseDepth = 0;
    enum int maxParseDepth = 128;

    @safe this(string source, string filePath = "")
    {
        this.filePath = filePath;
        auto lexer = new SlintLexer(source, filePath);
        Token tok;
        do
        {
            tok = lexer.nextToken();
            tokens ~= tok;
        }
        while (tok.kind != TokenKind.EOF);
        this.cursor = 0;
    }

    private @safe void enterRecursion(size_t line, size_t col)
    {
        parseDepth++;
        if (parseDepth > maxParseDepth)
        {
            throw new SlintParseError(filePath, line, col,
                    "Maximum parse depth (128) exceeded (possible stack overflow/infinite recursion)");
        }
    }

    private @safe void exitRecursion() nothrow
    {
        if (parseDepth > 0)
        {
            parseDepth--;
        }
    }

    /// Parse the complete Slint module.
    @safe SlintModule parseModule(string fileOverride = "")
    {
        if (fileOverride.length > 0)
        {
            this.filePath = fileOverride;
        }
        auto mod = new SlintModule(filePath);

        while (!isEOF())
        {
            if (matchKeyword("import"))
            {
                mod.imports ~= parseImport();
            }
            else if (matchKeyword("export"))
            {
                parseExport(mod);
            }
            else if (matchKeyword("component"))
            {
                mod.components ~= parseComponent(false);
            }
            else if (matchKeyword("global"))
            {
                mod.globals ~= parseGlobal(false);
            }
            else if (matchKeyword("struct"))
            {
                mod.structs ~= parseStruct(false);
            }
            else if (matchKeyword("enum"))
            {
                mod.enums ~= parseEnum(false);
            }
            else
            {
                auto tok = peek();
                throw new SlintParseError(filePath, tok.line, tok.column,
                        "Unexpected top-level token: '" ~ tok.text ~ "'");
            }
        }

        return mod;
    }

    // ── Imports and Exports ──────────────────────────────────

    private @safe SlintImport parseImport()
    {
        auto kwTok = consume(); // 'import'
        enterRecursion(kwTok.line, kwTok.column);
        scope (exit)
            exitRecursion();

        SlintImport imp;
        imp.line = kwTok.line;
        imp.column = kwTok.column;

        if (match(TokenKind.OpenBrace))
        {
            consume(); // '{'
            while (!match(TokenKind.CloseBrace) && !isEOF())
            {
                if (match(TokenKind.Identifier) || match(TokenKind.Keyword))
                {
                    imp.symbols ~= consume().text;
                }
                if (match(TokenKind.Comma))
                {
                    consume();
                }
                else
                {
                    break;
                }
            }
            expect(TokenKind.CloseBrace, "Expected '}' after import symbols");
        }

        expectKeyword("from", "Expected 'from' in import statement");
        auto pathTok = expect(TokenKind.StringLiteral, "Expected string path in import statement");
        imp.fromPath = unquote(pathTok.text);
        expect(TokenKind.Semicolon, "Expected ';' after import statement");

        return imp;
    }

    private @safe void parseExport(SlintModule mod)
    {
        auto kwTok = consume(); // 'export'
        enterRecursion(kwTok.line, kwTok.column);
        scope (exit)
            exitRecursion();

        if (matchKeyword("enum"))
        {
            mod.enums ~= parseEnum(true);
        }
        else if (matchKeyword("struct"))
        {
            mod.structs ~= parseStruct(true);
        }
        else if (matchKeyword("global"))
        {
            mod.globals ~= parseGlobal(true);
        }
        else if (matchKeyword("component"))
        {
            mod.components ~= parseComponent(true);
        }
        else if (match(TokenKind.OpenBrace))
        {
            // export { A, B } from "path";
            SlintExport exp;
            exp.line = kwTok.line;
            exp.column = kwTok.column;
            consume(); // '{'
            while (!match(TokenKind.CloseBrace) && !isEOF())
            {
                if (match(TokenKind.Identifier) || match(TokenKind.Keyword))
                {
                    exp.symbols ~= consume().text;
                }
                if (match(TokenKind.Comma))
                {
                    consume();
                }
                else
                {
                    break;
                }
            }
            expect(TokenKind.CloseBrace, "Expected '}' in export statement");
            if (matchKeyword("from"))
            {
                consume();
                auto pathTok = expect(TokenKind.StringLiteral,
                        "Expected string path after export 'from'");
                exp.fromPath = unquote(pathTok.text);
            }
            if (match(TokenKind.Semicolon))
            {
                consume();
            }
            mod.exports ~= exp;
        }
        else
        {
            auto tok = peek();
            throw new SlintParseError(filePath, tok.line, tok.column,
                    "Unexpected export item: '" ~ tok.text ~ "'");
        }
    }

    // ── Enums and Structs ────────────────────────────────────

    private @safe SlintEnum parseEnum(bool isExported)
    {
        auto kw = consume(); // 'enum'
        enterRecursion(kw.line, kw.column);
        scope (exit)
            exitRecursion();

        auto nameTok = expectIdentifierOrKeyword("Expected enum name");
        expect(TokenKind.OpenBrace, "Expected '{' after enum name");

        SlintEnum slintEnum;
        slintEnum.name = nameTok.text;
        slintEnum.isExported = isExported;
        slintEnum.line = kw.line;
        slintEnum.column = kw.column;

        while (!match(TokenKind.CloseBrace) && !isEOF())
        {
            auto varTok = expectIdentifierOrKeyword("Expected enum variant identifier");
            slintEnum.variants ~= varTok.text;
            if (match(TokenKind.Comma))
            {
                consume();
            }
            else
            {
                break;
            }
        }
        expect(TokenKind.CloseBrace, "Expected '}' after enum body");
        return slintEnum;
    }

    private @safe SlintStruct parseStruct(bool isExported)
    {
        auto kw = consume(); // 'struct'
        enterRecursion(kw.line, kw.column);
        scope (exit)
            exitRecursion();

        auto nameTok = expectIdentifierOrKeyword("Expected struct name");
        expect(TokenKind.OpenBrace, "Expected '{' after struct name");

        SlintStruct slintStruct;
        slintStruct.name = nameTok.text;
        slintStruct.isExported = isExported;
        slintStruct.line = kw.line;
        slintStruct.column = kw.column;

        while (!match(TokenKind.CloseBrace) && !isEOF())
        {
            auto fieldNameTok = expectIdentifierOrKeyword("Expected struct field name");
            expect(TokenKind.Colon, "Expected ':' after struct field name");
            string typeName = parseTypeName();
            string defVal = "";
            if (match(TokenKind.Colon))
            {
                consume();
                defVal = parseExpressionUntil([
                    TokenKind.Comma, TokenKind.CloseBrace
                ]);
            }
            slintStruct.fields ~= SlintStructField(fieldNameTok.text, typeName, defVal);
            if (match(TokenKind.Comma))
            {
                consume();
            }
        }
        expect(TokenKind.CloseBrace, "Expected '}' after struct body");
        return slintStruct;
    }

    // ── Globals ──────────────────────────────────────────────

    private @safe SlintGlobal parseGlobal(bool isExported)
    {
        auto kw = consume(); // 'global'
        enterRecursion(kw.line, kw.column);
        scope (exit)
            exitRecursion();

        auto nameTok = expectIdentifierOrKeyword("Expected global name");
        expect(TokenKind.OpenBrace, "Expected '{' after global name");

        SlintGlobal slintGlobal;
        slintGlobal.name = nameTok.text;
        slintGlobal.isExported = isExported;
        slintGlobal.line = kw.line;
        slintGlobal.column = kw.column;

        while (!match(TokenKind.CloseBrace) && !isEOF())
        {
            if (matchPropertyDecl())
            {
                slintGlobal.properties ~= parseProperty();
            }
            else if (matchKeyword("callback") || matchKeyword("pure"))
            {
                slintGlobal.callbacks ~= parseCallback();
            }
            else if (matchKeyword("function"))
            {
                slintGlobal.functions ~= parseFunction();
            }
            else
            {
                auto tok = peek();
                throw new SlintParseError(filePath, tok.line, tok.column,
                        "Unexpected item inside global: '" ~ tok.text ~ "'");
            }
        }
        expect(TokenKind.CloseBrace, "Expected '}' after global body");
        return slintGlobal;
    }

    // ── Components ───────────────────────────────────────────

    private @safe SlintComponent parseComponent(bool isExported)
    {
        auto kw = consume(); // 'component'
        enterRecursion(kw.line, kw.column);
        scope (exit)
            exitRecursion();

        auto nameTok = expectIdentifierOrKeyword("Expected component name");
        string basePrimitive = "Rectangle";

        if (matchKeyword("inherits"))
        {
            consume();
            auto baseTok = expectIdentifierOrKeyword("Expected base element name after inherits");
            basePrimitive = baseTok.text;
        }

        expect(TokenKind.OpenBrace, "Expected '{' to start component body");

        auto comp = new SlintComponent(nameTok.text, isExported, kw.line, kw.column);
        comp.rootElement = new SlintElement("root", basePrimitive, kw.line, kw.column);

        parseElementBody(comp.rootElement, comp);

        expect(TokenKind.CloseBrace, "Expected '}' to close component body");
        return comp;
    }

    private @safe void parseElementBody(SlintElement elem, SlintComponent comp)
    {
        enterRecursion(elem.line, elem.column);
        scope (exit)
            exitRecursion();

        while (!match(TokenKind.CloseBrace) && !isEOF())
        {
            if (match(TokenKind.AtChildren))
            {
                consume();
                elem.children ~= SlintChild(null, null, null, true);
            }
            else if (matchPropertyDecl())
            {
                auto prop = parseProperty();
                if (comp !is null && elem.id == "root")
                {
                    comp.properties ~= prop;
                }
                else
                {
                    elem.properties ~= prop;
                }
            }
            else if (matchKeyword("callback") || (matchKeyword("pure") && peek(1).text == "callback"))
            {
                auto cb = parseCallback();
                if (comp !is null && elem.id == "root")
                {
                    comp.callbacks ~= cb;
                }
            }
            else if (matchKeyword("function") || (matchKeyword("pure") && peek(1)
                    .text == "function") || (matchKeyword("public") && (peek(1)
                    .text == "function" || peek(2).text == "function")))
            {
                if (matchKeyword("public"))
                    consume();
                auto fn = parseFunction();
                if (comp !is null && elem.id == "root")
                {
                    comp.functions ~= fn;
                }
            }
            else if (matchKeyword("changed"))
            {
                auto chTok = consume(); // 'changed'
                auto propTok = expectIdentifierOrKeyword("Expected property name after 'changed'");
                expect(TokenKind.ArrowFat, "Expected '=>' after changed property name");
                string bodyCode = "";
                if (match(TokenKind.OpenBrace))
                {
                    bodyCode = parseBlockBody();
                }
                else
                {
                    bodyCode = parseExpressionUntil([TokenKind.Semicolon]);
                    if (match(TokenKind.Semicolon))
                        consume();
                }
                elem.callbackHandlers ~= SlintCallbackHandler("changed-" ~ propTok.text,
                        [], bodyCode, chTok.line, chTok.column);
            }
            else if (matchKeyword("animate"))
            {
                // animate propName { duration: 120ms; ... }
                consume();
                auto propTok = expectIdentifierOrKeyword("Expected property name for animate");
                expect(TokenKind.OpenBrace, "Expected '{' for animate block");
                SlintAnimate anim;
                anim.propertyName = propTok.text;
                while (!match(TokenKind.CloseBrace) && !isEOF())
                {
                    auto keyTok = expectIdentifierOrKeyword("Expected animate attribute");
                    expect(TokenKind.Colon, "Expected ':' in animate attribute");
                    string val = parseExpressionUntil([TokenKind.Semicolon]);
                    expect(TokenKind.Semicolon, "Expected ';' after animate attribute");
                    if (keyTok.text == "duration")
                    {
                        anim.duration = val.strip();
                    }
                    else if (keyTok.text == "easing")
                    {
                        anim.easing = val.strip();
                    }
                }
                expect(TokenKind.CloseBrace, "Expected '}' closing animate block");
                // Attach animate to matching binding or store
                bool attached = false;
                foreach (ref b; elem.bindings)
                {
                    if (b.name == anim.propertyName)
                    {
                        b.animate = anim;
                        attached = true;
                        break;
                    }
                }
                if (!attached)
                {
                    elem.bindings ~= SlintBinding(anim.propertyName, "", anim,
                            propTok.line, propTok.column);
                }
            }
            else if (matchKeyword("if"))
            {
                elem.children ~= SlintChild(null, parseIfBlock(comp), null, false);
            }
            else if (matchKeyword("for"))
            {
                elem.children ~= SlintChild(null, null, parseForBlock(comp), false);
            }
            else if (isElementDeclaration())
            {
                auto childElem = parseElement(comp);
                elem.children ~= SlintChild(childElem, null, null, false);
            }
            else if (isCallbackHandler())
            {
                elem.callbackHandlers ~= parseCallbackHandler();
            }
            else if (isPropertyBinding())
            {
                auto b = parsePropertyBinding();
                bool merged = false;
                foreach (ref existing; elem.bindings)
                {
                    if (existing.name == b.name)
                    {
                        existing.expr = b.expr;
                        if (existing.animate.propertyName.length == 0
                                && b.animate.propertyName.length > 0)
                            existing.animate = b.animate;
                        merged = true;
                        break;
                    }
                }
                if (!merged)
                    elem.bindings ~= b;
            }
            else
            {
                auto tok = peek();
                throw new SlintParseError(filePath, tok.line, tok.column,
                        "Unexpected token inside element: '" ~ tok.text ~ "'");
            }
        }
    }

    private @safe SlintElement parseElement(SlintComponent comp)
    {
        string id = "";
        size_t elLine = peek().line;
        size_t elCol = peek().column;
        enterRecursion(elLine, elCol);
        scope (exit)
            exitRecursion();

        if (peek(1).kind == TokenKind.AssignId)
        {
            id = consume().text;
            consume(); // ':='
        }

        auto primTok = expectIdentifierOrKeyword("Expected element type name");
        expect(TokenKind.OpenBrace, "Expected '{' to start element body");

        auto elem = new SlintElement(id, primTok.text, elLine, elCol);
        parseElementBody(elem, comp);
        expect(TokenKind.CloseBrace, "Expected '}' to close element body");

        return elem;
    }

    private @safe SlintIf parseIfBlock(SlintComponent comp)
    {
        auto ifTok = consume(); // 'if'
        enterRecursion(ifTok.line, ifTok.column);
        scope (exit)
            exitRecursion();

        string condition = "";
        if (match(TokenKind.OpenParen))
        {
            consume();
            condition = parseExpressionUntil([TokenKind.CloseParen]);
            expect(TokenKind.CloseParen, "Expected ')' after if condition");
        }
        else
        {
            condition = parseExpressionUntil([
                TokenKind.Colon, TokenKind.OpenBrace
            ]);
        }

        auto ifBlock = new SlintIf(condition.strip(), ifTok.line, ifTok.column);

        if (match(TokenKind.Colon))
        {
            consume(); // ':'
            if (isElementDeclaration())
            {
                ifBlock.element = parseElement(comp);
            }
            else
            {
                expect(TokenKind.OpenBrace, "Expected '{' after ':' in if block");
                auto dummy = new SlintElement("", "Group", ifTok.line, ifTok.column);
                parseElementBody(dummy, comp);
                expect(TokenKind.CloseBrace, "Expected '}' after if block");
                ifBlock.children = dummy.children;
            }
        }
        else if (match(TokenKind.OpenBrace))
        {
            consume();
            auto dummy = new SlintElement("", "Group", ifTok.line, ifTok.column);
            parseElementBody(dummy, comp);
            expect(TokenKind.CloseBrace, "Expected '}' after if block");
            ifBlock.children = dummy.children;
        }

        if (matchKeyword("else"))
        {
            consume(); // 'else'
            if (matchKeyword("if"))
            {
                ifBlock.elseBranch = parseIfBlock(comp);
            }
            else if (match(TokenKind.Colon))
            {
                consume();
                auto elseIf = new SlintIf("true", peek().line, peek().column);
                if (isElementDeclaration())
                {
                    elseIf.element = parseElement(comp);
                }
                else
                {
                    expect(TokenKind.OpenBrace, "Expected '{' after ':' in else block");
                    auto dummy = new SlintElement("", "Group", peek().line, peek().column);
                    parseElementBody(dummy, comp);
                    expect(TokenKind.CloseBrace, "Expected '}' after else block");
                    elseIf.children = dummy.children;
                }
                ifBlock.elseBranch = elseIf;
            }
            else if (match(TokenKind.OpenBrace))
            {
                consume();
                auto elseIf = new SlintIf("true", peek().line, peek().column);
                auto dummy = new SlintElement("", "Group", peek().line, peek().column);
                parseElementBody(dummy, comp);
                expect(TokenKind.CloseBrace, "Expected '}' after else block");
                elseIf.children = dummy.children;
                ifBlock.elseBranch = elseIf;
            }
        }

        return ifBlock;
    }

    private @safe SlintFor parseForBlock(SlintComponent comp)
    {
        auto forTok = consume(); // 'for'
        enterRecursion(forTok.line, forTok.column);
        scope (exit)
            exitRecursion();

        auto itemTok = expectIdentifierOrKeyword("Expected loop variable name");
        string itemVar = itemTok.text;
        string indexVar = "";

        if (match(TokenKind.OpenBracket))
        {
            consume(); // '['
            auto idxTok = expectIdentifierOrKeyword("Expected index variable name");
            indexVar = idxTok.text;
            expect(TokenKind.CloseBracket, "Expected ']' after index variable");
        }

        expectKeyword("in", "Expected 'in' in for loop");
        string iterable = parseExpressionUntil([
            TokenKind.Colon, TokenKind.OpenBrace
        ]).strip();

        auto forBlock = new SlintFor(itemVar, indexVar, iterable, forTok.line, forTok.column);

        if (match(TokenKind.Colon))
        {
            consume();
            if (isElementDeclaration())
            {
                forBlock.element = parseElement(comp);
            }
            else
            {
                expect(TokenKind.OpenBrace, "Expected '{' after ':' in for loop");
                auto dummy = new SlintElement("", "Group", forTok.line, forTok.column);
                parseElementBody(dummy, comp);
                expect(TokenKind.CloseBrace, "Expected '}' after for loop body");
                forBlock.children = dummy.children;
            }
        }
        else if (match(TokenKind.OpenBrace))
        {
            consume();
            auto dummy = new SlintElement("", "Group", forTok.line, forTok.column);
            parseElementBody(dummy, comp);
            expect(TokenKind.CloseBrace, "Expected '}' after for loop body");
            forBlock.children = dummy.children;
        }

        return forBlock;
    }

    // ── Properties, Callbacks, and Functions ─────────────────

    private @safe bool matchPropertyDecl()
    {
        if (matchKeyword("property"))
        {
            return true;
        }
        if (matchKeyword("in") || matchKeyword("out") || matchKeyword("in-out"))
        {
            return peek(1).text == "property";
        }
        return false;
    }

    private @safe SlintProperty parseProperty()
    {
        PropertyDirection dir = PropertyDirection.None;
        size_t line = peek().line;
        size_t col = peek().column;

        if (matchKeyword("in-out"))
        {
            consume();
            consume(); // 'property'
            dir = PropertyDirection.InOut;
        }
        else if (matchKeyword("in"))
        {
            consume();
            consume(); // 'property'
            dir = PropertyDirection.In;
        }
        else if (matchKeyword("out"))
        {
            consume();
            consume(); // 'property'
            dir = PropertyDirection.Out;
        }
        else if (matchKeyword("property"))
        {
            consume(); // 'property'
            dir = PropertyDirection.None;
        }

        expect(TokenKind.Less, "Expected '<' before property type");
        string typeName = parseTypeName();
        expect(TokenKind.Greater, "Expected '>' after property type");

        auto nameTok = expectIdentifierOrKeyword("Expected property name");
        string defVal = "";

        if (match(TokenKind.Colon))
        {
            consume();
            defVal = parseExpressionUntil([TokenKind.Semicolon]).strip();
        }
        expect(TokenKind.Semicolon, "Expected ';' after property declaration");

        return SlintProperty(nameTok.text, typeName, dir, defVal, line, col);
    }

    private @safe SlintCallback parseCallback()
    {
        bool isPure = false;
        size_t line = peek().line;
        size_t col = peek().column;

        if (matchKeyword("pure"))
        {
            consume();
            isPure = true;
        }
        expectKeyword("callback", "Expected 'callback'");

        auto nameTok = expectIdentifierOrKeyword("Expected callback name");
        string[] paramTypes;
        string returnType = "void";

        if (match(TokenKind.OpenParen))
        {
            consume();
            while (!match(TokenKind.CloseParen) && !isEOF())
            {
                paramTypes ~= parseTypeName();
                if (match(TokenKind.Comma))
                {
                    consume();
                }
                else
                {
                    break;
                }
            }
            expect(TokenKind.CloseParen, "Expected ')' after callback parameters");
        }

        if (match(TokenKind.ArrowThin))
        {
            consume();
            returnType = parseTypeName();
        }

        expect(TokenKind.Semicolon, "Expected ';' after callback declaration");
        return SlintCallback(nameTok.text, paramTypes, returnType, isPure, line, col);
    }

    private @safe SlintFunction parseFunction()
    {
        bool isPure = false;
        size_t line = peek().line;
        size_t col = peek().column;

        if (matchKeyword("pure"))
        {
            consume();
            isPure = true;
        }
        expectKeyword("function", "Expected 'function'");

        auto nameTok = expectIdentifierOrKeyword("Expected function name");
        string[][] params;
        string returnType = "void";

        expect(TokenKind.OpenParen, "Expected '(' after function name");
        while (!match(TokenKind.CloseParen) && !isEOF())
        {
            auto pName = expectIdentifierOrKeyword("Expected parameter name").text;
            string pType = "any";
            if (match(TokenKind.Colon))
            {
                consume();
                pType = parseTypeName();
            }
            params ~= [pName, pType];
            if (match(TokenKind.Comma))
            {
                consume();
            }
            else
            {
                break;
            }
        }
        expect(TokenKind.CloseParen, "Expected ')' after function parameters");

        if (match(TokenKind.ArrowThin))
        {
            consume();
            returnType = parseTypeName();
        }

        string bodyCode = parseBlockBody();
        return SlintFunction(nameTok.text, params, returnType, bodyCode, isPure, line, col);
    }

    private @safe bool isCallbackHandler()
    {
        // Name => { ... } or Name(params) => { ... }
        if (!match(TokenKind.Identifier) && !match(TokenKind.Keyword))
        {
            return false;
        }
        if (peek(1).kind == TokenKind.ArrowFat)
        {
            return true;
        }
        if (peek(1).kind == TokenKind.OpenParen)
        {
            // scan ahead to find matching close paren and =>
            size_t i = cursor + 2;
            int depth = 1;
            while (i < tokens.length && depth > 0)
            {
                if (tokens[i].kind == TokenKind.OpenParen)
                    depth++;
                else if (tokens[i].kind == TokenKind.CloseParen)
                    depth--;
                i++;
            }
            if (i < tokens.length && tokens[i].kind == TokenKind.ArrowFat)
            {
                return true;
            }
        }
        return false;
    }

    private @safe SlintCallbackHandler parseCallbackHandler()
    {
        auto nameTok = consume();
        size_t line = nameTok.line;
        size_t col = nameTok.column;
        string[] params;

        if (match(TokenKind.OpenParen))
        {
            consume();
            while (!match(TokenKind.CloseParen) && !isEOF())
            {
                params ~= consume().text;
                if (match(TokenKind.Comma))
                {
                    consume();
                }
                else
                {
                    break;
                }
            }
            expect(TokenKind.CloseParen, "Expected ')' in callback handler arguments");
        }

        expect(TokenKind.ArrowFat, "Expected '=>' in callback handler");
        string bodyCode = "";
        if (match(TokenKind.OpenBrace))
        {
            bodyCode = parseBlockBody();
        }
        else
        {
            bodyCode = parseExpressionUntil([TokenKind.Semicolon]);
            if (match(TokenKind.Semicolon))
            {
                consume();
            }
        }

        return SlintCallbackHandler(nameTok.text, params, bodyCode, line, col);
    }

    private @safe bool isPropertyBinding()
    {
        if ((match(TokenKind.Identifier) || match(TokenKind.Keyword)) && (peek(1)
                .kind == TokenKind.Colon || peek(1).kind == TokenKind.TwoWayBinding))
        {
            return true;
        }
        return false;
    }

    private @safe SlintBinding parsePropertyBinding()
    {
        auto nameTok = consume();
        size_t line = nameTok.line;
        size_t col = nameTok.column;
        if (match(TokenKind.TwoWayBinding))
        {
            consume();
        }
        else
        {
            expect(TokenKind.Colon, "Expected ':' or '<=>' after property binding name");
        }

        string expr = parseExpressionUntil([TokenKind.Semicolon]);
        expect(TokenKind.Semicolon, "Expected ';' after property binding");

        return SlintBinding(nameTok.text, expr.strip(), SlintAnimate.init, line, col);
    }

    private @safe bool isElementDeclaration()
    {
        if (peek(1).kind == TokenKind.AssignId)
        {
            return true; // id := PrimitiveName {
        }
        if ((match(TokenKind.Identifier) || match(TokenKind.Keyword)) && peek(1)
                .kind == TokenKind.OpenBrace)
        {
            return true; // PrimitiveName {
        }
        return false;
    }

    // ── Expression and Block Parsers ─────────────────────────

    private @safe string parseTypeName()
    {
        enterRecursion(peek().line, peek().column);
        scope (exit)
            exitRecursion();

        if (match(TokenKind.OpenBracket))
        {
            consume(); // '['
            string inner = parseTypeName();
            expect(TokenKind.CloseBracket, "Expected ']' in array type");
            return "[" ~ inner ~ "]";
        }
        auto tok = expectIdentifierOrKeyword("Expected type name");
        return tok.text;
    }

    private @safe string parseBlockBody()
    {
        auto open = expect(TokenKind.OpenBrace, "Expected '{' to start block");
        enterRecursion(open.line, open.column);
        scope (exit)
            exitRecursion();

        string result = "{";
        int depth = 1;

        while (depth > 0 && !isEOF())
        {
            auto tok = consume();
            result ~= " " ~ tok.text;
            if (tok.kind == TokenKind.OpenBrace)
            {
                depth++;
                enterRecursion(tok.line, tok.column);
            }
            else if (tok.kind == TokenKind.CloseBrace)
            {
                depth--;
                exitRecursion();
            }
        }

        if (depth > 0)
        {
            throw new SlintParseError(filePath, open.line, open.column,
                    "Unterminated block body, expected '}'");
        }

        return result;
    }

    private @safe string parseExpressionUntil(const(TokenKind)[] terminators)
    {
        string expr = "";
        char[] delimStack;
        TokenKind lastKind = TokenKind.EOF;

        while (!isEOF())
        {
            auto tok = peek();

            if (delimStack.length == 0)
            {
                bool isTerm = false;
                foreach (term; terminators)
                {
                    if (tok.kind == term)
                    {
                        isTerm = true;
                        break;
                    }
                }
                if (isTerm)
                {
                    break;
                }
            }

            consume();
            if (tok.kind == TokenKind.OpenParen)
            {
                delimStack ~= '(';
                enterRecursion(tok.line, tok.column);
            }
            else if (tok.kind == TokenKind.CloseParen)
            {
                if (delimStack.length == 0 || delimStack[$ - 1] != '(')
                {
                    throw new SlintParseError(filePath, tok.line, tok.column,
                            "Unmatched closing parenthesis ')'");
                }
                delimStack = delimStack[0 .. $ - 1];
                exitRecursion();
            }
            else if (tok.kind == TokenKind.OpenBrace)
            {
                delimStack ~= '{';
                enterRecursion(tok.line, tok.column);
            }
            else if (tok.kind == TokenKind.CloseBrace)
            {
                if (delimStack.length == 0 || delimStack[$ - 1] != '{')
                {
                    throw new SlintParseError(filePath, tok.line, tok.column,
                            "Unmatched closing brace '}'");
                }
                delimStack = delimStack[0 .. $ - 1];
                exitRecursion();
            }
            else if (tok.kind == TokenKind.OpenBracket)
            {
                delimStack ~= '[';
                enterRecursion(tok.line, tok.column);
            }
            else if (tok.kind == TokenKind.CloseBracket)
            {
                if (delimStack.length == 0 || delimStack[$ - 1] != '[')
                {
                    throw new SlintParseError(filePath, tok.line, tok.column,
                            "Unmatched closing bracket ']'");
                }
                delimStack = delimStack[0 .. $ - 1];
                exitRecursion();
            }

            bool needSpace = expr.length > 0 && tok.kind != TokenKind.Dot
                && lastKind != TokenKind.Dot && tok.kind != TokenKind.Comma
                && tok.kind != TokenKind.Semicolon && tok.kind != TokenKind.CloseParen
                && tok.kind != TokenKind.CloseBracket && lastKind != TokenKind.OpenParen
                && lastKind != TokenKind.OpenBracket && lastKind != TokenKind.Exclamation;

            if (needSpace)
            {
                expr ~= " ";
            }
            expr ~= tok.text;
            lastKind = tok.kind;
        }

        if (delimStack.length > 0)
        {
            auto tok = peek();
            throw new SlintParseError(filePath, tok.line, tok.column,
                    "Unclosed delimiter in expression, expected matching closing symbol");
        }

        return expr;
    }

    // ── Helper methods ───────────────────────────────────────

    private @safe pure nothrow bool isEOF() const
    {
        return cursor >= tokens.length || tokens[cursor].kind == TokenKind.EOF;
    }

    private @safe pure nothrow Token peek(size_t offset = 0) const
    {
        if (cursor + offset < tokens.length)
        {
            return tokens[cursor + offset];
        }
        return Token(TokenKind.EOF, "", 0, 0);
    }

    private @safe Token consume()
    {
        if (cursor < tokens.length)
        {
            return tokens[cursor++];
        }
        return Token(TokenKind.EOF, "", 0, 0);
    }

    private @safe bool match(TokenKind kind) const
    {
        return !isEOF() && peek().kind == kind;
    }

    private @safe bool matchKeyword(string kw) const
    {
        return !isEOF() && (peek().kind == TokenKind.Keyword || peek()
                .kind == TokenKind.Identifier) && peek().text == kw;
    }

    private @safe Token expect(TokenKind kind, string msg)
    {
        if (match(kind))
        {
            return consume();
        }
        auto tok = peek();
        throw new SlintParseError(filePath, tok.line, tok.column, msg ~ " (got '" ~ tok.text ~ "')");
    }

    private @safe Token expectKeyword(string kw, string msg)
    {
        if (matchKeyword(kw))
        {
            return consume();
        }
        auto tok = peek();
        throw new SlintParseError(filePath, tok.line, tok.column, msg ~ " (got '" ~ tok.text ~ "')");
    }

    private @safe Token expectIdentifierOrKeyword(string msg)
    {
        if (match(TokenKind.Identifier) || match(TokenKind.Keyword))
        {
            return consume();
        }
        auto tok = peek();
        throw new SlintParseError(filePath, tok.line, tok.column, msg ~ " (got '" ~ tok.text ~ "')");
    }

    private @safe pure nothrow string unquote(string s) const
    {
        if (s.length >= 2 && s[0] == '"' && s[$ - 1] == '"')
        {
            return s[1 .. $ - 1];
        }
        return s;
    }
}
