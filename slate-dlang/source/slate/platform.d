/// Linux/desktop platform integration helpers.
///
/// Exact port of `slate_extensions::platform`: `GTK_THEME` / `COLOR_SCHEME`
/// environment parsing, GNOME `color-scheme` gsettings fallback, and the
/// same priority order. Absence is `Nullable` (`None` in Rust); the final
/// default is dark, the framework's default aesthetic.
module slate.platform;

import std.typecons : Nullable, nullable;

/// Interpret a `GTK_THEME` value (e.g. `Adwaita:dark`). A set theme without
/// "dark" counts as light; blank counts as absent.
Nullable!bool parseGtkTheme(string value) @safe pure
{
    import std.string : strip;
    import std.uni : toLower;
    import std.algorithm : canFind;

    auto v = value.strip();
    if (v.length == 0)
        return Nullable!bool.init;
    return nullable(v.toLower().canFind("dark"));
}

/// Interpret a color-scheme value (`dark`, `prefer-dark`, quoted gsettings
/// output like `'default'`). Unrecognised input is absent.
Nullable!bool parseColorScheme(string value) @safe pure
{
    import std.string : strip;
    import std.uni : toLower;

    auto v = value.strip();
    while (v.length && (v[0] == '\'' || v[0] == '"'))
        v = v[1 .. $];
    while (v.length && (v[$ - 1] == '\'' || v[$ - 1] == '"'))
        v = v[0 .. $ - 1];
    switch (v.toLower())
    {
    case "dark":
    case "prefer-dark":
        return nullable(true);
    case "light":
    case "prefer-light":
    case "default":
        return nullable(false);
    default:
        return Nullable!bool.init;
    }
}

/// Resolve the preference in priority order: `GTK_THEME`, `COLOR_SCHEME`,
/// then the lazily evaluated gsettings query (never called when an earlier
/// source decides).
Nullable!bool resolveDarkMode(Nullable!string gtkTheme, Nullable!string colorScheme,
    Nullable!string delegate() @safe gsettings) @safe
{
    import slate.utils.optional : andThen;

    auto d = gtkTheme.andThen!parseGtkTheme;
    if (!d.isNull)
        return d;
    d = colorScheme.andThen!parseColorScheme;
    if (!d.isNull)
        return d;
    return gsettings().andThen!parseColorScheme;
}

private Nullable!string queryGsettings() @safe nothrow
{
    import std.process : execute;

    try
    {
        auto res = execute(["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"]);
        if (res.status != 0)
            return Nullable!string.init;
        return nullable(res.output);
    }
    catch (Exception)
    {
        return Nullable!string.init;
    }
}

/// Detect the system appearance, or null when it cannot be determined.
Nullable!bool detectSystemDarkModeOpt() @safe nothrow
{
    import std.process : environment;

    try
    {
        Nullable!string envOf(string name)
        {
            auto v = environment.get(name, null);
            return v is null ? Nullable!string.init : nullable(v);
        }

        return resolveDarkMode(envOf("GTK_THEME"), envOf("COLOR_SCHEME"), () => queryGsettings());
    }
    catch (Exception)
    {
        return Nullable!bool.init;
    }
}

/// Whether the desktop prefers dark; defaults to dark when undetectable.
bool detectSystemDarkMode() @safe nothrow
{
    import slate.utils.optional : unwrapOr;

    return detectSystemDarkModeOpt().unwrapOr(true);
}

///
unittest
{
    assert(parseGtkTheme("Adwaita:dark").get == true);
    assert(parseGtkTheme("Adwaita").get == false);
    assert(parseGtkTheme("  ").isNull);

    assert(parseColorScheme("'prefer-dark'\n").get == true);
    assert(parseColorScheme("dark").get == true);
    assert(parseColorScheme("'default'").get == false);
    assert(parseColorScheme("PREFER-LIGHT").get == false);
    assert(parseColorScheme("weird").isNull);

    Nullable!string never()
    {
        assert(false, "must not be queried");
    }

    assert(resolveDarkMode(nullable("X:dark"), nullable("light"), &never).get == true);
    assert(resolveDarkMode(Nullable!string.init, nullable("light"), &never).get == false);
    assert(resolveDarkMode(Nullable!string.init, Nullable!string.init,
        () => nullable("'prefer-dark'")).get == true);
    assert(resolveDarkMode(Nullable!string.init, nullable("bogus"),
        () => nullable("'default'")).get == false);
    assert(resolveDarkMode(Nullable!string.init, Nullable!string.init,
        () => Nullable!string.init).isNull);

    // Detection never throws, whatever the host looks like.
    assert(detectSystemDarkMode() == true || detectSystemDarkMode() == false);
}
