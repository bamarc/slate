/// Math and animation interpolation helpers.
///
/// Exact port of `slate_utils::math`.
module slate.utils.math;

/// Linear interpolation; `t` is clamped to 0..1.
float lerp(float a, float b, float t) @safe pure nothrow @nogc
in
{
    import std.math : isFinite;

    assert(isFinite(a), "lerp parameter 'a' must be finite (neither NaN nor infinity)");
    assert(isFinite(b), "lerp parameter 'b' must be finite (neither NaN nor infinity)");
    assert(isFinite(t), "lerp parameter 't' must be finite (neither NaN nor infinity)");
}
out (result)
{
    import std.algorithm.comparison : max, min;
    import std.math : isNaN;

    assert(!isNaN(result), "lerp result must not be NaN");
    assert(result >= min(a, b) - 1e-4f && result <= max(a, b) + 1e-4f,
        "lerp result must lie between min(a, b) and max(a, b)");
}
do
{
    import std.algorithm.comparison : clamp;

    return a + (b - a) * clamp(t, 0.0f, 1.0f);
}

/// Smoothstep curve for natural UI transitions.
float smoothstep(float edge0, float edge1, float x) @safe pure nothrow @nogc
in
{
    import std.math : isFinite;

    assert(isFinite(edge0), "smoothstep parameter 'edge0' must be finite (neither NaN nor infinity)");
    assert(isFinite(edge1), "smoothstep parameter 'edge1' must be finite (neither NaN nor infinity)");
    assert(isFinite(x), "smoothstep parameter 'x' must be finite (neither NaN nor infinity)");
    assert(edge0 < edge1, "smoothstep 'edge0' must be strictly less than 'edge1'");
}
out (result)
{
    import std.math : isNaN;

    assert(!isNaN(result), "smoothstep result must not be NaN");
    assert(result >= 0.0f && result <= 1.0f, "smoothstep result must be in [0.0, 1.0]");
}
do
{
    import std.algorithm.comparison : clamp;

    auto t = clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

///
unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;

    // Happy-path verification
    assert(lerp(0, 100, 0.5f) == 50.0f);
    assert(lerp(0, 100, 2.0f) == 100.0f);
    assert(lerp(100, 0, 0.25f) == 75.0f);
    assert(smoothstep(0, 1, 0.0f) == 0.0f);
    assert(smoothstep(0, 1, 1.0f) == 1.0f);
    assert(smoothstep(0, 1, 0.5f) == 0.5f);

    // Contract verification: lerp preconditions (NaN and Infinity)
    assertThrown!AssertError(lerp(float.nan, 100, 0.5f));
    assertThrown!AssertError(lerp(0, float.nan, 0.5f));
    assertThrown!AssertError(lerp(0, 100, float.nan));
    assertThrown!AssertError(lerp(float.infinity, 100, 0.5f));
    assertThrown!AssertError(lerp(-float.infinity, 100, 0.5f));
    assertThrown!AssertError(lerp(0, float.infinity, 0.5f));
    assertThrown!AssertError(lerp(0, 100, float.infinity));

    // Contract verification: smoothstep preconditions (NaN, Infinity, and edge ordering)
    assertThrown!AssertError(smoothstep(float.nan, 1, 0.5f));
    assertThrown!AssertError(smoothstep(0, float.nan, 0.5f));
    assertThrown!AssertError(smoothstep(0, 1, float.nan));
    assertThrown!AssertError(smoothstep(-float.infinity, 1, 0.5f));
    assertThrown!AssertError(smoothstep(0, float.infinity, 0.5f));
    assertThrown!AssertError(smoothstep(0, 1, float.infinity));
    assertThrown!AssertError(smoothstep(1, 0, 0.5f)); // edge0 >= edge1
    assertThrown!AssertError(smoothstep(5, 5, 2.0f)); // edge0 == edge1
}
