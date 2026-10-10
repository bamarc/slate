//! Slate: Modern, declarative, beautiful desktop UI framework.
//!
//! Inspired by Kirigami and Libadwaita, powered by Slint and Rust.

slint::include_modules!();

pub use slate_core as core;
pub use slate_extensions as extensions;
pub use slate_utils as utils;
pub use slint;

pub mod controller;
pub mod demo;

pub use controller::ComputeController;

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

    /// Application title.
    pub fn title(&self) -> &str {
        &self.title
    }

    /// Resolves the configured mode against the system preference.
    /// Only queries the system when the mode is `System`.
    pub fn is_dark(&self) -> bool {
        match self.theme_mode {
            ThemeMode::System => self
                .theme_mode
                .is_dark(slate_extensions::platform::detect_system_dark_mode()),
            mode => mode.is_dark(false),
        }
    }

    /// Initializes the logger (idempotent) and logs the resolved theme.
    /// Apply [`AppBuilder::is_dark`] to the generated `SlateTheme` global.
    pub fn init(&self) {
        init();
        log::info!(
            "Initializing Slate UI framework: '{}' (dark theme: {})",
            self.title,
            self.is_dark()
        );
    }
}

/// Convenience initialization function
pub fn init() {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).try_init();
}
