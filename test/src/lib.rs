#[cfg(test)]
mod tests {
    use slate::core::task::TaskCancellation;
    use slate::core::theme::ThemeMode;
    use slate::demo::{describe_result, monte_carlo_pi_samples};
    use slate::extensions::platform::{parse_color_scheme, resolve_dark_mode};
    use slate::extensions::plugin::{Plugin, PluginError, PluginRegistry};
    use slate::utils::{format_bytes, format_number, Rgba};
    use slate::{AppBuilder, ComputeController};
    use std::any::Any;

    #[test]
    fn test_framework_init() {
        let app = AppBuilder::new("Test App").theme_mode(ThemeMode::Dark);
        assert!(app.is_dark());
        assert!(!AppBuilder::new("Light").theme_mode(ThemeMode::Light).is_dark());
        app.init();
        app.init(); // idempotent
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
        assert_eq!(Rgba::from_hex("ééé"), None);
    }

    #[test]
    fn test_pi_demo() {
        let pi = monte_carlo_pi_samples(1_000_000, &|| false, &|_| {}).unwrap();
        assert!((pi - std::f64::consts::PI).abs() < 0.01);
        assert_eq!(monte_carlo_pi_samples(1_000_000, &|| true, &|_| {}), None);
        assert_eq!(describe_result(None).0, "Cancelled");
    }

    #[test]
    fn test_theme_detection_parsing() {
        assert_eq!(parse_color_scheme("'prefer-dark'"), Some(true));
        assert_eq!(resolve_dark_mode(Some("Adwaita"), None, || None), Some(false));
        assert_eq!(resolve_dark_mode(None, None, || None), None);
    }

    #[test]
    fn test_controller_idle() {
        let c = ComputeController::new();
        assert!(!c.is_running());
        c.cancel();
    }

    struct P;
    impl Plugin for P {
        fn name(&self) -> &'static str {
            "p"
        }
        fn as_any(&self) -> &dyn Any {
            self
        }
    }

    #[test]
    fn test_plugin_registry_unique() {
        let mut r = PluginRegistry::new();
        r.register(P).unwrap();
        assert!(r.get_by_name("p").is_some());
        let err = r.register(P).unwrap_err();
        assert!(err.downcast_ref::<PluginError>().is_some());
    }
}
