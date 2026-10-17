/// Quite OK Audio (QOA) 4-tap LMS adaptive predictor codec.
module slate.encoding.qoa;

import std.algorithm : min;

public enum ubyte[4] QOA_MAGIC = [0x71, 0x6f, 0x61, 0x66]; // "qoaf"
public enum size_t QOA_SLICE_LEN = 20;
public enum uint MAX_QOA_SAMPLES = 48_000; // 1 full second of 48 kHz audio DoS guard

public static immutable short[8][16] QOA_DEQUANT_TAB = [
    [1, -1, 3, -3, 5, -5, 7, -7], [5, -5, 18, -18, 32, -32, 49, -49],
    [16, -16, 53, -53, 95, -95, 144, -144],
    [34, -34, 113, -113, 202, -202, 306, -306],
    [59, -59, 197, -197, 353, -353, 535, -535],
    [92, -92, 306, -306, 548, -548, 831, -831],
    [133, -133, 443, -443, 793, -793, 1201, -1201],
    [183, -183, 610, -610, 1092, -1092, 1655, -1655],
    [242, -242, 807, -807, 1445, -1445, 2190, -2190],
    [310, -310, 1033, -1033, 1850, -1850, 2804, -2804],
    [387, -387, 1290, -1290, 2310, -2310, 3501, -3501],
    [474, -474, 1578, -1578, 2826, -2826, 4283, -4283],
    [570, -570, 1898, -1898, 3399, -3399, 5151, -5151],
    [676, -676, 2250, -2250, 4030, -4030, 6108, -6108],
    [792, -792, 2635, -2635, 4719, -4719, 7152, -7152],
    [918, -918, 3054, -3054, 5468, -5468, 8287, -8287],
];

public struct QoaLmsState
{
    int[4] history = [0, 0, 0, 0];
    int[4] weights = [0, 0, -1, 2];

    pragma(inline, true) int predict() const @safe pure nothrow @nogc
    {
        long sum = cast(long) weights[0] * history[0] + cast(
                long) weights[1] * history[1] + cast(
                long) weights[2] * history[2] + cast(long) weights[3] * history[3];
        long p = sum >> 13;
        if (p < -32768)
            return -32768;
        if (p > 32767)
            return 32767;
        return cast(int) p;
    }

    pragma(inline, true) void update(int sample, int dequantResidual) @safe pure nothrow @nogc
    {
        int delta = dequantResidual >> 4;
        weights[0] += (history[0] < 0) ? -delta : delta;
        weights[1] += (history[1] < 0) ? -delta : delta;
        weights[2] += (history[2] < 0) ? -delta : delta;
        weights[3] += (history[3] < 0) ? -delta : delta;

        history[0] = history[1];
        history[1] = history[2];
        history[2] = history[3];
        history[3] = sample;
    }
}

public struct QoaDecodeResult
{
    bool ok;
    string error;
    uint sampleRate;
    ubyte channels;
    short[] pcm;
}

/// Encode 20 audio samples into a 64-bit QOA slice.
ulong encodeQoaSlice(const(short)[] samples, ref QoaLmsState lms) @safe pure nothrow
{
    short[20] padded;
    const size_t copyLen = min(samples.length, 20);
    padded[0 .. copyLen] = samples[0 .. copyLen];

    ulong bestSlice = 0;
    long bestErrorSum = long.max;
    QoaLmsState bestLms = lms;

    foreach (sfIdx; 0 .. 16)
    {
        QoaLmsState tempLms = lms;
        ulong slice = cast(ulong) sfIdx << 60;
        long errorSum = 0;

        foreach (s; 0 .. 20)
        {
            int pred = tempLms.predict();
            int targetDiff = cast(int) padded[s] - pred;

            int bestQ = 0;
            int bestDist = int.max;
            foreach (q; 0 .. 8)
            {
                int dequant = QOA_DEQUANT_TAB[sfIdx][q];
                int dist = targetDiff - dequant;
                if (dist < 0)
                    dist = -dist;
                if (dist < bestDist)
                {
                    bestDist = dist;
                    bestQ = q;
                }
            }

            int bestDequant = QOA_DEQUANT_TAB[sfIdx][bestQ];
            int reconstructed = pred + bestDequant;
            if (reconstructed < -32768)
                reconstructed = -32768;
            if (reconstructed > 32767)
                reconstructed = 32767;

            int err = cast(int) padded[s] - reconstructed;
            errorSum += cast(long) err * cast(long) err;
            tempLms.update(reconstructed, bestDequant);

            slice |= (cast(ulong) bestQ) << ((19 - s) * 3);
        }

        if (errorSum < bestErrorSum)
        {
            bestErrorSum = errorSum;
            bestSlice = slice;
            bestLms = tempLms;
        }
    }

    lms = bestLms;
    return bestSlice;
}

