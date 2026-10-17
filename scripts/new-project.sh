#!/usr/bin/env bash
# ==============================================================================
# scripts/new-project.sh — Provision a new Slate Dlang + Slint + MCP application
#
# Creates a standalone Slate project in <target-dir> featuring:
#   - Declarative Slint window (app.slint) with Counter, Increment/Reset buttons,
#     and a live Switch to toggle the integrated MCP server on/off
#   - McpControllable CounterController (source/controller.d) with unit tests
#   - Native Slint + embedded MCP JSON-RPC 2.0 entrypoint (source/main.d)
#   - Ready-to-use mcp_config.json printed to stdout and written to disk
#
# Usage:
#   just new-project <target-dir> [app-name]
#   ./scripts/new-project.sh <target-dir> [app-name]
# ==============================================================================
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <target-dir> [app-name]" >&2
    exit 1
fi

SLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$1"
mkdir -p "$TARGET_DIR"
TARGET_ABS="$(cd "$TARGET_DIR" && pwd)"

RAW_NAME="${2:-$(basename "$TARGET_ABS")}"
# Normalize package name to lowercase alphanumeric + hyphens
APP_NAME="$(echo "$RAW_NAME" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]//g')"
[ -z "$APP_NAME" ] && APP_NAME="slate-counter-app"

SLINT_D_PATH="${SLATE_ROOT}/slint-d"
SLATE_DLANG_PATH="${SLATE_ROOT}/slate-dlang"
BRIDGE_LIB_DIR="${SLATE_ROOT}/slint-d/bridge/target/debug"
SLATE_LIB_DIR="${SLATE_ROOT}/slate-dlang/lib"

mkdir -p "$TARGET_ABS/source"

# 1. Write dub.json
cat > "$TARGET_ABS/dub.json" <<EOF
{
    "name": "${APP_NAME}",
    "description": "Slate desktop application with integrated MCP automation server",
    "license": "MIT",
    "targetType": "executable",
    "targetName": "${APP_NAME}",
    "mainSourceFile": "source/main.d",
    "sourcePaths": ["source"],
    "importPaths": ["source"],
    "dependencies": {
        "slint-d": {"path": "${SLINT_D_PATH}"},
        "slate": {"path": "${SLATE_DLANG_PATH}"}
    },
    "lflags-posix": [
        "-L${HOME}/.local/lib",
        "-L${SLATE_LIB_DIR}",
        "-L${BRIDGE_LIB_DIR}",
        "-rpath=${BRIDGE_LIB_DIR}"
    ],
    "configurations": [
        {
            "name": "application",
            "targetType": "executable"
        },
        {
            "name": "native",
            "targetType": "executable",
            "versions": ["SlintNative"],
            "subConfigurations": {
                "slate": "native",
                "slint-d": "native"
            }
        }
    ],
    "buildTypes": {
        "unittest": {
            "buildOptions": ["unittests", "debugMode", "debugInfo"]
        }
    }
}
EOF

