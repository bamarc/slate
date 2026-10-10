//! `slate-mcp` CLI helper and MCP client / proxy binary.
//!
//! Provides command-line remote control for Slate applications via Model Context Protocol:
//! - Component inspection (`inspect`)
//! - UI interaction (`click`, `type`)
//! - Visual snapshot capture (`screenshot`)
//! - Application state queries (`state`)
//! - MCP Server proxy bridge (`serve`)

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use base64::Engine;
use slate_mcp::client::{ClientError, ProcessMcpClient};

#[derive(Debug)]
struct CliConfig {
    app_bin: PathBuf,
    app_args: Vec<String>,
    timeout: Duration,
    json_output: bool,
    command: SubCommand,
}

#[derive(Debug)]
enum SubCommand {
    Inspect { root_id: Option<String> },
    Click {
        id: Option<String>,
        x: Option<f32>,
        y: Option<f32>,
        button: String,
        double: bool,
    },
    Type {
        text: String,
        target_id: Option<String>,
        clear: bool,
    },
    Screenshot {
        out_path: Option<PathBuf>,
    },
    State {
        query: Option<String>,
    },
    Tools,
    Resources,
    Read {
        uri: String,
    },
    Call {
        tool: String,
        args: serde_json::Value,
    },
    Serve,
    Help,
}

fn print_help() {
    println!(
        r#"slate-mcp - Model Context Protocol CLI & Remote Control for Slate Applications

USAGE:
    slate-mcp [GLOBAL_OPTIONS] <SUBCOMMAND> [SUBCOMMAND_OPTIONS]

SUBCOMMANDS:
    inspect [--root <ID>]            Inspect application UI tree and components
    click <ID>                       Click element by accessible ID
    click --x <X> --y <Y>            Click element by coordinates
    type <TEXT> [--target <ID>]      Type text into active or targeted input
    screenshot [--out <FILE.png>]    Capture window frame and optionally save PNG
    state [--query <KEY>]            Query runtime metrics and diagnostic state
    tools                            List all available MCP tools on the target
    resources                        List all available MCP resources
    read <URI>                       Read a specific MCP resource by URI
    call <TOOL> [JSON_ARGS]          Execute an arbitrary MCP tool
    serve                            Run stdio MCP proxy server to the application
    help, --help, -h                 Print this help documentation

GLOBAL OPTIONS:
    --app <PATH>         Path to Slate application binary (default: target/debug/slate-showcase)
    --app-arg <ARG>      Additional arguments passed to application (repeatable)
    --gui                Run with visual window (disables default --headless)
    --timeout <SECS>     Command timeout in seconds (default: 15)
    --json               Output raw JSON responses without formatting
    --help, -h           Show help

EXAMPLES:
    # Inspect UI tree
    slate-mcp inspect

    # Click increment button and capture screenshot
    slate-mcp click btn_increment
    slate-mcp screenshot --out /tmp/screen.png

    # Type search term into input field
    slate-mcp type "Hello Slate" --target search_box

    # Run as stdio MCP server for agent IDEs / tools:
    slate-mcp serve --app ./target/debug/slate-showcase
"#
    );
}

fn resolve_default_app() -> PathBuf {
    if let Ok(env_val) = env::var("SLATE_APP_BIN") {
        return PathBuf::from(env_val);
    }

    let candidates = [
        "target/debug/slate-showcase",
        "target/release/slate-showcase",
        "../target/debug/slate-showcase",
        "../target/release/slate-showcase",
    ];

    for c in &candidates {
        let p = PathBuf::from(c);
        if p.exists() {
            return p;
        }
    }

    if let Ok(current_exe) = env::current_exe() {
        if let Some(parent) = current_exe.parent() {
            let sibling = parent.join("slate-showcase");
            if sibling.exists() {
                return sibling;
            }
        }
    }

    PathBuf::from("target/debug/slate-showcase")
}

