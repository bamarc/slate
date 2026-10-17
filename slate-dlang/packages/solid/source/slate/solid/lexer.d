/++
    Lexer/Tokenizer for `.slint` declarative UI files.
+/
module slate.solid.lexer;

import slate.solid.ast : SlintParseError;
import std.ascii : isAlpha, isAlphaNum, isDigit, isWhite;
import std.conv : to;

/// Token kinds in the Slint grammar.
enum TokenKind
{
    EOF,
    Identifier,
    Keyword,
    Number,
    HexColor,
    StringLiteral,
    BooleanLiteral,

    // Operators and punctuation
    AssignId, // :=
    ArrowFat, // =>
    ArrowThin, // ->
    TwoWayBinding, // <=>
    EqualEqual, // ==
    NotEqual, // !=
    LessEqual, // <=
    GreaterEqual, // >=
    LogicalAnd, // &&
    LogicalOr, // ||
    PlusEqual, // +=
    MinusEqual, // -=

    Colon, // :
    Semicolon, // ;
    Comma, // ,
    Dot, // .
    Assign, // =
    Question, // ?
    Exclamation, // !
    Less, // <
    Greater, // >
    Plus, // +
    Minus, // -
    Star, // *
    Slash, // /
    Percent, // %

    OpenBrace, // {
    CloseBrace, // }
    OpenParen, // (
    CloseParen, // )
    OpenBracket, // [
    CloseBracket, // ]
    AtChildren // @children
}

/// A token emitted by the Slint lexer.
struct Token
{
    TokenKind kind;
    string text;
    size_t line;
    size_t column;
}

/// Tokenizer for Slint source files.
class SlintLexer
{
    private string source;
    private string filePath;
    private size_t index;
    private size_t currentLine = 1;
    private size_t currentColumn = 1;

    @safe pure nothrow this(string source, string filePath = "")
    {
        this.source = source;
        this.filePath = filePath;
        this.index = 0;
    }

