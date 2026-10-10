//! Linux and Desktop platform integration helpers.

use std::env;
use std::process::Command;

/// Interprets a `GTK_THEME` value (e.g. `Adwaita:dark`). A set theme without
/// "dark" is treated as light.
pub fn parse_gtk_theme(value: &str) -> Option<bool> {
    let v = value.trim();
    if v.is_empty() {
        None
    } else {
        Some(v.to_lowercase().contains("dark"))
    }
}

/// Interprets a color-scheme value such as `dark`, `prefer-dark`, `'default'`
/// (gsettings output is quoted). Returns `None` when unrecognised.
pub fn parse_color_scheme(value: &str) -> Option<bool> {
    let v = value.trim().trim_matches(|c| c == '\'' || c == '"').to_lowercase();
    match v.as_str() {
        "dark" | "prefer-dark" => Some(true),
        "light" | "prefer-light" | "default" => Some(false),
        _ => None,
    }
}

/// Resolves the preference from the three sources in priority order:
/// `GTK_THEME`, `COLOR_SCHEME`, then the lazily evaluated gsettings query.
pub fn resolve_dark_mode(
    gtk_theme: Option<&str>,
    color_scheme: Option<&str>,
    gsettings: impl FnOnce() -> Option<String>,
) -> Option<bool> {
    gtk_theme
        .and_then(parse_gtk_theme)
        .or_else(|| color_scheme.and_then(parse_color_scheme))
        .or_else(|| gsettings().as_deref().and_then(parse_color_scheme))
}

fn query_gsettings() -> Option<String> {
    let out = Command::new("gsettings")
        .args(["get", "org.gnome.desktop.interface", "color-scheme"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8(out.stdout).ok()
}

/// Detects the system appearance, or `None` if it cannot be determined.
pub fn detect_system_dark_mode_opt() -> Option<bool> {
    let gtk = env::var("GTK_THEME").ok();
    let scheme = env::var("COLOR_SCHEME").ok();
    resolve_dark_mode(gtk.as_deref(), scheme.as_deref(), query_gsettings)
}

/// Whether the desktop prefers a dark appearance.
///
/// Checks `GTK_THEME`, `COLOR_SCHEME`, then GNOME's `color-scheme` gsetting.
/// If nothing can be detected, defaults to **dark** (the framework's
/// default aesthetic).
pub fn detect_system_dark_mode() -> bool {
    detect_system_dark_mode_opt().unwrap_or(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_gtk_theme() {
        assert_eq!(parse_gtk_theme("Adwaita:dark"), Some(true));
        assert_eq!(parse_gtk_theme("Adwaita"), Some(false));
        assert_eq!(parse_gtk_theme("  "), None);
    }

    #[test]
    fn parses_color_scheme() {
        assert_eq!(parse_color_scheme("'prefer-dark'\n"), Some(true));
        assert_eq!(parse_color_scheme("dark"), Some(true));
        assert_eq!(parse_color_scheme("'default'"), Some(false));
        assert_eq!(parse_color_scheme("PREFER-LIGHT"), Some(false));
        assert_eq!(parse_color_scheme("weird"), None);
    }

    #[test]
    fn resolution_priority() {
        let never = || -> Option<String> { panic!("must not be queried") };
        assert_eq!(resolve_dark_mode(Some("X:dark"), Some("light"), never), Some(true));
        assert_eq!(resolve_dark_mode(None, Some("light"), never), Some(false));
        assert_eq!(resolve_dark_mode(None, None, || Some("'prefer-dark'".into())), Some(true));
        assert_eq!(resolve_dark_mode(None, Some("bogus"), || Some("'default'".into())), Some(false));
        assert_eq!(resolve_dark_mode(None, None, || None), None);
    }

    #[test]
    fn detection_does_not_panic() {
        let _ = detect_system_dark_mode();
    }
}
