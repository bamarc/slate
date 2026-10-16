module slate.quic.crypto.kdf;

import slate.quic.crypto.c_openssl;

/**
 * TLS 1.3 Cipher Suites for QUIC (RFC 9001 Section 5.3).
 */
enum CipherSuite : ushort
{
    TLS_AES_128_GCM_SHA256 = 0x1301,
    TLS_AES_256_GCM_SHA384 = 0x1302,
    TLS_CHACHA20_POLY1305_SHA256 = 0x1303,
}

/**
 * Endpoint side (client or server).
 */
enum Side : ubyte
{
    client = 0,
    server = 1,
}

/**
 * QUIC packet encryption levels (RFC 9001 Section 4).
 */
enum EncryptionLevel : ubyte
{
    initial = 0,
    zeroRtt = 1,
    handshake = 2,
    oneRtt = 3,
}

/**
 * Cryptographic operation error codes.
 */
enum QuicCryptoError : int
{
    none = 0,
    packetTooShort = 1,
    aeadTagMismatch = 2,
    invalidCipherSuite = 3,
    invalidKeyLength = 4,
    cryptoError = 5,
    handshakeFailed = 6,
    alpnMismatch = 7,
    internalError = 8,
}

/**
 * Key material derived for packet protection: AEAD key, AEAD IV, and HP key.
 */
struct KeyMaterial
{
    ubyte[32] key;
    size_t keyLen;
    ubyte[12] iv;
    ubyte[32] hp;
    size_t hpLen;
}

/**
 * Returns the hash output length in bytes for the cipher suite.
 */
size_t hashLength(CipherSuite suite) @safe @nogc nothrow pure
{
    switch (suite)
    {
    case CipherSuite.TLS_AES_256_GCM_SHA384:
        return 48;
    case CipherSuite.TLS_AES_128_GCM_SHA256:
    case CipherSuite.TLS_CHACHA20_POLY1305_SHA256:
    default:
        return 32;
    }
}

/**
 * Returns the AEAD key length in bytes for the cipher suite.
 */
size_t keyLength(CipherSuite suite) @safe @nogc nothrow pure
{
    switch (suite)
    {
    case CipherSuite.TLS_AES_256_GCM_SHA384:
    case CipherSuite.TLS_CHACHA20_POLY1305_SHA256:
        return 32;
    case CipherSuite.TLS_AES_128_GCM_SHA256:
    default:
        return 16;
    }
}

/**
 * Returns the AEAD IV length in bytes (always 12 bytes in QUIC).
 */
size_t ivLength(CipherSuite suite) @safe @nogc nothrow pure
{
    return 12;
}

/**
 * Returns the AEAD authentication tag length in bytes (always 16 bytes in QUIC).
 */
size_t tagLength(CipherSuite suite) @safe @nogc nothrow pure
{
    return 16;
}

/**
 * Returns the Header Protection key length in bytes for the cipher suite.
 */
size_t hpKeyLength(CipherSuite suite) @safe @nogc nothrow pure
{
    switch (suite)
    {
    case CipherSuite.TLS_AES_256_GCM_SHA384:
    case CipherSuite.TLS_CHACHA20_POLY1305_SHA256:
        return 32;
    case CipherSuite.TLS_AES_128_GCM_SHA256:
    default:
        return 16;
    }
}

/**
 * Returns the OpenSSL EVP_MD pointer for the cipher suite hash function.
 */
package(slate.quic) const(EVP_MD)* getEvpMd(CipherSuite suite) @trusted @nogc nothrow
{
    if (suite == CipherSuite.TLS_AES_256_GCM_SHA384)
        return EVP_sha384();
    return EVP_sha256();
}

/**
 * RFC 9001 Section 5.2 QUIC v1 Initial Salt.
 */
immutable ubyte[20] INITIAL_SALT_V1 = [
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6,
    0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a
];

/**
 * HKDF-Extract(salt, IKM) as defined in RFC 5869 Section 2.2.
 */
