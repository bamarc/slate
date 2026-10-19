module slate.quic.crypto.aead;

import slate.quic.crypto.c_openssl;
import slate.quic.crypto.kdf;

/**
 * RFC 9001 Section 5.8 fixed key and nonce for Retry Packet Integrity Tag.
 */
immutable ubyte[16] RETRY_KEY_V1 = [
    0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a, 0x1d, 0x76, 0x6b, 0x54,
    0xe3, 0x68, 0xc8, 0x4e
];
immutable ubyte[12] RETRY_NONCE_V1 = [
    0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2, 0x23, 0x98, 0x25, 0xbb
];

/**
 * RAII wrapper for AEAD packet encryption and decryption (RFC 9001 Section 5.3).
 *
 * Holds pre-initialized OpenSSL EVP_CIPHER_CTX handles to avoid heap allocations
 * on the per-packet hot path.
 */
struct AeadKey
{
    @disable this(this);

private:
    EVP_CIPHER_CTX* m_encCtx;
    EVP_CIPHER_CTX* m_decCtx;
    CipherSuite m_suite;
    ubyte[12] m_iv;
    bool m_initialized;

public:
    /**
     * Initializes an AeadKey with a cipher suite, key, and IV.
     */
    this(CipherSuite suite, const(ubyte)[] key, const(ubyte)[] iv) @trusted @nogc nothrow
    {
        init(suite, key, iv);
    }

    /**
     * Re-initializes or initializes in-place.
     */
    bool init(CipherSuite suite, const(ubyte)[] key, const(ubyte)[] iv) @trusted @nogc nothrow
    {
        cleanup();

        // An unknown suite must never silently become AES-128-GCM.
        if (!isSupportedSuite(suite))
            return false;
        const size_t reqKeyLen = keyLength(suite);
        if (key.length < reqKeyLen || iv.length < 12)
            return false;

        m_suite = suite;
        m_iv[0 .. 12] = iv[0 .. 12];

        const(EVP_CIPHER)* cipher;
        switch (suite)
        {
        case CipherSuite.TLS_AES_256_GCM_SHA384:
            cipher = EVP_aes_256_gcm();
            break;
        case CipherSuite.TLS_CHACHA20_POLY1305_SHA256:
            cipher = EVP_chacha20_poly1305();
            break;
        case CipherSuite.TLS_AES_128_GCM_SHA256:
            cipher = EVP_aes_128_gcm();
            break;
        default:
            return false; // unreachable: isSupportedSuite above
        }

        m_encCtx = EVP_CIPHER_CTX_new();
        m_decCtx = EVP_CIPHER_CTX_new();

        if (m_encCtx !is null && m_decCtx !is null && cipher !is null)
        {
            if (EVP_EncryptInit_ex(m_encCtx, cipher, null, key.ptr, null) > 0
                    && EVP_DecryptInit_ex(m_decCtx, cipher, null, key.ptr, null) > 0)
            {
                m_initialized = true;
                return true;
            }
        }
        cleanup();
        return false;
    }

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    public void cleanup() @trusted @nogc nothrow
    {
        if (m_encCtx !is null)
        {
            EVP_CIPHER_CTX_free(m_encCtx);
            m_encCtx = null;
        }
        if (m_decCtx !is null)
        {
            EVP_CIPHER_CTX_free(m_decCtx);
            m_decCtx = null;
        }
        m_initialized = false;
    }

