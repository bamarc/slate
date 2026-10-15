module slate.quic.crypto.tls_session;

import core.stdc.string : strlen;
import slate.quic.crypto.c_openssl;
import slate.quic.crypto.kdf;
import slate.quic.crypto.aead;
import slate.quic.crypto.header_protection;
import slate.quic.crypto.packet_keys;

/**
 * Server ALPN selection callback.
 *
 * Looks for "h3" in client ALPN list. If not offered, aborts with fatal alert 120.
 */
extern(C) private int alpnSelectCb(
    SSL* s,
    const(ubyte)** out_,
    ubyte* outlen,
    const(ubyte)* in_,
    uint inlen,
    void* arg
) @nogc nothrow
{
    uint pos = 0;
    while (pos < inlen)
    {
        const ubyte len = in_[pos];
        if (pos + 1 + len <= inlen)
        {
            const(ubyte)[] proto = in_[pos + 1 .. pos + 1 + len];
            if (proto == cast(const(ubyte)[]) "h3")
            {
                *out_ = in_ + pos + 1;
                *outlen = len;
                return SSL_TLSEXT_ERR_OK;
            }
        }
        pos += 1 + len;
    }
    return SSL_TLSEXT_ERR_ALERT_FATAL;
}

/**
 * RAII wrapper for OpenSSL SSL_CTX.
 */
struct TlsContext
{
    @disable this(this);

private:
    SSL_CTX* m_ctx;
    bool m_isServer;

    package(slate.quic) @property SSL_CTX* handle() @safe @nogc nothrow pure
    {
        return m_ctx;
    }

public:
    @property bool isValid() const @safe @nogc nothrow pure
    {
        return m_ctx !is null;
    }

    @property bool isServer() const @safe @nogc nothrow pure
    {
        return m_isServer;
    }

    ~this() @trusted @nogc nothrow
    {
        if (m_ctx !is null)
        {
            SSL_CTX_free(m_ctx);
            m_ctx = null;
        }
    }

    /**
     * Creates a server TLS context with certificate and private key files.
     */
    static TlsContext createServer(
        const(char)[] certPemPath,
        const(char)[] keyPemPath
    ) @trusted
    {
        TlsContext ctx;
        ctx.m_isServer = true;
        ctx.m_ctx = SSL_CTX_new(TLS_server_method());
        if (ctx.m_ctx is null)
            return ctx;

        // Require TLS 1.3
        SSL_CTX_ctrl(ctx.m_ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_3_VERSION, null);

        // Load certificate and key
        import std.string : toStringz;
        const char* cCert = certPemPath.toStringz();
        const char* cKey = keyPemPath.toStringz();

        if (SSL_CTX_use_certificate_file(ctx.m_ctx, cCert, SSL_FILETYPE_PEM) <= 0 ||
            SSL_CTX_use_PrivateKey_file(ctx.m_ctx, cKey, SSL_FILETYPE_PEM) <= 0)
        {
            SSL_CTX_free(ctx.m_ctx);
            ctx.m_ctx = null;
            return ctx;
        }

        // Set ALPN selection callback
        SSL_CTX_set_alpn_select_cb(ctx.m_ctx, &alpnSelectCb, null);

        return ctx;
    }

    /**
     * Creates a client TLS context.
     */
    static TlsContext createClient() @trusted
    {
        TlsContext ctx;
        ctx.m_isServer = false;
        ctx.m_ctx = SSL_CTX_new(TLS_client_method());
        if (ctx.m_ctx is null)
            return ctx;

        // Require TLS 1.3
        SSL_CTX_ctrl(ctx.m_ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_3_VERSION, null);

        return ctx;
    }
}

package(slate.quic) struct SecretSlot
{
    bool valid;
    ubyte[48] data;
    size_t len;
}

/**
 * Stable heap state for TlsSession callbacks.
 *
 * Ensures pointers registered with OpenSSL SSL_set_quic_tls_cbs remain valid
 * across struct moves (fixing Critical-1).
 */
