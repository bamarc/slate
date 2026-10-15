module slate.quic.crypto.header_protection;

import slate.quic.crypto.c_openssl;
import slate.quic.crypto.kdf;

/**
 * Encodes a packet number into truncated wire format (RFC 9000 Section 17.1 & Appendix A.2).
 */
void encodePacketNumber(ulong fullPn, size_t pnLen, ubyte[] outBuf) @safe @nogc nothrow pure
{
    foreach (i; 0 .. pnLen)
    {
        outBuf[i] = cast(ubyte)(fullPn >> ((pnLen - 1 - i) * 8));
    }
}

/**
 * Computes the minimum packet number encoding length in bytes (RFC 9000 Appendix A.2).
 */
size_t packetNumberLength(ulong fullPn, ulong largestAcked) @safe @nogc nothrow pure
{
    const ulong numUnacked = fullPn - largestAcked;
    const ulong minWin = numUnacked * 2;
    if (minWin < (1UL << 8))
        return 1;
    if (minWin < (1UL << 16))
        return 2;
    if (minWin < (1UL << 24))
        return 3;
    return 4;
}

/**
 * Decodes a truncated packet number given the largest acknowledged packet number (RFC 9000 Appendix A.3).
 */
ulong decodePacketNumber(ulong largestPn, ulong truncatedPn, size_t pnLen) @safe @nogc nothrow pure
{
    const ulong expectedPn = largestPn + 1;
    const ulong pnWin = 1UL << (pnLen * 8);
    const ulong pnHwin = pnWin / 2;
    const ulong pnMask = pnWin - 1;

    const ulong candidatePn = (expectedPn & ~pnMask) | truncatedPn;

    if (candidatePn + pnHwin <= expectedPn && candidatePn + pnWin < (1UL << 62))
        return candidatePn + pnWin;

    if (candidatePn > expectedPn + pnHwin && candidatePn >= pnWin)
        return candidatePn - pnWin;

    return candidatePn;
}

/**
 * RAII wrapper for Header Protection (RFC 9001 Section 5.4).
 *
 * Supports AES-128-ECB, AES-256-ECB, and ChaCha20 mask generation.
 */
struct HeaderProtectionKey
{
    @disable this(this);

private:
    EVP_CIPHER_CTX* m_ctx;
    CipherSuite m_suite;
    bool m_initialized;

public:
    /**
     * Initializes HeaderProtectionKey with cipher suite and HP key.
     */
    this(CipherSuite suite, const(ubyte)[] hpKey) @trusted @nogc nothrow
    {
        init(suite, hpKey);
    }

    /**
     * Initializes or re-initializes in-place.
     */
    void init(CipherSuite suite, const(ubyte)[] hpKey) @trusted @nogc nothrow
    {
        cleanup();

        m_suite = suite;
        const(EVP_CIPHER)* cipher;

        switch (suite)
        {
            case CipherSuite.TLS_AES_256_GCM_SHA384:
                cipher = EVP_aes_256_ecb();
                break;
            case CipherSuite.TLS_CHACHA20_POLY1305_SHA256:
                cipher = EVP_chacha20();
                break;
            case CipherSuite.TLS_AES_128_GCM_SHA256:
            default:
                cipher = EVP_aes_128_ecb();
                break;
        }

        m_ctx = EVP_CIPHER_CTX_new();
        if (m_ctx !is null && cipher !is null)
        {
            EVP_EncryptInit_ex(m_ctx, cipher, null, hpKey.ptr, null);
            if (suite != CipherSuite.TLS_CHACHA20_POLY1305_SHA256)
            {
                EVP_CIPHER_CTX_set_padding(m_ctx, 0);
            }
            m_initialized = true;
        }
    }

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    public void cleanup() @trusted @nogc nothrow
    {
        if (m_ctx !is null)
        {
            EVP_CIPHER_CTX_free(m_ctx);
            m_ctx = null;
        }
        m_initialized = false;
    }

