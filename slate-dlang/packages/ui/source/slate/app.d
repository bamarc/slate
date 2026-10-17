/// High-level application configuration builder.
///
/// Port of `slate::AppBuilder`: title plus theme mode, system-preference
/// resolution only when the mode is `system`, and idempotent logging
/// initialization. D adaptation: a value-type builder — combinators return a
/// modified copy, so `AppBuilder("x").themeMode(ThemeMode.dark).init()`
/// chains without borrow concerns.
module slate.app;

import slate.theme : ThemeMode, isDark;
import slate.platform : detectSystemDarkMode;

/// Application configuration under construction.
struct AppBuilder
{
    private string _title;
    private ThemeMode _mode = ThemeMode.system;

    this(string title) @safe pure nothrow
    {
        _title = title;
    }

    /// Set the initial theme mode (default: system).
    AppBuilder themeMode(ThemeMode mode) @safe pure nothrow
    {
        auto copy = this;
        copy._mode = mode;
        return copy;
    }

    /// Application title.
    string title() const @safe pure nothrow
    {
        return _title;
    }

    /// Configured mode (for tests and UI wiring).
    ThemeMode mode() const @safe pure nothrow
    {
        return _mode;
    }

    /// Resolve the configured mode against the system preference, querying
    /// the system only when the mode is `system`.
    bool isDark() const
    {
        final switch (_mode)
        {
        case ThemeMode.system:
            return .isDark(_mode, detectSystemDarkMode());
        case ThemeMode.light:
        case ThemeMode.dark:
            return .isDark(_mode, false);
        }
    }

    /// Initialize logging (idempotent) and log the resolved theme via `slog`.
    void init() const
    {
        import slate.log : slog;

        slateInit();
        slog.configure(_title.length > 0 ? _title : "slate");
        slog.info("Initializing Slate UI framework", "title", _title, "dark_theme", isDark());
    }
}

private shared bool _inited;

/// Idempotent logging initialization routing `std.logger` into `slate.log.slog`.
void slateInit() @trusted nothrow
{
    import core.atomic : cas;
    import slate.log : installOtelStdLoggerBridge;

    if (cas(&_inited, false, true))
    {
        installOtelStdLoggerBridge("slate");
    }
}

///
unittest
{
    auto b = AppBuilder("demo");
    assert(b.title == "demo");
    assert(b.mode == ThemeMode.system);
    assert(b.themeMode(ThemeMode.dark).mode == ThemeMode.dark);
    assert(b.mode == ThemeMode.system); // combinators copy, never mutate
    assert(AppBuilder("x").themeMode(ThemeMode.dark).isDark());
    assert(!AppBuilder("x").themeMode(ThemeMode.light).isDark());
    slateInit();
    b.init(); // idempotent, never throws
}