# 2. Write app.slint
cat > "$TARGET_ABS/app.slint" <<'EOF'
export component MainWindow inherits Window {
    title: "Slate Counter + Opt-In Secure MCP";
    preferred-width: 480px;
    preferred-height: 340px;
    background: #0f172a;

    in-out property <int> counter: 0;
    in-out property <bool> mcpEnabled: false;
    in-out property <string> mcpStatus: "MCP: Disabled (Opt-In)";

    callback increment();
    callback reset();
    callback toggleMcp(bool);

    VerticalLayout {
        padding: 24px;
        spacing: 20px;

        // Header + MCP Switch Row
        HorizontalLayout {
            alignment: space-between;
            VerticalLayout {
                spacing: 4px;
                Text {
                    text: "Slate Counter";
                    color: #f8fafc;
                    font-size: 20px;
                    font-weight: 700;
                }
                Text {
                    text: root.mcpStatus;
                    color: root.mcpEnabled ? #34d399 : #94a3b8;
                    font-size: 12px;
                }
            }

            // Integrated MCP Enable/Disable Switch (Opt-In)
            mcp_switch := Rectangle {
                width: 150px;
                height: 36px;
                border-radius: 18px;
                background: root.mcpEnabled ? #065f46 : #1e293b;
                border-width: 1px;
                border-color: root.mcpEnabled ? #10b981 : #334155;

                accessible-role: checkbox;
                accessible-id: "switch-mcp";
                accessible-label: "Enable Integrated MCP";
                accessible-checked: root.mcpEnabled;
                accessible-action-default => {
                    root.mcpEnabled = !root.mcpEnabled;
                    root.toggleMcp(root.mcpEnabled);
                }

                HorizontalLayout {
                    padding-left: 12px;
                    padding-right: 12px;
                    alignment: space-between;
                    Text {
                        text: root.mcpEnabled ? "MCP: ON" : "MCP: OFF";
                        color: #f8fafc;
                        font-size: 12px;
                        font-weight: 600;
                        vertical-alignment: center;
                    }
                    Rectangle {
                        width: 18px;
                        height: 18px;
                        y: 8px;
                        border-radius: 9px;
                        background: root.mcpEnabled ? #34d399 : #64748b;
                    }
                }

                TouchArea {
                    clicked => {
                        root.mcpEnabled = !root.mcpEnabled;
                        root.toggleMcp(root.mcpEnabled);
                    }
                }
            }
        }

        // Counter Card
        Rectangle {
            background: #1e293b;
            border-radius: 12px;
            border-width: 1px;
            border-color: #334155;
            height: 120px;

            accessible-role: text;
            accessible-id: "counter-display";
            accessible-label: "Counter Value";
            accessible-value: "\{root.counter}";

            VerticalLayout {
                alignment: center;
                spacing: 6px;
                Text {
                    text: "CURRENT COUNT";
                    color: #94a3b8;
                    font-size: 11px;
                    font-weight: 600;
                    horizontal-alignment: center;
                }
                Text {
                    text: "\{root.counter}";
                    color: #f8fafc;
                    font-size: 44px;
                    font-weight: 700;
                    horizontal-alignment: center;
                }
            }
        }

        // Action Buttons
        HorizontalLayout {
            spacing: 12px;

            inc_btn := Rectangle {
                horizontal-stretch: 2;
                height: 44px;
                border-radius: 8px;
                background: inc_touch.has-hover ? #2563eb : #3b82f6;

                accessible-role: button;
                accessible-id: "btn-increment";
                accessible-label: "Increment Counter";
                accessible-action-default => { root.increment(); }

                Text {
                    text: "Increment (+1)";
                    color: #ffffff;
                    font-size: 14px;
                    font-weight: 600;
                    horizontal-alignment: center;
                    vertical-alignment: center;
                }
                inc_touch := TouchArea {
                    clicked => { root.increment(); }
                }
            }

            reset_btn := Rectangle {
                horizontal-stretch: 1;
                height: 44px;
                border-radius: 8px;
                background: reset_touch.has-hover ? #334155 : #1e293b;
                border-width: 1px;
                border-color: #475569;

                accessible-role: button;
                accessible-id: "btn-reset";
                accessible-label: "Reset Counter";
                accessible-action-default => { root.reset(); }

                Text {
                    text: "Reset";
                    color: #e2e8f0;
                    font-size: 14px;
                    font-weight: 500;
                    horizontal-alignment: center;
                    vertical-alignment: center;
                }
                reset_touch := TouchArea {
                    clicked => { root.reset(); }
                }
            }
        }
    }
}
EOF

# 3. Write source/controller.d
cat > "$TARGET_ABS/source/controller.d" <<'EOF'
/// Reactive Counter + opt-in MCP switch controller with compile-time MCP introspection.
module controller;

import slate.agent.traits : McpControllable, McpControllableMixin;

class CounterController : McpControllable
{
    int count = 0;
    bool mcpEnabled = false;

    mixin McpControllableMixin!"counter";

    this(int initialCount = 0, bool initialMcpEnabled = false) @safe pure nothrow
    {
        this.count = initialCount;
        this.mcpEnabled = initialMcpEnabled;
    }

    int increment() @safe pure nothrow
    {
        count += 1;
        return count;
    }

    int reset() @safe pure nothrow
    {
        count = 0;
        return count;
    }

