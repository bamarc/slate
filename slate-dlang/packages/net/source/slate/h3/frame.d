module slate.h3.frame;

/**
 * HTTP/3 Framing Layer and SETTINGS Codec (RFC 9114 Section 7).
 *
 * Implements frame header encoding/decoding, SETTINGS payload codec with duplicate
 * and reserved HTTP/2 setting detection, GOAWAY payload codec, and GREASE handling.
 */

public import slate.h3.error;
public import slate.quic.wire.varint : encodeVarInt, decodeVarInt, varIntLen,
    VARINT_MAX, WireError;

public enum H3FrameType : ulong
{
    data = 0x00,
    headers = 0x01,
    cancelPush = 0x03,
    settings = 0x04,
    pushPromise = 0x05,
    goaway = 0x07,
    maxPushId = 0x0d
}

/**
 * Returns true if the frame type is a reserved HTTP/2 frame type (RFC 9114 Section 7.2.8).
 * Receipt of these frame types MUST be treated as a connection error of type H3_FRAME_UNEXPECTED.
 */
public bool isReservedH2FrameType(ulong type) @safe pure nothrow @nogc
{
    return (type == 0x02 || type == 0x06 || type == 0x08 || type == 0x09);
}

public enum H3SettingId : ulong
{
    qpackMaxTableCapacity = 0x01,
    maxFieldSectionSize = 0x06,
    qpackBlockedStreams = 0x07
}

/**
 * Returns true if the setting ID is a reserved HTTP/2 setting ID (RFC 9114 Section 7.2.4.1).
 * Receipt of these setting IDs MUST be treated as a connection error of type H3_SETTINGS_ERROR.
 */
public bool isReservedH2SettingId(ulong id) @safe pure nothrow @nogc
{
    return (id == 0x00 || id == 0x02 || id == 0x03 || id == 0x04 || id == 0x05);
}

/**
 * Parsed HTTP/3 SETTINGS values.
 */
public struct H3Settings
{
    ulong qpackMaxTableCapacity = 0;
    ulong maxFieldSectionSize = ulong.max;
    ulong qpackBlockedStreams = 0;
}

/**
 * Decoded HTTP/3 frame header (Type + Length).
 */
public struct H3FrameHeader
{
    ulong type;
    ulong length;
}

/**
 * Encodes an HTTP/3 frame header (Type [varint] + Length [varint]) into outBuf.
 */
public bool encodeH3FrameHeader(ulong type, ulong length, ubyte[] outBuf, out size_t bytesWritten) @safe pure nothrow @nogc
{
    bytesWritten = 0;
    if (type > VARINT_MAX || length > VARINT_MAX)
        return false;

    const size_t typeLen = varIntLen(type);
    const size_t lenLen = varIntLen(length);
    if (outBuf.length < typeLen + lenLen)
        return false;

    size_t w1 = 0;
    if (encodeVarInt(type, outBuf[0 .. typeLen], w1) != WireError.none)
        return false;

    size_t w2 = 0;
    if (encodeVarInt(length, outBuf[typeLen .. typeLen + lenLen], w2) != WireError.none)
        return false;

    bytesWritten = w1 + w2;
    return true;
}

/**
 * Decodes an HTTP/3 frame header from input starting at offset.
 * Validates that the frame type is not a forbidden HTTP/2 frame type.
 */
public H3ErrorCode decodeH3FrameHeader(const(ubyte)[] input, ref size_t offset,
        out H3FrameHeader header) @safe pure nothrow @nogc
{
    header = H3FrameHeader.init;
    if (offset >= input.length)
        return H3ErrorCode.frameError;

    size_t readOffset = offset;
    ulong type = 0;
    size_t consumed = 0;
    if (decodeVarInt(input[readOffset .. $], type, consumed) != WireError.none)
        return H3ErrorCode.frameError;
    readOffset += consumed;

    ulong len = 0;
    consumed = 0;
    if (decodeVarInt(input[readOffset .. $], len, consumed) != WireError.none)
        return H3ErrorCode.frameError;
    readOffset += consumed;

    if (isReservedH2FrameType(type))
        return H3ErrorCode.frameUnexpected;

    header.type = type;
    header.length = len;
    offset = readOffset;
    return H3ErrorCode.noError;
}