fn parse_cli_args() -> Result<CliConfig, String> {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() {
        return Ok(CliConfig {
            app_bin: resolve_default_app(),
            app_args: Vec::new(),
            timeout: Duration::from_secs(15),
            json_output: false,
            command: SubCommand::Help,
        });
    }

    let mut app_bin: Option<PathBuf> = None;
    let mut app_args: Vec<String> = Vec::new();
    let mut timeout = Duration::from_secs(15);
    let mut json_output = false;
    let mut is_gui = false;

    let mut i = 0;
    let mut subcommand_idx = None;

    while i < args.len() {
        match args[i].as_str() {
            "--app" => {
                i += 1;
                if i >= args.len() {
                    return Err("--app requires a path argument".to_string());
                }
                app_bin = Some(PathBuf::from(&args[i]));
            }
            "--app-arg" => {
                i += 1;
                if i >= args.len() {
                    return Err("--app-arg requires an argument".to_string());
                }
                app_args.push(args[i].clone());
            }
            "--timeout" => {
                i += 1;
                if i >= args.len() {
                    return Err("--timeout requires seconds argument".to_string());
                }
                let secs: u64 = args[i]
                    .parse()
                    .map_err(|_| format!("Invalid timeout integer: {}", args[i]))?;
                timeout = Duration::from_secs(secs);
            }
            "--json" => {
                json_output = true;
            }
            "--gui" => {
                is_gui = true;
            }
            "-h" | "--help" | "help" => {
                return Ok(CliConfig {
                    app_bin: resolve_default_app(),
                    app_args: Vec::new(),
                    timeout,
                    json_output,
                    command: SubCommand::Help,
                });
            }
            cmd if !cmd.starts_with('-') => {
                subcommand_idx = Some(i);
                break;
            }
            unknown => {
                return Err(format!("Unknown option: {}", unknown));
            }
        }
        i += 1;
    }

    let sub_idx = match subcommand_idx {
        Some(idx) => idx,
        None => {
            return Ok(CliConfig {
                app_bin: app_bin.unwrap_or_else(resolve_default_app),
                app_args,
                timeout,
                json_output,
                command: SubCommand::Help,
            });
        }
    };

    let sub_name = &args[sub_idx];
    let sub_args = &args[sub_idx + 1..];

    let command = match sub_name.as_str() {
        "inspect" => {
            let mut root_id = None;
            let mut j = 0;
            while j < sub_args.len() {
                if sub_args[j] == "--root" && j + 1 < sub_args.len() {
                    root_id = Some(sub_args[j + 1].clone());
                    j += 1;
                }
                j += 1;
            }
            SubCommand::Inspect { root_id }
        }
        "click" => {
            let mut id = None;
            let mut x = None;
            let mut y = None;
            let mut button = "left".to_string();
            let mut double = false;
            let mut j = 0;
            while j < sub_args.len() {
                match sub_args[j].as_str() {
                    "--x" if j + 1 < sub_args.len() => {
                        x = sub_args[j + 1].parse().ok();
                        j += 1;
                    }
                    "--y" if j + 1 < sub_args.len() => {
                        y = sub_args[j + 1].parse().ok();
                        j += 1;
                    }
                    "--button" if j + 1 < sub_args.len() => {
                        button = sub_args[j + 1].clone();
                        j += 1;
                    }
                    "--double" => {
                        double = true;
                    }
                    val if !val.starts_with('-') && id.is_none() => {
                        id = Some(val.to_string());
                    }
                    _ => {}
                }
                j += 1;
            }
            if id.is_none() && (x.is_none() || y.is_none()) {
                return Err("click requires element ID or both --x and --y coordinates".to_string());
            }
            SubCommand::Click {
                id,
                x,
                y,
                button,
                double,
            }
        }
        "type" | "send-keys" => {
            if sub_args.is_empty() {
                return Err("type requires text argument".to_string());
            }
            let mut text = String::new();
            let mut target_id = None;
            let mut clear = false;
            let mut j = 0;
            let mut found_text = false;

            while j < sub_args.len() {
                match sub_args[j].as_str() {
                    "--target" if j + 1 < sub_args.len() => {
                        target_id = Some(sub_args[j + 1].clone());
                        j += 1;
                    }
                    "--clear" => {
                        clear = true;
                    }
                    val if !val.starts_with('-') && !found_text => {
                        text = val.to_string();
                        found_text = true;
                    }
                    _ => {}
                }
                j += 1;
            }

            if !found_text {
                return Err("type requires text argument".to_string());
            }
            SubCommand::Type {
                text,
                target_id,
                clear,
            }
        }
        "screenshot" => {
            let mut out_path = None;
            let mut j = 0;
            while j < sub_args.len() {
                if sub_args[j] == "--out" && j + 1 < sub_args.len() {
                    out_path = Some(PathBuf::from(&sub_args[j + 1]));
                    j += 1;
                }
                j += 1;
            }
            SubCommand::Screenshot { out_path }
        }
        "state" => {
            let mut query = None;
            let mut j = 0;
            while j < sub_args.len() {
                if sub_args[j] == "--query" && j + 1 < sub_args.len() {
                    query = Some(sub_args[j + 1].clone());
                    j += 1;
                } else if !sub_args[j].starts_with('-') && query.is_none() {
                    query = Some(sub_args[j].clone());
                }
                j += 1;
            }
            SubCommand::State { query }
        }
        "tools" => SubCommand::Tools,
        "resources" => SubCommand::Resources,
        "read" => {
            if sub_args.is_empty() {
                return Err("read requires resource URI".to_string());
            }
            SubCommand::Read {
                uri: sub_args[0].clone(),
            }
        }
        "call" => {
            if sub_args.is_empty() {
                return Err("call requires tool name".to_string());
            }
            let tool = sub_args[0].clone();
            let args_json = if sub_args.len() > 1 {
                serde_json::from_str(&sub_args[1])
                    .map_err(|e| format!("Invalid JSON arguments: {}", e))?
            } else {
                serde_json::json!({})
            };
            SubCommand::Call {
                tool,
                args: args_json,
            }
        }
        "serve" => SubCommand::Serve,
        "help" => SubCommand::Help,
        other => return Err(format!("Unknown subcommand '{}'", other)),
    };

    let resolved_app = app_bin.unwrap_or_else(resolve_default_app);

    // Guarantee default --headless and --agent flags if not specified
    let mut final_app_args = app_args;
    if !final_app_args.iter().any(|a| a == "--agent" || a == "--mcp") {
        final_app_args.push("--agent".to_string());
    }
    if !is_gui && !final_app_args.iter().any(|a| a == "--headless") {
        final_app_args.push("--headless".to_string());
    }

    Ok(CliConfig {
        app_bin: resolved_app,
        app_args: final_app_args,
        timeout,
        json_output,
        command,
    })
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = match parse_cli_args() {
        Ok(cfg) => cfg,
        Err(err) => {
            eprintln!("Error: {}", err);
            eprintln!("Run 'slate-mcp --help' for usage.");
            std::process::exit(1);
        }
    };

    if let SubCommand::Help = config.command {
        print_help();
        return Ok(());
    }

    // Verify binary existence
    if !config.app_bin.exists() {
        eprintln!(
            "Error: Target application binary not found at '{}'.\n\
             Ensure the binary is built (e.g. 'cargo build --example slate-showcase')\n\
             or specify the binary with '--app <path>'.",
            config.app_bin.display()
        );
        std::process::exit(1);
    }

    let bin_path_str = config.app_bin.to_string_lossy().to_string();
    let app_args_ref: Vec<&str> = config.app_args.iter().map(|s| s.as_str()).collect();

    // Special case: `serve` acts as an stdio MCP proxy bridge
    if let SubCommand::Serve = config.command {
        run_stdio_proxy(&bin_path_str, &app_args_ref).await?;
        return Ok(());
    }

    // Launch application child process with MCP stdio pipe
    let mut client = ProcessMcpClient::spawn(&bin_path_str, &app_args_ref)
        .map_err(|e| format!("Failed to spawn child process: {}", e))?;
    client.set_timeout(config.timeout);

    // Initialize MCP handshake
    if let Err(e) = client.initialize("slate-cli", env!("CARGO_PKG_VERSION")).await {
        eprintln!("Failed to initialize MCP handshake with application: {}", e);
        let _ = client.kill().await;
        std::process::exit(1);
    }

    let result = match config.command {
        SubCommand::Inspect { root_id } => {
            let res = if let Some(root) = root_id {
                client
                    .call_tool("inspect_tree", serde_json::json!({ "root_id": root }))
                    .await
            } else {
                client.inspect_tree().await
            };
            handle_output(res, config.json_output)
        }
        SubCommand::Click {
            id,
            x,
            y,
            button,
            double,
        } => {
            let mut args = serde_json::Map::new();
            if let Some(id_val) = id {
                args.insert("id".to_string(), serde_json::json!(id_val));
            }
            if let (Some(x_val), Some(y_val)) = (x, y) {
                args.insert("x".to_string(), serde_json::json!(x_val));
                args.insert("y".to_string(), serde_json::json!(y_val));
            }
            args.insert("button".to_string(), serde_json::json!(button));
            args.insert(
                "click_count".to_string(),
                serde_json::json!(if double { 2 } else { 1 }),
            );

            let res = client
                .call_tool("click_element", serde_json::Value::Object(args))
                .await;
            handle_output(res, config.json_output)
        }
        SubCommand::Type {
            text,
            target_id,
            clear,
        } => {
            let mut args = serde_json::Map::new();
            args.insert("text".to_string(), serde_json::json!(text));
            if let Some(id_val) = target_id {
                args.insert("element_id".to_string(), serde_json::json!(id_val));
            }
            if clear {
                args.insert("clear_first".to_string(), serde_json::json!(true));
            }

            let res = client
                .call_tool("send_keys", serde_json::Value::Object(args))
                .await;
            handle_output(res, config.json_output)
        }
        SubCommand::Screenshot { out_path } => {
            let res = client.get_screenshot().await;
            match res {
                Ok(val) => {
                    if let Some(out) = out_path {
                        save_screenshot(&val, &out)?;
                        println!("Screenshot saved successfully to {}", out.display());
                    } else if config.json_output {
                        println!("{}", serde_json::to_string_pretty(&val)?);
                    } else {
                        // Extract base64 summary
                        if let Some(data) = extract_image_data(&val) {
                            println!(
                                "Screenshot acquired (PNG base64 length: {} characters). Use '--out <file.png>' to save.",
                                data.len()
                            );
                        } else {
                            println!("{}", serde_json::to_string_pretty(&val)?);
                        }
                    }
                    Ok(())
                }
                Err(e) => {
                    eprintln!("Error capturing screenshot: {}", e);
                    Err(Box::new(e) as Box<dyn std::error::Error>)
                }
            }
        }
        SubCommand::State { query } => {
            let res = client.get_state(query.as_deref()).await;
            handle_output(res, config.json_output)
        }
        SubCommand::Tools => {
            let res = client.list_tools().await;
            handle_output(res, config.json_output)
        }
        SubCommand::Resources => {
            let res = client.list_resources().await;
            handle_output(res, config.json_output)
        }
        SubCommand::Read { uri } => {
            let res = client.read_resource(&uri).await;
            handle_output(res, config.json_output)
        }
        SubCommand::Call { tool, args } => {
            let res = client.call_tool(&tool, args).await;
            handle_output(res, config.json_output)
        }
        SubCommand::Serve | SubCommand::Help => Ok(()),
    };

    // Gracefully shut down child process
    let _ = client.kill().await;

    if let Err(e) = result {
        eprintln!("{}", e);
        std::process::exit(1);
    }

    Ok(())
}

