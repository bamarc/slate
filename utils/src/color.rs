//! Color utilities for themes and palette manipulation.

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Rgba {
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }

    /// Parse hex color like "#RRGGBB" or "#RRGGBBAA"
    pub fn from_hex(hex: &str) -> Option<Self> {
        let hex = hex.strip_prefix('#').unwrap_or(hex);
        // Byte slicing below is only valid for ASCII input.
        if !hex.is_ascii() {
            return None;
        }
        match hex.len() {
            6 => {
                let r = u8::from_str_radix(&hex[0..2], 16).ok()? as f32 / 255.0;
                let g = u8::from_str_radix(&hex[2..4], 16).ok()? as f32 / 255.0;
                let b = u8::from_str_radix(&hex[4..6], 16).ok()? as f32 / 255.0;
                Some(Self::new(r, g, b, 1.0))
            }
            8 => {
                let r = u8::from_str_radix(&hex[0..2], 16).ok()? as f32 / 255.0;
                let g = u8::from_str_radix(&hex[2..4], 16).ok()? as f32 / 255.0;
                let b = u8::from_str_radix(&hex[4..6], 16).ok()? as f32 / 255.0;
                let a = u8::from_str_radix(&hex[6..8], 16).ok()? as f32 / 255.0;
                Some(Self::new(r, g, b, a))
            }
            _ => None,
        }
    }

    /// Calculate relative luminance (W3C formula)
    pub fn luminance(&self) -> f32 {
        let to_linear = |c: f32| -> f32 {
            if c <= 0.03928 {
                c / 12.92
            } else {
                ((c + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * to_linear(self.r) + 0.7152 * to_linear(self.g) + 0.0722 * to_linear(self.b)
    }

    /// Calculate contrast ratio against another color (1.0 to 21.0)
    pub fn contrast_ratio(&self, other: &Self) -> f32 {
        let l1 = self.luminance();
        let l2 = other.luminance();
        let lighter = l1.max(l2);
        let darker = l1.min(l2);
        (lighter + 0.05) / (darker + 0.05)
    }

    /// Lighten or darken color by factor
    pub fn adjust_brightness(&self, factor: f32) -> Self {
        Self {
            r: (self.r * factor).clamp(0.0, 1.0),
            g: (self.g * factor).clamp(0.0, 1.0),
            b: (self.b * factor).clamp(0.0, 1.0),
            a: self.a,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hex_parsing() {
        let white = Rgba::from_hex("#ffffff").unwrap();
        assert_eq!(white, Rgba::new(1.0, 1.0, 1.0, 1.0));

        let black = Rgba::from_hex("#000000").unwrap();
        assert_eq!(black, Rgba::new(0.0, 0.0, 0.0, 1.0));
        assert!(white.contrast_ratio(&black) >= 20.0);
    }

    #[test]
    fn test_hex_rejects_non_ascii_and_bad_input() {
        // 6 bytes but multi-byte chars: must not panic.
        assert_eq!(Rgba::from_hex("ééé"), None);
        assert_eq!(Rgba::from_hex("#ff00é"), None);
        assert_eq!(Rgba::from_hex("#12345"), None);
        assert_eq!(Rgba::from_hex("#gggggg"), None);
        assert!(Rgba::from_hex("#ff000080").is_some());
    }
}