package(slate.quic) void hkdfExtract(const(EVP_MD)* md, const(ubyte)[] salt,
        const(ubyte)[] ikm, ubyte[] prkOut) @trusted @nogc nothrow
{
    uint outLen = 0;
    ubyte[48] defaultSalt = 0;
    const(ubyte)* sPtr = salt.ptr;
    int sLen = cast(int) salt.length;

    if (sLen == 0)
    {
        sPtr = defaultSalt.ptr;
        sLen = (md == EVP_sha384()) ? 48 : 32;
    }

    HMAC(md, sPtr, sLen, ikm.ptr, ikm.length, prkOut.ptr, &outLen);
}

/// Public overload using CipherSuite
void hkdfExtract(CipherSuite suite, const(ubyte)[] salt, const(ubyte)[] ikm, ubyte[] prkOut) @trusted @nogc nothrow
{
    hkdfExtract(getEvpMd(suite), salt, ikm, prkOut);
}

/**
 * HKDF-Expand(PRK, info, L) as defined in RFC 5869 Section 2.3.
 */
package(slate.quic) void hkdfExpand(const(EVP_MD)* md, const(ubyte)[] prk,
        const(ubyte)[] info, ubyte[] okmOut) @trusted @nogc nothrow
{
    const size_t hashLen = (md == EVP_sha384()) ? 48 : 32;
    ubyte[256] hmacInput;
    if (info.length + hashLen + 1 > hmacInput.length)
        return;

    const size_t n = (okmOut.length + hashLen - 1) / hashLen;

    ubyte[48] t;
    size_t tLen = 0;
    size_t written = 0;

    foreach (ubyte i; 1 .. cast(ubyte)(n + 1))
    {
        size_t inputLen = 0;
        if (tLen > 0)
        {
            hmacInput[0 .. tLen] = t[0 .. tLen];
            inputLen += tLen;
        }
        hmacInput[inputLen .. inputLen + info.length] = info[];
        inputLen += info.length;
        hmacInput[inputLen] = i;
        inputLen += 1;

        uint outLen = 0;
        HMAC(md, prk.ptr, cast(int) prk.length, hmacInput.ptr, inputLen, t.ptr, &outLen);
        tLen = outLen;

        const size_t toCopy = (okmOut.length - written < hashLen) ? (okmOut.length - written)
            : hashLen;
        okmOut[written .. written + toCopy] = t[0 .. toCopy];
        written += toCopy;
    }
}

/// Public overload using CipherSuite
void hkdfExpand(CipherSuite suite, const(ubyte)[] prk, const(ubyte)[] info, ubyte[] okmOut) @trusted @nogc nothrow
{
    hkdfExpand(getEvpMd(suite), prk, info, okmOut);
}

/**
 * HKDF-Expand-Label(Secret, Label, Context, Length) as defined in RFC 9001 Section 5.1 / RFC 8446 Section 7.1.
 */
package(slate.quic) void hkdfExpandLabel(const(EVP_MD)* md,
        const(ubyte)[] secret, const(char)[] label, const(ubyte)[] context, ubyte[] outBuf) @trusted @nogc nothrow
{
    // HkdfLabel struct:
    // uint16 length (2 bytes, big-endian)
    // opaque label<7..255> (1 byte len + "tls13 " + label)
    // opaque context<0..255> (1 byte len + context)
    ubyte[128] labelBuf;

    if (10 + label.length + context.length > labelBuf.length)
        return;

    const ushort outLength = cast(ushort) outBuf.length;
    labelBuf[0] = cast(ubyte)(outLength >> 8);
    labelBuf[1] = cast(ubyte)(outLength & 0xFF);

    const ubyte fullLabelLen = cast(ubyte)(6 + label.length);
    labelBuf[2] = fullLabelLen;
    labelBuf[3 .. 9] = cast(const(ubyte)[]) "tls13 ";
    labelBuf[9 .. 9 + label.length] = cast(const(ubyte)[]) label[];

    size_t pos = 9 + label.length;
    labelBuf[pos] = cast(ubyte) context.length;
    pos += 1;

    if (context.length > 0)
    {
        labelBuf[pos .. pos + context.length] = context[];
        pos += context.length;
    }

    hkdfExpand(md, secret, labelBuf[0 .. pos], outBuf);
}

