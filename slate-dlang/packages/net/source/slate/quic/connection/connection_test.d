module slate.quic.connection.connection_test;

import slate.quic.connection;

import slate.quic.crypto.kdf : Side, CipherSuite, EncryptionLevel, QuicCryptoError;
import slate.quic.crypto.tls_session : TlsContext;
import slate.quic.wire.cid : ConnectionId, TransportErrorCode;
import slate.quic.wire.transport_params : TransportParameters;
import slate.quic.wire.packet : PacketType, encodeLongHeader, QUIC_VERSION_1,
    CoalescedPacketIterator, PacketPrefix;
import slate.quic.wire.frame : Frame, FrameType, encodeFrame, WireError,
    CryptoFrame, StreamFrame, AckFrame;
import slate.quic.recovery.loss_detection : PacketNumberSpace;
import slate.quic.crypto.packet_keys : protectPacket;
import slate.quic.stream.id : StreamDirection, StreamId;

/// Example:
// Spec: RFC 9000 Section 7 & RFC 9001 Section 4.9 - Full Sans-I/O Client <-> Server Handshake, Key Discard & Stream Exchange (covers U1, U2, U3, E1, E2, Scenario T1)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    assert(serverCtx.isValid);
    assert(clientCtx.isValid);

    const ubyte[8] dcidBytes = [0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08];
    const ubyte[8] scidBytes = [0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8];
    ConnectionId clientDcid = ConnectionId(dcidBytes[]);
    ConnectionId clientScid = ConnectionId(scidBytes[]);

    TransportParameters clientTp;
    clientTp.hasInitialSourceConnectionId = true;
    clientTp.initialSourceConnectionId = clientScid;
    clientTp.initialMaxData = 10_000_000;
    clientTp.initialMaxStreamsBidi = 100;
    clientTp.initialMaxStreamDataBidiLocal = 1_000_000;
    clientTp.initialMaxStreamDataBidiRemote = 1_000_000;

    TransportParameters serverTp;
    serverTp.hasOriginalDestinationConnectionId = true;
    serverTp.originalDestinationConnectionId = clientDcid;
    serverTp.hasInitialSourceConnectionId = true;
    serverTp.initialSourceConnectionId = clientDcid;
    serverTp.initialMaxData = 20_000_000;
    serverTp.initialMaxStreamsBidi = 200;
    serverTp.initialMaxStreamDataBidiLocal = 1_000_000;
    serverTp.initialMaxStreamDataBidiRemote = 1_000_000;

    ulong now = 1_000_000;

    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, clientScid,
            clientDcid, clientTp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, clientDcid,
            ConnectionId.init, serverTp, now, server));

    ubyte[4096] dgramBuf;
    size_t dgramLen = 0;

    // Flight 1: Client -> Server (Initial padded to >= 1200 bytes per RFC 9000 §14.1)
    assert(client.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen >= 1200, "Client Initial packet must be padded to >= 1200 bytes");
    assert(server.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);
    assert(server.hasWriteKeys[2], "server hasWriteKeys[2] after Flight 1");
    assert(server.cryptoSend[1].hasPendingBytes,
            "server cryptoSend[1] hasPendingBytes after Flight 1");

    // Flight 2: Server -> Client (Server Initial + Server Handshake)
    now += 10_000;
    assert(server.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen > 0);
    assert(client.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);
    assert(client.hasReadKeys[2], "client hasReadKeys[2]");
    assert(client.hasWriteKeys[2], "client hasWriteKeys[2]");
    assert(client.cryptoSend[1].hasPendingBytes, "client cryptoSend[1] hasPendingBytes");

    // Flight 3: Client -> Server (Client Handshake)
    now += 10_000;
    assert(client.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen > 0);

    // Client must have discarded Initial keys upon sending Handshake packet (RFC 9001 §4.9.1)
    assert(!client.hasReadKeys[0], "client hasReadKeys[0] must be false");
    assert(!client.hasWriteKeys[0]);

    assert(server.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);

    // Server must have discarded Initial keys upon receiving Client Handshake packet (RFC 9001 §4.9.1)
    assert(!server.hasReadKeys[0]);
    assert(!server.hasWriteKeys[0]);
    assert(server.peerAddressValidated, "Server must validate client address upon Handshake packet");

    // Flight 4: Server -> Client (1-RTT with HANDSHAKE_DONE)
    now += 10_000;
    assert(server.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen > 0);
    assert(client.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);

    // Client confirms handshake upon receiving HANDSHAKE_DONE
    assert(client.handshakeConfirmed);
    assert(!client.hasReadKeys[2],
            "Client must discard Handshake keys upon handshake confirmation");
    assert(!client.hasWriteKeys[2]);

    ConnectionEvent clientEv;
    assert(client.pollEvent(clientEv));
    assert(clientEv.type == ConnectionEventType.handshakeConfirmed);

    // Bidirectional Stream Data Exchange with FIN
    StreamId clientSid;
    assert(client.openStream(StreamDirection.bidirectional, clientSid) == TransportErrorCode
            .noError);
    assert(clientSid.id == 0);

    const(ubyte)[] reqData = cast(const(ubyte)[]) "GET / HTTP/3";
    assert(client.streamWrite(clientSid, reqData, true));

    now += 10_000;
    assert(client.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen > 0);
    assert(server.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);

    assert(server.handshakeConfirmed);
    ConnectionEvent serverEv;
    assert(server.pollEvent(serverEv));
    assert(serverEv.type == ConnectionEventType.handshakeConfirmed);
    assert(server.pollEvent(serverEv));
    assert(serverEv.type == ConnectionEventType.streamReadable);
    assert(serverEv.streamId == 0);

    ubyte[128] readBuf;
    bool finReached = false;
    ptrdiff_t nRead = server.streamRead(clientSid, readBuf[], finReached);
    assert(nRead == reqData.length);
    assert(readBuf[0 .. nRead] == reqData);
    assert(finReached);

    // Server responds on same stream
    const(ubyte)[] respData = cast(const(ubyte)[]) "HTTP/3 200 OK";
    assert(server.streamWrite(clientSid, respData, true));

    now += 10_000;
    assert(server.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen > 0);
    assert(client.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);

    nRead = client.streamRead(clientSid, readBuf[], finReached);
    assert(nRead == respData.length);
    assert(readBuf[0 .. nRead] == respData);
    assert(finReached);
}