    bool setMcpEnabled(bool enabled) @safe pure nothrow
    {
        mcpEnabled = enabled;
        return mcpEnabled;
    }

    string statusText(string socketPath = "") const @safe pure nothrow
    {
        if (!mcpEnabled)
            return "MCP: Disabled (Opt-In)";
        if (socketPath.length > 0)
            return "MCP: Active (Unix Socket 0600 + Token)";
        return "MCP: Active";
    }
}

// Spec: CounterController starts with MCP disabled (opt-in), increments, resets, and exposes MCP snapshots.
/// Example:
unittest
{
    import std.json : JSONValue;

    auto ctrl = new CounterController();
    assert(ctrl.count == 0);
    assert(!ctrl.mcpEnabled);
    assert(ctrl.statusText() == "MCP: Disabled (Opt-In)");

    assert(ctrl.increment() == 1);
    assert(ctrl.increment() == 2);
    assert(ctrl.mcpSnapshot()["count"].integer == 2);

    ctrl.mcpSetProperty("count", JSONValue(42));
    assert(ctrl.count == 42);

    ctrl.reset();
    assert(ctrl.count == 0);

    ctrl.setMcpEnabled(true);
    assert(ctrl.mcpEnabled);
    assert(ctrl.statusText("/tmp/app.sock") == "MCP: Active (Unix Socket 0600 + Token)");
}
EOF

# 4. Write source/main.d
cat > "$TARGET_ABS/source/main.d" <<EOF
/// Entrypoint for ${APP_NAME}: desktop window + opt-in, token-authenticated Unix Socket MCP server.
module main;

import std.algorithm : canFind;
import std.stdio : stderr, writeln, writefln;

import controller : CounterController;
import slate.agent.builder : AgentBuilder, AgentHandle;
import slate.agent.declarative : McpStateRegistry;
import slate.log : installOtelStdLoggerBridge, slog;
import slate.mcp.adapter : McpServerHandle, startMcpUnixSocket;
import slate.mcp.server : McpServer;
import slate.mcp.transport.stdio : runStdio;
import slate.mcp.transport.unix_socket : runUnixSocketStdioBridge;
import slint;
import slint.codegen : Prop, SlintCallbacks, SlintProps;
import slint.png : encodePngRgba;
import slint.value : Value;

struct MainWindow
{
    ComponentInstance _instance;
    mixin SlintProps!(
        Prop!("counter", double),
        Prop!("mcpEnabled", bool),
        Prop!("mcpStatus", string)
    );
    mixin SlintCallbacks!("increment", "reset", "toggleMcp");
    alias _instance this;
}

void printMcpConfig(string sockPath = "", string token = "")
{
    if (sockPath.length > 0 && token.length > 0)
    {
        writefln(q"{
{
  "mcpServers": {
    "${APP_NAME}": {
      "command": "dub",
      "args": [
        "run",
        "-q",
        "--root=${TARGET_ABS}",
        "--",
        "--mcp-attach",
        "%s",
        "--mcp-token",
        "%s"
      ]
    }
  }
}
}", sockPath, token);
        return;
    }

    writeln(q"{
{
  "mcpServers": {
    "${APP_NAME}": {
      "command": "dub",
      "args": [
        "run",
        "-q",
        "--root=${TARGET_ABS}",
        "--config=native",
        "--",
        "--mcp"
      ],
      "env": {
        "LD_LIBRARY_PATH": "${BRIDGE_LIB_DIR}:${SLATE_LIB_DIR}",
        "SLINT_BACKEND": "software"
      }
    }
  }
}
}");
}

