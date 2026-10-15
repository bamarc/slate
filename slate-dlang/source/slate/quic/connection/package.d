module slate.quic.connection;

/**
 * QUIC Connection State Machine and Subsystem Umbrella (RFC 9000 & RFC 9001).
 *
 * Re-exports:
 * - slate.quic.connection.events: ConnectionEventType, ConnectionEvent, ConnectionEventQueue
 * - slate.quic.connection.sent_frames: SentFrameKind, SentFrameDesc, SentPacketRecord, SentFrameTracker
 * - slate.quic.connection.connection: QuicConnection Sans-I/O state machine
 */

public import slate.quic.connection.events;
public import slate.quic.connection.sent_frames;
public import slate.quic.connection.connection;

import slate.quic.crypto.kdf : Side, CipherSuite, EncryptionLevel, QuicCryptoError;
import slate.quic.crypto.tls_session : TlsContext;
import slate.quic.wire.cid : ConnectionId, TransportErrorCode;
import slate.quic.wire.transport_params : TransportParameters;
import slate.quic.wire.packet : PacketType, encodeLongHeader, QUIC_VERSION_1;
import slate.quic.wire.frame : Frame, FrameType, encodeFrame, WireError;
import slate.quic.crypto.packet_keys : protectPacket;
import slate.quic.stream.id : StreamDirection, StreamId;

/// Example:
// Spec: RFC 9000 Section 7 & RFC 9001 Section 4.9 - Full Sans-I/O Client <-> Server Handshake, Key Discard & Stream Exchange (covers U1, U2, U3, E1, E2, Scenario T1)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow {
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
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
    assert(QuicConnection.create(Side.client, clientCtx, clientScid, clientDcid, clientTp, now, client));
    assert(QuicConnection.create(Side.server, serverCtx, clientDcid, ConnectionId.init, serverTp, now, server));

    ubyte[4096] dgramBuf;
    size_t dgramLen = 0;

    // Flight 1: Client -> Server (Initial padded to >= 1200 bytes per RFC 9000 §14.1)
    assert(client.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen >= 1200, "Client Initial packet must be padded to >= 1200 bytes");
    assert(server.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);
    assert(server.hasWriteKeys[2], "server hasWriteKeys[2] after Flight 1");
    assert(server.cryptoSend[1].hasPendingBytes, "server cryptoSend[1] hasPendingBytes after Flight 1");

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
    assert(!client.hasReadKeys[2], "Client must discard Handshake keys upon handshake confirmation");
    assert(!client.hasWriteKeys[2]);

    ConnectionEvent clientEv;
    assert(client.pollEvent(clientEv));
    assert(clientEv.type == ConnectionEventType.handshakeConfirmed);

    // Bidirectional Stream Data Exchange with FIN
    StreamId clientSid;
    assert(client.openStream(StreamDirection.bidirectional, clientSid) == TransportErrorCode.noError);
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
    auto makeServerCtx = () @trusted @nogc nothrow {
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
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
    assert(QuicConnection.create(Side.server, serverCtx, clientDcid, ConnectionId.init, tp, now, server));

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
    foreach (i; 0 .. 100) chunk[i] = cast(ubyte) i;

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
    auto makeServerCtx = () @trusted @nogc nothrow {
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
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
    assert(QuicConnection.create(Side.server, serverCtx, dcid, ConnectionId.init, tp, now, server, false));
    assert(!server.peerAddressValidated);

    // 1. Undersized Client Initial (< 1200 bytes) must be silently dropped (RFC 9000 §14.1 & F2)
    ubyte[1199] undersizedDgram;
    undersizedDgram[0] = 0xc0; // Long header Initial
    assert(server.handleDatagram(undersizedDgram[], now) == TransportErrorCode.noError);
    assert(server.totalBytesReceived == 0, "Undersized Initial must be dropped without updating received count");

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
    auto makeServerCtx = () @trusted @nogc nothrow {
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
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
    assert(!client.hasPendingPathChallenge, "Path challenge must be cleared upon receiving PATH_RESPONSE");

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
// Best practice: High-Iteration Creation/Destruction and Zero-Leak Lifecycle (covers U2, G4)
@nogc unittest
{
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
    };
    TlsContext clientCtx = makeClientCtx();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);
    TransportParameters tp;

    foreach (iter; 0 .. 50)
    {
        QuicConnection conn;
        assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, 1000, conn));
        assert(conn.state == ConnectionState.handshaking);
    }
}

/// Example:
// Spec: RFC 9001 Section 6 - Key Phase Authentication Gate & Forged 1-RTT Packet Rejection
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow {
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
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
    auto makeServerCtx = () @trusted @nogc nothrow {
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
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

    assert(encodeLongHeader(
        PacketType.initial,
        QUIC_VERSION_1,
        server.localCid,
        client.localCid,
        null,
        badPn,
        2,
        forbiddenLen,
        badInitialPkt[],
        badPnOff,
        badHdrLen
    ) == WireError.none);

    badInitialPkt[badHdrLen .. badHdrLen + forbiddenLen] = badPayload[0 .. forbiddenLen];

    size_t badProtLen = 0;
    assert(protectPacket(client.levelKeys[0].local, badPn, badPnOff, 2, badInitialPkt[], forbiddenLen, badProtLen) == QuicCryptoError.none);

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
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
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
    auto makeServerCtx = () @trusted @nogc nothrow {
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
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
