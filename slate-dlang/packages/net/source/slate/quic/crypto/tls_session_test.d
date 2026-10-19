module slate.quic.crypto.tls_session_test;

import slate.quic.crypto.tls_session;
import slate.quic.crypto.c_openssl;
import slate.quic.crypto.kdf;
import slate.quic.crypto.aead;
import slate.quic.crypto.header_protection;
import slate.quic.crypto.packet_keys;

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[4] params = [1, 2, 3, 4];
/// TlsSession serverSession, clientSession;
/// serverSession.init(serverCtx, Side.server, params);
/// clientSession.init(clientCtx, Side.client, params, "hq-29");   // the server speaks another ALPN
/// clientSession.stepHandshake();
/// const clientHello = clientSession.getOutput(EncryptionLevel.initial);
/// const sErr = serverSession.provideCryptoData(EncryptionLevel.initial, clientHello);
/// assert(sErr == QuicCryptoError.alpnMismatch);
/// assert(serverSession.alertCode == 120);          // no_application_protocol
/// assert(serverSession.quicErrorCode == 0x0178);   // 0x0100 | 120
/// ---
// Spec: RFC 9001 Section 4.8 & Section 8.1 - ALPN Mismatch & Alert Mapping (covers W3, Scenario T6)
unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();

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

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const(char)[][1] customProtos = ["smsp/1"];
/// assert(serverCtx.setAlpnProtocols(customProtos[]));   // the server only speaks smsp/1
/// const ubyte[4] sParams = [1, 2, 3, 4];
/// const ubyte[4] cParams = [5, 6, 7, 8];
/// TlsSession server, client;
/// server.init(serverCtx, Side.server, sParams);
/// client.init(clientCtx, Side.client, cParams, "unknown/9");   // the client offers something else
/// assert(client.stepHandshake() == QuicCryptoError.none);
/// const cHello = client.getOutput(EncryptionLevel.initial);
/// const sErr = server.provideCryptoData(EncryptionLevel.initial, cHello);
/// assert(sErr == QuicCryptoError.alpnMismatch);
/// assert(server.alertCode == 120);                 // no_application_protocol
/// assert(server.negotiatedAlpn.length == 0);
/// ---
// Spec: RFC 9001 Section 8.1 & Scenario T1 - Configurable ALPN negotiation ("smsp/1", "h3") and mismatch rejection (covers U1, W1)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);

    const ubyte[4] sParams = [1, 2, 3, 4];
    const ubyte[4] cParams = [5, 6, 7, 8];

    // 1. Default server context accepts "smsp/1" and reports negotiatedAlpn == "smsp/1"
    {
        TlsSession server;
        server.init(serverCtx, Side.server, sParams);
        TlsSession client;
        client.init(clientCtx, Side.client, cParams, "smsp/1");

        assert(client.stepHandshake() == QuicCryptoError.none);
        ubyte[2048] chBuf;
        const cHello = client.writeHandshake(EncryptionLevel.initial, chBuf);
        assert(cHello.length > 0);

        assert(server.readHandshake(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
        assert(server.negotiatedAlpn == "smsp/1");

        ubyte[2048] sInitBuf;
        const sInit = server.writeHandshake(EncryptionLevel.initial, sInitBuf);
        ubyte[4096] sHsBuf;
        const sHs = server.writeHandshake(EncryptionLevel.handshake, sHsBuf);

        assert(client.readHandshake(EncryptionLevel.initial, sInit) == QuicCryptoError.none);
        assert(client.readHandshake(EncryptionLevel.handshake, sHs) == QuicCryptoError.none);
        assert(client.isHandshakeComplete);
        assert(client.negotiatedAlpn == "smsp/1");

        ubyte[2048] cFinBuf;
        const cFin = client.writeHandshake(EncryptionLevel.handshake, cFinBuf);
        assert(server.readHandshake(EncryptionLevel.handshake, cFin) == QuicCryptoError.none);
        assert(server.isHandshakeComplete);
        assert(server.negotiatedAlpn == "smsp/1");
    }

    // 2. Custom server ALPN list restricts accepted protocol and rejects others with alert 120
    const(char)[][1] customProtos = ["smsp/1"];
    assert(serverCtx.setAlpnProtocols(customProtos[]));
    assert(!serverCtx.setAlpnProtocol("")); // empty protocol rejected

    {
        TlsSession server;
        server.init(serverCtx, Side.server, sParams);
        TlsSession client;
        client.init(clientCtx, Side.client, cParams, "unknown/9");

        assert(client.stepHandshake() == QuicCryptoError.none);
        const cHello = client.getOutput(EncryptionLevel.initial);
        const sErr = server.provideCryptoData(EncryptionLevel.initial, cHello);
        assert(sErr == QuicCryptoError.alpnMismatch);
        assert(server.alertCode == 120);
        assert(server.negotiatedAlpn.length == 0);
    }
}

/// Helper to create and return a TlsSession by value
private TlsSession createMovedClientSession(ref TlsContext ctx, const(ubyte)[] params) @trusted
{
    TlsSession session;
    session.init(ctx, Side.client, params);
    return session;
}

/// Example:
/// ---
/// import core.lifetime : move;
///
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[4] params = [1, 1, 1, 1];
/// TlsSession tempServer;
/// tempServer.init(serverCtx, Side.server, params);
/// TlsSession serverSession = move(tempServer);     // the OpenSSL callbacks survive the move
/// TlsSession clientSession;
/// clientSession.init(clientCtx, Side.client, params);
/// assert(clientSession.stepHandshake() == QuicCryptoError.none);
/// const cHello = clientSession.getOutput(EncryptionLevel.initial);
/// assert(serverSession.provideCryptoData(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
/// const sInit = serverSession.getOutput(EncryptionLevel.initial);
/// const sHs = serverSession.getOutput(EncryptionLevel.handshake);
/// assert(clientSession.provideCryptoData(EncryptionLevel.initial, sInit) == QuicCryptoError.none);
/// assert(clientSession.provideCryptoData(EncryptionLevel.handshake, sHs) == QuicCryptoError.none);
/// ---
// Spec: OpenSSL 3.5 SSL_set_quic_tls_cbs callback stability across struct moves (covers Critical-1)
unittest
{
    import core.lifetime : move;

    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();

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
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[4] params = [1, 2, 3, 4];
/// TlsSession serverSession, clientSession;
/// serverSession.init(serverCtx, Side.server, params);
/// clientSession.init(clientCtx, Side.client, params);
/// clientSession.stepHandshake();
/// const cHello = clientSession.getOutput(EncryptionLevel.initial);
/// // Initial data offered at the Handshake level is rejected, at its own level it is accepted
/// assert(serverSession.provideCryptoData(EncryptionLevel.handshake, cHello) == QuicCryptoError.cryptoError);
/// assert(serverSession.provideCryptoData(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
/// ---
// Spec: RFC 9001 Section 4.1.3 - Cross-Encryption-Level Record Injection Rejection (covers F4, High-3)
unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();

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
    assert(badLevelErr == QuicCryptoError.cryptoError,
            "Cross-level data injection must be rejected");

    // Feed correctly at Initial level -> succeeds
    const okErr = serverSession.provideCryptoData(EncryptionLevel.initial, cHello);
    assert(okErr == QuicCryptoError.none);

    // Now server expects Handshake level for incoming data; attempting Initial must fail
    const badSecondErr = serverSession.provideCryptoData(EncryptionLevel.initial, cHello);
    assert(badSecondErr == QuicCryptoError.cryptoError,
            "Injecting Initial data when expecting Handshake must be rejected");
}

/// Example:
/// ---
/// TlsContext bad = TlsContext.createServer("/nonexistent/cert.pem", "/nonexistent/key.pem");
/// assert(!bad.isValid);   // a context is never built from unreadable files
/// ---
// Spec: Validation of Certificate & Key paths in TlsContext (covers Minor-6)
unittest
{
    TlsContext badCtx = TlsContext.createServer("/nonexistent/path/cert.pem",
            "/nonexistent/path/key.pem");
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
    assert(serverSession.readHandshake(EncryptionLevel.initial, clientHello) == QuicCryptoError
            .none);
    ubyte[2048] sInitBuf;
    const serverInitial = serverSession.writeHandshake(EncryptionLevel.initial, sInitBuf);
    ubyte[4096] sHsBuf;
    const serverHandshake = serverSession.writeHandshake(EncryptionLevel.handshake, sHsBuf);
    assert(serverInitial.length > 0);
    assert(serverHandshake.length > 0);

    // Flight 3: Client processes Server Initial + Handshake -> produces Client Finished
    assert(clientSession.readHandshake(EncryptionLevel.initial,
            serverInitial) == QuicCryptoError.none);
    assert(clientSession.readHandshake(EncryptionLevel.handshake,
            serverHandshake) == QuicCryptoError.none);
    assert(clientSession.isHandshakeComplete);
    ubyte[2048] cHsBuf;
    const clientHandshake = clientSession.writeHandshake(EncryptionLevel.handshake, cHsBuf);
    assert(clientHandshake.length > 0);

    // Flight 4: Server processes Client Finished
    assert(serverSession.readHandshake(EncryptionLevel.handshake,
            clientHandshake) == QuicCryptoError.none);
    assert(serverSession.isHandshakeComplete);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// runNogcHandshake(serverCtx, clientCtx);         // both sides reach isHandshakeComplete
/// ---
// Spec: RFC 9001 Section 4 - Verified @nogc hot-path execution of Sans-I/O TLS Handshake (covers U2, G2)
unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);

    runNogcHandshake(serverCtx, clientCtx);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// SSL_CTX_set_ciphersuites(serverCtx.handle, "TLS_AES_256_GCM_SHA384");
/// SSL_CTX_set_ciphersuites(clientCtx.handle, "TLS_AES_256_GCM_SHA384");
/// const ubyte[4] params = [1, 2, 3, 4];
/// TlsSession server, client;
/// server.init(serverCtx, Side.server, params);
/// client.init(clientCtx, Side.client, params);
/// client.stepHandshake();
/// ubyte[2048] cHelloBuf;
/// const cHello = client.writeHandshake(EncryptionLevel.initial, cHelloBuf);
/// assert(server.readHandshake(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
/// TlsSession.LevelKeys serverHsKeys;
/// assert(server.pollNextKeys(serverHsKeys) && serverHsKeys.level == EncryptionLevel.handshake);
/// assert(server.negotiatedCipher == CipherSuite.TLS_AES_256_GCM_SHA384);
/// assert(serverHsKeys.readKeys.aead.cipherSuite == CipherSuite.TLS_AES_256_GCM_SHA384);
/// assert(serverHsKeys.writeKeys.aead.cipherSuite == CipherSuite.TLS_AES_256_GCM_SHA384);
/// ---
// Spec: RFC 9001 Section 5.3 - TLS_AES_256_GCM_SHA384 negotiation and early key derivation (covers E5, Scenario T5)
unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
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
/// ---
/// const ubyte[16] key = 0xAA;
/// const ubyte[12] iv = 0x55;
/// foreach (i; 0 .. 5_000)
/// {
///     AeadKey aead;                  // each handle frees its EVP context on scope exit
///     assert(aead.init(CipherSuite.TLS_AES_128_GCM_SHA256, key, iv));
///     assert(aead.isInitialized);
/// }
/// ---
// Spec: High-iteration RAII handle leak check for AeadKey, HeaderProtectionKey, and TlsSession (covers G5)
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
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
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

/// Example:
/// ---
/// const ubyte[4] params = [1, 2, 3, 4];
/// auto ctx = TlsContext.createClient();            // verifies chain and host name
/// TlsSession s;
/// assert(s.init(ctx, Side.client, params, "h3", "localhost") == QuicCryptoError.none);
/// ---
// Spec: RFC 9001 Section 4.4 & Section 8.2 & Scenario T5 - Client Certificate Verification and Hostname Validation (covers U2, W2, F-31)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);

    const ubyte[4] sParams = [1, 2, 3, 4];
    const ubyte[4] cParams = [5, 6, 7, 8];

    // (a) createClient() with default CA verification rejects server's self-signed cert
    {
        TlsContext clientCtx = TlsContext.createClient();
        assert(clientCtx.isValid);

        TlsSession server;
        server.init(serverCtx, Side.server, sParams);
        TlsSession client;
        assert(client.init(clientCtx, Side.client, cParams, "h3",
                "localhost") == QuicCryptoError.none);

        assert(client.stepHandshake() == QuicCryptoError.none);
        ubyte[2048] chBuf;
        const cHello = client.writeHandshake(EncryptionLevel.initial, chBuf);
        assert(cHello.length > 0);

        assert(server.readHandshake(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
        ubyte[2048] sInitBuf;
        const sInit = server.writeHandshake(EncryptionLevel.initial, sInitBuf);
        ubyte[4096] sHsBuf;
        const sHs = server.writeHandshake(EncryptionLevel.handshake, sHsBuf);

        assert(client.readHandshake(EncryptionLevel.initial, sInit) == QuicCryptoError.none);
        const hsErr = client.readHandshake(EncryptionLevel.handshake, sHs);
        assert(hsErr != QuicCryptoError.none,
                "Default createClient() must reject untrusted self-signed certificate");
        assert(!client.isHandshakeComplete,
                "Handshake must not complete when cert verification fails");
    }

    // (b) createClient("test/fixtures/quic_cert.pem") with serverName = "localhost" succeeds
    {
        TlsContext clientCtx = TlsContext.createClient("test/fixtures/quic_cert.pem");
        assert(clientCtx.isValid);

        TlsSession server;
        server.init(serverCtx, Side.server, sParams);
        TlsSession client;
        client.init(clientCtx, Side.client, cParams, "h3", "localhost");

        assert(client.stepHandshake() == QuicCryptoError.none);
        ubyte[2048] chBuf;
        const cHello = client.writeHandshake(EncryptionLevel.initial, chBuf);
        assert(cHello.length > 0);

        assert(server.readHandshake(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
        ubyte[2048] sInitBuf;
        const sInit = server.writeHandshake(EncryptionLevel.initial, sInitBuf);
        ubyte[4096] sHsBuf;
        const sHs = server.writeHandshake(EncryptionLevel.handshake, sHsBuf);

        assert(client.readHandshake(EncryptionLevel.initial, sInit) == QuicCryptoError.none);
        assert(client.readHandshake(EncryptionLevel.handshake, sHs) == QuicCryptoError.none);
        assert(client.isHandshakeComplete, "Valid CA and matching hostname must succeed");
    }

    // (c) createClient("test/fixtures/quic_cert.pem") with serverName = "evil.example.com" rejects cert due to hostname mismatch
    {
        TlsContext clientCtx = TlsContext.createClient("test/fixtures/quic_cert.pem");
        assert(clientCtx.isValid);

        TlsSession server;
        server.init(serverCtx, Side.server, sParams);
        TlsSession client;
        client.init(clientCtx, Side.client, cParams, "h3", "evil.example.com");

        assert(client.stepHandshake() == QuicCryptoError.none);
        ubyte[2048] chBuf;
        const cHello = client.writeHandshake(EncryptionLevel.initial, chBuf);
        assert(cHello.length > 0);

        assert(server.readHandshake(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
        ubyte[2048] sInitBuf;
        const sInit = server.writeHandshake(EncryptionLevel.initial, sInitBuf);
        ubyte[4096] sHsBuf;
        const sHs = server.writeHandshake(EncryptionLevel.handshake, sHsBuf);

        assert(client.readHandshake(EncryptionLevel.initial, sInit) == QuicCryptoError.none);
        const hsErr = client.readHandshake(EncryptionLevel.handshake, sHs);
        assert(hsErr != QuicCryptoError.none, "Mismatched hostname must fail handshake");
        assert(!client.isHandshakeComplete, "Handshake must not complete on hostname mismatch");
    }
}

/// Runs the client/server handshake exchange over the handshake levels and returns the
/// error of the client's final Handshake-level read (`none` on success). The ClientHello
/// bytes are copied to `helloOut` so a test can inspect what went on the wire.
private QuicCryptoError runHandshakeExchange(ref TlsSession client,
        ref TlsSession server, ubyte[] helloOut, out size_t helloLen) @trusted @nogc nothrow
{
    helloLen = 0;
    if (client.stepHandshake() != QuicCryptoError.none)
        return QuicCryptoError.handshakeFailed;
    ubyte[2048] chBuf;
    const cHello = client.writeHandshake(EncryptionLevel.initial, chBuf);
    if (cHello.length == 0 || cHello.length > helloOut.length)
        return QuicCryptoError.internalError;
    helloOut[0 .. cHello.length] = cHello[];
    helloLen = cHello.length;

    if (server.readHandshake(EncryptionLevel.initial, cHello) != QuicCryptoError.none)
        return QuicCryptoError.handshakeFailed;
    ubyte[2048] sInitBuf;
    const sInit = server.writeHandshake(EncryptionLevel.initial, sInitBuf);
    ubyte[4096] sHsBuf;
    const sHs = server.writeHandshake(EncryptionLevel.handshake, sHsBuf);

    const e = client.readHandshake(EncryptionLevel.initial, sInit);
    if (e != QuicCryptoError.none)
        return e;
    return client.readHandshake(EncryptionLevel.handshake, sHs);
}

/// The IP-SAN fixture lives in `packages/net/test/fixtures`; the working directory is either
/// that package or the `slate-dlang` root depending on how the tests are launched.
private void createIpFixtureServer(ref TlsContext c) @trusted @nogc nothrow
{
    auto t = TlsContext.createServer("test/fixtures/quic_cert_ip.pem",
            "test/fixtures/quic_key_ip.pem");
    if (!t.isValid)
    {
        auto u = TlsContext.createServer("packages/net/test/fixtures/quic_cert_ip.pem",
                "packages/net/test/fixtures/quic_key_ip.pem");
        t.moveFrom(u);
    }
    c.moveFrom(t);
}

private void createIpFixtureClient(ref TlsContext c) @trusted @nogc nothrow
{
    auto t = TlsContext.createClient("test/fixtures/quic_cert_ip.pem");
    if (!t.isValid)
    {
        auto u = TlsContext.createClient("packages/net/test/fixtures/quic_cert_ip.pem");
        t.moveFrom(u);
    }
    c.moveFrom(t);
}

private bool containsBytes(const(ubyte)[] haystack, const(char)[] needle) @safe @nogc nothrow pure
{
    if (needle.length == 0 || haystack.length < needle.length)
        return false;
    foreach (i; 0 .. haystack.length - needle.length + 1)
    {
        size_t j = 0;
        while (j < needle.length && haystack[i + j] == cast(ubyte) needle[j])
            j++;
        if (j == needle.length)
            return true;
    }
    return false;
}

/// Example:
/// ---
/// const ubyte[4] params = [1, 2, 3, 4];
/// auto ctx = TlsContext.createClient();
/// TlsSession s;
/// assert(s.init(ctx, Side.client, params, "h3", "") == QuicCryptoError.missingServerName);
/// ---
// Spec: RFC 9001 Section 4.4 / RFC 6125 Section 6 - a client that verifies the peer chain must
// also verify the identity, so an empty server name must fail initialisation instead of silently
// skipping the hostname check (R-06, W2, D2, Scenario T6)
@nogc unittest
{
    const ubyte[4] params = [1, 2, 3, 4];
    TlsContext verifying = TlsContext.createClient();
    assert(verifying.isValid && verifying.verifiesPeer);

    TlsSession s;
    assert(s.init(verifying, Side.client, params, "h3",
            "") == QuicCryptoError.missingServerName, "empty name must be rejected");
    assert(s.init(verifying, Side.client, params, "h3",
            null) == QuicCryptoError.missingServerName, "null name must be rejected");
    // A failed init leaves the session unusable and leak free (cleanup ran).
    assert(s.stepHandshake() != QuicCryptoError.none);

    // A valid name still succeeds
    assert(s.init(verifying, Side.client, params, "h3", "localhost") == QuicCryptoError.none);

    // Insecure contexts keep working without a name (unit-test / loopback use only)
    TlsContext insecure = TlsContext.createClientInsecure();
    assert(!insecure.verifiesPeer);
    TlsSession t;
    assert(t.init(insecure, Side.client, params, "h3", "") == QuicCryptoError.none);

    // Servers never need a name
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsSession srv;
    assert(srv.init(serverCtx, Side.server, params) == QuicCryptoError.none);
}

/// Example:
/// ---
/// TlsContext serverCtx;
/// createIpFixtureServer(serverCtx);
/// TlsContext ctx;
/// createIpFixtureClient(ctx);
/// const ubyte[4] sParams = [1, 2, 3, 4];
/// const ubyte[4] cParams = [5, 6, 7, 8];
/// TlsSession server, client;
/// assert(server.init(serverCtx, Side.server, sParams) == QuicCryptoError.none);
/// assert(client.init(ctx, Side.client, cParams, "h3", "127.0.0.1") == QuicCryptoError.none);   // IP SAN match
/// ubyte[2048] hello;
/// size_t helloLen;
/// assert(runHandshakeExchange(client, server, hello[], helloLen) == QuicCryptoError.none);
/// assert(client.isHandshakeComplete);
/// assert(!containsBytes(hello[0 .. helloLen], "127.0.0.1"));   // an IP literal is not sent as SNI
/// ---
// Spec: RFC 6066 Section 3 ("Literal IPv4 and IPv6 addresses are not permitted in HostName", so
// no SNI is sent) and RFC 6125 Section 6.4.4 / RFC 9110 Section 4.3.4 (an IP-address identity is
// matched against iPAddress subjectAltName entries only) (R-06, E3, D2)
@nogc unittest
{
    const ubyte[4] sParams = [1, 2, 3, 4];
    const ubyte[4] cParams = [5, 6, 7, 8];
    TlsContext serverCtx;
    createIpFixtureServer(serverCtx);
    assert(serverCtx.isValid);

    // (a) IPv4 literal matches the IP SAN; the name must not appear in the ClientHello (no SNI)
    {
        TlsContext ctx;
        createIpFixtureClient(ctx);
        assert(ctx.isValid);
        TlsSession server;
        assert(server.init(serverCtx, Side.server, sParams) == QuicCryptoError.none);
        TlsSession client;
        assert(client.init(ctx, Side.client, cParams, "h3", "127.0.0.1") == QuicCryptoError.none);
        ubyte[2048] hello;
        size_t helloLen;
        assert(runHandshakeExchange(client, server, hello[], helloLen) == QuicCryptoError.none);
        assert(client.isHandshakeComplete, "IP literal must verify against the IP SAN");
        assert(!containsBytes(hello[0 .. helloLen], "127.0.0.1"),
                "IP literal must not be sent as SNI");
    }

    // (b) bracketed IPv6 literal matches the IPv6 SAN
    {
        TlsContext ctx;
        createIpFixtureClient(ctx);
        TlsSession server;
        assert(server.init(serverCtx, Side.server, sParams) == QuicCryptoError.none);
        TlsSession client;
        assert(client.init(ctx, Side.client, cParams, "h3", "[::1]") == QuicCryptoError.none);
        ubyte[2048] hello;
        size_t helloLen;
        assert(runHandshakeExchange(client, server, hello[], helloLen) == QuicCryptoError.none);
        assert(client.isHandshakeComplete);
        assert(!containsBytes(hello[0 .. helloLen], "::1"));
    }

    // (c) an IP that is not in the certificate is rejected
    {
        TlsContext ctx;
        createIpFixtureClient(ctx);
        TlsSession server;
        assert(server.init(serverCtx, Side.server, sParams) == QuicCryptoError.none);
        TlsSession client;
        assert(client.init(ctx, Side.client, cParams, "h3", "192.0.2.1") == QuicCryptoError.none);
        ubyte[2048] hello;
        size_t helloLen;
        assert(runHandshakeExchange(client, server, hello[], helloLen) != QuicCryptoError.none,
                "an IP absent from the SANs must fail verification");
        assert(!client.isHandshakeComplete);
    }

    // (d) DNS names still travel as SNI
    {
        TlsContext ctx;
        createIpFixtureClient(ctx);
        TlsSession server;
        assert(server.init(serverCtx, Side.server, sParams) == QuicCryptoError.none);
        TlsSession client;
        assert(client.init(ctx, Side.client, cParams, "h3", "localhost") == QuicCryptoError.none);
        ubyte[2048] hello;
        size_t helloLen;
        assert(runHandshakeExchange(client, server, hello[], helloLen) == QuicCryptoError.none);
        assert(containsBytes(hello[0 .. helloLen], "localhost"), "DNS name must be sent as SNI");
    }
}

/// Example:
/// ---
/// const(char)[] host;
/// assert(validateServerName("[::1]", host) == QuicCryptoError.none && host == "::1");
/// assert(validateServerName("[]", host) == QuicCryptoError.invalidServerName);
/// assert(validateServerName("a\0b", host) == QuicCryptoError.invalidServerName);
/// ---
// Spec: RFC 6066 Section 3 (HostName is a non-empty ASCII DNS name, no control characters) and
// RFC 6125 Section 6 - a malformed identity must fail initialisation for verifying and
// insecure clients alike, never be truncated at a NUL or silently skipped (Sec L-1/L-2,
// Reviewer L5)
@nogc unittest
{
    const ubyte[4] params = [1, 2, 3, 4];
    TlsContext verifying = TlsContext.createClient();
    TlsContext insecure = TlsContext.createClientInsecure();
    assert(verifying.isValid && insecure.isValid);

    char[256] longName = 'a';
    const(char)[][6] bad = [
        "a\0b.example", "good.example\0evil.example", "tab\there",
        "del\x7f.example", "[]", longName[]
    ];
    foreach (name; bad)
    {
        TlsSession v;
        assert(v.init(verifying, Side.client, params, "h3",
                name) == QuicCryptoError.invalidServerName,
                "verifying client must reject a malformed name");
        TlsSession i;
        assert(i.init(insecure, Side.client, params, "h3", name) == QuicCryptoError.invalidServerName,
                "insecure client must reject a malformed name, not ignore it");
        // Failed init leaves nothing behind
        assert(v.stepHandshake() != QuicCryptoError.none);
    }

    // The boundary: 255 bytes is accepted, 256 is not.
    TlsSession ok;
    assert(ok.init(insecure, Side.client, params, "h3", longName[0 .. 255]) == QuicCryptoError.none);

    // Pure helper: brackets stripped, empty means "no name" (policy is the caller's).
    const(char)[] host;
    assert(validateServerName("[::1]", host) == QuicCryptoError.none && host == "::1");
    assert(validateServerName("", host) == QuicCryptoError.none && host.length == 0);
    assert(validateServerName("example.test", host) == QuicCryptoError.none && host == "example.test");
    // A server never evaluates the name (only clients send SNI).
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsSession srv;
    assert(srv.init(serverCtx, Side.server, params, "h3", "a\0b") == QuicCryptoError.none);
}

/// Example:
/// ---
/// const(char)[] host;
/// assert(validateServerName(".example.com", host) == QuicCryptoError.invalidServerName);
/// assert(validateServerName("a..b", host) == QuicCryptoError.invalidServerName);
/// assert(validateServerName("example.com.", host) == QuicCryptoError.invalidServerName);
/// assert(validateServerName("[example.com]", host) == QuicCryptoError.invalidServerName);
/// ---
// Spec: RFC 6066 Section 3 (HostName without trailing dot) and RFC 6125 Section 6 - a name with
// an empty label (leading '.', "..", trailing '.') or a space is malformed; OpenSSL would
// treat a leading '.' as an any-subdomain match. Brackets are only valid around IP literals
// (RFC 3986 Section 3.2.2). (Round 2 item 4)
@nogc unittest
{
    const ubyte[4] params = [1, 2, 3, 4];
    TlsContext verifying = TlsContext.createClient();
    TlsContext insecure = TlsContext.createClientInsecure();
    assert(verifying.isValid && insecure.isValid);

    const(char)[][10] bad = [
        ".example.com", ".", "..", "a..b.example", "example.com.", "example.com..",
        "exa mple.com", " example.com", "[example.com]", "[a..b]"
    ];
    foreach (name; bad)
    {
        TlsSession v;
        assert(v.init(verifying, Side.client, params, "h3",
                name) == QuicCryptoError.invalidServerName);
        TlsSession i;
        assert(i.init(insecure, Side.client, params, "h3",
                name) == QuicCryptoError.invalidServerName);
    }

    const(char)[] host;
    foreach (good; [
        "example.com", "a.b.c.example", "localhost", "127.0.0.1", "[::1]",
        "[2001:db8::1]", "2001:db8::1", "xn--bcher-kva.example", "a-b.example"
    ])
    {
        assert(validateServerName(good, host) == QuicCryptoError.none, good);
    }
}

/// Example:
/// ---
/// TlsSessionState st;
/// st.writeLevel = EncryptionLevel.initial;
/// ubyte[5000] flight;
/// size_t consumed;
/// assert(st.onCryptoSend(flight.ptr, 3000, &consumed) == 1 && consumed == 3000);
/// assert(st.onCryptoSend(flight.ptr, 2000, &consumed) == 0 && consumed == 0);   // 1096 bytes free
/// ---
// Spec: RFC 9001 Section 4.1.3 - TLS handshake data is passed to QUIC as CRYPTO data in full; a
// buffer that cannot take a whole TLS flight fails the callback without storing a partial
// copy (R-29, W12)
unittest
{
    TlsSessionState st;
    st.writeLevel = EncryptionLevel.initial;
    ubyte[5000] flight;
    foreach (i, ref b; flight)
        b = cast(ubyte) i;
    size_t consumed = 99;

    assert(st.onCryptoSend(flight.ptr, 3000, &consumed) == 1);
    assert(consumed == 3000 && st.outInitialLen == 3000);

    // 1096 bytes are free, 2000 are offered: nothing is stored and the callback fails.
    assert(st.onCryptoSend(flight.ptr, 2000, &consumed) == 0);
    assert(consumed == 0 && st.outInitialLen == 3000);
    assert(st.outInitial[0 .. 3000] == flight[0 .. 3000]);

    // What does fit is still accepted whole, up to the exact capacity.
    assert(st.onCryptoSend(flight.ptr, st.outInitial.length - 3000, &consumed) == 1);
    assert(consumed == st.outInitial.length - 3000 && st.outInitialLen == st.outInitial.length);
    assert(st.onCryptoSend(flight.ptr, 1, &consumed) == 0 && consumed == 0);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[4] params = [1, 2, 3, 4];
/// TlsSession server, client;
/// assert(server.init(serverCtx, Side.server, params) == QuicCryptoError.none);
/// assert(client.init(clientCtx, Side.client, params, "h3", "localhost") == QuicCryptoError.none);
/// assert(client.stepHandshake() == QuicCryptoError.none);
/// const cHello = client.getOutput(EncryptionLevel.initial);
/// assert(server.provideCryptoData(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
/// const sInit = server.getOutput(EncryptionLevel.initial);
/// assert(client.provideCryptoData(EncryptionLevel.initial, sInit) == QuicCryptoError.none);
///
/// // The server certificate arrives in pieces; a partial flight is not an error for an insecure client.
/// const sHs = server.getOutput(EncryptionLevel.handshake);
/// assert(client.provideCryptoData(EncryptionLevel.handshake, sHs[0 .. $ - 40]) == QuicCryptoError.none);
/// ---
// Spec: RFC 9001 Section 4.4 - certificate validation is the TLS stack's policy; a context that
// does not verify peers must not fail a handshake step because of a recorded chain error, while
// a verifying context still does (R-20, E6)
unittest
{
    foreach (verifying; [false, true])
    {
        TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
        TlsContext clientCtx = verifying ? TlsContext.createClient() : TlsContext.createClientInsecure();
        const ubyte[4] params = [1, 2, 3, 4];
        TlsSession server;
        TlsSession client;
        assert(server.init(serverCtx, Side.server, params) == QuicCryptoError.none);
        assert(client.init(clientCtx, Side.client, params, "h3",
                "localhost") == QuicCryptoError.none);
        assert(client.stepHandshake() == QuicCryptoError.none);
        const cHello = client.getOutput(EncryptionLevel.initial);
        assert(server.provideCryptoData(EncryptionLevel.initial, cHello) == QuicCryptoError.none);
        const sInit = server.getOutput(EncryptionLevel.initial);
        const sHs = server.getOutput(EncryptionLevel.handshake);
        assert(sHs.length > 100);
        assert(client.provideCryptoData(EncryptionLevel.initial, sInit) == QuicCryptoError.none);
        // Everything but the tail of the flight (Finished): the handshake is still in progress.
        const err = client.provideCryptoData(EncryptionLevel.handshake, sHs[0 .. $ - 40]);
        if (verifying)
            assert(err == QuicCryptoError.handshakeFailed,
                    "an untrusted chain fails a verifying client");
        else
            assert(err == QuicCryptoError.none, "an insecure client keeps going");
    }
}

/// Example:
/// ---
/// const(char)[] host;
/// assert(validateServerName("xn--bcher-kva.example", host) == QuicCryptoError.none);
/// assert(validateServerName("*.example.com", host) == QuicCryptoError.invalidServerName);
/// ---
// Spec: RFC 5890 Section 2.3.1 - an A-label is the "xn--" ASCII form of an IDN, and RFC 1123
// Section 2.1 limits host name labels to letters, digits and hyphens; a wildcard or raw UTF-8
// is not a host name and must not reach SNI or host matching (PB-6, W11)
@safe @nogc nothrow unittest
{
    const(char)[] host;
    assert(validateServerName("xn--bcher-kva.example", host) == QuicCryptoError.none);
    assert(host == "xn--bcher-kva.example");
    assert(validateServerName("a-b.C0.example", host) == QuicCryptoError.none);
    foreach (bad; [
        "*.example.com", "*", "b\u00fccher.example", "exa_mple.com",
        "a/b.example", "a@b.example", "a%2eb.example"
    ])
        assert(validateServerName(bad, host) == QuicCryptoError.invalidServerName, bad);
}

/// Example:
/// ---
/// TlsSessionState st;
/// st.writeLevel = EncryptionLevel.initial;
/// st.expectedReadLevel = EncryptionLevel.initial;
/// ubyte[64] secret = 0x42;
/// // a 64-byte secret does not fit its slot: the callback fails and the level does not advance
/// assert(st.onYieldSecret(OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE, 1, secret.ptr, 64) == 0);
/// assert(st.writeLevel == EncryptionLevel.initial && !st.hsWriteSec.valid);
/// ---
// Spec: RFC 9001 Section 5.1 "The current encryption level secret and the label "quic key" are
// input to the KDF to produce the AEAD key" (keys derive from the yielded traffic secret) - a secret that does not fit its slot must fail
// the callback and leave the level unadvanced, instead of moving to a level without keys
// (R-33, W14)
unittest
{
    TlsSessionState st;
    st.writeLevel = EncryptionLevel.initial;
    st.expectedReadLevel = EncryptionLevel.initial;
    ubyte[64] secret = 0x42;

    assert(st.onYieldSecret(OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE, 1, secret.ptr, 64) == 0);
    assert(st.writeLevel == EncryptionLevel.initial, "level must not advance without keys");
    assert(!st.hsWriteSec.valid && st.hsWriteSec.len == 0);
    assert(st.secretOverflow);
    assert(st.paramFailure() == QuicCryptoError.internalError);
    assert(st.hasAlert && st.alertCode == 80);

    // A secret that fits (48 bytes, SHA-384) is stored and advances the level.
    TlsSessionState ok;
    ok.writeLevel = EncryptionLevel.initial;
    assert(ok.onYieldSecret(OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE, 0, secret.ptr, 48) == 1);
    assert(ok.hsReadSec.valid && ok.hsReadSec.len == 48);
    assert(ok.expectedReadLevel == EncryptionLevel.handshake);
    assert(ok.paramFailure() == QuicCryptoError.none);
}

/// Example:
/// ---
/// TlsSessionState st;
/// ubyte[2049] big = 0x07;
/// // the peer's transport parameters are one byte over the 2048-byte limit
/// assert(st.onGotTransportParams(big.ptr, 2049) == 0);      // callback failed during the handshake
/// assert(st.paramFailure() == QuicCryptoError.transportParamsTooLarge);
/// ---
// Spec: RFC 9000 Section 7.4 "An endpoint MUST treat receipt of a transport parameter with an
// invalid value as a connection error of type TRANSPORT_PARAMETER_ERROR." and RFC 8446 Section
// 6.2 (illegal_parameter) - the transport parameter overflow recorded by the TLS callback must be
// reported after SSL_do_handshake too, not only before the next step (R-34, W15)
unittest
{
    TlsSessionState st;
    ubyte[2049] big = 0x07;
    assert(st.onGotTransportParams(big.ptr, big.length) == 0);
    assert(st.peerParamsLen == 0, "nothing is stored on overflow");
    assert(st.paramFailure() == QuicCryptoError.transportParamsTooLarge);
    assert(st.hasAlert && st.alertCode == 47);

    TlsSessionState fits;
    assert(fits.onGotTransportParams(big.ptr, 2048) == 1 && fits.peerParamsLen == 2048);
    assert(fits.paramFailure() == QuicCryptoError.none);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ubyte[1800] clientParams, serverParams;
/// foreach (i, ref b; clientParams)
///     b = cast(ubyte)(i * 7 + 1);
/// foreach (i, ref b; serverParams)
///     b = cast(ubyte)(i * 11 + 3);
///
/// TlsSession server, client;
/// assert(server.init(serverCtx, Side.server, serverParams[]) == QuicCryptoError.none);
/// assert(client.init(clientCtx, Side.client, clientParams[]) == QuicCryptoError.none);
/// assert(client.stepHandshake() == QuicCryptoError.none);
/// ubyte[4096] chBuf;
/// const hello = client.writeHandshake(EncryptionLevel.initial, chBuf);
/// assert(server.readHandshake(EncryptionLevel.initial, hello) == QuicCryptoError.none);
/// assert(server.peerTransportParams == clientParams[]);   // 1800 bytes arrive intact
///
/// ubyte[2049] tooBig;
/// TlsSession refused;
/// assert(refused.init(clientCtx, Side.client, tooBig[]) == QuicCryptoError.transportParamsTooLarge);
/// ---
// Spec: RFC 9000 Section 18 "transport_parameters ... extension_data" and the 2048-byte local
// limit (F-34): transport parameters far above 512 bytes complete the handshake and arrive
// whole; local parameters above the limit are refused at init (R-45, W28)
unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    ubyte[1800] clientParams, serverParams;
    foreach (i, ref b; clientParams)
        b = cast(ubyte)(i * 7 + 1);
    foreach (i, ref b; serverParams)
        b = cast(ubyte)(i * 11 + 3);

    TlsSession server, client;
    assert(server.init(serverCtx, Side.server, serverParams[]) == QuicCryptoError.none);
    assert(client.init(clientCtx, Side.client, clientParams[]) == QuicCryptoError.none);
    assert(client.stepHandshake() == QuicCryptoError.none);
    ubyte[4096] chBuf;
    const hello = client.writeHandshake(EncryptionLevel.initial, chBuf);
    assert(hello.length > 1800);
    assert(server.readHandshake(EncryptionLevel.initial, hello) == QuicCryptoError.none);
    assert(server.peerTransportParams == clientParams[]);

    ubyte[8192] sInit, sHs;
    const si = server.writeHandshake(EncryptionLevel.initial, sInit);
    const sh = server.writeHandshake(EncryptionLevel.handshake, sHs);
    assert(client.readHandshake(EncryptionLevel.initial, si) == QuicCryptoError.none);
    assert(client.readHandshake(EncryptionLevel.handshake, sh) == QuicCryptoError.none);
    assert(client.isHandshakeComplete);
    assert(client.peerTransportParams == serverParams[]);

    ubyte[2049] tooBig;
    TlsSession refused;
    assert(refused.init(clientCtx, Side.client, tooBig[]) == QuicCryptoError
            .transportParamsTooLarge);
}
