package Showcase library "main";

import Slate library "ui";
import Slate library "theme";

fn Main() -> i32 {
    // 1. Initialize Slate App via Carbon AppBuilder
    var builder: Slate.AppBuilder = Slate.AppBuilder.Create("Slate Showcase (Carbon)");
    builder.WithThemeMode(Slate.ThemeMode.Dark);
    builder.Init();

    // 2. Verified active mode
    var is_dark: bool = builder.IsDark();
    if (is_dark) {
        // Dark theme initialized
    }

    return 0;
}