fn handle_output(
    res: Result<serde_json::Value, ClientError>,
    json_output: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    match res {
        Ok(val) => {
            if json_output {
                println!("{}", serde_json::to_string_pretty(&val)?);
            } else if let Some(content) = val.get("content").and_then(|c| c.as_array()) {
                for item in content {
                    if let Some(text) = item.get("text").and_then(|t| t.as_str()) {
                        // Attempt to parse embedded JSON text for prettier printing
                        if let Ok(nested) = serde_json::from_str::<serde_json::Value>(text) {
                            println!("{}", serde_json::to_string_pretty(&nested)?);
                        } else {
                            println!("{}", text);
                        }
                    } else {
                        println!("{}", serde_json::to_string_pretty(item)?);
                    }
                }
            } else {
                println!("{}", serde_json::to_string_pretty(&val)?);
            }
            Ok(())
        }
        Err(e) => {
            eprintln!("Error executing command: {}", e);
            Err(Box::new(e))
        }
    }
}

fn extract_image_data(val: &serde_json::Value) -> Option<&str> {
    val.get("content")
        .and_then(|c| c.as_array())
        .and_then(|arr| arr.iter().find(|i| i.get("type").and_then(|t| t.as_str()) == Some("image")))
        .and_then(|i| i.get("data").and_then(|d| d.as_str()))
}

