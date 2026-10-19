module slate.quic.crypto.packet_keys;

import slate.quic.crypto.c_openssl;
import slate.quic.crypto.kdf;
import slate.quic.crypto.aead;
import slate.quic.crypto.header_protection;

/**
 * Directional keys for a single transmission direction (local or remote).
 */
struct DirectionalKeys
{
    @disable this(this);

    AeadKey aead;
    HeaderProtectionKey hp;
    bool initialized;

    this(CipherSuite suite, const(ubyte)[] key, const(ubyte)[] iv, const(ubyte)[] hpKey) @trusted @nogc nothrow
    {
        init(suite, key, iv, hpKey);
    }

    /// Initialises both keys; on any failure (unknown suite, short input, EVP error) nothing is
    /// retained and false is returned.
    bool init(CipherSuite suite, const(ubyte)[] key, const(ubyte)[] iv, const(ubyte)[] hpKey) @trusted @nogc nothrow
    {
        cleanup();
        if (!isSupportedSuite(suite))
            return false;
        const size_t reqKeyLen = keyLength(suite);
        const size_t reqHpLen = hpKeyLength(suite);
        if (key.length < reqKeyLen || iv.length < 12 || hpKey.length < reqHpLen)
            return false;

        if (!aead.init(suite, key, iv) || !hp.init(suite, hpKey))
        {
            cleanup();
            return false;
        }
        initialized = aead.isInitialized && hp.isInitialized;
        return initialized;
    }

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        aead.cleanup();
        hp.cleanup();
        initialized = false;
    }

    void moveFrom(ref DirectionalKeys other) @trusted @nogc nothrow
    {
        if (&this is &other)
            return;
        cleanup();
        aead.moveFrom(other.aead);
        hp.moveFrom(other.hp);
        initialized = other.initialized;
        other.initialized = false;
    }
}

/**
 * Bidirectional packet protection keys (local write keys + remote read keys).
 */
struct Keys
{
    @disable this(this);

    DirectionalKeys local;
    DirectionalKeys remote;
    bool initialized;

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        local.cleanup();
        remote.cleanup();
        initialized = false;
    }

    void moveFrom(ref Keys other) @trusted @nogc nothrow
    {
        if (&this is &other)
            return;
        cleanup();
        local.moveFrom(other.local);
        remote.moveFrom(other.remote);
        initialized = other.initialized;
        other.initialized = false;
    }
}

/**
 * Protects a QUIC packet in-place (RFC 9001 Section 5.3 & 5.4).
 *
 * packetBuffer must contain unprotected header + plaintext payload,
 * with at least 16 additional bytes for the AEAD authentication tag.
 */
QuicCryptoError protectPacket(ref DirectionalKeys keys, ulong packetNumber, size_t pnOffset,
        size_t pnLen, ubyte[] packetBuffer, size_t plaintextPayloadLen,
        out size_t protectedPacketLen) @trusted @nogc nothrow
{
    protectedPacketLen = 0;
    if (!keys.initialized)
        return QuicCryptoError.internalError;

    if (pnLen < 1 || pnLen > 4)
        return QuicCryptoError.invalidKeyLength;

    const size_t headerLen = pnOffset + pnLen;
    if (packetBuffer.length < headerLen + plaintextPayloadLen + 16)
        return QuicCryptoError.packetTooShort;

    const(ubyte)[] aad = packetBuffer[0 .. headerLen];
    ubyte[] payloadSlice = packetBuffer[headerLen .. headerLen + plaintextPayloadLen + 16];

    const err = keys.aead.encryptInPlace(packetNumber, aad, payloadSlice, plaintextPayloadLen);
    if (err != QuicCryptoError.none)
        return err;

    const hpErr = keys.hp.apply(packetBuffer, pnOffset, pnLen);
    if (hpErr != QuicCryptoError.none)
        return hpErr;

    protectedPacketLen = headerLen + plaintextPayloadLen + 16;
    return QuicCryptoError.none;
}

/**
 * Unprotects a QUIC packet in-place using separate HeaderProtectionKey and AeadKey handles (RFC 9001 Section 5.3 & 5.4).
 */
