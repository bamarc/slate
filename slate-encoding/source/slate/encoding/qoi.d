/// Lossless Quite OK Image (QOI) codec per specification.
module slate.encoding.qoi;

public enum uint MAX_QOI_PIXELS = 16_777_216; // 16 Mpix DoS guard
public enum ubyte[4] QOI_MAGIC = [0x71, 0x6f, 0x69, 0x66]; // "qoif"
public enum ubyte[8] QOI_END_MARKER = [0, 0, 0, 0, 0, 0, 0, 1];

public enum ubyte QOI_OP_INDEX = 0x00; // 00xxxxxx
public enum ubyte QOI_OP_DIFF = 0x40; // 01xxxxxx
public enum ubyte QOI_OP_LUMA = 0x80; // 10xxxxxx
public enum ubyte QOI_OP_RUN = 0xc0; // 11xxxxxx
public enum ubyte QOI_OP_RGB = 0xfe; // 11111110
public enum ubyte QOI_OP_RGBA = 0xff; // 11111111

public struct QoiRgba
{
    ubyte r = 0;
    ubyte g = 0;
    ubyte b = 0;
    ubyte a = 0; // Spec: index table initializes to zeroed entries {0,0,0,0}

    pragma(inline, true) bool opEquals(const ref QoiRgba other) const @safe pure nothrow @nogc
    {
        return r == other.r && g == other.g && b == other.b && a == other.a;
    }

    pragma(inline, true) ubyte hash() const @safe pure nothrow @nogc
    {
        return cast(ubyte)((cast(uint) r * 3u + cast(uint) g * 5u + cast(
                uint) b * 7u + cast(uint) a * 11u) % 64u);
    }
}

public struct QoiDesc
{
    uint width = 0;
    uint height = 0;
    ubyte channels = 4;
    ubyte colorspace = 0;
}

public struct QoiDecodeResult
{
    bool ok = false;
    string error = "";
    QoiDesc desc;
    ubyte[] rgba;
}

