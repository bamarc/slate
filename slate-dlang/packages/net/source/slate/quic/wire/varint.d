module slate.quic.wire.varint;

/**
 * QUIC Variable-Length Integer and Buffer Cursors (RFC 9000 Section 16).
 *
 * Implements 62-bit variable-length integer encoding and decoding,
 * fixed-width encoding, and zero-allocation slice cursors.
 */

public enum ulong VARINT_MAX = (1UL << 62) - 1;

public enum WireError : ubyte
{
    none = 0,
    unexpectedEof,
    varIntOverflow,
    bufferTooSmall,
    invalidPacketHeader,
    reservedBitsSet,
    invalidFrame,
    forbiddenFrameInPacket,
    transportParameterError
}

/**
 * Computes the minimum number of bytes needed to encode a VarInt (RFC 9000 Section 16).
 *
 * Returns 0 if v exceeds VARINT_MAX.
 */
size_t varIntLen(ulong v) @safe pure @nogc nothrow
{
    if (v <= 0x3fUL)
        return 1;
    if (v <= 0x3fffUL)
        return 2;
    if (v <= 0x3fff_ffffUL)
        return 4;
    if (v <= VARINT_MAX)
        return 8;
    return 0;
}

/**
 * Encodes a 62-bit integer into QUIC variable-length format with minimal width.
 */
WireError encodeVarInt(ulong v, ubyte[] outBuf, out size_t bytesWritten) @safe pure @nogc nothrow
{
    bytesWritten = 0;
    if (v > VARINT_MAX)
        return WireError.varIntOverflow;

    const size_t len = varIntLen(v);
    if (outBuf.length < len)
        return WireError.bufferTooSmall;

    return encodeVarIntWithLen(v, len, outBuf, bytesWritten);
}

/**
 * Encodes a 62-bit integer into QUIC variable-length format with a specific target width.
 *
 * targetLen must be 1, 2, 4, or 8.
 */
WireError encodeVarIntWithLen(ulong v, size_t targetLen, ubyte[] outBuf, out size_t bytesWritten) @safe pure @nogc nothrow
{
    bytesWritten = 0;
    if (v > VARINT_MAX)
        return WireError.varIntOverflow;

    if (outBuf.length < targetLen)
        return WireError.bufferTooSmall;

    switch (targetLen)
    {
    case 1:
        if (v > 0x3fUL)
            return WireError.varIntOverflow;
        outBuf[0] = cast(ubyte) v;
        bytesWritten = 1;
        return WireError.none;

    case 2:
        if (v > 0x3fffUL)
            return WireError.varIntOverflow;
        outBuf[0] = cast(ubyte)(0x40 | (v >> 8));
        outBuf[1] = cast(ubyte)(v & 0xff);
        bytesWritten = 2;
        return WireError.none;

    case 4:
        if (v > 0x3fff_ffffUL)
            return WireError.varIntOverflow;
        outBuf[0] = cast(ubyte)(0x80 | (v >> 24));
        outBuf[1] = cast(ubyte)((v >> 16) & 0xff);
        outBuf[2] = cast(ubyte)((v >> 8) & 0xff);
        outBuf[3] = cast(ubyte)(v & 0xff);
        bytesWritten = 4;
        return WireError.none;

    case 8:
        outBuf[0] = cast(ubyte)(0xc0 | (v >> 56));
        outBuf[1] = cast(ubyte)((v >> 48) & 0xff);
        outBuf[2] = cast(ubyte)((v >> 40) & 0xff);
        outBuf[3] = cast(ubyte)((v >> 32) & 0xff);
        outBuf[4] = cast(ubyte)((v >> 24) & 0xff);
        outBuf[5] = cast(ubyte)((v >> 16) & 0xff);
        outBuf[6] = cast(ubyte)((v >> 8) & 0xff);
        outBuf[7] = cast(ubyte)(v & 0xff);
        bytesWritten = 8;
        return WireError.none;

    default:
        return WireError.varIntOverflow;
    }
}

/**
 * Decodes a 62-bit integer from QUIC variable-length format (RFC 9000 Section 16).
 */