    /**
     * Move state from another AeadKey.
     */
    void moveFrom(ref AeadKey other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;
        cleanup();
        m_encCtx = other.m_encCtx;
        m_decCtx = other.m_decCtx;
        m_suite = other.m_suite;
        m_iv = other.m_iv;
        m_initialized = other.m_initialized;

        other.m_encCtx = null;
        other.m_decCtx = null;
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
     * Derives the 12-byte AEAD nonce by XORing IV with the reconstructed packet number (RFC 9001 Section 5.3).
     */
    void deriveNonce(ulong packetNumber, ref ubyte[12] nonceOut) const @safe @nogc nothrow pure
    {
        nonceOut = m_iv;
        nonceOut[4] ^= cast(ubyte)(packetNumber >> 56);
        nonceOut[5] ^= cast(ubyte)(packetNumber >> 48);
        nonceOut[6] ^= cast(ubyte)(packetNumber >> 40);
        nonceOut[7] ^= cast(ubyte)(packetNumber >> 32);
        nonceOut[8] ^= cast(ubyte)(packetNumber >> 24);
        nonceOut[9] ^= cast(ubyte)(packetNumber >> 16);
        nonceOut[10] ^= cast(ubyte)(packetNumber >> 8);
        nonceOut[11] ^= cast(ubyte)(packetNumber & 0xFF);
    }

    /**
     * Encrypts plaintext in-place and appends the 16-byte authentication tag (RFC 9001 Section 5.3).
     *
     * inoutPayload must have length >= plaintextLen + 16.
     */
    QuicCryptoError encryptInPlace(ulong packetNumber, const(ubyte)[] aad,
            ubyte[] inoutPayload, size_t plaintextLen) @trusted @nogc nothrow
    {
        if (!m_initialized || m_encCtx is null)
            return QuicCryptoError.internalError;

        if (inoutPayload.length < plaintextLen + 16)
            return QuicCryptoError.packetTooShort;

        ubyte[12] nonce;
        deriveNonce(packetNumber, nonce);

        if (EVP_EncryptInit_ex(m_encCtx, null, null, null, nonce.ptr) <= 0)
            return QuicCryptoError.cryptoError;

        int outl = 0;
        if (aad.length > 0)
        {
            if (EVP_EncryptUpdate(m_encCtx, null, &outl, aad.ptr, cast(int) aad.length) <= 0)
                return QuicCryptoError.cryptoError;
        }

        outl = 0;
        if (plaintextLen > 0)
        {
            if (EVP_EncryptUpdate(m_encCtx, inoutPayload.ptr, &outl,
                    inoutPayload.ptr, cast(int) plaintextLen) <= 0)
                return QuicCryptoError.cryptoError;
        }

        int finl = 0;
        if (EVP_EncryptFinal_ex(m_encCtx, inoutPayload.ptr + outl, &finl) <= 0)
            return QuicCryptoError.cryptoError;

        if (EVP_CIPHER_CTX_ctrl(m_encCtx, EVP_CTRL_AEAD_GET_TAG, 16,
                inoutPayload.ptr + plaintextLen) <= 0)
            return QuicCryptoError.cryptoError;

        return QuicCryptoError.none;
    }

    /**
     * Decrypts ciphertext in-place and verifies the 16-byte authentication tag (RFC 9001 Section 5.3).
     *
     * inoutPayload contains ciphertext || tag.
     */
    QuicCryptoError decryptInPlace(ulong packetNumber, const(ubyte)[] aad,
            ubyte[] inoutPayload, out size_t plaintextLen) @trusted @nogc nothrow
    {
        plaintextLen = 0;

        if (!m_initialized || m_decCtx is null)
            return QuicCryptoError.internalError;

        if (inoutPayload.length < 16)
            return QuicCryptoError.packetTooShort;

        const size_t cipherLen = inoutPayload.length - 16;
        const(ubyte)* tagPtr = inoutPayload.ptr + cipherLen;

        ubyte[12] nonce;
        deriveNonce(packetNumber, nonce);

        if (EVP_DecryptInit_ex(m_decCtx, null, null, null, nonce.ptr) <= 0)
            return QuicCryptoError.cryptoError;

        if (EVP_CIPHER_CTX_ctrl(m_decCtx, EVP_CTRL_AEAD_SET_TAG, 16, cast(void*) tagPtr) <= 0)
            return QuicCryptoError.cryptoError;

        int outl = 0;
        if (aad.length > 0)
        {
            if (EVP_DecryptUpdate(m_decCtx, null, &outl, aad.ptr, cast(int) aad.length) <= 0)
                return QuicCryptoError.cryptoError;
        }

        ubyte[2048] stackTemp;
        ubyte* tempBuf = stackTemp.ptr;
        bool isHeapAllocated = false;

        if (cipherLen > stackTemp.length)
        {
            import core.stdc.stdlib : malloc;

            tempBuf = cast(ubyte*) malloc(cipherLen);
            if (tempBuf is null)
                return QuicCryptoError.internalError;
            isHeapAllocated = true;
        }

        scope (exit)
        {
            if (isHeapAllocated)
            {
                import core.stdc.stdlib : free;

                free(tempBuf);
            }
        }

        outl = 0;
        if (cipherLen > 0)
        {
            if (EVP_DecryptUpdate(m_decCtx, tempBuf, &outl, inoutPayload.ptr,
                    cast(int) cipherLen) <= 0)
                return QuicCryptoError.aeadTagMismatch;
        }

        int finl = 0;
        if (EVP_DecryptFinal_ex(m_decCtx, tempBuf + outl, &finl) <= 0)
            return QuicCryptoError.aeadTagMismatch;

        // Tag verification succeeded: copy plaintext into inoutPayload
        if (cipherLen > 0)
            inoutPayload[0 .. cipherLen] = tempBuf[0 .. cipherLen];

        plaintextLen = cipherLen;
        return QuicCryptoError.none;
    }
}

/**
 * Computes the 16-byte Retry Packet Integrity Tag (RFC 9001 Section 5.8).
 */
bool computeRetryIntegrityTag(const(ubyte)[] originalDcid,
        const(ubyte)[] retryPacketWithoutTag, ref ubyte[16] tagOut) @trusted @nogc nothrow
{
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (ctx is null)
        return false;
    scope (exit)
        EVP_CIPHER_CTX_free(ctx);

    if (EVP_EncryptInit_ex(ctx, EVP_aes_128_gcm(), null, RETRY_KEY_V1.ptr, RETRY_NONCE_V1.ptr) <= 0)
        return false;

    // Retry pseudo-packet:
    // ODCIL (1 byte) || Original DCID || retryPacketWithoutTag
    const ubyte odcil = cast(ubyte) originalDcid.length;
    int outl = 0;

    if (EVP_EncryptUpdate(ctx, null, &outl, &odcil, 1) <= 0)
        return false;
    if (originalDcid.length > 0)
    {
        if (EVP_EncryptUpdate(ctx, null, &outl, originalDcid.ptr,
                cast(int) originalDcid.length) <= 0)
            return false;
    }
    if (retryPacketWithoutTag.length > 0)
    {
        if (EVP_EncryptUpdate(ctx, null, &outl, retryPacketWithoutTag.ptr,
                cast(int) retryPacketWithoutTag.length) <= 0)
            return false;
    }

    int finl = 0;
    ubyte dummy = 0;
    if (EVP_EncryptFinal_ex(ctx, &dummy, &finl) <= 0)
        return false;

    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, 16, tagOut.ptr) <= 0)
        return false;

    return true;
}

