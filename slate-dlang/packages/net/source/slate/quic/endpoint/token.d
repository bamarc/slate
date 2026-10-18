module slate.quic.endpoint.token;

/**
 * QUIC Stateless Retry Token Codec (RFC 9000 Section 8.1 & Section 17.2.5).
 *
 * Seals and verifies encrypted, authenticated tokens containing client address,
 * original destination connection ID, retry source connection ID, and timestamp
 * using AES-256-GCM.
 */

import slate.quic.crypto.aead : AeadKey;
import slate.quic.crypto.kdf : CipherSuite, QuicCryptoError;
import slate.quic.wire.cid : ConnectionId, TransportErrorCode;

/**
 * IP and port representation for QUIC address validation.
 */
public struct SocketAddr
{
    ubyte[16] ip;
    ushort port;
    bool isIpv6;

    static SocketAddr ipv4(ubyte a, ubyte b, ubyte c, ubyte d, ushort port) @safe pure @nogc nothrow
    {
        SocketAddr addr;
        addr.ip[0] = a;
        addr.ip[1] = b;
        addr.ip[2] = c;
        addr.ip[3] = d;
        addr.port = port;
        addr.isIpv6 = false;
        return addr;
    }

    static SocketAddr ipv6(const ref ubyte[16] ip6, ushort port) @safe pure @nogc nothrow
    {
        SocketAddr addr;
        addr.ip = ip6;
        addr.port = port;
        addr.isIpv6 = true;
        return addr;
    }

    bool opEquals(const ref SocketAddr other) const @safe pure @nogc nothrow
    {
        if (isIpv6 != other.isIpv6 || port != other.port)
            return false;
        const size_t len = isIpv6 ? 16 : 4;
        return ip[0 .. len] == other.ip[0 .. len];
    }
}

/**
 * Contents of a stateless Retry token.
 */
public struct RetryTokenPayload
{
    SocketAddr clientAddr;
    ConnectionId origDcid;
    ConnectionId retryScid;
    ulong issuedMicros;
    ulong nonceCounter;
}

public enum size_t MAX_RETRY_TOKEN_LEN = 128;

/**
 * AEAD codec for sealing and verifying stateless Retry tokens.
 */
