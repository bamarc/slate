module slate.quic.wire.packet;

/**
 * QUIC Packet Headers and Coalesced Datagram Splitting (RFC 9000 Section 17 & Section 12.2).
 *
 * Implements two-phase packet header parsing:
 * - Phase A: parsePacketPrefix (pre-unprotect) to split coalesced datagrams and locate pnOffset
 * - Phase B: completeHeaderAfterUnprotect (post-unprotect) to validate reserved bits and decode packet number
 */

public import slate.quic.crypto.header_protection : encodePacketNumber,
    packetNumberLength, decodePacketNumber;
public import slate.quic.wire.varint;
public import slate.quic.wire.cid;

public enum uint QUIC_VERSION_1 = 0x00000001u;
public enum uint QUIC_VERSION_2 = 0x6b3343cfu;
public enum uint QUIC_VERSION_NEGOTIATION = 0x00000000u;

public enum PacketType : ubyte
{
    initial = 0,
    zeroRtt,
    handshake,
    retry,
    versionNegotiation,
    oneRttShort
}

/**
 * Unmasked invariant fields parsed before removing header protection (RFC 9001 Section 5.4).
 */
public struct PacketPrefix
{
    PacketType type;
    uint version_;
    ConnectionId dcid;
    ConnectionId scid;
    const(ubyte)[] token;
    ubyte[16] retryIntegrityTag;
    ulong payloadAndPnLength;
    size_t pnOffset;
    size_t totalPacketLen;
    ubyte firstByte;
}

/**
 * Fully parsed packet header after header protection has been removed.
 */
public struct DecodedPacketHeader
{
    PacketType type;
    uint version_;
    ConnectionId dcid;
    ConnectionId scid;
    const(ubyte)[] token;
    ulong packetNumber;
    size_t pnLen;
    size_t pnOffset;
    size_t payloadOffset;
    size_t payloadLen;
    bool keyPhase;
    bool spinBit;
}

/**
 * Parses invariant packet header fields prior to header unprotection (Phase A).
 *
 * shortDcidLen must be provided for 1-RTT short header packets (established during handshake).
 */
