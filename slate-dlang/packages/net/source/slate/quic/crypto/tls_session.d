module slate.quic.crypto.tls_session;

import core.stdc.string : strlen;
import slate.quic.crypto.c_openssl;
import slate.quic.crypto.kdf;
import slate.quic.crypto.aead;
import slate.quic.crypto.header_protection;
import slate.quic.crypto.packet_keys;

/**
 * Heap-allocated ALPN configuration for TlsContext.
 *
 * Ensures pointers registered with OpenSSL SSL_CTX_set_alpn_select_cb remain valid
 * across TlsContext struct moves.
 */
private struct TlsAlpnConfig
{
    ubyte[256] wireData;
    uint wireLen;
    int refCount;
}

private void retainAlpnConfig(TlsAlpnConfig* cfg) @trusted @nogc nothrow
{
    if (cfg !is null)
        cfg.refCount++;
}

private void releaseAlpnConfig(ref TlsAlpnConfig* cfg) @trusted @nogc nothrow
{
    if (cfg !is null)
    {
        cfg.refCount--;
        if (cfg.refCount <= 0)
        {
            import core.stdc.stdlib : free;

            free(cfg);
        }
        cfg = null;
    }
}

/**
 * Server ALPN selection callback (RFC 7301 & RFC 9001 Section 8.1).
 *
 * Validates the client ALPN wire list and matches against the server's configured
 * ALPN protocols. If no match or malformed input, aborts with fatal alert 120.
 */