package(slate.quic) struct TlsSessionState
{
    Side side;
    CipherSuite cipher;
    bool handshakeComplete;
    bool hasAlert;
    ubyte alertCode;

    // Expected incoming level & current outgoing level (fixing High-3)
    EncryptionLevel expectedReadLevel;
    EncryptionLevel writeLevel;

    // Transport Parameters
    ubyte[512] peerParams;
    size_t peerParamsLen;
    ubyte[512] localParams;
    size_t localParamsLen;

    // Incoming crypto feed
    const(ubyte)* inBufPtr;
    size_t inBufLen;
    size_t inBufOffset;

    // Outgoing crypto buffers per encryption level
    ubyte[4096] outInitial;
    size_t outInitialLen;
    ubyte[4096] outHandshake;
    size_t outHandshakeLen;
    ubyte[4096] out1Rtt;
    size_t out1RttLen;

    // Yielded traffic secrets
    SecretSlot hsReadSec;
    SecretSlot hsWriteSec;
    SecretSlot appReadSec;
    SecretSlot appWriteSec;

    int onCryptoSend(const(ubyte)* buf, size_t buf_len, size_t* consumed) @trusted @nogc nothrow
    {
        ubyte[] target;
        size_t* pLen;

        switch (writeLevel)
        {
            case EncryptionLevel.handshake:
                target = outHandshake[];
                pLen = &outHandshakeLen;
                break;
            case EncryptionLevel.oneRtt:
                target = out1Rtt[];
                pLen = &out1RttLen;
                break;
            case EncryptionLevel.initial:
            default:
                target = outInitial[];
                pLen = &outInitialLen;
                break;
        }

        const size_t avail = target.length - *pLen;
        const size_t toCopy = (buf_len < avail) ? buf_len : avail;

        if (toCopy > 0)
        {
            target[*pLen .. *pLen + toCopy] = buf[0 .. toCopy];
            *pLen += toCopy;
        }

        *consumed = toCopy;
        return 1;
    }

    int onCryptoRecv(const(ubyte)** buf, size_t* bytes_read) @trusted @nogc nothrow
    {
        const size_t avail = inBufLen - inBufOffset;
        if (avail > 0)
        {
            *buf = inBufPtr + inBufOffset;
            *bytes_read = avail;
        }
        else
        {
            *buf = null;
            *bytes_read = 0;
        }
        return 1;
    }

    int onCryptoRelease(size_t bytes_read) @safe @nogc nothrow
    {
        inBufOffset += bytes_read;
        return 1;
    }

    int onYieldSecret(
        uint prot_level,
        int direction,
        const(ubyte)* secret,
        size_t secret_len
    ) @trusted @nogc nothrow
    {
        SecretSlot* slot;
        if (prot_level == OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE)
        {
            slot = (direction == 1) ? &hsWriteSec : &hsReadSec;
        }
        else if (prot_level == OSSL_RECORD_PROTECTION_LEVEL_APPLICATION)
        {
            slot = (direction == 1) ? &appWriteSec : &appReadSec;
        }

        if (slot !is null && secret_len <= slot.data.length)
        {
            slot.data[0 .. secret_len] = secret[0 .. secret_len];
            slot.len = secret_len;
            slot.valid = true;
        }

        if (direction == 1)
        {
            if (prot_level == OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE)
                writeLevel = EncryptionLevel.handshake;
            else if (prot_level == OSSL_RECORD_PROTECTION_LEVEL_APPLICATION)
                writeLevel = EncryptionLevel.oneRtt;
        }
        else if (direction == 0)
        {
            if (prot_level == OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE)
                expectedReadLevel = EncryptionLevel.handshake;
            else if (prot_level == OSSL_RECORD_PROTECTION_LEVEL_APPLICATION)
                expectedReadLevel = EncryptionLevel.oneRtt;
        }

        return 1;
    }

    int onGotTransportParams(const(ubyte)* params, size_t params_len) @trusted @nogc nothrow
    {
        const size_t toCopy = (params_len < peerParams.length) ? params_len : peerParams.length;
        peerParams[0 .. toCopy] = params[0 .. toCopy];
        peerParamsLen = toCopy;
        return 1;
    }

    int onAlert(ubyte alert_code) @safe @nogc nothrow
    {
        alertCode = alert_code;
        hasAlert = true;
        return 1;
    }
}

// OpenSSL 3.5 QUIC TLS Callbacks dispatching to heap-allocated TlsSessionState
extern(C) private int quicCryptoSendCb(
    SSL* s,
    const(ubyte)* buf,
    size_t buf_len,
    size_t* consumed,
    void* arg
) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null) return 0;
    return state.onCryptoSend(buf, buf_len, consumed);
}

extern(C) private int quicCryptoRecvRcdCb(
    SSL* s,
    const(ubyte)** buf,
    size_t* bytes_read,
    void* arg
) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null) return 0;
    return state.onCryptoRecv(buf, bytes_read);
}

extern(C) private int quicCryptoReleaseRcdCb(
    SSL* s,
    size_t bytes_read,
    void* arg
) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null) return 0;
    return state.onCryptoRelease(bytes_read);
}

extern(C) private int quicYieldSecretCb(
    SSL* s,
    uint prot_level,
    int direction,
    const(ubyte)* secret,
    size_t secret_len,
    void* arg
) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null) return 0;

    const(SSL_CIPHER)* c = SSL_get_current_cipher(s);
    if (c !is null)
    {
        const uint id = SSL_CIPHER_get_protocol_id(c);
        state.cipher = cast(CipherSuite) id;
    }

    return state.onYieldSecret(prot_level, direction, secret, secret_len);
}

