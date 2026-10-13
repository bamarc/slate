/// Minimal RGBA8 PNG encoding (no dependencies).
///
/// Exists so offscreen snapshots (`ComponentInstance.snapshot`, the same
/// technique as Slate's screenshot tool) can be saved anywhere without
/// pulling in an image library.
module slint.png;

/// Encode `rgba` (width × height × 4 bytes) as a PNG file image.
ubyte[] encodePngRgba(uint width, uint height, const ubyte[] rgba)
{
    import std.bitmanip : nativeToBigEndian;
    import std.digest.crc : crc32Of;
    import std.zlib : compress;
    import slint.instance : SlintCallError;

    if (rgba.length != cast(size_t) width * height * 4)
        throw new SlintCallError("pixel buffer size mismatch for PNG encoding");

    ubyte[] png = [137, 80, 78, 71, 13, 10, 26, 10];
    void chunk(string tag, const ubyte[] payload)
    {
        png ~= nativeToBigEndian(cast(uint) payload.length)[];
        png ~= cast(const ubyte[]) tag;
        png ~= payload;
        // NB: crc32Of yields little-endian bytes; PNG stores big-endian.
        ubyte[4] crc = crc32Of(cast(const ubyte[]) tag ~ payload);
        png ~= [crc[3], crc[2], crc[1], crc[0]];
    }

    ubyte[] ihdr;
    ihdr ~= nativeToBigEndian(width)[];
    ihdr ~= nativeToBigEndian(height)[];
    ihdr ~= [8, 6, 0, 0, 0];
    chunk("IHDR", ihdr);

    ubyte[] raw;
    raw.reserve(height * (1 + width * 4));
    foreach (y; 0 .. height)
    {
        raw ~= 0;
        raw ~= rgba[y * width * 4 .. (y + 1) * width * 4];
    }
    chunk("IDAT", cast(const ubyte[]) compress(raw, 6));
    chunk("IEND", []);
    return png;
}

///
unittest
{
    import std.bitmanip : bigEndianToNative;

    auto png = encodePngRgba(2, 1, [255, 0, 0, 255, 0, 0, 255, 255]);
    assert(png[0 .. 8] == [137, 80, 78, 71, 13, 10, 26, 10]);
    assert(bigEndianToNative!uint(png[16 .. 20]) == 2);
    assert(bigEndianToNative!uint(png[20 .. 24]) == 1);
    // IHDR CRC golden value (external ground truth: Python zlib).
    assert(png[29 .. 33] == [0xF4, 0x22, 0x7F, 0x8A]);

    import std.exception : assertThrown;
    import slint.instance : SlintCallError;

    assertThrown!SlintCallError(encodePngRgba(2, 2, [1, 2, 3]));
}
