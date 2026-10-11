package Slate library "ui";

// Carbon imports C++ declarations directly via zero-overhead Clang interop
import Cpp library "slate/app.h";

// Idiomatic Carbon ThemeMode enum wrapping C++ slate::ThemeMode
choice ThemeMode {
    System,
    Light,
    Dark
}

// Idiomatic Carbon AppBuilder class managing desktop application lifecycle
class AppBuilder {
    var title: String;
    var mode: ThemeMode;

    fn Create(title: String) -> AppBuilder {
        return {.title = title, .mode = ThemeMode.System};
    }

    fn WithThemeMode[addr self: Self*](mode: ThemeMode) -> Self* {
        self->mode = mode;
        return self;
    }

    fn GetTitle[self: Self]() -> String {
        return self.title;
    }

    fn IsDark[self: Self]() -> bool {
        match (self.mode) {
            case ThemeMode.Dark => { return true; }
            case ThemeMode.Light => { return false; }
            case ThemeMode.System => {
                // Resolves via C++ platform integration bridge
                var cpp_builder: Cpp.slate.AppBuilder = Cpp.slate.AppBuilder(self.title);
                return cpp_builder.is_dark();
            }
        }
    }

    fn Init[self: Self]() {
        var cpp_builder: Cpp.slate.AppBuilder = Cpp.slate.AppBuilder(self.title);
        if (self.mode == ThemeMode.Dark) {
            cpp_builder.theme_mode(Cpp.slate.ThemeMode.Dark);
        } else if (self.mode == ThemeMode.Light) {
            cpp_builder.theme_mode(Cpp.slate.ThemeMode.Light);
        }
        cpp_builder.init();
    }
}