extern(C) private int quicGotTransportParamsCb(
    SSL* s,
    const(ubyte)* params,
    size_t params_len,
    void* arg
) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null) return 0;
    return state.onGotTransportParams(params, params_len);
}

extern(C) private int quicAlertCb(
    SSL* s,
    ubyte alert_code,
    void* arg
) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null) return 0;
    return state.onAlert(alert_code);
}

private static immutable OSSL_DISPATCH[7] s_quicTlsDispatch = [
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_SEND, cast(immutable(void)*) &quicCryptoSendCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RECV_RCD, cast(immutable(void)*) &quicCryptoRecvRcdCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RELEASE_RCD, cast(immutable(void)*) &quicCryptoReleaseRcdCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_YIELD_SECRET, cast(immutable(void)*) &quicYieldSecretCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_GOT_TRANSPORT_PARAMS, cast(immutable(void)*) &quicGotTransportParamsCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_ALERT, cast(immutable(void)*) &quicAlertCb),
    immutable(OSSL_DISPATCH)(0, null)
];

/**
 * Sans-I/O TLS 1.3 QUIC Handshake Engine (RFC 9001 Section 4).
 *
 * Implements full TLS 1.3 QUIC handshake over OpenSSL 3.5's SSL_set_quic_tls_cbs.
 */
struct TlsSession
{
    @disable this(this);
    @disable void opAssign(typeof(this));

public:
    /**
     * Set of yielded packet protection keys for a single encryption level.
     */
    struct LevelKeys
    {
        EncryptionLevel level;
        DirectionalKeys readKeys;
        DirectionalKeys writeKeys;
    }

private:
    SSL* m_ssl;
    TlsSessionState* m_state;
    bool m_hsKeysPolled;
    bool m_appKeysPolled;

public:
    /**
     * Initializes TlsSession with TlsContext, endpoint side, and transport parameters.
     */
    this(
        ref TlsContext ctx,
        Side side,
        const(ubyte)[] transportParams,
        const(char)[] clientAlpn = "h3"
    ) @trusted @nogc nothrow
    {
        init(ctx, side, transportParams, clientAlpn);
    }

    void init(
        ref TlsContext ctx,
        Side side,
        const(ubyte)[] transportParams,
        const(char)[] clientAlpn = "h3"
    ) @trusted @nogc nothrow
    {
        cleanup();

        import core.stdc.stdlib : calloc;
        m_state = cast(TlsSessionState*) calloc(1, TlsSessionState.sizeof);
        if (m_state is null)
            return;

        m_state.side = side;
        m_state.cipher = CipherSuite.TLS_AES_128_GCM_SHA256;
        m_state.expectedReadLevel = EncryptionLevel.initial;
        m_state.writeLevel = EncryptionLevel.initial;

        m_ssl = SSL_new(ctx.handle);
        if (m_ssl is null)
            return;

        if (side == Side.server)
        {
            SSL_set_accept_state(m_ssl);
        }
        else
        {
            SSL_set_connect_state(m_ssl);

            // Configure Client ALPN
            if (clientAlpn.length > 0 && clientAlpn.length < 255)
            {
                ubyte[256] alpnWire;
                alpnWire[0] = cast(ubyte) clientAlpn.length;
                alpnWire[1 .. 1 + clientAlpn.length] = cast(const(ubyte)[]) clientAlpn[];
                SSL_set_alpn_protos(m_ssl, alpnWire.ptr, cast(uint)(1 + clientAlpn.length));
            }
        }

        SSL_set_quic_tls_cbs(m_ssl, s_quicTlsDispatch.ptr, m_state);

        if (transportParams.length > 0 && transportParams.length <= m_state.localParams.length)
        {
            m_state.localParamsLen = transportParams.length;
            m_state.localParams[0 .. m_state.localParamsLen] = transportParams[];
            SSL_set_quic_tls_transport_params(m_ssl, m_state.localParams.ptr, m_state.localParamsLen);
        }
    }

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    public void cleanup() @trusted @nogc nothrow
    {
        if (m_ssl !is null)
        {
            SSL_free(m_ssl);
            m_ssl = null;
        }
        if (m_state !is null)
        {
            import core.stdc.stdlib : free;
            free(m_state);
            m_state = null;
        }
        m_hsKeysPolled = false;
        m_appKeysPolled = false;
    }

    void moveFrom(ref TlsSession other) @trusted @nogc nothrow
    {
        cleanup();
        m_ssl = other.m_ssl;
        m_state = other.m_state;
        m_hsKeysPolled = other.m_hsKeysPolled;
        m_appKeysPolled = other.m_appKeysPolled;
        other.m_ssl = null;
        other.m_state = null;
    }