WireError parsePacketPrefix(const(ubyte)[] datagram, size_t shortDcidLen, out PacketPrefix prefix) @safe pure @nogc nothrow
{
    prefix = PacketPrefix.init;
    if (datagram.length == 0)
        return WireError.unexpectedEof;

    const ubyte firstByte = datagram[0];
    prefix.firstByte = firstByte;

    const bool isLong = (firstByte & 0x80) != 0;
    if (isLong)
    {
        if (datagram.length < 5)
            return WireError.unexpectedEof;

        const uint ver = (cast(uint) datagram[1] << 24) | (cast(
                uint) datagram[2] << 16) | (cast(uint) datagram[3] << 8) | cast(uint) datagram[4];
        prefix.version_ = ver;

        if (ver == QUIC_VERSION_NEGOTIATION)
        {
            // RFC 9000 Section 17.2.1: Version Negotiation Packet
            prefix.type = PacketType.versionNegotiation;
            if (datagram.length < 6)
                return WireError.unexpectedEof;

            const ubyte dcidLen = datagram[5];
            if (dcidLen > MAX_CID_LEN)
                return WireError.invalidPacketHeader;
            if (datagram.length < 6 + dcidLen + 1)
                return WireError.unexpectedEof;

            prefix.dcid = ConnectionId(datagram[6 .. 6 + dcidLen]);
            const size_t scidOffset = 6 + dcidLen;
            const ubyte scidLen = datagram[scidOffset];
            if (scidLen > MAX_CID_LEN)
                return WireError.invalidPacketHeader;
            if (datagram.length < scidOffset + 1 + scidLen)
                return WireError.unexpectedEof;

            prefix.scid = ConnectionId(datagram[scidOffset + 1 .. scidOffset + 1 + scidLen]);
            prefix.totalPacketLen = datagram.length;
            prefix.pnOffset = 0;
            prefix.payloadAndPnLength = 0;
            return WireError.none;
        }

        // Fixed bit (0x40) check for QUIC v1/v2 long headers (RFC 9000 Section 17.2)
        if ((firstByte & 0x40) == 0)
            return WireError.invalidPacketHeader;

        const ubyte longType = (firstByte >> 4) & 0x03;
        switch (longType)
        {
        case 0x00:
            prefix.type = PacketType.initial;
            break;
        case 0x01:
            prefix.type = PacketType.zeroRtt;
            break;
        case 0x02:
            prefix.type = PacketType.handshake;
            break;
        case 0x03:
            prefix.type = PacketType.retry;
            break;
        default:
            return WireError.invalidPacketHeader;
        }

        size_t offset = 5;
        if (datagram.length <= offset)
            return WireError.unexpectedEof;

        const ubyte dcidLen = datagram[offset++];
        if (dcidLen > MAX_CID_LEN)
            return WireError.invalidPacketHeader;
        if (datagram.length - offset < dcidLen)
            return WireError.unexpectedEof;
        prefix.dcid = ConnectionId(datagram[offset .. offset + dcidLen]);
        offset += dcidLen;

        if (datagram.length <= offset)
            return WireError.unexpectedEof;

        const ubyte scidLen = datagram[offset++];
        if (scidLen > MAX_CID_LEN)
            return WireError.invalidPacketHeader;
        if (datagram.length - offset < scidLen)
            return WireError.unexpectedEof;
        prefix.scid = ConnectionId(datagram[offset .. offset + scidLen]);
        offset += scidLen;

        if (prefix.type == PacketType.retry)
        {
            // RFC 9000 Section 17.2.5: Retry packet contains Retry Token + 16-byte Retry Integrity Tag
            if (datagram.length - offset < 16)
                return WireError.unexpectedEof;
            if (datagram.length - offset == 16)
                return WireError.invalidPacketHeader; // 0-byte token is forbidden
            prefix.token = datagram[offset .. $ - 16];
            prefix.retryIntegrityTag[] = datagram[$ - 16 .. $];
            prefix.totalPacketLen = datagram.length;
            prefix.pnOffset = 0;
            prefix.payloadAndPnLength = 0;
            return WireError.none;
        }

        if (prefix.type == PacketType.initial)
        {
            ulong tokenLen = 0;
            size_t tokenLenBytes = 0;
            const err = decodeVarInt(datagram[offset .. $], tokenLen, tokenLenBytes);
            if (err != WireError.none)
                return err;
            offset += tokenLenBytes;

            if (tokenLen > datagram.length - offset)
                return WireError.unexpectedEof;
            prefix.token = datagram[offset .. offset + cast(size_t) tokenLen];
            offset += cast(size_t) tokenLen;
        }

        // Length field (VarInt) for Initial, 0-RTT, and Handshake packets (RFC 9000 Section 17.2)
        ulong lengthVal = 0;
        size_t lengthBytes = 0;
        const err = decodeVarInt(datagram[offset .. $], lengthVal, lengthBytes);
        if (err != WireError.none)
            return err;
        offset += lengthBytes;

        if (lengthVal < 1)
            return WireError.invalidPacketHeader; // Length covers at least 1-byte packet number
        if (lengthVal > datagram.length - offset)
            return WireError.unexpectedEof;

        prefix.pnOffset = offset;
        prefix.payloadAndPnLength = lengthVal;
        prefix.totalPacketLen = prefix.pnOffset + cast(size_t) lengthVal;

        return WireError.none;
    }
    else
    {
        // RFC 9000 Section 17.3.1: 1-RTT Short Header Packet
        // Fixed bit (0x40) must be 1
        if ((firstByte & 0x40) == 0)
            return WireError.invalidPacketHeader;

        if (shortDcidLen > MAX_CID_LEN)
            return WireError.invalidPacketHeader;

        if (datagram.length < 1 + shortDcidLen)
            return WireError.unexpectedEof;

        prefix.type = PacketType.oneRttShort;
        prefix.version_ = 0;
        prefix.dcid = ConnectionId(datagram[1 .. 1 + shortDcidLen]);
        prefix.pnOffset = 1 + shortDcidLen;
        prefix.totalPacketLen = datagram.length;
        prefix.payloadAndPnLength = datagram.length - prefix.pnOffset;
        return WireError.none;
    }
}

