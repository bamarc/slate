pub mod types;
pub mod client;
pub mod harness;
pub mod tier1_feature_coverage;
pub mod tier2_boundary_corner;
pub mod tier3_cross_feature;
pub mod tier4_showcase_workloads;
pub mod runner;

#[cfg(test)]
mod tests {
    use slate::core::task::TaskCancellation;
    use slate::core::theme::ThemeMode;
    use slate::utils::{format_bytes, format_number, Rgba};
    use slate::AppBuilder;

    #[test]
    fn test_framework_init() {
        let app = AppBuilder::new("Test App").theme_mode(ThemeMode::Dark);
        assert!(app.is_dark());
    }

    #[test]
    fn test_task_cancellation() {
        let handle = TaskCancellation::new();
        assert!(!handle.is_cancelled());
        handle.cancel();
        assert!(handle.is_cancelled());
    }

    #[test]
    fn test_utils() {
        assert_eq!(format_bytes(1024), "1.0 KiB");
        assert_eq!(format_number(1_000_000), "1,000,000");
        let col = Rgba::from_hex("#3b82f6").unwrap();
        assert!(col.r > 0.0);
    }
}