void main(string[] args)
{
    installOtelStdLoggerBridge("${APP_NAME}");

    // 1. Authenticated Unix socket client bridge mode: --mcp-attach <sock> --mcp-token <token>
    string attachSock = "";
    string attachToken = "";
    foreach (i, a; args)
    {
        if (a == "--mcp-attach" && i + 1 < args.length)
            attachSock = args[i + 1];
        if (a == "--mcp-token" && i + 1 < args.length)
            attachToken = args[i + 1];
    }
    if (attachSock.length > 0)
    {
        runUnixSocketStdioBridge(attachSock, attachToken);
        return;
    }

    if (args.canFind("--mcp-config"))
    {
        printMcpConfig();
        return;
    }

    // Opt-in by default: MCP is OFF until the user flips the UI switch or passes --enable-mcp
    bool startWithMcp = args.canFind("--enable-mcp");
    bool headlessMcp = args.canFind("--mcp");
    auto ctrl = new CounterController(0, startWithMcp);

    try
    {
        runApp(ctrl, headlessMcp, args);
    }
    catch (NativeUnavailable e)
    {
        if (headlessMcp)
        {
            auto registry = new McpStateRegistry("${APP_NAME}");
            registry.registerController(ctrl);
            auto handle = AgentBuilder.forWindow(null, registry).build();
            auto server = new McpServer(handle.engine(), "${APP_NAME}", "0.1.0");
            runStdio(server);
            return;
        }
        slog.info("Running in pure-D mode", "count", ctrl.count, "mcp_enabled", ctrl.mcpEnabled);
        ctrl.increment();
        slog.info("Incremented counter", "count", ctrl.count);
    }
}

private void runApp(CounterController ctrl, bool headlessMcp, string[] args)
{
    import slate.agent.slint_backend; // Registers Slint window wiring hook

    auto span = slog.span("app.startup", "app", "${APP_NAME}");

    auto result = loadFile("app.slint");
    foreach (d; result.diagnostics)
        stderr.writeln(d.toString());

    auto def = result.component("MainWindow");
    if (def is null)
    {
        slog.error("MainWindow component not found in app.slint");
        return;
    }

    auto inst = def.create();
    auto w = MainWindow(inst);

    auto registry = new McpStateRegistry("${APP_NAME}");
    registry.registerController(ctrl);

    AgentHandle mcpHandle = null;
    string activeSocketPath = "";

    void syncUi()
    {
        w.counter = cast(double) ctrl.count;
        w.mcpEnabled = ctrl.mcpEnabled;
        w.mcpStatus = ctrl.statusText(activeSocketPath);
    }

    void updateMcpServer(bool enabled)
    {
        ctrl.setMcpEnabled(enabled);
        if (enabled && mcpHandle is null)
        {
            mcpHandle = AgentBuilder.forWindow(inst, registry)
                .withName("${APP_NAME}")
                .startMcpUnixSocket();
            auto sh = cast(McpServerHandle) mcpHandle.serverHandles()[0];
            activeSocketPath = sh.localAddr().get("");
            string token = sh.authToken();
            slog.info("Opt-in MCP Unix socket enabled",
                "socket_path", activeSocketPath,
                "permissions", "0600");
            printMcpConfig(activeSocketPath, token);
        }
        else if (!enabled && mcpHandle !is null)
        {
            mcpHandle.stop();
            mcpHandle = null;
            activeSocketPath = "";
            slog.info("Opt-in MCP Unix socket disabled and unlinked");
        }
        syncUi();
    }

    w.onIncrement(() {
        auto s = slog.span("ui.increment");
        ctrl.increment();
        slog.info("Counter incremented", "count", ctrl.count);
        syncUi();
    });

    w.onReset(() {
        auto s = slog.span("ui.reset");
        ctrl.reset();
        slog.info("Counter reset", "count", ctrl.count);
        syncUi();
    });

    w.onToggleMcp((const(Value)[] cbArgs) {
        bool nextState = cbArgs.length > 0 ? cbArgs[0].boolean : !ctrl.mcpEnabled;
        updateMcpServer(nextState);
        return Value.nil();
    });

    syncUi();

    // Optional offscreen PNG snapshot mode: --shot [path.png]
    foreach (i, a; args)
    {
        if (a == "--shot")
        {
            string outPath = (i + 1 < args.length) ? args[i + 1] : "snapshot.png";
            auto shot = inst.snapshot();
            import std.file : write;
            write(outPath, encodePngRgba(shot.width, shot.height, shot.pixels));
            slog.info("Saved snapshot", "path", outPath, "width", shot.width, "height", shot.height);
            return;
        }
    }

    // Headless blocking MCP stdio mode (when spawned directly by an MCP client)
    if (headlessMcp)
    {
        auto handle = AgentBuilder.forWindow(inst, registry).withName("${APP_NAME}").build();
        auto server = new McpServer(handle.engine(), "${APP_NAME}", "0.1.0");
        runStdio(server);
        return;
    }

    // Interactive GUI mode: only start Unix socket if explicitly opted in (--enable-mcp)
    if (ctrl.mcpEnabled)
        updateMcpServer(true);

    scope (exit)
    {
        if (mcpHandle !is null)
            mcpHandle.stop();
    }

    w.run();
}
EOF