/**
 * Validates unmasked header bits, extracts packet number length and full packet number (Phase B).
 */
WireError completeHeaderAfterUnprotect(const(ubyte)[] unprotectedPacket, ref const PacketPrefix prefix,
        ulong largestAckedPn, out DecodedPacketHeader outHdr, out TransportErrorCode err) @safe pure @nogc nothrow
{
    outHdr = DecodedPacketHeader.init;
    err = TransportErrorCode.noError;

    if (unprotectedPacket.length == 0 || unprotectedPacket.length < prefix.pnOffset)
        return WireError.unexpectedEof;

    const ubyte firstByte = unprotectedPacket[0];
    const bool isLong = (firstByte & 0x80) != 0;

    if (isLong)
    {
        // RFC 9000 Section 17.2: Reserved bits (0x0c) must be zero
        if ((firstByte & 0x0c) != 0)
        {
            err = TransportErrorCode.protocolViolation;
            return WireError.reservedBitsSet;
        }
    }
    else
    {
        // RFC 9000 Section 17.3.1: Reserved bits (0x18) must be zero
        if ((firstByte & 0x18) != 0)
        {
            err = TransportErrorCode.protocolViolation;
            return WireError.reservedBitsSet;
        }
    }

    const size_t pnLen = (firstByte & 0x03) + 1;
    if (unprotectedPacket.length < prefix.pnOffset + pnLen)
        return WireError.unexpectedEof;

    ulong truncatedPn = 0;
    foreach (i; 0 .. pnLen)
    {
        truncatedPn = (truncatedPn << 8) | unprotectedPacket[prefix.pnOffset + i];
    }

    const ulong fullPn = decodePacketNumber(largestAckedPn, truncatedPn, pnLen);

    outHdr.type = prefix.type;
    outHdr.version_ = prefix.version_;
    outHdr.dcid = prefix.dcid;
    outHdr.scid = prefix.scid;
    outHdr.token = prefix.token;
    outHdr.packetNumber = fullPn;
    outHdr.pnLen = pnLen;
    outHdr.pnOffset = prefix.pnOffset;
    outHdr.payloadOffset = prefix.pnOffset + pnLen;

    if (unprotectedPacket.length >= outHdr.payloadOffset)
        outHdr.payloadLen = unprotectedPacket.length - outHdr.payloadOffset;
    else
        outHdr.payloadLen = 0;

    if (!isLong)
    {
        outHdr.spinBit = (firstByte & 0x20) != 0;
        outHdr.keyPhase = (firstByte & 0x04) != 0;
    }

    return WireError.none;
}

/**
 * Iterator for splitting a coalesced UDP datagram into individual QUIC packets (RFC 9000 Section 12.2).
 */
public struct CoalescedPacketIterator
{
private:
    const(ubyte)[] m_datagram;
    size_t m_shortDcidLen;

public:
    this(const(ubyte)[] datagram, size_t shortDcidLen) @safe pure @nogc nothrow
    {
        m_datagram = datagram;
        m_shortDcidLen = shortDcidLen;
    }

    @property bool empty() const @safe pure @nogc nothrow
    {
        return m_datagram.length == 0;
    }

    bool next(out const(ubyte)[] packetSlice, out PacketPrefix prefix, out WireError err) @safe pure @nogc nothrow
    {
        packetSlice = null;
        prefix = PacketPrefix.init;
        err = WireError.none;

        if (m_datagram.length == 0)
            return false;

        err = parsePacketPrefix(m_datagram, m_shortDcidLen, prefix);
        if (err != WireError.none)
            return false;

        if (m_datagram.length < prefix.totalPacketLen)
        {
            err = WireError.unexpectedEof;
            return false;
        }

        packetSlice = m_datagram[0 .. prefix.totalPacketLen];
        m_datagram = m_datagram[prefix.totalPacketLen .. $];
        return true;
    }
}

/**
 * Encodes a QUIC Long Header in place (RFC 9000 Section 17.2).
 *
 * Uses a 2-byte fixed-width VarInt for the Length field.
 */