extern (C) private int alpnSelectCb(SSL* s, const(ubyte)** out_,
        ubyte* outlen, const(ubyte)* in_, uint inlen, void* arg) @nogc nothrow
{
    if (in_ is null || inlen == 0 || out_ is null || outlen is null)
        return SSL_TLSEXT_ERR_ALERT_FATAL;

    // Validate entire client ALPN wire format (no zero-length tokens, no truncation)
    uint vPos = 0;
    while (vPos < inlen)
    {
        const uint cLen = in_[vPos];
        if (cLen == 0 || inlen - vPos < 1 + cLen)
            return SSL_TLSEXT_ERR_ALERT_FATAL;
        vPos += 1 + cLen;
    }

    const(TlsAlpnConfig)* cfg = cast(const(TlsAlpnConfig)*) arg;
    if (cfg !is null && cfg.wireLen > 0 && cfg.wireLen <= cfg.wireData.length)
    {
        uint sPos = 0;
        while (sPos < cfg.wireLen)
        {
            const uint sLen = cfg.wireData[sPos];
            if (sLen == 0 || cfg.wireLen - sPos < 1 + sLen)
                break;
            const(ubyte)[] sProto = cfg.wireData[sPos + 1 .. sPos + 1 + sLen];

            uint cPos = 0;
            while (cPos < inlen)
            {
                const uint cLen = in_[cPos];
                const(ubyte)[] cProto = in_[cPos + 1 .. cPos + 1 + cLen];
                if (cProto == sProto)
                {
                    *out_ = in_ + cPos + 1;
                    *outlen = cast(ubyte) cLen;
                    return SSL_TLSEXT_ERR_OK;
                }
                cPos += 1 + cLen;
            }
            sPos += 1 + sLen;
        }
        return SSL_TLSEXT_ERR_ALERT_FATAL;
    }

    // Fallback default if no TlsAlpnConfig was attached ("h3" and "smsp/1")
    uint pos = 0;
    while (pos < inlen)
    {
        const ubyte len = in_[pos];
        const(ubyte)[] proto = in_[pos + 1 .. pos + 1 + len];
        if (proto == cast(const(ubyte)[]) "h3" || proto == cast(const(ubyte)[]) "smsp/1")
        {
            *out_ = in_ + pos + 1;
            *outlen = len;
            return SSL_TLSEXT_ERR_OK;
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
    TlsAlpnConfig* m_alpnConfig;
    bool m_isServer;
    bool m_verifyPeer;

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

    /// Whether this (client) context authenticates the server certificate chain.
    @property bool verifiesPeer() const @safe @nogc nothrow pure
    {
        return m_verifyPeer;
    }

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        if (m_ctx !is null)
        {
            SSL_CTX_free(m_ctx);
            m_ctx = null;
        }
        releaseAlpnConfig(m_alpnConfig);
    }

    void moveFrom(ref TlsContext other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;
        cleanup();
        m_ctx = other.m_ctx;
        m_alpnConfig = other.m_alpnConfig;
        m_isServer = other.m_isServer;
        m_verifyPeer = other.m_verifyPeer;
        other.m_ctx = null;
        other.m_alpnConfig = null;
    }

    /**
     * Configures the list of ALPN protocols accepted by this server context.
     */
    bool setAlpnProtocols(scope const(char[])[] protocols) @trusted @nogc nothrow
    {
        if (m_ctx is null || protocols.length == 0)
            return false;

        ubyte[256] tempWire;
        uint offset = 0;
        foreach (proto; protocols)
        {
            if (proto.length == 0 || proto.length > 255)
                return false;
            if (tempWire.length - offset < 1 + proto.length)
                return false;
            tempWire[offset] = cast(ubyte) proto.length;
            tempWire[offset + 1 .. offset + 1 + proto.length] = cast(const(ubyte)[]) proto[];
            offset += cast(uint)(1 + proto.length);
        }

        if (m_alpnConfig is null)
        {
            import core.stdc.stdlib : calloc;

            m_alpnConfig = cast(TlsAlpnConfig*) calloc(1, TlsAlpnConfig.sizeof);
            if (m_alpnConfig is null)
                return false;
            m_alpnConfig.refCount = 1;
        }

        m_alpnConfig.wireData[0 .. offset] = tempWire[0 .. offset];
        m_alpnConfig.wireLen = offset;

        if (m_isServer)
        {
            SSL_CTX_set_alpn_select_cb(m_ctx, &alpnSelectCb, m_alpnConfig);
        }
        else
        {
            SSL_CTX_set_alpn_protos(m_ctx, m_alpnConfig.wireData.ptr, m_alpnConfig.wireLen);
        }
        return true;
    }

    /**
     * Configures a single ALPN protocol token on this context.
     */
    bool setAlpnProtocol(scope const(char)[] proto) @trusted @nogc nothrow
    {
        const(char)[][1] list = [proto];
        return setAlpnProtocols(list[]);
    }

    /**
     * Creates a server TLS context with certificate and private key files.
     */
    static TlsContext createServer(scope const(char)[] certPemPath, scope const(char)[] keyPemPath) @trusted @nogc nothrow
    {
        TlsContext ctx;
        ctx.m_isServer = true;
        ctx.m_ctx = SSL_CTX_new(TLS_server_method());
        if (ctx.m_ctx is null)
            return ctx;

        // Require TLS 1.3
        SSL_CTX_ctrl(ctx.m_ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_3_VERSION, null);

        if (certPemPath.length == 0 || certPemPath.length >= 1024
                || keyPemPath.length == 0 || keyPemPath.length >= 1024)
        {
            ctx.cleanup();
            return ctx;
        }

        char[1024] cCertBuf = void;
        cCertBuf[0 .. certPemPath.length] = certPemPath[];
        cCertBuf[certPemPath.length] = '\0';

        char[1024] cKeyBuf = void;
        cKeyBuf[0 .. keyPemPath.length] = keyPemPath[];
        cKeyBuf[keyPemPath.length] = '\0';

        if (SSL_CTX_use_certificate_file(ctx.m_ctx, cCertBuf.ptr, SSL_FILETYPE_PEM) <= 0
                || SSL_CTX_use_PrivateKey_file(ctx.m_ctx, cKeyBuf.ptr, SSL_FILETYPE_PEM) <= 0)
        {
            ctx.cleanup();
            return ctx;
        }

        // Default server ALPN protocols: "h3" and "smsp/1"
        const(char)[][2] defaultAlpn = ["h3", "smsp/1"];
        ctx.setAlpnProtocols(defaultAlpn[]);

        return ctx;
    }

    /**
     * Creates a client TLS context with peer verification enabled by default (RFC 9001 Section 8.2).
     */
    static TlsContext createClient(scope const(char)[] caFilePath = null) @trusted @nogc nothrow
    {
        TlsContext ctx;
        ctx.m_isServer = false;
        ctx.m_ctx = SSL_CTX_new(TLS_client_method());
        if (ctx.m_ctx is null)
            return ctx;

        // Require TLS 1.3
        SSL_CTX_ctrl(ctx.m_ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_3_VERSION, null);

        // Enable peer verification & system CA paths
        SSL_CTX_set_verify(ctx.m_ctx, SSL_VERIFY_PEER, null);
        SSL_CTX_set_default_verify_paths(ctx.m_ctx);
        ctx.m_verifyPeer = true;

        if (caFilePath.length > 0)
        {
            if (caFilePath.length >= 1024)
            {
                ctx.cleanup();
                return ctx;
            }
            char[1024] caBuf = void;
            caBuf[0 .. caFilePath.length] = caFilePath[];
            caBuf[caFilePath.length] = '\0';

            if (SSL_CTX_load_verify_locations(ctx.m_ctx, caBuf.ptr, null) <= 0)
            {
                ctx.cleanup();
                return ctx;
            }
        }

        return ctx;
    }

    /**
     * Creates an insecure client TLS context with SSL_VERIFY_NONE.
     *
     * Used exclusively for unit tests or loopback self-signed test fixtures.
     */
    static TlsContext createClientInsecure() @trusted @nogc nothrow
    {
        TlsContext ctx;
        ctx.m_isServer = false;
        ctx.m_ctx = SSL_CTX_new(TLS_client_method());
        if (ctx.m_ctx is null)
            return ctx;

        // Require TLS 1.3
        SSL_CTX_ctrl(ctx.m_ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_3_VERSION, null);
        SSL_CTX_set_verify(ctx.m_ctx, SSL_VERIFY_NONE, null);

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
    /// Whether a recorded certificate chain error aborts the handshake (R-20).
    bool verifyPeer;
    bool hasAlert;
    ubyte alertCode;

    // Expected incoming level & current outgoing level (fixing High-3)
    EncryptionLevel expectedReadLevel;
    EncryptionLevel writeLevel;

    // Transport Parameters (RFC 9000 & F-34: 2048 bytes capacity)
    ubyte[2048] peerParams;
    size_t peerParamsLen;
    ubyte[2048] localParams;
    size_t localParamsLen;
    bool peerParamsOverflow;
    /// A yielded traffic secret did not fit its slot: the handshake cannot continue (R-33).
    bool secretOverflow;

    // Incoming crypto feed
    const(ubyte)* inBufPtr;
    size_t inBufLen;
    size_t inBufOffset;

    // Outgoing crypto buffers per encryption level (F-34: 16 KiB handshake buffer)
    ubyte[4096] outInitial;
    size_t outInitialLen;
    ubyte[16384] outHandshake;
    size_t outHandshakeLen;
    ubyte[4096] out1Rtt;
    size_t out1RttLen;

    // Yielded traffic secrets
    SecretSlot hsReadSec;
    SecretSlot hsWriteSec;
    SecretSlot appReadSec;
    SecretSlot appWriteSec;

    int onCryptoSend(const(ubyte)* buf, size_t bufLen, size_t* consumed) @trusted @nogc nothrow
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

        // The flight must be stored whole: a partial copy that is reported as success would drop
        // handshake bytes silently (RFC 9001 Section 4.1.3 requires CRYPTO data in full), so
        // an overflow fails the handshake and leaves the buffer untouched (R-29).
        *consumed = 0;
        if (bufLen > target.length - *pLen)
            return 0;

        if (bufLen > 0)
        {
            target[*pLen .. *pLen + bufLen] = buf[0 .. bufLen];
            *pLen += bufLen;
        }

        *consumed = bufLen;
        return 1;
    }

    int onCryptoRecv(const(ubyte)** buf, size_t* bytesRead) @trusted @nogc nothrow
    {
        const size_t avail = inBufLen - inBufOffset;
        if (avail > 0)
        {
            *buf = inBufPtr + inBufOffset;
            *bytesRead = avail;
        }
        else
        {
            *buf = null;
            *bytesRead = 0;
        }
        return 1;
    }

    int onCryptoRelease(size_t bytesRead) @safe @nogc nothrow
    {
        inBufOffset += bytesRead;
        return 1;
    }

    int onYieldSecret(uint protLevel, int direction, const(ubyte)* secret, size_t secretLen) @trusted @nogc nothrow
    {
        SecretSlot* slot;
        if (protLevel == OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE)
        {
            slot = (direction == 1) ? &hsWriteSec : &hsReadSec;
        }
        else if (protLevel == OSSL_RECORD_PROTECTION_LEVEL_APPLICATION)
        {
            slot = (direction == 1) ? &appWriteSec : &appReadSec;
        }

        if (slot !is null)
        {
            // A secret that does not fit would leave the level advanced without keys to
            // protect it: fail the callback and record why, before any state moves (R-33).
            if (secretLen > slot.data.length)
            {
                secretOverflow = true;
                return 0;
            }
            slot.data[0 .. secretLen] = secret[0 .. secretLen];
            slot.len = secretLen;
            slot.valid = true;
        }

        if (direction == 1)
        {
            if (protLevel == OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE)
                writeLevel = EncryptionLevel.handshake;
            else if (protLevel == OSSL_RECORD_PROTECTION_LEVEL_APPLICATION)
                writeLevel = EncryptionLevel.oneRtt;
        }
        else if (direction == 0)
        {
            if (protLevel == OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE)
                expectedReadLevel = EncryptionLevel.handshake;
            else if (protLevel == OSSL_RECORD_PROTECTION_LEVEL_APPLICATION)
                expectedReadLevel = EncryptionLevel.oneRtt;
        }

        return 1;
    }

    /// The failure recorded by a callback during the handshake, if any (also raises the alert).
    QuicCryptoError paramFailure() @safe @nogc nothrow
    {
        if (peerParamsOverflow)
        {
            hasAlert = true;
            alertCode = 47; // illegal_parameter
            return QuicCryptoError.transportParamsTooLarge;
        }
        if (secretOverflow)
        {
            hasAlert = true;
            alertCode = 80; // internal_error
            return QuicCryptoError.internalError;
        }
        return QuicCryptoError.none;
    }

    int onGotTransportParams(const(ubyte)* params, size_t paramsLen) @trusted @nogc nothrow
    {
        if (paramsLen > peerParams.length)
        {
            peerParamsOverflow = true;
            return 0; // Reject oversized transport parameters per RFC 9000 & F-34
        }
        peerParams[0 .. paramsLen] = params[0 .. paramsLen];
        peerParamsLen = paramsLen;
        return 1;
    }

    int onAlert(ubyte alertCodeIn) @safe @nogc nothrow
    {
        alertCode = alertCodeIn;
        hasAlert = true;
        return 1;
    }
}

// OpenSSL 3.5 QUIC TLS Callbacks dispatching to heap-allocated TlsSessionState
extern (C) private int quicCryptoSendCb(SSL* s, const(ubyte)* buf,
        size_t buf_len, size_t* consumed, void* arg) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null)
        return 0;
    return state.onCryptoSend(buf, buf_len, consumed);
}