/// Encode RGBA8 pixel buffer to QOI wire format.
ubyte[] encodeQoi(const(ubyte)[] pixels, uint width, uint height,
        ubyte channels = 4, ubyte colorspace = 0) @safe pure nothrow
{
    if (width == 0 || height == 0 || channels < 3 || channels > 4 || colorspace > 1)
        return null;

    const ulong totalPixels = cast(ulong) width * cast(ulong) height;
    if (totalPixels > MAX_QOI_PIXELS)
        return null;

    const size_t expectedBytes = cast(size_t) totalPixels * channels;
    if (pixels.length < expectedBytes)
        return null;

    // Allocate upper bound: 14 header + pixels * 5 + 8 end marker
    size_t maxOutputSize = 14 + cast(size_t) totalPixels * 5 + 8;
    ubyte[] output = new ubyte[maxOutputSize];
    size_t outPos = 0;

    // Header: "qoif", width (BE), height (BE), channels, colorspace
    output[outPos++] = QOI_MAGIC[0];
    output[outPos++] = QOI_MAGIC[1];
    output[outPos++] = QOI_MAGIC[2];
    output[outPos++] = QOI_MAGIC[3];
    output[outPos++] = cast(ubyte)((width >> 24) & 0xff);
    output[outPos++] = cast(ubyte)((width >> 16) & 0xff);
    output[outPos++] = cast(ubyte)((width >> 8) & 0xff);
    output[outPos++] = cast(ubyte)(width & 0xff);
    output[outPos++] = cast(ubyte)((height >> 24) & 0xff);
    output[outPos++] = cast(ubyte)((height >> 16) & 0xff);
    output[outPos++] = cast(ubyte)((height >> 8) & 0xff);
    output[outPos++] = cast(ubyte)(height & 0xff);
    output[outPos++] = channels;
    output[outPos++] = colorspace;

    QoiRgba[64] indexTable;
    QoiRgba prevPixel = QoiRgba(0, 0, 0, 255);
    int run = 0;

    size_t inPos = 0;
    foreach (p; 0 .. totalPixels)
    {
        QoiRgba cur;
        cur.r = pixels[inPos++];
        cur.g = pixels[inPos++];
        cur.b = pixels[inPos++];
        cur.a = (channels == 4) ? pixels[inPos++] : cast(ubyte) 255;

        if (cur == prevPixel)
        {
            run++;
            if (run == 62 || p + 1 == totalPixels)
            {
                output[outPos++] = cast(ubyte)(QOI_OP_RUN | (run - 1));
                run = 0;
            }
        }
        else
        {
            if (run > 0)
            {
                output[outPos++] = cast(ubyte)(QOI_OP_RUN | (run - 1));
                run = 0;
            }

            ubyte hashIdx = cur.hash();
            if (indexTable[hashIdx] == cur)
            {
                output[outPos++] = cast(ubyte)(QOI_OP_INDEX | hashIdx);
            }
            else
            {
                indexTable[hashIdx] = cur;

                if (cur.a == prevPixel.a)
                {
                    int vr = cast(int) cur.r - cast(int) prevPixel.r;
                    int vg = cast(int) cur.g - cast(int) prevPixel.g;
                    int vb = cast(int) cur.b - cast(int) prevPixel.b;

                    int drDg = vr - vg;
                    int dbDg = vb - vg;

                    if (vr >= -2 && vr <= 1 && vg >= -2 && vg <= 1 && vb >= -2 && vb <= 1)
                    {
                        output[outPos++] = cast(ubyte)(
                                QOI_OP_DIFF | ((vr + 2) << 4) | ((vg + 2) << 2) | (vb + 2));
                    }
                    else if (vg >= -32 && vg <= 31 && drDg >= -8 && drDg <= 7
                            && dbDg >= -8 && dbDg <= 7)
                    {
                        output[outPos++] = cast(ubyte)(QOI_OP_LUMA | (vg + 32));
                        output[outPos++] = cast(ubyte)(((drDg + 8) << 4) | (dbDg + 8));
                    }
                    else
                    {
                        output[outPos++] = QOI_OP_RGB;
                        output[outPos++] = cur.r;
                        output[outPos++] = cur.g;
                        output[outPos++] = cur.b;
                    }
                }
                else
                {
                    output[outPos++] = QOI_OP_RGBA;
                    output[outPos++] = cur.r;
                    output[outPos++] = cur.g;
                    output[outPos++] = cur.b;
                    output[outPos++] = cur.a;
                }
            }

            prevPixel = cur;
        }
    }

    if (run > 0)
    {
        output[outPos++] = cast(ubyte)(QOI_OP_RUN | (run - 1));
    }

    // End marker: 0, 0, 0, 0, 0, 0, 0, 1
    foreach (m; QOI_END_MARKER)
        output[outPos++] = m;

    return output[0 .. outPos];
}