WireError encodeLongHeader(PacketType type, uint version_, const ref ConnectionId dcid,
        const ref ConnectionId scid, const(ubyte)[] token, ulong packetNumber, size_t pnLen,
        size_t plaintextPayloadLen, ubyte[] outBuf, out size_t pnOffset, out size_t headerLen) @safe pure @nogc nothrow
{
    pnOffset = 0;
    headerLen = 0;

    if (pnLen < 1 || pnLen > 4)
        return WireError.invalidPacketHeader;

    ubyte typeBits = 0;
    switch (type)
    {
    case PacketType.initial:
        typeBits = 0x00;
        break;
    case PacketType.zeroRtt:
        typeBits = 0x01;
        break;
    case PacketType.handshake:
        typeBits = 0x02;
        break;
    default:
        return WireError.invalidPacketHeader;
    }

    WireWriter writer = WireWriter(outBuf);

    // Byte 0: Header Form (1) | Fixed Bit (1) | Long Packet Type (2 bits) | Reserved (2 bits = 0) | PN Length (2 bits)
    const ubyte firstByte = cast(ubyte)(0xc0 | (typeBits << 4) | (cast(ubyte)(pnLen - 1) & 0x03));
    if (writer.writeU8(firstByte) != WireError.none)
        return WireError.bufferTooSmall;

    // Version (4 bytes)
    if (writer.writeU32(version_) != WireError.none)
        return WireError.bufferTooSmall;

    // DCID
    if (writer.writeU8(dcid.len) != WireError.none)
        return WireError.bufferTooSmall;
    if (dcid.len > 0 && writer.writeBytes(dcid.asSlice()) != WireError.none)
        return WireError.bufferTooSmall;

    // SCID
    if (writer.writeU8(scid.len) != WireError.none)
        return WireError.bufferTooSmall;
    if (scid.len > 0 && writer.writeBytes(scid.asSlice()) != WireError.none)
        return WireError.bufferTooSmall;

    // Token (only in Initial)
    if (type == PacketType.initial)
    {
        if (writer.writeVarInt(token.length) != WireError.none)
            return WireError.bufferTooSmall;
        if (token.length > 0 && writer.writeBytes(token) != WireError.none)
            return WireError.bufferTooSmall;
    }

    // Length field (VarInt): includes pnLen + plaintextPayloadLen + 16 (AEAD tag)
    const ulong lengthVal = pnLen + plaintextPayloadLen + 16;
    if (writer.writeVarIntWithLen(lengthVal, 2) != WireError.none)
        return WireError.bufferTooSmall;

    pnOffset = writer.bytesWritten;

    // Truncated Packet Number
    ubyte[4] pnBytes;
    encodePacketNumber(packetNumber, pnLen, pnBytes[0 .. pnLen]);
    if (writer.writeBytes(pnBytes[0 .. pnLen]) != WireError.none)
        return WireError.bufferTooSmall;

    headerLen = writer.bytesWritten;
    return WireError.none;
}

/**
 * Encodes a 1-RTT Short Header in place (RFC 9000 Section 17.3.1).
 */
WireError encodeShortHeader(const ref ConnectionId dcid, ulong packetNumber, size_t pnLen,
        bool keyPhase, bool spinBit, ubyte[] outBuf, out size_t pnOffset, out size_t headerLen) @safe pure @nogc nothrow
{
    pnOffset = 0;
    headerLen = 0;

    if (pnLen < 1 || pnLen > 4)
        return WireError.invalidPacketHeader;

    WireWriter writer = WireWriter(outBuf);

    // Byte 0: Header Form (0) | Fixed Bit (1) | Spin Bit (1 bit) | Reserved (2 bits = 0) | Key Phase (1 bit) | PN Length (2 bits)
    const ubyte firstByte = cast(ubyte)(0x40 | (spinBit ? 0x20 : 0x00) | (keyPhase
            ? 0x04 : 0x00) | (cast(ubyte)(pnLen - 1) & 0x03));

    if (writer.writeU8(firstByte) != WireError.none)
        return WireError.bufferTooSmall;

    if (dcid.len > 0 && writer.writeBytes(dcid.asSlice()) != WireError.none)
        return WireError.bufferTooSmall;

    pnOffset = writer.bytesWritten;

    ubyte[4] pnBytes;
    encodePacketNumber(packetNumber, pnLen, pnBytes[0 .. pnLen]);
    if (writer.writeBytes(pnBytes[0 .. pnLen]) != WireError.none)
        return WireError.bufferTooSmall;

    headerLen = writer.bytesWritten;
    return WireError.none;
}