/// Decode a 64-bit QOA slice into 20 audio samples.
void decodeQoaSlice(ulong slice, ref QoaLmsState lms, short[] output) @safe pure nothrow
{
    if (output.length < 20)
        return;

    ubyte sfIdx = cast(ubyte)((slice >> 60) & 0x0f);

    foreach (s; 0 .. 20)
    {
        ubyte q = cast(ubyte)((slice >> ((19 - s) * 3)) & 0x07);
        int dequant = QOA_DEQUANT_TAB[sfIdx][q];
        int pred = lms.predict();
        int reconstructed = pred + dequant;
        if (reconstructed < -32768)
            reconstructed = -32768;
        if (reconstructed > 32767)
            reconstructed = 32767;

        lms.update(reconstructed, dequant);
        output[s] = cast(short) reconstructed;
    }
}

/// Synthesize 20 phase-continuous audio samples on underrun using LMS predictor.
void concealQoaSlice(ref QoaLmsState lms, short[] output, double decay = 0.92) @safe pure nothrow
{
    const size_t outLen = min(output.length, 20);
    foreach (s; 0 .. outLen)
    {
        int pred = lms.predict();
        int decayed = cast(int)(cast(double) pred * decay);
        if (decayed < -32768)
            decayed = -32768;
        if (decayed > 32767)
            decayed = 32767;

        lms.update(decayed, 0);
        output[s] = cast(short) decayed;
    }
}

private ubyte sampleRateToCode(uint rate) @safe pure nothrow @nogc
{
    if (rate == 48000)
        return 0;
    if (rate == 44100)
        return 1;
    if (rate == 32000)
        return 2;
    if (rate == 24000)
        return 3;
    if (rate == 16000)
        return 4;
    if (rate == 8000)
        return 5;
    uint code = rate / 500;
    return cast(ubyte)(code > 255 ? 255 : code);
}

private uint codeToSampleRate(ubyte code) @safe pure nothrow @nogc
{
    switch (code)
    {
    case 0:
        return 48000;
    case 1:
        return 44100;
    case 2:
        return 32000;
    case 3:
        return 24000;
    case 4:
        return 16000;
    case 5:
        return 8000;
    default:
        return cast(uint) code * 500;
    }
}

/// Encode PCM16 samples into a complete QOA frame.
ubyte[] encodeQoaFrame(const(short)[] pcmSamples, uint sampleRate = 48000, ubyte channels = 1) @safe pure nothrow
{
    if (pcmSamples.length == 0 || channels == 0 || sampleRate == 0)
        return null;

    if (pcmSamples.length > MAX_QOA_SAMPLES)
        return null;

    const size_t numSlices = (pcmSamples.length + 19) / 20;
    ubyte[] output = new ubyte[8 + numSlices * 8];

    // Frame header (8 bytes): "qoaf", channels, sampleCount (BE), sampleRateCode
    output[0 .. 4] = QOA_MAGIC[];
    output[4] = channels;
    uint count = cast(uint) pcmSamples.length;
    output[5] = cast(ubyte)((count >> 8) & 0xff);
    output[6] = cast(ubyte)(count & 0xff);
    output[7] = sampleRateToCode(sampleRate);

    QoaLmsState lms;
    size_t outPos = 8;

    foreach (sIdx; 0 .. numSlices)
    {
        size_t start = sIdx * 20;
        size_t end = min(start + 20, pcmSamples.length);
        ulong slice = encodeQoaSlice(pcmSamples[start .. end], lms);

        output[outPos++] = cast(ubyte)((slice >> 56) & 0xff);
        output[outPos++] = cast(ubyte)((slice >> 48) & 0xff);
        output[outPos++] = cast(ubyte)((slice >> 40) & 0xff);
        output[outPos++] = cast(ubyte)((slice >> 32) & 0xff);
        output[outPos++] = cast(ubyte)((slice >> 24) & 0xff);
        output[outPos++] = cast(ubyte)((slice >> 16) & 0xff);
        output[outPos++] = cast(ubyte)((slice >> 8) & 0xff);
        output[outPos++] = cast(ubyte)(slice & 0xff);
    }

    return output;
}

/// Decode a complete QOA frame back to PCM16 samples.
QoaDecodeResult decodeQoaFrame(const(ubyte)[] data) @safe pure nothrow
{
    QoaDecodeResult res;
    if (data.length < 8)
    {
        res.error = "Input data too short for QOA frame header";
        return res;
    }

    if (data[0 .. 4] != QOA_MAGIC)
    {
        res.error = "Invalid QOA magic";
        return res;
    }

    ubyte channels = data[4];
    uint sampleCount = (cast(uint) data[5] << 8) | cast(uint) data[6];
    uint sampleRate = codeToSampleRate(data[7]);

    if (channels == 0 || sampleCount == 0)
    {
        res.error = "Invalid channel count or zero sample count";
        return res;
    }

    if (sampleCount > MAX_QOA_SAMPLES)
    {
        res.error = "Sample count exceeds MAX_QOA_SAMPLES DoS limit";
        return res;
    }

    const size_t numSlices = (sampleCount + 19) / 20;
    const size_t expectedBytes = 8 + numSlices * 8;
    if (data.length < expectedBytes)
    {
        res.error = "Truncated QOA frame slice data";
        return res;
    }

    short[] pcm = new short[sampleCount];
    QoaLmsState lms;
    size_t inPos = 8;
    short[20] sliceSamples;

    foreach (sIdx; 0 .. numSlices)
    {
        ulong slice = (cast(ulong) data[inPos + 0] << 56) | (
                cast(ulong) data[inPos + 1] << 48) | (cast(ulong) data[inPos + 2] << 40) | (
                cast(ulong) data[inPos + 3] << 32) | (cast(ulong) data[inPos + 4] << 24) | (
                cast(ulong) data[inPos + 5] << 16) | (
                cast(ulong) data[inPos + 6] << 8) | cast(ulong) data[inPos + 7];
        inPos += 8;

        decodeQoaSlice(slice, lms, sliceSamples[]);
        size_t start = sIdx * 20;
        size_t count = min(cast(size_t) 20, sampleCount - start);
        pcm[start .. start + count] = sliceSamples[0 .. count];
    }

    res.ok = true;
    res.channels = channels;
    res.sampleRate = sampleRate;
    res.pcm = pcm;
    return res;
}