extern (C) private int quicCryptoRecvRcdCb(SSL* s, const(ubyte)** buf,
        size_t* bytes_read, void* arg) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null)
        return 0;
    return state.onCryptoRecv(buf, bytes_read);
}

extern (C) private int quicCryptoReleaseRcdCb(SSL* s, size_t bytes_read, void* arg) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null)
        return 0;
    return state.onCryptoRelease(bytes_read);
}

extern (C) private int quicYieldSecretCb(SSL* s, uint prot_level, int direction,
        const(ubyte)* secret, size_t secret_len, void* arg) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null)
        return 0;

    const(SSL_CIPHER)* c = SSL_get_current_cipher(s);
    if (c !is null)
    {
        const uint id = SSL_CIPHER_get_protocol_id(c);
        state.cipher = cast(CipherSuite) id;
    }

    return state.onYieldSecret(prot_level, direction, secret, secret_len);
}

extern (C) private int quicGotTransportParamsCb(SSL* s, const(ubyte)* params,
        size_t params_len, void* arg) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null)
        return 0;
    return state.onGotTransportParams(params, params_len);
}

extern (C) private int quicAlertCb(SSL* s, ubyte alert_code, void* arg) @nogc nothrow
{
    TlsSessionState* state = cast(TlsSessionState*) arg;
    if (state is null)
        return 0;
    return state.onAlert(alert_code);
}

