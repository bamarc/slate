use slate_tests::runner::run_e2e_tests;
use std::env;

#[tokio::main]
async fn main() {
    let args: Vec<String> = env::args().collect();
    let mut selected_tier = None;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--tier" => {
                if i + 1 < args.len() {
                    if let Ok(t) = args[i + 1].parse::<u32>() {
                        selected_tier = Some(t);
                    }
                    i += 1;
                }
            }
            "--all" => {
                selected_tier = None;
            }
            "-h" | "--help" => {
                println!("Usage: e2e_runner [OPTIONS]");
                println!();
                println!("Options:");
                println!("  --tier <1-4>   Run tests for a specific tier only");
                println!("  --all          Run all tiers 1-4 (default)");
                println!("  -h, --help     Show this help message");
                return;
            }
            _ => {}
        }
        i += 1;
    }

    let (_reports, all_passed) = run_e2e_tests(selected_tier).await;
    if !all_passed {
        std::process::exit(1);
    }
}
