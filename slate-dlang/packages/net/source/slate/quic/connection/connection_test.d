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
import slate.quic.recovery.ack_ranges : MAX_ACK_RANGES;
import slate.quic.crypto.packet_keys : protectPacket;
import slate.quic.stream.id : StreamDirection, StreamId;

/// Delivers every datagram `from` currently wants to send (one handshake flight, which may
/// span several datagrams of at most 1200 bytes) to `to`. Fails on any rejected datagram.
private bool deliverFlight(ref QuicConnection from, ref QuicConnection to, ulong now) @trusted @nogc nothrow
{
    ubyte[4096] buf;
    size_t len = 0;
    size_t count = 0;
    while (from.pollTransmit(buf[], now, len) && len > 0)
    {
        if (to.handleDatagram(buf[0 .. len], now) != TransportErrorCode.noError)
            return false;
        if (++count > 64)
            return false;
    }
    return count > 0;
}

/// Example:
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
/// // pump datagrams both ways until nothing is left to send
/// assert(exchangeUntilQuiet(client, server, now));
/// assert(client.handshakeConfirmed && server.handshakeConfirmed);
/// ---
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

    // Flight 1: Client -> Server (each Initial datagram padded to 1200 bytes per RFC 9000 §14.1)
    while (client.pollTransmit(dgramBuf[], now, dgramLen) && dgramLen > 0)
    {
        assert(dgramLen == 1200, "Client Initial datagram must be padded to 1200 bytes");
        assert(server.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);
    }
    assert(server.hasWriteKeys[2], "server hasWriteKeys[2] after Flight 1");
    assert(server.cryptoSend[1].hasPendingBytes,
            "server cryptoSend[1] hasPendingBytes after Flight 1");

    // Flight 2: Server -> Client (Server Initial + Server Handshake)
    now += 10_000;
    assert(deliverFlight(server, client, now));
    assert(client.hasReadKeys[2], "client hasReadKeys[2]");
    assert(client.hasWriteKeys[2], "client hasWriteKeys[2]");
    assert(client.cryptoSend[1].hasPendingBytes, "client cryptoSend[1] hasPendingBytes");

    // Flight 3: Client -> Server (Initial ACK coalesced with the Client Handshake, padded to 1200)
    now += 10_000;
    assert(deliverFlight(client, server, now));

    // Client must have discarded Initial keys upon sending Handshake packet (RFC 9001 §4.9.1)
    assert(!client.hasReadKeys[0], "client hasReadKeys[0] must be false");
    assert(!client.hasWriteKeys[0]);

    // Server must have discarded Initial keys upon receiving Client Handshake packet (RFC 9001 §4.9.1)
    assert(!server.hasReadKeys[0]);
    assert(!server.hasWriteKeys[0]);
    assert(server.peerAddressValidated, "Server must validate client address upon Handshake packet");

    // Flight 4: Server -> Client (1-RTT with HANDSHAKE_DONE)
    now += 10_000;
    assert(deliverFlight(server, client, now));

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
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "payload", false));
/// ubyte[4096] buf;
/// size_t len;
/// assert(p.client.pollTransmit(buf[], p.now, len));    // lost on the wire, never delivered
/// p.now += 1_000_000;
/// p.client.onTimeout(p.now);                           // the loss timer fires
/// assert(p.client.pollTransmit(buf[], p.now, len) && len > 0);   // the bytes are retransmitted
/// ---
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
    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));
    now += 10_000;
    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));

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
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// ConnectionId dcid = ConnectionId(dcidBytes[]);
/// TransportParameters tp;
/// ulong now = 1_000_000;
/// QuicConnection server;
/// assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, tp, now, server, false));
///
/// // An Initial datagram below 1200 bytes is dropped: nothing is counted, nothing is answered.
/// ubyte[1199] undersized;
/// undersized[0] = 0xc0;   // long header, Initial
/// assert(server.handleDatagram(undersized[], now) == TransportErrorCode.noError);
/// assert(server.totalBytesReceived == 0);
/// ubyte[1500] buf;
/// size_t len;
/// assert(!server.pollTransmit(buf[], now, len) || len == 0);
/// ---
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
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
///
/// // PATH_CHALLENGE is answered with a PATH_RESPONSE carrying the same data.
/// const ubyte[8] challengeData = [1, 2, 3, 4, 5, 6, 7, 8];
/// p.client.sendPathChallenge(challengeData);
/// ubyte[1500] dgram;
/// size_t len;
/// assert(p.client.pollTransmit(dgram[], p.now, len));
/// assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
/// assert(p.server.hasPendingPathResponse && p.server.pendingPathResponseData == challengeData);
///
/// // A key update flips the key phase bit and the peer follows.
/// assert(p.client.initiateKeyUpdate() && p.client.localKeyPhase == 1);
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "ping", false));
/// assert(p.client.pollTransmit(dgram[], p.now, len));
/// assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
/// assert(p.server.remoteKeyPhase == 1);
/// ---
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
    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));
    now += 10_000;
    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));
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
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "hello", false));
/// ubyte[1200] dgram;
/// size_t n;
/// assert(p.client.pollTransmit(dgram[], p.now, n));
/// ubyte[1200] forged = dgram;
/// forged[0] ^= 0x04;                                   // flip the key phase bit: the AEAD tag no longer fits
/// assert(p.server.handleDatagram(forged[0 .. n], p.now) == TransportErrorCode.noError);
/// assert(p.server.state == ConnectionState.active);    // dropped silently, no key update
/// ---
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
    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));
    now += 10_000;
    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));

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
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
/// // a client Initial whose payload is a STREAM frame, which RFC 9000 Table 3 forbids there
/// Frame forbidden;
/// forbidden.type = FrameType.stream;
/// forbidden.stream.data = cast(const(ubyte)[]) "forbidden";
/// forbidden.stream.hasLength = true;
/// ubyte[1200] badInitialPkt;
/// ubyte[64] payload;
/// size_t payloadLen, pnOffset, headerLen, protectedLen;
/// assert(encodeFrame(forbidden, payload[], payloadLen) == WireError.none);
/// payload[payloadLen .. 32] = 0;                       // PADDING up to the header protection sample
/// payloadLen = 32;
/// assert(encodeLongHeader(PacketType.initial, QUIC_VERSION_1, server.localCid, client.localCid,
///         null, 99, 2, payloadLen, badInitialPkt[], pnOffset, headerLen) == WireError.none);
/// badInitialPkt[headerLen .. headerLen + payloadLen] = payload[0 .. payloadLen];
/// assert(protectPacket(client.levelKeys[0].local, 99, pnOffset, 2, badInitialPkt[], payloadLen,
///         protectedLen) == QuicCryptoError.none);
/// badInitialPkt[protectedLen .. 1200] = 0;             // datagram padded to 1200 bytes
/// assert(server.handleDatagram(badInitialPkt[], now) == TransportErrorCode.protocolViolation);
/// assert(server.state == ConnectionState.closing);
/// ubyte[1200] closeBuf;
/// size_t closeLen;
/// assert(server.pollTransmit(closeBuf[], now, closeLen));   // CONNECTION_CLOSE goes out
/// assert(server.state == ConnectionState.draining);
/// ---
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
/// ---
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// TransportParameters tp;
/// tp.maxIdleTimeout = 1000;                            // 1000 ms
/// ulong now = 1_000_000;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidBytes[]),
///         ConnectionId(dcidBytes[]), tp, now, client));
/// client.lastRxTimeMicros = now;
/// client.onTimeout(now + 1_100_000);                   // 1.1 s of silence
/// assert(client.state == ConnectionState.closed);
/// ConnectionEvent ev;
/// assert(client.pollEvent(ev) && ev.type == ConnectionEventType.connectionClosed);
/// assert(!ev.isApplicationClose);
/// ---
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
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// p.client.resetStream(sid, 0x1234);               // queues RESET_STREAM(sid, 0x1234)
/// ubyte[4096] dgram;
/// size_t len;
/// assert(p.client.pollTransmit(dgram[], p.now += 1000, len));
/// assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
/// ConnectionEvent ev;
/// bool seen;
/// while (p.server.pollEvent(ev))
///     seen = seen || (ev.type == ConnectionEventType.streamReset && ev.errorCode == 0x1234);
/// assert(seen);                                    // the peer is told the stream was reset
/// p.server.stopSending(sid, 0x5678);               // queues STOP_SENDING(sid, 0x5678)
/// assert(p.server.pollTransmit(dgram[], p.now += 1000, len));
/// assert(p.client.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
/// seen = false;
/// while (p.client.pollEvent(ev))
///     seen = seen || (ev.type == ConnectionEventType.stopSending && ev.errorCode == 0x5678);
/// assert(seen);
/// ---
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
    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));
    now += 10_000;
    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));

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
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// ConnectionId dcid = ConnectionId(dcidBytes[]);
/// ConnectionId scid = ConnectionId(scidBytes[]);
/// TransportParameters tp;
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client, false, null, "smsp/1"));
/// assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, tp, now, server));
///
/// assert(deliverFlight(client, server, now));
/// assert(server.negotiatedAlpn == "smsp/1");   // the server picks the client's protocol
/// ---
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
    assert(deliverFlight(client, server, now));
    assert(server.negotiatedAlpn == "smsp/1");

    now += 10_000;
    assert(deliverFlight(server, client, now));
    assert(client.state == ConnectionState.active);
    assert(client.negotiatedAlpn == "smsp/1");

    now += 10_000;
    assert(deliverFlight(client, server, now));
    assert(server.state == ConnectionState.active);
    assert(server.negotiatedAlpn == "smsp/1");

    // Second client offering unknown ALPN "unknown/9" is rejected with TLS alert 120 (0x0178)
    QuicConnection badClient;
    QuicConnection server2;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now,
            badClient, false, null, "unknown/9"));
    assert(QuicConnection.create(Side.server, serverCtx, dcid,
            ConnectionId.init, tp, now, server2));
    // The ClientHello spans several datagrams; the alert fires once it is complete.
    TransportErrorCode badTe = TransportErrorCode.noError;
    while (badTe == TransportErrorCode.noError && badClient.pollTransmit(dgram[],
            now, len) && len > 0)
        badTe = server2.handleDatagram(dgram[0 .. len], now);
    assert(badTe == cast(TransportErrorCode) 0x0178);
    assert(server2.state == ConnectionState.closing);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p, 8192, 4096, 10));   // 8 KiB connection window, 4 KiB stream window