private static immutable OSSL_DISPATCH[7] s_quicTlsDispatch = [
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_SEND, cast(immutable(void)*)&quicCryptoSendCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RECV_RCD, cast(immutable(void)*)&quicCryptoRecvRcdCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RELEASE_RCD,
            cast(immutable(void)*)&quicCryptoReleaseRcdCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_YIELD_SECRET, cast(immutable(void)*)&quicYieldSecretCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_GOT_TRANSPORT_PARAMS,
            cast(immutable(void)*)&quicGotTransportParamsCb),
    immutable(OSSL_DISPATCH)(OSSL_FUNC_SSL_QUIC_TLS_ALERT,
            cast(immutable(void)*)&quicAlertCb), immutable(OSSL_DISPATCH)(0, null)
];

/// Longest accepted server name in bytes.
enum size_t MAX_SERVER_NAME_LEN = 255;

/**
 * Checks a client-supplied server name and yields the host to use (IPv6 brackets removed).
 * An empty `serverName` is not an error here (`host` is empty; the caller decides whether a
 * name is required). Rejected with `invalidServerName`: more than 255 bytes (the limit of a
 * DNS name and of what OpenSSL accepts for SNI, RFC 1035 Section 2.3.4), an empty host
 * between brackets, brackets around a non-IP name, a leading or trailing '.', an empty label
 * (".."), a space, any byte outside the LDH set (letters, digits, '-', '.'; so IDNs must be
 * punycode and '*' is refused), and any NUL or other control character (U+0000-U+001F, U+007F), which
 * would truncate the C string handed to OpenSSL or smuggle a different host past the check.
 */
