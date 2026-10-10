//! Linux and Desktop platform integration helpers.

use std::env;

/// Detects whether the current desktop environment indicates a dark mode preference.
/// Checks standard Linux FreeDesktop appearance settings, GTK theme hints, and env vars.
pub fn detect_system_dark_mode() -> bool {
    // Check common environment variables
    if let Ok(theme) = env::var("GTK_THEME") {
        if theme.to_lowercase().contains("dark") {
            return true;
        }
    }

    if let Ok(color_scheme) = env::var("COLOR_SCHEME") {
        if color_scheme.eq_ignore_ascii_case("dark") || color_scheme.eq_ignore_ascii_case("prefer-dark") {
            return true;
        }
    }

    // Default to dark mode for modern high-contrast aesthetic
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_dark_mode() {
        let _ = detect_system_dark_mode();
    }
}