QuicCryptoError unprotectPacketWithAead(ref HeaderProtectionKey hp, ref AeadKey aead, size_t pnOffset, ulong largestAcked,
        ubyte[] packetBuffer, out size_t pnLen, out ulong decodedPn,
        out size_t payloadOffset, out size_t plaintextLen) @trusted @nogc nothrow
{
    pnLen = 0;
    decodedPn = 0;
    payloadOffset = 0;
    plaintextLen = 0;

    if (!hp.isInitialized || !aead.isInitialized)
        return QuicCryptoError.internalError;

    if (packetBuffer.length < pnOffset + 4 + 16)
        return QuicCryptoError.packetTooShort;

    // Save original header bytes to restore on any unprotect failure
    const ubyte origFirstByte = packetBuffer[0];
    ubyte[4] origPnBytes;
    const size_t maxPn = (packetBuffer.length - pnOffset >= 4) ? 4 : (packetBuffer.length - pnOffset);
    origPnBytes[0 .. maxPn] = packetBuffer[pnOffset .. pnOffset + maxPn];

    const hpErr = hp.remove(packetBuffer, pnOffset, largestAcked, pnLen, decodedPn);
    if (hpErr != QuicCryptoError.none)
    {
        packetBuffer[0] = origFirstByte;
        packetBuffer[pnOffset .. pnOffset + maxPn] = origPnBytes[0 .. maxPn];
        pnLen = 0;
        decodedPn = 0;
        return hpErr;
    }

    payloadOffset = pnOffset + pnLen;
    if (packetBuffer.length < payloadOffset + 16)
    {
        packetBuffer[0] = origFirstByte;
        packetBuffer[pnOffset .. pnOffset + pnLen] = origPnBytes[0 .. pnLen];
        pnLen = 0;
        decodedPn = 0;
        payloadOffset = 0;
        return QuicCryptoError.packetTooShort;
    }

    const(ubyte)[] aad = packetBuffer[0 .. payloadOffset];
    ubyte[] payloadSlice = packetBuffer[payloadOffset .. $];

    const aeadErr = aead.decryptInPlace(decodedPn, aad, payloadSlice, plaintextLen);
    if (aeadErr != QuicCryptoError.none)
    {
        packetBuffer[0] = origFirstByte;
        packetBuffer[pnOffset .. pnOffset + pnLen] = origPnBytes[0 .. pnLen];
        pnLen = 0;
        decodedPn = 0;
        payloadOffset = 0;
        plaintextLen = 0;
        return aeadErr;
    }

    return QuicCryptoError.none;
}

/**
 * Unprotects a QUIC packet in-place (RFC 9001 Section 5.3 & 5.4).
 *
 * packetBuffer contains the protected packet.
 */
QuicCryptoError unprotectPacket(ref DirectionalKeys keys, size_t pnOffset, ulong largestAcked, ubyte[] packetBuffer,
        out size_t pnLen, out ulong decodedPn, out size_t payloadOffset, out size_t plaintextLen) @trusted @nogc nothrow
{
    if (!keys.initialized)
        return QuicCryptoError.internalError;

    return unprotectPacketWithAead(keys.hp, keys.aead, pnOffset, largestAcked,
            packetBuffer, pnLen, decodedPn, payloadOffset, plaintextLen);
}