///
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[32768] payload;
/// assert(p.client.streamWrite(sid, payload[], true));
///
/// // The 32 KiB only fit because the receiver raises MAX_STREAM_DATA / MAX_DATA as it reads.
/// size_t total;
/// ubyte[2048] rb;
/// bool fin;
/// foreach (round; 0 .. 500)
/// {
///     size_t len;
///     ubyte[1500] dgram;
///     while (p.client.pollTransmit(dgram[], p.now, len) && len > 0)
///         assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
///     ptrdiff_t n;
///     while ((n = p.server.streamRead(sid, rb[], fin)) > 0)
///         total += n;                     // reading is what credits the window
///     while (p.server.pollTransmit(dgram[], p.now, len) && len > 0)
///         assert(p.client.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
///     if (fin)
///         break;
/// }
/// assert(total == payload.length);
/// ---
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
    assert(deliverFlight(client, server, now));

    // Flight 2: Server Initial + Handshake
    now += 10_000;
    assert(deliverFlight(server, client, now));

    // Flight 3: Client Handshake
    now += 10_000;
    assert(deliverFlight(client, server, now));

    // Flight 4: Server 1-RTT (HANDSHAKE_DONE)
    now += 10_000;
    assert(deliverFlight(server, client, now));
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
    if (!deliverFlight(pair.client, pair.server, now))
        return false;

    // Flight 2: Server Initial + Handshake
    now += 10_000;
    if (!deliverFlight(pair.server, pair.client, now))
        return false;

    // Flight 3: Client Handshake
    now += 10_000;
    if (!deliverFlight(pair.client, pair.server, now))
        return false;

    // Flight 4: Server 1-RTT (HANDSHAKE_DONE)
    now += 10_000;
    if (!deliverFlight(pair.server, pair.client, now))
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
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.server.openStream(StreamDirection.unidirectional, sid) == TransportErrorCode.noError);
///
/// // 400 packets: the 1-byte packet numbers wrap, yet every one must be decoded and recorded.
/// ubyte[4096] dgram;
/// ubyte[64] readBuf;
/// size_t len;
/// bool fin;
/// foreach (i; 0 .. 400)
/// {
///     ubyte[8] payload = cast(ubyte) i;
///     assert(p.server.streamWrite(sid, payload[], false));
///     assert(p.server.pollTransmit(dgram[], p.now, len) && len > 0);
///     const ulong pn = p.server.nextPn[2] - 1;
///     assert(p.client.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
///     assert(p.client.ackRanges[2].contains(pn));   // decoded against the largest received PN
///     p.client.streamRead(sid, readBuf[], fin);     // the application keeps reading
///     if (p.client.pollTransmit(dgram[], p.now, len) && len > 0)   // and ACKs go back
///         assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
///     p.now += 1000;
/// }
/// ---
// Spec: RFC 9000 Section 17.1 & Appendix A.3 - packet numbers are decoded relative to the
// largest packet number received in the space (R-10, U3, Scenario T10; regression for F-01)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));

    // Server-initiated unidirectional stream: the client only ever receives on it.
    StreamId sid;
    assert(p.server.openStream(StreamDirection.unidirectional, sid) == TransportErrorCode.noError);

    enum size_t PACKETS = 400; // > 256: 1-byte packet numbers wrap at least once
    ubyte[4096] dgram;
    size_t len = 0;
    ubyte[64] readBuf;
    size_t received = 0;
    size_t maxPnLen = 0;

    foreach (i; 0 .. PACKETS)
    {
        ubyte[8] payload;
        foreach (j, ref b; payload)
            b = cast(ubyte)(i * 8 + j);
        assert(p.server.streamWrite(sid, payload[], false));
        assert(p.server.pollTransmit(dgram[], p.now, len) && len > 0);
        // Short header: the low two bits of the (unprotected) first byte encode pnLen - 1;
        // learn the length the server chose from its packet-number state instead.
        const ulong pn = p.server.nextPn[2] - 1;
        const ulong srvAcked = p.server.lossDetector.hasAckedPn[2]
            ? p.server.lossDetector.largestAckedPn[2] : 0;
        const size_t pnLen = (pn > srvAcked ? pn - srvAcked : 1) * 2 < 256 ? 1 : 2;
        if (pnLen > maxPnLen)
            maxPnLen = pnLen;

        assert(p.client.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
        // The packet must have been authenticated and recorded, not silently dropped.
        assert(p.client.ackRanges[2].contains(pn), "1-RTT packet dropped by PN decoding");

        bool fin = false;
        const ptrdiff_t n = p.client.streamRead(sid, readBuf[], fin);
        assert(n == 8);
        foreach (j; 0 .. 8)
            assert(readBuf[j] == cast(ubyte)(received + j));
        received += 8;

        // The client answers with ACK-only packets, keeping the server's PNs 1 byte long.
        if (p.client.pollTransmit(dgram[], p.now, len) && len > 0)
            assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
        p.now += 1000;
    }

    assert(received == PACKETS * 8);
    assert(maxPnLen == 1, "test precondition: server used 1-byte packet numbers");
    assert(p.server.nextPn[2] > 256);
    // Precondition that makes the test bite: the client has no acknowledged 1-RTT packet, so
    // a decoder keyed on largestAckedPn would expect PN 1 and mis-decode PNs >= 256.
    assert(!p.client.lossDetector.hasAckedPn[2]);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[200 * 1024] payload;
/// assert(p.client.streamWrite(sid, payload[], false));
/// const ulong cwnd = p.client.lossDetector.cc.cwnd;
///
/// // Send until pollTransmit stops; no ACK returns, so the congestion window closes.
/// ubyte[1200] mtuBuf;
/// size_t len;
/// while (p.client.pollTransmit(mtuBuf[], p.now, len) && len > 0)
///     assert(p.server.handleDatagram(mtuBuf[0 .. len], p.now) == TransportErrorCode.noError);
/// const ulong inFlight = p.client.lossDetector.cc.bytesInFlight;
/// assert(inFlight >= cwnd && inFlight < cwnd + 1200);   // at most one datagram past the window
/// assert(!p.client.pollTransmit(mtuBuf[], p.now, len) || len == 0);
/// ---
// Spec: RFC 9002 Section 7 - a sender MUST NOT send ack-eliciting data beyond the congestion
// window (R-11, U3; regression for F-10), RFC 9002 Section 2 - ACK-only packets are not in flight
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));

    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    ubyte[200 * 1024] payload;
    foreach (i, ref b; payload)
        b = cast(ubyte)(i & 0xFF);
    assert(p.client.streamWrite(sid, payload[], false));

    const ulong cwnd = p.client.lossDetector.cc.cwnd;
    assert(cwnd < payload.length, "test precondition: data exceeds the congestion window");

    // Drain pollTransmit; the datagrams reach the server but nothing returns to the client, so
    // no ACK can open the window yet.
    ubyte[1200] mtuBuf;
    size_t packedLen = 0;
    size_t datagrams = 0;
    while (datagrams < 1000 && p.client.pollTransmit(mtuBuf[], p.now, packedLen) && packedLen > 0)
    {
        assert(packedLen <= 1200);
        assert(p.server.handleDatagram(mtuBuf[0 .. packedLen], p.now) == TransportErrorCode.noError);
        datagrams++;
    }
    auto qs = p.client.streams.getStream(sid);
    assert(qs !is null);
    const ulong inFlight = p.client.lossDetector.cc.bytesInFlight;
    // Gating: at most one datagram beyond the window may be in flight ...
    assert(inFlight >= cwnd && inFlight < cwnd + 1200, "STREAM packing ignored cwnd");
    // ... and most of the stream data is still waiting.
    const ulong unsentBlocked = qs.sendBuf.unsentOffset;
    assert(unsentBlocked < payload.length);
    assert(unsentBlocked < cwnd + 1200);
    assert(datagrams < 1000);
    // Blocked: another poll yields no STREAM data.
    assert(!p.client.pollTransmit(mtuBuf[], p.now, packedLen) || packedLen == 0);
    assert(qs.sendBuf.unsentOffset == unsentBlocked);

    // ACK-only packets are not counted in flight (RFC 9002 Section 2).
    const ulong srvInFlightBefore = p.server.lossDetector.cc.bytesInFlight;
    assert(p.server.ackRanges[2].ackNeeded);
    p.now += 1000;
    assert(p.server.pollTransmit(mtuBuf[], p.now, packedLen) && packedLen > 0);
    assert(p.server.lossDetector.cc.bytesInFlight == srvInFlightBefore,
            "ACK-only packet must not increase bytesInFlight");

    // The ACK opens the client's window and the remaining data flows again: new STREAM bytes
    // are transmitted and the sender's in-flight count rises from the drained level.
    assert(p.client.handleDatagram(mtuBuf[0 .. packedLen], p.now) == TransportErrorCode.noError);
    const ulong inFlightAfterAck = p.client.lossDetector.cc.bytesInFlight;
    assert(inFlightAfterAck < inFlight, "ACK must release bytes in flight");
    size_t resumed = 0;
    while (resumed < 1000 && p.client.pollTransmit(mtuBuf[], p.now, packedLen) && packedLen > 0)
    {
        assert(p.server.handleDatagram(mtuBuf[0 .. packedLen], p.now) == TransportErrorCode.noError);
        resumed++;
    }
    assert(resumed > 0, "sending must resume after the ACK");
    assert(qs.sendBuf.unsentOffset > unsentBlocked, "new STREAM bytes must be transmitted");
    assert(p.server.streams.getStream(sid) !is null);
}

/// Example:
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
/// assert(deliverFlight(client, server, now));
/// now += 10_000;
/// assert(deliverFlight(server, client, now));
/// now += 10_000;
/// assert(deliverFlight(client, server, now));
/// // a CRYPTO frame at offset 65536 lies beyond the crypto buffer and is refused
/// CryptoFrame big;
/// big.offset = 65536;
/// const ubyte[10] cryptoData = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
/// big.data = cryptoData[];
/// assert(server.processCryptoFrame(PacketNumberSpace.initial, big, now)
///         == TransportErrorCode.cryptoBufferExceeded);
/// ---
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
    assert(!server.ackRanges[0].empty,
            "Server must successfully decrypt and process Initial with trailing garbage");
    deliverFlight(client, server, now); // remainder of the ClientHello, if any
    assert(server.hasWriteKeys[2]);

    // Flight 2: Server transmits Initial + Handshake
    now += 10_000;
    assert(deliverFlight(server, client, now));

    // Flight 3: Client Handshake extracted as standalone packet (< 1200 bytes) (F-07)
    now += 10_000;
    assert(client.pollTransmit(dgram[], now, len));
    const(ubyte)[] handshakeSlice;
    {
        CoalescedPacketIterator iter = CoalescedPacketIterator(dgram[0 .. len], 8);
        const(ubyte)[] pktSlice;
        PacketPrefix pfx;
        WireError we = WireError.none;
        while (iter.next(pktSlice, pfx, we))
        {
            if (pfx.type == PacketType.handshake)
                handshakeSlice = pktSlice;
        }
    }
    assert(handshakeSlice.length > 0, "client must emit a Handshake packet");
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
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// const ubyte[8] wrongBytes = [0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4];
/// const ConnectionId dcid = ConnectionId(dcidBytes[]);
/// const ConnectionId scid = ConnectionId(scidBytes[]);
/// TransportParameters clientTp, serverTp;
/// serverTp.hasOriginalDestinationConnectionId = true;
/// serverTp.originalDestinationConnectionId = ConnectionId(wrongBytes[]);   // not the client's DCID
/// serverTp.hasInitialSourceConnectionId = true;
/// serverTp.initialSourceConnectionId = dcid;
/// const ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, clientTp, now, client));
/// assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, serverTp, now, server));
/// assert(deliverFlight(client, server, now));
/// // the client rejects the server's flight once the mismatching parameters arrive
/// ubyte[4096] flight;
/// size_t n;
/// TransportErrorCode te;
/// while (te == TransportErrorCode.noError && server.pollTransmit(flight[], now + 10_000, n) && n > 0)
///     te = client.handleDatagram(flight[0 .. n], now + 10_000);
/// assert(te == TransportErrorCode.transportParameterError);
/// ---
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
    assert(deliverFlight(goodClient, badServer, now));

    now += 10_000;
    // Client rejects server Handshake missing original_destination_connection_id
    TransportErrorCode te = TransportErrorCode.noError;
    while (te == TransportErrorCode.noError && badServer.pollTransmit(dgram[], now, len) && len > 0)
        te = goodClient.handleDatagram(dgram[0 .. len], now);
    assert(te == TransportErrorCode.transportParameterError);
}

/// Example:
/// ---
/// // CONNECTION_CLOSE with an application error sent in the Initial space is sanitized (F-27)
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98];
/// const ubyte[8] scidBytes = [0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f, 0xa0];
/// TransportParameters tp;
/// const ulong now = 1_000_000;
/// QuicConnection earlyClient, earlyServer;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidBytes[]),
///         ConnectionId(dcidBytes[]), tp, now, earlyClient));
/// assert(QuicConnection.create(Side.server, serverCtx, ConnectionId(dcidBytes[]),
///         ConnectionId.init, tp, now, earlyServer));
/// earlyServer.peerAddressValidated = true;
/// earlyClient.close(0x1234, true);
/// ubyte[1200] closeBuf;
/// size_t closeLen;
/// assert(earlyClient.pollTransmit(closeBuf[], now, closeLen));
/// assert(earlyServer.handleDatagram(closeBuf[0 .. closeLen], now) == TransportErrorCode.noError);
/// assert(earlyServer.state == ConnectionState.draining && !earlyServer.closeIsApp);
/// assert(earlyServer.closeErrorCode == 0x0c);          // APPLICATION_ERROR
/// ---
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
/// ---
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// const ConnectionId dcid = ConnectionId(dcidBytes[]);
/// const ConnectionId scid = ConnectionId(scidBytes[]);
/// TransportParameters tp;
/// tp.ackDelayExponent = 5;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, 1_000_000, client));
///
/// client.retryReceived = true;   // a Retry was already processed
/// const ubyte[8] newScidBytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22];
/// PacketPrefix pfx;
/// pfx.token = cast(const(ubyte)[]) "token1";
/// pfx.scid = ConnectionId(newScidBytes[]);
/// assert(client.handleRetryPacket(pfx, null) == TransportErrorCode.noError);   // discarded silently
/// assert(client.retryScid != pfx.scid && client.retryTokenLen == 0);
///
/// // The advertised ack_delay_exponent scales the ACK delay.
/// client.ackRanges[2].insert(10, true, 1_000_000);
/// AckFrame ack;
/// assert(client.ackRanges[2].buildAckFrame(1_032_000, cast(ubyte) client.localParams.ackDelayExponent, ack));
/// assert(ack.ackDelay == (32_000 >> 5));
/// ---
// Spec: RFC 9000 Section 17.2.5.2 & Section 18.2 - Retry Rejection (a second Retry is discarded, R-17) & Custom ack_delay_exponent Scaling (F-19, F-21, D-12)
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

    // R-17: a second Retry is discarded silently (no PROTOCOL_VIOLATION, no state change)
    client.retryReceived = true;
    const ubyte[8] newScidBytes = [
        0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22
    ];
    pfx.scid = ConnectionId(newScidBytes[]);
    assert(client.handleRetryPacket(pfx, null) == TransportErrorCode.noError);
    assert(client.retryScid != pfx.scid && client.retryTokenLen == 0);

    // F-19: Custom ackDelayExponent = 5 scaled on ACK generation
    client.ackRanges[2].insert(10, true, 1_000_000);
    AckFrame ack;
    assert(client.ackRanges[2].buildAckFrame(1_032_000,
            cast(ubyte) client.localParams.ackDelayExponent, ack));
    // Raw delay = 32_000 us. With exponent 5 (2^5 = 32), scaled delay is 32_000 >> 5 = 1000
    assert(ack.ackDelay == (32_000 >> 5));
}

private TlsContext loadTestServerCtx() @trusted @nogc nothrow
{
    TlsContext ctx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    if (!ctx.isValid)
        ctx = TlsContext.createServer("packages/net/test/fixtures/quic_cert.pem",
                "packages/net/test/fixtures/quic_key.pem");
    if (!ctx.isValid)
        ctx = TlsContext.createServer("slate-dlang/packages/net/test/fixtures/quic_cert.pem",
                "slate-dlang/packages/net/test/fixtures/quic_key.pem");
    return ctx;
}