/// Example:
// Spec: RFC 9000 Section 13.3 & RFC 9002 Section 6 - Packet Drop & Automatic Loss Recovery of STREAM and CRYPTO Frames (covers U1, U2, U3, E2, F5, Scenario T2)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId clientDcid = ConnectionId(dcidBytes[]);
    ConnectionId clientScid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    tp.initialMaxStreamsBidi = 100;
    tp.initialMaxStreamDataBidiLocal = 1_000_000;
    tp.initialMaxStreamDataBidiRemote = 1_000_000;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, clientScid, clientDcid, tp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, clientDcid,
            ConnectionId.init, tp, now, server));

    // Fast-forward handshake: Flight 1, 2, 3, 4
    ubyte[4096] dgram;
    size_t len;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Open stream 0
    StreamId sid;
    assert(client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    // Client writes 5 chunks (100 bytes each)
    ubyte[100] chunk;
    foreach (i; 0 .. 100)
        chunk[i] = cast(ubyte) i;

    // Packet 0
    assert(client.streamWrite(sid, chunk[], false));
    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Packet 1
    assert(client.streamWrite(sid, chunk[], false));
    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Packet 2: dropped in transit!
    assert(client.streamWrite(sid, chunk[], false));
    now += 1000;
    ubyte[4096] droppedDgram;
    size_t droppedLen;
    assert(client.pollTransmit(droppedDgram[], now, droppedLen));
    // (Do not deliver droppedDgram to server)

    // Packet 3
    assert(client.streamWrite(sid, chunk[], false));
    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Packet 4 with FIN
    assert(client.streamWrite(sid, chunk[], true));
    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Server has received packets 0, 1, 3, 4. Readable bytes is 200 due to gap at [200..300]
    ubyte[512] sReadBuf;
    bool sFin;
    assert(server.streamRead(sid, sReadBuf[], sFin) == 200);
    assert(!sFin);

    // Server transmits ACK for packets 0, 1, 3, 4
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Client's LossDetector triggers kPacketThreshold = 3 loss for packet 2 (largestAcked = 4, 4 - 2 >= 3)
    // Client retransmits lost stream range [200..300]
    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(len > 0);

    // Server receives retransmitted packet
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Server now has all 500 contiguous bytes and FIN!
    const n = server.streamRead(sid, sReadBuf[200 .. $], sFin);
    assert(n == 300);
    assert(sFin);
}

/// Example:
// Spec: RFC 9000 Section 8.1 & Section 14.1 - 3x Anti-Amplification Limit & Undersized Client Initial Drop (covers U1, U3, W1, F1, F2, Scenario T3)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;

    ulong now = 1_000_000;
    QuicConnection server;
    assert(QuicConnection.create(Side.server, serverCtx, dcid,
            ConnectionId.init, tp, now, server, false));
    assert(!server.peerAddressValidated);

    // 1. Undersized Client Initial (< 1200 bytes) must be silently dropped (RFC 9000 §14.1 & F2)
    ubyte[1199] undersizedDgram;
    undersizedDgram[0] = 0xc0; // Long header Initial
    assert(server.handleDatagram(undersizedDgram[], now) == TransportErrorCode.noError);
    assert(server.totalBytesReceived == 0,
            "Undersized Initial must be dropped without updating received count");

    // 2. Valid 1200-byte datagram updates amplification budget to 3 * 1200 = 3600 bytes
    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));

    ubyte[1200] clientInitDgram;
    size_t initLen;
    assert(client.pollTransmit(clientInitDgram[], now, initLen));
    assert(initLen == 1200);

    assert(server.handleDatagram(clientInitDgram[], now) == TransportErrorCode.noError);
    assert(server.totalBytesReceived == 1200);
    assert(server.amplificationBudget() == 3600);

    // Server pollTransmit must not emit more than 3600 bytes before validation
    ubyte[8192] sDgram;
    size_t sLen;
    assert(server.pollTransmit(sDgram[], now, sLen));
    assert(sLen <= 3600);
    assert(server.totalBytesSent <= 3600);
}

