module slate.quic.endpoint;

/**
 * QUIC Server Endpoint Subsystem (RFC 9000 & RFC 9001).
 *
 * Provides connection multiplexing, Stateless Retry token validation,
 * Version Negotiation, and Stateless Reset handling.
 */

public import slate.quic.endpoint.token;
public import slate.quic.endpoint.endpoint;

import slate.quic.crypto.tls_session : TlsContext;
import slate.quic.crypto.aead : verifyRetryIntegrityTag;
import slate.quic.crypto.kdf : Side;
import slate.quic.wire.cid : ConnectionId, TransportErrorCode;
import slate.quic.wire.packet : PacketType, PacketPrefix, parsePacketPrefix, WireError;
import slate.quic.wire.transport_params : TransportParameters;
import slate.quic.connection.connection : QuicConnection, ConnectionState;

/// Example:
// Spec: RFC 9000 Section 8.1 & Section 17.2.5 - Server QuicEndpoint Stateless Retry, Token Verification & Tamper Rejection (covers U1, U2, U3, E4, W3, F3, Scenario T5)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    assert(serverCtx.isValid);
    assert(clientCtx.isValid);

    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    const ubyte[16] resetToken = [
        0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x55, 0x55, 0x55, 0x55
    ];

    TransportParameters serverTp;
    serverTp.initialMaxData = 10_000_000;
    serverTp.initialMaxStreamsBidi = 100;

    TransportParameters clientTp;
    clientTp.initialMaxData = 10_000_000;
    clientTp.initialMaxStreamsBidi = 100;

    QuicEndpoint serverEndpoint;
    serverEndpoint.init(serverCtx, serverTp, tokenSecret, tokenIv, resetToken, true, 32);
    assert(serverEndpoint.requireRetry);
    assert(serverEndpoint.connectionCount == 0);

    const SocketAddr clientAddr = SocketAddr.ipv4(192, 0, 2, 1, 55443);
    const ubyte[8] dcidBytes = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
    const ubyte[8] scidBytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11];
    ConnectionId clientDcid = ConnectionId(dcidBytes[]);
    ConnectionId clientScid = ConnectionId(scidBytes[]);

    ulong now = 1_000_000;

    // 1. Client creates connection and sends Initial without token
    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, clientScid,
            clientDcid, clientTp, now, client));

    ubyte[4096] dgramBuf;
    size_t dgramLen = 0;
    assert(client.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen >= 1200);

    // 2. Server Endpoint receives Initial without token -> Emits Stateless Retry (allocates 0 connections)
    ubyte[1500] retryBuf;
    size_t retryLen = 0;
    QuicConnection* matched = null;
    assert(serverEndpoint.handleDatagram(clientAddr, dgramBuf[0 .. dgramLen],
            now, retryBuf[], retryLen, matched) == TransportErrorCode.noError);
    assert(matched is null, "Stateless Retry must not allocate a connection");
    assert(serverEndpoint.connectionCount == 0, "Server must have 0 connections allocated");
    assert(retryLen > 0, "Server must emit Retry packet");

    // Verify Retry packet structure and integrity tag
    PacketPrefix retryPrefix;
    assert(parsePacketPrefix(retryBuf[0 .. retryLen], 8, retryPrefix) == WireError.none);
    assert(retryPrefix.type == PacketType.retry);
    assert(retryPrefix.token.length > 0);
    assert(verifyRetryIntegrityTag(clientDcid.asSlice(), retryBuf[0 .. retryLen]));

    // 3. Client ingests Retry packet and re-keys
    assert(client.handleDatagram(retryBuf[0 .. retryLen], now) == TransportErrorCode.noError);
    assert(client.remoteCid == retryPrefix.scid, "Client must update remote CID to Retry SCID");

    // 4. Client generates Flight 1 again, now containing the Retry token
    now += 10_000;
    ubyte[4096] tokenDgramBuf;
    size_t tokenDgramLen = 0;
    assert(client.pollTransmit(tokenDgramBuf[], now, tokenDgramLen));
    assert(tokenDgramLen >= 1200);

    // 5. Test tamper rejection: corrupted token must be rejected with invalidToken (0x0b)
    ubyte[4096] tamperedBuf;
    tamperedBuf[0 .. tokenDgramLen] = tokenDgramBuf[0 .. tokenDgramLen];
    tamperedBuf[32] ^= 0xff; // Flip bit in the token payload
    QuicConnection* tamperedMatched = null;
    ubyte[1500] dummyResp;
    size_t dummyRespLen = 0;
    assert(serverEndpoint.handleDatagram(clientAddr, tamperedBuf[0 .. tokenDgramLen], now,
            dummyResp[], dummyRespLen, tamperedMatched) == TransportErrorCode.invalidToken);
    assert(serverEndpoint.connectionCount == 0);

    // 6. Test address mismatch rejection: token sent from different IP/port must be rejected
    const SocketAddr attackerAddr = SocketAddr.ipv4(198, 51, 100, 4, 12345);
    assert(serverEndpoint.handleDatagram(attackerAddr, tokenDgramBuf[0 .. tokenDgramLen], now,
            dummyResp[], dummyRespLen, tamperedMatched) == TransportErrorCode.invalidToken);
    assert(serverEndpoint.connectionCount == 0);

    // 7. Legitimate Client Initial with valid Retry token is accepted
    assert(serverEndpoint.handleDatagram(clientAddr, tokenDgramBuf[0 .. tokenDgramLen],
            now, dummyResp[], dummyRespLen, matched) == TransportErrorCode.noError);
    assert(matched !is null, "Server must allocate a QuicConnection");
    assert(serverEndpoint.connectionCount == 1);
    assert(matched.peerAddressValidated,
            "Server must mark address as validated after successful Retry");

    // 8. Complete the handshake
    now += 10_000;
    ubyte[4096] sDgramBuf;
    size_t sDgramLen = 0;
    assert(matched.pollTransmit(sDgramBuf[], now, sDgramLen));
    assert(sDgramLen > 0);
    assert(client.handleDatagram(sDgramBuf[0 .. sDgramLen], now) == TransportErrorCode.noError);

    now += 10_000;
    assert(client.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen > 0);
    assert(matched.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);

    now += 10_000;
    assert(matched.pollTransmit(sDgramBuf[], now, sDgramLen));
    assert(sDgramLen > 0);
    assert(client.handleDatagram(sDgramBuf[0 .. sDgramLen], now) == TransportErrorCode.noError);

    now += 10_000;
    assert(client.pollTransmit(dgramBuf[], now, dgramLen));
    assert(dgramLen > 0);
    assert(matched.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode.noError);

    assert(client.handshakeConfirmed);
    assert(matched.handshakeConfirmed);
}

