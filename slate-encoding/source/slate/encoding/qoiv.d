/// Layered Delta-QOI Video (QOIV) codec for MoQ Subgroups.
module slate.encoding.qoiv;

import slate.encoding.qoi : MAX_QOI_PIXELS, QoiDecodeResult, decodeQoi, encodeQoi;

public enum ubyte[4] QOIV_MAGIC = [0x71, 0x6f, 0x69, 0x76]; // "qoiv"

public enum QoivLayerKind : ubyte
{
    keyframe = 0,
    delta = 1,
    baseAnchor = 2
}

public struct QoivEncodedFrame
{
    QoivLayerKind kind;
    ubyte[] baseLayerBytes;
    ubyte[] deltaLayerBytes;
    size_t rawBytes;
    size_t compressedBytes;
    double compressionRatio;
    uint width;
    uint height;
}

public struct QoivDecodeResult
{
    bool ok;
    string error;
    uint width;
    uint height;
    ubyte[] rgba;
    bool isBaseOnlyFallback;
}

/// Helper: compress buffer with etc.c.zlib with strict bounded safety.
private ubyte[] safeZlibCompress(const(ubyte)[] data) @trusted pure nothrow
{
    import etc.c.zlib : compress, compressBound, Z_OK;

    if (data.length == 0)
        return null;

    alias CBoundFn = extern (C) size_t function(size_t) nothrow @nogc pure;
    auto bFn = cast(CBoundFn)(&compressBound);
    size_t bound = bFn(data.length);
    ubyte[] dest = new ubyte[bound];
    size_t destLen = bound;

    alias CCompressFn = extern (C) int function(ubyte*, size_t*, const(ubyte)*, size_t) nothrow @nogc pure;
    auto cFn = cast(CCompressFn)(&compress);
    int err = cFn(dest.ptr, &destLen, data.ptr, data.length);
    if (err != Z_OK)
        return null;

    return dest[0 .. destLen];
}

/// Helper: uncompress buffer with etc.c.zlib bounded to expected maximum size (DoS guard G5).
// Output is pre-allocated strictly to expectedSize; zlib returns Z_BUF_ERROR if uncompressed data exceeds expectedSize.
private ubyte[] safeZlibUncompress(const(ubyte)[] data, size_t expectedSize) @trusted pure nothrow
{
    import etc.c.zlib : uncompress, Z_OK;

    if (data.length == 0 || expectedSize == 0)
        return null;

    ubyte[] dest = new ubyte[expectedSize];
    size_t destLen = expectedSize;

    alias CUncompressFn = extern (C) int function(ubyte*, size_t*, const(ubyte)*, size_t) nothrow @nogc pure;
    auto uFn = cast(CUncompressFn)(&uncompress);
    int err = uFn(dest.ptr, &destLen, data.ptr, data.length);
    if (err != Z_OK || destLen != expectedSize)
        return null;

    return dest;
}

/// Pack a QOIV container chunk (10-byte header: magic, kind, flags, uncompressedLen).
private ubyte[] packQoivChunk(QoivLayerKind kind, const(ubyte)[] rawPayload) @trusted pure nothrow
{
    ubyte[] compressed = null;
    // Compress with zlib; fall back to uncompressed if zlib fails or payload is tiny
    if (rawPayload.length > 32)
    {
        compressed = safeZlibCompress(rawPayload);
    }

    bool useCompressed = (compressed !is null && compressed.length < rawPayload.length);
    const(ubyte)[] bodyData = useCompressed ? compressed : rawPayload;
    ubyte flags = useCompressed ? 1 : 0;
    uint rawLen = cast(uint) rawPayload.length;

    ubyte[] chunk = new ubyte[10 + bodyData.length];
    chunk[0 .. 4] = QOIV_MAGIC[];
    chunk[4] = cast(ubyte) kind;
    chunk[5] = flags;
    chunk[6] = cast(ubyte)((rawLen >> 24) & 0xff);
    chunk[7] = cast(ubyte)((rawLen >> 16) & 0xff);
    chunk[8] = cast(ubyte)((rawLen >> 8) & 0xff);
    chunk[9] = cast(ubyte)(rawLen & 0xff);
    chunk[10 .. $] = bodyData[];

    return chunk;
}