    /**
     * Feeds incoming CRYPTO data from a QUIC packet into TLS.
     *
     * Validates that the data's EncryptionLevel matches the expected read level (RFC 9001 Section 4.1.3).
     */
    QuicCryptoError provideCryptoData(
        EncryptionLevel level,
        const(ubyte)[] data
    ) @trusted @nogc nothrow
    {
        if (m_state is null || m_ssl is null)
            return QuicCryptoError.internalError;

        // F4 & RFC 9001 Section 4.1.3: Reject cross-encryption-level record injection
        if (level != m_state.expectedReadLevel)
            return QuicCryptoError.cryptoError;

        m_state.inBufPtr = data.ptr;
        m_state.inBufLen = data.length;
        m_state.inBufOffset = 0;

        return stepHandshake();
    }

    /**
     * Canonical D3 API: Feeds incoming CRYPTO data for the given level.
     */
    QuicCryptoError readHandshake(
        EncryptionLevel level,
        const(ubyte)[] data
    ) @trusted @nogc nothrow
    {
        return provideCryptoData(level, data);
    }

    /**
     * Executes one step of the TLS 1.3 handshake.
     */
    QuicCryptoError stepHandshake() @trusted @nogc nothrow
    {
        if (m_ssl is null || m_state is null)
            return QuicCryptoError.internalError;

        const int ret = SSL_do_handshake(m_ssl);

        const(SSL_CIPHER)* c = SSL_get_current_cipher(m_ssl);
        if (c !is null)
        {
            const uint id = SSL_CIPHER_get_protocol_id(c);
            m_state.cipher = cast(CipherSuite) id;
        }

        if (ret == 1)
        {
            m_state.handshakeComplete = true;
            return QuicCryptoError.none;
        }

        if (m_state.hasAlert)
        {
            if (m_state.alertCode == 120) // no_application_protocol
                return QuicCryptoError.alpnMismatch;
            return QuicCryptoError.handshakeFailed;
        }

        const int err = SSL_get_error(m_ssl, ret);

        if (err == 2) // SSL_ERROR_WANT_READ
        {
            return QuicCryptoError.none;
        }

        return QuicCryptoError.handshakeFailed;
    }

    @property bool isHandshakeComplete() const @trusted @nogc nothrow pure
    {
        return m_state !is null && m_state.handshakeComplete;
    }

    @property CipherSuite negotiatedCipher() const @trusted @nogc nothrow pure
    {
        return m_state !is null ? m_state.cipher : CipherSuite.TLS_AES_128_GCM_SHA256;
    }

    @property bool hasAlert() const @trusted @nogc nothrow pure
    {
        return m_state !is null && m_state.hasAlert;
    }

    @property ubyte alertCode() const @trusted @nogc nothrow pure
    {
        return m_state !is null ? m_state.alertCode : 0;
    }

    /**
     * Maps TLS alert code to QUIC transport error code (RFC 9001 Section 4.8).
     *
     * 0x0100 | alert_code.
     */
    @property uint quicErrorCode() const @trusted @nogc nothrow pure
    {
        if (m_state is null || !m_state.hasAlert)
            return 0;
        return 0x0100 | cast(uint) m_state.alertCode;
    }

    @property const(ubyte)[] peerTransportParams() return const @trusted @nogc nothrow pure
    {
        if (m_state is null)
            return null;
        return m_state.peerParams[0 .. m_state.peerParamsLen];
    }

    @property const(ubyte)[] appReadSecret() return const @trusted @nogc nothrow pure
    {
        if (m_state is null || !m_state.appReadSec.valid)
            return null;
        return m_state.appReadSec.data[0 .. m_state.appReadSec.len];
    }

    @property const(ubyte)[] appWriteSecret() return const @trusted @nogc nothrow pure
    {
        if (m_state is null || !m_state.appWriteSec.valid)
            return null;
        return m_state.appWriteSec.data[0 .. m_state.appWriteSec.len];
    }

    /**
     * Returns pending outgoing CRYPTO bytes for the given level.
     */
    const(ubyte)[] getOutput(EncryptionLevel level) return const @trusted @nogc nothrow pure
    {
        if (m_state is null)
            return null;
        switch (level)
        {
            case EncryptionLevel.handshake:
                return m_state.outHandshake[0 .. m_state.outHandshakeLen];
            case EncryptionLevel.oneRtt:
                return m_state.out1Rtt[0 .. m_state.out1RttLen];
            case EncryptionLevel.initial:
            default:
                return m_state.outInitial[0 .. m_state.outInitialLen];
        }
    }