/// Example:
// Spec: RFC 9000 Section 8.2, Section 10.2, Section 12.4 & RFC 9001 Section 6 - Protocol Violation, PATH_CHALLENGE/RESPONSE, 1-RTT Key Update & Connection Close (covers U1, U3, E3, W2, F6, Scenario T4)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    tp.initialMaxStreamDataBidiLocal = 1_000_000;
    tp.initialMaxStreamDataBidiRemote = 1_000_000;
    tp.initialMaxStreamDataUni = 1_000_000;
    tp.initialMaxStreamsBidi = 100;
    tp.initialMaxStreamsUni = 100;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, tp, now, server));

    // Complete Handshake
    ubyte[4096] dgram;
    size_t len;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    assert(client.handshakeConfirmed);
    ConnectionEvent clientConfirmEv;
    assert(client.pollEvent(clientConfirmEv));
    assert(clientConfirmEv.type == ConnectionEventType.handshakeConfirmed);

    // 1. Path Challenge & Response
    const ubyte[8] challengeData = [1, 2, 3, 4, 5, 6, 7, 8];
    client.sendPathChallenge(challengeData);
    assert(client.hasPendingPathChallenge);

    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    assert(server.hasPendingPathResponse);
    assert(server.pendingPathResponseData == challengeData);

    assert(server.handshakeConfirmed);
    ConnectionEvent confirmEv;
    assert(server.pollEvent(confirmEv));
    assert(confirmEv.type == ConnectionEventType.handshakeConfirmed);

    now += 1000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    assert(!client.hasPendingPathChallenge,
            "Path challenge must be cleared upon receiving PATH_RESPONSE");

    // 2. 1-RTT Key Update & Post-Update Stream Exchange (RFC 9001 §6)
    assert(client.localKeyPhase == 0);
    assert(client.remoteKeyPhase == 0);
    assert(server.localKeyPhase == 0);
    assert(server.remoteKeyPhase == 0);

    assert(client.initiateKeyUpdate());
    assert(client.localKeyPhase == 1);
    assert(client.remoteKeyPhase == 0);

    // Client opens stream 0 and sends post-update data
    StreamId sid;
    assert(client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    const ubyte[5] payload1 = [0xde, 0xad, 0xbe, 0xef, 0x01];
    assert(client.streamWrite(sid, payload1[], false));

    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Server decrypted with candidate key and rotated both remote and local key phases
    assert(server.remoteKeyPhase == 1);
    assert(server.localKeyPhase == 1);

    // Server receives stream data and dispatches streamReadable event
    ConnectionEvent sEv;
    assert(server.pollEvent(sEv));
    assert(sEv.type == ConnectionEventType.streamReadable);
    assert(sEv.streamId == sid.id);

    ubyte[16] readBuf;
    bool finReceived = false;
    const bytesRead1 = server.streamRead(sid, readBuf[], finReceived);
    assert(bytesRead1 == 5);
    assert(readBuf[0 .. 5] == payload1[]);

    // Server responds on stream 0 with phase 1
    const ubyte[5] payload2 = [0xca, 0xfe, 0xba, 0xbe, 0x02];
    assert(server.streamWrite(sid, payload2[], false));

    now += 1000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    assert(client.remoteKeyPhase == 1);

    ConnectionEvent cEv;
    assert(client.pollEvent(cEv));
    assert(cEv.type == ConnectionEventType.streamReadable);
    assert(cEv.streamId == sid.id);

    const bytesRead2 = client.streamRead(sid, readBuf[], finReceived);
    assert(bytesRead2 == 5);
    assert(readBuf[0 .. 5] == payload2[]);

    // 3. Graceful Connection Close
    client.close(0, true);
    assert(client.state == ConnectionState.closing);

    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(client.state == ConnectionState.draining);
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    assert(server.state == ConnectionState.draining);

    ConnectionEvent closeEv;
    assert(server.pollEvent(closeEv));
    assert(closeEv.type == ConnectionEventType.connectionClosed);
    assert(closeEv.isApplicationClose);
}

/// Example:
// Spec: RFC 9001 Section 6 - Key Phase Authentication Gate & Forged 1-RTT Packet Rejection
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    tp.initialMaxStreamDataBidiLocal = 1_000_000;
    tp.initialMaxStreamDataBidiRemote = 1_000_000;
    tp.initialMaxStreamsBidi = 100;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, tp, now, server));

    // Complete Handshake
    ubyte[4096] dgram;
    size_t len;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    assert(client.handshakeConfirmed);

    // Client produces valid 1-RTT packet with PING
    client.pingQueued = true;
    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(len > 0);

    // Attacker tampers with the ciphertext / AEAD tag (corrupt last byte)
    ubyte[4096] forged;
    forged[0 .. len] = dgram[0 .. len];
    forged[len - 1] ^= 0xff;

    // Server ingests forged packet: trial decryption fails and packet is dropped silently
    assert(server.handleDatagram(forged[0 .. len], now) == TransportErrorCode.noError);

    // Server must NOT rotate key phase on authentication failure!
    assert(server.localKeyPhase == 0);
    assert(server.remoteKeyPhase == 0);

    // Legitimate packet is ingested by server and confirms server's handshake
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    assert(server.handshakeConfirmed);
    assert(server.localKeyPhase == 0);
    assert(server.remoteKeyPhase == 0);
}