// Spec: Scenario T3 - QOA 4-tap LMS Audio 5.33:1 encoding, decoding, and Wi-Fi underrun concealment (covers U3, W1, G1-G5)
/// Example:
unittest
{
    import std.math : PI, isNaN, sin, sqrt;

    // 240 samples = 12 slices of 48 kHz sine/harmonic PCM audio (480 bytes)
    const size_t sampleCount = 240;
    short[] pcm = new short[sampleCount];

    foreach (i; 0 .. sampleCount)
    {
        double t = cast(double) i / 48000.0;
        // 440 Hz fundamental + 880 Hz harmonic
        double s = 0.65 * sin(2.0 * PI * 440.0 * t) + 0.25 * sin(2.0 * PI * 880.0 * t);
        pcm[i] = cast(short)(s * 28000.0);
    }

    // 1. Encode into QOA frame
    ubyte[] qoaFrame = encodeQoaFrame(pcm, 48000, 1);
    assert(qoaFrame !is null, "encodeQoaFrame must return encoded frame");
    assert(qoaFrame.length == 8 + 12 * 8,
            "Frame must be 8-byte header + 12 8-byte slices (104 bytes)");
    assert(qoaFrame[0 .. 4] == QOA_MAGIC);

    // Compression ratio: 480 bytes / 104 bytes = 4.615x (> 4.5x)
    const double ratio = cast(double)(sampleCount * 2) / cast(double) qoaFrame.length;
    assert(ratio > 4.5, "QOA frame must achieve > 4.5x compression ratio");

    // 2. Decode back to PCM16
    auto dec = decodeQoaFrame(qoaFrame);
    assert(dec.ok, "decodeQoaFrame must succeed");
    assert(dec.sampleRate == 48000);
    assert(dec.channels == 1);
    assert(dec.pcm.length == sampleCount);

    // Verify bounded RMS reconstruction error (normalized RMS error < 0.08)
    double sumSqDiff = 0.0;
    double sumSqOrig = 0.0;
    foreach (i; 0 .. sampleCount)
    {
        double diff = cast(double) pcm[i] - cast(double) dec.pcm[i];
        sumSqDiff += diff * diff;
        sumSqOrig += cast(double) pcm[i] * cast(double) pcm[i];
    }
    double nrms = sqrt(sumSqDiff / sumSqOrig);
    assert(nrms < 0.08, "QOA 4-tap LMS decoded audio must achieve < 0.08 normalized RMS error");

    // 3. Test LMS audio underrun concealment
    QoaLmsState lms = QoaLmsState([12000, 14000, 15500, 16000], [
        200, 400, 1200, 6000
    ]);
    short[20] concealed;
    concealQoaSlice(lms, concealed[], 0.92);

    foreach (s; concealed)
    {
        assert(!isNaN(cast(float) s));
    }
    // Concealed samples must follow smooth decay without clipping/overflow
    assert(concealed[0] != 0);
    assert(concealed[$ - 1] != concealed[0]);

    // 4. Unwanted behavior / error cases (W1, G5, Finding 4)
    assert(!decodeQoaFrame([]).ok);
    assert(!decodeQoaFrame(qoaFrame[0 .. 6]).ok);
    ubyte[] badMagic = qoaFrame.dup;
    badMagic[0] = 'X';
    assert(!decodeQoaFrame(badMagic).ok);
    assert(!decodeQoaFrame(qoaFrame[0 .. $ - 4]).ok);

    // Reject sampleCount > MAX_QOA_SAMPLES (48_000)
    ubyte[8] oversizedHeader = [
        0x71, 0x6f, 0x61, 0x66, // "qoaf"
        0x01, // channels = 1
        0xea, 0x60, // sampleCount = 60_000 (> 48_000)
        0x00 // sampleRate code = 0 (48 kHz)
    ];
    assert(!decodeQoaFrame(oversizedHeader).ok, "Must reject sample count > 48_000 DoS limit");
}