/// Exchanges datagrams in both directions until neither side has anything to send.
/// Returns false as soon as either side rejects a datagram.
private bool exchangeUntilQuiet(ref QuicConnection a, ref QuicConnection b,
        ref ulong now, size_t maxDatagram = 1200) @trusted @nogc nothrow
{
    ubyte[4096] buf;
    size_t len = 0;
    foreach (_; 0 .. 200)
    {
        bool traffic = false;
        if (a.pollTransmit(buf[0 .. maxDatagram], now, len) && len > 0)
        {
            if (b.handleDatagram(buf[0 .. len], now) != TransportErrorCode.noError)
                return false;
            traffic = true;
        }
        if (b.pollTransmit(buf[0 .. maxDatagram], now, len) && len > 0)
        {
            if (a.handleDatagram(buf[0 .. len], now) != TransportErrorCode.noError)
                return false;
            traffic = true;
        }
        now += 1000;
        if (!traffic)
            return true;
    }
    return true;
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// const ubyte[12] srvBytes = [0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab];
/// const ConnectionId clientDcid = ConnectionId(dcidBytes[]);
/// const ConnectionId serverScid = ConnectionId(srvBytes[]);
/// TransportParameters tp;
/// TransportParameters serverTp = tp;
/// serverTp.hasOriginalDestinationConnectionId = true;
/// serverTp.originalDestinationConnectionId = clientDcid;
/// serverTp.hasInitialSourceConnectionId = true;
/// serverTp.initialSourceConnectionId = serverScid;
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidBytes[]), clientDcid, tp, now, client));
/// assert(QuicConnection.create(Side.server, serverCtx, clientDcid, ConnectionId.init, serverTp, now, server));
/// server.localCid = serverScid;   // the endpoint picks a 12-byte SCID unrelated to the client's DCID
///
/// assert(deliverFlight(client, server, now));
/// now += 1000;
/// assert(deliverFlight(server, client, now));
/// assert(client.remoteCid == serverScid);   // later client packets use the server-chosen CID
/// ---
// Spec: RFC 9000 Section 7.2 - the client uses the server's Initial SCID as DCID for all
// subsequent packets; Section 7.3 - initial_source_connection_id authentication
// (R-02, E1, Scenario T2)
@nogc unittest
{
    TlsContext serverCtx = loadTestServerCtx();
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);

    const ubyte[8] dcidBytes = [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17];
    const ubyte[8] scidBytes = [0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27];
    const ubyte[12] srvBytes = [
        0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab
    ];
    const ConnectionId clientDcid = ConnectionId(dcidBytes[]);
    const ConnectionId clientScid = ConnectionId(scidBytes[]);
    const ConnectionId serverScid = ConnectionId(srvBytes[]);

    TransportParameters clientTp;
    clientTp.initialMaxData = 1_000_000;
    clientTp.initialMaxStreamsBidi = 10;
    clientTp.initialMaxStreamDataBidiLocal = 100_000;
    clientTp.initialMaxStreamDataBidiRemote = 100_000;

    TransportParameters serverTp = clientTp;
    serverTp.hasOriginalDestinationConnectionId = true;
    serverTp.originalDestinationConnectionId = clientDcid;
    serverTp.hasInitialSourceConnectionId = true;
    serverTp.initialSourceConnectionId = serverScid;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, clientScid,
            clientDcid, clientTp, now, client));
    // The server's Initial keys derive from the client's DCID (RFC 9001 Section 5.2); its
    // endpoint then picks a fresh 12-byte SCID before anything is sent, as a real server
    // does. The transport parameters already advertise that SCID.
    assert(QuicConnection.create(Side.server, serverCtx, clientDcid,
            ConnectionId.init, serverTp, now, server));
    server.localCid = serverScid;

    ubyte[1200] dg;
    size_t len = 0;
    // Flight 1 (the ClientHello may span several datagrams): every client Initial is
    // addressed to its randomly chosen DCID.
    size_t flight1 = 0;
    while (client.pollTransmit(dg[], now, len) && len > 0)
    {
        assert(len == 1200);
        assert(dg[5] == 8 && dg[6 .. 14] == dcidBytes[]);
        assert(server.handleDatagram(dg[0 .. len], now) == TransportErrorCode.noError);
        flight1++;
    }
    assert(flight1 > 0);

    // Flight 2 (possibly several datagrams): the server's Initial carries SCID = serverScid.
    now += 1000;
    while (server.pollTransmit(dg[], now, len) && len > 0)
        assert(client.handleDatagram(dg[0 .. len], now) == TransportErrorCode.noError);
    assert(client.remoteCid == serverScid);

    // Every subsequent client packet (here: Handshake) uses the server-chosen CID.
    now += 1000;
    assert(client.pollTransmit(dg[], now, len) && len > 0);
    assert((dg[0] & 0x80) != 0 && dg[5] == 12 && dg[6 .. 18] == srvBytes[]);
    assert(server.handleDatagram(dg[0 .. len], now) == TransportErrorCode.noError);

    assert(exchangeUntilQuiet(client, server, now));
    assert(client.handshakeConfirmed);
    assert(client.peerParamsReceived && client.peerParams.initialSourceConnectionId == serverScid);
    assert(server.remoteCid == clientScid);

    // 1-RTT: short header DCID is the 12-byte server CID; the server accepts the data.
    StreamId sid;
    assert(client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    assert(client.streamWrite(sid, cast(const(ubyte)[]) "ping", true));
    assert(client.pollTransmit(dg[], now, len) && len > 0);
    assert((dg[0] & 0x80) == 0 && dg[1 .. 13] == srvBytes[]);
    assert(server.handleDatagram(dg[0 .. len], now) == TransportErrorCode.noError);
    ubyte[16] rb;
    bool fin = false;
    assert(server.streamRead(sid, rb[], fin) == 4 && fin && rb[0 .. 4] == cast(const(ubyte)[]) "ping");

    // W: a server whose initial_source_connection_id does not match its Initial SCID is
    // rejected with TRANSPORT_PARAMETER_ERROR (CID authentication still bites).
    const ubyte[8] liarBytes = [0xee, 0xee, 0xee, 0xee, 0xee, 0xee, 0xee, 0xee];
    TransportParameters liarTp = serverTp;
    liarTp.initialSourceConnectionId = ConnectionId(liarBytes[]);
    QuicConnection client2;
    QuicConnection liar;
    TlsContext clientCtx2 = TlsContext.createClientInsecure();
    assert(QuicConnection.create(Side.client, clientCtx2, clientScid,
            clientDcid, clientTp, now, client2));
    assert(QuicConnection.create(Side.server, serverCtx, clientDcid,
            ConnectionId.init, liarTp, now, liar));
    liar.localCid = serverScid;
    while (client2.pollTransmit(dg[], now, len) && len > 0)
        assert(liar.handleDatagram(dg[0 .. len], now) == TransportErrorCode.noError);
    TransportErrorCode clientErr = TransportErrorCode.noError;
    while (clientErr == TransportErrorCode.noError && liar.pollTransmit(dg[], now, len) && len > 0)
        clientErr = client2.handleDatagram(dg[0 .. len], now);
    assert(clientErr == TransportErrorCode.transportParameterError);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "request", true));
/// assert(exchangeUntilQuiet(p.client, p.server, p.now));
/// ubyte[64] rb;
/// bool fin;
/// assert(p.server.streamRead(sid, rb[], fin) == 7 && fin);
/// assert(p.server.streamWrite(sid, cast(const(ubyte)[]) "response", true));
/// assert(exchangeUntilQuiet(p.client, p.server, p.now));
/// assert(p.client.streamRead(sid, rb[], fin) == 8 && fin);
/// assert(exchangeUntilQuiet(p.client, p.server, p.now));   // again, round 3
/// assert(p.client.streams.getStream(sid) is null);   // reaped on both endpoints
///
/// // A late retransmission of the response must neither fail nor bring the stream back.
/// Frame lateStream;
/// lateStream.type = FrameType.stream;
/// lateStream.stream.streamId = sid.id;
/// lateStream.stream.data = cast(const(ubyte)[]) "response";
/// lateStream.stream.hasLength = true;
/// lateStream.stream.fin = true;
/// assert(p.client.dispatchFrame(PacketNumberSpace.applicationData, lateStream, p.now)
///         == TransportErrorCode.noError);
/// assert(p.client.streams.getStream(sid) is null);
/// ---
// Spec: RFC 9000 Section 3.2/3.5 & Section 13.3 - retransmissions may arrive after a stream
// reached a terminal state and must not cause errors or recreate the stream (R-04, E2,
// Scenario T4)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));

    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "request", true));
    assert(exchangeUntilQuiet(p.client, p.server, p.now));

    ubyte[64] rb;
    bool fin = false;
    assert(p.server.streamRead(sid, rb[], fin) == 7 && fin);
    assert(p.server.streamWrite(sid, cast(const(ubyte)[]) "response", true));
    assert(exchangeUntilQuiet(p.client, p.server, p.now));
    assert(p.client.streamRead(sid, rb[], fin) == 8 && fin);
    assert(exchangeUntilQuiet(p.client, p.server, p.now));

    // Precondition: the stream is gone on both sides.
    assert(p.client.streams.getStream(sid) is null);
    assert(p.server.streams.getStream(sid) is null);
    const size_t clientStreams = p.client.streams.streamCount;
    const size_t serverStreams = p.server.streams.streamCount;

    Frame lateStream;
    lateStream.type = FrameType.stream;
    lateStream.stream.streamId = sid.id;
    lateStream.stream.data = cast(const(ubyte)[]) "response";
    lateStream.stream.hasLength = true;
    lateStream.stream.fin = true;

    Frame lateReset;
    lateReset.type = FrameType.resetStream;
    lateReset.resetStream.streamId = sid.id;
    lateReset.resetStream.applicationErrorCode = 7;
    lateReset.resetStream.finalSize = 8;

    Frame lateMsd;
    lateMsd.type = FrameType.maxStreamData;
    lateMsd.maxStreamData.streamId = sid.id;
    lateMsd.maxStreamData.maximumStreamData = 500_000;

    Frame lateStop;
    lateStop.type = FrameType.stopSending;
    lateStop.stopSending.streamId = sid.id;
    lateStop.stopSending.applicationErrorCode = 7;

    Frame lateBlocked;
    lateBlocked.type = FrameType.streamDataBlocked;
    lateBlocked.streamDataBlocked.streamId = sid.id;
    lateBlocked.streamDataBlocked.maximumStreamData = 8;

    const Frame[5] late = [
        lateStream, lateReset, lateMsd, lateStop, lateBlocked
    ];
    foreach (ref const f; late)
    {
        // Client: the stream is locally initiated and was reaped.
        assert(p.client.dispatchFrame(PacketNumberSpace.applicationData, f,
                p.now) == TransportErrorCode.noError);
        // Server: the stream is peer initiated and was reaped.
        assert(p.server.dispatchFrame(PacketNumberSpace.applicationData, f,
                p.now) == TransportErrorCode.noError);
    }
    assert(p.client.streams.getStream(sid) is null && p.client.streams.streamCount == clientStreams);
    assert(p.server.streams.getStream(sid) is null && p.server.streams.streamCount == serverStreams);
    assert(p.client.state == ConnectionState.active && p.server.state == ConnectionState.active);
    assert(exchangeUntilQuiet(p.client, p.server, p.now));

    // W: frames for a locally initiated stream that was never opened remain an error.
    const StreamId unopened = StreamId.make(Side.client, StreamDirection.bidirectional, 50);
    Frame bogus = lateStream;
    bogus.stream.streamId = unopened.id;
    assert(p.client.dispatchFrame(PacketNumberSpace.applicationData, bogus,
            p.now) == TransportErrorCode.streamStateError);
    Frame bogusReset = lateReset;
    bogusReset.resetStream.streamId = unopened.id;
    assert(p.client.dispatchFrame(PacketNumberSpace.applicationData,
            bogusReset, p.now) == TransportErrorCode.streamStateError);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// p.client.peerParams.maxUdpPayloadSize = 1350;   // the peer allows 1350, we still cap at 1200
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[64 * 1024] payload;
/// assert(p.client.streamWrite(sid, payload[], true));
///
/// ubyte[4096] dg;   // the buffer is larger than any datagram that may be produced
/// size_t len, datagrams;
/// while (p.client.pollTransmit(dg[], p.now, len) && len > 0 && datagrams < 100)
/// {
///     assert(len <= 1200);
///     assert(p.server.handleDatagram(dg[0 .. len], p.now) == TransportErrorCode.noError);
///     datagrams++;
/// }
/// assert(datagrams > 0);
/// ---
// Spec: RFC 9000 Section 14 & Section 18.2 (max_udp_payload_size) - datagrams are capped at
// min(1200, peer limit) until path MTU discovery exists (R-05, U2, plan D1, Scenario T5)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    p.client.peerParams.maxUdpPayloadSize = 1350;
    p.server.peerParams.maxUdpPayloadSize = 1350;

    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    ubyte[64 * 1024] payload;
    foreach (i, ref b; payload)
        b = cast(ubyte)(i * 13);
    assert(p.client.streamWrite(sid, payload[], true));

    ubyte[4096] dg;
    size_t len = 0;
    size_t received = 0;
    ubyte[4096] rb;
    bool fin = false;
    size_t datagrams = 0;
    foreach (_; 0 .. 2000)
    {
        bool traffic = false;
        if (p.client.pollTransmit(dg[], p.now, len) && len > 0)
        {
            assert(len <= 1200, "client datagram exceeds 1200 bytes");
            datagrams++;
            assert(p.server.handleDatagram(dg[0 .. len], p.now) == TransportErrorCode.noError);
            traffic = true;
        }
        ptrdiff_t n;
        while ((n = p.server.streamRead(sid, rb[], fin)) > 0)
        {
            assert(rb[0 .. n] == payload[received .. received + n]);
            received += n;
        }
        if (p.server.pollTransmit(dg[], p.now, len) && len > 0)
        {
            assert(len <= 1200, "server datagram exceeds 1200 bytes");
            assert(p.client.handleDatagram(dg[0 .. len], p.now) == TransportErrorCode.noError);
            traffic = true;
        }
        p.now += 1000;
        if (!traffic && fin)
            break;
    }
    assert(fin && received == payload.length);
    assert(datagrams >= payload.length / 1200);

    // Defence in depth: should a peer limit below 1200 ever be stored (the TP decoder rejects
    // it, RFC 9000 Section 18.2), the packer still honours it instead of the 1200 default.
    {
        TestConnPair q;
        assert(initTestConnPair(q));
        q.client.peerParams.maxUdpPayloadSize = 1000;
        StreamId qsid;
        assert(q.client.openStream(StreamDirection.bidirectional,
                qsid) == TransportErrorCode.noError);
        ubyte[4000] data;
        assert(q.client.streamWrite(qsid, data[], false));
        size_t qlen;
        size_t seen;
        while (q.client.pollTransmit(dg[], q.now, qlen) && qlen > 0)
        {
            assert(qlen <= 1000, "peer max_udp_payload_size ignored");
            seen++;
            if (seen > 50)
                break;
        }
        assert(seen > 0);
    }

    // The client Initial still fills 1200 bytes (RFC 9000 Section 14.1).
    TlsContext cctx = TlsContext.createClientInsecure();
    QuicConnection fresh;
    TransportParameters tp;
    const ubyte[8] d = [1, 2, 3, 4, 5, 6, 7, 8];
    assert(QuicConnection.create(Side.client, cctx, ConnectionId(d[0 .. 4]),
            ConnectionId(d[]), tp, p.now, fresh));
    assert(fresh.pollTransmit(dg[], p.now, len) && len == 1200);
}