/// Public overload using CipherSuite
void hkdfExpandLabel(CipherSuite suite, const(ubyte)[] secret,
        const(char)[] label, const(ubyte)[] context, ubyte[] outBuf) @trusted @nogc nothrow
{
    hkdfExpandLabel(getEvpMd(suite), secret, label, context, outBuf);
}

/**
 * Derives the initial secret from the Destination Connection ID (RFC 9001 Section 5.2).
 */
void deriveInitialSecret(const(ubyte)[] dcid, ubyte[] secretOut) @trusted @nogc nothrow
{
    hkdfExtract(EVP_sha256(), INITIAL_SALT_V1, dcid, secretOut);
}

/**
 * Derives the client initial secret from the initial secret (RFC 9001 Section 5.2).
 */
void deriveClientInitialSecret(const(ubyte)[] initialSecret, ubyte[] clientSecretOut) @trusted @nogc nothrow
{
    hkdfExpandLabel(EVP_sha256(), initialSecret, "client in", null, clientSecretOut);
}

/**
 * Derives the server initial secret from the initial secret (RFC 9001 Section 5.2).
 */
void deriveServerInitialSecret(const(ubyte)[] initialSecret, ubyte[] serverSecretOut) @trusted @nogc nothrow
{
    hkdfExpandLabel(EVP_sha256(), initialSecret, "server in", null, serverSecretOut);
}

/**
 * Derives packet protection key, IV, and header protection key from a traffic secret (RFC 9001 Section 5.1).
 */
void deriveKeyMaterial(CipherSuite suite, const(ubyte)[] secret, ref KeyMaterial km) @trusted @nogc nothrow
{
    const(EVP_MD)* md = getEvpMd(suite);
    km.keyLen = keyLength(suite);
    km.hpLen = hpKeyLength(suite);

    hkdfExpandLabel(md, secret, "quic key", null, km.key[0 .. km.keyLen]);
    hkdfExpandLabel(md, secret, "quic iv", null, km.iv[0 .. 12]);
    hkdfExpandLabel(md, secret, "quic hp", null, km.hp[0 .. km.hpLen]);
}

/**
 * Derives the next application traffic secret during a Key Update (RFC 9001 Section 6.1).
 */
void deriveNextApplicationSecret(CipherSuite suite, const(ubyte)[] currentSecret,
        ubyte[] nextSecretOut) @trusted @nogc nothrow
{
    const(EVP_MD)* md = getEvpMd(suite);
    hkdfExpandLabel(md, currentSecret, "quic ku", null, nextSecretOut);
}