/**
 * Encodes a Retry Packet (RFC 9000 Section 17.2.5).
 */
WireError encodeRetryPacket(uint version_, const ref ConnectionId dcid,
        const ref ConnectionId scid, const(ubyte)[] retryToken,
        const(ubyte)[16] integrityTag, ubyte[] outBuf, out size_t bytesWritten) @safe pure @nogc nothrow
{
    bytesWritten = 0;
    if (retryToken.length == 0)
        return WireError.invalidPacketHeader;
    WireWriter writer = WireWriter(outBuf);

    // Long header with type 0x03 (Retry), unpredictable unused bits
    const ubyte firstByte = cast(ubyte)(0xc0 | (0x03 << 4) | 0x0f);
    if (writer.writeU8(firstByte) != WireError.none)
        return WireError.bufferTooSmall;

    if (writer.writeU32(version_) != WireError.none)
        return WireError.bufferTooSmall;

    if (writer.writeU8(dcid.len) != WireError.none)
        return WireError.bufferTooSmall;
    if (dcid.len > 0 && writer.writeBytes(dcid.asSlice()) != WireError.none)
        return WireError.bufferTooSmall;

    if (writer.writeU8(scid.len) != WireError.none)
        return WireError.bufferTooSmall;
    if (scid.len > 0 && writer.writeBytes(scid.asSlice()) != WireError.none)
        return WireError.bufferTooSmall;

    if (retryToken.length > 0 && writer.writeBytes(retryToken) != WireError.none)
        return WireError.bufferTooSmall;

    if (writer.writeBytes(integrityTag[]) != WireError.none)
        return WireError.bufferTooSmall;

    bytesWritten = writer.bytesWritten;
    return WireError.none;
}

/**
 * Encodes a Version Negotiation Packet (RFC 9000 Section 17.2.1).
 */
WireError encodeVersionNegotiationPacket(const ref ConnectionId dcid, const ref ConnectionId scid,
        const(uint)[] supportedVersions, ubyte[] outBuf, out size_t bytesWritten) @safe pure @nogc nothrow
{
    bytesWritten = 0;
    WireWriter writer = WireWriter(outBuf);

    // Byte 0: Header Form (1) | Unpredictable bits
    const ubyte firstByte = cast(ubyte)(0x80 | 0x3a);
    if (writer.writeU8(firstByte) != WireError.none)
        return WireError.bufferTooSmall;

    // Version = 0x00000000
    if (writer.writeU32(QUIC_VERSION_NEGOTIATION) != WireError.none)
        return WireError.bufferTooSmall;

    if (writer.writeU8(dcid.len) != WireError.none)
        return WireError.bufferTooSmall;
    if (dcid.len > 0 && writer.writeBytes(dcid.asSlice()) != WireError.none)
        return WireError.bufferTooSmall;

    if (writer.writeU8(scid.len) != WireError.none)
        return WireError.bufferTooSmall;
    if (scid.len > 0 && writer.writeBytes(scid.asSlice()) != WireError.none)
        return WireError.bufferTooSmall;

    foreach (ver; supportedVersions)
    {
        if (writer.writeU32(ver) != WireError.none)
            return WireError.bufferTooSmall;
    }

    bytesWritten = writer.bytesWritten;
    return WireError.none;
}