/**
 * Verifies the 16-byte Retry Packet Integrity Tag (RFC 9001 Section 5.8) using constant-time comparison.
 */
bool verifyRetryIntegrityTag(const(ubyte)[] originalDcid, const(ubyte)[] retryPacketWithTag) @trusted @nogc nothrow
{
    if (retryPacketWithTag.length < 16)
        return false;

    const size_t pktLenNoTag = retryPacketWithTag.length - 16;
    ubyte[16] computedTag;
    if (!computeRetryIntegrityTag(originalDcid, retryPacketWithTag[0 .. pktLenNoTag], computedTag))
        return false;

    return CRYPTO_memcmp(computedTag.ptr, retryPacketWithTag.ptr + pktLenNoTag, 16) == 0;
}

/// Example:
/// ---
/// const ubyte[8] originalDcid = [0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08];   // RFC 9001 A.4
/// const ubyte[20] retryPktWithoutTag = [
///     0xff, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0xf0, 0x67, 0xa5, 0x50, 0x2a,
///     0x42, 0x62, 0xb5, 0x74, 0x6f, 0x6b, 0x65, 0x6e
/// ];
/// ubyte[16] tag;
/// computeRetryIntegrityTag(originalDcid, retryPktWithoutTag, tag);
///
/// ubyte[36] retryPacket;
/// retryPacket[0 .. 20] = retryPktWithoutTag[];
/// retryPacket[20 .. 36] = tag[];
/// assert(verifyRetryIntegrityTag(originalDcid, retryPacket));
/// retryPacket[35] ^= 0x01;
/// assert(!verifyRetryIntegrityTag(originalDcid, retryPacket));
/// ---
// Spec: RFC 9001 Section 5.8 & Appendix A.4 - Retry Packet Integrity Tag (covers E4, Scenario T3)
@nogc unittest
{
    const ubyte[8] originalDcid = [
        0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08
    ];
    const ubyte[20] retryPktWithoutTag = [
        0xff, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0xf0, 0x67, 0xa5, 0x50, 0x2a,
        0x42, 0x62, 0xb5, 0x74, 0x6f, 0x6b, 0x65, 0x6e
    ];

    ubyte[16] tag;
    computeRetryIntegrityTag(originalDcid, retryPktWithoutTag, tag);

    const ubyte[16] expectedTag = [
        0x04, 0xa2, 0x65, 0xba, 0x2e, 0xff, 0x4d, 0x82, 0x90, 0x58, 0xfb, 0x3f,
        0x0f, 0x24, 0x96, 0xba
    ];
    assert(tag == expectedTag, "Retry integrity tag mismatch");

    ubyte[36] fullRetryPacket;
    fullRetryPacket[0 .. 20] = retryPktWithoutTag[];
    fullRetryPacket[20 .. 36] = tag[];
    assert(verifyRetryIntegrityTag(originalDcid, fullRetryPacket), "Valid retry packet must verify");

    // Corrupt one byte of tag
    fullRetryPacket[35] ^= 0x01;
    assert(!verifyRetryIntegrityTag(originalDcid, fullRetryPacket),
            "Corrupted retry packet must not verify");
}