package(slate.quic) QuicCryptoError validateServerName(
        return scope const(char)[] serverName, out const(char)[] host) @safe @nogc nothrow pure
{
    if (serverName.length > MAX_SERVER_NAME_LEN)
        return QuicCryptoError.invalidServerName;
    const(char)[] name = serverName;
    bool bracketed = false;
    if (name.length >= 2 && name[0] == '[' && name[$ - 1] == ']')
    {
        name = name[1 .. $ - 1];
        bracketed = true;
        if (name.length == 0)
            return QuicCryptoError.invalidServerName;
    }
    foreach (c; name)
    {
        if (c <= 0x20 || c == 0x7f)
            return QuicCryptoError.invalidServerName;
    }
    // Brackets only delimit IP literals (RFC 3986 Section 3.2.2); "[example.com]" is malformed.
    if (bracketed && !isIpLiteral(name))
        return QuicCryptoError.invalidServerName;
    // A DNS name has no empty labels: a leading '.' would be an any-subdomain pattern for
    // OpenSSL's host matching, and ".." or a trailing '.' is not a valid HostName
    // (RFC 6066 Section 3: no trailing dot). The FQDN form "host." is rejected, not stripped,
    // so the name that is verified is the name that is sent.
    if (!isIpLiteral(name) && name.length > 0)
    {
        if (name[0] == '.' || name[$ - 1] == '.')
            return QuicCryptoError.invalidServerName;
        foreach (i; 1 .. name.length)
        {
            if (name[i] == '.' && name[i - 1] == '.')
                return QuicCryptoError.invalidServerName;
        }
        // Only LDH labels (letters, digits, '-') plus the '.' separators remain (RFC 1123
        // Section 2.1, RFC 5890 Section 2.3.1): IDNs must already be punycode, and '*' (a wildcard
        // pattern, never a host name) or any other byte is rejected (PB-6).
        foreach (c; name)
        {
            const bool ldh = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9') || c == '-' || c == '.';
            if (!ldh)
                return QuicCryptoError.invalidServerName;
        }
    }
    host = name;
    return QuicCryptoError.none;
}

/**
 * Whether `name` (brackets already stripped) is an IPv4 dotted-quad or IPv6 textual literal.
 * Such names are identities for IP SAN matching and must never be sent as SNI (RFC 6066 Section 3).
 */
package(slate.quic) bool isIpLiteral(scope const(char)[] name) @safe @nogc nothrow pure
{
    if (name.length == 0)
        return false;

    // IPv6: hex digits, ':' and an optional embedded dotted-quad tail.
    bool hasColon = false;
    foreach (c; name)
    {
        if (c == ':')
            hasColon = true;
        else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
                || c == '.'))
            return false;
    }
    if (hasColon)
        return true;

    // IPv4: exactly four decimal parts, each 0..255.
    size_t parts = 0;
    size_t i = 0;
    while (i <= name.length)
    {
        size_t digits = 0;
        uint value = 0;
        while (i < name.length && name[i] >= '0' && name[i] <= '9')
        {
            value = value * 10 + (name[i] - '0');
            digits++;
            i++;
            if (digits > 3)
                return false;
        }
        if (digits == 0 || value > 255)
            return false;
        parts++;
        if (i == name.length)
            break;
        if (name[i] != '.')
            return false;
        i++;
    }
    return parts == 4;
}

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
    TlsAlpnConfig* m_alpnConfig;
    bool m_hsKeysPolled;
    bool m_appKeysPolled;