/// Example:
/// ---
/// TlsContext verifying = TlsContext.createClient();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// ConnectionId dcid = ConnectionId(dcidBytes[]);
/// ConnectionId scid = ConnectionId(scidBytes[]);
/// TransportParameters tp;
/// QuicConnection conn;
/// assert(!QuicConnection.create(Side.client, verifying, scid, dcid, tp, 1_000_000, conn));   // no name
/// assert(QuicConnection.create(Side.client, verifying, scid, dcid, tp, 1_000_000, conn,
///         false, null, "h3", "example.com"));                                               // with one
/// ---
// Spec: RFC 9001 Section 4.4 / RFC 6125 Section 6 - a verifying client connection cannot be
// created without a server name; creation fails cleanly and a later create() on the same
// object succeeds (R-06, W2, D2)
@nogc unittest
{
    TlsContext verifying = TlsContext.createClient();
    assert(verifying.isValid);
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);
    TransportParameters tp;
    tp.initialMaxData = 1_000_000;

    QuicConnection conn;
    assert(!QuicConnection.create(Side.client, verifying, scid, dcid, tp, 1_000_000, conn));
    assert(!QuicConnection.create(Side.client, verifying, scid, dcid, tp,
            1_000_000, conn, false, null, "h3", ""));
    assert(QuicConnection.create(Side.client, verifying, scid, dcid, tp,
            1_000_000, conn, false, null, "h3", "example.com"));
}

/// Example:
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
/// assert(deliverFlight(client, server, now));
/// now += 10_000;
/// assert(deliverFlight(server, client, now));      // the server's first flight reaches the client
/// // The client's third flight is a single datagram: Initial ACK + Handshake Finished,
/// // padded inside the Initial so the datagram reaches 1200 bytes.
/// ubyte[4096] dg;
/// size_t len;
/// now += 10_000;
/// assert(client.pollTransmit(dg[], now, len) && len == 1200);
/// ---
// Spec: RFC 9000 Section 12.2 (coalescing) & Section 14.1 (datagrams carrying Initial packets
// are expanded to 1200 bytes; PADDING sits inside a packet, not after it) (M1, plan R-05)
@nogc unittest
{
    TlsContext serverCtx = loadTestServerCtx();
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);

    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    const ConnectionId dcid = ConnectionId(dcidBytes[]);
    const ConnectionId scid = ConnectionId(scidBytes[]);

    TransportParameters tp;
    tp.hasInitialSourceConnectionId = true;
    tp.initialSourceConnectionId = scid;
    tp.initialMaxData = 1_000_000;
    tp.initialMaxStreamsBidi = 10;
    TransportParameters serverTp = tp;
    serverTp.hasOriginalDestinationConnectionId = true;
    serverTp.originalDestinationConnectionId = dcid;
    serverTp.initialSourceConnectionId = dcid;

    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, dcid,
            ConnectionId.init, serverTp, now, server));

    ubyte[4096] dg;
    size_t len = 0;
    assert(deliverFlight(client, server, now));

    // Server flight 2: its first datagram carries an ack-eliciting Initial (ServerHello), so
    // it is expanded to 1200 bytes as well (RFC 9000 Section 14.1).
    now += 10_000;
    assert(server.pollTransmit(dg[], now, len));
    assert(len == 1200, "server ack-eliciting Initial datagram must be 1200 bytes");
    assert(client.handleDatagram(dg[0 .. len], now) == TransportErrorCode.noError);
    deliverFlight(server, client, now); // rest of the server flight, if any

    // Flight 3: one datagram, Initial (ACK) + Handshake, padded to exactly 1200 bytes.
    now += 10_000;
    assert(client.pollTransmit(dg[], now, len));
    assert(len == 1200 && len <= client.maxDatagramSize);
    bool sawInitial = false;
    bool sawHandshake = false;
    size_t packets = 0;
    CoalescedPacketIterator iter = CoalescedPacketIterator(dg[0 .. len], 8);
    const(ubyte)[] pkt;
    PacketPrefix pfx;
    WireError we = WireError.none;
    size_t consumed = 0;
    while (iter.next(pkt, pfx, we))
    {
        consumed += pkt.length;
        packets++;
        sawInitial = sawInitial || pfx.type == PacketType.initial;
        sawHandshake = sawHandshake || pfx.type == PacketType.handshake;
    }
    assert(we == WireError.none);
    assert(sawInitial && sawHandshake && packets == 2, "Initial and Handshake must be coalesced");
    assert(consumed == len, "no trailing bytes: padding lives inside the Initial packet");
    assert(server.handleDatagram(dg[0 .. len], now) == TransportErrorCode.noError);
    assert(server.peerAddressValidated);
    assert(!client.pollTransmit(dg[], now, len) || len == 0 || (dg[0] & 0x80) == 0,
            "flight 3 must not need a second long-header datagram");
}

/// Builds a server-to-client Initial datagram (padded to 1200 bytes) carrying `frame` as its
/// only frame, sealed with the client's Initial read keys, which equal the server's write keys.
private size_t forgeServerInitial(ref QuicConnection client,
        const ConnectionId serverScid, ulong pn, ref const Frame frame, ubyte[] outBuf) @trusted @nogc nothrow
{
    ubyte[1200] payload;
    size_t frameLen = 0;
    if (encodeFrame(frame, payload[], frameLen) != WireError.none)
        return 0;
    const size_t plainLen = 1100;
    payload[frameLen .. plainLen] = 0; // PADDING
    size_t pnOff = 0;
    size_t hdrLen = 0;
    if (encodeLongHeader(PacketType.initial, QUIC_VERSION_1, client.localCid,
            serverScid, null, pn, 2, plainLen, outBuf, pnOff, hdrLen) != WireError.none)
        return 0;
    outBuf[hdrLen .. hdrLen + plainLen] = payload[0 .. plainLen];
    size_t protLen = 0;
    if (protectPacket(client.levelKeys[0].remote, pn, pnOff, 2, outBuf,
            plainLen, protLen) != QuicCryptoError.none)
        return 0;
    return protLen;
}

/// Example:
/// ---
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// const ubyte[12] aBytes = [0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab];
/// const ubyte[12] bBytes = [0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb];
/// const ConnectionId a = ConnectionId(aBytes[]);
/// const ConnectionId b = ConnectionId(bBytes[]);
/// TransportParameters tp;
/// const ulong now = 1_000_000;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidBytes[]),
///         ConnectionId(dcidBytes[]), tp, now, client));
/// Frame ping;
/// ping.type = FrameType.ping;
/// ubyte[1500] fromA, fromB;
/// const size_t lenA = forgeServerInitial(client, a, 0, ping, fromA[]);
/// const size_t lenB = forgeServerInitial(client, b, 5, ping, fromB[]);
/// // the first server Initial (SCID a) is adopted; an Initial from SCID b is then ignored
/// assert(client.handleDatagram(fromA[0 .. lenA], now) == TransportErrorCode.noError);
/// assert(client.handleDatagram(fromB[0 .. lenB], now) == TransportErrorCode.noError);
/// assert(client.remoteCid == a && !client.ackRanges[0].contains(5));
/// ---
// Spec: RFC 9000 Section 7.2 - "Once a client has received a valid Initial packet from the
// server, it MUST discard any subsequent packet it receives on that connection with a
// different Source Connection ID."; the DCID switch is committed only after the first Initial was accepted
// (L3, Sec L-3)
@nogc unittest
{
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(clientCtx.isValid);
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    const ubyte[12] aBytes = [
        0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab
    ];
    const ubyte[12] bBytes = [
        0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb
    ];
    const ConnectionId dcid = ConnectionId(dcidBytes[]);
    const ConnectionId scid = ConnectionId(scidBytes[]);
    const ConnectionId idA = ConnectionId(aBytes[]);
    const ConnectionId idB = ConnectionId(bBytes[]);
    TransportParameters tp;
    ulong now = 1_000_000;

    Frame ping;
    ping.type = FrameType.ping;
    ubyte[1500] dg;

    // A rejected first Initial (forbidden STREAM frame) must not redirect the connection.
    {
        QuicConnection client;
        assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
        Frame bad;
        bad.type = FrameType.stream;
        bad.stream.streamId = 0;
        bad.stream.data = cast(const(ubyte)[]) "forbidden";
        bad.stream.hasLength = true;
        size_t n = forgeServerInitial(client, idB, 0, bad, dg[]);
        assert(n > 0);
        assert(client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.protocolViolation);
        assert(!client.serverCidAdopted, "a rejected Initial must not commit the SCID switch");
        assert(client.remoteCid == dcid);
    }

    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
    size_t n = forgeServerInitial(client, idA, 0, ping, dg[]);
    assert(n > 0 && client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);
    assert(client.serverCidAdopted && client.remoteCid == idA);

    // Initial from a different SCID: discarded without error and without any state change.
    n = forgeServerInitial(client, idB, 5, ping, dg[]);
    assert(n > 0 && client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);
    assert(client.remoteCid == idA);
    assert(!client.ackRanges[0].contains(5), "foreign-SCID Initial must be discarded");

    // Control: the same packet number from the adopted SCID is processed.
    n = forgeServerInitial(client, idA, 5, ping, dg[]);
    assert(n > 0 && client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);
    assert(client.ackRanges[0].contains(5));
}

/// Creates an unconnected client/server pair with transport parameters that satisfy the
/// handshake checks.
private bool makeHandshakePair(ref TlsContext serverCtx, ref TlsContext clientCtx,
        out QuicConnection client, out QuicConnection server, ulong now) @trusted @nogc nothrow
{
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    const ConnectionId dcid = ConnectionId(dcidBytes[]);
    const ConnectionId scid = ConnectionId(scidBytes[]);
    TransportParameters tp;
    tp.hasInitialSourceConnectionId = true;
    tp.initialSourceConnectionId = scid;
    tp.initialMaxData = 1_000_000;
    tp.initialMaxStreamsBidi = 10;
    TransportParameters serverTp = tp;
    serverTp.hasOriginalDestinationConnectionId = true;
    serverTp.originalDestinationConnectionId = dcid;
    serverTp.initialSourceConnectionId = dcid;
    return QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now,
            client) && QuicConnection.create(Side.server, serverCtx, dcid,
            ConnectionId.init, serverTp, now, server);
}

/// Example:
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
/// ubyte[4096] small, full;
/// size_t len;
/// assert(!client.pollTransmit(small[0 .. 200], now, len));   // an Initial cannot fit: no-op
/// assert(client.pollTransmit(full[], now, len) && len == 1200);   // CRYPTO starts at offset 0
/// ---
// Spec: RFC 9000 Section 14.1 (a client Initial datagram is at least 1200 bytes) and
// RFC 9001 Section 4.1.3 (CRYPTO data is delivered reliably and in full): a poll with a buffer
// that cannot hold the Initial must not consume CRYPTO bytes (Round 2 item 1a)
@nogc unittest
{
    TlsContext serverCtx = loadTestServerCtx();
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));

    ubyte[4096] buf;
    size_t len = 0;
    foreach (small; [0, 1, 50, 200, 1199])
    {
        assert(!client.pollTransmit(buf[0 .. small], now, len), "no datagram fits");
        assert(len == 0);
    }
    assert(client.nextPn[0] == 0, "nothing was sent");
    assert(client.cryptoSend[0].hasPendingBytes);

    // The next full-size poll starts at CRYPTO offset 0 and the handshake completes: no byte
    // range of the ClientHello was skipped.
    assert(client.pollTransmit(buf[], now, len) && len == 1200);
    assert(client.cryptoSend[0].writeOffset > 0);
    assert(server.handleDatagram(buf[0 .. len], now) == TransportErrorCode.noError);
    assert(server.cryptoRecv[0].highestReceivedOffset > 0,
            "server must have received CRYPTO from offset 0");
    assert(deliverFlight(client, server, now)); // rest of the ClientHello, if any
    assert(exchangeUntilQuiet(client, server, now));
    assert(client.handshakeConfirmed && server.handshakeConfirmed);
}

/// Example:
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
/// assert(deliverFlight(client, server, now));
/// ubyte[1200] buf;
/// size_t len;
/// server.totalBytesSent = 3 * server.totalBytesReceived - 100;   // only 100 bytes of budget left
/// assert(server.pollTransmit(buf[], now, len) && len <= 100);    // partial CRYPTO, none lost
/// assert(server.cryptoSend[0].hasPendingBytes);                  // the rest stays queued
/// ---
// Spec: RFC 9000 Section 8.1 (a server sends at most three times the bytes it received before
// validating the address) and RFC 9001 Section 4.1.3 (CRYPTO data is delivered in full): an
// Initial that does not fit the remaining budget is split, never dropped (Round 2 item 1b)
@nogc unittest
{
    TlsContext serverCtx = loadTestServerCtx();
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));

    // Client flight 1, kept so it can be repeated later (a retransmission).
    ubyte[1200][4] flight;
    size_t[4] flightLen;
    size_t flights = 0;
    ubyte[1200] tmp;
    size_t len = 0;
    while (flights < 4 && client.pollTransmit(tmp[], now, len) && len > 0)
    {
        flight[flights][0 .. len] = tmp[0 .. len];
        flightLen[flights] = len;
        assert(server.handleDatagram(tmp[0 .. len], now) == TransportErrorCode.noError);
        flights++;
    }
    assert(flights > 0);

    // The server has received `flights * 1200` bytes; leave it only 100 bytes of budget, as
    // after an earlier (lost) flight. Its Initial (ServerHello + ACK) does not fit.
    server.totalBytesSent = 3 * server.totalBytesReceived - 100;
    now += 10_000;
    size_t sent = 0;
    while (server.pollTransmit(tmp[], now, len) && len > 0)
    {
        assert(len <= 100, "must respect the remaining amplification budget");
        sent += len;
        assert(client.handleDatagram(tmp[0 .. len], now) == TransportErrorCode.noError);
    }
    assert(sent > 0 && sent <= 100);
    assert(server.cryptoSend[0].hasPendingBytes,
            "the part of the ServerHello that did not fit must still be queued");

    // The client repeats flight 1 (counted by the server's budget although the packets are
    // duplicates); the budget grows and the rest of the handshake data flows.
    foreach (i; 0 .. flights)
        assert(server.handleDatagram(flight[i][0 .. flightLen[i]], now) == TransportErrorCode
                .noError);
    assert(exchangeUntilQuiet(server, client, now));
    assert(exchangeUntilQuiet(client, server, now));
    assert(client.handshakeConfirmed, "no CRYPTO range may have been lost");
    assert(server.handshakeConfirmed || server.hasReadKeys[3]);
}

