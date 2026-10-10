//! Theme controller and palette modes.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ThemeMode {
    #[default]
    System,
    Light,
    Dark,
}

impl ThemeMode {
    /// Resolves whether the dark palette applies, given the system preference.
    pub fn is_dark(self, system_prefers_dark: bool) -> bool {
        match self {
            Self::Dark => true,
            Self::Light => false,
            Self::System => system_prefers_dark,
        }
    }

    /// Returns the explicit mode that flips the currently resolved appearance.
    pub fn toggle(self, system_prefers_dark: bool) -> Self {
        if self.is_dark(system_prefers_dark) {
            Self::Light
        } else {
            Self::Dark
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_theme_mode() {
        assert!(!ThemeMode::Light.is_dark(true));
        assert!(ThemeMode::Dark.is_dark(false));
        assert!(ThemeMode::System.is_dark(true));
        assert!(!ThemeMode::System.is_dark(false));
    }

    #[test]
    fn test_toggle() {
        assert_eq!(ThemeMode::System.toggle(true), ThemeMode::Light);
        assert_eq!(ThemeMode::System.toggle(false), ThemeMode::Dark);
        assert_eq!(ThemeMode::Dark.toggle(false), ThemeMode::Light);
        assert_eq!(ThemeMode::Light.toggle(true), ThemeMode::Dark);
    }
}