/// Example:
// Spec: RFC 9000 Section 6 & Section 10.3 - Server QuicEndpoint Version Negotiation, Multi-Client Routing & Stateless Reset (covers U1, U2, U3, E4, Scenario T6)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    assert(serverCtx.isValid);
    assert(clientCtx.isValid);

    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    const ubyte[16] resetToken = [
        0xca, 0xfe, 0xba, 0xbe, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c
    ];

    TransportParameters serverTp;
    serverTp.initialMaxData = 10_000_000;
    serverTp.initialMaxStreamsBidi = 100;

    TransportParameters clientTp;
    clientTp.initialMaxData = 10_000_000;
    clientTp.initialMaxStreamsBidi = 100;

    QuicEndpoint serverEndpoint;
    serverEndpoint.init(serverCtx, serverTp, tokenSecret, tokenIv, resetToken, false, 32);

    ulong now = 1_000_000;

    // 1. Version Negotiation: Packet with unsupported version 0xbad0cafe
    const SocketAddr client1Addr = SocketAddr.ipv4(10, 0, 1, 1, 50001);
    const ubyte[8] dcid1Bytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scid1Bytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid1 = ConnectionId(dcid1Bytes[]);
    ConnectionId scid1 = ConnectionId(scid1Bytes[]);

    ubyte[1200] unsuppVerPkt;
    unsuppVerPkt[0] = 0xc0;
    unsuppVerPkt[1] = 0xba;
    unsuppVerPkt[2] = 0xd0;
    unsuppVerPkt[3] = 0xca;
    unsuppVerPkt[4] = 0xfe;
    unsuppVerPkt[5] = 8;
    unsuppVerPkt[6 .. 14] = dcid1Bytes[];
    unsuppVerPkt[14] = 8;
    unsuppVerPkt[15 .. 23] = scid1Bytes[];

    ubyte[1500] respBuf;
    size_t respLen = 0;
    QuicConnection* matched1 = null;
    assert(serverEndpoint.handleDatagram(client1Addr, unsuppVerPkt[], now,
            respBuf[], respLen, matched1) == TransportErrorCode.noError);
    assert(matched1 is null);
    assert(respLen > 0);

    PacketPrefix vnPrefix;
    assert(parsePacketPrefix(respBuf[0 .. respLen], 8, vnPrefix) == WireError.none);
    assert(vnPrefix.type == PacketType.versionNegotiation);
    assert(vnPrefix.dcid == scid1);
    assert(vnPrefix.scid == dcid1);

    // 2. Multi-Client Routing: Concurrently connect Client A and Client B
    const SocketAddr client2Addr = SocketAddr.ipv4(10, 0, 2, 2, 50002);
    const ubyte[8] dcid2Bytes = [0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8];
    const ubyte[8] scid2Bytes = [0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8];
    ConnectionId dcid2 = ConnectionId(dcid2Bytes[]);
    ConnectionId scid2 = ConnectionId(scid2Bytes[]);

    QuicConnection clientA;
    assert(QuicConnection.create(Side.client, clientCtx, scid1, dcid1, clientTp, now, clientA));

    QuicConnection clientB;
    assert(QuicConnection.create(Side.client, clientCtx, scid2, dcid2, clientTp, now, clientB));

    ubyte[4096] dgramA;
    size_t lenA = 0;
    assert(clientA.pollTransmit(dgramA[], now, lenA));

    ubyte[4096] dgramB;
    size_t lenB = 0;
    assert(clientB.pollTransmit(dgramB[], now, lenB));

    QuicConnection* connA = null;
    assert(serverEndpoint.handleDatagram(client1Addr, dgramA[0 .. lenA], now,
            respBuf[], respLen, connA) == TransportErrorCode.noError);
    assert(connA !is null);
    assert(serverEndpoint.connectionCount == 1);

    QuicConnection* connB = null;
    assert(serverEndpoint.handleDatagram(client2Addr, dgramB[0 .. lenB], now,
            respBuf[], respLen, connB) == TransportErrorCode.noError);
    assert(connB !is null);
    assert(serverEndpoint.connectionCount == 2);
    assert(connA !is connB, "Different clients must route to distinct QuicConnection slots");

    // Lookup verification
    assert(serverEndpoint.findConnection(dcid1) is connA);
    assert(serverEndpoint.findConnection(dcid2) is connB);
    assert(serverEndpoint.findConnectionByPeer(client1Addr) is connA);
    assert(serverEndpoint.findConnectionByPeer(client2Addr) is connB);

    // 3. Stateless Reset: Unrecognized Short Header packet
    const SocketAddr strangerAddr = SocketAddr.ipv4(172, 16, 0, 99, 44444);
    ubyte[60] randomShortPkt;
    randomShortPkt[0] = 0x40; // Short header with fixed bit = 1
    randomShortPkt[1 .. 9] = 0x99; // Random unrecognized DCID

    QuicConnection* strangerMatched = null;
    assert(serverEndpoint.handleDatagram(strangerAddr, randomShortPkt[], now,
            respBuf[], respLen, strangerMatched) == TransportErrorCode.noError);
    assert(strangerMatched is null);
    assert(respLen >= 43);
    assert((respBuf[0] & 0x80) == 0, "Stateless Reset must be short header form");
    assert((respBuf[0] & 0x40) != 0, "Stateless Reset must have fixed bit set to 1");
    assert(respBuf[respLen - 16 .. respLen] == resetToken[],
            "Stateless Reset must end with StatelessResetToken");
}