fn save_screenshot(val: &serde_json::Value, out_path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let b64 = extract_image_data(val).ok_or("No image data found in response")?;
    let bytes = base64::prelude::BASE64_STANDARD
        .decode(b64)
        .map_err(|e| format!("Base64 decoding failed: {}", e))?;

    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }

    fs::write(out_path, bytes)?;
    Ok(())
}

/// Runs a transparent stdio proxy forwarding JSON-RPC between parent stdio and the child Slate process.
async fn run_stdio_proxy(cmd: &str, args: &[&str]) -> Result<(), Box<dyn std::error::Error>> {
    let mut child = tokio::process::Command::new(cmd)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;

    let mut child_stdin = child.stdin.take().ok_or("Failed to open child stdin")?;
    let mut child_stdout = child.stdout.take().ok_or("Failed to open child stdout")?;

    let mut stdin_reader = tokio::io::BufReader::new(tokio::io::stdin());
    let mut stdout_writer = tokio::io::stdout();

    let to_child = tokio::spawn(async move {
        tokio::io::copy(&mut stdin_reader, &mut child_stdin).await
    });

    let from_child = tokio::spawn(async move {
        tokio::io::copy(&mut child_stdout, &mut stdout_writer).await
    });

    tokio::select! {
        _ = to_child => {},
        _ = from_child => {},
        status = child.wait() => {
            let code = status?.code().unwrap_or(0);
            std::process::exit(code);
        }
    }

    let _ = child.kill().await;
    Ok(())
}