/// Example:
/// ---
/// // RFC 9001 Appendix A.2 client Initial keys protect a packet, and the same keys open it again
/// const ubyte[16] clientKey = [0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46,
///         0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d];
/// const ubyte[12] clientIv = [0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b, 0x46, 0xfb, 0x25, 0x5c];
/// const ubyte[16] clientHp = [0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10,
///         0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2];
/// DirectionalKeys keys;
/// keys.init(CipherSuite.TLS_AES_128_GCM_SHA256, clientKey, clientIv, clientHp);
/// ubyte[22 + 20 + 16] pkt;
/// pkt[0 .. 22] = [0xc3, 0, 0, 0, 1, 8, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 8, 0, 0, 0x44, 0x9e, 0, 0, 0, 2];
/// pkt[22 .. 42] = 0x06;                            // 20 bytes of payload
/// size_t protectedLen;
/// assert(protectPacket(keys, 2, 18, 4, pkt, 20, protectedLen) == QuicCryptoError.none);
/// size_t pnLen, payloadOffset, plainLen;
/// ulong pn;
/// assert(unprotectPacket(keys, 18, 0, pkt[0 .. protectedLen], pnLen, pn, payloadOffset, plainLen)
///         == QuicCryptoError.none);
/// assert(pn == 2 && payloadOffset == 22 && plainLen == 20 && pkt[22] == 0x06);
/// ---
// Spec: RFC 9001 Appendix A.2 - Client Initial Packet Protection & Unprotection (covers E2, W1, W2, Scenario T2)
@nogc unittest
{
    const ubyte[16] clientKey = [
        0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46, 0x77, 0x30, 0xef, 0xcb,
        0xe3, 0xb1, 0xa2, 0x2d
    ];
    const ubyte[12] clientIv = [
        0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b, 0x46, 0xfb, 0x25, 0x5c
    ];
    const ubyte[16] clientHp = [
        0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10, 0x28, 0x3a, 0x1e, 0x99,
        0x33, 0xad, 0xed, 0xd2
    ];

    DirectionalKeys keys;
    keys.init(CipherSuite.TLS_AES_128_GCM_SHA256, clientKey, clientIv, clientHp);

    // Unprotected header (22 bytes)
    const ubyte[22] unprotHeader = [
        0xc3, 0x00, 0x00, 0x00, 0x01, 0x08, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51,
        0x57, 0x08, 0x00, 0x00, 0x44, 0x9e, 0x00, 0x00, 0x00, 0x02
    ];

    // Plaintext payload (1162 bytes: CRYPTO frame + PADDING)
    const ubyte[245] cryptoFramePrefix = [
        0x06, 0x00, 0x40, 0xf1, 0x01, 0x00, 0x00, 0xed, 0x03, 0x03, 0xeb, 0xf8,
        0xfa, 0x56, 0xf1, 0x29, 0x39, 0xb9, 0x58, 0x4a, 0x38, 0x96, 0x47,
        0x2e, 0xc4, 0x0b, 0xb8, 0x63, 0xcf, 0xd3, 0xe8, 0x68, 0x04, 0xfe, 0x3a,
        0x47, 0xf0, 0x6a, 0x2b, 0x69, 0x48, 0x4c, 0x00, 0x00, 0x04, 0x13,
        0x01, 0x13, 0x02, 0x01, 0x00, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x10, 0x00,
        0x0e, 0x00, 0x00, 0x0b, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
        0x2e, 0x63, 0x6f, 0x6d, 0xff, 0x01, 0x00, 0x01, 0x00, 0x00, 0x0a, 0x00,
        0x08, 0x00, 0x06, 0x00, 0x1d, 0x00, 0x17, 0x00, 0x18, 0x00, 0x10,
        0x00, 0x07, 0x00, 0x05, 0x04, 0x61, 0x6c, 0x70, 0x6e, 0x00, 0x05, 0x00,
        0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x33, 0x00, 0x26, 0x00,
        0x24, 0x00, 0x1d, 0x00, 0x20, 0x93, 0x70, 0xb2, 0xc9, 0xca, 0xa4, 0x7f,
        0xba, 0xba, 0xf4, 0x55, 0x9f, 0xed, 0xba, 0x75, 0x3d, 0xe1, 0x71,
        0xfa, 0x71, 0xf5, 0x0f, 0x1c, 0xe1, 0x5d, 0x43, 0xe9, 0x94, 0xec, 0x74,
        0xd7, 0x48, 0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04, 0x00, 0x0d,
        0x00, 0x10, 0x00, 0x0e, 0x04, 0x03, 0x05, 0x03, 0x06, 0x03, 0x02, 0x03,
        0x08, 0x04, 0x08, 0x05, 0x08, 0x06, 0x00, 0x2d, 0x00, 0x02, 0x01,
        0x01, 0x00, 0x1c, 0x00, 0x02, 0x40, 0x01, 0x00, 0x39, 0x00, 0x32, 0x04,
        0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x05, 0x04,
        0x80, 0x00, 0xff, 0xff, 0x07, 0x04, 0x80, 0x00, 0xff, 0xff, 0x08, 0x01,
        0x10, 0x01, 0x04, 0x80, 0x00, 0x75, 0x30, 0x09, 0x01, 0x10, 0x0f,
        0x08, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08, 0x06, 0x04, 0x80,
        0x00, 0xff, 0xff
    ];

    ubyte[1200] pktBuffer;
    pktBuffer[0 .. 22] = unprotHeader[];
    pktBuffer[22 .. 22 + 245] = cryptoFramePrefix[];
    pktBuffer[22 + 245 .. 22 + 1162] = 0; // PADDING

    size_t protectedLen = 0;
    const protErr = protectPacket(keys, 2, 18, 4, pktBuffer, 1162, protectedLen);
    assert(protErr == QuicCryptoError.none, "protectPacket failed");
    assert(protectedLen == 1200, "Protected packet must be 1200 bytes");

    // Verify protected header prefix matches RFC 9001 Appendix A.2
    const ubyte[22] expectedProtHeader = [
        0xc0, 0x00, 0x00, 0x00, 0x01, 0x08, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51,
        0x57, 0x08, 0x00, 0x00, 0x44, 0x9e, 0x7b, 0x9a, 0xec, 0x34
    ];
    assert(pktBuffer[0 .. 22] == expectedProtHeader, "Protected header mismatch");

    // Verify first 16 bytes of ciphertext match Appendix A.2 sample
    const ubyte[16] expectedSample = [
        0xd1, 0xb1, 0xc9, 0x8d, 0xd7, 0x68, 0x9f, 0xb8, 0xec, 0x11, 0xd2, 0x42,
        0xb1, 0x23, 0xdc, 0x9b
    ];
    assert(pktBuffer[22 .. 38] == expectedSample, "Ciphertext sample mismatch");

    // Now test unprotect
    ubyte[1200] unprotBuffer = pktBuffer;
    size_t decPnLen = 0;
    ulong decPn = 0;
    size_t decPayOffset = 0;
    size_t decPlainLen = 0;

    const unprotErr = unprotectPacket(keys, 18, 0, unprotBuffer, decPnLen,
            decPn, decPayOffset, decPlainLen);
    assert(unprotErr == QuicCryptoError.none, "unprotectPacket failed");
    assert(decPn == 2, "Decoded packet number mismatch");
    assert(decPnLen == 4, "Decoded packet number length mismatch");
    assert(decPayOffset == 22, "Decoded payload offset mismatch");
    assert(decPlainLen == 1162, "Decoded plaintext length mismatch");
    assert(unprotBuffer[22 .. 22 + 245] == cryptoFramePrefix, "Decrypted CRYPTO frame mismatch");

    // Test tamper failure (W1) and verify buffer unmodified
    ubyte[1200] tamperedBuffer = pktBuffer;
    tamperedBuffer[50] ^= 0x01; // Tamper ciphertext
    const ubyte[1200] preTamper = tamperedBuffer;
    size_t tPnLen;
    ulong tPn;
    size_t tPayOff;
    size_t tPlainLen;
    const tamperErr = unprotectPacket(keys, 18, 0, tamperedBuffer, tPnLen,
            tPn, tPayOff, tPlainLen);
    assert(tamperErr == QuicCryptoError.aeadTagMismatch,
            "Tampered ciphertext must fail unprotection");
    assert(tamperedBuffer == preTamper,
            "Packet buffer must remain byte-for-byte unmodified on unprotect failure");

    // Test header AAD tamper failure (W1) and verify buffer unmodified
    ubyte[1200] tamperedAadBuffer = pktBuffer;
    tamperedAadBuffer[5] ^= 0x01; // Tamper version
    const ubyte[1200] preTamperAad = tamperedAadBuffer;
    const tamperAadErr = unprotectPacket(keys, 18, 0, tamperedAadBuffer,
            tPnLen, tPn, tPayOff, tPlainLen);
    assert(tamperAadErr == QuicCryptoError.aeadTagMismatch,
            "Tampered header AAD must fail unprotection");
    assert(tamperedAadBuffer == preTamperAad,
            "Packet buffer must remain byte-for-byte unmodified on AAD tamper failure");

    // Test short packet failure (W2)
    ubyte[30] shortBuffer = pktBuffer[0 .. 30]; // Too short for sample (needs 18 + 4 + 16 = 38)
    const shortErr = unprotectPacket(keys, 18, 0, shortBuffer, tPnLen, tPn, tPayOff, tPlainLen);
    assert(shortErr == QuicCryptoError.packetTooShort, "Short packet must fail with packetTooShort");
}