/// Example:
// Spec: RFC 9000 Section 10.3 - Stateless Reset Size & Loop Prevention (Self-Token Reflection Rejection)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    TlsContext serverCtx = makeServerCtx();

    TransportParameters tp;
    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    const ubyte[16] resetToken = [
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc,
        0xdd, 0xee, 0xff, 0x00
    ];

    QuicEndpoint endpoint;
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, resetToken, false, 16);

    const SocketAddr clientAddr = SocketAddr.ipv4(127, 0, 0, 1, 55555);
    ubyte[1500] respBuf;
    size_t respLen = 0;
    QuicConnection* matched = null;

    // 1. Datagram of length 43 (less than 44 bytes minimum required for Stateless Reset)
    ubyte[43] tooSmall;
    tooSmall[0] = 0x40; // Short header
    assert(endpoint.handleDatagram(clientAddr, tooSmall[], 1_000_000,
            respBuf[], respLen, matched) == TransportErrorCode.noError);
    assert(matched is null);
    assert(respLen == 0, "Server must not emit Stateless Reset for datagram < 44 bytes");

    // 2. Datagram ending with the server's own Stateless Reset token (Stateless Reset loop reflection attack)
    ubyte[50] selfTokenPkt;
    selfTokenPkt[0] = 0x40;
    selfTokenPkt[$ - 16 .. $] = resetToken[];
    assert(endpoint.handleDatagram(clientAddr, selfTokenPkt[], 1_000_000,
            respBuf[], respLen, matched) == TransportErrorCode.noError);
    assert(matched is null);
    assert(respLen == 0, "Server must not emit Stateless Reset in response to its own token");

    // 3. Legitimate short header of length 44 bytes emits Stateless Reset of length 43
    ubyte[44] validTrigger;
    validTrigger[0] = 0x40;
    assert(endpoint.handleDatagram(clientAddr, validTrigger[], 1_000_000,
            respBuf[], respLen, matched) == TransportErrorCode.noError);
    assert(matched is null);
    assert(respLen == 43, "Stateless Reset must be 43 bytes");
    assert(respBuf[respLen - 16 .. respLen] == resetToken[]);
}

