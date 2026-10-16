use std::path::PathBuf;
use std::{env, fs};

/// Slint only generates Rust code for exported Window components, globals,
/// structs and enums of the *main* entry file. Compiling `ui/index.slint` directly
/// would make every re-exported widget warn "doesn't inherit Window" on each build,
/// so the library compiles a small generated entry that re-exports only the
/// items that produce Rust code. Widgets are consumed from `.slint` via `ui/index.slint`.
const ENTRY: &str = r#"export { SlateTheme } from "components/theme.slint";
export { SlateButtonVariant, SlateButtonSize } from "components/button.slint";
export { SlateTableRow } from "components/table.slint";
export { SlateWindow } from "layouts/window.slint";
export { NavItem } from "layouts/navigation_split_view.slint";
"#;

fn main() {
    let ui_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../ui");
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let entry = out_dir.join("slate_entry.slint");
    fs::write(&entry, ENTRY).expect("Failed to write Slate entry file");

    let config = slint_build::CompilerConfiguration::new()
        .with_include_paths(vec![
            ui_dir.clone(),
            ui_dir.join("components"),
            ui_dir.join("layouts"),
        ])
        .with_debug_info(true);

    slint_build::compile_with_config(&entry, config).expect("Failed to compile Slate UI components");
    println!("cargo:rustc-env=SLINT_INCLUDE_PATH={}", ui_dir.parent().unwrap().display());
    println!("cargo:rerun-if-changed=../../ui");
}