/// Example:
/// ---
/// // RFC 9001 Appendix A.3 server Initial keys protect a packet, and the same keys open it again
/// const ubyte[16] serverKey = [0xcf, 0x3a, 0x53, 0x31, 0x65, 0x3c, 0x36, 0x4c,
///         0x88, 0xf0, 0xf3, 0x79, 0xb6, 0x06, 0x7e, 0x37];
/// const ubyte[12] serverIv = [0x0a, 0xc1, 0x49, 0x3c, 0xa1, 0x90, 0x58, 0x53, 0xb0, 0xbb, 0xa0, 0x3e];
/// const ubyte[16] serverHp = [0xc2, 0x06, 0xb8, 0xd9, 0xb9, 0xf0, 0xf3, 0x76,
///         0x44, 0x43, 0x0b, 0x49, 0x0e, 0xea, 0xa3, 0x14];
/// DirectionalKeys keys;
/// keys.init(CipherSuite.TLS_AES_128_GCM_SHA256, serverKey, serverIv, serverHp);
/// ubyte[20 + 30 + 16] pkt;
/// pkt[0 .. 20] = [0xc1, 0, 0, 0, 1, 0, 8, 0xf0, 0x67, 0xa5, 0x50, 0x2a, 0x42, 0x62, 0xb5, 0, 0x40, 0x75, 0, 1];
/// pkt[20 .. 50] = 0x02;
/// size_t protLen;
/// assert(protectPacket(keys, 1, 18, 2, pkt, 30, protLen) == QuicCryptoError.none);
/// size_t pnLen, payloadOffset, plainLen;
/// ulong pn;
/// assert(unprotectPacket(keys, 18, 0, pkt[0 .. protLen], pnLen, pn, payloadOffset, plainLen)
///         == QuicCryptoError.none);
/// assert(pn == 1 && plainLen == 30 && pkt[20] == 0x02);
/// ---
// Spec: RFC 9001 Appendix A.3 - Server Initial Packet Protection & Unprotection (covers E2, Scenario T2)
@nogc unittest
{
    const ubyte[16] serverKey = [
        0xcf, 0x3a, 0x53, 0x31, 0x65, 0x3c, 0x36, 0x4c, 0x88, 0xf0, 0xf3, 0x79,
        0xb6, 0x06, 0x7e, 0x37
    ];
    const ubyte[12] serverIv = [
        0x0a, 0xc1, 0x49, 0x3c, 0xa1, 0x90, 0x58, 0x53, 0xb0, 0xbb, 0xa0, 0x3e
    ];
    const ubyte[16] serverHp = [
        0xc2, 0x06, 0xb8, 0xd9, 0xb9, 0xf0, 0xf3, 0x76, 0x44, 0x43, 0x0b, 0x49,
        0x0e, 0xea, 0xa3, 0x14
    ];

    DirectionalKeys keys;
    keys.init(CipherSuite.TLS_AES_128_GCM_SHA256, serverKey, serverIv, serverHp);

    const ubyte[20] header = [
        0xc1, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0xf0, 0x67, 0xa5, 0x50, 0x2a,
        0x42, 0x62, 0xb5, 0x00, 0x40, 0x75, 0x00, 0x01
    ];
    const ubyte[99] payload = [
        0x02, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x40, 0x5a, 0x02, 0x00, 0x00,
        0x56, 0x03, 0x03, 0xee, 0xfc, 0xe7, 0xf7, 0xb3, 0x7b, 0xa1, 0xd1,
        0x63, 0x2e, 0x96, 0x67, 0x78, 0x25, 0xdd, 0xf7, 0x39, 0x88, 0xcf, 0xc7,
        0x98, 0x25, 0xdf, 0x56, 0x6d, 0xc5, 0x43, 0x0b, 0x9a, 0x04, 0x5a,
        0x12, 0x00, 0x13, 0x01, 0x00, 0x00, 0x2e, 0x00, 0x33, 0x00, 0x24, 0x00,
        0x1d, 0x00, 0x20, 0x9d, 0x3c, 0x94, 0x0d, 0x89, 0x69, 0x0b, 0x84,
        0xd0, 0x8a, 0x60, 0x99, 0x3c, 0x14, 0x4e, 0xca, 0x68, 0x4d, 0x10, 0x81,
        0x28, 0x7c, 0x83, 0x4d, 0x53, 0x11, 0xbc, 0xf3, 0x2b, 0xb9, 0xda,
        0x1a, 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04
    ];

    ubyte[135] pktBuffer;
    pktBuffer[0 .. 20] = header[];
    pktBuffer[20 .. 119] = payload[];

    size_t protLen = 0;
    const protErr = protectPacket(keys, 1, 18, 2, pktBuffer, 99, protLen);
    assert(protErr == QuicCryptoError.none, "Server protectPacket failed");
    assert(protLen == 135, "Protected packet must be 135 bytes");

    const ubyte[20] expectedProtHeader = [
        0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0xf0, 0x67, 0xa5, 0x50, 0x2a,
        0x42, 0x62, 0xb5, 0x00, 0x40, 0x75, 0xc0, 0xd9
    ];
    assert(pktBuffer[0 .. 20] == expectedProtHeader, "Server protected header mismatch");

    // Unprotect and verify
    ubyte[135] unprotBuffer = pktBuffer;
    size_t decPnLen;
    ulong decPn;
    size_t decPayOff;
    size_t decPlainLen;
    const unprotErr = unprotectPacket(keys, 18, 0, unprotBuffer, decPnLen,
            decPn, decPayOff, decPlainLen);
    assert(unprotErr == QuicCryptoError.none, "Server unprotectPacket failed");
    assert(decPn == 1, "Server decoded packet number mismatch");
    assert(decPlainLen == 99, "Server decoded payload length mismatch");
    assert(unprotBuffer[20 .. 119] == payload, "Server decrypted payload mismatch");
}