/// Example:
// Spec: RFC 9000 Section 8.1 - Pre-Authentication Slot Rollback Defense against Connection Table Exhaustion
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    TlsContext serverCtx = makeServerCtx();

    TransportParameters tp;
    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    const ubyte[16] resetToken = [
        0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x55, 0x55, 0x55, 0x55
    ];

    QuicEndpoint endpoint;
    // Set capacity to 2 to test exhaustion resistance
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, resetToken, false, 2);
    assert(endpoint.capacity == 2);
    assert(endpoint.connectionCount == 0);

    const SocketAddr clientAddr = SocketAddr.ipv4(10, 0, 0, 1, 40001);

    // Craft a forged 1200-byte Initial packet with invalid ciphertext that fails AEAD
    ubyte[1200] forgedInitial;
    forgedInitial[0] = 0xc0; // Initial packet long header
    forgedInitial[1] = 0x00;
    forgedInitial[2] = 0x00;
    forgedInitial[3] = 0x00;
    forgedInitial[4] = 0x01; // Version 1
    forgedInitial[5] = 8; // DCID len
    forgedInitial[6 .. 14] = 0x77;
    forgedInitial[14] = 8; // SCID len
    forgedInitial[15 .. 23] = 0x88;
    forgedInitial[23] = 0x00; // Token len 0
    // Invalid remainder
    foreach (i; 24 .. 1200)
    {
        forgedInitial[i] = cast(ubyte)(i & 0xff);
    }

    ubyte[1500] respBuf;
    size_t respLen = 0;
    QuicConnection* matched = null;

    // Send forged initial multiple times
    foreach (iter; 0 .. 5)
    {
        endpoint.handleDatagram(clientAddr, forgedInitial[], 1_000_000,
                respBuf[], respLen, matched);
        assert(matched is null);
        assert(endpoint.connectionCount == 0,
                "Unauthenticated Initial must not consume connection slot");
    }
}