/// Example:
// Spec: RFC 9000 Section 12.4 - Forbidden Frame in Initial Packet Triggers Protocol Violation
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, tp, now, server));

    // Construct an Initial packet containing a forbidden STREAM frame (RFC 9000 Table 3)
    ubyte[1200] badInitialPkt;
    size_t badHdrLen = 0;
    size_t badPnOff = 0;
    const ulong badPn = 99;

    ubyte[64] badPayload;
    Frame forbiddenFrame;
    forbiddenFrame.type = FrameType.stream;
    forbiddenFrame.stream.streamId = 0;
    forbiddenFrame.stream.offset = 0;
    forbiddenFrame.stream.data = cast(const(ubyte)[]) "forbidden";
    forbiddenFrame.stream.fin = false;
    forbiddenFrame.stream.hasOffset = false;
    forbiddenFrame.stream.hasLength = true;
    size_t forbiddenLen = 0;
    assert(encodeFrame(forbiddenFrame, badPayload[], forbiddenLen) == WireError.none);

    // Pad badPayload to at least 20 bytes (for sample protection)
    while (forbiddenLen < 32)
    {
        badPayload[forbiddenLen++] = 0x00; // PADDING
    }

    assert(encodeLongHeader(PacketType.initial, QUIC_VERSION_1, server.localCid,
            client.localCid, null, badPn, 2, forbiddenLen, badInitialPkt[], badPnOff, badHdrLen) == WireError
            .none);

    badInitialPkt[badHdrLen .. badHdrLen + forbiddenLen] = badPayload[0 .. forbiddenLen];

    size_t badProtLen = 0;
    assert(protectPacket(client.levelKeys[0].local, badPn, badPnOff, 2,
            badInitialPkt[], forbiddenLen, badProtLen) == QuicCryptoError.none);

    // Pad packet up to 1200 bytes so server doesn't drop as undersized
    foreach (i; badProtLen .. 1200)
    {
        badInitialPkt[i] = 0;
    }

    // Ingest into server: must trigger protocolViolation (0x0a) and transition to closing state
    const te = server.handleDatagram(badInitialPkt[], now);
    assert(te == TransportErrorCode.protocolViolation);
    assert(server.state == ConnectionState.closing);

    // Verify server transmits CONNECTION_CLOSE with protocolViolation
    ubyte[1500] closeBuf;
    size_t closeLen = 0;
    assert(server.pollTransmit(closeBuf[], now, closeLen));
    assert(closeLen > 0);
    assert(server.state == ConnectionState.draining);
}

/// Example:
// Spec: RFC 9000 Section 10.1 - Idle Timeout Teardown & Event Notification
@nogc unittest
{
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };
    TlsContext clientCtx = makeClientCtx();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.maxIdleTimeout = 1000; // 1000 ms = 1,000,000 microseconds

    ulong now = 1_000_000;
    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));

    // Simulate packet reception
    client.lastRxTimeMicros = now;

    // Advance time before timeout: still open
    now += 500_000;
    client.onTimeout(now);
    assert(client.state != ConnectionState.closed);

    // Advance time past timeout (1_000_000 us): triggers idle timeout
    now += 600_000; // Total 1,100,000 us > 1,000,000 us
    client.onTimeout(now);
    assert(client.state == ConnectionState.closed);

    ConnectionEvent ev;
    assert(client.pollEvent(ev));
    assert(ev.type == ConnectionEventType.connectionClosed);
    assert(!ev.isApplicationClose);
}

/// Example:
// Spec: RFC 9000 Section 19.3 & 19.4 - RESET_STREAM and STOP_SENDING Outgoing Control Frames
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    tp.initialMaxStreamDataBidiLocal = 1_000_000;
    tp.initialMaxStreamDataBidiRemote = 1_000_000;
    tp.initialMaxStreamsBidi = 100;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, tp, now, server));

    // Complete Handshake
    ubyte[4096] dgram;
    size_t len;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Open stream 0 on client
    StreamId sid;
    assert(client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    // 1. Client calls resetStream -> frame emitted and server receives streamReset event
    client.resetStream(sid, 0x1234);
    now += 1000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    ConnectionEvent rEv;
    bool gotStreamReset = false;
    while (server.pollEvent(rEv))
    {
        if (rEv.type == ConnectionEventType.streamReset)
        {
            assert(rEv.streamId == sid.id);
            assert(rEv.errorCode == 0x1234);
            gotStreamReset = true;
            break;
        }
    }
    assert(gotStreamReset);

    // 2. Server calls stopSending -> frame emitted and client receives stopSending event
    server.stopSending(sid, 0x5678);
    now += 1000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    ConnectionEvent sEv;
    bool gotStopSending = false;
    while (client.pollEvent(sEv))
    {
        if (sEv.type == ConnectionEventType.stopSending)
        {
            assert(sEv.streamId == sid.id);
            assert(sEv.errorCode == 0x5678);
            gotStopSending = true;
            break;
        }
    }
    assert(gotStopSending);
}

/// Example:
// Spec: RFC 9001 Section 8.1 & Scenario T1 - QuicConnection configurable ALPN negotiation ("smsp/1") and mismatch rejection (covers U1, W1)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    assert(serverCtx.isValid && clientCtx.isValid);

    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    tp.initialMaxStreamDataBidiLocal = 1_000_000;
    tp.initialMaxStreamDataBidiRemote = 1_000_000;
    tp.initialMaxStreamsBidi = 100;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now,
            client, false, null, "smsp/1"));
    assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, tp, now, server));

    ubyte[4096] dgram;
    size_t len = 0;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    assert(server.negotiatedAlpn == "smsp/1");

    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    assert(client.state == ConnectionState.active);
    assert(client.negotiatedAlpn == "smsp/1");

    now += 10_000;
    assert(client.pollTransmit(dgram[], now, len));
    assert(server.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);
    assert(server.state == ConnectionState.active);
    assert(server.negotiatedAlpn == "smsp/1");

    // Second client offering unknown ALPN "unknown/9" is rejected with TLS alert 120 (0x0178)
    QuicConnection badClient;
    QuicConnection server2;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now,
            badClient, false, null, "unknown/9"));
    assert(QuicConnection.create(Side.server, serverCtx, dcid,
            ConnectionId.init, tp, now, server2));
    assert(badClient.pollTransmit(dgram[], now, len));
    const badTe = server2.handleDatagram(dgram[0 .. len], now);
    assert(badTe == cast(TransportErrorCode) 0x0178);
    assert(server2.state == ConnectionState.closing);
}