/// Builds a server-to-client long-header packet of `type`, sealed with the client's read keys of
/// `level`, carrying `frame` plus PADDING.
private size_t forgeServerLongPacket(ref QuicConnection client, PacketType type,
        size_t level, const ConnectionId serverScid, ulong pn, ref const Frame frame, ubyte[] outBuf) @trusted @nogc nothrow
{
    ubyte[1200] payload;
    size_t frameLen = 0;
    if (encodeFrame(frame, payload[], frameLen) != WireError.none)
        return 0;
    const size_t plainLen = 100;
    payload[frameLen .. plainLen] = 0;
    size_t pnOff = 0;
    size_t hdrLen = 0;
    if (encodeLongHeader(type, QUIC_VERSION_1, client.localCid, serverScid,
            null, pn, 2, plainLen, outBuf, pnOff, hdrLen) != WireError.none)
        return 0;
    outBuf[hdrLen .. hdrLen + plainLen] = payload[0 .. plainLen];
    size_t protLen = 0;
    if (protectPacket(client.levelKeys[level].remote, pn, pnOff, 2, outBuf,
            plainLen, protLen) != QuicCryptoError.none)
        return 0;
    return protLen;
}

/// Example:
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
/// assert(deliverFlight(client, server, now));
/// assert(deliverFlight(server, client, now));      // the client adopts the server's SCID
/// const ubyte[12] bBytes = [0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb];
/// Frame ping;
/// ping.type = FrameType.ping;
/// ubyte[1500] foreign;
/// const size_t n = forgeServerLongPacket(client, PacketType.handshake, 2,
///         ConnectionId(bBytes[]), 900, ping, foreign[]);
/// // a Handshake packet from a different SCID is dropped without effect
/// assert(client.handleDatagram(foreign[0 .. n], now) == TransportErrorCode.noError);
/// assert(!client.ackRanges[1].contains(900));
/// ---
// Spec: RFC 9000 Section 7.2 - "Once a client has received a valid Initial packet from the
// server, it MUST discard any subsequent packet it receives on that connection with a
// different Source Connection ID." - applies to Handshake packets too (Round 2 item 6)
@nogc unittest
{
    TlsContext serverCtx = loadTestServerCtx();
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
    assert(deliverFlight(client, server, now));
    assert(deliverFlight(server, client, now));
    assert(client.serverCidAdopted && client.hasReadKeys[2]);

    const ubyte[12] bBytes = [
        0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb
    ];
    const ConnectionId idB = ConnectionId(bBytes[]);
    Frame ping;
    ping.type = FrameType.ping;
    ubyte[1500] dg;

    const ConnectionId adopted = client.remoteCid;
    size_t n = forgeServerLongPacket(client, PacketType.handshake, 2, idB, 900, ping, dg[]);
    assert(n > 0 && client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);
    assert(!client.ackRanges[1].contains(900), "foreign-SCID Handshake packet must be discarded");
    assert(client.remoteCid == adopted);

    // Control: the same packet from the adopted SCID is processed.
    n = forgeServerLongPacket(client, PacketType.handshake, 2, adopted, 900, ping, dg[]);
    assert(n > 0 && client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);
    assert(client.ackRanges[1].contains(900));
}

/// Example:
/// ---
/// import slate.quic.crypto.aead : computeRetryIntegrityTag;
///
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// const ubyte[8] aBytes = [0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7];
/// const ubyte[8] rBytes = [0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7];
/// const ConnectionId dcid = ConnectionId(dcidBytes[]);
/// const ConnectionId scid = ConnectionId(scidBytes[]);
/// TransportParameters tp;
/// const ulong now = 1_000_000;
/// // a Retry packet carrying a correct integrity tag for the client's original DCID
/// ubyte[128] retry;
/// size_t r;
/// retry[r++] = 0xf0;
/// retry[r .. r + 4] = [0, 0, 0, 1];                // version 1
/// r += 4;
/// retry[r++] = cast(ubyte) scid.len;
/// retry[r .. r + scid.len] = scid.asSlice();
/// r += scid.len;
/// retry[r++] = cast(ubyte) rBytes.length;
/// retry[r .. r + rBytes.length] = rBytes[];
/// r += rBytes.length;
/// retry[r .. r + 5] = cast(const(ubyte)[]) "token";
/// r += 5;
/// ubyte[16] tag;
/// assert(computeRetryIntegrityTag(dcid.asSlice(), retry[0 .. r], tag));
/// retry[r .. r + 16] = tag[];
/// r += 16;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
/// Frame ping;
/// ping.type = FrameType.ping;
/// ubyte[1500] dg;
/// const size_t n = forgeServerInitial(client, ConnectionId(aBytes[]), 0, ping, dg[]);
/// assert(client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);   // first server Initial
/// // a valid Retry after the first server Initial is discarded
/// assert(client.handleDatagram(retry[0 .. r], now) == TransportErrorCode.noError);
/// assert(!client.retryReceived && client.retryTokenLen == 0);
/// ---
// Spec: RFC 9000 Section 17.2.5.2 - "After the client has received and processed an Initial or
// Retry packet from the server, it MUST discard any subsequent Retry packets that it
// receives." (Round 2 item 5)
@nogc unittest
{
    import slate.quic.crypto.aead : computeRetryIntegrityTag;

    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(clientCtx.isValid);
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    const ubyte[8] aBytes = [0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7];
    const ubyte[8] rBytes = [0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7];
    const ConnectionId dcid = ConnectionId(dcidBytes[]);
    const ConnectionId scid = ConnectionId(scidBytes[]);
    const ConnectionId idA = ConnectionId(aBytes[]);
    TransportParameters tp;
    ulong now = 1_000_000;

    // Retry packet with a correct Retry Integrity Tag for the client's original DCID.
    ubyte[128] retry;
    size_t r = 0;
    retry[r++] = 0xf0;
    retry[r++] = 0;
    retry[r++] = 0;
    retry[r++] = 0;
    retry[r++] = 1;
    retry[r++] = cast(ubyte) scid.len;
    retry[r .. r + scid.len] = scid.asSlice();
    r += scid.len;
    retry[r++] = cast(ubyte) rBytes.length;
    retry[r .. r + rBytes.length] = rBytes[];
    r += rBytes.length;
    retry[r .. r + 5] = cast(const(ubyte)[]) "token";
    r += 5;
    ubyte[16] tag;
    assert(computeRetryIntegrityTag(dcid.asSlice(), retry[0 .. r], tag));
    retry[r .. r + 16] = tag[];
    r += 16;

    // Control: before any server Initial the very same Retry is accepted.
    {
        QuicConnection control;
        assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, control));
        assert(control.handleDatagram(retry[0 .. r], now) == TransportErrorCode.noError);
        assert(control.retryReceived && control.retryTokenLen == 5);
    }

    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
    Frame ping;
    ping.type = FrameType.ping;
    ubyte[1500] dg;
    const size_t n = forgeServerInitial(client, idA, 0, ping, dg[]);
    assert(n > 0 && client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);
    assert(client.serverCidAdopted);

    assert(client.handleDatagram(retry[0 .. r], now) == TransportErrorCode.noError);
    assert(!client.retryReceived && client.retryTokenLen == 0, "late Retry must be ignored");
    assert(client.remoteCid == idA, "late Retry must not redirect the connection");
}

/// Example:
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection clientA, serverA;                 // connection A only supplies a 1-RTT packet
/// assert(makeHandshakePair(serverCtx, clientCtx, clientA, serverA, now));
/// assert(exchangeUntilQuiet(clientA, serverA, now));
/// const ubyte[8] challenge = [1, 2, 3, 4, 5, 6, 7, 8];
/// clientA.sendPathChallenge(challenge);
/// ubyte[1200] oneRtt;
/// size_t n;
/// assert(clientA.pollTransmit(oneRtt[], now, n) && n > 0);
/// QuicConnection clientB, serverB;                 // B has seen the first flight only
/// TlsContext serverCtx2 = loadTestServerCtx();
/// TlsContext clientCtx2 = TlsContext.createClientInsecure();
/// assert(makeHandshakePair(serverCtx2, clientCtx2, clientB, serverB, now));
/// assert(deliverFlight(clientB, serverB, now) && !serverB.tls.isHandshakeComplete);
/// serverB.levelKeys[3].remote.moveFrom(clientA.levelKeys[3].local);   // keys that open A's packet
/// serverB.hasReadKeys[3] = true;
/// assert(serverB.handleDatagram(oneRtt[0 .. n], now) == TransportErrorCode.noError);
/// assert(!serverB.handshakeConfirmed);             // dropped, not processed
/// ---
// Spec: RFC 9001 Section 5.7 and Section 4.1.2 - a server does not process 1-RTT packets until its
// handshake is complete and only then confirms the handshake (R-15, S3)
@nogc unittest
{
    TlsContext serverCtx = loadTestServerCtx();
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    ulong now = 1_000_000;

    // Connection A completes a handshake; it only supplies a well-formed 1-RTT packet.
    QuicConnection clientA;
    QuicConnection serverA;
    assert(makeHandshakePair(serverCtx, clientCtx, clientA, serverA, now));
    assert(exchangeUntilQuiet(clientA, serverA, now));
    assert(clientA.handshakeConfirmed);
    const ubyte[8] challenge = [1, 2, 3, 4, 5, 6, 7, 8];
    clientA.sendPathChallenge(challenge);
    ubyte[1200] oneRtt;
    size_t n = 0;
    now += 1000;
    assert(clientA.pollTransmit(oneRtt[], now, n) && n > 0);
    assert((oneRtt[0] & 0x80) == 0, "short header packet");

    // Connection B (same CIDs) has only seen the client's first flight; the server is mid-handshake
    // and, for the test, holds the keys that open A's packet.
    TlsContext serverCtx2 = loadTestServerCtx();
    TlsContext clientCtx2 = TlsContext.createClientInsecure();
    QuicConnection clientB;
    QuicConnection serverB;
    assert(makeHandshakePair(serverCtx2, clientCtx2, clientB, serverB, now));
    ubyte[1200] first;
    size_t fl = 0;
    assert(clientB.pollTransmit(first[], now, fl) && fl > 0);
    assert(serverB.handleDatagram(first[0 .. fl], now) == TransportErrorCode.noError);
    assert(!serverB.tls.isHandshakeComplete);
    serverB.levelKeys[3].remote.moveFrom(clientA.levelKeys[3].local);
    serverB.hasReadKeys[3] = true;

    assert(serverB.handleDatagram(oneRtt[0 .. n], now) == TransportErrorCode.noError);
    assert(!serverB.handshakeConfirmed, "an unauthenticated 1-RTT packet must not confirm");
    assert(!serverB.hasPendingPathResponse, "its frames must not be processed");
    assert(!serverB.ackRanges[2].contains(0), "and it is not acknowledged");
}

/// Builds a Retry packet (RFC 9000 Section 17.2.5) with a valid integrity tag for `odcid`.
private size_t buildRetryPacket(const ConnectionId odcid, const ConnectionId clientCid,
        const ConnectionId retryScid, const(ubyte)[] token, ubyte[] outBuf) @trusted @nogc nothrow
{
    import slate.quic.crypto.aead : computeRetryIntegrityTag;

    size_t r = 0;
    outBuf[r++] = 0xf0;
    outBuf[r++] = 0;
    outBuf[r++] = 0;
    outBuf[r++] = 0;
    outBuf[r++] = 1;
    outBuf[r++] = cast(ubyte) clientCid.len;
    outBuf[r .. r + clientCid.len] = clientCid.asSlice();
    r += clientCid.len;
    outBuf[r++] = cast(ubyte) retryScid.len;
    outBuf[r .. r + retryScid.len] = retryScid.asSlice();
    r += retryScid.len;
    outBuf[r .. r + token.length] = token[];
    r += token.length;
    ubyte[16] tag;
    if (!computeRetryIntegrityTag(odcid.asSlice(), outBuf[0 .. r], tag))
        return 0;
    outBuf[r .. r + 16] = tag[];
    return r + 16;
}

/// Example:
/// ---
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// const ubyte[8] r1Bytes = [0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7];
/// const ubyte[8] r2Bytes = [0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7];
/// const ConnectionId dcid = ConnectionId(dcidBytes[]);
/// const ConnectionId scid = ConnectionId(scidBytes[]);
/// TransportParameters tp;
/// const ulong now = 1_000_000;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
/// ubyte[128] retry1, retry2;
/// const n1 = buildRetryPacket(dcid, scid, ConnectionId(r1Bytes[]), cast(const(ubyte)[]) "token-1", retry1[]);
/// const n2 = buildRetryPacket(dcid, scid, ConnectionId(r2Bytes[]), cast(const(ubyte)[]) "token-2", retry2[]);
/// assert(client.handleDatagram(retry1[0 .. n1], now) == TransportErrorCode.noError);   // accepted
/// const firstRetryScid = client.retryScid;
/// assert(client.handleDatagram(retry2[0 .. n2], now) == TransportErrorCode.noError);   // discarded
/// assert(client.retryScid == firstRetryScid);
/// ---
// Spec: RFC 9000 Section 17.2.5.2 - "A client MUST accept and process at most one Retry packet
// for each connection attempt." and "After the client has received and processed an Initial or
// Retry packet from the server, it MUST discard any subsequent Retry packets that it
// receives." (R-17, W5)
@nogc unittest
{
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(clientCtx.isValid);
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    const ubyte[8] r1Bytes = [0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7];
    const ubyte[8] r2Bytes = [0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7];
    const ConnectionId dcid = ConnectionId(dcidBytes[]);
    const ConnectionId scid = ConnectionId(scidBytes[]);
    const ConnectionId r1 = ConnectionId(r1Bytes[]);
    const ConnectionId r2 = ConnectionId(r2Bytes[]);
    TransportParameters tp;
    const ulong now = 1_000_000;

    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));

    ubyte[128] retry1;
    ubyte[128] retry2;
    const n1 = buildRetryPacket(dcid, scid, r1, cast(const(ubyte)[]) "token-1", retry1[]);
    const n2 = buildRetryPacket(dcid, scid, r2, cast(const(ubyte)[]) "token-2", retry2[]);
    assert(n1 > 0 && n2 > 0);

    assert(client.handleDatagram(retry1[0 .. n1], now) == TransportErrorCode.noError);
    assert(client.retryReceived && client.retryScid == r1 && client.retryTokenLen == 7);
    assert(client.state != ConnectionState.closing && client.state != ConnectionState.draining);

    // The second (otherwise valid) Retry is dropped without an error or any state change.
    assert(client.handleDatagram(retry2[0 .. n2], now) == TransportErrorCode.noError);
    assert(client.retryScid == r1 && client.remoteCid == r1);
    assert(client.retryTokenBuf[0 .. client.retryTokenLen] == cast(const(ubyte)[]) "token-1");
    assert(client.state != ConnectionState.closing && client.state != ConnectionState.draining);
}

