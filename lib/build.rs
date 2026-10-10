use std::path::PathBuf;

fn main() {
    let mut config = slint_build::CompilerConfiguration::new();
    config = config.with_include_paths(vec![
        PathBuf::from("../ui"),
        PathBuf::from("../ui/components"),
        PathBuf::from("../ui/layouts"),
    ]);

    slint_build::compile_with_config("../ui/index.slint", config).expect("Failed to compile Slate UI components");
}
