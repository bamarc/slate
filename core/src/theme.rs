//! Theme controller and palette modes.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ThemeMode {
    #[default]
    System,
    Light,
    Dark,
}

impl ThemeMode {
    pub fn is_dark(&self, system_prefers_dark: bool) -> bool {
        match self {
            Self::Dark => true,
            Self::Light => false,
            Self::System => system_prefers_dark,
        }
    }

    pub fn toggle(&self, system_prefers_dark: bool) -> Self {
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
        assert_eq!(ThemeMode::Light.is_dark(true), false);
        assert_eq!(ThemeMode::Dark.is_dark(false), true);
        assert_eq!(ThemeMode::System.is_dark(true), true);
        assert_eq!(ThemeMode::System.is_dark(false), false);
    }
}
