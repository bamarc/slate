/// Slate theme modes: which palette applies to the UI.
///
/// Exact port of `slate_core::theme::ThemeMode`: `system` follows the
/// desktop preference (see `slate.platform`), `light`/`dark` pin it.
module slate.theme;

/// Palette selection for the Slate UI.
enum ThemeMode
{
    system,
    light,
    dark
}

/// Resolve whether the dark palette applies, given the system preference.
bool isDark(ThemeMode mode, bool systemPrefersDark) @safe pure nothrow @nogc
{
    final switch (mode)
    {
    case ThemeMode.dark:
        return true;
    case ThemeMode.light:
        return false;
    case ThemeMode.system:
        return systemPrefersDark;
    }
}

/// The explicit mode flipping the currently resolved appearance.
ThemeMode toggle(ThemeMode mode, bool systemPrefersDark) @safe pure nothrow @nogc
{
    return isDark(mode, systemPrefersDark) ? ThemeMode.light : ThemeMode.dark;
}

///
unittest
{
    assert(!isDark(ThemeMode.light, true));
    assert(isDark(ThemeMode.dark, false));
    assert(isDark(ThemeMode.system, true));
    assert(!isDark(ThemeMode.system, false));
    assert(toggle(ThemeMode.system, true) == ThemeMode.light);
    assert(toggle(ThemeMode.system, false) == ThemeMode.dark);
    assert(toggle(ThemeMode.dark, false) == ThemeMode.light);
    assert(toggle(ThemeMode.light, true) == ThemeMode.dark);
}
