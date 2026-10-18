module slate.quic.crypto.tls_session_test;

import slate.quic.crypto.tls_session;
import slate.quic.crypto.c_openssl;
import slate.quic.crypto.kdf;
import slate.quic.crypto.aead;
import slate.quic.crypto.header_protection;
import slate.quic.crypto.packet_keys;

/// Example:
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
        client.init(clientCtx, Side.client, cParams);

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