/// Example:
/// ---
/// // RFC 9001 Appendix A.5 ChaCha20-Poly1305 keys protect a short header packet and open it again
/// const ubyte[32] key = [0xc6, 0xd9, 0x8f, 0xf3, 0x44, 0x1c, 0x3f, 0xe1, 0xb2,
///         0x18, 0x20, 0x94, 0xf6, 0x9c, 0xaa, 0x2e, 0xd4, 0xb7, 0x16, 0xb6, 0x54,
///         0x88, 0x96, 0x0a, 0x7a, 0x98, 0x49, 0x79, 0xfb, 0x23, 0xe1, 0xc8];
/// const ubyte[12] iv = [0xe0, 0x45, 0x9b, 0x34, 0x74, 0xbd, 0xd0, 0xe4, 0x4a, 0x41, 0xc1, 0x44];
/// const ubyte[32] hpKey = [0x25, 0xa2, 0x82, 0xb9, 0xe8, 0x2f, 0x06, 0xf2, 0x1f,
///         0x48, 0x89, 0x17, 0xa4, 0xfc, 0x8f, 0x1b, 0x73, 0x57, 0x36, 0x85, 0x60,
///         0x85, 0x97, 0xd0, 0xef, 0xcb, 0x07, 0x6b, 0x0a, 0xb7, 0xa7, 0xa4];
/// DirectionalKeys keys;
/// keys.init(CipherSuite.TLS_CHACHA20_POLY1305_SHA256, key, iv, hpKey);
/// ubyte[21] pkt;
/// pkt[0 .. 5] = [0x42, 0x00, 0xbf, 0xf4, 0x01];   // 1 + 3 byte header, 1 byte payload
/// size_t protLen;
/// assert(protectPacket(keys, 654360564, 1, 3, pkt, 1, protLen) == QuicCryptoError.none);
/// size_t pnLen, payloadOffset, plainLen;
/// ulong pn;
/// assert(unprotectPacket(keys, 1, 654360563, pkt[0 .. protLen], pnLen, pn, payloadOffset, plainLen)
///         == QuicCryptoError.none);
/// assert(pn == 654360564 && plainLen == 1 && pkt[4] == 0x01);
/// ---
// Spec: RFC 9001 Appendix A.5 - ChaCha20-Poly1305 Short Header Packet Protection (covers E3, Scenario T3)
@nogc unittest
{
    const ubyte[32] key = [
        0xc6, 0xd9, 0x8f, 0xf3, 0x44, 0x1c, 0x3f, 0xe1, 0xb2, 0x18, 0x20, 0x94,
        0xf6, 0x9c, 0xaa, 0x2e, 0xd4, 0xb7, 0x16, 0xb6, 0x54, 0x88, 0x96,
        0x0a, 0x7a, 0x98, 0x49, 0x79, 0xfb, 0x23, 0xe1, 0xc8
    ];
    const ubyte[12] iv = [
        0xe0, 0x45, 0x9b, 0x34, 0x74, 0xbd, 0xd0, 0xe4, 0x4a, 0x41, 0xc1, 0x44
    ];
    const ubyte[32] hpKey = [
        0x25, 0xa2, 0x82, 0xb9, 0xe8, 0x2f, 0x06, 0xf2, 0x1f, 0x48, 0x89, 0x17,
        0xa4, 0xfc, 0x8f, 0x1b, 0x73, 0x57, 0x36, 0x85, 0x60, 0x85, 0x97,
        0xd0, 0xef, 0xcb, 0x07, 0x6b, 0x0a, 0xb7, 0xa7, 0xa4
    ];

    DirectionalKeys keys;
    keys.init(CipherSuite.TLS_CHACHA20_POLY1305_SHA256, key, iv, hpKey);

    const ubyte[4] header = [0x42, 0x00, 0xbf, 0xf4];
    const ubyte[1] plaintext = [0x01];

    ubyte[21] pktBuffer;
    pktBuffer[0 .. 4] = header[];
    pktBuffer[4] = plaintext[0];

    size_t protLen = 0;
    const protErr = protectPacket(keys, 654360564, 1, 3, pktBuffer, 1, protLen);
    assert(protErr == QuicCryptoError.none, "ChaCha protectPacket failed");
    assert(protLen == 21, "Protected packet must be 21 bytes");

    const ubyte[21] expectedPacket = [
        0x4c, 0xfe, 0x41, 0x89, 0x65, 0x5e, 0x5c, 0xd5, 0x5c, 0x41, 0xf6, 0x90,
        0x80, 0x57, 0x5d, 0x79, 0x99, 0xc2, 0x5a, 0x5b, 0xfb
    ];
    assert(pktBuffer == expectedPacket, "ChaCha20-Poly1305 protected packet mismatch");

    // Unprotect
    ubyte[21] unprotBuffer = pktBuffer;
    size_t decPnLen;
    ulong decPn;
    size_t decPayOff;
    size_t decPlainLen;
    const unprotErr = unprotectPacket(keys, 1, 654360500, unprotBuffer,
            decPnLen, decPn, decPayOff, decPlainLen);
    assert(unprotErr == QuicCryptoError.none, "ChaCha unprotectPacket failed");
    assert(decPn == 654360564, "Decoded packet number mismatch");
    assert(decPlainLen == 1, "Decoded plaintext length mismatch");
    assert(unprotBuffer[4] == 0x01, "Decrypted payload mismatch");
}

