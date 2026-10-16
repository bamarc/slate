/// Color utilities for themes and palette manipulation.
///
/// Exact port of `slate_utils::color`: normalized-float `Rgba`, hex parsing
/// (`#RRGGBB` / `#RRGGBBAA`, ASCII-only like the Rust byte slicing),
/// W3C relative luminance, contrast ratios, brightness adjustment.
module slate.utils.color;

import std.typecons : Nullable, nullable;

/// RGBA color with normalized `float` channels.
struct Rgba
{
    float r = 0;
    float g = 0;
    float b = 0;
    float a = 1;

    this(float r, float g, float b, float a = 1) @safe pure nothrow @nogc
    in
    {
        import std.math : isNaN;

        assert(!isNaN(r), "Rgba 'r' must not be NaN");
        assert(!isNaN(g), "Rgba 'g' must not be NaN");
        assert(!isNaN(b), "Rgba 'b' must not be NaN");
        assert(!isNaN(a), "Rgba 'a' must not be NaN");
        assert(r >= 0.0f && r <= 1.0f, "Rgba 'r' must be in [0.0, 1.0]");
        assert(g >= 0.0f && g <= 1.0f, "Rgba 'g' must be in [0.0, 1.0]");
        assert(b >= 0.0f && b <= 1.0f, "Rgba 'b' must be in [0.0, 1.0]");
        assert(a >= 0.0f && a <= 1.0f, "Rgba 'a' must be in [0.0, 1.0]");
    }
    do
    {
        this.r = r;
        this.g = g;
        this.b = b;
        this.a = a;
    }

    invariant
    {
        import std.math : isNaN;

        assert(!isNaN(r), "Rgba 'r' must not be NaN");
        assert(!isNaN(g), "Rgba 'g' must not be NaN");
        assert(!isNaN(b), "Rgba 'b' must not be NaN");
        assert(!isNaN(a), "Rgba 'a' must not be NaN");
        assert(r >= 0.0f && r <= 1.0f, "Rgba 'r' must be in [0.0, 1.0]");
        assert(g >= 0.0f && g <= 1.0f, "Rgba 'g' must be in [0.0, 1.0]");
        assert(b >= 0.0f && b <= 1.0f, "Rgba 'b' must be in [0.0, 1.0]");
        assert(a >= 0.0f && a <= 1.0f, "Rgba 'a' must be in [0.0, 1.0]");
    }

    static Rgba create(float r, float g, float b, float a = 1) @safe pure nothrow @nogc
    in
    {
        import std.math : isNaN;

        assert(!isNaN(r) && !isNaN(g) && !isNaN(b) && !isNaN(a));
        assert(r >= 0.0f && r <= 1.0f && g >= 0.0f && g <= 1.0f && b >= 0.0f
                && b <= 1.0f && a >= 0.0f && a <= 1.0f);
    }
    do
    {
        return Rgba(r, g, b, a);
    }

    /// Parse `#RRGGBB` (alpha 1) or `#RRGGBBAA`; `#` optional.
    /// Returns null for non-ASCII, wrong lengths, or bad hex digits.
    static Nullable!Rgba fromHex(string hex) @safe pure
    {
        import std.conv : to;
        import std.string : startsWith;

        if (hex.startsWith("#"))
            hex = hex[1 .. $];
        foreach (c; hex)
            if (c > 0x7F)
                return Nullable!Rgba.init;
        ubyte pair(size_t i)
        {
            return hex[i .. i + 2].to!ubyte(16);
        }

        try
        {
            if (hex.length == 6)
                return nullable(Rgba(pair(0) / 255.0f, pair(2) / 255.0f, pair(4) / 255.0f, 1.0f));
            if (hex.length == 8)
                return nullable(Rgba(pair(0) / 255.0f, pair(2) / 255.0f,
                        pair(4) / 255.0f, pair(6) / 255.0f));
        }
        catch (Exception)
        {
        }
        return Nullable!Rgba.init;
    }