/// Example:
/// ---
/// TestConnPair pair;
/// assert(initTestConnPair(pair));
/// StreamId sid;
/// assert(pair.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(pair.client.streamWrite(sid, cast(const(ubyte)[]) "hello", false));
///
/// // Fill the ledger with unresolved 1-RTT packets.
/// const SentFrameDesc[1] ping = [SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false)];
/// foreach (i; 0 .. MAX_TRACKED_PACKETS_PER_SPACE)
///     assert(pair.client.sentFrames.recordPacket(PacketNumberSpace.applicationData, 1_000_000 + i, ping[]));
/// pair.client.ackRanges[2].onAckSent();   // no ACK owed: only the stream data is pending
///
/// ubyte[1500] buf;
/// size_t n;
/// assert(!pair.client.pollTransmit(buf[], pair.now, n));   // nothing is sent untracked
/// assert(pair.client.streams.hasPendingWritable);          // the data stays queued
/// ---
// Spec: RFC 9000 Section 13.3 - STREAM data must be retransmitted when lost, which needs a ledger
// entry per ack-eliciting packet; with a full ledger the packer sends nothing rather than
// sending frames that could never be retransmitted (R-18, W6)
@nogc unittest
{
    import slate.quic.connection.sent_frames : SentFrameDesc, SentFrameKind,
        SentPacketRecord, MAX_TRACKED_PACKETS_PER_SPACE;

    TestConnPair pair;
    assert(initTestConnPair(pair));
    StreamId sid;
    assert(pair.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    const ubyte[5] data = [1, 2, 3, 4, 5];
    assert(pair.client.streamWrite(sid, data[], false));

    const SentFrameDesc[1] ping = [
        SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false)
    ];
    foreach (i; 0 .. MAX_TRACKED_PACKETS_PER_SPACE)
        assert(pair.client.sentFrames.recordPacket(PacketNumberSpace.applicationData,
                1_000_000 + i, ping[]));

    pair.client.ackRanges[2].onAckSent(); // no ACK owed: only the stream data is pending
    ubyte[1500] buf;
    size_t n = 0;
    pair.now += 1000;
    assert(!pair.client.pollTransmit(buf[], pair.now, n), "must not send untracked frames");
    assert(n == 0);
    assert(pair.client.streams.hasPendingWritable, "stream data must stay queued");

    // Once a slot is released the data goes out and is tracked.
    SentPacketRecord rec;
    assert(pair.client.sentFrames.takePacket(PacketNumberSpace.applicationData, 1_000_000, rec));
    assert(pair.client.pollTransmit(buf[], pair.now, n) && n > 0);
    assert(!pair.client.streams.hasPendingWritable);
}

/// Example:
/// ---
/// TestConnPair pair;
/// assert(initTestConnPair(pair));
/// StreamId sid;
/// assert(pair.server.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(pair.server.streamWrite(sid, cast(const(ubyte)[]) "hello", false));
/// ubyte[1500] buf;
/// size_t n;
/// assert(pair.server.pollTransmit(buf[], pair.now, n) && n > 0);
/// assert(pair.client.handleDatagram(buf[0 .. n], pair.now) == TransportErrorCode.noError);
/// assert(pair.client.ackRanges[2].hasPendingAck);   // the client owes an ACK
///
/// // Fill the client's ledger and queue stream data behind it.
/// const SentFrameDesc[1] ping = [SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false)];
/// foreach (i; 0 .. MAX_TRACKED_PACKETS_PER_SPACE)
///     assert(pair.client.sentFrames.recordPacket(PacketNumberSpace.applicationData, 2_000_000 + i, ping[]));
/// StreamId csid;
/// assert(pair.client.openStream(StreamDirection.bidirectional, csid) == TransportErrorCode.noError);
/// assert(pair.client.streamWrite(csid, cast(const(ubyte)[]) "data", false));
///
/// assert(pair.client.pollTransmit(buf[], pair.now, n) && n > 0);   // the pure ACK still flows
/// assert(!pair.client.ackRanges[2].hasPendingAck && pair.client.streams.hasPendingWritable);
/// ---
// Spec: RFC 9000 Section 13.2.1 "An endpoint MUST acknowledge all ack-eliciting Initial and
// Handshake packets" - a full sent-frame ledger must not stop ACK-only packets (they carry
// nothing to retransmit), otherwise two endpoints with full ledgers deadlock (R-18, W6)
@nogc unittest
{
    import slate.quic.connection.sent_frames : SentFrameDesc, SentFrameKind,
        SentPacketRecord, MAX_TRACKED_PACKETS_PER_SPACE;

    TestConnPair pair;
    assert(initTestConnPair(pair));
    StreamId sid;
    assert(pair.server.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    const ubyte[5] data = [1, 2, 3, 4, 5];
    assert(pair.server.streamWrite(sid, data[], false));
    ubyte[1500] buf;
    size_t n = 0;
    pair.now += 1000;
    assert(pair.server.pollTransmit(buf[], pair.now, n) && n > 0);
    assert(pair.client.handleDatagram(buf[0 .. n], pair.now) == TransportErrorCode.noError);
    assert(pair.client.ackRanges[2].hasPendingAck, "the client owes an ACK");

    // Fill the client's ledger completely.
    const SentFrameDesc[1] ping = [
        SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false)
    ];
    foreach (i; 0 .. MAX_TRACKED_PACKETS_PER_SPACE)
        assert(pair.client.sentFrames.recordPacket(PacketNumberSpace.applicationData,
                2_000_000 + i, ping[]));
    StreamId csid;
    assert(pair.client.openStream(StreamDirection.bidirectional, csid) == TransportErrorCode
            .noError);
    assert(pair.client.streamWrite(csid, data[], false));

    pair.now += 1000;
    assert(pair.client.pollTransmit(buf[], pair.now, n) && n > 0,
            "the ACK is sent although the ledger is full");
    assert(!pair.client.ackRanges[2].hasPendingAck);
    assert(pair.client.streams.hasPendingWritable, "tracked stream data stays queued");
    assert(pair.server.handleDatagram(buf[0 .. n], pair.now) == TransportErrorCode.noError);
    assert(!pair.client.pollTransmit(buf[], pair.now, n), "nothing else may be sent untracked");
}

/// Example:
/// ---
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
/// assert(deliverFlight(client, server, now));
/// server.drainTls();
/// server.totalBytesSent = 3 * server.totalBytesReceived - 1000;   // budget 1000 < 1200
/// ubyte[1500] buf;
/// size_t n;
/// // the ServerHello Initial waits, Handshake packets still go out
/// assert(server.pollTransmit(buf[], now, n) && ((buf[0] & 0x30) >> 4) == 2);
/// server.totalBytesReceived += 1200;               // more client bytes arrive
/// // now the Initial is sent, padded to 1200 bytes
/// assert(server.pollTransmit(buf[], now + 1000, n) && n >= 1200);
/// ---
// Spec: RFC 9000 Section 14.1 - "a server MUST expand the payload of all UDP datagrams carrying
// ack-eliciting Initial packets to at least the smallest allowed maximum datagram size of 1200
// bytes." Within the Section 8.1 amplification budget that is impossible below 1200 bytes, so the
// server waits instead of sending an unpadded Initial (PB-3)
@nogc unittest
{
    TlsContext serverCtx = loadTestServerCtx();
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
    ubyte[1500] buf;
    size_t n = 0;
    // The whole ClientHello (it may span two datagrams) reaches the server.
    assert(deliverFlight(client, server, now));
    server.drainTls();
    assert(server.cryptoSend[0].hasPendingBytes, "the ServerHello is queued");
    assert(!server.peerAddressValidated);

    // Leave exactly 1000 bytes of amplification budget.
    server.totalBytesSent = 3 * server.totalBytesReceived - 1000;
    assert(server.amplificationBudget() == 1000);
    now += 1000;
    n = 0;
    assert(server.pollTransmit(buf[], now, n), "Handshake data is not held back");
    assert(n <= 1000);
    assert((buf[0] & 0x80) != 0 && ((buf[0] & 0x30) >> 4) == 2,
            "a Handshake packet, no Initial below the padding threshold");
    assert(server.cryptoSend[0].hasPendingBytes, "the Initial CRYPTO data stays queued");

    // With budget for a full datagram the Initial goes out padded to 1200 bytes.
    server.totalBytesReceived += 1200;
    now += 1000;
    assert(server.pollTransmit(buf[], now, n) && n >= 1200);
    assert((buf[0] & 0x80) != 0 && ((buf[0] & 0x30) >> 4) == 0, "Initial first");
}

/// Example:
/// ---
/// import slate.quic.connection.packet_packer : PendingInitial;
///
/// TlsContext serverCtx = loadTestServerCtx();
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
/// assert(deliverFlight(client, server, now));
/// server.drainTls();
/// ubyte[1500] buf;
/// size_t n;
/// while (server.cryptoSend[0].hasPendingBytes)     // drain the ServerHello: only the PING stays pending
///     assert(server.pollTransmit(buf[], now += 1000, n));
/// server.ackRanges[0].onAckSent();
/// server.pingQueued = true;
/// PendingInitial pi;
/// assert(server.buildInitialPacket(pi, now, 1200));
/// assert(pi.plainLen + pi.pnLen >= 4);             // the sample for header protection exists
/// ---
// Spec: RFC 9001 Section 5.4.2 - "packets are padded so that the combined lengths of the encoded
// packet number and protected payload is at least 4 bytes longer than the sample required for
// header protection": a lone PING in an Initial is padded to 3 bytes with a 1-byte packet number
// (PB-2)
@nogc unittest
{
    import slate.quic.connection.packet_packer : PendingInitial;

    TlsContext serverCtx = loadTestServerCtx();
    TlsContext clientCtx = TlsContext.createClientInsecure();
    ulong now = 1_000_000;
    QuicConnection client;
    QuicConnection server;
    assert(makeHandshakePair(serverCtx, clientCtx, client, server, now));
    ubyte[1500] buf;
    size_t n = 0;
    assert(deliverFlight(client, server, now));
    // Drain the ServerHello so that only the PING is pending.
    server.drainTls();
    while (server.cryptoSend[0].hasPendingBytes)
        assert(server.pollTransmit(buf[], now += 1000, n));
    server.ackRanges[0].onAckSent();
    server.pingQueued = true;

    PendingInitial pi;
    assert(server.buildInitialPacket(pi, now, 1200));
    assert(pi.frameCount == 1 && pi.pingPacked);
    assert(pi.plainLen + pi.pnLen >= 4);

    // It seals (header protection finds its sample) and the client opens it.
    size_t measured = 0;
    assert(server.measureInitialPacket(pi, buf[], measured));
    size_t sealed = 0;
    size_t restAt = 0;
    assert(server.sealInitialPacket(pi, buf[], 0, measured, 0, now, sealed, restAt));
    assert(sealed == measured);
    assert(client.handleDatagram(buf[0 .. sealed], now) == TransportErrorCode.noError);
    assert(client.ackRanges[0].contains(pi.pn), "the client authenticated and processed it");
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// p.client.lossDetector.rtt.smoothedRtt = 80_000;
/// p.client.lossDetector.rtt.rttVar = 10_000;
/// p.client.peerParamsReceived = true;
/// p.client.peerParams.maxAckDelay = 30;            // PTO = 80 + 4 * 10 + 30 = 150 ms
/// ubyte[1200] dgram;
/// size_t len;
/// const ulong now = 6_000_000;
/// p.client.close(0, true);
/// assert(p.client.pollTransmit(dgram[], now, len));
/// assert(p.client.drainingEndTimeMicros == now + 3 * 150_000);   // 3 * PTO, not 3 * smoothed RTT
/// ---
// Spec: RFC 9000 Section 10.2 "These states SHOULD persist for at least three
// times the current PTO interval as defined in [QUIC-RECOVERY]." - both the endpoint that sends CONNECTION_CLOSE
// and the one that receives it hold on for 3 * PTO (R-36, W18)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    p.client.lossDetector.rtt.smoothedRtt = 80_000;
    p.client.lossDetector.rtt.rttVar = 10_000;
    p.client.peerParamsReceived = true;
    p.client.peerParams.maxAckDelay = 30;
    // PTO = 80 ms + 4 * 10 ms + 30 ms = 150 ms, three of them = 450 ms (3 * SRTT would be 240 ms)
    assert(p.client.drainingEndFor(5_000_000) == 5_000_000 + 450_000);

    p.server.lossDetector.rtt.smoothedRtt = 50_000;
    p.server.lossDetector.rtt.rttVar = 5_000;
    p.server.peerParamsReceived = true;
    p.server.peerParams.maxAckDelay = 25;
    // PTO = 50 + 20 + 25 = 95 ms
    p.client.close(0, true);
    ubyte[1200] dg;
    size_t len;
    const ulong now = 6_000_000;
    assert(p.client.pollTransmit(dg[], now, len));
    assert(p.client.state == ConnectionState.draining);
    assert(p.client.drainingEndTimeMicros == now + 450_000, "sender holds on for 3 * PTO");
    assert(p.server.handleDatagram(dg[0 .. len], now) == TransportErrorCode.noError);
    assert(p.server.state == ConnectionState.draining);
    assert(p.server.drainingEndTimeMicros == now + 3 * 95_000, "receiver holds on for 3 * PTO");

    // Saturation: an absurd RTT cannot overflow the deadline.
    p.client.lossDetector.rtt.smoothedRtt = ulong.max / 2;
    assert(p.client.drainingEndFor(ulong.max - 1) == ulong.max);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "hello", false));