/// Example:
/// ---
/// const suite = CipherSuite.TLS_AES_128_GCM_SHA256;
/// ubyte[32] appSecret = 0x5a;
/// ubyte[32] appSecret1;
/// assert(deriveNextApplicationSecret(suite, appSecret[], appSecret1[]));   // phase-1 secret
/// KeyMaterial km0, km1;
/// assert(deriveKeyMaterial(suite, appSecret[], km0) && deriveKeyMaterial(suite, appSecret1[], km1));
/// DirectionalKeys receiverPhase0Keys, senderPhase1Keys;
/// receiverPhase0Keys.init(suite, km0.key[0 .. km0.keyLen], km0.iv[0 .. 12], km0.hp[0 .. km0.hpLen]);
/// senderPhase1Keys.init(suite, km1.key[0 .. km1.keyLen], km1.iv[0 .. 12], km1.hp[0 .. km1.hpLen]);
/// ubyte[26] pkt;
/// pkt[0 .. 10] = [0x44, 0x02, 1, 2, 3, 4, 5, 6, 7, 8];   // short header (key phase 1), 8-byte payload
/// size_t protLen;
/// assert(protectPacket(senderPhase1Keys, 2, 1, 1, pkt, 8, protLen) == QuicCryptoError.none);
/// size_t pnLen, payOff, plainLen;
/// ulong pn;
/// // phase-1 keys come from the next secret, so the phase-0 keys cannot open the packet
/// assert(unprotectPacket(receiverPhase0Keys, 1, 1, pkt[0 .. protLen], pnLen, pn, payOff, plainLen)
///         == QuicCryptoError.aeadTagMismatch);
/// ---
// Spec: RFC 9001 Section 6 - Key Update rotation & Cross-Phase Rejection (covers E3, Scenario T4)
@nogc unittest
{
    // Part 1: TLS_AES_128_GCM_SHA256 (32-byte secret)
    const ubyte[32] appSecret = [
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x11, 0x21, 0x31, 0x41,
        0x51, 0x61, 0x71, 0x81, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72,
        0x82, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x73, 0x83
    ];
    const ubyte[16] hpKey = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10
    ];

    // Protect full packet at key phase 0
    ubyte[26] packet0 = [
        0x40, 0x01, // 1-RTT Short Header (Phase 0, pnLen = 1)
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, // 8 bytes plaintext
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0,
        0 // Tag space
    ];

    KeyMaterial km0;
    deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, appSecret, km0);
    DirectionalKeys senderPhase0Keys;
    senderPhase0Keys.init(CipherSuite.TLS_AES_128_GCM_SHA256,
            km0.key[0 .. km0.keyLen], km0.iv[0 .. 12], km0.hp[0 .. km0.hpLen]);
    DirectionalKeys receiverPhase0Keys;
    receiverPhase0Keys.init(CipherSuite.TLS_AES_128_GCM_SHA256,
            km0.key[0 .. km0.keyLen], km0.iv[0 .. 12], km0.hp[0 .. km0.hpLen]);

    size_t protLen0 = 0;
    const pErr0 = protectPacket(senderPhase0Keys, 1, 1, 1, packet0, 8, protLen0);
    assert(pErr0 == QuicCryptoError.none);

    // Receiver phase 0 decrypts packet0
    ubyte[26] decPkt0 = packet0;
    size_t dPnLen0;
    ulong dPn0;
    size_t dPayOff0;
    size_t dPlainLen0;
    const dErr0 = unprotectPacket(receiverPhase0Keys, 1, 0, decPkt0, dPnLen0,
            dPn0, dPayOff0, dPlainLen0);
    assert(dErr0 == QuicCryptoError.none);
    assert(dPlainLen0 == 8);
    assert(decPkt0[dPayOff0 .. dPayOff0 + 8] == [
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80
    ]);

    // Derive next phase secret and phase 1 keys
    ubyte[32] appSecret1;
    deriveNextApplicationSecret(CipherSuite.TLS_AES_128_GCM_SHA256, appSecret, appSecret1);
    KeyMaterial km1;
    deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, appSecret1, km1);
    DirectionalKeys senderPhase1Keys;
    senderPhase1Keys.init(CipherSuite.TLS_AES_128_GCM_SHA256,
            km1.key[0 .. km1.keyLen], km1.iv[0 .. 12], km1.hp[0 .. km1.hpLen]);

    // Protect packet at phase 1
    ubyte[26] packet1 = [
        0x44, 0x02, // 1-RTT Short Header (Phase 1 bit 0x04, pnLen = 1)
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, // 8 bytes plaintext
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0,
        0 // Tag space
    ];
    size_t protLen1 = 0;
    const pErr1 = protectPacket(senderPhase1Keys, 2, 1, 1, packet1, 8, protLen1);
    assert(pErr1 == QuicCryptoError.none);

    // Cross-phase rejection: Receiver with Phase 0 keys attempts to unprotect Phase 1 packet
    ubyte[26] crossPkt = packet1;
    const ubyte[26] preCross = packet1;
    size_t crossPnLen;
    ulong crossPn;
    size_t crossPayOff;
    size_t crossPlainLen;
    const crossErr = unprotectPacket(receiverPhase0Keys, 1, 1, crossPkt,
            crossPnLen, crossPn, crossPayOff, crossPlainLen);
    assert(crossErr == QuicCryptoError.aeadTagMismatch, "Phase 0 keys must reject Phase 1 packet");
    assert(crossPkt == preCross,
            "Packet buffer must remain byte-for-byte untouched when cross-phase decrypt fails");

    // Phase 1 keys unprotect successfully
    DirectionalKeys receiverPhase1Keys;
    receiverPhase1Keys.init(CipherSuite.TLS_AES_128_GCM_SHA256,
            km1.key[0 .. km1.keyLen], km1.iv[0 .. 12], km1.hp[0 .. km1.hpLen]);
    const succErr = unprotectPacket(receiverPhase1Keys, 1, 1, crossPkt,
            crossPnLen, crossPn, crossPayOff, crossPlainLen);
    assert(succErr == QuicCryptoError.none, "Phase 1 keys must decrypt Phase 1 packet");
    assert(crossPlainLen == 8);
    assert(crossPkt[crossPayOff .. crossPayOff + 8] == [
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22
    ]);
}