/**
 * Encodes an H3Settings payload into outBuf.
 * Optionally appends a GREASE setting (0x21) to verify peer interoperability.
 */
public bool encodeSettingsPayload(const ref H3Settings settings, ubyte[] outBuf,
        out size_t bytesWritten, bool includeGrease = false) @safe pure nothrow @nogc
{
    bytesWritten = 0;
    size_t offset = 0;

    // Helper closure
    bool writePair(ulong id, ulong val)
    {
        const size_t idLen = varIntLen(id);
        const size_t valLen = varIntLen(val);
        if (offset + idLen + valLen > outBuf.length)
            return false;

        size_t w = 0;
        if (encodeVarInt(id, outBuf[offset .. offset + idLen], w) != WireError.none)
            return false;
        offset += w;

        if (encodeVarInt(val, outBuf[offset .. offset + valLen], w) != WireError.none)
            return false;
        offset += w;
        return true;
    }

    if (!writePair(H3SettingId.qpackMaxTableCapacity, settings.qpackMaxTableCapacity))
        return false;

    if (settings.maxFieldSectionSize != ulong.max)
    {
        if (!writePair(H3SettingId.maxFieldSectionSize, settings.maxFieldSectionSize))
            return false;
    }

    if (!writePair(H3SettingId.qpackBlockedStreams, settings.qpackBlockedStreams))
        return false;

    if (includeGrease)
    {
        if (!writePair(0x21, 0)) // GREASE setting (0x1f * 0 + 0x21)
            return false;
    }

    bytesWritten = offset;
    return true;
}

/**
 * Decodes an HTTP/3 SETTINGS frame payload (RFC 9114 Section 7.2.4.1).
 * Enforces detection of duplicate setting identifiers and forbidden HTTP/2 setting identifiers.
 * Unknown or GREASE setting identifiers are safely ignored.
 */
public H3ErrorCode decodeSettingsPayload(const(ubyte)[] payload, out H3Settings settings) @safe pure nothrow @nogc
{
    settings = H3Settings.init;

    enum size_t MAX_SETTINGS_TRACKED = 64;
    ulong[MAX_SETTINGS_TRACKED] seenIds;
    size_t seenCount = 0;

    size_t offset = 0;
    while (offset < payload.length)
    {
        ulong id = 0;
        size_t consumed = 0;
        if (decodeVarInt(payload[offset .. $], id, consumed) != WireError.none)
            return H3ErrorCode.frameError;
        offset += consumed;

        ulong val = 0;
        consumed = 0;
        if (decodeVarInt(payload[offset .. $], val, consumed) != WireError.none)
            return H3ErrorCode.frameError;
        offset += consumed;

        // RFC 9114 Section 7.2.4.1: Reject forbidden HTTP/2 settings
        if (isReservedH2SettingId(id))
            return H3ErrorCode.settingsError;

        // RFC 9114 Section 7.2.4.1: Reject duplicate settings
        foreach (i; 0 .. seenCount)
        {
            if (seenIds[i] == id)
                return H3ErrorCode.settingsError;
        }

        if (seenCount >= MAX_SETTINGS_TRACKED)
            return H3ErrorCode.settingsError;
        seenIds[seenCount++] = id;

        // Store recognized settings
        if (id == H3SettingId.qpackMaxTableCapacity)
            settings.qpackMaxTableCapacity = val;
        else if (id == H3SettingId.maxFieldSectionSize)
            settings.maxFieldSectionSize = val;
        else if (id == H3SettingId.qpackBlockedStreams)
            settings.qpackBlockedStreams = val;
        // Unknown or GREASE setting IDs are cleanly ignored
    }

    return H3ErrorCode.noError;
}

/**
 * Encodes a GOAWAY frame payload (Stream ID [varint]).
 */
public bool encodeGoawayPayload(ulong streamId, ubyte[] outBuf, out size_t bytesWritten) @safe pure nothrow @nogc
{
    bytesWritten = 0;
    if (streamId > VARINT_MAX)
        return false;

    const size_t len = varIntLen(streamId);
    if (outBuf.length < len)
        return false;

    return encodeVarInt(streamId, outBuf[0 .. len], bytesWritten) == WireError.none;
}

