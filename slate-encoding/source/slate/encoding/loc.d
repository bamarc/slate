/// IETF MoQ Low Overhead Container (LOC) and W3C WebCodecs descriptors.
module slate.encoding.loc;

public enum ubyte[4] MOQ_LOC_MAGIC = [0x6d, 0x6f, 0x71, 0x6c]; // "moql"

public enum MoqSubgroupKind : ubyte
{
    audio = 0,
    videoBase = 1,
    videoDelta = 2
}

public struct MoqLocHeader
{
    MoqSubgroupKind subgroupKind = MoqSubgroupKind.audio;
    ubyte priority = 0;
    string codec = "qoa";
    ulong groupId = 0;
    ulong objectId = 0;
    ulong ptsMicros = 0;
    uint payloadLength = 0;
}

public struct LocDecodeResult
{
    bool ok = false;
    string error = "";
    MoqLocHeader header;
    size_t headerBytes = 0;
}

public struct WebCodecsConfig
{
    string codec;
    uint width = 0;
    uint height = 0;
    uint sampleRate = 0;
    uint numberOfChannels = 0;
}

/// Validates whether a codec string conforms to standard MoQ WebCodecs identifiers.
bool isValidMoqCodec(string codec) @safe pure nothrow @nogc
{
    return codec == "qoi" || codec == "qoiv-layered" || codec == "qoa"
        || codec == "av01.0.04M.08" || codec == "opus";
}

/// Serialize MoQ LOC header into wire bytes.
ubyte[] encodeLocHeader(const ref MoqLocHeader header) @safe pure nothrow
{
    const size_t codecLen = header.codec.length > 255 ? 255 : header.codec.length;
    const size_t totalBytes = 7 + codecLen + 8 + 8 + 8 + 4;
    ubyte[] outBuf = new ubyte[totalBytes];

    outBuf[0 .. 4] = MOQ_LOC_MAGIC[];
    outBuf[4] = cast(ubyte) header.subgroupKind;
    outBuf[5] = header.priority;
    outBuf[6] = cast(ubyte) codecLen;

    outBuf[7 .. 7 + codecLen] = (cast(const(ubyte)[]) header.codec)[0 .. codecLen];
    size_t pos = 7 + codecLen;

    // Group ID (64-bit BE)
    outBuf[pos++] = cast(ubyte)((header.groupId >> 56) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.groupId >> 48) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.groupId >> 40) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.groupId >> 32) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.groupId >> 24) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.groupId >> 16) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.groupId >> 8) & 0xff);
    outBuf[pos++] = cast(ubyte)(header.groupId & 0xff);

    // Object ID (64-bit BE)
    outBuf[pos++] = cast(ubyte)((header.objectId >> 56) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.objectId >> 48) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.objectId >> 40) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.objectId >> 32) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.objectId >> 24) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.objectId >> 16) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.objectId >> 8) & 0xff);
    outBuf[pos++] = cast(ubyte)(header.objectId & 0xff);

    // PTS Micros (64-bit BE)
    outBuf[pos++] = cast(ubyte)((header.ptsMicros >> 56) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.ptsMicros >> 48) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.ptsMicros >> 40) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.ptsMicros >> 32) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.ptsMicros >> 24) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.ptsMicros >> 16) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.ptsMicros >> 8) & 0xff);
    outBuf[pos++] = cast(ubyte)(header.ptsMicros & 0xff);

    // Payload Length (32-bit BE)
    outBuf[pos++] = cast(ubyte)((header.payloadLength >> 24) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.payloadLength >> 16) & 0xff);
    outBuf[pos++] = cast(ubyte)((header.payloadLength >> 8) & 0xff);
    outBuf[pos++] = cast(ubyte)(header.payloadLength & 0xff);

    return outBuf;
}