    /**
     * Consumes pending outgoing CRYPTO bytes.
     */
    void consumeOutput(EncryptionLevel level, size_t count) @trusted @nogc nothrow pure
    {
        if (m_state is null)
            return;
        switch (level)
        {
            case EncryptionLevel.handshake:
                if (count >= m_state.outHandshakeLen) m_state.outHandshakeLen = 0;
                else
                {
                    m_state.outHandshake[0 .. m_state.outHandshakeLen - count] = m_state.outHandshake[count .. m_state.outHandshakeLen];
                    m_state.outHandshakeLen -= count;
                }
                break;
            case EncryptionLevel.oneRtt:
                if (count >= m_state.out1RttLen) m_state.out1RttLen = 0;
                else
                {
                    m_state.out1Rtt[0 .. m_state.out1RttLen - count] = m_state.out1Rtt[count .. m_state.out1RttLen];
                    m_state.out1RttLen -= count;
                }
                break;
            case EncryptionLevel.initial:
            default:
                if (count >= m_state.outInitialLen) m_state.outInitialLen = 0;
                else
                {
                    m_state.outInitial[0 .. m_state.outInitialLen - count] = m_state.outInitial[count .. m_state.outInitialLen];
                    m_state.outInitialLen -= count;
                }
                break;
        }
    }

    /**
     * Canonical D3 API: Pulls outgoing pending CRYPTO bytes into outBuf, consumes them,
     * and returns the written slice.
     */
    const(ubyte)[] writeHandshake(EncryptionLevel level, ubyte[] outBuf) @trusted @nogc nothrow
    {
        const pending = getOutput(level);
        if (pending.length == 0)
            return null;
        const size_t toCopy = (pending.length < outBuf.length) ? pending.length : outBuf.length;
        outBuf[0 .. toCopy] = pending[0 .. toCopy];
        consumeOutput(level, toCopy);
        return outBuf[0 .. toCopy];
    }

    /**
     * Canonical D3 API: Polls next available LevelKeys (Handshake or 1-RTT).
     */
    bool pollNextKeys(out LevelKeys outKeys) @trusted @nogc nothrow
    {
        if (m_state is null)
            return false;

        if (m_state.hsReadSec.valid && m_state.hsWriteSec.valid && !m_hsKeysPolled)
        {
            m_hsKeysPolled = true;
            outKeys.level = EncryptionLevel.handshake;
            return pollKeys(EncryptionLevel.handshake, outKeys.readKeys, outKeys.writeKeys);
        }

        if (m_state.appReadSec.valid && m_state.appWriteSec.valid && !m_appKeysPolled)
        {
            m_appKeysPolled = true;
            outKeys.level = EncryptionLevel.oneRtt;
            return pollKeys(EncryptionLevel.oneRtt, outKeys.readKeys, outKeys.writeKeys);
        }

        return false;
    }

    /**
     * Polls newly yielded packet protection keys for the given encryption level.
     */
    bool pollKeys(
        EncryptionLevel level,
        ref DirectionalKeys readKeys,
        ref DirectionalKeys writeKeys
    ) @trusted @nogc nothrow
    {
        if (m_state is null)
            return false;

        SecretSlot* rSlot;
        SecretSlot* wSlot;

        if (level == EncryptionLevel.handshake)
        {
            rSlot = &m_state.hsReadSec;
            wSlot = &m_state.hsWriteSec;
        }
        else if (level == EncryptionLevel.oneRtt)
        {
            rSlot = &m_state.appReadSec;
            wSlot = &m_state.appWriteSec;
        }
        else
        {
            return false;
        }

        if (!rSlot.valid || !wSlot.valid)
            return false;

        KeyMaterial rKm;
        deriveKeyMaterial(m_state.cipher, rSlot.data[0 .. rSlot.len], rKm);
        readKeys.init(m_state.cipher, rKm.key[0 .. rKm.keyLen], rKm.iv[0 .. 12], rKm.hp[0 .. rKm.hpLen]);

        KeyMaterial wKm;
        deriveKeyMaterial(m_state.cipher, wSlot.data[0 .. wSlot.len], wKm);
        writeKeys.init(m_state.cipher, wKm.key[0 .. wKm.keyLen], wKm.iv[0 .. 12], wKm.hp[0 .. wKm.hpLen]);

        return readKeys.initialized && writeKeys.initialized;
    }
}