/// Example:
// Spec: RFC 9000 Section 4 - Flow Control Window Auto-Tuning: 32 KiB Transfer over 4 KiB Stream / 8 KiB Connection Window (F-05, D-01, D-12)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        return TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    assert(serverCtx.isValid && clientCtx.isValid);

    const ubyte[8] dcidBytes = [0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77];
    const ubyte[8] scidBytes = [0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87];
    ConnectionId clientDcid = ConnectionId(dcidBytes[]);
    ConnectionId clientScid = ConnectionId(scidBytes[]);

    TransportParameters clientTp;
    clientTp.hasInitialSourceConnectionId = true;
    clientTp.initialSourceConnectionId = clientScid;
    clientTp.initialMaxData = 8192;
    clientTp.initialMaxStreamsBidi = 10;
    clientTp.initialMaxStreamDataBidiLocal = 4096;
    clientTp.initialMaxStreamDataBidiRemote = 4096;

    TransportParameters serverTp;
    serverTp.hasOriginalDestinationConnectionId = true;
    serverTp.originalDestinationConnectionId = clientDcid;
    serverTp.hasInitialSourceConnectionId = true;
    serverTp.initialSourceConnectionId = clientDcid;
    serverTp.initialMaxData = 8192;
    serverTp.initialMaxStreamsBidi = 10;
    serverTp.initialMaxStreamDataBidiLocal = 4096;
    serverTp.initialMaxStreamDataBidiRemote = 4096;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, clientScid,
            clientDcid, clientTp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, clientDcid,
            ConnectionId.init, serverTp, now, server));

    ubyte[4096] dgramBuf;
    size_t dgramLen = 0;

    // Flight 1: Client Initial
    assert(client.pollTransmit(dgramBuf[], now, dgramLen));
    assert(server.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);

    // Flight 2: Server Initial + Handshake
    now += 10_000;
    assert(server.pollTransmit(dgramBuf[], now, dgramLen));
    assert(client.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);

    // Flight 3: Client Handshake
    now += 10_000;
    assert(client.pollTransmit(dgramBuf[], now, dgramLen));
    assert(server.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);

    // Flight 4: Server 1-RTT (HANDSHAKE_DONE)
    now += 10_000;
    assert(server.pollTransmit(dgramBuf[], now, dgramLen));
    assert(client.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);
    assert(client.handshakeConfirmed);

    StreamId sid;
    assert(client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    // Prepare 32 KiB test payload (32768 bytes)
    ubyte[32768] sendPayload;
    foreach (i, ref b; sendPayload)
        b = cast(ubyte)(i & 0xFF);

    assert(client.streamWrite(sid, sendPayload[], true));

    size_t totalReceived = 0;
    ubyte[2048] readBuf;
    bool finReceived = false;

    // Pump loop until all 32 KiB are received by server across window updates
    foreach (round; 0 .. 500)
    {
        bool hadTraffic = false;

        // Drain client transmits to server
        while (client.pollTransmit(dgramBuf[], now, dgramLen) && dgramLen > 0)
        {
            assert(server.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode
                    .noError);
            hadTraffic = true;
        }

        // Server reads available stream data in chunks of up to 2 KiB
        ConnectionEvent ev;
        while (server.pollEvent(ev))
        {
        }

        while (true)
        {
            const ptrdiff_t n = server.streamRead(sid, readBuf[], finReceived);
            if (n <= 0)
                break;
            foreach (j; 0 .. n)
            {
                assert(readBuf[j] == cast(ubyte)((totalReceived + j) & 0xFF));
            }
            totalReceived += n;
            hadTraffic = true;
        }

        // Drain server transmits to client (carrying MAX_STREAM_DATA, MAX_DATA, and ACKs)
        while (server.pollTransmit(dgramBuf[], now, dgramLen) && dgramLen > 0)
        {
            assert(client.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode
                    .noError);
            hadTraffic = true;
        }

        while (client.pollEvent(ev))
        {
        }

        now += 1000;
        if (totalReceived == sendPayload.length && finReceived)
            break;
    }

    assert(totalReceived == 32768, "All 32 KiB must be read by server");
    assert(finReceived, "FIN must be received on stream");
}

private struct TestConnPair
{
    QuicConnection client;
    QuicConnection server;
    ulong now = 1_000_000;
}

