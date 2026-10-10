//! Slate: Modern, declarative, beautiful desktop UI framework.
//!
//! Inspired by Kirigami and Libadwaita, powered by Slint and Rust.

slint::include_modules!();

pub use slate_core as core;
pub use slate_extensions as extensions;
pub use slate_utils as utils;
pub use slint;

use slate_core::theme::ThemeMode;

/// High-level application configuration builder
pub struct AppBuilder {
    title: String,
    theme_mode: ThemeMode,
}

impl AppBuilder {
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            theme_mode: ThemeMode::System,
        }
    }

    /// Set initial theme mode (System, Light, Dark)
    pub fn theme_mode(mut self, mode: ThemeMode) -> Self {
        self.theme_mode = mode;
        self
    }

    /// Returns the resolved theme mode given system preferences
    pub fn is_dark(&self) -> bool {
        let system_dark = slate_extensions::platform::detect_system_dark_mode();
        self.theme_mode.is_dark(system_dark)
    }

    /// Initialize the framework logger and theme
    pub fn init(&self) {
        let _ = env_logger::try_init();
        log::info!("Initializing Slate UI framework: '{}'", self.title);
    }
}

/// Convenience initialization function
pub fn init() {
    let _ = env_logger::try_init();
}