/// Example:
// Spec: RFC 9001 Section 4 - In-Memory TLS 1.3 QUIC Handshake (covers U1, U2, U3, E5, Scenario T5)
unittest
{
    // Initialize server and client contexts
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClient();

    assert(serverCtx.isValid, "Server context init failed");
    assert(clientCtx.isValid, "Client context init failed");

    const ubyte[4] serverParams = [1, 2, 3, 4];
    const ubyte[4] clientParams = [5, 6, 7, 8];

    TlsSession serverSession;
    serverSession.init(serverCtx, Side.server, serverParams);

    TlsSession clientSession;
    clientSession.init(clientCtx, Side.client, clientParams);

    // Flight 1: Client initiates handshake -> produces ClientHello
    const cErr1 = clientSession.stepHandshake();
    assert(cErr1 == QuicCryptoError.none, "Client initial step failed");
    assert(!clientSession.isHandshakeComplete);

    ubyte[2048] flightBuf;
    const clientHello = clientSession.writeHandshake(EncryptionLevel.initial, flightBuf);
    assert(clientHello.length > 0, "ClientHello must be generated");

    // Flight 2: Server receives ClientHello -> produces ServerHello and Handshake messages
    const sErr1 = serverSession.readHandshake(EncryptionLevel.initial, clientHello);
    assert(sErr1 == QuicCryptoError.none, "Server provide initial failed");

    assert(serverSession.peerTransportParams == clientParams, "Server must receive client transport params");

    ubyte[2048] sInitBuf;
    const serverInitial = serverSession.writeHandshake(EncryptionLevel.initial, sInitBuf);
    ubyte[4096] sHsBuf;
    const serverHandshake = serverSession.writeHandshake(EncryptionLevel.handshake, sHsBuf);
    assert(serverInitial.length > 0, "ServerHello must be generated");
    assert(serverHandshake.length > 0, "Server handshake messages must be generated");

    // Flight 3a: Client processes Server Initial
    const cErr2a = clientSession.readHandshake(EncryptionLevel.initial, serverInitial);
    assert(cErr2a == QuicCryptoError.none, "Client provide initial failed");

    // Flight 3b: Client processes Server Handshake
    const cErr2b = clientSession.readHandshake(EncryptionLevel.handshake, serverHandshake);
    assert(cErr2b == QuicCryptoError.none, "Client provide handshake failed");

    assert(clientSession.peerTransportParams == serverParams, "Client must receive server transport params");
    assert(clientSession.isHandshakeComplete, "Client handshake must be complete");

    ubyte[2048] cHsBuf;
    const clientHandshake = clientSession.writeHandshake(EncryptionLevel.handshake, cHsBuf);
    assert(clientHandshake.length > 0, "Client Finished must be generated");

    // Flight 4: Server processes Client Handshake (Finished)
    const sErr2 = serverSession.readHandshake(EncryptionLevel.handshake, clientHandshake);
    assert(sErr2 == QuicCryptoError.none, "Server provide handshake failed");

    assert(serverSession.isHandshakeComplete, "Server handshake must be complete");

    // Verify canonical D3 pollNextKeys for Handshake and 1-RTT keys
    TlsSession.LevelKeys clientKeys1;
    TlsSession.LevelKeys serverKeys1;
    assert(clientSession.pollNextKeys(clientKeys1), "Client handshake keys available");
    assert(serverSession.pollNextKeys(serverKeys1), "Server handshake keys available");
    assert(clientKeys1.level == EncryptionLevel.handshake);
    assert(serverKeys1.level == EncryptionLevel.handshake);

    TlsSession.LevelKeys clientKeys2;
    TlsSession.LevelKeys serverKeys2;
    assert(clientSession.pollNextKeys(clientKeys2), "Client 1-RTT keys available");
    assert(serverSession.pollNextKeys(serverKeys2), "Server 1-RTT keys available");
    assert(clientKeys2.level == EncryptionLevel.oneRtt);
    assert(serverKeys2.level == EncryptionLevel.oneRtt);

    // Encrypt 1-RTT packet on server (server write) and decrypt on client (client read)
    ubyte[26] packetBuffer = [
        0x40, 0x01,                                     // 1-RTT Short Header (pnLen = 1)
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, // 8 bytes plaintext
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0   // Tag space
    ];

    size_t protLen = 0;
    const protErr = protectPacket(serverKeys2.writeKeys, 1, 1, 1, packetBuffer, 8, protLen);
    assert(protErr == QuicCryptoError.none, "1-RTT protectPacket failed");
    assert(protLen == 2 + 8 + 16, "1-RTT packet length mismatch");

    // Decrypt on client with clientReadKeys
    size_t decPnLen; ulong decPn; size_t decPayOff; size_t decPlainLen;
    const decErr = unprotectPacket(clientKeys2.readKeys, 1, 0, packetBuffer[0 .. protLen], decPnLen, decPn, decPayOff, decPlainLen);
    assert(decErr == QuicCryptoError.none, "1-RTT unprotectPacket failed");
    assert(decPn == 1, "Decrypted packet number mismatch");
    assert(decPlainLen == 8, "Decrypted payload length mismatch");
    assert(packetBuffer[decPayOff .. decPayOff + 8] == [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80], "Plaintext mismatch");
}

/// Example:
// Spec: RFC 9001 Section 4.8 & Section 8.1 - ALPN Mismatch & Alert Mapping (covers W3, Scenario T6)
unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClient();

    const ubyte[4] dummyParams = [1, 2, 3, 4];

    TlsSession serverSession;
    serverSession.init(serverCtx, Side.server, dummyParams);

    // Client offers only "hq-29"
    TlsSession clientSession;
    clientSession.init(clientCtx, Side.client, dummyParams, "hq-29");

    // Client step 1 generates ClientHello
    clientSession.stepHandshake();
    const clientHello = clientSession.getOutput(EncryptionLevel.initial);
    assert(clientHello.length > 0);

    // Server receives ClientHello with mismatched ALPN
    const sErr = serverSession.provideCryptoData(EncryptionLevel.initial, clientHello);
    assert(sErr == QuicCryptoError.alpnMismatch, "Server must report alpnMismatch error");
    assert(serverSession.hasAlert, "Server must have recorded TLS alert");
    assert(serverSession.alertCode == 120, "Alert must be 120 (no_application_protocol)");
    assert(serverSession.quicErrorCode == 0x0178, "QUIC error code must be 0x0178 (0x0100 | 120)");
}