/// Example:
// Spec: RFC 9000 Section 17.2 & Section 12.2 - Packet Headers & Coalesced Datagram Splitting (covers U1, U2, U3, E2, Scenario T2)
@nogc unittest
{
    const ubyte[8] dcidBytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08];
    const ubyte[8] scidBytes = [0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    ubyte[1024] datagramBuf;
    size_t totalDatagramLen = 0;

    // 1. Append Initial Packet (with 20 payload bytes + 16 AEAD tag)
    size_t initPnOffset = 0;
    size_t initHdrLen = 0;
    WireError err = encodeLongHeader(PacketType.initial, QUIC_VERSION_1, dcid,
            scid, null, // no token
            1UL, // PN = 1
            2, // PN len = 2
            20, // plaintext payload len
            datagramBuf[totalDatagramLen .. $], initPnOffset, initHdrLen);
    assert(err == WireError.none);
    // Fill 20 bytes plaintext + 16 bytes tag dummy
    totalDatagramLen += initHdrLen + 20 + 16;

    // 2. Append Handshake Packet (with 30 payload bytes + 16 AEAD tag)
    size_t hsPnOffset = 0;
    size_t hsHdrLen = 0;
    err = encodeLongHeader(PacketType.handshake, QUIC_VERSION_1, dcid, scid,
            null, 2UL, // PN = 2
            2, // PN len = 2
            30, // plaintext payload len
            datagramBuf[totalDatagramLen .. $], hsPnOffset, hsHdrLen);
    assert(err == WireError.none);
    totalDatagramLen += hsHdrLen + 30 + 16;

    // 3. Append 1-RTT Short Header Packet (with 40 payload bytes + 16 AEAD tag)
    size_t shortPnOffset = 0;
    size_t shortHdrLen = 0;
    err = encodeShortHeader(dcid, 3UL, // PN = 3
            1, // PN len = 1
            true, // keyPhase = 1
            false, // spinBit = 0
            datagramBuf[totalDatagramLen .. $], shortPnOffset, shortHdrLen);
    assert(err == WireError.none);
    totalDatagramLen += shortHdrLen + 40 + 16;

    // 4. Test CoalescedPacketIterator splitting all 3 packets
    CoalescedPacketIterator iter = CoalescedPacketIterator(datagramBuf[0 .. totalDatagramLen], 8);
    const(ubyte)[] p1;
    const(ubyte)[] p2;
    const(ubyte)[] p3;
    PacketPrefix pref1;
    PacketPrefix pref2;
    PacketPrefix pref3;
    WireError splitErr;

    assert(iter.next(p1, pref1, splitErr));
    assert(splitErr == WireError.none);
    assert(pref1.type == PacketType.initial);
    assert(pref1.version_ == QUIC_VERSION_1);
    assert(pref1.dcid == dcid);
    assert(pref1.scid == scid);
    assert(p1.length == pref1.totalPacketLen);

    assert(iter.next(p2, pref2, splitErr));
    assert(splitErr == WireError.none);
    assert(pref2.type == PacketType.handshake);
    assert(pref2.version_ == QUIC_VERSION_1);
    assert(pref2.dcid == dcid);
    assert(pref2.scid == scid);
    assert(p2.length == pref2.totalPacketLen);

    assert(iter.next(p3, pref3, splitErr));
    assert(splitErr == WireError.none);
    assert(pref3.type == PacketType.oneRttShort);
    assert(pref3.dcid == dcid);
    assert(p3.length == pref3.totalPacketLen);

    assert(iter.empty);

    // 5. Complete headers (Phase B) and verify PN & flags
    DecodedPacketHeader h1;
    DecodedPacketHeader h2;
    DecodedPacketHeader h3;
    TransportErrorCode te;

    assert(completeHeaderAfterUnprotect(p1, pref1, 0, h1, te) == WireError.none);
    assert(h1.packetNumber == 1UL);
    assert(h1.pnLen == 2);

    assert(completeHeaderAfterUnprotect(p2, pref2, 1, h2, te) == WireError.none);
    assert(h2.packetNumber == 2UL);
    assert(h2.pnLen == 2);

    assert(completeHeaderAfterUnprotect(p3, pref3, 2, h3, te) == WireError.none);
    assert(h3.packetNumber == 3UL);
    assert(h3.pnLen == 1);
    assert(h3.keyPhase == true);
    assert(h3.spinBit == false);
}