WireError decodeVarInt(const(ubyte)[] inBuf, out ulong value, out size_t bytesRead) @safe pure @nogc nothrow
{
    value = 0;
    bytesRead = 0;
    if (inBuf.length == 0)
        return WireError.unexpectedEof;

    const ubyte prefix = cast(ubyte)(inBuf[0] >> 6);
    const size_t len = 1 << prefix;

    if (inBuf.length < len)
        return WireError.unexpectedEof;

    ulong v = inBuf[0] & 0x3f;
    foreach (i; 1 .. len)
    {
        v = (v << 8) | inBuf[i];
    }

    value = v;
    bytesRead = len;
    return WireError.none;
}

/**
 * Sequential bounds-checked reader for QUIC wire parsing.
 */
struct WireReader
{
private:
    const(ubyte)[] m_data;
    size_t m_pos;

public:
    this(const(ubyte)[] data) @safe pure @nogc nothrow
    {
        m_data = data;
        m_pos = 0;
    }

    @property size_t remaining() const @safe pure @nogc nothrow
    {
        return (m_pos <= m_data.length) ? (m_data.length - m_pos) : 0;
    }

    @property size_t position() const @safe pure @nogc nothrow
    {
        return m_pos;
    }

    @property bool empty() const @safe pure @nogc nothrow
    {
        return m_pos >= m_data.length;
    }

    @property const(ubyte)[] unreadSlice() const @safe pure @nogc nothrow
    {
        if (m_pos >= m_data.length)
            return null;
        return m_data[m_pos .. $];
    }

    WireError readU8(out ubyte val) @safe pure @nogc nothrow
    {
        val = 0;
        if (remaining < 1)
            return WireError.unexpectedEof;
        val = m_data[m_pos];
        m_pos += 1;
        return WireError.none;
    }

    WireError peekU8(out ubyte val) const @safe pure @nogc nothrow
    {
        val = 0;
        if (remaining < 1)
            return WireError.unexpectedEof;
        val = m_data[m_pos];
        return WireError.none;
    }

    WireError readU16(out ushort val) @safe pure @nogc nothrow
    {
        val = 0;
        if (remaining < 2)
            return WireError.unexpectedEof;
        val = cast(ushort)((cast(ushort) m_data[m_pos] << 8) | m_data[m_pos + 1]);
        m_pos += 2;
        return WireError.none;
    }

    WireError readU32(out uint val) @safe pure @nogc nothrow
    {
        val = 0;
        if (remaining < 4)
            return WireError.unexpectedEof;
        val = (cast(uint) m_data[m_pos] << 24) | (cast(uint) m_data[m_pos + 1] << 16) | (
                cast(uint) m_data[m_pos + 2] << 8) | cast(uint) m_data[m_pos + 3];
        m_pos += 4;
        return WireError.none;
    }

    WireError readU64(out ulong val) @safe pure @nogc nothrow
    {
        val = 0;
        if (remaining < 8)
            return WireError.unexpectedEof;
        ulong v = 0;
        foreach (i; 0 .. 8)
        {
            v = (v << 8) | m_data[m_pos + i];
        }
        val = v;
        m_pos += 8;
        return WireError.none;
    }

    WireError readVarInt(out ulong val) @safe pure @nogc nothrow
    {
        val = 0;
        size_t bytesRead = 0;
        const err = decodeVarInt(m_data[m_pos .. $], val, bytesRead);
        if (err != WireError.none)
            return err;
        m_pos += bytesRead;
        return WireError.none;
    }

    WireError readSlice(size_t len, out const(ubyte)[] slice) @safe pure @nogc nothrow
    {
        slice = null;
        if (remaining < len)
            return WireError.unexpectedEof;
        slice = m_data[m_pos .. m_pos + len];
        m_pos += len;
        return WireError.none;
    }

    WireError readBytes(ubyte[] dest) @safe pure @nogc nothrow
    {
        if (remaining < dest.length)
            return WireError.unexpectedEof;
        dest[] = m_data[m_pos .. m_pos + dest.length];
        m_pos += dest.length;
        return WireError.none;
    }
}

/**
 * Sequential bounds-checked writer for QUIC wire serialization.
 */
struct WireWriter
{
private:
    ubyte[] m_buf;
    size_t m_pos;

public:
    this(ubyte[] buf) @safe pure @nogc nothrow
    {
        m_buf = buf;
        m_pos = 0;
    }

