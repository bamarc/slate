#!/usr/bin/env python3
"""MCP Stdio Server exposing Dlang & Slint LSP / Static Analysis tools to Antigravity."""

import json
import os
import subprocess
import sys
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[1]
DSCANNER_INI = WORKSPACE_ROOT / "dscanner.ini"

DEFAULT_D_DIRS = [
    "slint-d/source",
    "slate-dlang/source",
    "slate-dlang/packages/core/source",
    "slate-dlang/packages/net/source",
    "slate-dlang/packages/mcp/source",
    "slate-dlang/packages/ui/source",
]


def _resolve_targets(paths: list[str] | None) -> list[str]:
    if paths:
        return [str(WORKSPACE_ROOT / p) if not os.path.isabs(p) else p for p in paths]
    return [str(WORKSPACE_ROOT / d) for d in DEFAULT_D_DIRS if (WORKSPACE_ROOT / d).exists()]


def _run(cmd: list[str], cwd: Path = WORKSPACE_ROOT) -> tuple[int, str, str]:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd),
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


TOOLS = [
    {
        "name": "d_lint",
        "description": "Run D-Scanner syntax and static analysis checks (--syntaxCheck and --styleCheck) across D source files or directories.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "paths": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional list of file or directory paths relative to workspace root. Defaults to all slint-d and slate-dlang source directories.",
                }
            },
        },
    },
    {
        "name": "d_find_declaration",
        "description": "Find the exact file, line, and column where a D symbol (class, struct, interface, function, template) is declared using D-Scanner's AST parser.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "symbol": {
                    "type": "string",
                    "description": "The symbol name to locate (e.g. 'DataGridController', 'WindowHandle', 'McpStateRegistry').",
                },
                "paths": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional list of directories/files to search.",
                },
            },
            "required": ["symbol"],
        },
    },
    {
        "name": "d_module_imports",
        "description": "Inspect all modules imported by a D source file using D-Scanner AST import resolution.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {
                    "type": "string",
                    "description": "Path to the .d file (relative to workspace root or absolute).",
                }
            },
            "required": ["file"],
        },
    },
    {
        "name": "d_format",
        "description": "Check or apply canonical D code formatting using dfmt and the workspace .editorconfig.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {
                    "type": "string",
                    "description": "Path to the .d file to format or check.",
                },
                "in_place": {
                    "type": "boolean",
                    "description": "If true, formats the file in-place (-i). If false (default), returns a unified diff preview.",
                },
            },
            "required": ["file"],
        },
    },
    {
        "name": "d_lsp_document_symbols",
        "description": "Query the serve-d Language Server (LSP) for all structured symbols (classes, structs, methods, enums) in a D source file.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {
                    "type": "string",
                    "description": "Path to the .d file (relative to workspace root or absolute).",
                }
            },
            "required": ["file"],
        },
    },
    {
        "name": "slint_check",
        "description": "Validate a .slint UI file using slint-viewer / slint-lsp to verify syntax, imports, and component definitions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {
                    "type": "string",
                    "description": "Path to the .slint file (e.g. 'ui/index.slint').",
                }
            },
            "required": ["file"],
        },
    },
]


def _query_served_symbols(file_path: Path) -> str:
    proc = subprocess.Popen(
        ["serve-d"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    def send_rpc(msg: dict) -> None:
        body = json.dumps(msg).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        assert proc.stdin is not None
        proc.stdin.write(header + body)
        proc.stdin.flush()

    def recv_rpc() -> dict | None:
        assert proc.stdout is not None
        headers: dict[str, str] = {}
        while True:
            line = proc.stdout.readline().decode("ascii", errors="replace")
            if not line or line == "\r\n":
                break
            if ":" in line:
                k, v = line.strip().split(":", 1)
                headers[k.lower()] = v.strip()
        length = int(headers.get("content-length", "0"))
        if length <= 0:
            return None
        payload = proc.stdout.read(length).decode("utf-8", errors="replace")
        return json.loads(payload)

    try:
        uri = file_path.resolve().as_uri()
        root_uri = WORKSPACE_ROOT.as_uri()
        text = file_path.read_text(encoding="utf-8")
        send_rpc(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "processId": None,
                    "rootUri": root_uri,
                    "capabilities": {},
                },
            }
        )
        while True:
            resp = recv_rpc()
            if resp and resp.get("id") == 1:
                break

        send_rpc({"jsonrpc": "2.0", "method": "initialized", "params": {}})
        send_rpc(
            {
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": {
                    "textDocument": {
                        "uri": uri,
                        "languageId": "d",
                        "version": 1,
                        "text": text,
                    }
                },
            }
        )
        send_rpc(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "textDocument/documentSymbol",
                "params": {"textDocument": {"uri": uri}},
            }
        )
        while True:
            resp = recv_rpc()
            if resp and resp.get("id") == 2:
                return json.dumps(resp.get("result", []), indent=2)
    finally:
        proc.terminate()


