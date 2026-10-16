/// Pure `@safe` SVG path and coordinate normalization utilities for Slate charts:
/// - `SlateSparkline` (`buildSparklinePath`, `buildAreaPath`)
/// - `SlateLineChart` (`buildLinePath`)
/// - `SlateDonutChart` / `SlateGauge` (`buildDonutArcPath`)
///
/// Satisfies Requirements `U4` and `W3` (`Scenario T5`):
/// - Handles empty, single-element, and zero-variance (`min == max`) series gracefully.
/// - Scrubs `NaN` and `Infinity` values so SVG path strings never contain `"nan"` or `"inf"`.
module slate.utils.chart;

import std.algorithm : max, min;
import std.array : appender;
import std.format : formattedWrite;
import std.math : cos, isFinite, PI, sin;

/// Filter/replace non-finite (`NaN` / `Inf`) values with `0.0`.
double[] sanitizeSeries(const(double)[] series) @safe pure nothrow
{
    double[] clean;
    clean.reserve(series.length);
    foreach (v; series)
        clean ~= isFinite(v) ? v : 0.0;
    return clean;
}

/// Normalize a numeric series into `[0.0, 1.0]`.
/// When all values are equal (`min == max`), returns `0.5` for every point (`W3`).
double[] normalizeSeries(const(double)[] series) @safe pure nothrow
{
    auto clean = sanitizeSeries(series);
    if (clean.length == 0)
        return [];

    double minVal = clean[0];
    double maxVal = clean[0];
    foreach (v; clean[1 .. $])
    {
        if (v < minVal)
            minVal = v;
        if (v > maxVal)
            maxVal = v;
    }

    double span = maxVal - minVal;
    double[] norm = new double[clean.length];
    if (!isFinite(span) || span <= 1e-12)
    {
        norm[] = 0.5;
        return norm;
    }

    foreach (i, v; clean)
        norm[i] = (v - minVal) / span;
    return norm;
}

/// Build an SVG polyline `M x0 y0 L x1 y1 ...` path within `[0..width] × [0..height]`.
/// Y-coordinates are inverted (`0` at top, `height` at bottom).
string buildSparklinePath(const(double)[] series, double width = 100.0, double height = 30.0) @safe pure
{
    double w = (isFinite(width) && width > 0.0) ? width : 100.0;
    double h = (isFinite(height) && height > 0.0) ? height : 30.0;
    double midY = h * 0.5;

    auto norm = normalizeSeries(series);
    if (norm.length == 0)
    {
        auto buf = appender!string();
        formattedWrite(buf, "M 0 %.2f L %.2f %.2f", midY, w, midY);
        return buf.data;
    }
    if (norm.length == 1)
    {
        double y = h - norm[0] * h;
        auto buf = appender!string();
        formattedWrite(buf, "M 0 %.2f L %.2f %.2f", y, w, y);
        return buf.data;
    }

    auto buf = appender!string();
    double stepX = w / cast(double)(norm.length - 1);
    foreach (i, n; norm)
    {
        double x = i * stepX;
        double y = h - (n * h);
        if (i == 0)
            formattedWrite(buf, "M %.2f %.2f", x, y);
        else
            formattedWrite(buf, " L %.2f %.2f", x, y);
    }
    return buf.data;
}

/// Alias for `buildSparklinePath` with default chart viewbox dimensions (`100 × 100`).
string buildLinePath(const(double)[] series, double width = 100.0, double height = 100.0) @safe pure
{
    return buildSparklinePath(series, width, height);
}

/// Build a closed SVG area path (`M 0 y0 L ... L width height L 0 height Z`) for area fills.
string buildAreaPath(const(double)[] series, double width = 100.0, double height = 30.0) @safe pure
{
    double w = (isFinite(width) && width > 0.0) ? width : 100.0;
    double h = (isFinite(height) && height > 0.0) ? height : 30.0;
    string line = buildSparklinePath(series, w, h);
    auto buf = appender!string();
    formattedWrite(buf, "%s L %.2f %.2f L 0 %.2f Z", line, w, h, h);
    return buf.data;
}

