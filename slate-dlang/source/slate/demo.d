/// Shared demo workload: Monte Carlo π approximation.
///
/// Exact port of `slate::demo`, including the splitmix64 PRNG (same seed,
/// same sequence), batching, cancellation polling, and result text.
module slate.demo;

import std.typecons : Nullable, Tuple, tuple;

/// Samples used by the showcase.
enum ulong defaultSamples = 20_000_000UL;

private enum ulong batchSize = 200_000UL;

/// splitmix64: small, fast, full-period 64-bit PRNG.
private struct SplitMix64
{
    ulong s;

    ulong nextU64() @safe pure nothrow @nogc
    {
        s += 0x9E37_79B9_7F4A_7C15UL;
        ulong z = s;
        z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBUL;
        return z ^ (z >> 31);
    }

    /// Uniform in [0, 1) from the top 53 bits.
    double nextF64() @safe pure nothrow @nogc
    {
        return cast(double)(nextU64() >> 11) / cast(double)(1UL << 53);
    }
}

/// Monte Carlo π with `defaultSamples` points. Null when cancelled.
Nullable!double monteCarloPi(bool delegate() isCancelled, void delegate(float) progress)
{
    return monteCarloPiSamples(defaultSamples, isCancelled, progress);
}

/// Monte Carlo π with `totalSamples` points in the unit square.
/// Null when cancelled; `0` samples yield `Some(0.0)` like Rust.
Nullable!double monteCarloPiSamples(ulong totalSamples, bool delegate() isCancelled,
    void delegate(float) progress)
{
    if (totalSamples == 0)
        return Nullable!double(0.0);
    auto rng = SplitMix64(0x5EED_1234_ABCD_EF01UL);
    ulong inside;

    foreach (i; 0 .. totalSamples)
    {
        if (i % batchSize == 0)
        {
            if (isCancelled())
                return Nullable!double.init;
            progress(cast(float) i / cast(float) totalSamples);
        }
        auto x = rng.nextF64();
        auto y = rng.nextF64();
        if (x * x + y * y <= 1.0)
            inside++;
    }
    return Nullable!double(4.0 * cast(double) inside / cast(double) totalSamples);
}

/// Status and result text for the UI for a finished run.
Tuple!(string, "status", string, "text") describeResult(Nullable!double result) @safe pure
{
    import std.format : format;

    if (result.isNull)
        return tuple!("status", "text")("Cancelled", "Computation was cancelled");
    return tuple!("status", "text")("Completed", format!"π ≈ %.6f"(result.get));
}

///
unittest
{
    import std.math : PI, abs;

    auto pi = monteCarloPiSamples(2_000_000, () => false, (float p) {});
    assert(!pi.isNull && abs(pi.get - PI) < 0.01);

    assert(monteCarloPiSamples(2_000_000, () => true, (float p) {}).isNull);
    assert(monteCarloPiSamples(0, () => false, (float p) {}).get == 0.0);

    int polls;
    auto midway = monteCarloPiSamples(2_000_000, () {
        polls++;
        return polls > 3;
    }, (float p) {});
    assert(midway.isNull);

    auto rng = SplitMix64(1);
    double top = 0; // NB: D inits floats to NaN, unlike Rust's 0.0
    foreach (_; 0 .. 10_000)
    {
        auto v = rng.nextF64();
        assert(v >= 0.0 && v < 1.0);
        if (v > top)
            top = v;
    }
    assert(top > 0.99);

    // Bit-identity with Steele et al. splitmix64, cross-checked against an
    // independent Python implementation of the algorithm (hence with Rust).
    auto g = SplitMix64(0x5EED_1234_ABCD_EF01UL);
    assert(g.nextU64() == 0xfde27e9b94895d85UL);
    assert(g.nextU64() == 0x8350d6a98064f98aUL);
    assert(SplitMix64(1).nextU64() == 0x910a2dec89025cc1UL);

    assert(describeResult(Nullable!double(3.14159265)).status == "Completed");
    assert(describeResult(Nullable!double(3.14159265)).text.length > 0);
    import std.algorithm : canFind;

    assert(describeResult(Nullable!double(3.14159265)).text.canFind("3.141593"));
    assert(describeResult(Nullable!double.init).status == "Cancelled");
}