/// Example:
// Spec: RFC 9000 Section 17.2 & Section 17.3.1 - Reserved Bits & Truncation (covers W2, G4, Scenario W2)
@nogc unittest
{
    const ubyte[8] dcidBytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(dcidBytes[]);

    ubyte[128] buf;
    size_t pnOff = 0;
    size_t hdrLen = 0;
    WireError err = encodeLongHeader(PacketType.initial, QUIC_VERSION_1, dcid,
            scid, null, 1UL, 1, 10, buf[], pnOff, hdrLen);
    assert(err == WireError.none);

    PacketPrefix prefix;
    assert(parsePacketPrefix(buf[0 .. hdrLen + 10 + 16], 8, prefix) == WireError.none);

    // Corrupt reserved bits in Long Header: bits 0x0c
    buf[0] |= 0x08;
    DecodedPacketHeader hdr;
    TransportErrorCode te;
    assert(completeHeaderAfterUnprotect(buf[0 .. hdrLen + 10 + 16], prefix, 0,
            hdr, te) == WireError.reservedBitsSet);
    assert(te == TransportErrorCode.protocolViolation);

    // Corrupt Short Header reserved bits: bits 0x18
    ubyte[64] shortBuf;
    assert(encodeShortHeader(dcid, 1UL, 1, false, false, shortBuf[], pnOff,
            hdrLen) == WireError.none);
    PacketPrefix sPref;
    assert(parsePacketPrefix(shortBuf[0 .. hdrLen + 10], 8, sPref) == WireError.none);

    shortBuf[0] |= 0x10; // set reserved bit
    assert(completeHeaderAfterUnprotect(shortBuf[0 .. hdrLen + 10], sPref, 0,
            hdr, te) == WireError.reservedBitsSet);
    assert(te == TransportErrorCode.protocolViolation);

    // Fixed bit 0x40 == 0 must be rejected
    buf[0] &= ~0x40;
    assert(parsePacketPrefix(buf[0 .. hdrLen + 10 + 16], 8, prefix) == WireError
            .invalidPacketHeader);
    buf[0] |= 0x40; // restore fixed bit for truncation test

    // G4 Truncation safety on prefix parser across full packet length
    foreach (len; 0 .. hdrLen + 10 + 16)
    {
        PacketPrefix truncPref;
        assert(parsePacketPrefix(buf[0 .. len], 8, truncPref) == WireError.unexpectedEof);
    }
}