/**
 * Decodes a GOAWAY frame payload (Stream ID [varint]).
 * Ensures no trailing bytes exist in the payload (RFC 9114 Section 7.2.6).
 */
public H3ErrorCode decodeGoawayPayload(const(ubyte)[] payload, out ulong streamId) @safe pure nothrow @nogc
{
    streamId = 0;
    if (payload.length == 0)
        return H3ErrorCode.frameError;

    size_t consumed = 0;
    if (decodeVarInt(payload, streamId, consumed) != WireError.none)
        return H3ErrorCode.frameError;

    if (consumed != payload.length)
        return H3ErrorCode.frameError; // Trailing garbage

    return H3ErrorCode.noError;
}

/// Example:
// Spec: RFC 9114 Section 7.2, Section 7.2.8 - Frame Header Codec & HTTP/2 Forbidden Frame Rejection (covers Scenario T2, U1, U3, E2, W1, F3)
@nogc unittest
{
    ubyte[32] buf;
    size_t written = 0;

    // 1. Valid DATA frame header (type=0x00, len=1024)
    assert(encodeH3FrameHeader(H3FrameType.data, 1024, buf[], written));
    assert(written > 0);

    size_t offset = 0;
    H3FrameHeader hdr;
    assert(decodeH3FrameHeader(buf[0 .. written], offset, hdr) == H3ErrorCode.noError);
    assert(hdr.type == H3FrameType.data);
    assert(hdr.length == 1024);
    assert(offset == written);

    // 2. Valid HEADERS frame header (type=0x01, len=256)
    offset = 0;
    assert(encodeH3FrameHeader(H3FrameType.headers, 256, buf[], written));
    assert(decodeH3FrameHeader(buf[0 .. written], offset, hdr) == H3ErrorCode.noError);
    assert(hdr.type == H3FrameType.headers);
    assert(hdr.length == 256);

    // 3. GREASE frame header (type = 0x21, len=50)
    offset = 0;
    assert(encodeH3FrameHeader(0x21, 50, buf[], written));
    assert(decodeH3FrameHeader(buf[0 .. written], offset, hdr) == H3ErrorCode.noError);
    assert(hdr.type == 0x21);
    assert(hdr.length == 50);

    // 4. Round-trip settings, goaway, cancelPush, pushPromise, maxPushId, and GREASE 0x40
    const ulong[6] standardAndGrease = [
        cast(ulong) H3FrameType.settings, cast(ulong) H3FrameType.goaway,
        cast(ulong) H3FrameType.cancelPush, cast(ulong) H3FrameType.pushPromise,
        cast(ulong) H3FrameType.maxPushId, 0x40
    ];
    foreach (ftype; standardAndGrease)
    {
        offset = 0;
        assert(encodeH3FrameHeader(ftype, 128, buf[], written));
        assert(decodeH3FrameHeader(buf[0 .. written], offset, hdr) == H3ErrorCode.noError);
        assert(hdr.type == ftype);
        assert(hdr.length == 128);
    }

    // 5. Forbidden HTTP/2 frame types: 0x02 (PRIORITY), 0x06 (PING), 0x08 (WINDOW_UPDATE), 0x09 (CONTINUATION)
    const ulong[4] forbiddenH2Frames = [0x02, 0x06, 0x08, 0x09];
    foreach (h2Type; forbiddenH2Frames)
    {
        assert(isReservedH2FrameType(h2Type));
        offset = 0;
        assert(encodeH3FrameHeader(h2Type, 0, buf[], written));
        assert(decodeH3FrameHeader(buf[0 .. written], offset, hdr) == H3ErrorCode.frameUnexpected);
    }
}