/// Decode QOI wire format back to RGBA8 pixel buffer.
QoiDecodeResult decodeQoi(const(ubyte)[] data) @safe pure nothrow
{
    QoiDecodeResult res;
    if (data.length < 14 + 8)
    {
        res.error = "Input buffer too small for QOI header and end marker";
        return res;
    }

    if (data[0 .. 4] != QOI_MAGIC)
    {
        res.error = "Invalid QOI magic";
        return res;
    }

    uint width = (cast(uint) data[4] << 24) | (cast(uint) data[5] << 16) | (
            cast(uint) data[6] << 8) | cast(uint) data[7];
    uint height = (cast(uint) data[8] << 24) | (cast(uint) data[9] << 16) | (
            cast(uint) data[10] << 8) | cast(uint) data[11];
    ubyte channels = data[12];
    ubyte colorspace = data[13];

    if (width == 0 || height == 0)
    {
        res.error = "Invalid zero dimensions";
        return res;
    }
    if (channels < 3 || channels > 4)
    {
        res.error = "Unsupported channels count";
        return res;
    }
    if (colorspace > 1)
    {
        res.error = "Invalid QOI colorspace";
        return res;
    }

    const ulong totalPixels = cast(ulong) width * cast(ulong) height;
    if (totalPixels > MAX_QOI_PIXELS)
    {
        res.error = "Dimension exceeds MAX_QOI_PIXELS DoS limit";
        return res;
    }

    // Pre-allocation feasibility check (G2, G5, W1):
    // Minimum bytes required to encode totalPixels at max run-length (62 pixels per byte).
    const ulong minOpcodeBytes = (totalPixels + 61) / 62;
    if ((data.length - 22) < minOpcodeBytes)
    {
        res.error = "Truncated QOI stream for declared dimensions";
        return res;
    }

    // Verify 8-byte end marker at end of stream
    if (data[$ - 8 .. $] != QOI_END_MARKER)
    {
        res.error = "Missing or corrupted QOI end marker";
        return res;
    }

    res.desc = QoiDesc(width, height, channels, colorspace);
    ubyte[] rgba = new ubyte[cast(size_t) totalPixels * 4];
    size_t outPos = 0;

    QoiRgba[64] indexTable;
    QoiRgba cur = QoiRgba(0, 0, 0, 255);

    size_t inPos = 14;
    const size_t endLimit = data.length - 8;

    while (inPos < endLimit && (outPos / 4) < totalPixels)
    {
        ubyte b1 = data[inPos++];

        if (b1 == QOI_OP_RGB)
        {
            if (inPos + 3 > endLimit)
            {
                res.error = "Truncated QOI_OP_RGB chunk";
                return res;
            }
            cur.r = data[inPos++];
            cur.g = data[inPos++];
            cur.b = data[inPos++];
        }
        else if (b1 == QOI_OP_RGBA)
        {
            if (inPos + 4 > endLimit)
            {
                res.error = "Truncated QOI_OP_RGBA chunk";
                return res;
            }
            cur.r = data[inPos++];
            cur.g = data[inPos++];
            cur.b = data[inPos++];
            cur.a = data[inPos++];
        }
        else if ((b1 & 0xc0) == QOI_OP_INDEX)
        {
            cur = indexTable[b1 & 0x3f];
        }
        else if ((b1 & 0xc0) == QOI_OP_DIFF)
        {
            int dr = ((b1 >> 4) & 0x03) - 2;
            int dg = ((b1 >> 2) & 0x03) - 2;
            int db = (b1 & 0x03) - 2;
            cur.r = cast(ubyte)(cur.r + dr);
            cur.g = cast(ubyte)(cur.g + dg);
            cur.b = cast(ubyte)(cur.b + db);
        }
        else if ((b1 & 0xc0) == QOI_OP_LUMA)
        {
            if (inPos >= endLimit)
            {
                res.error = "Truncated QOI_OP_LUMA chunk";
                return res;
            }
            ubyte b2 = data[inPos++];
            int vg = (b1 & 0x3f) - 32;
            int dr = vg + ((b2 >> 4) & 0x0f) - 8;
            int db = vg + (b2 & 0x0f) - 8;
            cur.r = cast(ubyte)(cur.r + dr);
            cur.g = cast(ubyte)(cur.g + vg);
            cur.b = cast(ubyte)(cur.b + db);
        }
        else if ((b1 & 0xc0) == QOI_OP_RUN)
        {
            int run = (b1 & 0x3f) + 1;
            foreach (_; 0 .. run)
            {
                if ((outPos / 4) >= totalPixels)
                {
                    res.error = "Run exceeded total pixel count";
                    return res;
                }
                rgba[outPos++] = cur.r;
                rgba[outPos++] = cur.g;
                rgba[outPos++] = cur.b;
                rgba[outPos++] = cur.a;
            }
            continue;
        }

        indexTable[cur.hash()] = cur;
        rgba[outPos++] = cur.r;
        rgba[outPos++] = cur.g;
        rgba[outPos++] = cur.b;
        rgba[outPos++] = cur.a;
    }

    if ((outPos / 4) != totalPixels)
    {
        res.error = "Decoded pixel count mismatch";
        return res;
    }

    res.ok = true;
    res.rgba = rgba;
    return res;
}