public:
    /**
     * Initializes TlsSession with TlsContext, endpoint side, and transport parameters.
     *
     * Use `init` and check its result: the constructor cannot report failure.
     */
    this(ref TlsContext ctx, Side side, const(ubyte)[] transportParams,
            const(char)[] clientAlpn = "h3", const(char)[] serverName = null) @trusted @nogc nothrow
    {
        init(ctx, side, transportParams, clientAlpn, serverName);
    }

    /**
     * (Re-)initializes the session. Returns `QuicCryptoError.none` on success; on failure the
     * session is left cleaned up (no handles retained).
     *
     * A client whose context verifies the peer certificate chain must be given a server name
     * (RFC 9001 Section 4.4, RFC 6125 Section 6): `missingServerName` otherwise. A DNS name is
     * sent as SNI and matched against DNS SANs; an IP literal is matched against IP SANs only
     * and is not sent as SNI (RFC 6066 Section 3). A malformed name (see `validateServerName`)
     * yields `invalidServerName` for every client, verifying or not, instead of being ignored.
     */
    QuicCryptoError init(ref TlsContext ctx, Side side,
            const(ubyte)[] transportParams, const(char)[] clientAlpn = "h3",
            const(char)[] serverName = null) @trusted @nogc nothrow
    {
        cleanup();

        // Reject empty or oversized local transport parameters (RFC 9000 & F-34)
        if (transportParams.length == 0 || transportParams.length > 2048)
            return QuicCryptoError.transportParamsTooLarge;

        // Check the name policy before allocating anything, so this error path owns nothing.
        const(char)[] name = null;
        if (side == Side.client)
        {
            const nameErr = validateServerName(serverName, name);
            if (nameErr != QuicCryptoError.none)
                return nameErr;
            if (name.length == 0 && ctx.verifiesPeer)
                return QuicCryptoError.missingServerName;
        }

        import core.stdc.stdlib : calloc;

        m_state = cast(TlsSessionState*) calloc(1, TlsSessionState.sizeof);
        if (m_state is null)
            return QuicCryptoError.internalError;

        m_state.side = side;
        m_state.verifyPeer = ctx.verifiesPeer;
        m_state.cipher = CipherSuite.TLS_AES_128_GCM_SHA256;
        m_state.expectedReadLevel = EncryptionLevel.initial;
        m_state.writeLevel = EncryptionLevel.initial;

        m_ssl = SSL_new(ctx.handle);
        if (m_ssl is null)
        {
            cleanup();
            return QuicCryptoError.internalError;
        }

        m_alpnConfig = ctx.m_alpnConfig;
        retainAlpnConfig(m_alpnConfig);

        if (side == Side.server)
        {
            SSL_set_accept_state(m_ssl);
        }
        else
        {
            SSL_set_connect_state(m_ssl);

            // Configure SNI & identity verification
            if (name.length > 0)
            {
                char[1024] hostBuf = void;
                hostBuf[0 .. name.length] = name[];
                hostBuf[name.length] = '\0';

                if (isIpLiteral(name))
                {
                    // IP identity: verified against iPAddress SANs, never sent as SNI.
                    X509_VERIFY_PARAM* param = SSL_get0_param(m_ssl);
                    if (param is null || X509_VERIFY_PARAM_set1_ip_asc(param, hostBuf.ptr) != 1)
                    {
                        cleanup();
                        return QuicCryptoError.cryptoError;
                    }
                }
                else
                {
                    if (SSL_ctrl(m_ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name,
                            cast(void*) hostBuf.ptr) != 1 || SSL_set1_host(m_ssl, hostBuf.ptr) != 1)
                    {
                        cleanup();
                        return QuicCryptoError.cryptoError;
                    }
                }
            }

            // Configure Client ALPN
            if (clientAlpn.length > 0 && clientAlpn.length <= 255)
            {
                ubyte[256] alpnWire;
                alpnWire[0] = cast(ubyte) clientAlpn.length;
                alpnWire[1 .. 1 + clientAlpn.length] = cast(const(ubyte)[]) clientAlpn[];
                SSL_set_alpn_protos(m_ssl, alpnWire.ptr, cast(uint)(1 + clientAlpn.length));
            }
        }

        SSL_set_quic_tls_cbs(m_ssl, s_quicTlsDispatch.ptr, m_state);

        m_state.localParamsLen = transportParams.length;
        m_state.localParams[0 .. m_state.localParamsLen] = transportParams[];
        SSL_set_quic_tls_transport_params(m_ssl, m_state.localParams.ptr, m_state.localParamsLen);
        return QuicCryptoError.none;
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
            OPENSSL_cleanse(m_state.hsReadSec.data.ptr, m_state.hsReadSec.data.length);
            OPENSSL_cleanse(m_state.hsWriteSec.data.ptr, m_state.hsWriteSec.data.length);
            OPENSSL_cleanse(m_state.appReadSec.data.ptr, m_state.appReadSec.data.length);
            OPENSSL_cleanse(m_state.appWriteSec.data.ptr, m_state.appWriteSec.data.length);
            import core.stdc.stdlib : free;

            free(m_state);
            m_state = null;
        }
        releaseAlpnConfig(m_alpnConfig);
        m_hsKeysPolled = false;
        m_appKeysPolled = false;
    }

    void moveFrom(ref TlsSession other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;
        cleanup();
        m_ssl = other.m_ssl;
        m_state = other.m_state;
        m_alpnConfig = other.m_alpnConfig;
        m_hsKeysPolled = other.m_hsKeysPolled;
        m_appKeysPolled = other.m_appKeysPolled;
        other.m_ssl = null;
        other.m_state = null;
        other.m_alpnConfig = null;
    }

    /**
     * Feeds incoming CRYPTO data from a QUIC packet into TLS.
     *
     * Validates that the data's EncryptionLevel matches the expected read level (RFC 9001 Section 4.1.3).
     */
    QuicCryptoError provideCryptoData(EncryptionLevel level, const(ubyte)[] data) @trusted @nogc nothrow
    {
        if (m_state is null || m_ssl is null)
            return QuicCryptoError.internalError;

        // F4 & RFC 9001 Section 4.1.3: Reject cross-encryption-level record injection
        if (level != m_state.expectedReadLevel)
            return QuicCryptoError.cryptoError;

        m_state.inBufPtr = data.ptr;
        m_state.inBufLen = data.length;
        m_state.inBufOffset = 0;
        scope (exit)
        {
            m_state.inBufPtr = null;
            m_state.inBufLen = 0;
            m_state.inBufOffset = 0;
        }

        return stepHandshake();
    }

    /**
     * Canonical D3 API: Feeds incoming CRYPTO data for the given level.
     */
    QuicCryptoError readHandshake(EncryptionLevel level, const(ubyte)[] data) @trusted @nogc nothrow
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

        const preErr = m_state.paramFailure();
        if (preErr != QuicCryptoError.none)
            return preErr;

        const int ret = SSL_do_handshake(m_ssl);

        // The callbacks run inside SSL_do_handshake: their recorded failures (oversized peer
        // transport parameters, a traffic secret that does not fit) decide the result even when
        // OpenSSL itself reports success or a generic failure (R-33, R-34).
        const postErr = m_state.paramFailure();
        if (postErr != QuicCryptoError.none)
            return postErr;

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

        // Only a verifying context treats a recorded chain error as fatal; with verification off
        // the error is merely recorded while the handshake goes on (R-20, RFC 9001 Section 4.4).
        const c_long verifyRes = m_state.verifyPeer ? SSL_get_verify_result(m_ssl) : X509_V_OK;
        if (verifyRes != X509_V_OK)
        {
            if (!m_state.hasAlert)
            {
                m_state.hasAlert = true;
                m_state.alertCode = 42; // bad_certificate
            }
            return QuicCryptoError.handshakeFailed;
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

    /**
     * Returns the negotiated ALPN protocol string, or empty slice if not negotiated.
     */
    @property const(char)[] negotiatedAlpn() const return @trusted @nogc nothrow
    {
        if (m_ssl is null)
            return null;
        const(ubyte)* data = null;
        uint len = 0;
        SSL_get0_alpn_selected(m_ssl, &data, &len);
        if (data is null || len == 0)
            return null;
        return cast(const(char)[]) data[0 .. len];
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
            if (count >= m_state.outHandshakeLen)
                m_state.outHandshakeLen = 0;
            else
            {
                m_state.outHandshake[0 .. m_state.outHandshakeLen - count]
                    = m_state.outHandshake[count .. m_state.outHandshakeLen];
                m_state.outHandshakeLen -= count;
            }
            break;
        case EncryptionLevel.oneRtt:
            if (count >= m_state.out1RttLen)
                m_state.out1RttLen = 0;
            else
            {
                m_state.out1Rtt[0 .. m_state.out1RttLen - count]
                    = m_state.out1Rtt[count .. m_state.out1RttLen];
                m_state.out1RttLen -= count;
            }
            break;
        case EncryptionLevel.initial:
        default:
            if (count >= m_state.outInitialLen)
                m_state.outInitialLen = 0;
            else
            {
                m_state.outInitial[0 .. m_state.outInitialLen - count]
                    = m_state.outInitial[count .. m_state.outInitialLen];
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
    bool pollKeys(EncryptionLevel level, ref DirectionalKeys readKeys, ref DirectionalKeys writeKeys) @trusted @nogc nothrow
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
        KeyMaterial wKm;
        scope (exit)
        {
            OPENSSL_cleanse(rKm.key.ptr, rKm.key.length);
            OPENSSL_cleanse(rKm.hp.ptr, rKm.hp.length);
            OPENSSL_cleanse(wKm.key.ptr, wKm.key.length);
            OPENSSL_cleanse(wKm.hp.ptr, wKm.hp.length);
        }
        if (!deriveKeyMaterial(m_state.cipher, rSlot.data[0 .. rSlot.len],
                rKm) || !deriveKeyMaterial(m_state.cipher, wSlot.data[0 .. wSlot.len], wKm))
            return false;
        if (!readKeys.init(m_state.cipher, rKm.key[0 .. rKm.keyLen],
                rKm.iv[0 .. 12], rKm.hp[0 .. rKm.hpLen]) || !writeKeys.init(m_state.cipher,
                wKm.key[0 .. wKm.keyLen], wKm.iv[0 .. 12], wKm.hp[0 .. wKm.hpLen]))
            return false;

        return readKeys.initialized && writeKeys.initialized;
    }
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[4] params = [1, 2, 3, 4];
/// TlsSession server, client;
/// server.init(serverCtx, Side.server, params);
/// client.init(clientCtx, Side.client, params);
/// ubyte[4096] b1, b2, b3, b4;
/// client.stepHandshake();
/// assert(server.readHandshake(EncryptionLevel.initial,
///         client.writeHandshake(EncryptionLevel.initial, b1)) == QuicCryptoError.none);
/// const sInitial = server.writeHandshake(EncryptionLevel.initial, b2);
/// const sHandshake = server.writeHandshake(EncryptionLevel.handshake, b3);
/// assert(client.readHandshake(EncryptionLevel.initial, sInitial) == QuicCryptoError.none);
/// assert(client.readHandshake(EncryptionLevel.handshake, sHandshake) == QuicCryptoError.none);
/// assert(server.readHandshake(EncryptionLevel.handshake,
///         client.writeHandshake(EncryptionLevel.handshake, b4)) == QuicCryptoError.none);
/// // the server's 1-RTT write keys protect a packet
/// TlsSession.LevelKeys hsKeys, oneRttKeys;
/// assert(server.pollNextKeys(hsKeys) && server.pollNextKeys(oneRttKeys));
/// assert(oneRttKeys.level == EncryptionLevel.oneRtt);
/// ubyte[26] packet;
/// packet[0 .. 10] = [0x40, 0x01, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80];
/// size_t protLen;
/// assert(protectPacket(oneRttKeys.writeKeys, 1, 1, 1, packet, 8, protLen) == QuicCryptoError.none);
/// assert(protLen == 2 + 8 + 16);
/// ---
// Spec: RFC 9001 Section 4 - In-Memory TLS 1.3 QUIC Handshake (covers U1, U2, U3, E5, Scenario T5)
unittest
{
    // Initialize server and client contexts
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();

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

    assert(serverSession.peerTransportParams == clientParams,
            "Server must receive client transport params");

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

    assert(clientSession.peerTransportParams == serverParams,
            "Client must receive server transport params");
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
        0x40, 0x01, // 1-RTT Short Header (pnLen = 1)
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, // 8 bytes plaintext
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0,
        0 // Tag space
    ];

    size_t protLen = 0;
    const protErr = protectPacket(serverKeys2.writeKeys, 1, 1, 1, packetBuffer, 8, protLen);
    assert(protErr == QuicCryptoError.none, "1-RTT protectPacket failed");
    assert(protLen == 2 + 8 + 16, "1-RTT packet length mismatch");

    // Decrypt on client with clientReadKeys
    size_t decPnLen;
    ulong decPn;
    size_t decPayOff;
    size_t decPlainLen;
    const decErr = unprotectPacket(clientKeys2.readKeys, 1, 0,
            packetBuffer[0 .. protLen], decPnLen, decPn, decPayOff, decPlainLen);
    assert(decErr == QuicCryptoError.none, "1-RTT unprotectPacket failed");
    assert(decPn == 1, "Decrypted packet number mismatch");
    assert(decPlainLen == 8, "Decrypted payload length mismatch");
    assert(packetBuffer[decPayOff .. decPayOff + 8] == [
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80
    ], "Plaintext mismatch");
}