public struct RetryTokenCodec
{
    @disable this(this);

private:
    AeadKey m_aead;
    bool m_initialized;

public:
     ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        AeadKey empty;
        m_aead.moveFrom(empty);
        m_initialized = false;
    }

    void init(const ref ubyte[32] secretKey, const ref ubyte[12] baseIv) @trusted @nogc nothrow
    {
        m_aead.init(CipherSuite.TLS_AES_256_GCM_SHA384, secretKey[], baseIv[]);
        m_initialized = m_aead.isInitialized;
    }

    void moveFrom(ref RetryTokenCodec other) @trusted @nogc nothrow
    {
        m_aead.moveFrom(other.m_aead);
        m_initialized = other.m_initialized;
        other.m_initialized = false;
    }

    @property bool isInitialized() const @safe pure @nogc nothrow
    {
        return m_initialized;
    }

    /**
     * Seals payload into outBuf.
     * Output format: [8 bytes nonceCounter] [AES-256-GCM ciphertext + 16 bytes tag]
     */
    bool sealToken(ref const RetryTokenPayload payload, ulong nonceCounter,
            ubyte[] outBuf, out size_t tokenLen) @safe @nogc nothrow
    {
        tokenLen = 0;
        if (!m_initialized)
            return false;

        // Serialize plaintext payload
        ubyte[96] plainBuf;
        size_t off = 0;

        // Header byte: version 1 | isIpv6 bit
        plainBuf[off++] = cast(ubyte)(0x01 | (payload.clientAddr.isIpv6 ? 0x02 : 0x00));

        // IP
        const size_t ipLen = payload.clientAddr.isIpv6 ? 16 : 4;
        plainBuf[off .. off + ipLen] = payload.clientAddr.ip[0 .. ipLen];
        off += ipLen;

        // Port (big endian)
        plainBuf[off++] = cast(ubyte)(payload.clientAddr.port >> 8);
        plainBuf[off++] = cast(ubyte)(payload.clientAddr.port & 0xFF);

        // origDcid
        if (payload.origDcid.len > 20)
            return false;
        plainBuf[off++] = payload.origDcid.len;
        if (payload.origDcid.len > 0)
        {
            plainBuf[off .. off + payload.origDcid.len] = payload.origDcid.asSlice()[];
            off += payload.origDcid.len;
        }

        // retryScid
        if (payload.retryScid.len > 20)
            return false;
        plainBuf[off++] = payload.retryScid.len;
        if (payload.retryScid.len > 0)
        {
            plainBuf[off .. off + payload.retryScid.len] = payload.retryScid.asSlice()[];
            off += payload.retryScid.len;
        }

        // issuedMicros (big endian 8 bytes)
        foreach_reverse (i; 0 .. 8)
        {
            plainBuf[off++] = cast(ubyte)((payload.issuedMicros >> (i * 8)) & 0xFF);
        }

        const size_t plainLen = off;
        const size_t totalNeeded = 8 + plainLen + 16;
        if (outBuf.length < totalNeeded)
            return false;

        // Write 8-byte nonceCounter prefix
        foreach_reverse (i; 0 .. 8)
        {
            outBuf[7 - i] = cast(ubyte)((nonceCounter >> (i * 8)) & 0xFF);
        }

        // Encrypt in-place in outBuf
        outBuf[8 .. 8 + plainLen] = plainBuf[0 .. plainLen];
        ubyte[] cipherSlice = outBuf[8 .. 8 + plainLen + 16];

        const err = m_aead.encryptInPlace(nonceCounter, outBuf[0 .. 8], cipherSlice, plainLen);
        if (err != QuicCryptoError.none)
            return false;

        tokenLen = totalNeeded;
        return true;
    }

    /**
     * Decrypts and authenticates a Retry token.
     * Verifies:
     * 1. AEAD integrity tag and decryption
     * 2. Client address matching
     * 3. Packet DCID matching Retry SCID
     * 4. Expiry within maxLifetimeMicros
     */
    TransportErrorCode verifyToken(const(ubyte)[] token, ref const SocketAddr clientAddr,
            ref const ConnectionId packetDcid, ulong nowMicros,
            ulong maxLifetimeMicros, out RetryTokenPayload payloadOut) @safe @nogc nothrow
    {
        payloadOut = RetryTokenPayload.init;
        if (!m_initialized || token.length < 8 + 1 + 4 + 2 + 1 + 1 + 8 + 16)
            return TransportErrorCode.invalidToken;

        // Parse 8-byte nonceCounter
        ulong nonceCounter = 0;
        foreach (i; 0 .. 8)
        {
            nonceCounter = (nonceCounter << 8) | token[i];
        }

        ubyte[128] workBuf;
        const size_t cipherLen = token.length - 8;
        if (cipherLen > workBuf.length)
            return TransportErrorCode.invalidToken;

        workBuf[0 .. cipherLen] = token[8 .. $];

        size_t plainLen = 0;
        const err = m_aead.decryptInPlace(nonceCounter, token[0 .. 8],
                workBuf[0 .. cipherLen], plainLen);
        if (err != QuicCryptoError.none)
            return TransportErrorCode.invalidToken;

        // Deserialize plaintext
        if (plainLen < 1 + 4 + 2 + 1 + 1 + 8)
            return TransportErrorCode.invalidToken;

        size_t off = 0;
        const ubyte hdrByte = workBuf[off++];
        // RFC 9000 version check (F-29): check version 1
        if ((hdrByte & ~0x02) != 0x01)
            return TransportErrorCode.invalidToken;

        const bool isIpv6 = (hdrByte & 0x02) != 0;
        const size_t ipLen = isIpv6 ? 16 : 4;

        if (off + ipLen + 2 > plainLen)
            return TransportErrorCode.invalidToken;

        SocketAddr decodedAddr;
        decodedAddr.isIpv6 = isIpv6;
        decodedAddr.ip[0 .. ipLen] = workBuf[off .. off + ipLen];
        off += ipLen;

        decodedAddr.port = cast(ushort)((cast(ushort) workBuf[off] << 8) | cast(
                ushort) workBuf[off + 1]);
        off += 2;

        // origDcid
        if (off >= plainLen)
            return TransportErrorCode.invalidToken;
        const ubyte origLen = workBuf[off++];
        if (origLen > 20 || off + origLen > plainLen)
            return TransportErrorCode.invalidToken;

        payloadOut.origDcid = ConnectionId(workBuf[off .. off + origLen]);
        off += origLen;

        // retryScid
        if (off >= plainLen)
            return TransportErrorCode.invalidToken;
        const ubyte retryLen = workBuf[off++];
        if (retryLen > 20 || off + retryLen > plainLen)
            return TransportErrorCode.invalidToken;

        payloadOut.retryScid = ConnectionId(workBuf[off .. off + retryLen]);
        off += retryLen;

        // issuedMicros
        if (off + 8 > plainLen)
            return TransportErrorCode.invalidToken;
        ulong issued = 0;
        foreach (i; 0 .. 8)
        {
            issued = (issued << 8) | workBuf[off++];
        }
        payloadOut.issuedMicros = issued;
        payloadOut.nonceCounter = nonceCounter;
        payloadOut.clientAddr = decodedAddr;

        // 1. Verify Client Address
        if (!(decodedAddr == clientAddr))
            return TransportErrorCode.invalidToken;

        // 2. Verify Destination Connection ID matches retryScid (RFC 9000 Section 8.1.3)
        if (packetDcid != payloadOut.retryScid)
            return TransportErrorCode.invalidToken;

        // 3. Verify Token Lifetime
        if (maxLifetimeMicros > 0)
        {
            if (nowMicros < issued)
                return TransportErrorCode.invalidToken; // Future timestamp invalid
            if (nowMicros - issued > maxLifetimeMicros)
                return TransportErrorCode.invalidToken; // Expired
        }

        return TransportErrorCode.noError;
    }
}