/// Build an SVG arc path for a donut/gauge chart covering `fraction` in `[0.0, 1.0]`.
string buildDonutArcPath(double fraction, double cx = 50.0, double cy = 50.0, double radius = 40.0) @safe pure
{
    double f = isFinite(fraction) ? max(0.0, min(1.0, fraction)) : 0.0;
    double r = (isFinite(radius) && radius > 0.0) ? radius : 40.0;
    double centerX = isFinite(cx) ? cx : 50.0;
    double centerY = isFinite(cy) ? cy : 50.0;

    if (f <= 0.0001)
    {
        auto buf = appender!string();
        formattedWrite(buf, "M %.2f %.2f", centerX, centerY - r);
        return buf.data;
    }

    // Clamp to 0.9999 so start and end points don't collapse to a 0-length SVG arc
    double clamped = min(f, 0.999);
    double startAngle = -PI * 0.5;
    double endAngle = startAngle + clamped * 2.0 * PI;

    double x1 = centerX + r * cos(startAngle);
    double y1 = centerY + r * sin(startAngle);
    double x2 = centerX + r * cos(endAngle);
    double y2 = centerY + r * sin(endAngle);
    int largeArc = clamped > 0.5 ? 1 : 0;

    auto buf = appender!string();
    formattedWrite(buf, "M %.2f %.2f A %.2f %.2f 0 %d 1 %.2f %.2f", x1, y1,
            r, r, largeArc, x2, y2);
    return buf.data;
}

// Spec: Scenario T5: SVG chart path generation and degenerate series safety (covers U4, W3)
/// Example:
@safe unittest
{
    import std.algorithm : canFind, startsWith;
    import std.uni : toLower;

    // 1. Empty series returns flat mid-line without NaN
    auto pEmpty = buildSparklinePath([], 100.0, 30.0);
    assert(pEmpty == "M 0 15.00 L 100.00 15.00");
    assert(!pEmpty.toLower().canFind("nan"));

    // 2. Single-point series returns horizontal line at mid-height
    auto pSingle = buildSparklinePath([42.0], 100.0, 30.0);
    assert(pSingle == "M 0 15.00 L 100.00 15.00");
    assert(!pSingle.toLower().canFind("nan"));

    // 3. Flat zero-variance series [5.0, 5.0, 5.0] produces flat line at height / 2 without NaN
    auto pFlat = buildSparklinePath([5.0, 5.0, 5.0], 100.0, 30.0);
    assert(pFlat == "M 0.00 15.00 L 50.00 15.00 L 100.00 15.00");
    assert(!pFlat.toLower().canFind("nan"));

    // 4. Multi-point series [10.0, 40.0, 25.0, 80.0] starts with "M " and stays within bounds
    auto pMulti = buildSparklinePath([10.0, 40.0, 25.0, 80.0], 120.0, 40.0);
    assert(pMulti.startsWith("M "));
    assert(!pMulti.toLower().canFind("nan"));
    assert(!pMulti.toLower().canFind("inf"));

    // 5. NaN / Infinity inputs are sanitized cleanly
    auto pNan = buildSparklinePath([double.nan, double.infinity, 10.0], 100.0, 30.0);
    assert(pNan.startsWith("M "));
    assert(!pNan.toLower().canFind("nan"));
    assert(!pNan.toLower().canFind("inf"));

    // 6. Area and Donut Arc paths
    auto area = buildAreaPath([10.0, 20.0, 15.0], 100.0, 30.0);
    assert(area.canFind("Z"));
    auto arc = buildDonutArcPath(0.75, 50.0, 50.0, 40.0);
    assert(arc.startsWith("M ") && arc.canFind(" A "));
}