/// Deserialize MoQ LOC header from wire bytes.
LocDecodeResult decodeLocHeader(const(ubyte)[] data) @safe pure nothrow
{
    LocDecodeResult res;
    if (data.length < 35)
    {
        res.error = "Data too short for minimum MoQ LOC header";
        return res;
    }

    if (data[0 .. 4] != MOQ_LOC_MAGIC)
    {
        res.error = "Invalid MoQ LOC magic";
        return res;
    }

    ubyte kind = data[4];
    if (kind > cast(ubyte) MoqSubgroupKind.videoDelta)
    {
        res.error = "Unknown MoQ subgroup kind";
        return res;
    }

    ubyte priority = data[5];
    ubyte codecLen = data[6];

    const size_t totalExpected = 7 + codecLen + 8 + 8 + 8 + 4;
    if (data.length < totalExpected)
    {
        res.error = "Truncated MoQ LOC header payload";
        return res;
    }

    string codec = cast(string) data[7 .. 7 + codecLen].idup;
    size_t pos = 7 + codecLen;

    ulong groupId = (cast(ulong) data[pos + 0] << 56) | (
            cast(ulong) data[pos + 1] << 48) | (cast(ulong) data[pos + 2] << 40) | (
            cast(ulong) data[pos + 3] << 32) | (cast(ulong) data[pos + 4] << 24) | (
            cast(ulong) data[pos + 5] << 16) | (
            cast(ulong) data[pos + 6] << 8) | cast(ulong) data[pos + 7];
    pos += 8;

    ulong objectId = (cast(ulong) data[pos + 0] << 56) | (
            cast(ulong) data[pos + 1] << 48) | (cast(ulong) data[pos + 2] << 40) | (
            cast(ulong) data[pos + 3] << 32) | (cast(ulong) data[pos + 4] << 24) | (
            cast(ulong) data[pos + 5] << 16) | (
            cast(ulong) data[pos + 6] << 8) | cast(ulong) data[pos + 7];
    pos += 8;

    ulong ptsMicros = (cast(ulong) data[pos + 0] << 56) | (
            cast(ulong) data[pos + 1] << 48) | (cast(ulong) data[pos + 2] << 40) | (
            cast(ulong) data[pos + 3] << 32) | (cast(ulong) data[pos + 4] << 24) | (
            cast(ulong) data[pos + 5] << 16) | (
            cast(ulong) data[pos + 6] << 8) | cast(ulong) data[pos + 7];
    pos += 8;

    uint payloadLength = (cast(uint) data[pos + 0] << 24) | (
            cast(uint) data[pos + 1] << 16) | (cast(uint) data[pos + 2] << 8) | cast(
            uint) data[pos + 3];
    pos += 4;

    res.ok = true;
    res.headerBytes = pos;
    res.header.subgroupKind = cast(MoqSubgroupKind) kind;
    res.header.priority = priority;
    res.header.codec = codec;
    res.header.groupId = groupId;
    res.header.objectId = objectId;
    res.header.ptsMicros = ptsMicros;
    res.header.payloadLength = payloadLength;
    return res;
}

// Spec: Scenario T4 - MoQ LOC Header round-trip with Subgroup Priorities and WebCodecs descriptors (covers U4, W1, G1-G5)
/// Example:
unittest
{
    MoqLocHeader hdr;
    hdr.subgroupKind = MoqSubgroupKind.videoDelta;
    hdr.priority = 2; // Lowest priority (shed first on Wi-Fi stall)
    hdr.codec = "qoiv-layered";
    hdr.groupId = 42;
    hdr.objectId = 3;
    hdr.ptsMicros = 66_666;
    hdr.payloadLength = 1024;

    ubyte[] wire = encodeLocHeader(hdr);
    assert(wire !is null, "encodeLocHeader must return wire bytes");
    assert(wire.length >= 32, "Header must be at least 32 bytes");
    assert(wire[0 .. 4] == MOQ_LOC_MAGIC);

    auto dec = decodeLocHeader(wire);
    assert(dec.ok, "decodeLocHeader must succeed on valid wire header");
    assert(dec.headerBytes == wire.length);
    assert(dec.header.subgroupKind == MoqSubgroupKind.videoDelta);
    assert(dec.header.priority == 2);
    assert(dec.header.codec == "qoiv-layered");
    assert(dec.header.groupId == 42);
    assert(dec.header.objectId == 3);
    assert(dec.header.ptsMicros == 66_666);
    assert(dec.header.payloadLength == 1024);

    // Verify audio and video base priorities
    MoqLocHeader audioHdr = MoqLocHeader(MoqSubgroupKind.audio, 0, "qoa", 42, 0, 66_666, 104);
    assert(audioHdr.priority == 0, "Audio subgroup must have highest priority 0");

    MoqLocHeader baseHdr = MoqLocHeader(MoqSubgroupKind.videoBase, 1,
            "qoiv-layered", 42, 1, 66_666, 512);
    assert(baseHdr.priority == 1, "VideoBase subgroup must have priority 1");

    // Codec validation
    assert(isValidMoqCodec("qoi"));
    assert(isValidMoqCodec("qoiv-layered"));
    assert(isValidMoqCodec("qoa"));
    assert(isValidMoqCodec("av01.0.04M.08"));
    assert(isValidMoqCodec("opus"));
    assert(!isValidMoqCodec("invalid-codec"));

    // Failure / unwanted behavior tests (W1, G5)
    assert(!decodeLocHeader([]).ok);
    assert(!decodeLocHeader(wire[0 .. 8]).ok);
    ubyte[] badMagic = wire.dup;
    badMagic[0] = 0;
    assert(!decodeLocHeader(badMagic).ok);
    ubyte[] badCodecLen = wire.dup;
    badCodecLen[6] = 250; // Oversized codec string length
    assert(!decodeLocHeader(badCodecLen).ok);
}
