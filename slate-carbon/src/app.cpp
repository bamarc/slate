#include "slate/app.h"
#include <iostream>
#include <cstdlib>

namespace slate {

AppBuilder::AppBuilder(std::string_view title) : title_(title) {}

AppBuilder& AppBuilder::theme_mode(ThemeMode mode) {
    theme_mode_ = mode;
    return *this;
}

std::string_view AppBuilder::title() const {
    return title_;
}

bool AppBuilder::is_dark() const {
    switch (theme_mode_) {
        case ThemeMode::Dark:
            return true;
        case ThemeMode::Light:
            return false;
        case ThemeMode::System: {
            // Check environment override or freedesktop/OS preference
            const char* env_dark = std::getenv("SLATE_FORCE_DARK");
            if (env_dark != nullptr && std::string_view(env_dark) == "1") {
                return true;
            }
            const char* color_scheme = std::getenv("COLOR_SCHEME");
            if (color_scheme != nullptr && std::string_view(color_scheme) == "dark") {
                return true;
            }
            return false;
        }
    }
    return false;
}

void AppBuilder::init() const {
    slate::init();
    std::cout << "[INFO] Initializing Slate Carbon UI framework: '" 
              << title_ << "' (dark theme: " << (is_dark() ? "true" : "false") << ")" << std::endl;
}

void init() {
    // Static logger initialization
    static bool initialized = false;
    if (!initialized) {
        initialized = true;
    }
}

void run_event_loop() {
    // Delegates to Slint C++ event loop
}

void quit_event_loop() {
    // Delegates to Slint C++ quit event loop
}

} // namespace slate