/// Example:
/// ---
/// const ubyte[32] key = [0xc6, 0xd9, 0x8f, 0xf3, 0x44, 0x1c, 0x3f, 0xe1, 0xb2,
///         0x18, 0x20, 0x94, 0xf6, 0x9c, 0xaa, 0x2e, 0xd4, 0xb7, 0x16, 0xb6, 0x54,
///         0x88, 0x96, 0x0a, 0x7a, 0x98, 0x49, 0x79, 0xfb, 0x23, 0xe1, 0xc8];
/// const ubyte[12] iv = [0xe0, 0x45, 0x9b, 0x34, 0x74, 0xbd, 0xd0, 0xe4, 0x4a, 0x41, 0xc1, 0x44];
/// AeadKey aead;
/// assert(aead.init(CipherSuite.TLS_CHACHA20_POLY1305_SHA256, key, iv));   // RFC 9001 A.5 key and IV
///
/// const ulong pn = 654360564;
/// const ubyte[4] aad = [0x42, 0x00, 0xbf, 0xf4];
/// ubyte[17] payloadBuf;
/// payloadBuf[0] = 0x01;
/// assert(aead.encryptInPlace(pn, aad, payloadBuf, 1) == QuicCryptoError.none);
///
/// size_t decryptedLen;
/// const decErr = aead.decryptInPlace(pn, aad, payloadBuf, decryptedLen);
/// assert(decErr == QuicCryptoError.none);
/// assert(decryptedLen == 1 && payloadBuf[0] == 0x01);
/// ---
// Spec: RFC 9001 Appendix A.5 - ChaCha20-Poly1305 Payload Protection (covers E3, Scenario T3)
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

    AeadKey aead;
    aead.init(CipherSuite.TLS_CHACHA20_POLY1305_SHA256, key, iv);

    const ulong pn = 654360564;
    const ubyte[4] aad = [0x42, 0x00, 0xbf, 0xf4];
    const ubyte[1] plaintext = [0x01];

    ubyte[17] payloadBuf;
    payloadBuf[0] = plaintext[0];

    const err = aead.encryptInPlace(pn, aad, payloadBuf, 1);
    assert(err == QuicCryptoError.none, "Encryption failed");

    const ubyte[17] expectedCiphertext = [
        0x65, 0x5e, 0x5c, 0xd5, 0x5c, 0x41, 0xf6, 0x90, 0x80, 0x57, 0x5d, 0x79,
        0x99, 0xc2, 0x5a, 0x5b, 0xfb
    ];
    assert(payloadBuf == expectedCiphertext, "ChaCha20-Poly1305 ciphertext mismatch");

    // Decrypt in-place
    size_t decryptedLen = 0;
    const decErr = aead.decryptInPlace(pn, aad, payloadBuf, decryptedLen);
    assert(decErr == QuicCryptoError.none, "Decryption failed");
    assert(decryptedLen == 1, "Decrypted length mismatch");
    assert(payloadBuf[0] == 0x01, "Decrypted plaintext mismatch");

    // Test tamper failure (W1)
    payloadBuf[0] ^= 0x40;
    size_t tamperLen = 0;
    const tamperErr = aead.decryptInPlace(pn, aad, payloadBuf, tamperLen);
    assert(tamperErr == QuicCryptoError.aeadTagMismatch,
            "Tampered ciphertext must fail AEAD tag check");
}