/// Example:
// Spec: RFC 9001 Appendix A.1 - Keys (covers U2, U4, E1, Scenario T1)
@nogc unittest
{
    // RFC 9001 Appendix A.1 Destination Connection ID
    const ubyte[8] dcid = [0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08];

    ubyte[32] initialSecret;
    deriveInitialSecret(dcid, initialSecret);

    const ubyte[32] expectedInitialSecret = [
        0x7d, 0xb5, 0xdf, 0x06, 0xe7, 0xa6, 0x9e, 0x43, 0x24, 0x96, 0xad, 0xed,
        0xb0, 0x08, 0x51, 0x92, 0x35, 0x95, 0x22, 0x15, 0x96, 0xae, 0x2a,
        0xe9, 0xfb, 0x81, 0x15, 0xc1, 0xe9, 0xed, 0x0a, 0x44
    ];
    assert(initialSecret == expectedInitialSecret, "Initial secret mismatch");

    // Client Initial Secret
    ubyte[32] clientInitialSecret;
    deriveClientInitialSecret(initialSecret, clientInitialSecret);

    const ubyte[32] expectedClientInitialSecret = [
        0xc0, 0x0c, 0xf1, 0x51, 0xca, 0x5b, 0xe0, 0x75, 0xed, 0x0e, 0xbf, 0xb5,
        0xc8, 0x03, 0x23, 0xc4, 0x2d, 0x6b, 0x7d, 0xb6, 0x78, 0x81, 0x28,
        0x9a, 0xf4, 0x00, 0x8f, 0x1f, 0x6c, 0x35, 0x7a, 0xea
    ];
    assert(clientInitialSecret == expectedClientInitialSecret, "Client initial secret mismatch");

    // Client Key Material
    KeyMaterial clientKm;
    deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, clientInitialSecret, clientKm);

    const ubyte[16] expectedClientKey = [
        0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46, 0x77, 0x30, 0xef, 0xcb,
        0xe3, 0xb1, 0xa2, 0x2d
    ];
    const ubyte[12] expectedClientIv = [
        0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b, 0x46, 0xfb, 0x25, 0x5c
    ];
    const ubyte[16] expectedClientHp = [
        0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10, 0x28, 0x3a, 0x1e, 0x99,
        0x33, 0xad, 0xed, 0xd2
    ];
    assert(clientKm.key[0 .. 16] == expectedClientKey, "Client key mismatch");
    assert(clientKm.iv == expectedClientIv, "Client IV mismatch");
    assert(clientKm.hp[0 .. 16] == expectedClientHp, "Client HP key mismatch");

    // Server Initial Secret
    ubyte[32] serverInitialSecret;
    deriveServerInitialSecret(initialSecret, serverInitialSecret);

    const ubyte[32] expectedServerInitialSecret = [
        0x3c, 0x19, 0x98, 0x28, 0xfd, 0x13, 0x9e, 0xfd, 0x21, 0x6c, 0x15, 0x5a,
        0xd8, 0x44, 0xcc, 0x81, 0xfb, 0x82, 0xfa, 0x8d, 0x74, 0x46, 0xfa,
        0x7d, 0x78, 0xbe, 0x80, 0x3a, 0xcd, 0xda, 0x95, 0x1b
    ];
    assert(serverInitialSecret == expectedServerInitialSecret, "Server initial secret mismatch");

    // Server Key Material
    KeyMaterial serverKm;
    deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, serverInitialSecret, serverKm);

    const ubyte[16] expectedServerKey = [
        0xcf, 0x3a, 0x53, 0x31, 0x65, 0x3c, 0x36, 0x4c, 0x88, 0xf0, 0xf3, 0x79,
        0xb6, 0x06, 0x7e, 0x37
    ];
    const ubyte[12] expectedServerIv = [
        0x0a, 0xc1, 0x49, 0x3c, 0xa1, 0x90, 0x58, 0x53, 0xb0, 0xbb, 0xa0, 0x3e
    ];
    const ubyte[16] expectedServerHp = [
        0xc2, 0x06, 0xb8, 0xd9, 0xb9, 0xf0, 0xf3, 0x76, 0x44, 0x43, 0x0b, 0x49,
        0x0e, 0xea, 0xa3, 0x14
    ];
    assert(serverKm.key[0 .. 16] == expectedServerKey, "Server key mismatch");
    assert(serverKm.iv == expectedServerIv, "Server IV mismatch");
    assert(serverKm.hp[0 .. 16] == expectedServerHp, "Server HP key mismatch");
}

/// Example:
// Spec: RFC 9001 Section 6.1 - Key Update secret derivation
@nogc unittest
{
    ubyte[32] currentSecret = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20
    ];
    ubyte[32] nextSecret;
    deriveNextApplicationSecret(CipherSuite.TLS_AES_128_GCM_SHA256, currentSecret, nextSecret);
    assert(nextSecret != currentSecret, "Next secret must differ from current secret");

    ubyte[32] thirdSecret;
    deriveNextApplicationSecret(CipherSuite.TLS_AES_128_GCM_SHA256, nextSecret, thirdSecret);
    assert(thirdSecret != nextSecret, "Third secret must differ from second secret");
}