    @property size_t remaining() const @safe pure @nogc nothrow
    {
        return (m_pos <= m_buf.length) ? (m_buf.length - m_pos) : 0;
    }

    @property size_t bytesWritten() const @safe pure @nogc nothrow
    {
        return m_pos;
    }

    @property const(ubyte)[] writtenSlice() const @safe pure @nogc nothrow
    {
        return m_buf[0 .. m_pos];
    }

    WireError writeU8(ubyte val) @safe pure @nogc nothrow
    {
        if (remaining < 1)
            return WireError.bufferTooSmall;
        m_buf[m_pos] = val;
        m_pos += 1;
        return WireError.none;
    }

    WireError writeU16(ushort val) @safe pure @nogc nothrow
    {
        if (remaining < 2)
            return WireError.bufferTooSmall;
        m_buf[m_pos] = cast(ubyte)(val >> 8);
        m_buf[m_pos + 1] = cast(ubyte)(val & 0xff);
        m_pos += 2;
        return WireError.none;
    }

    WireError writeU32(uint val) @safe pure @nogc nothrow
    {
        if (remaining < 4)
            return WireError.bufferTooSmall;
        m_buf[m_pos] = cast(ubyte)(val >> 24);
        m_buf[m_pos + 1] = cast(ubyte)((val >> 16) & 0xff);
        m_buf[m_pos + 2] = cast(ubyte)((val >> 8) & 0xff);
        m_buf[m_pos + 3] = cast(ubyte)(val & 0xff);
        m_pos += 4;
        return WireError.none;
    }

    WireError writeU64(ulong val) @safe pure @nogc nothrow
    {
        if (remaining < 8)
            return WireError.bufferTooSmall;
        foreach (i; 0 .. 8)
        {
            m_buf[m_pos + i] = cast(ubyte)(val >> ((7 - i) * 8));
        }
        m_pos += 8;
        return WireError.none;
    }

    WireError writeVarInt(ulong val) @safe pure @nogc nothrow
    {
        size_t written = 0;
        const err = encodeVarInt(val, m_buf[m_pos .. $], written);
        if (err != WireError.none)
            return err;
        m_pos += written;
        return WireError.none;
    }

    WireError writeVarIntWithLen(ulong val, size_t targetLen) @safe pure @nogc nothrow
    {
        size_t written = 0;
        const err = encodeVarIntWithLen(val, targetLen, m_buf[m_pos .. $], written);
        if (err != WireError.none)
            return err;
        m_pos += written;
        return WireError.none;
    }

    WireError writeBytes(const(ubyte)[] src) @safe pure @nogc nothrow
    {
        if (remaining < src.length)
            return WireError.bufferTooSmall;
        m_buf[m_pos .. m_pos + src.length] = src[];
        m_pos += src.length;
        return WireError.none;
    }
}