/// Example:
/// ---
/// // keys built from material of the wrong length stay uninitialised and refuse to protect
/// DirectionalKeys dKeys;
/// ubyte[10] shortKey, shortIv, shortHp;
/// dKeys.init(CipherSuite.TLS_AES_128_GCM_SHA256, shortKey, shortIv, shortHp);
/// assert(!dKeys.initialized);
/// ubyte[64] pktBuf;
/// size_t protLen;
/// assert(protectPacket(dKeys, 0, 1, 0, pktBuf, 10, protLen) == QuicCryptoError.internalError);
/// ---
// Spec: RFC 9001 / F-32, F-33 & F-41 - PacketKeys bounds validation, self-move guards, and cleanup
@nogc unittest
{
    DirectionalKeys dKeys;
    ubyte[10] shortKey;
    ubyte[10] shortIv;
    ubyte[10] shortHp;
    dKeys.init(CipherSuite.TLS_AES_128_GCM_SHA256, shortKey, shortIv, shortHp);
    assert(!dKeys.initialized);

    // Self-move guard on DirectionalKeys
    dKeys.moveFrom(dKeys);

    Keys keys;
    // Self-move guard on Keys
    keys.moveFrom(keys);

    // protectPacket with invalid pnLen
    ubyte[64] pktBuf;
    size_t protLen;
    assert(protectPacket(dKeys, 0, 1, 0, pktBuf, 10, protLen) == QuicCryptoError.internalError);
}