# 5. Write mcp_config.json
cat > "$TARGET_ABS/mcp_config.json" <<EOF
{
  "mcpServers": {
    "${APP_NAME}": {
      "command": "dub",
      "args": [
        "run",
        "-q",
        "--root=${TARGET_ABS}",
        "--config=native",
        "--",
        "--mcp"
      ],
      "env": {
        "LD_LIBRARY_PATH": "${BRIDGE_LIB_DIR}:${SLATE_LIB_DIR}",
        "SLINT_BACKEND": "software"
      }
    }
  }
}
EOF

# 6. Write .gitignore & README.md
cat > "$TARGET_ABS/.gitignore" <<EOF
.dub/
dub.selections.json
${APP_NAME}
${APP_NAME}-test-*
*.o
*.a
*.png
EOF

cat > "$TARGET_ABS/README.md" <<EOF
# ${APP_NAME}

Slate desktop application provisioned with a Counter, Increment/Reset buttons, and a live **Integrated MCP Switch**.

## How Integrated MCP Works

1. **Interactive Window Mode (\`dub run --config=native\`)**:
   - The embedded MCP server starts automatically in a background daemon thread when the **MCP: ON** switch is active.
   - Toggling the switch in the UI starts or stops the MCP server at runtime (\`AgentBuilder.forWindow(inst, registry).startMcpStdio()\` / \`mcpHandle.stop()\`).
   - Pass \`--no-mcp\` to start with the MCP switch initially turned off.
2. **Headless Agent Mode (\`--mcp\`)**:
   - Runs with \`SLINT_BACKEND=software\` and serves JSON-RPC 2.0 over \`stdin\`/\`stdout\` so any MCP client (Antigravity, Claude Desktop, Cursor) can call \`inspect_tree\`, \`click_element\`, \`get_state\`, \`set_property\`, \`invoke_action\`, and \`get_screenshot\`.

## Quick Commands

\`\`\`bash
# Run unit tests
dub test

# Launch native desktop window (with live MCP switch)
LD_LIBRARY_PATH="${BRIDGE_LIB_DIR}:${SLATE_LIB_DIR}" dub run --config=native

# Render an offscreen PNG snapshot of the window
LD_LIBRARY_PATH="${BRIDGE_LIB_DIR}:${SLATE_LIB_DIR}" SLINT_BACKEND=software dub run --config=native -- --shot preview.png

# Print the MCP client config JSON
dub run -- --mcp-config
\`\`\`

## MCP Client Configuration (\`mcp_config.json\`)

\`\`\`json
$(cat "$TARGET_ABS/mcp_config.json")
\`\`\`
EOF

echo "=================================================================="
echo " ✅ Provisioned new Slate project '${APP_NAME}' at:"
echo "    ${TARGET_ABS}"
echo "=================================================================="
echo ""
echo "Files created:"
echo "  - ${TARGET_ABS}/dub.json"
echo "  - ${TARGET_ABS}/app.slint           (Window + Counter + Buttons + MCP Switch)"
echo "  - ${TARGET_ABS}/source/controller.d (McpControllable CounterController + unittest)"
echo "  - ${TARGET_ABS}/source/main.d       (GUI + runtime MCP toggle + --mcp stdio mode)"
echo "  - ${TARGET_ABS}/mcp_config.json     (Ready-to-use MCP client config)"
echo "  - ${TARGET_ABS}/README.md"
echo ""
echo "📋 Use this MCP configuration in your MCP client (also saved to ${TARGET_ABS}/mcp_config.json):"
echo ""
cat "$TARGET_ABS/mcp_config.json"
echo ""