    /// Retrieve the next token from the stream.
    @safe Token nextToken()
    {
        skipWhitespaceAndComments();

        if (index >= source.length)
        {
            return Token(TokenKind.EOF, "", currentLine, currentColumn);
        }

        size_t tokenLine = currentLine;
        size_t tokenCol = currentColumn;
        char c = source[index];

        // @children check
        if (c == '@')
        {
            if (index + 9 <= source.length && source[index .. index + 9] == "@children")
            {
                advance(9);
                return Token(TokenKind.AtChildren, "@children", tokenLine, tokenCol);
            }
        }

        // Multi-character punctuation
        if (c == ':' && peek(1) == '=')
        {
            advance(2);
            return Token(TokenKind.AssignId, ":=", tokenLine, tokenCol);
        }
        if (c == '=' && peek(1) == '>')
        {
            advance(2);
            return Token(TokenKind.ArrowFat, "=>", tokenLine, tokenCol);
        }
        if (c == '-' && peek(1) == '>')
        {
            advance(2);
            return Token(TokenKind.ArrowThin, "->", tokenLine, tokenCol);
        }
        if (c == '=' && peek(1) == '=')
        {
            advance(2);
            return Token(TokenKind.EqualEqual, "==", tokenLine, tokenCol);
        }
        if (c == '!' && peek(1) == '=')
        {
            advance(2);
            return Token(TokenKind.NotEqual, "!=", tokenLine, tokenCol);
        }
        if (c == '<' && peek(1) == '=' && peek(2) == '>')
        {
            advance(3);
            return Token(TokenKind.TwoWayBinding, "<=>", tokenLine, tokenCol);
        }
        if (c == '<' && peek(1) == '=')
        {
            advance(2);
            return Token(TokenKind.LessEqual, "<=", tokenLine, tokenCol);
        }
        if (c == '>' && peek(1) == '=')
        {
            advance(2);
            return Token(TokenKind.GreaterEqual, ">=", tokenLine, tokenCol);
        }
        if (c == '&' && peek(1) == '&')
        {
            advance(2);
            return Token(TokenKind.LogicalAnd, "&&", tokenLine, tokenCol);
        }
        if (c == '|' && peek(1) == '|')
        {
            advance(2);
            return Token(TokenKind.LogicalOr, "||", tokenLine, tokenCol);
        }
        if (c == '+' && peek(1) == '=')
        {
            advance(2);
            return Token(TokenKind.PlusEqual, "+=", tokenLine, tokenCol);
        }
        if (c == '-' && peek(1) == '=')
        {
            advance(2);
            return Token(TokenKind.MinusEqual, "-=", tokenLine, tokenCol);
        }

        // Hex color literal: #fff, #0f1117, etc.
        if (c == '#')
        {
            return lexHexColor(tokenLine, tokenCol);
        }

        // String literal
        if (c == '"')
        {
            return lexString(tokenLine, tokenCol);
        }

        // Number literal
        if (isDigit(c) || (c == '.' && isDigit(peek(1))))
        {
            return lexNumber(tokenLine, tokenCol);
        }

        // Identifier or keyword (supports kebab-case like is-dark, border-radius)
        if (isAlpha(c) || c == '_')
        {
            return lexIdentifierOrKeyword(tokenLine, tokenCol);
        }

        // Single-character punctuation
        advance(1);
        switch (c)
        {
        case '{':
            return Token(TokenKind.OpenBrace, "{", tokenLine, tokenCol);
        case '}':
            return Token(TokenKind.CloseBrace, "}", tokenLine, tokenCol);
        case '(':
            return Token(TokenKind.OpenParen, "(", tokenLine, tokenCol);
        case ')':
            return Token(TokenKind.CloseParen, ")", tokenLine, tokenCol);
        case '[':
            return Token(TokenKind.OpenBracket, "[", tokenLine, tokenCol);
        case ']':
            return Token(TokenKind.CloseBracket, "]", tokenLine, tokenCol);
        case ':':
            return Token(TokenKind.Colon, ":", tokenLine, tokenCol);
        case ';':
            return Token(TokenKind.Semicolon, ";", tokenLine, tokenCol);
        case ',':
            return Token(TokenKind.Comma, ",", tokenLine, tokenCol);
        case '.':
            return Token(TokenKind.Dot, ".", tokenLine, tokenCol);
        case '=':
            return Token(TokenKind.Assign, "=", tokenLine, tokenCol);
        case '?':
            return Token(TokenKind.Question, "?", tokenLine, tokenCol);
        case '!':
            return Token(TokenKind.Exclamation, "!", tokenLine, tokenCol);
        case '<':
            return Token(TokenKind.Less, "<", tokenLine, tokenCol);
        case '>':
            return Token(TokenKind.Greater, ">", tokenLine, tokenCol);
        case '+':
            return Token(TokenKind.Plus, "+", tokenLine, tokenCol);
        case '-':
            return Token(TokenKind.Minus, "-", tokenLine, tokenCol);
        case '*':
            return Token(TokenKind.Star, "*", tokenLine, tokenCol);
        case '/':
            return Token(TokenKind.Slash, "/", tokenLine, tokenCol);
        case '%':
            return Token(TokenKind.Percent, "%", tokenLine, tokenCol);
        default:
            return Token(TokenKind.Identifier, [c], tokenLine, tokenCol);
        }
    }

    private @safe Token lexHexColor(size_t tokenLine, size_t tokenCol)
    {
        size_t start = index;
        advance(1); // skip '#'
        while (index < source.length && isHexDigit(source[index]))
        {
            advance(1);
        }
        return Token(TokenKind.HexColor, source[start .. index], tokenLine, tokenCol);
    }

    private @safe Token lexString(size_t tokenLine, size_t tokenCol)
    {
        size_t start = index;
        advance(1); // skip opening '"'
        int interpDepth = 0;
        bool inInterpString = false;
        bool closed = false;

        while (index < source.length)
        {
            if (interpDepth > 0)
            {
                if (inInterpString)
                {
                    if (source[index] == '\\' && index + 1 < source.length)
                    {
                        advance(2);
                    }
                    else if (source[index] == '"')
                    {
                        inInterpString = false;
                        advance(1);
                    }
                    else
                    {
                        advance(1);
                    }
                }
                else
                {
                    if (source[index] == '"')
                    {
                        inInterpString = true;
                        advance(1);
                    }
                    else if (source[index] == '{')
                    {
                        interpDepth++;
                        if (interpDepth > 128)
                        {
                            throw new SlintParseError(filePath, tokenLine, tokenCol,
                                    "Maximum interpolation depth (128) exceeded in string literal");
                        }
                        advance(1);
                    }
                    else if (source[index] == '}')
                    {
                        interpDepth--;
                        advance(1);
                    }
                    else if (source[index] == '\\' && index + 1 < source.length)
                    {
                        advance(2);
                    }
                    else
                    {
                        advance(1);
                    }
                }
            }
            else
            {
                if (source[index] == '\\' && peek(1) == '{')
                {
                    interpDepth = 1;
                    advance(2);
                }
                else if (source[index] == '\\' && index + 1 < source.length)
                {
                    advance(2); // escaped character e.g. \" or \\
                }
                else if (source[index] == '"')
                {
                    advance(1);
                    closed = true;
                    break;
                }
                else
                {
                    advance(1);
                }
            }
        }

        if (!closed)
        {
            throw new SlintParseError(filePath, tokenLine, tokenCol,
                    "Unterminated string literal at end of file");
        }

        return Token(TokenKind.StringLiteral, source[start .. index], tokenLine, tokenCol);
    }