/// Example:
/// ---
/// const ubyte[16] key = 0x5A;
/// const ubyte[12] iv = 0x3C;
/// AeadKey aead;
/// assert(aead.init(CipherSuite.TLS_AES_128_GCM_SHA256, key, iv));
///
/// const ubyte[20] aad = 0xAA;
/// ubyte[16] payloadBuf = 0;   // 0 bytes of plaintext + the 16-byte tag
/// assert(aead.encryptInPlace(1, aad, payloadBuf, 0) == QuicCryptoError.none);
///
/// size_t decLen = 99;
/// assert(aead.decryptInPlace(1, aad, payloadBuf, decLen) == QuicCryptoError.none);
/// assert(decLen == 0);
/// ---
// Spec: RFC 9001 Section 5.3 - Zero-length payload encryption and authentication (covers W1)
@nogc unittest
{
    const ubyte[16] key = 0x5A;
    const ubyte[12] iv = 0x3C;
    AeadKey aead;
    aead.init(CipherSuite.TLS_AES_128_GCM_SHA256, key, iv);

    const ubyte[20] aad = 0xAA;
    ubyte[16] payloadBuf = 0; // 0-byte plaintext + 16-byte tag

    const encErr = aead.encryptInPlace(1, aad, payloadBuf, 0);
    assert(encErr == QuicCryptoError.none, "Zero-length payload encryption failed");

    size_t decLen = 99;
    const decErr = aead.decryptInPlace(1, aad, payloadBuf, decLen);
    assert(decErr == QuicCryptoError.none, "Zero-length payload decryption failed");
    assert(decLen == 0, "Decrypted length must be 0");
}

/// Example:
/// ---
/// AeadKey aead;
/// const ubyte[15] shortKey = 0xAA;   // AES-128 needs 16 bytes
/// const ubyte[12] validIv = 0x55;
/// assert(!aead.init(CipherSuite.TLS_AES_128_GCM_SHA256, shortKey, validIv));
/// assert(!aead.isInitialized);
///
/// const ubyte[16] validKey = 0xAA;
/// const ubyte[11] shortIv = 0x55;    // the IV needs 12 bytes
/// assert(!aead.init(CipherSuite.TLS_AES_128_GCM_SHA256, validKey, shortIv));
/// assert(!aead.isInitialized);   // still uninitialised
/// ---
// Spec: RFC 9001 Section 5.3 & Scenario T5 - Key/IV Length Validation and Self-Move Safety (covers W2, F-32, F-33)
@nogc unittest
{
    AeadKey aead;
    const ubyte[15] shortKey = 0xAA; // 15 bytes < 16 bytes required for AES-128
    const ubyte[12] validIv = 0x55;
    assert(!aead.init(CipherSuite.TLS_AES_128_GCM_SHA256, shortKey, validIv));
    assert(!aead.isInitialized, "Short key must fail initialization");

    const ubyte[16] validKey = 0xAA;
    const ubyte[11] shortIv = 0x55; // 11 bytes < 12 bytes required
    assert(!aead.init(CipherSuite.TLS_AES_128_GCM_SHA256, validKey, shortIv));
    assert(!aead.isInitialized, "Short IV must fail initialization");

    assert(aead.init(CipherSuite.TLS_AES_128_GCM_SHA256, validKey, validIv));
    assert(aead.isInitialized);

    // Self-move guard verification
    aead.moveFrom(aead);
    assert(aead.isInitialized, "Self-move must preserve initialized state");
}