    /**
     * Moves state from another HeaderProtectionKey.
     */
    void moveFrom(ref HeaderProtectionKey other) @trusted @nogc nothrow
    {
        cleanup();
        m_ctx = other.m_ctx;
        m_suite = other.m_suite;
        m_initialized = other.m_initialized;

        other.m_ctx = null;
        other.m_initialized = false;
    }

    @property bool isInitialized() const @safe @nogc nothrow pure
    {
        return m_initialized;
    }

    @property CipherSuite cipherSuite() const @safe @nogc nothrow pure
    {
        return m_suite;
    }

    /**
     * Computes the 5-byte header protection mask from a 16-byte sample (RFC 9001 Section 5.4.1).
     */
    QuicCryptoError computeMask(const(ubyte)[] sample, ref ubyte[5] maskOut) @trusted @nogc nothrow
    {
        if (!m_initialized || m_ctx is null)
            return QuicCryptoError.internalError;

        if (sample.length < 16)
            return QuicCryptoError.packetTooShort;

        int outl = 0;

        if (m_suite == CipherSuite.TLS_CHACHA20_POLY1305_SHA256)
        {
            // ChaCha20: the 16-byte sample is used as 4-byte counter + 12-byte nonce
            if (EVP_EncryptInit_ex(m_ctx, null, null, null, sample.ptr) <= 0)
                return QuicCryptoError.cryptoError;

            const ubyte[5] zeros = [0, 0, 0, 0, 0];
            if (EVP_EncryptUpdate(m_ctx, maskOut.ptr, &outl, zeros.ptr, 5) <= 0)
                return QuicCryptoError.cryptoError;
        }
        else
        {
            // AES-ECB: encrypt 16-byte sample with AES, mask is the first 5 bytes
            ubyte[16] blockOut;
            if (EVP_EncryptUpdate(m_ctx, blockOut.ptr, &outl, sample.ptr, 16) <= 0)
                return QuicCryptoError.cryptoError;

            maskOut[0 .. 5] = blockOut[0 .. 5];
        }

        return QuicCryptoError.none;
    }

    /**
     * Applies header protection to a packet header in-place (RFC 9001 Section 5.4.1).
     *
     * pnOffset is the byte offset of the packet number field.
     * pnLen is the length of the packet number field (1..4).
     */
    QuicCryptoError apply(
        ubyte[] packet,
        size_t pnOffset,
        size_t pnLen
    ) @trusted @nogc nothrow
    {
        if (packet.length < pnOffset + 4 + 16)
            return QuicCryptoError.packetTooShort;

        const size_t sampleOffset = pnOffset + 4;
        const(ubyte)[] sample = packet[sampleOffset .. sampleOffset + 16];

        ubyte[5] mask;
        const err = computeMask(sample, mask);
        if (err != QuicCryptoError.none)
            return err;

        const bool isLongHeader = (packet[0] & 0x80) != 0;
        if (isLongHeader)
        {
            packet[0] ^= (mask[0] & 0x0F);
        }
        else
        {
            packet[0] ^= (mask[0] & 0x1F);
        }

        foreach (i; 0 .. pnLen)
        {
            packet[pnOffset + i] ^= mask[1 + i];
        }

        return QuicCryptoError.none;
    }