/// Unpack a QOIV container chunk.
private bool unpackQoivChunk(const(ubyte)[] chunk, out QoivLayerKind kind,
        out ubyte[] payload, out string error) @trusted pure nothrow
{
    if (chunk.length < 10)
    {
        error = "Truncated QOIV chunk header";
        return false;
    }
    if (chunk[0 .. 4] != QOIV_MAGIC)
    {
        error = "Invalid QOIV magic";
        return false;
    }

    kind = cast(QoivLayerKind) chunk[4];
    ubyte flags = chunk[5];
    uint expectedLen = (cast(uint) chunk[6] << 24) | (cast(uint) chunk[7] << 16) | (
            cast(uint) chunk[8] << 8) | cast(uint) chunk[9];

    // DoS guard: reject chunks with zero expectedLen or exceeding max valid QOI stream
    enum ulong MAX_QOIV_UNCOMPRESSED = 14 + cast(ulong) MAX_QOI_PIXELS * 5 + 8; // 83_886_102
    if (expectedLen == 0 || expectedLen > MAX_QOIV_UNCOMPRESSED)
    {
        error = "QOIV uncompressed length zero or exceeds security bounds";
        return false;
    }

    const(ubyte)[] bodyData = chunk[10 .. $];
    if (flags & 1)
    {
        ubyte[] decompressed = safeZlibUncompress(bodyData, expectedLen);
        if (decompressed is null || decompressed.length != expectedLen)
        {
            error = "Zlib decompression failed or length mismatch";
            return false;
        }
        payload = decompressed;
    }
    else
    {
        if (bodyData.length != expectedLen)
        {
            error = "Uncompressed payload length mismatch";
            return false;
        }
        payload = bodyData.dup;
    }

    return true;
}

/// Downscale an RGBA8 buffer by factor of 4 (with minimum 4x4) for Base Anchor preview.
private ubyte[] downscaleRgba4x(const(ubyte)[] src, uint srcW, uint srcH, out uint dstW,
        out uint dstH) @safe pure nothrow
{
    dstW = srcW >= 16 ? srcW / 4 : (srcW >= 4 ? srcW : 4);
    dstH = srcH >= 16 ? srcH / 4 : (srcH >= 4 ? srcH : 4);

    ubyte[] dst = new ubyte[cast(size_t) dstW * cast(size_t) dstH * 4];
    foreach (size_t dy; 0 .. dstH)
    {
        size_t sy = (dy * cast(size_t) srcH) / dstH;
        foreach (size_t dx; 0 .. dstW)
        {
            size_t sx = (dx * cast(size_t) srcW) / dstW;
            size_t sIdx = (sy * cast(size_t) srcW + sx) * 4;
            size_t dIdx = (dy * cast(size_t) dstW + dx) * 4;
            dst[dIdx + 0] = src[sIdx + 0];
            dst[dIdx + 1] = src[sIdx + 1];
            dst[dIdx + 2] = src[sIdx + 2];
            dst[dIdx + 3] = src[sIdx + 3];
        }
    }
    return dst;
}

/// Upscale an RGBA8 buffer back to target dimensions via nearest neighbor interpolation.
private ubyte[] upscaleRgba(const(ubyte)[] src, uint srcW, uint srcH, uint dstW, uint dstH) @safe pure nothrow
{
    ubyte[] dst = new ubyte[cast(size_t) dstW * cast(size_t) dstH * 4];
    foreach (size_t dy; 0 .. dstH)
    {
        size_t sy = (dy * cast(size_t) srcH) / dstH;
        if (sy >= srcH)
            sy = srcH - 1;
        foreach (size_t dx; 0 .. dstW)
        {
            size_t sx = (dx * cast(size_t) srcW) / dstW;
            if (sx >= srcW)
                sx = srcW - 1;
            size_t sIdx = (sy * cast(size_t) srcW + sx) * 4;
            size_t dIdx = (dy * cast(size_t) dstW + dx) * 4;
            dst[dIdx + 0] = src[sIdx + 0];
            dst[dIdx + 1] = src[sIdx + 1];
            dst[dIdx + 2] = src[sIdx + 2];
            dst[dIdx + 3] = src[sIdx + 3];
        }
    }
    return dst;
}

