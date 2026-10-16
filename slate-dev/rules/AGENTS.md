# Slate Dlang & Slint Toolchain Rules (`slate-dev`)

Always use the installed Dlang (`dmd`, `dub`, `serve-d`, `dcd`, `dscanner`, `dfmt`) and Slint (`slint-lsp`, `slint-viewer`) toolchain in `~/.local/bin` (and synced to `~/.gemini/antigravity/bin`):

- **Syntax & Style Linting**: Run `just d-lint` (or `dscanner --syntaxCheck` and `dscanner --styleCheck --config dscanner.ini`, or the `d_lint` MCP tool) before completing D code changes.
- **Formatting**: Format modified `.d` files using `just d-fmt`, `dfmt -i <file.d>`, or the `d_format` MCP tool.
- **AST Symbol & Import Queries**: Prefer `dscanner -d <symbol>` (`d_find_declaration`), `dscanner --ctags <file.d>` (`d_lsp_document_symbols`), and `dscanner --imports <file.d>` (`d_module_imports`) over blind text regex searches when navigating D symbols.
- **Slint Validation**: Validate `.slint` UI changes using `slint_check` (`slint-lsp`).