    /// Relative luminance (W3C formula).
    float luminance() const @safe pure nothrow
    out (lum)
    {
        import std.math : isNaN;

        assert(!isNaN(lum), "luminance must not be NaN");
        assert(lum >= 0.0f && lum <= 1.0f, "luminance must be in [0.0, 1.0]");
    }
    do
    {
        import std.math : pow;

        static float toLinear(float c) @safe pure nothrow
        {
            return c <= 0.03928f ? c / 12.92f : pow((c + 0.055f) / 1.055f, 2.4f);
        }

        return 0.2126f * toLinear(r) + 0.7152f * toLinear(g) + 0.0722f * toLinear(b);
    }

    /// Contrast ratio against another color (1.0 to 21.0).
    /// Validates channel invariants for this Rgba instance.
    void validate() const @safe pure nothrow @nogc
    {
        import std.math : isNaN;

        assert(!isNaN(r) && r >= 0.0f && r <= 1.0f);
        assert(!isNaN(g) && g >= 0.0f && g <= 1.0f);
        assert(!isNaN(b) && b >= 0.0f && b <= 1.0f);
        assert(!isNaN(a) && a >= 0.0f && a <= 1.0f);
    }

    /// Contrast ratio against another color (1.0 to 21.0).
    float contrastRatio(const Rgba other) const @safe pure nothrow
    in
    {
        other.validate();
    }
    out (ratio)
    {
        import std.math : isNaN;

        assert(!isNaN(ratio), "contrastRatio must not be NaN");
        assert(ratio >= 1.0f && ratio <= 21.05f, "contrastRatio must be within [1.0, 21.0]");
    }
    do
    {
        import std.algorithm : max, min;

        auto lighter = max(luminance(), other.luminance());
        auto darker = min(luminance(), other.luminance());
        return (lighter + 0.05f) / (darker + 0.05f);
    }

    /// Lighten (`factor > 1`) or darken (`factor < 1`); alpha preserved.
    Rgba adjustBrightness(float factor) const @safe pure nothrow
    in
    {
        import std.math : isFinite;

        assert(isFinite(factor),
                "adjustBrightness parameter 'factor' must be finite (neither NaN nor infinity)");
        assert(factor >= 0.0f, "adjustBrightness parameter 'factor' must be non-negative");
    }
    out (result)
    {
        assert(result.a == a, "adjustBrightness must preserve alpha channel");
    }
    do
    {
        import std.algorithm.comparison : clamp;

        return Rgba(clamp(r * factor, 0.0f, 1.0f), clamp(g * factor, 0.0f, 1.0f),
                clamp(b * factor, 0.0f, 1.0f), a);
    }
}

///
unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;

    auto white = Rgba.fromHex("#ffffff");
    assert(!white.isNull && white.get == Rgba.create(1, 1, 1, 1));
    auto black = Rgba.fromHex("#000000");
    assert(!black.isNull && black.get == Rgba.create(0, 0, 0, 1));
    assert(white.get.contrastRatio(black.get) >= 20.0);

    // Non-ASCII / malformed input is rejected, never panics.
    assert(Rgba.fromHex("ééé").isNull);
    assert(Rgba.fromHex("#ff00é").isNull);
    assert(Rgba.fromHex("#12345").isNull);
    assert(Rgba.fromHex("#gggggg").isNull);
    assert(!Rgba.fromHex("#ff000080").isNull);
    assert(Rgba.fromHex("ff0000").get.r == 1.0f);

    // Contract verification: Rgba invariants and preconditions
    assertThrown!AssertError(Rgba(float.nan, 0, 0, 1));
    assertThrown!AssertError(Rgba(-0.1f, 0, 0, 1));
    assertThrown!AssertError(Rgba(1.1f, 0, 0, 1));
    assertThrown!AssertError(Rgba.create(0, -0.5f, 0, 1));
    assertThrown!AssertError(white.get.adjustBrightness(float.nan));
    assertThrown!AssertError(white.get.adjustBrightness(-1.0f));
    assertThrown!AssertError(white.get.adjustBrightness(float.infinity));
    assertThrown!AssertError(white.get.adjustBrightness(-float.infinity));

    // Contrast ratio rejects invalid mutated other
    Rgba mutated = Rgba(0, 0, 0, 1);
    mutated.r = float.nan;
    assertThrown!AssertError(white.get.contrastRatio(mutated));

    // adjustBrightness happy path preserves alpha
    auto dimWhite = white.get.adjustBrightness(0.5f);
    assert(dimWhite.r == 0.5f && dimWhite.a == 1.0f);
}