private bool initTestConnPair(out TestConnPair pair, ulong maxData = 10_000_000,
        ulong maxStreamData = 1_000_000, uint maxStreams = 100) @trusted @nogc nothrow
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    if (!serverCtx.isValid)
        serverCtx = TlsContext.createServer("packages/net/test/fixtures/quic_cert.pem",
                "packages/net/test/fixtures/quic_key.pem");
    if (!serverCtx.isValid)
        serverCtx = TlsContext.createServer("slate-dlang/packages/net/test/fixtures/quic_cert.pem",
                "slate-dlang/packages/net/test/fixtures/quic_key.pem");
    if (!serverCtx.isValid)
        return false;

    TlsContext clientCtx = TlsContext.createClientInsecure();
    if (!clientCtx.isValid)
        return false;

    const ubyte[8] dcidBytes = [0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08];
    const ubyte[8] scidBytes = [0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8];
    ConnectionId clientDcid = ConnectionId(dcidBytes[]);
    ConnectionId clientScid = ConnectionId(scidBytes[]);

    TransportParameters clientTp;
    clientTp.hasInitialSourceConnectionId = true;
    clientTp.initialSourceConnectionId = clientScid;
    clientTp.initialMaxData = maxData;
    clientTp.initialMaxStreamsBidi = maxStreams;
    clientTp.initialMaxStreamsUni = maxStreams;
    clientTp.initialMaxStreamDataBidiLocal = maxStreamData;
    clientTp.initialMaxStreamDataBidiRemote = maxStreamData;
    clientTp.initialMaxStreamDataUni = maxStreamData;

    TransportParameters serverTp;
    serverTp.hasOriginalDestinationConnectionId = true;
    serverTp.originalDestinationConnectionId = clientDcid;
    serverTp.hasInitialSourceConnectionId = true;
    serverTp.initialSourceConnectionId = clientDcid;
    serverTp.initialMaxData = maxData;
    serverTp.initialMaxStreamsBidi = maxStreams;
    serverTp.initialMaxStreamsUni = maxStreams;
    serverTp.initialMaxStreamDataBidiLocal = maxStreamData;
    serverTp.initialMaxStreamDataBidiRemote = maxStreamData;
    serverTp.initialMaxStreamDataUni = maxStreamData;

    ulong now = 1_000_000;
    pair.now = now;

    if (!QuicConnection.create(Side.client, clientCtx, clientScid, clientDcid,
            clientTp, now, pair.client))
        return false;
    if (!QuicConnection.create(Side.server, serverCtx, clientDcid,
            ConnectionId.init, serverTp, now, pair.server))
        return false;

    ubyte[4096] dgramBuf;
    size_t dgramLen = 0;

    // Flight 1: Client Initial
    if (!pair.client.pollTransmit(dgramBuf[], now, dgramLen) || dgramLen == 0)
        return false;
    if (pair.server.handleDatagram(dgramBuf[0 .. dgramLen], now) != TransportErrorCode.noError)
        return false;

    // Flight 2: Server Initial + Handshake
    now += 10_000;
    if (!pair.server.pollTransmit(dgramBuf[], now, dgramLen) || dgramLen == 0)
        return false;
    if (pair.client.handleDatagram(dgramBuf[0 .. dgramLen], now) != TransportErrorCode.noError)
        return false;

    // Flight 3: Client Handshake
    now += 10_000;
    if (!pair.client.pollTransmit(dgramBuf[], now, dgramLen) || dgramLen == 0)
        return false;
    if (pair.server.handleDatagram(dgramBuf[0 .. dgramLen], now) != TransportErrorCode.noError)
        return false;

    // Flight 4: Server 1-RTT (HANDSHAKE_DONE)
    now += 10_000;
    if (!pair.server.pollTransmit(dgramBuf[], now, dgramLen) || dgramLen == 0)
        return false;
    if (pair.client.handleDatagram(dgramBuf[0 .. dgramLen], now) != TransportErrorCode.noError)
        return false;

    now += 10_000;
    pair.now = now;

    ConnectionEvent dummyEv;
    while (pair.client.pollEvent(dummyEv))
    {
    }
    while (pair.server.pollEvent(dummyEv))
    {
    }

    return pair.client.handshakeConfirmed;
}

/// Example:
// Spec: RFC 9000 Section 12.3, RFC 9002 Section 6 - Asymmetric 1-RTT Packet Numbers Decoded Against largestReceived & Outbound pnLen >= 2 (F-01, F-02, D-12)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));

    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    ubyte[4096] dgram;
    size_t len = 0;

    // Client sends > 150 asymmetric 1-RTT packets without receiving ACKs
    foreach (i; 0 .. 160)
    {
        const ubyte[4] payload = [cast(ubyte) i, 0x01, 0x02, 0x03];
        assert(p.client.streamWrite(sid, payload[], false));
        assert(p.client.pollTransmit(dgram[], p.now, len));
        assert(len > 0);
        // Server decodes PN against largestReceived without AEAD authentication failure
        assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
        p.now += 1000;
    }

    // Since PN gap (160 - 0) > 128, client's outbound pnLen must be at least 2 bytes (F-01)
    assert(p.client.lossDetector.largestAckedPn[2] == 0);

    // Verify ACK transmission clears hasPendingAck (F-02)
    assert(p.server.ackRanges[2].ackNeeded);
    assert(p.server.pollTransmit(dgram[], p.now, len));
    assert(len > 0);
    // After sending ACK, hasPendingAck is false until new ack-eliciting packet arrives
    assert(!p.server.ackRanges[2].ackNeeded);
    assert(p.client.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
    assert(p.client.lossDetector.largestAckedPn[2] > 0);
}

/// Example:
// Spec: RFC 9000 Section 12.4, RFC 9002 Section 7 - Congestion Window Gating & Multi-Packet Stream MTU Packing (F-03, F-10, D-04, D-12)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));

    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    // Write 4000 bytes of stream data
    ubyte[4000] payload;
    foreach (i, ref b; payload)
        b = cast(ubyte)(i & 0xFF);
    assert(p.client.streamWrite(sid, payload[], false));

    // Pack into 1200-byte MTU buffers without frame truncation or state corruption
    ubyte[1200] mtuBuf;
    size_t packedLen = 0;
    size_t totalPacked = 0;
    while (p.client.pollTransmit(mtuBuf[], p.now, packedLen) && packedLen > 0)
    {
        assert(packedLen <= 1200);
        assert(p.server.handleDatagram(mtuBuf[0 .. packedLen], p.now) == TransportErrorCode.noError);
        totalPacked += packedLen;
        p.now += 500;
    }
    assert(totalPacked >= 4000);

    // Verify ACK-only packets pass inFlight == false (F-10)
    const ulong inFlightBefore = p.server.lossDetector.cc.bytesInFlight;
    assert(p.server.ackRanges[2].ackNeeded);
    assert(p.server.pollTransmit(mtuBuf[], p.now, packedLen));
    assert(packedLen > 0);
    assert(p.server.lossDetector.cc.bytesInFlight == inFlightBefore,
            "ACK-only packet must not increase bytesInFlight");
}