// Spec: Scenario T1 - Lossless QOI RGBA8 round-trip, compression ratio, and error rejection (covers U1, W1, G1-G5)
/// Example:
unittest
{
    // 64x64 test image: SMPTE-like color bars and motion reticle
    const uint width = 64;
    const uint height = 64;
    ubyte[] rawRgba = new ubyte[width * height * 4];

    foreach (y; 0 .. height)
    {
        foreach (x; 0 .. width)
        {
            size_t idx = (y * width + x) * 4;
            // 8 vertical color bars
            int bar = (x * 8) / width;
            ubyte r = (bar & 1) ? 255 : 0;
            ubyte g = (bar & 2) ? 255 : 0;
            ubyte b = (bar & 4) ? 255 : 0;
            ubyte a = 255;

            // Moving reticle in center
            if ((x >= 28 && x <= 36) && (y >= 28 && y <= 36))
            {
                r = 240;
                g = 120;
                b = 60;
            }

            rawRgba[idx + 0] = r;
            rawRgba[idx + 1] = g;
            rawRgba[idx + 2] = b;
            rawRgba[idx + 3] = a;
        }
    }

    ubyte[] encoded = encodeQoi(rawRgba, width, height, 4, 0);
    assert(encoded !is null, "encodeQoi must return encoded bytes");
    assert(encoded.length >= 22, "QOI header + end marker is at least 22 bytes");
    assert(encoded[0 .. 4] == QOI_MAGIC);

    // Verify compression ratio >= 4x on 64x64 color bars
    assert(encoded.length < (rawRgba.length / 4),
            "QOI must compress 64x64 color bars at >= 4x ratio");

    // Decode and verify lossless round-trip
    auto decoded = decodeQoi(encoded);
    assert(decoded.ok, "decodeQoi must succeed on valid stream");
    assert(decoded.desc.width == width && decoded.desc.height == height);
    assert(decoded.desc.channels == 4);
    assert(decoded.rgba.length == rawRgba.length);
    assert(decoded.rgba == rawRgba, "Decoded RGBA buffer must match original byte-for-byte");

    // Failure / unwanted behavior tests (W1, G5)
    // 1. Truncated header
    assert(!decodeQoi([]).ok);
    assert(!decodeQoi(encoded[0 .. 10]).ok);
    // 2. Corrupted magic
    ubyte[] corrupted = encoded.dup;
    corrupted[0] = 'X';
    assert(!decodeQoi(corrupted).ok);
    // 3. Truncated stream body
    assert(!decodeQoi(encoded[0 .. $ - 10]).ok);
    // 4. Missing end marker
    ubyte[] noEnd = encoded.dup;
    noEnd[$ - 1] = 0;
    assert(!decodeQoi(noEnd).ok);
    // 5. Oversized dimensions (G5)
    ubyte[] badDim = encoded.dup;
    badDim[4] = 0x02; // width ~ 33 million
    assert(!decodeQoi(badDim).ok);

    // 6. Pre-allocation feasibility check: 4096x4096 header with zero opcode body (Finding 2)
    ubyte[22] bombHeader = [
        0x71, 0x6f, 0x69, 0x66, // "qoif"
        0x00, 0x00, 0x10, 0x00, // width = 4096
        0x00, 0x00, 0x10, 0x00, // height = 4096
        0x04, // channels = 4
        0x00, // colorspace = 0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01 // end marker
    ];
    auto bombRes = decodeQoi(bombHeader);
    assert(!bombRes.ok, "Must reject stream with insufficient opcode payload without allocating");

    // 7. Invalid colorspace (Finding 2)
    ubyte[] badColorspace = encoded.dup;
    badColorspace[13] = 2; // invalid colorspace > 1
    assert(!decodeQoi(badColorspace).ok, "Must reject invalid colorspace > 1");

    // 8. Spec-compliant initial index table {0,0,0,0}
    QoiRgba[64] freshTable;
    foreach (ref entry; freshTable)
    {
        assert(entry.r == 0 && entry.g == 0 && entry.b == 0 && entry.a == 0,
                "Fresh index table entries must initialize to 0,0,0,0");
    }
}