/// Example:
// Spec: RFC 9000 Section 8.1.3 - Stateless Retry Token Anti-Replay Rejection
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();

    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    const ubyte[16] resetToken = [
        0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x55, 0x55, 0x55, 0x55
    ];

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;

    QuicEndpoint serverEndpoint;
    serverEndpoint.init(serverCtx, tp, tokenSecret, tokenIv, resetToken, true, 16);

    const SocketAddr clientAddr = SocketAddr.ipv4(192, 0, 2, 10, 50000);
    const ubyte[8] dcidBytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08];
    const ubyte[8] scidBytes = [0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10];
    ConnectionId clientDcid = ConnectionId(dcidBytes[]);
    ConnectionId clientScid = ConnectionId(scidBytes[]);

    ulong now = 1_000_000;
    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, clientScid, clientDcid, tp, now, client));

    ubyte[4096] dgram;
    size_t len;
    assert(client.pollTransmit(dgram[], now, len));

    // Server emits Retry
    ubyte[1500] retryBuf;
    size_t retryLen = 0;
    QuicConnection* matched = null;
    assert(serverEndpoint.handleDatagram(clientAddr, dgram[0 .. len], now,
            retryBuf[], retryLen, matched) == TransportErrorCode.noError);
    assert(retryLen > 0);

    // Client ingests Retry
    assert(client.handleDatagram(retryBuf[0 .. retryLen], now) == TransportErrorCode.noError);

    // Client generates Initial with Retry token
    now += 1000;
    ubyte[4096] tokenDgram;
    size_t tokenDgramLen = 0;
    assert(client.pollTransmit(tokenDgram[], now, tokenDgramLen));

    // First ingestion of Retry token succeeds
    ubyte[1500] respBuf;
    size_t respLen = 0;
    assert(serverEndpoint.handleDatagram(clientAddr, tokenDgram[0 .. tokenDgramLen],
            now, respBuf[], respLen, matched) == TransportErrorCode.noError);
    assert(matched !is null);
    assert(serverEndpoint.connectionCount == 1);

    // Original connection is closed / terminated
    serverEndpoint.closeConnection(matched.localCid);
    assert(serverEndpoint.connectionCount == 0);

    // Replay of the exact same Initial packet with same spent Retry token is REJECTED by anti-replay cache
    QuicConnection* replayedMatched = null;
    assert(serverEndpoint.handleDatagram(clientAddr, tokenDgram[0 .. tokenDgramLen],
            now, respBuf[], respLen, replayedMatched) == TransportErrorCode.invalidToken);
    assert(replayedMatched is null);
    assert(serverEndpoint.connectionCount == 0);
}

/// Example:
// Best practice: Slot Recycling for Closed Connections
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;

    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    const ubyte[16] resetToken = [
        0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x55, 0x55, 0x55, 0x55
    ];

    QuicEndpoint serverEndpoint;
    // Capacity of only 1 connection
    serverEndpoint.init(serverCtx, tp, tokenSecret, tokenIv, resetToken, false, 1);
    assert(serverEndpoint.capacity == 1);

    const SocketAddr client1Addr = SocketAddr.ipv4(10, 0, 0, 1, 5001);
    const ubyte[8] dcid1Bytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scid1Bytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid1 = ConnectionId(dcid1Bytes[]);
    ConnectionId scid1 = ConnectionId(scid1Bytes[]);

    ulong now = 1_000_000;
    QuicConnection client1;
    assert(QuicConnection.create(Side.client, clientCtx, scid1, dcid1, tp, now, client1));

    ubyte[4096] dgram;
    size_t len;
    assert(client1.pollTransmit(dgram[], now, len));

    ubyte[1500] respBuf;
    size_t respLen = 0;
    QuicConnection* conn1 = null;
    assert(serverEndpoint.handleDatagram(client1Addr, dgram[0 .. len], now,
            respBuf[], respLen, conn1) == TransportErrorCode.noError);
    assert(conn1 !is null);
    assert(serverEndpoint.connectionCount == 1);

    // Close connection 1 explicitly
    conn1.close(0, true);
    assert(conn1.state == ConnectionState.closing || conn1.state == ConnectionState.draining);

    // Now client 2 connects: server reclaims the closing/draining slot!
    const SocketAddr client2Addr = SocketAddr.ipv4(10, 0, 0, 2, 5002);
    const ubyte[8] dcid2Bytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x01, 0x02];
    const ubyte[8] scid2Bytes = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
    ConnectionId dcid2 = ConnectionId(dcid2Bytes[]);
    ConnectionId scid2 = ConnectionId(scid2Bytes[]);

    QuicConnection client2;
    assert(QuicConnection.create(Side.client, clientCtx, scid2, dcid2, tp, now, client2));
    assert(client2.pollTransmit(dgram[], now, len));

    QuicConnection* conn2 = null;
    assert(serverEndpoint.handleDatagram(client2Addr, dgram[0 .. len], now,
            respBuf[], respLen, conn2) == TransportErrorCode.noError);
    assert(conn2 !is null);
    assert(serverEndpoint.connectionCount == 1);
}