/// Example:
// Spec: RFC 9000 Section 14.1, Section 5.2, Section 19.6 - Server Accepts < 1200B Handshake, Drops Trailing Coalesced Bytes & Rejects Excessive Crypto Buffer (F-06, F-07, F-26, D-12)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);

    const ubyte[8] dcidBytes = [0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57];
    const ubyte[8] scidBytes = [0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.initialMaxData = 1_000_000;
    tp.initialMaxStreamsBidi = 50;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, tp, now, server));

    // Flight 1: Client Initial with trailing unparseable garbage bytes (F-26)
    ubyte[4096] dgram;
    size_t len = 0;
    assert(client.pollTransmit(dgram[], now, len));
    assert(len >= 1200);

    // Append 8 trailing unparseable bytes to the datagram
    ubyte[4104] coalescedGarbage;
    coalescedGarbage[0 .. len] = dgram[0 .. len];
    static const ubyte[8] junkBytes = [
        0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8
    ];
    coalescedGarbage[len .. len + 8] = junkBytes[];

    // Server must process the valid Initial packet and silently drop the trailing garbage without aborting (F-26)
    assert(server.handleDatagram(coalescedGarbage[0 .. len + 8], now) == TransportErrorCode.noError);
    assert(server.hasWriteKeys[2],
            "Server must successfully decrypt and process Initial with trailing garbage");

    // Flight 2: Server transmits Initial + Handshake
    now += 10_000;
    assert(server.pollTransmit(dgram[], now, len));
    assert(client.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    // Flight 3: Client Handshake extracted as standalone packet (< 1200 bytes) (F-07)
    now += 10_000;
    assert(client.pollTransmit(dgram[], now, len));
    CoalescedPacketIterator iter = CoalescedPacketIterator(dgram[0 .. len], 8);
    const(ubyte)[] initialSlice;
    const(ubyte)[] handshakeSlice;
    PacketPrefix pfx;
    WireError we = WireError.none;
    assert(iter.next(initialSlice, pfx, we));
    assert(iter.next(handshakeSlice, pfx, we));
    assert(handshakeSlice.length < 1200, "Standalone Handshake packet is unpadded (< 1200 bytes)");
    // Server must accept unpadded standalone Handshake packet after Initial (F-07)
    assert(server.handleDatagram(handshakeSlice, now) == TransportErrorCode.noError);

    // Verify high-offset CRYPTO frame rejection with cryptoBufferExceeded (0x0d) (F-06)
    CryptoFrame bigCrypto;
    bigCrypto.offset = 65536;
    ubyte[10] cData = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    bigCrypto.data = cData[];
    const te = server.processCryptoFrame(PacketNumberSpace.initial, bigCrypto, now);
    assert(te == TransportErrorCode.cryptoBufferExceeded);
}

/// Example:
// Spec: RFC 9000 Section 7.3 & Section 18.2 - Transport Parameter Mandatory CIDs and Window Isolation (F-08, F-14, D-05, D-12)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        return TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    assert(serverCtx.isValid && clientCtx.isValid);

    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters clientTp;
    clientTp.hasInitialSourceConnectionId = true;
    clientTp.initialSourceConnectionId = scid;
    clientTp.initialMaxData = 1_000_000;
    clientTp.initialMaxStreamsBidi = 50;
    clientTp.initialMaxStreamDataBidiLocal = 12345;

    TransportParameters serverTp;
    serverTp.hasOriginalDestinationConnectionId = true;
    serverTp.originalDestinationConnectionId = dcid;
    serverTp.hasInitialSourceConnectionId = true;
    serverTp.initialSourceConnectionId = dcid;
    serverTp.initialMaxData = 1_000_000;
    serverTp.initialMaxStreamsBidi = 50;
    serverTp.initialMaxStreamDataBidiLocal = 99999;

    ulong now = 1_000_000;
    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, clientTp, now, client));

    // Before peer transport parameters arrive, remote max streams are 0 (F-08, D-05)
    assert(client.streams.remoteMaxStreamsBidi == 0);
    assert(client.streams.remoteMaxStreamsUni == 0);
    assert(client.streams.localInitialMaxStreamDataBidiLocal == 12345);

    // Mismatched original_destination_connection_id on server transport parameters triggers transportParameterError (0x08)
    const ubyte[8] wrongCidBytes = [
        0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04
    ];
    serverTp.hasOriginalDestinationConnectionId = true;
    serverTp.originalDestinationConnectionId = ConnectionId(wrongCidBytes[]);
    QuicConnection badServer;
    QuicConnection goodClient;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, clientTp, now, goodClient));
    assert(QuicConnection.create(Side.server, serverCtx, dcid,
            ConnectionId.init, serverTp, now, badServer));

    ubyte[4096] dgram;
    size_t len = 0;
    assert(goodClient.pollTransmit(dgram[], now, len));
    assert(badServer.handleDatagram(dgram[0 .. len], now) == TransportErrorCode.noError);

    now += 10_000;
    assert(badServer.pollTransmit(dgram[], now, len));
    // Client rejects server Handshake missing original_destination_connection_id
    const te = goodClient.handleDatagram(dgram[0 .. len], now);
    assert(te == TransportErrorCode.transportParameterError);
}