/// ubyte[1200] genuine;
/// size_t n;
/// assert(p.client.pollTransmit(genuine[], p.now, n));
/// ubyte[1200] tampered = genuine;
/// tampered[n - 1] ^= 0x5a;
/// const ulong t = p.server.lastRxTimeMicros;
/// p.server.handleDatagram(tampered[0 .. n], t + 900_000);   // fails authentication
/// assert(p.server.lastRxTimeMicros == t);                   // the idle timer did not restart
/// p.server.handleDatagram(genuine[0 .. n], t + 950_000);
/// assert(p.server.lastRxTimeMicros == t + 950_000);
/// ---
// Spec: RFC 9000 Section 10.1 "An endpoint restarts its idle timer when a packet from its peer
// is received and processed successfully." - a datagram that fails authentication must not keep
// the connection alive, otherwise an off-path attacker can prevent the idle timeout (R-37, W20)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "hello", false));
    ubyte[1200] dg;
    size_t n;
    assert(p.client.pollTransmit(dg[], p.now, n) && n > 0);
    ubyte[1200] tampered = dg;
    tampered[n - 1] ^= 0x5a;
    tampered[n - 2] ^= 0xa5;

    const ulong t = p.server.lastRxTimeMicros;
    assert(t > 0);
    assert(p.server.handleDatagram(tampered[0 .. n], t + 900_000) == TransportErrorCode.noError);
    assert(p.server.lastRxTimeMicros == t,
            "an unauthenticated datagram must not reset the idle timer");

    assert(p.server.handleDatagram(dg[0 .. n], t + 950_000) == TransportErrorCode.noError);
    assert(p.server.lastRxTimeMicros == t + 950_000, "a processed packet restarts the idle timer");

    // A duplicate is not new progress: it must not postpone the idle deadline either.
    assert(p.server.handleDatagram(dg[0 .. n], t + 990_000) == TransportErrorCode.noError);
    assert(p.server.lastRxTimeMicros == t + 950_000);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "AAAAA", false));
/// ubyte[4096] late, fresh;
/// size_t lateLen, freshLen;
/// p.now += 1000;
/// assert(p.client.pollTransmit(late[], p.now, lateLen));    // packet A, held back by the network
/// assert(p.client.initiateKeyUpdate());
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "BBBBB", false));
/// assert(p.client.pollTransmit(fresh[], p.now, freshLen));  // packet B, under the new keys
/// assert(p.server.handleDatagram(fresh[0 .. freshLen], p.now) == TransportErrorCode.noError);
/// // A arrives after the key update and is still opened with the retained previous key:
/// assert(p.server.handleDatagram(late[0 .. lateLen], p.now) == TransportErrorCode.noError);
/// ubyte[32] buf;
/// bool fin;
/// assert(p.server.streamRead(sid, buf[], fin) == 10);       // both packets' data, in order
/// ---
// Spec: RFC 9001 Section 6.5 "An endpoint SHOULD retain old read keys for no more than three
// times the PTO after having received a packet protected using the new keys." - a packet
// reordered behind the first packet of the new key phase is still decrypted with the retained
// previous key and its data is delivered (R-41, W23)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));

    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    // Packet A is built under key phase 0 but held back by the network.
    const ubyte[5] dataA = [1, 2, 3, 4, 5];
    assert(p.client.streamWrite(sid, dataA[], false));
    ubyte[4096] late;
    size_t lateLen;
    p.now += 1000;
    assert(p.client.pollTransmit(late[], p.now, lateLen));

    // Key update, then packet B under phase 1 overtakes A.
    assert(p.client.initiateKeyUpdate());
    const ubyte[5] dataB = [6, 7, 8, 9, 10];
    assert(p.client.streamWrite(sid, dataB[], false));
    ubyte[4096] fresh;
    size_t freshLen;
    p.now += 1000;
    assert(p.client.pollTransmit(fresh[], p.now, freshLen));
    assert(p.server.handleDatagram(fresh[0 .. freshLen], p.now) == TransportErrorCode.noError);
    assert(p.server.remoteKeyPhase == 1);
    ubyte[16] gapBuf;
    bool gapFin;
    assert(p.server.streamRead(sid, gapBuf[], gapFin) == 0, "B alone leaves a gap at offset 0");

    // A arrives now: protected with the phase-0 key, it must still open.
    p.now += 1000;
    assert(p.server.handleDatagram(late[0 .. lateLen], p.now) == TransportErrorCode.noError);
    ubyte[16] buf;
    bool fin;
    assert(p.server.streamRead(sid, buf[], fin) == 10, "A's bytes fill the gap before B's");
    assert(buf[0 .. 5] == dataA[] && buf[5 .. 10] == dataB[]);
    assert(p.server.remoteKeyPhase == 1, "a late old-phase packet does not flip the phase back");
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[4096] oldPhase, oldPhase2, underNewKey;
/// size_t n1, n2, n3;
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "aaa", false));
/// assert(p.client.pollTransmit(oldPhase[], p.now += 1000, n2));    // held back by the network
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "ccc", false));
/// assert(p.client.pollTransmit(oldPhase2[], p.now += 1000, n3));   // held back as well
/// assert(p.client.initiateKeyUpdate());
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "bb", false));
/// assert(p.client.pollTransmit(underNewKey[], p.now += 1000, n1));
/// const ulong t0 = p.now;
/// // the first packet under the new keys starts a 3 x PTO retention period for the old key
/// assert(p.server.handleDatagram(underNewKey[0 .. n1], t0) == TransportErrorCode.noError);
/// const ulong until = p.server.prevRemoteDiscardMicros;
/// assert(until == p.server.drainingEndFor(t0) && p.server.nextTimeoutMicros(t0) <= until);
/// assert(p.server.handleDatagram(oldPhase[0 .. n2], until - 1) == TransportErrorCode.noError);   // opens
/// p.server.onTimeout(until);
/// assert(!p.server.hasPrevRemoteAead);             // the old key is gone at the deadline
/// const ulong rx = p.server.lastRxTimeMicros;
/// assert(p.server.handleDatagram(oldPhase2[0 .. n3], until + 1) == TransportErrorCode.noError);
/// assert(p.server.lastRxTimeMicros == rx);         // dropped, not processed
/// ---
// Spec: RFC 9001 Section 6.5 "An endpoint SHOULD retain old read keys for no more than three
// times the PTO after having received a packet protected using the new keys. After this period,
// old read keys and their corresponding secrets SHOULD be discarded." - the retained key opens an
// old-phase packet before the deadline and is gone at 3 x PTO; the deadline is part of
// nextTimeoutMicros and is acted on by onTimeout (R-41, W23)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    // Two packets under key phase 0 that the network holds back.
    const ubyte[3] dataA = [1, 2, 3];
    const ubyte[3] dataC = [7, 8, 9];
    ubyte[4096] lateA;
    ubyte[4096] lateC;
    size_t lenA, lenC;
    assert(p.client.streamWrite(sid, dataA[], false));
    p.now += 1000;
    assert(p.client.pollTransmit(lateA[], p.now, lenA));
    assert(p.client.streamWrite(sid, dataC[], false));
    p.now += 1000;
    assert(p.client.pollTransmit(lateC[], p.now, lenC));

    // Key update; the first packet under the new keys reaches the server.
    assert(p.client.initiateKeyUpdate());
    const ubyte[2] dataB = [4, 5];
    ubyte[4096] fresh;
    size_t lenB;
    assert(p.client.streamWrite(sid, dataB[], false));
    p.now += 1000;
    assert(p.client.pollTransmit(fresh[], p.now, lenB));
    const ulong t0 = p.now;
    assert(!p.server.hasPrevRemoteAead);
    assert(p.server.handleDatagram(fresh[0 .. lenB], t0) == TransportErrorCode.noError);
    assert(p.server.remoteKeyPhase == 1 && p.server.hasPrevRemoteAead);

    const ulong until = p.server.prevRemoteDiscardMicros;
    assert(until > t0 && until == p.server.drainingEndFor(t0),
            "3 x PTO from the first new-key packet");
    assert(p.server.nextTimeoutMicros(t0) != 0 && p.server.nextTimeoutMicros(t0) <= until,
            "the discard deadline is part of the connection's next timeout");

    // Before the deadline the old key still opens the reordered packet...
    assert(p.server.handleDatagram(lateA[0 .. lenA], until - 1) == TransportErrorCode.noError);
    assert(p.server.hasPrevRemoteAead);
    ubyte[16] buf;
    bool fin;
    assert(p.server.streamRead(sid, buf[], fin) == 3 && buf[0 .. 3] == dataA[],
            "A opens with the retained key; B stays behind C's gap");

    // ...and at the deadline it is discarded, so the next old-phase packet is dropped.
    p.server.onTimeout(until);
    assert(!p.server.hasPrevRemoteAead, "onTimeout discards the expired previous key");
    const ulong rx = p.server.lastRxTimeMicros;
    assert(p.server.handleDatagram(lateC[0 .. lenC], until + 1) == TransportErrorCode.noError);
    assert(p.server.lastRxTimeMicros == rx, "an old-phase packet after 3 x PTO is not processed");
    assert(p.server.remoteKeyPhase == 1);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[4096] oldPhase, fresh;
/// size_t n, freshLen;
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "aaa", false));
/// assert(p.client.pollTransmit(oldPhase[], p.now += 1000, n));
/// assert(p.client.initiateKeyUpdate());
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "bb", false));
/// assert(p.client.pollTransmit(fresh[], p.now += 1000, freshLen));
/// assert(p.server.handleDatagram(fresh[0 .. freshLen], p.now) == TransportErrorCode.noError);
/// const ulong until = p.server.prevRemoteDiscardMicros;
/// const ulong before = p.server.lastRxTimeMicros;
/// // no onTimeout ran: a packet arriving after the deadline discards the key itself
/// assert(p.server.handleDatagram(oldPhase[0 .. n], until) == TransportErrorCode.noError);
/// assert(!p.server.hasPrevRemoteAead && p.server.lastRxTimeMicros == before);
/// ---
// Spec: RFC 9001 Section 6.5 "After this period, old read keys and their corresponding secrets
// SHOULD be discarded." - the expiry holds even when no timer callback ran before the packet
// (R-41, W23)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    const ubyte[3] dataA = [1, 2, 3];
    ubyte[4096] late;
    size_t lateLen;
    assert(p.client.streamWrite(sid, dataA[], false));
    p.now += 1000;
    assert(p.client.pollTransmit(late[], p.now, lateLen));
    assert(p.client.initiateKeyUpdate());
    const ubyte[2] dataB = [4, 5];
    ubyte[4096] fresh;
    size_t freshLen;
    assert(p.client.streamWrite(sid, dataB[], false));
    p.now += 1000;
    assert(p.client.pollTransmit(fresh[], p.now, freshLen));
    assert(p.server.handleDatagram(fresh[0 .. freshLen], p.now) == TransportErrorCode.noError);
    const ulong until = p.server.prevRemoteDiscardMicros;
    const ulong before = p.server.lastRxTimeMicros;
    assert(p.server.handleDatagram(late[0 .. lateLen], until) == TransportErrorCode.noError);
    assert(!p.server.hasPrevRemoteAead);
    assert(p.server.lastRxTimeMicros == before);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// assert(p.server.hasNextRemote);                  // derived when the 1-RTT keys were installed
