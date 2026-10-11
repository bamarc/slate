#pragma once

#include <string>
#include <memory>
#include <string_view>

namespace slate {

enum class ThemeMode : int {
    System = 0,
    Light = 1,
    Dark = 2
};

class AppBuilder {
public:
    explicit AppBuilder(std::string_view title);
    ~AppBuilder() = default;

    AppBuilder& theme_mode(ThemeMode mode);
    [[nodiscard]] std::string_view title() const;
    [[nodiscard]] bool is_dark() const;
    void init() const;

private:
    std::string title_;
    ThemeMode theme_mode_{ThemeMode::System};
};

/// Convenience function to initialize the Slate logging runtime.
void init();

/// Starts the Slint desktop event loop.
void run_event_loop();

/// Quits the active Slint desktop event loop.
void quit_event_loop();

} // namespace slate