/// Helper to create and return a TlsSession by value
private TlsSession createMovedClientSession(ref TlsContext ctx, const(ubyte)[] params) @trusted
{
    TlsSession session;
    session.init(ctx, Side.client, params);
    return session;
}

/// Example:
// Spec: OpenSSL 3.5 SSL_set_quic_tls_cbs callback stability across struct moves (covers Critical-1)
unittest
{
    import core.lifetime : move;

    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClient();

    const ubyte[4] sParams = [1, 1, 1, 1];
    const ubyte[4] cParams = [2, 2, 2, 2];

    // Create client via return-by-value move
    TlsSession clientSession = createMovedClientSession(clientCtx, cParams);

    // Create server and move via core.lifetime.move
    TlsSession tempServer;
    tempServer.init(serverCtx, Side.server, sParams);
    TlsSession serverSession = move(tempServer);

    // Verify full handshake executes cleanly on moved sessions
    assert(clientSession.stepHandshake() == QuicCryptoError.none);
    const cHello = clientSession.getOutput(EncryptionLevel.initial);
    assert(cHello.length > 0);

    assert(serverSession.provideCryptoData(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
    clientSession.consumeOutput(EncryptionLevel.initial, cHello.length);

    const sInit = serverSession.getOutput(EncryptionLevel.initial);
    const sHs = serverSession.getOutput(EncryptionLevel.handshake);
    assert(clientSession.provideCryptoData(EncryptionLevel.initial, sInit) == QuicCryptoError.none);
    assert(clientSession.provideCryptoData(EncryptionLevel.handshake, sHs) == QuicCryptoError.none);
    serverSession.consumeOutput(EncryptionLevel.initial, sInit.length);
    serverSession.consumeOutput(EncryptionLevel.handshake, sHs.length);

    const cFin = clientSession.getOutput(EncryptionLevel.handshake);
    assert(serverSession.provideCryptoData(EncryptionLevel.handshake, cFin) == QuicCryptoError.none);
    clientSession.consumeOutput(EncryptionLevel.handshake, cFin.length);

    assert(clientSession.isHandshakeComplete);
    assert(serverSession.isHandshakeComplete);
}

/// Example:
// Spec: RFC 9001 Section 4.1.3 - Cross-Encryption-Level Record Injection Rejection (covers F4, High-3)
unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClient();

    const ubyte[4] dummyParams = [1, 2, 3, 4];

    TlsSession serverSession;
    serverSession.init(serverCtx, Side.server, dummyParams);
    TlsSession clientSession;
    clientSession.init(clientCtx, Side.client, dummyParams);

    clientSession.stepHandshake();
    const cHello = clientSession.getOutput(EncryptionLevel.initial);
    assert(cHello.length > 0);

    // Attempt cross-level injection: feeding Initial data at Handshake level must be rejected
    const badLevelErr = serverSession.provideCryptoData(EncryptionLevel.handshake, cHello);
    assert(badLevelErr == QuicCryptoError.cryptoError, "Cross-level data injection must be rejected");

    // Feed correctly at Initial level -> succeeds
    const okErr = serverSession.provideCryptoData(EncryptionLevel.initial, cHello);
    assert(okErr == QuicCryptoError.none);

    // Now server expects Handshake level for incoming data; attempting Initial must fail
    const badSecondErr = serverSession.provideCryptoData(EncryptionLevel.initial, cHello);
    assert(badSecondErr == QuicCryptoError.cryptoError, "Injecting Initial data when expecting Handshake must be rejected");
}

/// Example:
// Best practice: Validation of Certificate & Key paths in TlsContext (covers Minor-6)
unittest
{
    TlsContext badCtx = TlsContext.createServer("/nonexistent/path/cert.pem", "/nonexistent/path/key.pem");
    assert(!badCtx.isValid, "Nonexistent cert/key files must result in invalid TlsContext");
}

/// Helper running in-memory QUIC TLS 1.3 handshake exchange in @nogc nothrow (covers G2)
private void runNogcHandshake(ref TlsContext serverCtx, ref TlsContext clientCtx) @nogc nothrow
{
    const ubyte[4] serverParams = [1, 2, 3, 4];
    const ubyte[4] clientParams = [5, 6, 7, 8];

    TlsSession serverSession;
    serverSession.init(serverCtx, Side.server, serverParams);

    TlsSession clientSession;
    clientSession.init(clientCtx, Side.client, clientParams);

    // Flight 1: Client Initial
    assert(clientSession.stepHandshake() == QuicCryptoError.none);
    ubyte[2048] cHelloBuf;
    const clientHello = clientSession.writeHandshake(EncryptionLevel.initial, cHelloBuf);
    assert(clientHello.length > 0);

    // Flight 2: Server Initial + Handshake
    assert(serverSession.readHandshake(EncryptionLevel.initial, clientHello) == QuicCryptoError.none);
    ubyte[2048] sInitBuf;
    const serverInitial = serverSession.writeHandshake(EncryptionLevel.initial, sInitBuf);
    ubyte[4096] sHsBuf;
    const serverHandshake = serverSession.writeHandshake(EncryptionLevel.handshake, sHsBuf);
    assert(serverInitial.length > 0);
    assert(serverHandshake.length > 0);

    // Flight 3: Client processes Server Initial + Handshake -> produces Client Finished
    assert(clientSession.readHandshake(EncryptionLevel.initial, serverInitial) == QuicCryptoError.none);
    assert(clientSession.readHandshake(EncryptionLevel.handshake, serverHandshake) == QuicCryptoError.none);
    assert(clientSession.isHandshakeComplete);
    ubyte[2048] cHsBuf;
    const clientHandshake = clientSession.writeHandshake(EncryptionLevel.handshake, cHsBuf);
    assert(clientHandshake.length > 0);

    // Flight 4: Server processes Client Finished
    assert(serverSession.readHandshake(EncryptionLevel.handshake, clientHandshake) == QuicCryptoError.none);
    assert(serverSession.isHandshakeComplete);
}

/// Example:
// Spec: RFC 9001 Section 4 - Verified @nogc hot-path execution of Sans-I/O TLS Handshake (covers U2, G2)
unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClient();
    assert(serverCtx.isValid && clientCtx.isValid);

    runNogcHandshake(serverCtx, clientCtx);
}