/// Example:
// Spec: RFC 9000 Section 17.2 & 17.3 - Packet Header Edge Cases, 0-RTT, Retry, Version Negotiation (covers W2, Scenario W2)
@nogc unittest
{
    // 1. Zero-RTT Packet encode, prefix parse, and unprotect
    const ubyte[8] dcidBytes = [10, 11, 12, 13, 14, 15, 16, 17];
    const ubyte[8] scidBytes = [20, 21, 22, 23, 24, 25, 26, 27];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    ubyte[128] zrBuf;
    size_t zrPnOff = 0;
    size_t zrHdrLen = 0;
    assert(encodeLongHeader(PacketType.zeroRtt, QUIC_VERSION_1, dcid, scid,
            null, 42UL, 2, 20, zrBuf[], zrPnOff, zrHdrLen) == WireError.none);

    PacketPrefix zrPrefix;
    assert(parsePacketPrefix(zrBuf[0 .. zrHdrLen + 20 + 16], 8, zrPrefix) == WireError.none);
    assert(zrPrefix.type == PacketType.zeroRtt);
    assert(zrPrefix.version_ == QUIC_VERSION_1);
    assert(zrPrefix.dcid == dcid);
    assert(zrPrefix.scid == scid);

    DecodedPacketHeader zrHdr;
    TransportErrorCode te;
    assert(completeHeaderAfterUnprotect(zrBuf[0 .. zrHdrLen + 20 + 16], zrPrefix,
            0, zrHdr, te) == WireError.none);
    assert(zrHdr.packetNumber == 42UL);
    assert(zrHdr.pnLen == 2);

    // completeHeaderAfterUnprotect with empty slice
    assert(completeHeaderAfterUnprotect(null, zrPrefix, 0, zrHdr, te) == WireError.unexpectedEof);

    // 2. Retry Packet encode, prefix parse, and integrity tag check
    ubyte[128] retryBuf;
    const ubyte[8] retryToken = [1, 2, 3, 4, 5, 6, 7, 8];
    static const ubyte[16] tag = [
        0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
    ];
    size_t retryWritten = 0;

    // Reject empty retry token in encode
    assert(encodeRetryPacket(QUIC_VERSION_1, dcid, scid, null, tag, retryBuf[],
            retryWritten) == WireError.invalidPacketHeader);

    assert(encodeRetryPacket(QUIC_VERSION_1, dcid, scid, retryToken[], tag,
            retryBuf[], retryWritten) == WireError.none);
    PacketPrefix retryPrefix;
    assert(parsePacketPrefix(retryBuf[0 .. retryWritten], 8, retryPrefix) == WireError.none);
    assert(retryPrefix.type == PacketType.retry);
    assert(retryPrefix.version_ == QUIC_VERSION_1);
    assert(retryPrefix.dcid == dcid);
    assert(retryPrefix.scid == scid);
    assert(retryPrefix.token == retryToken[]);
    assert(retryPrefix.retryIntegrityTag == tag);

    // Reject Retry with 0-byte token during prefix parse
    ubyte[64] corruptedRetry;
    WireWriter rw = WireWriter(corruptedRetry[]);
    rw.writeU8(0xf0);
    rw.writeU32(QUIC_VERSION_1);
    rw.writeU8(dcid.len);
    rw.writeBytes(dcid.asSlice());
    rw.writeU8(scid.len);
    rw.writeBytes(scid.asSlice());
    rw.writeBytes(tag[]);
    PacketPrefix badRetryPref;
    assert(parsePacketPrefix(rw.writtenSlice, 8, badRetryPref) == WireError.invalidPacketHeader);

    // 3. Version Negotiation Packet
    ubyte[128] vnBuf;
    static const uint[2] supportedVersions = [QUIC_VERSION_1, 0x1a2a3a4a];
    size_t vnWritten = 0;
    assert(encodeVersionNegotiationPacket(dcid, scid, supportedVersions[],
            vnBuf[], vnWritten) == WireError.none);

    PacketPrefix vnPrefix;
    assert(parsePacketPrefix(vnBuf[0 .. vnWritten], 8, vnPrefix) == WireError.none);
    assert(vnPrefix.type == PacketType.versionNegotiation);
    assert(vnPrefix.version_ == 0);
    assert(vnPrefix.dcid == dcid);
    assert(vnPrefix.scid == scid);
    const size_t vOffset = 1 + 4 + 1 + dcid.len + 1 + scid.len;
    const(ubyte)[] vSlice = vnBuf[vOffset .. vnWritten];
    assert(vSlice.length == 8);

    // 4. DCID > 20 and SCID > 20 rejection
    ubyte[64] badCidBuf;
    ubyte[40] dummyBytes;
    WireWriter cw = WireWriter(badCidBuf[]);
    cw.writeU8(0xc0 | (0x00 << 4) | 0x01); // Initial
    cw.writeU32(QUIC_VERSION_1);
    cw.writeU8(21); // DCID length 21 > 20!
    cw.writeBytes(dummyBytes[]);
    PacketPrefix badCidPref;
    assert(parsePacketPrefix(cw.writtenSlice, 8, badCidPref) == WireError.invalidPacketHeader);

    // SCID > 20
    cw = WireWriter(badCidBuf[]);
    cw.writeU8(0xc0 | (0x00 << 4) | 0x01); // Initial
    cw.writeU32(QUIC_VERSION_1);
    cw.writeU8(4); // DCID length 4
    cw.writeBytes(dummyBytes[0 .. 4]);
    cw.writeU8(21); // SCID length 21 > 20!
    cw.writeBytes(dummyBytes[]);
    assert(parsePacketPrefix(cw.writtenSlice, 8, badCidPref) == WireError.invalidPacketHeader);

    // 5. Long header length == 0 rejection
    cw = WireWriter(badCidBuf[]);
    cw.writeU8(0xc0 | (0x02 << 4) | 0x01); // Handshake
    cw.writeU32(QUIC_VERSION_1);
    cw.writeU8(4);
    cw.writeBytes(dummyBytes[0 .. 4]);
    cw.writeU8(4);
    cw.writeBytes(dummyBytes[0 .. 4]);
    cw.writeVarInt(0); // Length = 0 -> invalid!
    cw.writeBytes(dummyBytes[0 .. 10]);
    PacketPrefix badLenPref;
    assert(parsePacketPrefix(cw.writtenSlice, 8, badLenPref) == WireError.invalidPacketHeader);
}