/// Encode video frame into layered Base and Delta Subgroups.
QoivEncodedFrame encodeQoivFrame(const(ubyte)[] currentRgba,
        const(ubyte)[] prevRgba, uint width, uint height, bool forceKeyframe = false) @trusted pure nothrow
{
    QoivEncodedFrame frame;
    frame.width = width;
    frame.height = height;

    if (width == 0 || height == 0)
        return frame;

    const ulong totalPixels = cast(ulong) width * cast(ulong) height;
    if (totalPixels > MAX_QOI_PIXELS)
        return frame;

    const size_t frameBytes = cast(size_t) totalPixels * 4;
    if (currentRgba.length < frameBytes)
        return frame;

    frame.rawBytes = frameBytes;

    const bool isKeyframe = forceKeyframe || (prevRgba is null) || (prevRgba.length < frameBytes);

    if (isKeyframe)
    {
        frame.kind = QoivLayerKind.keyframe;
        ubyte[] qoiBase = encodeQoi(currentRgba, width, height, 4, 0);
        if (qoiBase is null)
            return frame;

        frame.baseLayerBytes = packQoivChunk(QoivLayerKind.keyframe, qoiBase);
        frame.deltaLayerBytes = null;
        frame.compressedBytes = frame.baseLayerBytes.length;
        frame.compressionRatio = cast(double) frame.rawBytes / cast(double) frame.compressedBytes;
        return frame;
    }

    // P-frame: Layered Base Anchor + Temporal Delta Residual
    frame.kind = QoivLayerKind.delta;

    // 1. Delta Subgroup: temporal residual delta[i] = (current[i] - prev[i]) mod 256
    ubyte[] deltaResidual = new ubyte[frameBytes];
    foreach (i; 0 .. frameBytes)
    {
        deltaResidual[i] = cast(ubyte)((cast(int) currentRgba[i] - cast(int) prevRgba[i]) & 0xFF);
    }

    ubyte[] qoiDelta = encodeQoi(deltaResidual, width, height, 4, 0);
    if (qoiDelta is null)
        return frame;
    frame.deltaLayerBytes = packQoivChunk(QoivLayerKind.delta, qoiDelta);

    // 2. Base Subgroup: downscaled anchor preview
    uint anchorW, anchorH;
    ubyte[] downscaled = downscaleRgba4x(currentRgba, width, height, anchorW, anchorH);
    ubyte[] qoiAnchor = encodeQoi(downscaled, anchorW, anchorH, 4, 0);
    if (qoiAnchor is null)
        return frame;
    frame.baseLayerBytes = packQoivChunk(QoivLayerKind.baseAnchor, qoiAnchor);

    frame.compressedBytes = frame.baseLayerBytes.length + frame.deltaLayerBytes.length;
    frame.compressionRatio = cast(double) frame.rawBytes / cast(double) frame.compressedBytes;
    return frame;
}

/// Decode layered Base and Delta Subgroups back to RGBA8.
QoivDecodeResult decodeQoivFrame(const(ubyte)[] baseBytes,
        const(ubyte)[] deltaBytes, const(ubyte)[] prevRgba, uint width, uint height) @trusted pure nothrow
{
    QoivDecodeResult res;
    res.width = width;
    res.height = height;

    if (width == 0 || height == 0)
    {
        res.error = "Invalid zero dimensions";
        return res;
    }
    const ulong totalPixels = cast(ulong) width * cast(ulong) height;
    if (totalPixels > MAX_QOI_PIXELS)
    {
        res.error = "Dimensions exceed MAX_QOI_PIXELS DoS limit";
        return res;
    }
    const size_t frameBytes = cast(size_t) totalPixels * 4;

    // Case A: Full Base + Delta Enhancement decode
    if (deltaBytes.length > 0)
    {
        if (prevRgba is null || prevRgba.length < frameBytes)
        {
            res.error = "Missing previous reference frame for temporal delta decode";
            return res;
        }

        QoivLayerKind deltaKind;
        ubyte[] deltaPayload;
        string err;
        if (!unpackQoivChunk(deltaBytes, deltaKind, deltaPayload, err))
        {
            res.error = "Delta chunk error: " ~ err;
            return res;
        }
        if (deltaKind != QoivLayerKind.delta)
        {
            res.error = "Unexpected chunk kind in delta bytes";
            return res;
        }

        auto qoiRes = decodeQoi(deltaPayload);
        if (!qoiRes.ok || qoiRes.rgba.length != frameBytes)
        {
            res.error = "Failed to decode QOI temporal residual: " ~ qoiRes.error;
            return res;
        }

        ubyte[] reconstructed = new ubyte[frameBytes];
        foreach (i; 0 .. frameBytes)
        {
            reconstructed[i] = cast(ubyte)((cast(int) prevRgba[i] + cast(int) qoiRes.rgba[i]) & 0xFF);
        }

        res.ok = true;
        res.rgba = reconstructed;
        res.isBaseOnlyFallback = false;
        return res;
    }

    // Case B: Base Subgroup decode (Keyframe or Base-only fallback when Delta was shed)
    if (baseBytes.length == 0)
    {
        res.error = "Empty base layer bytes";
        return res;
    }

    QoivLayerKind baseKind;
    ubyte[] basePayload;
    string err;
    if (!unpackQoivChunk(baseBytes, baseKind, basePayload, err))
    {
        res.error = "Base chunk error: " ~ err;
        return res;
    }

    if (baseKind != QoivLayerKind.keyframe && baseKind != QoivLayerKind.baseAnchor)
    {
        res.error = "Invalid base chunk kind: expected keyframe or baseAnchor";
        return res;
    }

    auto qoiBase = decodeQoi(basePayload);
    if (!qoiBase.ok)
    {
        res.error = "Failed to decode QOI base layer: " ~ qoiBase.error;
        return res;
    }

    if (baseKind == QoivLayerKind.keyframe && (qoiBase.desc.width != width
            || qoiBase.desc.height != height))
    {
        res.error = "Keyframe dimensions do not match target dimensions";
        return res;
    }

    if (qoiBase.desc.width == width && qoiBase.desc.height == height)
    {
        res.ok = true;
        res.rgba = qoiBase.rgba;
        res.isBaseOnlyFallback = (baseKind != QoivLayerKind.keyframe);
        return res;
    }

    // Upscale downscaled Base Anchor to target dimensions
    ubyte[] upscaled = upscaleRgba(qoiBase.rgba, qoiBase.desc.width,
            qoiBase.desc.height, width, height);
    res.ok = true;
    res.rgba = upscaled;
    res.isBaseOnlyFallback = true;
    return res;
}