/// Example:
// Spec: RFC 9001 Section 5.3 - TLS_AES_256_GCM_SHA384 negotiation and early key derivation (covers E5, Scenario T5)
unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClient();
    assert(serverCtx.isValid && clientCtx.isValid);

    // Restrict cipher suite to TLS_AES_256_GCM_SHA384
    SSL_CTX_set_ciphersuites(serverCtx.handle, "TLS_AES_256_GCM_SHA384");
    SSL_CTX_set_ciphersuites(clientCtx.handle, "TLS_AES_256_GCM_SHA384");

    const ubyte[4] dummyParams = [1, 2, 3, 4];
    TlsSession server;
    server.init(serverCtx, Side.server, dummyParams);
    TlsSession client;
    client.init(clientCtx, Side.client, dummyParams);

    client.stepHandshake();
    ubyte[2048] cHelloBuf;
    const cHello = client.writeHandshake(EncryptionLevel.initial, cHelloBuf);

    assert(server.readHandshake(EncryptionLevel.initial, cHello) == QuicCryptoError.none);

    // Handshake keys must be derived with TLS_AES_256_GCM_SHA384 immediately upon yield
    TlsSession.LevelKeys serverHsKeys;
    assert(server.pollNextKeys(serverHsKeys));
    assert(serverHsKeys.level == EncryptionLevel.handshake);
    assert(server.negotiatedCipher == CipherSuite.TLS_AES_256_GCM_SHA384);
    assert(serverHsKeys.readKeys.aead.cipherSuite == CipherSuite.TLS_AES_256_GCM_SHA384);
    assert(serverHsKeys.writeKeys.aead.cipherSuite == CipherSuite.TLS_AES_256_GCM_SHA384);
}

/// Example:
// Best practice: High-iteration RAII handle leak check for AeadKey, HeaderProtectionKey, and TlsSession (covers G5)
unittest
{
    // High-iteration AeadKey & HeaderProtectionKey handle creation/free
    const ubyte[16] key128 = 0xAA;
    const ubyte[12] iv128 = 0x55;
    const ubyte[16] hpKey = 0xBB;
    foreach (i; 0 .. 5_000)
    {
        AeadKey aead;
        aead.init(CipherSuite.TLS_AES_128_GCM_SHA256, key128, iv128);
        assert(aead.isInitialized);

        HeaderProtectionKey hp;
        hp.init(CipherSuite.TLS_AES_128_GCM_SHA256, hpKey);
        assert(hp.isInitialized);
    }

    // High-iteration TlsSession handle creation/free
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClient();
    assert(serverCtx.isValid && clientCtx.isValid);

    const ubyte[4] dummyParams = [1, 2, 3, 4];
    foreach (i; 0 .. 1_000)
    {
        TlsSession s;
        s.init(serverCtx, Side.server, dummyParams);
        TlsSession c;
        c.init(clientCtx, Side.client, dummyParams);
    }
}