def handle_tool_call(name: str, args: dict) -> str:
    if name == "d_lint":
        targets = _resolve_targets(args.get("paths"))
        rc1, out1, err1 = _run(["dscanner", "--syntaxCheck", *targets])
        rc2, out2, err2 = _run(
            ["dscanner", "--styleCheck", "--config", str(DSCANNER_INI), *targets]
        )
        combined = "\n".join(p for p in [out1.strip(), err1.strip(), out2.strip(), err2.strip()] if p)
        if rc1 == 0 and rc2 == 0 and not combined:
            return "OK: 0 syntax errors, 0 style/static-analysis warnings."
        return combined or f"Exited with syntax={rc1}, style={rc2}"

    if name == "d_find_declaration":
        symbol = args["symbol"]
        targets = _resolve_targets(args.get("paths"))
        _, out, err = _run(["dscanner", "-d", symbol, *targets])
        return (out + err).strip() or f"No declaration found for '{symbol}'."

    if name == "d_module_imports":
        fpath = WORKSPACE_ROOT / args["file"] if not os.path.isabs(args["file"]) else Path(args["file"])
        include_flags = []
        for d in DEFAULT_D_DIRS:
            p = WORKSPACE_ROOT / d
            if p.exists():
                include_flags.extend(["-I", str(p)])
        _, out, err = _run(["dscanner", "--imports", str(fpath), *include_flags])
        return (out + err).strip()

    if name == "d_format":
        fpath = WORKSPACE_ROOT / args["file"] if not os.path.isabs(args["file"]) else Path(args["file"])
        if args.get("in_place", False):
            rc, out, err = _run(["dfmt", "-i", str(fpath)])
            return f"Formatted {fpath} in-place (exit={rc}).\n{(out + err).strip()}".strip()
        _, formatted, err = _run(["dfmt", str(fpath)])
        if err.strip():
            return err.strip()
        original = fpath.read_text(encoding="utf-8")
        if original == formatted:
            return f"OK: {fpath.name} is already formatted according to .editorconfig."
        proc = subprocess.run(
            ["diff", "-u", str(fpath), "-"],
            input=formatted,
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.stdout or "Formatting differences detected."

    if name == "d_lsp_document_symbols":
        fpath = WORKSPACE_ROOT / args["file"] if not os.path.isabs(args["file"]) else Path(args["file"])
        _, out, _ = _run(["dscanner", "--ctags", str(fpath)])
        symbols = []
        kind_map = {
            "c": "class",
            "s": "struct",
            "i": "interface",
            "g": "enum",
            "e": "enum_member",
            "f": "function",
            "v": "variable",
            "T": "template",
            "a": "alias",
            "u": "union",
        }
        for line in out.splitlines():
            if line.startswith("!_TAG_"):
                continue
            parts = line.split("\t")
            if len(parts) >= 4:
                sym_name = parts[0]
                kind_code = parts[3]
                meta = {p.split(":", 1)[0]: p.split(":", 1)[1] for p in parts[4:] if ":" in p}
                symbols.append(
                    {
                        "name": sym_name,
                        "kind": kind_map.get(kind_code, kind_code),
                        "line": int(meta.get("line", "0")),
                        "access": meta.get("access", ""),
                        "scope": meta.get("class") or meta.get("struct") or meta.get("interface") or "",
                        "signature": meta.get("signature", ""),
                    }
                )
        if symbols:
            return json.dumps(symbols, indent=2)
        return _query_served_symbols(fpath)

    if name == "slint_check":
        fpath = WORKSPACE_ROOT / args["file"] if not os.path.isabs(args["file"]) else Path(args["file"])
        proc = subprocess.Popen(
            ["slint-lsp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            uri = fpath.resolve().as_uri()
            text = fpath.read_text(encoding="utf-8")

            def send_slint(msg: dict) -> None:
                body = json.dumps(msg).encode("utf-8")
                header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
                assert proc.stdin is not None
                proc.stdin.write(header + body)
                proc.stdin.flush()

            def recv_slint() -> dict | None:
                assert proc.stdout is not None
                headers: dict[str, str] = {}
                while True:
                    line = proc.stdout.readline().decode("ascii", errors="replace")
                    if not line or line == "\r\n":
                        break
                    if ":" in line:
                        k, v = line.strip().split(":", 1)
                        headers[k.lower()] = v.strip()
                length = int(headers.get("content-length", "0"))
                if length <= 0:
                    return None
                return json.loads(proc.stdout.read(length).decode("utf-8", errors="replace"))

            send_slint(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "processId": None,
                        "rootUri": WORKSPACE_ROOT.as_uri(),
                        "capabilities": {},
                    },
                }
            )
            while True:
                r = recv_slint()
                if r and r.get("id") == 1:
                    break
            send_slint({"jsonrpc": "2.0", "method": "initialized", "params": {}})
            send_slint(
                {
                    "jsonrpc": "2.0",
                    "method": "textDocument/didOpen",
                    "params": {
                        "textDocument": {
                            "uri": uri,
                            "languageId": "slint",
                            "version": 1,
                            "text": text,
                        }
                    },
                }
            )
            send_slint(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "textDocument/documentSymbol",
                    "params": {"textDocument": {"uri": uri}},
                }
            )
            diagnostics = []
            symbols = []
            while True:
                r = recv_slint()
                if not r:
                    break
                if r.get("method") == "textDocument/publishDiagnostics":
                    diagnostics = r.get("params", {}).get("diagnostics", [])
                if r.get("id") == 2:
                    symbols = r.get("result", [])
                    break
            return json.dumps({"diagnostics": diagnostics, "symbols": symbols}, indent=2)
        finally:
            proc.terminate()

    raise ValueError(f"Unknown tool: {name}")


def main() -> None:
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = req.get("method")
        req_id = req.get("id")

        if method == "initialize":
            resp = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "dlang-lsp", "version": "1.0.0"},
                },
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            resp = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"tools": TOOLS},
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
        elif method == "tools/call":
            params = req.get("params", {})
            tname = params.get("name", "")
            targs = params.get("arguments", {})
            try:
                output = handle_tool_call(tname, targs)
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": output}],
                        "isError": False,
                    },
                }
            except Exception as exc:  # noqa: BLE001
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": f"Error: {exc}"}],
                        "isError": True,
                    },
                }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
        elif req_id is not None:
            resp = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {},
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
