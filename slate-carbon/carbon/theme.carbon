package Slate library "theme";

// Carbon definitions of Slate theme tokens mirroring ui/components/theme.slint
class Color {
    var r: i32;
    var g: i32;
    var b: i32;
    var a: i32;

    fn Rgb(r: i32, g: i32, b: i32) -> Color {
        return {.r = r, .g = g, .b = b, .a = 255};
    }

    fn Rgba(r: i32, g: i32, b: i32, a: i32) -> Color {
        return {.r = r, .g = g, .b = b, .a = a};
    }
}

// Brand & semantic palettes
fn AccentDefault() -> Color { return Color.Rgb(99, 102, 241); }     // Indigo-500
fn AccentHover() -> Color { return Color.Rgb(79, 70, 229); }        // Indigo-600
fn Success() -> Color { return Color.Rgb(34, 197, 94); }            // Green-500
fn Warning() -> Color { return Color.Rgb(234, 179, 8); }            // Yellow-500
fn Danger() -> Color { return Color.Rgb(239, 68, 68); }             // Red-500