    private @safe Token lexNumber(size_t tokenLine, size_t tokenCol)
    {
        size_t start = index;
        bool hasDot = false;
        while (index < source.length)
        {
            if (isDigit(source[index]))
            {
                advance(1);
            }
            else if (source[index] == '.' && !hasDot && index + 1 < source.length
                    && isDigit(source[index + 1]))
            {
                hasDot = true;
                advance(1);
            }
            else
            {
                break;
            }
        }
        // Check for dimensional units or percentage: px, pt, ms, s, %, rem, deg, rad, phx
        if (index < source.length)
        {
            if (source[index] == '%')
            {
                advance(1);
            }
            else if (isAlpha(source[index]))
            {
                while (index < source.length && isAlpha(source[index]))
                {
                    advance(1);
                }
            }
        }
        return Token(TokenKind.Number, source[start .. index], tokenLine, tokenCol);
    }

    private @safe Token lexIdentifierOrKeyword(size_t tokenLine, size_t tokenCol)
    {
        size_t start = index;
        while (index < source.length)
        {
            char c = source[index];
            if (isAlphaNum(c) || c == '_')
            {
                advance(1);
            }
            else if (c == '-' && index + 1 < source.length
                    && (isAlphaNum(source[index + 1]) || source[index + 1] == '_'))
            {
                // kebab-case identifier support like is-dark, border-radius, surface-1, font-2xl
                advance(1);
            }
            else
            {
                break;
            }
        }

        string text = source[start .. index];
        if (text == "true" || text == "false")
        {
            return Token(TokenKind.BooleanLiteral, text, tokenLine, tokenCol);
        }

        if (isKeyword(text))
        {
            return Token(TokenKind.Keyword, text, tokenLine, tokenCol);
        }

        return Token(TokenKind.Identifier, text, tokenLine, tokenCol);
    }

    private @safe pure nothrow bool isKeyword(string text)
    {
        switch (text)
        {
        case "component":
        case "export":
        case "import":
        case "from":
        case "global":
        case "struct":
        case "enum":
        case "property":
        case "in":
        case "out":
        case "in-out":
        case "callback":
        case "pure":
        case "function":
        case "if":
        case "else":
        case "for":
        case "animate":
        case "changed":
        case "public":
        case "root":
        case "self":
        case "parent":
            return true;
        default:
            return false;
        }
    }

    private @safe pure nothrow bool isHexDigit(char c)
    {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }

    private @safe void skipWhitespaceAndComments()
    {
        while (index < source.length)
        {
            char c = source[index];
            if (isWhite(c))
            {
                advance(1);
            }
            else if (c == '/' && peek(1) == '/')
            {
                // Line comment
                advance(2);
                while (index < source.length && source[index] != '\n')
                {
                    advance(1);
                }
            }
            else if (c == '/' && peek(1) == '*')
            {
                // Block comment
                size_t commentLine = currentLine;
                size_t commentCol = currentColumn;
                advance(2);
                bool closed = false;
                while (index < source.length)
                {
                    if (source[index] == '*' && peek(1) == '/')
                    {
                        advance(2);
                        closed = true;
                        break;
                    }
                    advance(1);
                }
                if (!closed)
                {
                    throw new SlintParseError(filePath, commentLine, commentCol,
                            "Unterminated block comment '/*' at end of file");
                }
            }
            else
            {
                break;
            }
        }
    }

    private @safe pure nothrow char peek(size_t offset)
    {
        if (index + offset < source.length)
        {
            return source[index + offset];
        }
        return '\0';
    }

    private @safe void advance(size_t count)
    {
        foreach (_; 0 .. count)
        {
            if (index < source.length)
            {
                if (source[index] == '\n')
                {
                    currentLine++;
                    currentColumn = 1;
                }
                else
                {
                    currentColumn++;
                }
                index++;
            }
        }
    }
}
