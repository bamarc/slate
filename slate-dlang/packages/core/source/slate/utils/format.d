/// Formatting helpers for developer experience.
///
/// Exact port of `slate_utils::format`: binary byte quantities and
/// thousands-separated integers.
module slate.utils.format;

import std.format : format;

/// `500` → `"500 B"`, `2048` → `"2.0 KiB"`, binary units up to GiB.
string formatBytes(ulong bytes) @safe pure
{
    enum kib = 1024UL;
    enum mib = kib * 1024;
    enum gib = mib * 1024;

    if (bytes >= gib)
        return format!"%.2f GiB"(cast(double) bytes / gib);
    if (bytes >= mib)
        return format!"%.2f MiB"(cast(double) bytes / mib);
    if (bytes >= kib)
        return format!"%.1f KiB"(cast(double) bytes / kib);
    return format!"%s B"(bytes);
}

/// `1234567` → `"1,234,567"`.
string formatNumber(ulong val) @safe pure nothrow
{
    if (val == 0)
        return "0";

    char[32] buf;
    size_t pos = buf.length;
    size_t count = 0;

    while (val > 0)
    {
        if (count > 0 && count % 3 == 0)
        {
            pos--;
            buf[pos] = ',';
        }
        pos--;
        buf[pos] = cast(char)('0' + (val % 10));
        val /= 10;
        count++;
    }

    return buf[pos .. $].idup;
}

///
unittest
{
    assert(formatBytes(500) == "500 B");
    assert(formatBytes(2048) == "2.0 KiB");
    assert(formatBytes(5UL * 1024 * 1024) == "5.00 MiB");
    assert(formatNumber(1_234_567) == "1,234,567");
    assert(formatNumber(42) == "42");
}