/// Example:
// Spec: RFC 9000 Section 8.1.3 & Section 17.2.5 - Stateless Retry Token Sealing and Verification (covers U1, U2, U3, E4, W3, F3, Scenario T5)
@nogc unittest
{
    const ubyte[32] serverKey = [
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b,
        0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f
    ];
    const ubyte[12] baseIv = [
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b
    ];

    RetryTokenCodec codec;
    codec.init(serverKey, baseIv);
    assert(codec.isInitialized);

    const SocketAddr clientAddr = SocketAddr.ipv4(192, 168, 1, 100, 4433);
    const ubyte[8] origBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] retryBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    const ConnectionId origDcid = ConnectionId(origBytes[]);
    const ConnectionId retryScid = ConnectionId(retryBytes[]);

    RetryTokenPayload payload;
    payload.clientAddr = clientAddr;
    payload.origDcid = origDcid;
    payload.retryScid = retryScid;
    payload.issuedMicros = 1_000_000;

    ubyte[128] tokenBuf;
    size_t tokenLen = 0;
    assert(codec.sealToken(payload, 42, tokenBuf[], tokenLen));
    assert(tokenLen > 0);

    // Verify valid token
    RetryTokenPayload decoded;
    const err = codec.verifyToken(tokenBuf[0 .. tokenLen], clientAddr,
            retryScid, 1_500_000, 10_000_000, decoded);
    assert(err == TransportErrorCode.noError);
    assert(decoded.clientAddr == clientAddr);
    assert(decoded.origDcid == origDcid);
    assert(decoded.retryScid == retryScid);
    assert(decoded.issuedMicros == 1_000_000);

    // Verify tamper rejection (F3, W3)
    ubyte[128] tamperedBuf = tokenBuf;
    tamperedBuf[20] ^= 0xFF;
    assert(codec.verifyToken(tamperedBuf[0 .. tokenLen], clientAddr, retryScid,
            1_500_000, 10_000_000, decoded) == TransportErrorCode.invalidToken);

    // Verify header byte version tamper rejection (F-29, D-12)
    ubyte[128] versionTamperedBuf = tokenBuf;
    versionTamperedBuf[0] = 0x88;
    assert(codec.verifyToken(versionTamperedBuf[0 .. tokenLen], clientAddr,
            retryScid, 1_500_000, 10_000_000, decoded) == TransportErrorCode.invalidToken);

    // Verify address mismatch rejection (W3)
    const SocketAddr wrongAddr = SocketAddr.ipv4(192, 168, 1, 101, 4433);
    assert(codec.verifyToken(tokenBuf[0 .. tokenLen], wrongAddr, retryScid,
            1_500_000, 10_000_000, decoded) == TransportErrorCode.invalidToken);

    // Verify DCID mismatch rejection (W3)
    const ConnectionId wrongDcid = ConnectionId(origBytes[]);
    assert(codec.verifyToken(tokenBuf[0 .. tokenLen], clientAddr, wrongDcid,
            1_500_000, 10_000_000, decoded) == TransportErrorCode.invalidToken);

    // Verify expiration rejection (W3)
    assert(codec.verifyToken(tokenBuf[0 .. tokenLen], clientAddr, retryScid,
            20_000_000, 10_000_000, decoded) == TransportErrorCode.invalidToken);
}

/// Example:
// Spec: Retry Token Codec RAII Movement (covers U2, G4)
@nogc unittest
{
    const ubyte[32] key = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] iv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

    RetryTokenCodec c1;
    c1.init(key, iv);
    assert(c1.isInitialized);

    RetryTokenCodec c2;
    c2.moveFrom(c1);
    assert(!c1.isInitialized);
    assert(c2.isInitialized);
}