/// const secret = p.server.nextRemoteSecret;        // cached
/// assert(!p.server.ensureNextRemoteKeys() || p.server.nextRemoteSecret == secret);
/// // a key update consumes it and derives the following generation straight away
/// assert(p.client.initiateKeyUpdate());
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "y", false));
/// ubyte[4096] dg;
/// size_t n;
/// assert(p.client.pollTransmit(dg[], p.now += 1000, n));
/// assert(p.server.handleDatagram(dg[0 .. n], p.now) == TransportErrorCode.noError);
/// assert(p.server.hasNextRemote && p.server.nextRemoteSecret != secret);
/// ---
// Spec: RFC 9001 Section 9.5 "After receiving a key update, an endpoint SHOULD generate and save
// the next set of receive packet protection keys, as described in Section 6.3. By generating new
// keys before a key update is received, receipt of packets will not create timing signals that
// leak the value of the Key Phase." - the next generation is cached once per phase and a
// garbage 1-RTT packet does not re-derive it (Auditor L-2)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    assert(p.server.hasNextRemote, "derived when the 1-RTT keys were installed");
    const secret0 = p.server.nextRemoteSecret;

    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "x", false));
    ubyte[4096] dg;
    size_t n;
    p.now += 1000;
    assert(p.client.pollTransmit(dg[], p.now, n));
    ubyte[4096] junk = dg;
    junk[n - 1] ^= 0xff;
    junk[n - 2] ^= 0xff;
    assert(p.server.handleDatagram(junk[0 .. n], p.now) == TransportErrorCode.noError);
    assert(p.server.hasNextRemote && p.server.nextRemoteSecret == secret0,
            "a failed packet reuses the cached next key");

    // A real key update consumes it and immediately derives the following generation.
    assert(p.client.initiateKeyUpdate());
    assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "y", false));
    p.now += 1000;
    assert(p.client.pollTransmit(dg[], p.now, n));
    assert(p.server.handleDatagram(dg[0 .. n], p.now) == TransportErrorCode.noError);
    assert(p.server.remoteKeyPhase == 1);
    assert(p.server.hasNextRemote && p.server.nextRemoteSecret != secret0,
            "the generation after the new one is ready before it is needed");
    assert(p.server.remoteAppSecret == secret0, "the cached secret became the current one");
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[4096] first;
/// size_t firstLen;
/// ulong pn0;
/// // deliver every second 1-RTT packet: each one is its own range in the server's table
/// foreach (i; 0 .. 2 * (MAX_ACK_RANGES + 1))
/// {
///     const ubyte[1] one = [cast(ubyte) i];
///     assert(p.client.streamWrite(sid, one[], false));
///     ubyte[4096] dg;
///     size_t n;
///     const ulong pn = p.client.nextPn[2];
///     assert(p.client.pollTransmit(dg[], p.now += 1000, n));
///     if (i % 2 != 0)
///         continue;
///     if (i == 0)
///     {
///         first[0 .. n] = dg[0 .. n];
///         firstLen = n;
///         pn0 = pn;
///     }
///     assert(p.server.handleDatagram(dg[0 .. n], p.now) == TransportErrorCode.noError);
/// }
/// // the oldest range was evicted from the table ...
/// assert(!p.server.ackRanges[2].contains(pn0) && p.server.ackRanges[2].isDuplicateOrTooOld(pn0));
/// // ... and a replay of that packet is dropped before any frame is processed
/// p.server.ackRanges[2].onAckSent();
/// const ulong before = p.server.lastRxTimeMicros;
/// assert(p.server.handleDatagram(first[0 .. firstLen], p.now + 5000) == TransportErrorCode.noError);
/// assert(p.server.lastRxTimeMicros == before && !p.server.ackRanges[2].hasPendingAck);
/// ---
// Spec: RFC 9000 Section 13.2 "A receiver MUST discard a newly unprotected packet unless it is
// certain that it has not processed another packet with the same packet number from the same
// packet number space." and Section 13.2.3 "The data required for detecting duplicates can be
// limited by maintaining a minimum packet number below which all packets are immediately
// dropped." - a packet whose range was evicted from the ACK table must not be processed again:
// no frame dispatch, no idle-timer restart, no ACK (Auditor M-1, W27)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    ubyte[4096] first;
    size_t firstLen;
    ulong firstPn;
    // Deliver every second 1-RTT packet: each one is a separate range in the server's table.
    foreach (i; 0 .. 2 * (MAX_ACK_RANGES + 1))
    {
        const ubyte[1] one = [cast(ubyte) i];
        assert(p.client.streamWrite(sid, one[], false));
        ubyte[4096] dg;
        size_t n;
        const ulong pn = p.client.nextPn[2];
        p.now += 1000;
        assert(p.client.pollTransmit(dg[], p.now, n));
        assert(p.client.nextPn[2] == pn + 1);
        if (i % 2 != 0)
            continue;
        if (i == 0)
        {
            first[0 .. n] = dg[0 .. n];
            firstLen = n;
            firstPn = pn;
        }
        assert(p.server.handleDatagram(dg[0 .. n], p.now) == TransportErrorCode.noError);
    }
    assert(p.server.ackRanges[2].numRanges == MAX_ACK_RANGES);
    assert(!p.server.ackRanges[2].contains(firstPn), "the oldest range was evicted");
    assert(p.server.ackRanges[2].isDuplicateOrTooOld(firstPn));

    // Replay the evicted packet later.
    p.server.ackRanges[2].onAckSent();
    const ulong before = p.server.lastRxTimeMicros;
    const ranges = p.server.ackRanges[2].numRanges;
    const largestBefore = p.server.ackRanges[2].largestReceived;
    p.now += 5000;
    assert(p.server.handleDatagram(first[0 .. firstLen], p.now) == TransportErrorCode.noError);
    assert(p.server.lastRxTimeMicros == before, "a replayed packet must not restart the idle timer");
    assert(!p.server.ackRanges[2].hasPendingAck, "and must not schedule an ACK");
    assert(p.server.ackRanges[2].numRanges == ranges && !p.server.ackRanges[2].contains(firstPn));
    assert(p.server.ackRanges[2].largestReceived == largestBefore);
}

/// Example:
/// ---
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// const ubyte[8] srvBytes = [0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7];
/// TransportParameters tp;
/// ulong now = 1_000_000;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidBytes[]),
///         ConnectionId(dcidBytes[]), tp, now, client));
/// ubyte[1500] dg;
/// size_t n;
/// assert(client.pollTransmit(dg[], now, n));       // Initial packet 0 is in flight
/// Frame ackEcn;
/// ackEcn.type = FrameType.ackEcn;
/// ackEcn.ack.numRanges = 1;                        // acknowledges packet 0, with ECN counts
/// ackEcn.ack.hasEcn = true;
/// n = forgeServerInitial(client, ConnectionId(srvBytes[]), 1, ackEcn, dg[]);
/// assert(client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);
/// assert(!client.ackRanges[0].ackNeeded);          // ACK_ECN is not ack-eliciting
/// ---
// Spec: RFC 9002 Section 2 "ACK-eliciting packets: Packets that contain ack-eliciting frames
// elicit an ACK from the receiver within the maximum acknowledgment delay and are called
// ack-eliciting packets." and "Ack-eliciting frames: All frames other than ACK, PADDING, and
// CONNECTION_CLOSE are considered ack-eliciting." - ACK_ECN is an ACK frame, so packets that
// carry only ACK_ECN (and PADDING) never schedule an ACK (R-38, W19)
@nogc unittest
{
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(clientCtx.isValid);
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    const ubyte[8] srvBytes = [0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7];
    const ConnectionId dcid = ConnectionId(dcidBytes[]);
    const ConnectionId scid = ConnectionId(scidBytes[]);
    const ConnectionId srvScid = ConnectionId(srvBytes[]);
    TransportParameters tp;
    ulong now = 1_000_000;
    ubyte[1500] dg;
    size_t n;

    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, now, client));
    assert(client.pollTransmit(dg[], now, n)); // Initial packet 0 is in flight

    Frame ackEcn;
    ackEcn.type = FrameType.ackEcn;
    ackEcn.ack.numRanges = 1;
    ackEcn.ack.ranges[0].largest = 0;
    ackEcn.ack.ranges[0].smallest = 0;
    ackEcn.ack.hasEcn = true;
    foreach (pn; 1 .. 4)
    {
        n = forgeServerInitial(client, srvScid, pn, ackEcn, dg[]);
        assert(n > 0);
        assert(client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);
    }
    assert(client.ackRanges[0].contains(3), "the packets were processed");
    assert(client.ackRanges[0].ackElicitingSinceLastAck == 0);
    assert(!client.ackRanges[0].ackNeeded, "ACK_ECN-only packets are not ack-eliciting");

    // Control: the same number of PING packets does schedule an ACK.
    Frame ping;
    ping.type = FrameType.ping;
    foreach (pn; 4 .. 7)
    {
        n = forgeServerInitial(client, srvScid, pn, ping, dg[]);
        assert(client.handleDatagram(dg[0 .. n], now) == TransportErrorCode.noError);
    }
    assert(client.ackRanges[0].ackNeeded);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[4096] dgram;
/// size_t len;
///
/// // A misbehaving peer sends a packet under the old keys that is numbered above one it sends
/// // under the new keys.
/// const ulong base = p.client.nextPn[2];
/// p.client.nextPn[2] = base + 10;
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "old", false));
/// assert(p.client.pollTransmit(dgram[], p.now, len));
/// ubyte[4096] oldKeyPacket;
/// oldKeyPacket[0 .. len] = dgram[0 .. len];
/// const size_t oldLen = len;
/// p.client.nextPn[2] = base;
/// assert(p.client.initiateKeyUpdate());
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "new", false));
/// assert(p.client.pollTransmit(dgram[], p.now, len));
///
/// assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
/// assert(p.server.handleDatagram(oldKeyPacket[0 .. oldLen], p.now) == TransportErrorCode.keyUpdateError);
/// ---
// Spec: RFC 9001 Section 6.4 "Packets with higher packet numbers MUST be protected with either
// the same or newer packet protection keys than packets with lower packet numbers. An endpoint
// that successfully removes protection with old keys when newer keys were used for packets with
// lower packet numbers MUST treat this as a connection error of type KEY_UPDATE_ERROR." - the
// lowest packet number opened with the current keys is tracked, and a packet that opens with the
// retained previous keys above it is a KEY_UPDATE_ERROR (Auditor L, item 3)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    ubyte[4096] dgram;
    size_t len;

    const ulong base = p.client.nextPn[2];
    p.client.nextPn[2] = base + 10;
    assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "old", false));
    assert(p.client.pollTransmit(dgram[], p.now, len));
    ubyte[4096] oldKeyPacket;
    oldKeyPacket[0 .. len] = dgram[0 .. len];
    const size_t oldLen = len;
    p.client.nextPn[2] = base;
    assert(p.client.initiateKeyUpdate());
    assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "new", false));
    assert(p.client.pollTransmit(dgram[], p.now, len));

    assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
    assert(p.server.remoteKeyPhase == 1 && p.server.hasPrevRemoteAead);
    assert(p.server.handleDatagram(oldKeyPacket[0 .. oldLen],
            p.now) == TransportErrorCode.keyUpdateError);
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[4096] dgram;
/// size_t len;
///
/// // The server has received packet base + 10 under the current keys ...
/// const ulong base = p.client.nextPn[2];
/// p.client.nextPn[2] = base + 10;
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "current", false));
/// assert(p.client.pollTransmit(dgram[], p.now, len));
/// assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);
///
/// // ... and now a packet numbered below it arrives under new keys: it cannot start an update.
/// p.client.nextPn[2] = base + 1;
/// assert(p.client.initiateKeyUpdate());
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "next", false));
/// assert(p.client.pollTransmit(dgram[], p.now, len));
/// assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.keyUpdateError);
/// assert(p.server.remoteKeyPhase == 0);   // the keys were not rotated
/// ---
// Spec: RFC 9001 Section 6.4 "Packets with higher packet numbers MUST be protected with either
// the same or newer packet protection keys than packets with lower packet numbers." - a packet
// that would start a key update but is numbered below a packet already received under the
// current keys is a KEY_UPDATE_ERROR and rotates nothing (Auditor L, item 3)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    ubyte[4096] dgram;
    size_t len;

    const ulong base = p.client.nextPn[2];
    p.client.nextPn[2] = base + 10;
    assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "current", false));
    assert(p.client.pollTransmit(dgram[], p.now, len));
    assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.noError);

    p.client.nextPn[2] = base + 1;
    assert(p.client.initiateKeyUpdate());
    assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "next", false));
    assert(p.client.pollTransmit(dgram[], p.now, len));
    assert(p.server.handleDatagram(dgram[0 .. len], p.now) == TransportErrorCode.keyUpdateError);
    assert(p.server.remoteKeyPhase == 0, "a refused update rotates nothing");
}

/// Example:
/// ---
/// TestConnPair p;
/// assert(initTestConnPair(p));
/// StreamId sid;
/// assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
///
/// assert(p.client.initiateKeyUpdate());    // the first update needs only a confirmed handshake
/// assert(!p.client.initiateKeyUpdate());   // the second waits for an ACK under the new keys
///
/// assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "ping", false));
/// assert(exchangeUntilQuiet(p.client, p.server, p.now));   // the server acknowledges it
/// assert(p.client.initiateKeyUpdate());    // now it is allowed
/// ---
// Spec: RFC 9001 Section 6.1 "An endpoint MUST NOT initiate a subsequent key update unless it has
// received an acknowledgment for a packet that was sent protected with keys from the current key
// phase." - initiateKeyUpdate refuses a second update until a packet sent under the first update's
// keys has been acknowledged (Auditor L, item 4)
@nogc unittest
{
    TestConnPair p;
    assert(initTestConnPair(p));
    StreamId sid;
    assert(p.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);

    assert(p.client.initiateKeyUpdate());
    assert(p.client.localKeyPhase == 1);
    assert(!p.client.initiateKeyUpdate(), "no second update before an ACK");
    assert(p.client.localKeyPhase == 1, "a refused update changes nothing");

    assert(p.client.streamWrite(sid, cast(const(ubyte)[]) "ping", false));
    assert(exchangeUntilQuiet(p.client, p.server, p.now));
    assert(p.client.initiateKeyUpdate(), "an ACK for a packet of the current phase arrived");
    assert(p.client.localKeyPhase == 0);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// TransportParameters tp;
/// ulong now = 1_000_000;
/// QuicConnection client, server;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidBytes[]), ConnectionId(dcidBytes[]), tp, now, client));
/// assert(QuicConnection.create(Side.server, serverCtx, ConnectionId(dcidBytes[]), ConnectionId.init, tp, now, server));
///
/// assert(deliverFlight(client, server, now));
/// now += 10_000;
/// assert(deliverFlight(server, client, now));              // the client now holds 1-RTT keys ...
/// assert(client.state == ConnectionState.active && !client.handshakeConfirmed);
/// assert(!client.initiateKeyUpdate());                     // ... but may not update yet
///
/// now += 10_000;
/// assert(deliverFlight(client, server, now));
/// now += 10_000;
/// assert(deliverFlight(server, client, now));              // HANDSHAKE_DONE
/// assert(client.handshakeConfirmed && client.initiateKeyUpdate());
/// ---
// Spec: RFC 9001 Section 6.1 "An endpoint MUST NOT initiate a key update prior to having
// confirmed the handshake (Section 4.1.2)." - between receiving the server's Finished and
// HANDSHAKE_DONE the client has 1-RTT keys but initiateKeyUpdate refuses (Auditor L, item 4)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    TransportParameters tp;
    ulong now = 1_000_000;
    QuicConnection client, server;
    assert(QuicConnection.create(Side.client, clientCtx,
            ConnectionId(scidBytes[]), ConnectionId(dcidBytes[]), tp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx,
            ConnectionId(dcidBytes[]), ConnectionId.init, tp, now, server));

    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));
    assert(client.state == ConnectionState.active && !client.handshakeConfirmed);
    assert(!client.initiateKeyUpdate(), "refused before the handshake is confirmed");
    assert(client.localKeyPhase == 0);

    now += 10_000;
    assert(deliverFlight(client, server, now));
    now += 10_000;
    assert(deliverFlight(server, client, now));
    assert(client.handshakeConfirmed);
    assert(client.initiateKeyUpdate());
}