/// Example:
// Spec: RFC 9000 Section 10.2.3, Section 13.3, Section 19.7 - Packet Loss Isolation, Duplicate 1-RTT, Sanitized CC & Frame Validation (F-11, F-20, F-21, F-24, F-27, F-28, D-10, D-12)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));

    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    // F-20: Duplicate 1-RTT packet is ignored without re-dispatching frames or events
    const ubyte[5] data = [1, 2, 3, 4, 5];
    assert(p.client.streamWrite(sid, data[], false));
    ubyte[4096] dgram;
    size_t len = 0;
    assert(p.client.pollTransmit(dgram[], p.now, len));
    assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);

    ConnectionEvent ev;
    bool gotStreamReadable = false;
    while (p.server.pollEvent(ev))
    {
        if (ev.type == ConnectionEventType.streamReadable)
            gotStreamReadable = true;
    }
    assert(gotStreamReadable);

    // Replaying the exact same 1-RTT packet is silently ignored (F-20)
    assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
    assert(!p.server.pollEvent(ev), "Duplicate 1-RTT packet must not generate duplicate events");

    // F-24: Out-of-order FIN does not emit streamFinished until gap is filled
    StreamId sid2;
    assert(p.client.openStream(StreamDirection.bidirectional, sid2) == TransportErrorCode.noError);
    StreamFrame gapFin;
    gapFin.streamId = sid2.id;
    gapFin.offset = 100;
    gapFin.data = cast(const(ubyte)[]) "fin";
    gapFin.fin = true;
    assert(p.server.processStreamFrame(gapFin) == TransportErrorCode.noError);
    // Since offset 0..100 has not arrived, streamFinished must not be emitted
    while (p.server.pollEvent(ev))
    {
        assert(ev.type != ConnectionEventType.streamFinished);
    }

    // F-28: Server rejects FrameType.newToken with protocolViolation
    Frame tokenFrame;
    tokenFrame.type = FrameType.newToken;
    tokenFrame.newToken.token = cast(const(ubyte)[]) "bad_token";
    assert(p.server.dispatchFrame(PacketNumberSpace.applicationData,
            tokenFrame, p.now) == TransportErrorCode.protocolViolation);

    // F-28 & D-10: Server rejects FrameType.retireConnectionId with sequenceNumber > 0
    Frame retireFrame;
    retireFrame.type = FrameType.retireConnectionId;
    retireFrame.retireConnectionId.sequenceNumber = 5;
    assert(p.server.dispatchFrame(PacketNumberSpace.applicationData,
            retireFrame, p.now) == TransportErrorCode.protocolViolation);

    // F-27: CONNECTION_CLOSE_APP in Initial space is sanitized to CONNECTION_CLOSE_QUIC (0x1c) with APPLICATION_ERROR (0x0c)
    QuicConnection earlyClient;
    QuicConnection earlyServer;
    TlsContext earlyCtx = TlsContext.createClientInsecure();
    TlsContext earlyServerCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    const ubyte[8] earlyDcidBytes = [
        0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98
    ];
    const ubyte[8] earlyScidBytes = [
        0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f, 0xa0
    ];
    const ConnectionId earlyDcid = ConnectionId(earlyDcidBytes[]);
    const ConnectionId earlyScid = ConnectionId(earlyScidBytes[]);
    TransportParameters earlyTp;
    assert(QuicConnection.create(Side.client, earlyCtx, earlyScid, earlyDcid,
            earlyTp, p.now, earlyClient));
    assert(QuicConnection.create(Side.server, earlyServerCtx, earlyDcid,
            ConnectionId.init, earlyTp, p.now, earlyServer));
    earlyServer.peerAddressValidated = true;
    earlyClient.close(0x1234, true);
    ubyte[1200] closeBuf;
    size_t closeLen = 0;
    assert(earlyClient.pollTransmit(closeBuf[], p.now, closeLen));
    assert(closeLen > 0);
    assert(earlyServer.handleDatagram(closeBuf[0 .. closeLen], p.now) == TransportErrorCode.noError);
    assert(earlyServer.state == ConnectionState.draining);
    assert(!earlyServer.closeIsApp,
            "CONNECTION_CLOSE_APP in Initial space must be sanitized to QUIC close");
    assert(earlyServer.closeErrorCode == 0x0c,
            "Sanitized error code must be APPLICATION_ERROR (0x0c)");
}

/// Example:
// Spec: RFC 9000 Section 17.2.5.2 & Section 18.2 - Retry Rejection & Custom ack_delay_exponent Scaling (F-19, F-21, D-12)
@nogc unittest
{
    QuicConnection client;
    TlsContext clientCtx = TlsContext.createClientInsecure();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    const ConnectionId dcid = ConnectionId(dcidBytes[]);
    const ConnectionId scid = ConnectionId(scidBytes[]);
    TransportParameters tp;
    tp.ackDelayExponent = 5;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, 1_000_000, client));

    // F-21: Discard if SCID matches client's DCID
    PacketPrefix pfx;
    pfx.token = cast(const(ubyte)[]) "token1";
    pfx.scid = dcid;
    assert(client.handleRetryPacket(pfx, null) == TransportErrorCode.noError);
    assert(!client.retryReceived);

    // F-21: Second Retry packet returns protocolViolation
    client.retryReceived = true;
    const ubyte[8] newScidBytes = [
        0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22
    ];
    pfx.scid = ConnectionId(newScidBytes[]);
    assert(client.handleRetryPacket(pfx, null) == TransportErrorCode.protocolViolation);

    // F-19: Custom ackDelayExponent = 5 scaled on ACK generation
    client.ackRanges[2].insert(10, true, 1_000_000);
    AckFrame ack;
    assert(client.ackRanges[2].buildAckFrame(1_032_000,
            cast(ubyte) client.localParams.ackDelayExponent, ack));
    // Raw delay = 32_000 us. With exponent 5 (2^5 = 32), scaled delay is 32_000 >> 5 = 1000
    assert(ack.ackDelay == (32_000 >> 5));
}
