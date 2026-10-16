//! Slate Showcase Application CLI entrypoint

fn main() -> Result<(), Box<dyn std::error::Error>> {
    slate_gallery::run_from_cli()
}
