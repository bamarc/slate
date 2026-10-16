module slate.quic.crypto;

/**
 * QUIC Cryptographic and Packet Protection Engine (RFC 9001).
 *
 * Implements key derivation (KDF), AEAD packet protection (AES-GCM, ChaCha20-Poly1305),
 * Header Protection (AES-ECB, ChaCha20), Retry Packet Integrity Tag, Key Update,
 * and Sans-I/O TLS 1.3 handshake session integration over OpenSSL 3.5.
 */
public import slate.quic.crypto.kdf;
public import slate.quic.crypto.aead;
public import slate.quic.crypto.header_protection;
public import slate.quic.crypto.packet_keys;
public import slate.quic.crypto.tls_session;

/// Example:
// Best practice: Ensure slate.quic.crypto package module re-exports correctly
@nogc unittest
{
    const ubyte[8] dcid = [0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08];
    ubyte[32] secret;
    deriveInitialSecret(dcid, secret);
    assert(secret[0] == 0x7d);
}