// Spec: Scenario T2 - Layered Delta-QOI (QOIV) Keyframe + Temporal Delta P-Frame round-trip (covers U2, W1, G1-G5)
/// Example:
unittest
{
    const uint width = 64;
    const uint height = 64;
    const size_t frameBytes = width * height * 4;

    ubyte[] frame0 = new ubyte[frameBytes];
    ubyte[] frame1 = new ubyte[frameBytes];

    // Static background: dark blue grid with green stripes
    foreach (y; 0 .. height)
    {
        foreach (x; 0 .. width)
        {
            size_t idx = (y * width + x) * 4;
            frame0[idx + 0] = 16;
            frame0[idx + 1] = cast(ubyte)((y % 8 == 0) ? 180 : 32);
            frame0[idx + 2] = 64;
            frame0[idx + 3] = 255;

            frame1[idx + 0] = frame0[idx + 0];
            frame1[idx + 1] = frame0[idx + 1];
            frame1[idx + 2] = frame0[idx + 2];
            frame1[idx + 3] = frame0[idx + 3];
        }
    }

    // Motion in Frame 0: 6x6 reticle at (10, 10)
    foreach (ry; 10 .. 16)
    {
        foreach (rx; 10 .. 16)
        {
            size_t idx = (ry * width + rx) * 4;
            frame0[idx + 0] = 255;
            frame0[idx + 1] = 200;
            frame0[idx + 2] = 50;
        }
    }

    // Motion in Frame 1: 6x6 reticle shifted to (14, 14)
    foreach (ry; 14 .. 20)
    {
        foreach (rx; 14 .. 20)
        {
            size_t idx = (ry * width + rx) * 4;
            frame1[idx + 0] = 255;
            frame1[idx + 1] = 200;
            frame1[idx + 2] = 50;
        }
    }

    // 1. Encode Frame 0 as Keyframe
    auto enc0 = encodeQoivFrame(frame0, null, width, height, true);
    assert(enc0.kind == QoivLayerKind.keyframe);
    assert(enc0.baseLayerBytes.length > 0);
    assert(enc0.deltaLayerBytes.length == 0);
    assert(enc0.rawBytes == frameBytes);
    assert(enc0.compressedBytes == enc0.baseLayerBytes.length);
    assert(enc0.compressionRatio > 3.0, "Keyframe must compress > 3x on graphic test pattern");

    // Decode Frame 0
    auto dec0 = decodeQoivFrame(enc0.baseLayerBytes, null, null, width, height);
    assert(dec0.ok, "Keyframe decode must succeed");
    assert(!dec0.isBaseOnlyFallback);
    assert(dec0.rgba == frame0, "Decoded Keyframe must match frame0 byte-for-byte");

    // 2. Encode Frame 1 as Layered Delta against Frame 0
    auto enc1 = encodeQoivFrame(frame1, dec0.rgba, width, height, false);
    assert(enc1.kind == QoivLayerKind.delta);
    assert(enc1.baseLayerBytes.length > 0, "Base anchor layer must be present");
    assert(enc1.deltaLayerBytes.length > 0, "Delta enhancement layer must be present");

    // Verify Delta layer achieves >= 10x compression over raw RGBA8
    const double deltaRatio = cast(double) frameBytes / cast(double) enc1.deltaLayerBytes.length;
    assert(deltaRatio >= 10.0, "Delta layer must achieve >= 10x compression on low-motion frame");

    // 3. Decode Frame 1 with both Base + Delta layers -> exact reconstruction
    auto dec1Full = decodeQoivFrame(enc1.baseLayerBytes, enc1.deltaLayerBytes,
            dec0.rgba, width, height);
    assert(dec1Full.ok, "Full Base+Delta decode must succeed");
    assert(!dec1Full.isBaseOnlyFallback);
    assert(dec1Full.rgba == frame1, "Full decode must reconstruct frame1 byte-for-byte");

    // 4. Decode Frame 1 with Base-only (simulating Home Wi-Fi stall dropping Delta Subgroup)
    auto dec1BaseOnly = decodeQoivFrame(enc1.baseLayerBytes, null, dec0.rgba, width, height);
    assert(dec1BaseOnly.ok, "Base-only decode must succeed as fallback");
    assert(dec1BaseOnly.isBaseOnlyFallback, "isBaseOnlyFallback flag must be set");
    assert(dec1BaseOnly.rgba.length == frameBytes,
            "Base-only fallback must produce a valid 64x64 frame");

    // 5. Unwanted behavior / error cases (W1, G5, Finding 1 & 3)
    assert(!decodeQoivFrame([], null, null, width, height).ok);
    assert(!decodeQoivFrame([0x00, 0x01], null, null, width, height).ok);
    assert(!decodeQoivFrame(enc0.baseLayerBytes, [0x01, 0x02], dec0.rgba, width, height).ok);

    // Corrupted zlib payload (flags = 1 with invalid data)
    ubyte[20] corruptedZlibChunk = [
        0x71, 0x6f, 0x69, 0x76, // "qoiv"
        cast(ubyte) QoivLayerKind.keyframe, 0x01, // flags = 1 (zlib)
        0x00, 0x00, 0x04, 0x00, // expectedLen = 1024
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff // invalid zlib stream
    ];
    assert(!decodeQoivFrame(corruptedZlibChunk, null, null, width, height).ok,
            "Must reject corrupted zlib chunk safely without throwing");

    // Zip-bomb test: uncompressed data exceeds declared expectedLen
    ubyte[] raw1k = new ubyte[1024];
    raw1k[] = 0xAA;
    ubyte[] compressed1k = safeZlibCompress(raw1k);
    assert(compressed1k !is null);
    ubyte[] bombChunk = new ubyte[10 + compressed1k.length];
    bombChunk[0 .. 4] = QOIV_MAGIC[];
    bombChunk[4] = cast(ubyte) QoivLayerKind.keyframe;
    bombChunk[5] = 1; // zlib compressed
    // Declare expectedLen = 100, which is strictly smaller than the 1024 uncompressed bytes in the stream
    bombChunk[6 .. 10] = [0, 0, 0, 100];
    bombChunk[10 .. $] = compressed1k[];
    assert(!decodeQoivFrame(bombChunk, null, null, width, height).ok,
            "Must reject decompression bomb payload exceeding declared expectedLen");

    // Zero expectedLen in chunk header
    ubyte[10] zeroLenChunk = [
        0x71, 0x6f, 0x69, 0x76, cast(ubyte) QoivLayerKind.keyframe, 0, 0, 0, 0, 0
    ];
    assert(!decodeQoivFrame(zeroLenChunk, null, null, width, height).ok,
            "Must reject chunk with zero expectedLen");

    // Invalid baseKind in base bytes (e.g. passing Delta chunk as base)
    assert(!decodeQoivFrame(enc1.deltaLayerBytes, null, dec0.rgba, width,
            height).ok, "Must reject delta chunk passed as base layer");
}