    /**
     * Removes header protection from a packet header in-place (RFC 9001 Section 5.4.1).
     *
     * Decodes the packet number length and truncated packet number, and returns full packet number.
     */
    QuicCryptoError remove(
        ubyte[] packet,
        size_t pnOffset,
        ulong largestAcked,
        out size_t decodedPnLen,
        out ulong decodedPn
    ) @trusted @nogc nothrow
    {
        decodedPnLen = 0;
        decodedPn = 0;

        if (packet.length < pnOffset + 4 + 16)
            return QuicCryptoError.packetTooShort;

        const size_t sampleOffset = pnOffset + 4;
        const(ubyte)[] sample = packet[sampleOffset .. sampleOffset + 16];

        ubyte[5] mask;
        const err = computeMask(sample, mask);
        if (err != QuicCryptoError.none)
            return err;

        const bool isLongHeader = (packet[0] & 0x80) != 0;
        if (isLongHeader)
        {
            packet[0] ^= (mask[0] & 0x0F);
        }
        else
        {
            packet[0] ^= (mask[0] & 0x1F);
        }

        const size_t pnLen = (packet[0] & 0x03) + 1;
        if (packet.length < pnOffset + pnLen)
            return QuicCryptoError.packetTooShort;

        foreach (i; 0 .. pnLen)
        {
            packet[pnOffset + i] ^= mask[1 + i];
        }

        ulong truncatedPn = 0;
        foreach (i; 0 .. pnLen)
        {
            truncatedPn = (truncatedPn << 8) | packet[pnOffset + i];
        }

        decodedPnLen = pnLen;
        decodedPn = decodePacketNumber(largestAcked, truncatedPn, pnLen);

        return QuicCryptoError.none;
    }
}

/// Example:
// Spec: RFC 9001 Appendix A.2 - Client Initial Header Protection (covers E2, Scenario T2)
@nogc unittest
{
    const ubyte[16] hpKey = [
        0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10,
        0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2
    ];
    const ubyte[16] sample = [
        0xd1, 0xb1, 0xc9, 0x8d, 0xd7, 0x68, 0x9f, 0xb8,
        0xec, 0x11, 0xd2, 0x42, 0xb1, 0x23, 0xdc, 0x9b
    ];

    HeaderProtectionKey hp;
    hp.init(CipherSuite.TLS_AES_128_GCM_SHA256, hpKey);

    ubyte[5] mask;
    const err = hp.computeMask(sample, mask);
    assert(err == QuicCryptoError.none, "Mask computation failed");

    const ubyte[5] expectedMask = [0x43, 0x7b, 0x9a, 0xec, 0x36];
    assert(mask == expectedMask, "Header protection mask mismatch");
}

/// Example:
// Spec: RFC 9001 Appendix A.5 - ChaCha20 Header Protection (covers E3, Scenario T3)
@nogc unittest
{
    const ubyte[32] hpKey = [
        0x25, 0xa2, 0x82, 0xb9, 0xe8, 0x2f, 0x06, 0xf2,
        0x1f, 0x48, 0x89, 0x17, 0xa4, 0xfc, 0x8f, 0x1b,
        0x73, 0x57, 0x36, 0x85, 0x60, 0x85, 0x97, 0xd0,
        0xef, 0xcb, 0x07, 0x6b, 0x0a, 0xb7, 0xa7, 0xa4
    ];
    const ubyte[16] sample = [
        0x5e, 0x5c, 0xd5, 0x5c, 0x41, 0xf6, 0x90, 0x80,
        0x57, 0x5d, 0x79, 0x99, 0xc2, 0x5a, 0x5b, 0xfb
    ];

    HeaderProtectionKey hp;
    hp.init(CipherSuite.TLS_CHACHA20_POLY1305_SHA256, hpKey);

    ubyte[5] mask;
    const err = hp.computeMask(sample, mask);
    assert(err == QuicCryptoError.none, "Mask computation failed");

    const ubyte[5] expectedMask = [0xae, 0xfe, 0xfe, 0x7d, 0x03];
    assert(mask == expectedMask, "ChaCha20 header protection mask mismatch");
}

/// Example:
// Spec: RFC 9000 Appendix A.3 - Packet Number Encoding and Decoding (covers E2)
@nogc unittest
{
    // Test 1-byte decoding
    assert(decodePacketNumber(0x64, 0x65, 1) == 0x65);
    // Test 2-byte decoding
    assert(decodePacketNumber(0, 1, 2) == 1);
    // Test 4-byte decoding (Appendix A.2)
    assert(decodePacketNumber(0, 2, 4) == 2);
    // Test 3-byte decoding (Appendix A.5: pn 654360564)
    assert(decodePacketNumber(654360500, 49140, 3) == 654360564);
}