/// Example:
// Spec: RFC 9000 Section 16 & Appendix A.1 - VarInt Encoding, Decoding, Non-Minimal & Overflow (covers U1, U2, U3, E1, W1, Scenario T1)
@nogc unittest
{
    // Test vectors from RFC 9000 Appendix A.1 Table 6:
    // 37 -> 0x25
    // 15293 -> 0x7bbd
    // 494878333 -> 0x9d7f3e7d
    // 151288809941952652 -> 0xc2197c5eff14e88c

    static struct TestCase
    {
        ulong val;
        ubyte[8] bytes;
        size_t len;
    }

    const TestCase[4] cases = [
        TestCase(37UL, [0x25, 0, 0, 0, 0, 0, 0, 0], 1),
        TestCase(15293UL, [0x7b, 0xbd, 0, 0, 0, 0, 0, 0], 2),
        TestCase(494878333UL, [0x9d, 0x7f, 0x3e, 0x7d, 0, 0, 0, 0], 4),
        TestCase(151288809941952652UL, [
            0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c
        ], 8)
    ];

    foreach (ref c; cases)
    {
        // 1. Verify varIntLen
        assert(varIntLen(c.val) == c.len);

        // 2. Encode
        ubyte[8] outBuf;
        size_t written = 0;
        WireError err = encodeVarInt(c.val, outBuf[], written);
        assert(err == WireError.none);
        assert(written == c.len);
        assert(outBuf[0 .. written] == c.bytes[0 .. c.len]);

        // 3. Decode
        ulong decoded = 0;
        size_t readLen = 0;
        err = decodeVarInt(c.bytes[0 .. c.len], decoded, readLen);
        assert(err == WireError.none);
        assert(readLen == c.len);
        assert(decoded == c.val);
    }

    // 4. Non-minimal 2-byte encoding of 37 (0x4025 -> 37) per RFC 9000 Appendix A.1
    const ubyte[2] nonMinimal37 = [0x40, 0x25];
    ulong nonMinimalDecoded = 0;
    size_t nonMinimalRead = 0;
    WireError nmErr = decodeVarInt(nonMinimal37[], nonMinimalDecoded, nonMinimalRead);
    assert(nmErr == WireError.none);
    assert(nonMinimalRead == 2);
    assert(nonMinimalDecoded == 37UL);

    // 5. Fixed-width encodeVarIntWithLen
    ubyte[4] fixedBuf;
    size_t fixedWritten = 0;
    WireError fixedErr = encodeVarIntWithLen(37UL, 2, fixedBuf[], fixedWritten);
    assert(fixedErr == WireError.none);
    assert(fixedWritten == 2);
    assert(fixedBuf[0 .. 2] == nonMinimal37[]);

    // 6. Value exceeding target width
    fixedErr = encodeVarIntWithLen(1000UL, 1, fixedBuf[], fixedWritten);
    assert(fixedErr == WireError.varIntOverflow);

    // 7. Overflow beyond 2^62 - 1
    const ulong overflowVal = 1UL << 62;
    ubyte[8] overflowBuf;
    size_t overflowWritten = 0;
    assert(encodeVarInt(overflowVal, overflowBuf[], overflowWritten) == WireError.varIntOverflow);

    // 8. Buffer too small on encode
    ubyte[1] tinyBuf;
    size_t tinyWritten = 0;
    assert(encodeVarInt(15293UL, tinyBuf[], tinyWritten) == WireError.bufferTooSmall);
}

/// Example:
// Spec: RFC 9000 Section 16 - Buffer Cursors & Prefix Truncation Safety (covers U1, U2, G4, Scenario W1)
@nogc unittest
{
    // Test WireWriter and WireReader
    ubyte[32] rawBuf;
    WireWriter writer = WireWriter(rawBuf[]);

    assert(writer.writeU8(0xaa) == WireError.none);
    assert(writer.writeU16(0x1234) == WireError.none);
    assert(writer.writeU32(0xdeadbeef) == WireError.none);
    assert(writer.writeU64(0x0123456789abcdefUL) == WireError.none);
    assert(writer.writeVarInt(15293UL) == WireError.none);
    assert(writer.writeBytes(cast(const(ubyte)[]) "QUIC") == WireError.none);

    WireReader reader = WireReader(writer.writtenSlice);
    ubyte u8Val = 0;
    ushort u16Val = 0;
    uint u32Val = 0;
    ulong u64Val = 0;
    ulong viVal = 0;
    ubyte[4] bytesVal;

    assert(reader.readU8(u8Val) == WireError.none);
    assert(u8Val == 0xaa);
    assert(reader.readU16(u16Val) == WireError.none);
    assert(u16Val == 0x1234);
    assert(reader.readU32(u32Val) == WireError.none);
    assert(u32Val == 0xdeadbeef);
    assert(reader.readU64(u64Val) == WireError.none);
    assert(u64Val == 0x0123456789abcdefUL);
    assert(reader.readVarInt(viVal) == WireError.none);
    assert(viVal == 15293UL);
    assert(reader.readBytes(bytesVal[]) == WireError.none);
    assert(bytesVal[] == cast(const(ubyte)[]) "QUIC");
    assert(reader.empty);
    assert(reader.remaining == 0);

    // Read past end returns unexpectedEof
    assert(reader.readU8(u8Val) == WireError.unexpectedEof);
    assert(reader.readVarInt(viVal) == WireError.unexpectedEof);

    // G4: Truncation safety across all prefix lengths
    const ubyte[8] full8 = [0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c];
    foreach (prefixLen; 0 .. 8)
    {
        ulong v = 999;
        size_t r = 999;
        WireError err = decodeVarInt(full8[0 .. prefixLen], v, r);
        assert(err == WireError.unexpectedEof);
        assert(v == 0);
        assert(r == 0);
    }
}
