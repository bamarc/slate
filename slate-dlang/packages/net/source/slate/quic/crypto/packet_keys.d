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

    void init(CipherSuite suite, const(ubyte)[] key, const(ubyte)[] iv, const(ubyte)[] hpKey) @trusted @nogc nothrow
    {
        aead.init(suite, key, iv);
        hp.init(suite, hpKey);
        initialized = aead.isInitialized && hp.isInitialized;
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
        cleanup();
        local.moveFrom(other.local);
        remote.moveFrom(other.remote);
        initialized = other.initialized;
        other.initialized = false;
    }
}

/**
 * 1-RTT Key Phase updater for Key Update (RFC 9001 Section 6).
 */
struct KeyPhaseUpdater
{
    @disable this(this);

private:
    CipherSuite m_suite;
    ubyte[48] m_currentSecret;
    ubyte[48] m_nextSecret;
    size_t m_secretLen;
    AeadKey m_currentAead;
    AeadKey m_nextAead;
    HeaderProtectionKey m_hp;
    ubyte m_keyPhase;
    bool m_initialized;

public:
    void init(CipherSuite suite, const(ubyte)[] appSecret, const(ubyte)[] hpKey) @trusted @nogc nothrow
    {
        m_suite = suite;
        m_secretLen = hashLength(suite);
        m_currentSecret[0 .. m_secretLen] = appSecret[0 .. m_secretLen];
        m_keyPhase = 0;

        KeyMaterial km;
        deriveKeyMaterial(suite, appSecret, km);
        m_currentAead.init(suite, km.key[0 .. km.keyLen], km.iv[0 .. 12]);

        deriveNextApplicationSecret(suite, m_currentSecret[0 .. m_secretLen],
                m_nextSecret[0 .. m_secretLen]);
        KeyMaterial nextKm;
        deriveKeyMaterial(suite, m_nextSecret[0 .. m_secretLen], nextKm);
        m_nextAead.init(suite, nextKm.key[0 .. nextKm.keyLen], nextKm.iv[0 .. 12]);

        m_hp.init(suite, hpKey);
        m_initialized = true;
    }

    void updateKeys() @trusted @nogc nothrow
    {
        m_keyPhase ^= 1;
        m_currentSecret[0 .. m_secretLen] = m_nextSecret[0 .. m_secretLen];
        m_currentAead.moveFrom(m_nextAead);

        deriveNextApplicationSecret(m_suite, m_currentSecret[0 .. m_secretLen],
                m_nextSecret[0 .. m_secretLen]);
        KeyMaterial nextKm;
        deriveKeyMaterial(m_suite, m_nextSecret[0 .. m_secretLen], nextKm);
        m_nextAead.init(m_suite, nextKm.key[0 .. nextKm.keyLen], nextKm.iv[0 .. 12]);
    }

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        m_currentAead.cleanup();
        m_nextAead.cleanup();
        m_hp.cleanup();
        m_initialized = false;
    }

    void moveFrom(ref KeyPhaseUpdater other) @trusted @nogc nothrow
    {
        cleanup();
        m_suite = other.m_suite;
        m_currentSecret = other.m_currentSecret;
        m_nextSecret = other.m_nextSecret;
        m_secretLen = other.m_secretLen;
        m_currentAead.moveFrom(other.m_currentAead);
        m_nextAead.moveFrom(other.m_nextAead);
        m_hp.moveFrom(other.m_hp);
        m_keyPhase = other.m_keyPhase;
        m_initialized = other.m_initialized;
        other.m_initialized = false;
    }

    @property ubyte keyPhase() const @safe @nogc nothrow pure
    {
        return m_keyPhase;
    }

    @property bool isInitialized() const @safe @nogc nothrow pure
    {
        return m_initialized;
    }

    @property ref AeadKey currentAead() return @safe @nogc nothrow pure
    {
        return m_currentAead;
    }

    @property ref AeadKey nextAead() return @safe @nogc nothrow pure
    {
        return m_nextAead;
    }

    @property ref HeaderProtectionKey hp() return @safe @nogc nothrow pure
    {
        return m_hp;
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
        return hpErr;
    }

    payloadOffset = pnOffset + pnLen;
    if (packetBuffer.length < payloadOffset + 16)
    {
        packetBuffer[0] = origFirstByte;
        packetBuffer[pnOffset .. pnOffset + pnLen] = origPnBytes[0 .. pnLen];
        return QuicCryptoError.packetTooShort;
    }

    const(ubyte)[] aad = packetBuffer[0 .. payloadOffset];
    ubyte[] payloadSlice = packetBuffer[payloadOffset .. $];

    const aeadErr = aead.decryptInPlace(decodedPn, aad, payloadSlice, plaintextLen);
    if (aeadErr != QuicCryptoError.none)
    {
        packetBuffer[0] = origFirstByte;
        packetBuffer[pnOffset .. pnOffset + pnLen] = origPnBytes[0 .. pnLen];
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

    KeyPhaseUpdater sender;
    sender.init(CipherSuite.TLS_AES_128_GCM_SHA256, appSecret, hpKey);

    KeyPhaseUpdater receiver;
    receiver.init(CipherSuite.TLS_AES_128_GCM_SHA256, appSecret, hpKey);

    assert(sender.keyPhase == 0, "Initial key phase must be 0");
    assert(receiver.keyPhase == 0, "Initial key phase must be 0");

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

    // Test KeyPhaseUpdater rotation
    sender.updateKeys();
    receiver.updateKeys();
    assert(sender.keyPhase == 1, "Key phase must toggle to 1");
    assert(receiver.keyPhase == 1, "Key phase must toggle to 1");

    // Part 2: TLS_AES_256_GCM_SHA384 (48-byte secret, 32-byte HP key)
    const ubyte[48] appSecret256 = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23,
        0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
        0x30
    ];
    const ubyte[32] hpKey256 = [
        0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c,
        0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47,
        0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50
    ];

    KeyPhaseUpdater updater256;
    updater256.init(CipherSuite.TLS_AES_256_GCM_SHA384, appSecret256, hpKey256);
    assert(updater256.keyPhase == 0);

    ubyte[48] nextSecret256;
    deriveNextApplicationSecret(CipherSuite.TLS_AES_256_GCM_SHA384, appSecret256, nextSecret256);
    assert(nextSecret256 != appSecret256, "Next AES-256 secret must differ from current");

    updater256.updateKeys();
    assert(updater256.keyPhase == 1, "Key phase must toggle to 1 for AES-256");
}
