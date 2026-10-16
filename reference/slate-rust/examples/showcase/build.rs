use std::path::PathBuf;

fn main() {
    let mut config = slint_build::CompilerConfiguration::new();
    config = config.with_include_paths(vec![
        PathBuf::from("../../../ui"),
        PathBuf::from("../../../ui/components"),
        PathBuf::from("../../../ui/layouts"),
    ]).with_debug_info(true);

    slint_build::compile_with_config("ui/app.slint", config).expect("Failed to compile Showcase UI");
}