/// Example:
// Spec: RFC 9114 Section 7.2.4.1, Section 9 - SETTINGS Payload Codec, GREASE Skipping & Forbidden Settings (covers Scenario T2, U1, U3, E2, W2, F3)
@nogc unittest
{
    ubyte[128] buf;
    size_t written = 0;

    H3Settings sendSettings;
    sendSettings.qpackMaxTableCapacity = 4096;
    sendSettings.maxFieldSectionSize = 16384;
    sendSettings.qpackBlockedStreams = 16;

    // Encode with GREASE setting 0x21 included
    assert(encodeSettingsPayload(sendSettings, buf[], written, true));
    assert(written > 0);

    H3Settings recvSettings;
    assert(decodeSettingsPayload(buf[0 .. written], recvSettings) == H3ErrorCode.noError);
    assert(recvSettings.qpackMaxTableCapacity == 4096);
    assert(recvSettings.maxFieldSectionSize == 16384);
    assert(recvSettings.qpackBlockedStreams == 16);

    // Forbidden HTTP/2 setting IDs: 0x00, 0x02, 0x03, 0x04, 0x05
    const ulong[5] forbiddenH2Settings = [0x00, 0x02, 0x03, 0x04, 0x05];
    foreach (h2Set; forbiddenH2Settings)
    {
        assert(isReservedH2SettingId(h2Set));
        ubyte[16] badBuf;
        size_t bw = 0;
        size_t w = 0;
        assert(encodeVarInt(h2Set, badBuf[0 .. 4], w) == WireError.none);
        bw += w;
        assert(encodeVarInt(100, badBuf[bw .. $], w) == WireError.none);
        bw += w;

        assert(decodeSettingsPayload(badBuf[0 .. bw], recvSettings) == H3ErrorCode.settingsError);
    }

    // Duplicate setting ID rejection
    ubyte[16] dupBuf;
    size_t dw = 0;
    size_t w = 0;
    // Setting 0x01 = 100
    assert(encodeVarInt(0x01, dupBuf[dw .. $], w) == WireError.none);
    dw += w;
    assert(encodeVarInt(100, dupBuf[dw .. $], w) == WireError.none);
    dw += w;
    // Duplicate setting 0x01 = 200
    assert(encodeVarInt(0x01, dupBuf[dw .. $], w) == WireError.none);
    dw += w;
    assert(encodeVarInt(200, dupBuf[dw .. $], w) == WireError.none);
    dw += w;

    assert(decodeSettingsPayload(dupBuf[0 .. dw], recvSettings) == H3ErrorCode.settingsError);

    // >32 settings duplicate detection (D3 / [HIGH-5])
    ubyte[512] manySettingsBuf;
    size_t msw = 0;
    foreach (i; 0 .. 35)
    {
        const ulong greaseId = 0x1f * i + 0x21;
        assert(encodeVarInt(greaseId, manySettingsBuf[msw .. $], w) == WireError.none);
        msw += w;
        assert(encodeVarInt(i, manySettingsBuf[msw .. $], w) == WireError.none);
        msw += w;
    }
    // Duplicate of first GREASE setting (0x21) at setting index 36 (> 32)
    assert(encodeVarInt(0x21, manySettingsBuf[msw .. $], w) == WireError.none);
    msw += w;
    assert(encodeVarInt(999, manySettingsBuf[msw .. $], w) == WireError.none);
    msw += w;
    assert(decodeSettingsPayload(manySettingsBuf[0 .. msw],
            recvSettings) == H3ErrorCode.settingsError);
}

/// Example:
// Spec: RFC 9114 Section 7.2.6 - GOAWAY Payload Codec & Strict Trailing Byte Enforcement (covers Scenario T2, U1, U3, E2)
@nogc unittest
{
    ubyte[16] buf;
    size_t written = 0;

    assert(encodeGoawayPayload(4, buf[], written));
    assert(written == 1);
    assert(buf[0] == 4);

    ulong streamId = 0;
    assert(decodeGoawayPayload(buf[0 .. written], streamId) == H3ErrorCode.noError);
    assert(streamId == 4);

    // Payload with trailing garbage byte
    ubyte[2] badGoaway = [0x04, 0xFF];
    assert(decodeGoawayPayload(badGoaway[], streamId) == H3ErrorCode.frameError);

    // Empty payload
    assert(decodeGoawayPayload(null, streamId) == H3ErrorCode.frameError);
}