/// Example:
/// ---
/// const unknown = cast(CipherSuite) 0x1304;       // not one of the three QUIC suites
/// ubyte[32] key = 0x11;
/// ubyte[12] iv = 0x22;
/// ubyte[32] secret = 0x33;
/// AeadKey a;
/// assert(!a.init(unknown, key[], iv[]) && !a.isInitialized);   // no silent AES-128 fallback
/// KeyMaterial km;
/// assert(!deriveKeyMaterial(unknown, secret[], km) && km.keyLen == 0);
/// ---
// Spec: RFC 9001 Section 5.1 / 5.3 (the AEAD and HP algorithms follow the negotiated TLS 1.3
// cipher suite) - an unknown suite or a failing derivation must yield an error and an
// uninitialised object, never AES-128 keys (R-28, W11)
@nogc unittest
{
    const unknown = cast(CipherSuite) 0x1304;
    ubyte[32] key = 0x11;
    ubyte[12] iv = 0x22;
    ubyte[32] secret = 0x33;

    AeadKey aead;
    assert(!aead.init(unknown, key[], iv[]));
    assert(!aead.isInitialized);

    HeaderProtectionKey hp;
    assert(!hp.init(unknown, key[]));
    assert(!hp.isInitialized);

    KeyMaterial km;
    km.keyLen = 99;
    assert(!deriveKeyMaterial(unknown, secret[], km));
    assert(km.keyLen == 0 && km.key == (ubyte[32]).init, "failure must not leave key material");
    assert(!deriveKeyMaterial(CipherSuite.TLS_AES_256_GCM_SHA384,
            secret[0 .. 32], km), "SHA-384 suite needs a 48-byte secret");

    ubyte[48] next = 0x77;
    assert(!deriveNextApplicationSecret(unknown, secret[], next[]));
    foreach (b; next)
        assert(b == 0x77);

    DirectionalKeys dk;
    assert(!dk.init(unknown, key[], iv[], key[]));
    assert(!dk.initialized);

    // Control: the supported suites still work.
    foreach (suite; [
        CipherSuite.TLS_AES_128_GCM_SHA256, CipherSuite.TLS_AES_256_GCM_SHA384,
        CipherSuite.TLS_CHACHA20_POLY1305_SHA256
    ])
    {
        ubyte[48] sec = 0x44;
        KeyMaterial ok;
        assert(deriveKeyMaterial(suite, sec[0 .. hashLength(suite)], ok));
        assert(ok.keyLen == keyLength(suite));
        AeadKey good;
        assert(good.init(suite, ok.key[0 .. ok.keyLen], ok.iv[]) && good.isInitialized);
    }
}

/// Example:
/// ---
/// ubyte[16] key = 0x11, hpk = 0x22, key2 = 0x44;
/// ubyte[12] iv = 0x33;
/// DirectionalKeys good, wrongKeys;
/// assert(good.init(CipherSuite.TLS_AES_128_GCM_SHA256, key[], iv[], hpk[]));
/// assert(wrongKeys.init(CipherSuite.TLS_AES_128_GCM_SHA256, key2[], iv[], hpk[]));
/// ubyte[64] buf;
/// buf[0] = 0x41;                                  // short header, 2-byte packet number
/// buf[1 .. 9] = 0xA5;
/// buf[9 .. 11] = [0x01, 0x23];
/// buf[11 .. 31] = 0x7e;                           // 20 bytes of payload
/// size_t protLen, pnLen, payOff, plainLen;
/// ulong pn;
/// assert(protectPacket(good, 0x123, 9, 2, buf[], 20, protLen) == QuicCryptoError.none);
/// // keys with the same header protection key but another AEAD key: the tag does not verify
/// const err = unprotectPacket(wrongKeys, 9, 0, buf[0 .. protLen], pnLen, pn, payOff, plainLen);
/// assert(err == QuicCryptoError.aeadTagMismatch);
/// assert(pnLen == 0 && pn == 0 && payOff == 0 && plainLen == 0);   // no outputs on failure
/// ---
// Spec: RFC 9001 Section 5.4.1 / Section 5.3 - a packet that fails header unprotection or AEAD
// authentication yields no packet number: the decoded number and length must not leak out of a
// failed attempt, so a retry with another key generation never sees stale values (R-41, W23)
@nogc unittest
{
    ubyte[16] key = 0x11, hpk = 0x22;
    ubyte[12] iv = 0x33;
    DirectionalKeys good, other;
    assert(good.init(CipherSuite.TLS_AES_128_GCM_SHA256, key[], iv[], hpk[]));
    ubyte[16] key2 = 0x44;
    assert(other.init(CipherSuite.TLS_AES_128_GCM_SHA256, key2[], iv[], hpk[]));

    ubyte[64] pkt;
    pkt[0] = 0x41; // short header, pn length 2, key phase 0
    pkt[1 .. 9] = 0xA5;
    const size_t pnOff = 9;
    const size_t pnLen = 2;
    const size_t plain = 20;
    pkt[pnOff] = 0x01;
    pkt[pnOff + 1] = 0x23;
    pkt[pnOff + pnLen .. pnOff + pnLen + plain] = 0x7e;
    size_t protLen;
    assert(protectPacket(good, 0x123, pnOff, pnLen, pkt[], plain, protLen) == QuicCryptoError.none);
    ubyte[64] orig = pkt;

    size_t dl = 99, po = 99, pl = 99;
    ulong dpn = 99;
    // Header protection of `other` uses the same hp key, so the pn is decoded, then AEAD fails.
    ubyte[64] work = orig;
    assert(unprotectPacket(other, pnOff, 0, work[0 .. protLen], dl, dpn, po,
            pl) == QuicCryptoError.aeadTagMismatch);
    assert(dl == 0 && dpn == 0 && po == 0 && pl == 0, "no outputs after an AEAD failure");
    assert(work == orig, "buffer restored");

    // Too short for a tag after the packet number.
    dl = 99;
    dpn = 99;
    po = 99;
    pl = 99;
    ubyte[64] shortBuf = orig;
    assert(unprotectPacket(good, pnOff, 0, shortBuf[0 .. pnOff + 4 + 16], dl, dpn,
            po, pl) != QuicCryptoError.none);
    assert(dl == 0 && dpn == 0 && po == 0 && pl == 0);

    // The good key still works and yields the packet number.
    work = orig;
    assert(unprotectPacket(good, pnOff, 0x100, work[0 .. protLen], dl, dpn, po,
            pl) == QuicCryptoError.none);
    assert(dpn == 0x123 && dl == 2 && pl == plain);
}
