module slate.quic.endpoint;

/**
 * QUIC Server Endpoint Subsystem (RFC 9000 & RFC 9001).
 *
 * Provides connection multiplexing, Stateless Retry token validation,
 * Version Negotiation, and Stateless Reset handling.
 */

public import slate.quic.endpoint.token;
public import slate.quic.endpoint.endpoint;

version (unittest)
{
    import slate.quic.crypto.tls_session : TlsContext;
    import slate.quic.crypto.aead : verifyRetryIntegrityTag;
    import slate.quic.crypto.kdf : Side;
    import slate.quic.wire.cid : ConnectionId, StatelessResetToken, TransportErrorCode;
    import slate.quic.wire.packet : PacketType, PacketPrefix, parsePacketPrefix, WireError;
    import slate.quic.wire.transport_params : TransportParameters;
    import slate.quic.connection.connection : QuicConnection, ConnectionState;
    import slate.quic.stream.id : StreamId, StreamDirection;

    /// Rvalue-friendly wrappers around the `ref` parameters of the endpoint API.
    TransportErrorCode feed(ref QuicEndpoint ep, SocketAddr peer, const(ubyte)[] datagram,
            ulong now, ubyte[] resp, out size_t respLen, out QuicConnection* matched) @safe @nogc nothrow
    {
        return ep.handleDatagram(peer, datagram, now, resp, respLen, matched);
    }

    QuicConnection* find(ref QuicEndpoint ep, ConnectionId cid) @safe @nogc nothrow
    {
        return ep.findConnection(cid);
    }
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x01;
/// const ubyte[12] tokenIv = 0x02;
/// QuicEndpoint endpoint;
/// endpoint.init(serverCtx, tp, tokenSecret, tokenIv, true, 32);   // every new client must answer a Retry
/// const SocketAddr peer = SocketAddr.ipv4(192, 0, 2, 1, 55443);
/// const ubyte[8] dcidBytes = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
/// const ubyte[8] scidBytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11];
/// const ulong now = 1_000_000;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidBytes[]),
///         ConnectionId(dcidBytes[]), tp, now, client));
/// // the first Initial is answered with a Retry, no connection is allocated
/// ubyte[4096] initial, withToken;
/// ubyte[1500] outBuf;
/// size_t n, tokenLen, outLen;
/// QuicConnection* matched;
/// assert(client.pollTransmit(initial[], now, n));
/// assert(endpoint.handleDatagram(peer, initial[0 .. n], now, outBuf[], outLen, matched)
///         == TransportErrorCode.noError && matched is null && outLen > 0);
/// assert(endpoint.connectionCount == 0);
/// // the client echoes the token in its next Initial
/// assert(client.handleDatagram(outBuf[0 .. outLen], now) == TransportErrorCode.noError);
/// assert(client.pollTransmit(withToken[], now + 10_000, tokenLen));
/// // a token with a flipped bit is rejected without creating a connection ...
/// ubyte[4096] tampered = withToken;
/// tampered[40] ^= 0xff;
/// assert(endpoint.handleDatagram(peer, tampered[0 .. tokenLen], now, outBuf[], outLen, matched)
///         == TransportErrorCode.invalidToken && endpoint.connectionCount == 0);
/// // ... the intact one is admitted and the address counts as validated
/// assert(endpoint.handleDatagram(peer, withToken[0 .. tokenLen], now, outBuf[], outLen, matched)
///         == TransportErrorCode.noError && matched !is null && matched.peerAddressValidated);
/// ---
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
        return TlsContext.createClientInsecure();
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

    TransportParameters serverTp;
    serverTp.initialMaxData = 10_000_000;
    serverTp.initialMaxStreamsBidi = 100;

    TransportParameters clientTp;
    clientTp.initialMaxData = 10_000_000;
    clientTp.initialMaxStreamsBidi = 100;

    QuicEndpoint serverEndpoint;
    serverEndpoint.init(serverCtx, serverTp, tokenSecret, tokenIv, true, 32);
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
    tamperedBuf[40] ^= 0xff; // Flip bit in the token payload (the Retry SCID is 16 bytes: token starts at 33)
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

    // 8. Complete the handshake (each flight may span several datagrams of <= 1200 bytes)
    ubyte[4096] sDgramBuf;
    size_t sDgramLen = 0;
    foreach (round; 0 .. 8)
    {
        if (client.handshakeConfirmed && matched.handshakeConfirmed)
            break;
        now += 10_000;
        while (matched.pollTransmit(sDgramBuf[], now, sDgramLen) && sDgramLen > 0)
        {
            assert(sDgramLen <= 1200);
            assert(client.handleDatagram(sDgramBuf[0 .. sDgramLen],
                    now) == TransportErrorCode.noError);
        }
        now += 10_000;
        while (client.pollTransmit(dgramBuf[], now, dgramLen) && dgramLen > 0)
        {
            assert(dgramLen <= 1200);
            assert(matched.handleDatagram(dgramBuf[0 .. dgramLen], now) == TransportErrorCode
                    .noError);
        }
    }

    assert(client.handshakeConfirmed);
    assert(matched.handshakeConfirmed);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x01;
/// const ubyte[12] tokenIv = 0x02;
/// QuicEndpoint serverEndpoint;
/// serverEndpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 32);
/// const ulong now = 1_000_000;
/// // two clients are routed to distinct connection slots
/// const SocketAddr addrA = SocketAddr.ipv4(10, 0, 1, 1, 50001);
/// const SocketAddr addrB = SocketAddr.ipv4(10, 0, 2, 2, 50002);
/// QuicConnection* connA = admitFreshClient(serverEndpoint, clientCtx, tp, addrA, 1, now);
/// QuicConnection* connB = admitFreshClient(serverEndpoint, clientCtx, tp, addrB, 2, now);
/// assert(connA !is null && connB !is null && connA !is connB);
/// assert(serverEndpoint.findConnection(connA.localCid) is connA);
/// assert(serverEndpoint.findConnectionByPeer(addrB) is connB);
/// // a short header packet for an unknown connection is answered with a Stateless Reset
/// ubyte[60] randomShortPkt;
/// randomShortPkt[0] = 0x40;                        // short header, fixed bit set
/// randomShortPkt[1 .. 17] = 0x99;                  // a DCID nobody knows
/// ubyte[1500] respBuf;
/// size_t respLen;
/// QuicConnection* strangerMatched;
/// const SocketAddr stranger = SocketAddr.ipv4(172, 16, 0, 99, 44444);
/// serverEndpoint.handleDatagram(stranger, randomShortPkt[], now, respBuf[], respLen,
///         strangerMatched);
/// assert(strangerMatched is null && respLen >= 43);
/// assert((respBuf[0] & 0x80) == 0 && (respBuf[0] & 0x40) != 0);   // short header, fixed bit
/// StatelessResetToken expected;
/// assert(serverEndpoint.statelessResetTokenFor(ConnectionId(randomShortPkt[1 .. 17]), expected));
/// assert(respBuf[respLen - 16 .. respLen] == expected[]);
/// ---
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
        return TlsContext.createClientInsecure();
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

    TransportParameters serverTp;
    serverTp.initialMaxData = 10_000_000;
    serverTp.initialMaxStreamsBidi = 100;

    TransportParameters clientTp;
    clientTp.initialMaxData = 10_000_000;
    clientTp.initialMaxStreamsBidi = 100;

    QuicEndpoint serverEndpoint;
    serverEndpoint.init(serverCtx, serverTp, tokenSecret, tokenIv, false, 32);

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
    assert(serverEndpoint.findConnection(connA.localCid) is connA);
    assert(serverEndpoint.findConnection(connB.localCid) is connB);
    assert(connA.localCid != dcid1 && connA.localCid.len == SERVER_CID_LEN,
            "the server chooses its own fixed-length CID (RFC 9000 Section 7.2)");
    assert(serverEndpoint.findConnectionByPeer(client1Addr) is connA);
    assert(serverEndpoint.findConnectionByPeer(client2Addr) is connB);

    // 3. Stateless Reset: Unrecognized Short Header packet
    const SocketAddr strangerAddr = SocketAddr.ipv4(172, 16, 0, 99, 44444);
    ubyte[60] randomShortPkt;
    randomShortPkt[0] = 0x40; // Short header with fixed bit = 1
    randomShortPkt[1 .. 17] = 0x99; // Random unrecognized 16-byte DCID

    QuicConnection* strangerMatched = null;
    assert(serverEndpoint.handleDatagram(strangerAddr, randomShortPkt[], now,
            respBuf[], respLen, strangerMatched) == TransportErrorCode.noError);
    assert(strangerMatched is null);
    assert(respLen >= 43);
    assert((respBuf[0] & 0x80) == 0, "Stateless Reset must be short header form");
    assert((respBuf[0] & 0x40) != 0, "Stateless Reset must have fixed bit set to 1");
    StatelessResetToken expected;
    assert(serverEndpoint.statelessResetTokenFor(ConnectionId(randomShortPkt[1 .. 17]), expected));
    assert(respBuf[respLen - 16 .. respLen] == expected[],
            "Stateless Reset must end with the token derived for the packet's CID");
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x01;
/// const ubyte[12] tokenIv = 0x02;
/// QuicEndpoint endpoint;
/// endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 16);
/// const SocketAddr clientAddr = SocketAddr.ipv4(127, 0, 0, 1, 55555);
/// ubyte[1500] respBuf;
/// size_t respLen;
/// QuicConnection* matched;
/// ubyte[43] tooSmall;
/// tooSmall[0] = 0x40;
/// endpoint.handleDatagram(clientAddr, tooSmall[], 1_000_000, respBuf[], respLen, matched);
/// assert(respLen == 0);                            // 43 bytes: too small to answer with a reset
/// ubyte[44] validTrigger;
/// validTrigger[0] = 0x40;
/// endpoint.handleDatagram(clientAddr, validTrigger[], 1_000_000, respBuf[], respLen, matched);
/// assert(respLen == 43);                           // the reset is smaller than its trigger
/// StatelessResetToken expected;
/// assert(endpoint.statelessResetTokenFor(ConnectionId(validTrigger[1 .. 17]), expected));
/// assert(respBuf[respLen - 16 .. respLen] == expected[]);
/// // reflecting the reset back can never elicit another one
/// ubyte[43] reflected = respBuf[0 .. 43];
/// size_t reflectedLen;
/// endpoint.handleDatagram(clientAddr, reflected[], 1_000_000, respBuf[], reflectedLen, matched);
/// assert(reflectedLen == 0);
/// ---
// Spec: RFC 9000 Section 10.3 - Stateless Reset Size & Loop Prevention (a reset is smaller than its trigger)
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

    QuicEndpoint endpoint;
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 16);

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

    // 2. Legitimate short header of length 44 bytes emits Stateless Reset of length 43
    ubyte[44] validTrigger;
    validTrigger[0] = 0x40;
    assert(endpoint.handleDatagram(clientAddr, validTrigger[], 1_000_000,
            respBuf[], respLen, matched) == TransportErrorCode.noError);
    assert(matched is null);
    assert(respLen == 43, "Stateless Reset must be 43 bytes");
    StatelessResetToken expected;
    assert(endpoint.statelessResetTokenFor(ConnectionId(validTrigger[1 .. 17]), expected));
    assert(respBuf[respLen - 16 .. respLen] == expected[]);

    // 3. Loop prevention: the reset is smaller than its trigger, so reflecting it back
    // (a datagram of 43 bytes) can never elicit another reset.
    ubyte[43] reflected;
    reflected[] = respBuf[0 .. 43];
    size_t reflectedLen = 0;
    assert(endpoint.handleDatagram(clientAddr, reflected[], 1_000_000,
            respBuf[], reflectedLen, matched) == TransportErrorCode.noError);
    assert(reflectedLen == 0, "Server must not answer a Stateless Reset with another one");
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x01;
/// const ubyte[12] tokenIv = 0x02;
/// QuicEndpoint endpoint;
/// endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 2);
/// assert(endpoint.capacity == 2 && endpoint.connectionCount == 0);
/// ubyte[1200] forgedInitial;                       // valid long header, garbage ciphertext
/// forgedInitial[0] = 0xc0;
/// forgedInitial[4] = 0x01;                         // version 1
/// forgedInitial[5] = 8;
/// forgedInitial[6 .. 14] = 0x77;
/// forgedInitial[14] = 8;
/// forgedInitial[15 .. 23] = 0x88;
/// foreach (i; 24 .. 1200)
///     forgedInitial[i] = cast(ubyte)(i & 0xff);
/// ubyte[1500] respBuf;
/// size_t respLen;
/// QuicConnection* matched;
/// const SocketAddr attacker = SocketAddr.ipv4(10, 0, 0, 1, 40001);
/// foreach (attempt; 0 .. 5)
/// {
///     endpoint.handleDatagram(attacker, forgedInitial[], 1_000_000, respBuf[], respLen, matched);
///     assert(matched is null && endpoint.connectionCount == 0);   // no slot is consumed
/// }
/// ---
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

    QuicEndpoint endpoint;
    // Set capacity to 2 to test exhaustion resistance
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 2);
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
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x01;
/// const ubyte[12] tokenIv = 0x02;
/// QuicEndpoint serverEndpoint;
/// serverEndpoint.init(serverCtx, tp, tokenSecret, tokenIv, true, 16);
/// const SocketAddr clientAddr = SocketAddr.ipv4(192, 0, 2, 10, 50000);
/// const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
/// ulong now = 1_000_000;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidBytes[]),
///         ConnectionId(dcidBytes[]), tp, now, client));
/// ubyte[4096] dgram, tokenDgram;
/// ubyte[1500] respBuf;
/// size_t len, tokenLen, respLen;
/// QuicConnection* matched;
/// assert(client.pollTransmit(dgram[], now, len));
/// serverEndpoint.handleDatagram(clientAddr, dgram[0 .. len], now, respBuf[], respLen, matched);   // Retry
/// assert(client.handleDatagram(respBuf[0 .. respLen], now) == TransportErrorCode.noError);
/// assert(client.pollTransmit(tokenDgram[], now += 1000, tokenLen));
/// // the first Initial with the Retry token is admitted ...
/// assert(serverEndpoint.handleDatagram(clientAddr, tokenDgram[0 .. tokenLen], now, respBuf[],
///         respLen, matched) == TransportErrorCode.noError && matched !is null);
/// serverEndpoint.closeConnection(matched.localCid);
/// // ... the exact same Initial replayed afterwards is refused: the token is spent
/// QuicConnection* replayed;
/// assert(serverEndpoint.handleDatagram(clientAddr, tokenDgram[0 .. tokenLen], now, respBuf[],
///         respLen, replayed) == TransportErrorCode.invalidToken);
/// assert(replayed is null && serverEndpoint.connectionCount == 0);
/// ---
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
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();

    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;

    QuicEndpoint serverEndpoint;
    serverEndpoint.init(serverCtx, tp, tokenSecret, tokenIv, true, 16);

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

    // Two separate clients triggering Retry at the exact same now timestamp both succeed (F-13, D-12)
    const SocketAddr c1Addr = SocketAddr.ipv4(192, 0, 2, 21, 50001);
    const SocketAddr c2Addr = SocketAddr.ipv4(192, 0, 2, 22, 50002);
    const ubyte[8] c1DcidBytes = [
        0x21, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ];
    const ubyte[8] c1ScidBytes = [
        0x21, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02
    ];
    const ubyte[8] c2DcidBytes = [
        0x22, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ];
    const ubyte[8] c2ScidBytes = [
        0x22, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02
    ];
    const ConnectionId c1Dcid = ConnectionId(c1DcidBytes[]);
    const ConnectionId c1Scid = ConnectionId(c1ScidBytes[]);
    const ConnectionId c2Dcid = ConnectionId(c2DcidBytes[]);
    const ConnectionId c2Scid = ConnectionId(c2ScidBytes[]);

    QuicConnection client1;
    QuicConnection client2;
    assert(QuicConnection.create(Side.client, clientCtx, c1Scid, c1Dcid, tp, now, client1));
    assert(QuicConnection.create(Side.client, clientCtx, c2Scid, c2Dcid, tp, now, client2));

    ubyte[4096] c1Dgram;
    ubyte[4096] c2Dgram;
    size_t c1Len = 0;
    size_t c2Len = 0;
    assert(client1.pollTransmit(c1Dgram[], now, c1Len));
    assert(client2.pollTransmit(c2Dgram[], now, c2Len));

    ubyte[1500] retry1Buf;
    ubyte[1500] retry2Buf;
    size_t retry1Len = 0;
    size_t retry2Len = 0;
    QuicConnection* m1 = null;
    QuicConnection* m2 = null;
    assert(serverEndpoint.handleDatagram(c1Addr, c1Dgram[0 .. c1Len], now,
            retry1Buf[], retry1Len, m1) == TransportErrorCode.noError);
    assert(serverEndpoint.handleDatagram(c2Addr, c2Dgram[0 .. c2Len], now,
            retry2Buf[], retry2Len, m2) == TransportErrorCode.noError);

    assert(client1.handleDatagram(retry1Buf[0 .. retry1Len], now) == TransportErrorCode.noError);
    assert(client2.handleDatagram(retry2Buf[0 .. retry2Len], now) == TransportErrorCode.noError);

    ubyte[4096] token1Dgram;
    ubyte[4096] token2Dgram;
    size_t token1Len = 0;
    size_t token2Len = 0;
    assert(client1.pollTransmit(token1Dgram[], now, token1Len));
    assert(client2.pollTransmit(token2Dgram[], now, token2Len));

    // Both clients send tokens generated at the exact same now timestamp; both must succeed because nonceCounter distinguishes them
    assert(serverEndpoint.handleDatagram(c1Addr, token1Dgram[0 .. token1Len],
            now, respBuf[], respLen, m1) == TransportErrorCode.noError);
    assert(m1 !is null);
    assert(serverEndpoint.handleDatagram(c2Addr, token2Dgram[0 .. token2Len],
            now, respBuf[], respLen, m2) == TransportErrorCode.noError);
    assert(m2 !is null);
    assert(serverEndpoint.connectionCount == 2);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x01;
/// const ubyte[12] tokenIv = 0x02;
/// QuicEndpoint serverEndpoint;
/// serverEndpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 1);   // a single slot
/// const SocketAddr addr1 = SocketAddr.ipv4(10, 0, 0, 1, 5001);
/// const SocketAddr addr2 = SocketAddr.ipv4(10, 0, 0, 2, 5002);
/// QuicConnection* conn1 = admitFreshClient(serverEndpoint, clientCtx, tp, addr1, 1, 1_000_000);
/// assert(conn1 !is null && serverEndpoint.connectionCount == 1);
/// conn1.close(0, true);                            // closing: the slot must not be recycled
/// assert(admitFreshClient(serverEndpoint, clientCtx, tp, addr2, 2, 1_000_000) is null);
/// serverEndpoint.closeConnection(conn1.localCid);  // explicit release frees it
/// assert(serverEndpoint.connectionCount == 0);
/// assert(admitFreshClient(serverEndpoint, clientCtx, tp, addr2, 2, 1_000_000) !is null);
/// assert(serverEndpoint.connectionCount == 1);
/// ---
// Spec: RFC 9000 Section 10.2 - Slot Recycling Protects Closing State & Checks Connection CID (D-09, D-12)
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

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;

    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

    QuicEndpoint serverEndpoint;
    // Capacity of only 1 connection
    serverEndpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 1);
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

    // Close connection 1 explicitly -> transitions to closing
    conn1.close(0, true);
    assert(conn1.state == ConnectionState.closing || conn1.state == ConnectionState.draining);

    // While in closing state, slot must NOT be evicted (D-09)
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
            respBuf[], respLen, conn2) == TransportErrorCode.internalError);
    assert(conn2 is null);

    // Explicit deallocate by localCid or conn.localCid frees the slot (D-09)
    serverEndpoint.closeConnection(conn1.localCid);
    assert(serverEndpoint.connectionCount == 0);

    // Now client 2 connects successfully into the recycled slot
    assert(serverEndpoint.handleDatagram(client2Addr, dgram[0 .. len], now,
            respBuf[], respLen, conn2) == TransportErrorCode.noError);
    assert(conn2 !is null);
    assert(serverEndpoint.connectionCount == 1);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x01;
/// const ubyte[12] tokenIv = 0x02;
/// QuicEndpoint endpoint;
/// endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 1);
/// QuicConnection* first = admitFreshClient(endpoint, clientCtx, tp, SocketAddr.ipv4(10, 0, 0, 1, 5000),
///         0x10, 1_000_000);
/// const ConnectionId firstCid = first.localCid;
/// // capacity 1: a second client's Initial replaces the half-open, unvalidated first one
/// QuicConnection* second = admitFreshClient(endpoint, clientCtx, tp, SocketAddr.ipv4(10, 0, 0, 2, 5000),
///         0x11, 2_000_000);
/// assert(second !is null && endpoint.connectionCount == 1);
/// assert(endpoint.findConnection(firstCid) is null && endpoint.evictedCount == 1);
/// ---
// Spec: RFC 9000 Section 8.1 - an address that has not been validated holds a slot only while
// it is not needed: with a full table the oldest half-open, unvalidated slot is evicted;
// established connections never are, and an address-validated half-open one only when no
// unvalidated one is left (R-19, W7, Auditor M-2)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x31;
    const ubyte[12] tokenIv = 0x13;

    QuicEndpoint endpoint;
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 2);
    ubyte[4096] dgram;
    size_t len = 0;
    ubyte[1500] resp;
    size_t respLen = 0;

    // Three clients (distinct CIDs) send a first flight; the table holds two.
    QuicConnection[3] clients;
    QuicConnection*[3] served;
    foreach (i; 0 .. 3)
    {
        ubyte[8] dcid = cast(ubyte)(0x10 + i);
        ubyte[8] scid = cast(ubyte)(0x20 + i);
        assert(QuicConnection.create(Side.client, clientCtx,
                ConnectionId(scid[]), ConnectionId(dcid[]), tp, 1_000_000, clients[i]));
        assert(clients[i].pollTransmit(dgram[], 1_000_000, len));
        const SocketAddr addr = SocketAddr.ipv4(10, 0, 0, cast(ubyte)(1 + i), 5000);
        const ulong now = 1_000_000 + i * 1000;
        assert(endpoint.handleDatagram(addr, dgram[0 .. len], now, resp[],
                respLen, served[i]) == TransportErrorCode.noError);
        assert(served[i]!is null, "a full table evicts a half-open slot instead of refusing");
        assert(endpoint.connectionCount == (i < 2 ? i + 1 : 2));
    }
    // Client 2 displaced the oldest (client 0); client 1 is untouched.
    assert(endpoint.findConnection(served[2].localCid) is served[2]);
    const ConnectionId cid1Id = served[1].localCid;
    assert(endpoint.findConnection(cid1Id) is served[1]);

    assert(endpoint.evictedCount == 1, "client 0 was evicted once");

    // An established connection is never evicted, even when it is the oldest.
    served[1].state = ConnectionState.active;
    served[2].state = ConnectionState.active;
    ubyte[8] dcid4 = 0x14;
    ubyte[8] scid4 = 0x24;
    QuicConnection client4;
    assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid4[]),
            ConnectionId(dcid4[]), tp, 1_000_000, client4));
    assert(client4.pollTransmit(dgram[], 1_000_000, len));
    QuicConnection* none = null;
    const SocketAddr addr4 = SocketAddr.ipv4(10, 0, 0, 9, 5000);
    assert(endpoint.handleDatagram(addr4, dgram[0 .. len], 1_010_000, resp[],
            respLen, none) == TransportErrorCode.internalError);
    assert(none is null);
    assert(endpoint.evictedCount == 1, "a refused Initial evicts nobody");

    // A half-open slot that is address-validated but never finishes is evictable once no
    // unvalidated one is left: the oldest of them goes (Auditor M-2).
    served[1].state = ConnectionState.handshaking;
    served[2].state = ConnectionState.handshaking;
    served[1].peerAddressValidated = true;
    served[2].peerAddressValidated = true;
    assert(endpoint.handleDatagram(addr4, dgram[0 .. len], 1_020_000, resp[],
            respLen, none) == TransportErrorCode.noError);
    assert(none !is null, "the oldest validated half-open slot made room");
    assert(endpoint.evictedCount == 2);
    assert(endpoint.findConnection(cid1Id) is null, "client 1 was the oldest validated slot");
    assert(endpoint.findConnection(served[2].localCid) is served[2]);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x31;
/// const ubyte[12] tokenIv = 0x13;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* matched;
///
/// ubyte[1200] pkt;
/// pkt[0] = 0xc0;
/// pkt[1 .. 5] = [0x1a, 0x2a, 0x3a, 0x4a];   // an unknown version
/// pkt[5] = 8;
/// pkt[6 .. 14] = 0x11;                      // DCID
/// pkt[14] = 8;
/// pkt[15 .. 23] = 0x22;                     // SCID
/// const SocketAddr addr = SocketAddr.ipv4(10, 0, 0, 1, 4000);
///
/// assert(ep.handleDatagram(addr, pkt[0 .. 1199], 1_000_000, resp[], respLen, matched) == TransportErrorCode.noError);
/// assert(respLen == 0);                     // too small to be a client Initial: no answer
/// assert(ep.handleDatagram(addr, pkt[], 1_000_000, resp[], respLen, matched) == TransportErrorCode.noError);
/// assert(respLen > 0 && respLen < 1200);    // Version Negotiation
/// ---
// Spec: RFC 9000 Section 6.1 - "A server MAY limit the number of Version Negotiation packets it
// sends." The endpoint answers only datagrams large enough to be a client Initial (Section 14.1),
// so a short probe cannot be amplified into a larger reply (R-19, W7)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x31;
    const ubyte[12] tokenIv = 0x13;
    QuicEndpoint endpoint;
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);

    ubyte[1200] pkt;
    pkt[0] = 0xc0;
    pkt[1] = 0x1a;
    pkt[2] = 0x2a;
    pkt[3] = 0x3a;
    pkt[4] = 0x4a;
    pkt[5] = 8;
    pkt[6 .. 14] = 0x11;
    pkt[14] = 8;
    pkt[15 .. 23] = 0x22;
    ubyte[1500] resp;
    size_t respLen = 0;
    QuicConnection* matched = null;
    const SocketAddr addr = SocketAddr.ipv4(10, 0, 0, 1, 4000);

    assert(endpoint.handleDatagram(addr, pkt[0 .. 1199], 1_000_000, resp[],
            respLen, matched) == TransportErrorCode.noError);
    assert(respLen == 0, "an undersized datagram must not elicit Version Negotiation");
    assert(endpoint.handleDatagram(addr, pkt[], 1_000_000, resp[], respLen,
            matched) == TransportErrorCode.noError);
    assert(respLen > 0 && respLen < 1200);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x31;
/// const ubyte[12] tokenIv = 0x13;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* matched;
///
/// // The token of a CID is derived from a per-endpoint key and the whole CID.
/// const ubyte[16] c1 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
/// const ubyte[16] c2 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17];
/// StatelessResetToken t1, t1again, t2;
/// assert(ep.statelessResetTokenFor(ConnectionId(c1[]), t1));
/// assert(ep.statelessResetTokenFor(ConnectionId(c1[]), t1again));
/// assert(ep.statelessResetTokenFor(ConnectionId(c2[]), t2));
/// assert(t1 == t1again && t1 != t2);        // deterministic per CID, different across CIDs
/// StatelessResetToken none;
/// assert(!ep.statelessResetTokenFor(ConnectionId(c1[0 .. 8]), none));   // not a length it issues
/// ---
// Spec: RFC 9000 Section 10.3.2 - the reset token of a connection ID is derived with a static key
// so it can be regenerated without per-connection state, and Section 18.2 - the server
// advertises it in the stateless_reset_token transport parameter (R-30, U7)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x31;
    const ubyte[12] tokenIv = 0x13;
    QuicEndpoint a;
    QuicEndpoint b;
    a.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
    b.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);

    // Two CIDs that differ only in their last byte must still get different tokens (the token
    // covers the whole CID), and only the fixed CID length of this endpoint gets one at all.
    const ubyte[16] c1 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
    const ubyte[16] c2 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17];
    StatelessResetToken t1;
    StatelessResetToken t1again;
    StatelessResetToken t2;
    StatelessResetToken tOther;
    assert(a.statelessResetTokenFor(ConnectionId(c1[]), t1));
    assert(a.statelessResetTokenFor(ConnectionId(c1[]), t1again));
    assert(a.statelessResetTokenFor(ConnectionId(c2[]), t2));
    assert(b.statelessResetTokenFor(ConnectionId(c1[]), tOther));
    assert(t1 == t1again, "deterministic per CID");
    assert(t1 != t2, "different CIDs get different tokens");
    assert(t1 != tOther, "the key is random per endpoint");
    StatelessResetToken none;
    assert(!a.statelessResetTokenFor(ConnectionId(c1[0 .. 8]), none),
            "no token for a CID length the endpoint never issues");

    // The server advertises the token of the CID it chose, not of the CID it was contacted on.
    ubyte[8] scid = 0x44;
    const ubyte[8] clientDcid = [9, 8, 7, 6, 5, 4, 3, 2];
    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid[]),
            ConnectionId(clientDcid[]), tp, 1_000_000, client));
    ubyte[4096] dgram;
    size_t len = 0;
    assert(client.pollTransmit(dgram[], 1_000_000, len));
    ubyte[1500] resp;
    size_t respLen = 0;
    QuicConnection* conn = null;
    const SocketAddr peer = SocketAddr.ipv4(10, 0, 0, 1, 4000);
    assert(a.handleDatagram(peer, dgram[0 .. len], 1_000_000, resp[], respLen,
            conn) == TransportErrorCode.noError);
    assert(conn !is null);
    assert(conn.localParams.hasStatelessResetToken);
    StatelessResetToken own;
    assert(a.statelessResetTokenFor(conn.localCid, own));
    assert(conn.localParams.statelessResetToken == own);
    assert(conn.localParams.statelessResetToken != t1);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x31;
/// const ubyte[12] tokenIv = 0x13;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 8);
///
/// // Two clients whose 12-byte DCIDs share their first 8 bytes.
/// const ubyte[12] dcidA = [1, 2, 3, 4, 5, 6, 7, 8, 0xa0, 0xa1, 0xa2, 0xa3];
/// const ubyte[12] dcidB = [1, 2, 3, 4, 5, 6, 7, 8, 0xb0, 0xb1, 0xb2, 0xb3];
/// const ubyte[8] scidA = 0x41;
/// const ubyte[8] scidB = 0x42;
/// QuicConnection clientA, clientB;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidA[]), ConnectionId(dcidA[]), tp, 1_000_000, clientA));
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidB[]), ConnectionId(dcidB[]), tp, 1_000_000, clientB));
/// ubyte[4096] dA, dB;
/// size_t lenA, lenB;
/// assert(clientA.pollTransmit(dA[], 1_000_000, lenA) && clientB.pollTransmit(dB[], 1_000_000, lenB));
///
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* connA, connB;
/// assert(feed(ep, SocketAddr.ipv4(10, 0, 0, 1, 4001), dA[0 .. lenA], 1_000_000, resp[], respLen, connA) == TransportErrorCode.noError);
/// assert(feed(ep, SocketAddr.ipv4(10, 0, 0, 2, 4002), dB[0 .. lenB], 1_000_000, resp[], respLen, connB) == TransportErrorCode.noError);
/// assert(connA.localCid.len == SERVER_CID_LEN && connA.localCid != connB.localCid);
/// ---
// Spec: RFC 9000 Section 10.3.2 "The same stateless reset token MUST NOT be used for multiple
// connection IDs." and Section 7.2 - the server chooses its own fixed-length CID, routes short
// headers on an exact match of it and never hands out a token for a prefix of a live CID (R-30, D7)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x31;
    const ubyte[12] tokenIv = 0x13;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 8);

    // 12-byte client DCIDs that share their first 8 bytes.
    const ubyte[12] dcidA = [1, 2, 3, 4, 5, 6, 7, 8, 0xa0, 0xa1, 0xa2, 0xa3];
    const ubyte[12] dcidB = [1, 2, 3, 4, 5, 6, 7, 8, 0xb0, 0xb1, 0xb2, 0xb3];
    const ubyte[8] scidA = 0x41;
    const ubyte[8] scidB = 0x42;
    QuicConnection clientA, clientB;
    assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidA[]),
            ConnectionId(dcidA[]), tp, 1_000_000, clientA));
    assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scidB[]),
            ConnectionId(dcidB[]), tp, 1_000_000, clientB));
    ubyte[4096] dA, dB;
    size_t lenA, lenB;
    assert(clientA.pollTransmit(dA[], 1_000_000, lenA));
    assert(clientB.pollTransmit(dB[], 1_000_000, lenB));

    ubyte[1500] resp;
    size_t respLen;
    QuicConnection* connA, connB;
    assert(feed(ep, SocketAddr.ipv4(10, 0, 0, 1, 4001), dA[0 .. lenA],
            1_000_000, resp[], respLen, connA) == TransportErrorCode.noError);
    assert(feed(ep, SocketAddr.ipv4(10, 0, 0, 2, 4002), dB[0 .. lenB],
            1_000_000, resp[], respLen, connB) == TransportErrorCode.noError);
    assert(connA !is null && connB !is null && connA !is connB);

    assert(connA.localCid.len == SERVER_CID_LEN && connB.localCid.len == SERVER_CID_LEN);
    assert(connA.localCid != connB.localCid);
    assert(connA.localCid.asSlice()[0 .. 8] != connB.localCid.asSlice()[0 .. 8],
            "server CIDs are random, not derived from the shared client DCID prefix");
    assert(connA.localCid.asSlice() != dcidA[] && connA.localCid.asSlice()[0 .. 8] != dcidA[0 .. 8]);
    assert(connA.localParams.statelessResetToken != connB.localParams.statelessResetToken);
    assert(connA.localParams.originalDestinationConnectionId == ConnectionId(dcidA[]));
    assert(connA.localParams.initialSourceConnectionId == connA.localCid);

    // Routing: a long header on the client's original DCID reaches the slot, a short header
    // only on the exact 16-byte server CID.
    assert(find(ep, ConnectionId(dcidA[])) is null);
    assert(ep.findConnection(connA.localCid) is connA);

    // A short header whose first 8 bytes equal connA's CID but whose tail differs matches no
    // connection and gets a reset carrying its own token, never connA's.
    ubyte[60] probe;
    probe[0] = 0x40;
    probe[1 .. 17] = connA.localCid.asSlice();
    probe[16] ^= 0xff;
    QuicConnection* probeMatched = null;
    assert(feed(ep, SocketAddr.ipv4(10, 9, 9, 9, 9), probe[], 1_000_001,
            resp[], respLen, probeMatched) == TransportErrorCode.noError);
    assert(probeMatched is null, "a CID prefix must not route to a live connection");
    assert(respLen == 43);
    StatelessResetToken own;
    assert(ep.statelessResetTokenFor(ConnectionId(probe[1 .. 17]), own));
    assert(resp[respLen - 16 .. respLen] == own[]);
    assert(resp[respLen - 16 .. respLen] != connA.localParams.statelessResetToken[]);

    // A short header on a 1-byte prefix of a live CID does not hijack the connection either.
    ubyte[60] shortProbe;
    shortProbe[0] = 0x40;
    shortProbe[1] = connA.localCid.asSlice()[0];
    assert(feed(ep, SocketAddr.ipv4(10, 9, 9, 9, 9), shortProbe[], 1_000_002,
            resp[], respLen, probeMatched) == TransportErrorCode.noError);
    assert(probeMatched is null);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x31;
/// const ubyte[12] tokenIv = 0x13;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 8);
/// const ubyte[7] shortDcid = [1, 2, 3, 4, 5, 6, 7];
/// const ubyte[8] scid = 0x41;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid[]),
///         ConnectionId(shortDcid[]), tp, 1_000_000, client));
/// ubyte[4096] initial;
/// ubyte[1500] resp;
/// size_t n, respLen;
/// QuicConnection* m;
/// assert(client.pollTransmit(initial[], 1_000_000, n));
/// // a client Initial whose DCID is shorter than 8 bytes is dropped without any state or reply
/// const SocketAddr peer = SocketAddr.ipv4(10, 0, 0, 1, 4001);
/// assert(ep.handleDatagram(peer, initial[0 .. n], 1_000_000, resp[], respLen, m)
///         == TransportErrorCode.noError);
/// assert(m is null && ep.connectionCount == 0 && respLen == 0);
/// ---
// Spec: RFC 9000 Section 7.2 "This Destination Connection ID MUST be at least 8 bytes in length."
// (R-30, D7)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x31;
    const ubyte[12] tokenIv = 0x13;

    foreach (retry; 0 .. 2)
    {
        QuicEndpoint ep;
        ep.init(serverCtx, tp, tokenSecret, tokenIv, retry == 1, 8);
        const ubyte[7] shortDcid = [1, 2, 3, 4, 5, 6, 7];
        const ubyte[1] oneDcid = [9];
        const ubyte[8] okDcid = [1, 2, 3, 4, 5, 6, 7, 8];
        const ubyte[8] scid = 0x41;
        ubyte[4096] d;
        ubyte[1500] resp;
        size_t len, respLen;
        QuicConnection* m;

        foreach (dcid; [shortDcid[], oneDcid[]])
        {
            QuicConnection c;
            assert(QuicConnection.create(Side.client, clientCtx,
                    ConnectionId(scid[]), ConnectionId(dcid), tp, 1_000_000, c));
            assert(c.pollTransmit(d[], 1_000_000, len) && len >= 1200);
            assert(feed(ep, SocketAddr.ipv4(10, 0, 0, 1, 4001), d[0 .. len],
                    1_000_000, resp[], respLen, m) == TransportErrorCode.noError);
            assert(m is null && ep.connectionCount == 0 && respLen == 0,
                    "an Initial with a DCID < 8 bytes is dropped silently");
        }

        QuicConnection ok;
        assert(QuicConnection.create(Side.client, clientCtx,
                ConnectionId(scid[]), ConnectionId(okDcid[]), tp, 1_000_000, ok));
        assert(ok.pollTransmit(d[], 1_000_000, len));
        assert(feed(ep, SocketAddr.ipv4(10, 0, 0, 1, 4001), d[0 .. len],
                1_000_000, resp[], respLen, m) == TransportErrorCode.noError);
        assert(respLen > 0 || m !is null, "an 8-byte DCID is accepted (Retry or connection)");
    }
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x31;
/// const ubyte[12] tokenIv = 0x13;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
/// const ubyte[9] dcid = [1, 2, 3, 4, 5, 6, 7, 8, 9];
/// const ubyte[8] scid = 0x41;
/// const SocketAddr peer = SocketAddr.ipv4(10, 0, 0, 1, 4001);
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid[]), ConnectionId(dcid[]), tp, 1_000_000, client));
///
/// ubyte[4096] d;
/// ubyte[1500] resp;
/// size_t len, respLen;
/// QuicConnection* serverConn;
/// while (client.pollTransmit(d[], 1_000_000, len))   // the ClientHello may span several datagrams
///     assert(feed(ep, peer, d[0 .. len], 1_000_000, resp[], respLen, serverConn) == TransportErrorCode.noError);
/// assert(serverConn !is null && serverConn.pollTransmit(resp[], 1_001_000, respLen));
/// assert(client.handleDatagram(resp[0 .. respLen], 1_001_000) == TransportErrorCode.noError);
/// assert(client.remoteCid == serverConn.localCid && client.remoteCid != ConnectionId(dcid[]));
/// ---
// Spec: RFC 9000 Section 7.2 "Upon first receiving an Initial or Retry packet from the server, the
// client uses the Source Connection ID supplied by the server as the Destination Connection ID
// for subsequent packets" - the client adopts the server-chosen CID against a real endpoint and the handshake plus application
// data still work, with and without Retry (R-30, D7, E1)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    tp.initialMaxStreamDataBidiLocal = 1_000_000;
    tp.initialMaxStreamDataBidiRemote = 1_000_000;
    tp.initialMaxStreamsBidi = 10;
    const ubyte[32] tokenSecret = 0x31;
    const ubyte[12] tokenIv = 0x13;

    foreach (retry; 0 .. 2)
    {
        QuicEndpoint ep;
        ep.init(serverCtx, tp, tokenSecret, tokenIv, retry == 1, 4);
        const ubyte[9] dcid = [1, 2, 3, 4, 5, 6, 7, 8, 9];
        const ubyte[8] scid = 0x41;
        const SocketAddr peer = SocketAddr.ipv4(10, 0, 0, 1, 4001);
        QuicConnection client;
        assert(QuicConnection.create(Side.client, clientCtx,
                ConnectionId(scid[]), ConnectionId(dcid[]), tp, 1_000_000, client));

        ubyte[4096] d;
        ubyte[1500] resp;
        size_t len, respLen;
        QuicConnection* server = null;
        ulong now = 1_000_000;
        foreach (round; 0 .. 20)
        {
            now += 1000;
            while (client.pollTransmit(d[], now, len))
            {
                QuicConnection* m;
                assert(feed(ep, peer, d[0 .. len], now, resp[], respLen,
                        m) == TransportErrorCode.noError);
                if (m !is null)
                    server = m;
                if (respLen > 0)
                    assert(client.handleDatagram(resp[0 .. respLen],
                            now) == TransportErrorCode.noError);
            }
            SocketAddr to;
            while (ep.pollTransmit(to, d[], now, len))
                assert(client.handleDatagram(d[0 .. len], now) == TransportErrorCode.noError);
            if (client.handshakeConfirmed && server !is null && server.handshakeConfirmed)
                break;
        }
        assert(server !is null);
        assert(client.handshakeConfirmed && server.handshakeConfirmed);
        assert(client.remoteCid == server.localCid);
        assert(client.remoteCid.len == SERVER_CID_LEN && client.remoteCid.asSlice() != dcid[]);
        assert(ep.findConnection(client.remoteCid) is server);

        // Application data now flows on short headers addressed to the server CID.
        StreamId sid;
        assert(client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
        const(ubyte)[] msg = cast(const(ubyte)[]) "ping";
        assert(client.streamWrite(sid, msg, true));
        now += 1000;
        bool got = false;
        foreach (round; 0 .. 10)
        {
            while (client.pollTransmit(d[], now, len))
            {
                QuicConnection* m;
                assert(feed(ep, peer, d[0 .. len], now, resp[], respLen,
                        m) == TransportErrorCode.noError);
                assert(m is server, "short headers route to the handshaken connection");
            }
            SocketAddr to;
            while (ep.pollTransmit(to, d[], now, len))
                client.handleDatagram(d[0 .. len], now);
            ubyte[16] rb;
            ptrdiff_t n;
            bool fin;
            if ((n = server.streamRead(sid, rb[], fin)) == 4 && rb[0 .. 4] == "ping")
                got = true;
            if (got)
                break;
            now += 1000;
        }
        assert(got, "application data must arrive over the server-chosen CID");
    }
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x31;
/// const ubyte[12] tokenIv = 0x13;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 2);
/// QuicConnection* oldest = admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(10, 0, 0, 1, 4000),
///         0x10, 1_000_000);
/// admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(10, 0, 0, 2, 4000), 0x11, 1_000_001);
/// const ConnectionId oldestCid = oldest.localCid;
/// ubyte[1200] forged;                              // valid header, garbage ciphertext
/// forged[0] = 0xc0;
/// forged[4] = 0x01;
/// forged[5] = 8;
/// forged[6 .. 14] = 0x77;
/// forged[14] = 8;
/// forged[15 .. 23] = 0x88;
/// foreach (i; 24 .. 1200)
///     forged[i] = cast(ubyte)(i & 0xff);
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* m;
/// // an Initial that does not decrypt must not evict a half-open connection from the full table
/// const SocketAddr attacker = SocketAddr.ipv4(10, 66, 6, 6, 666);
/// ep.handleDatagram(attacker, forged[], 2_000_000, resp[], respLen, m);
/// assert(m is null && ep.connectionCount == 2 && ep.findConnection(oldestCid) is oldest);
/// // an authentic Initial may evict it
/// admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(10, 0, 0, 3, 4000), 0x12, 3_000_000);
/// assert(ep.connectionCount == 2 && ep.findConnection(oldestCid) is null);
/// ---
// Spec: RFC 9000 Section 17.2.2 "This protection does not provide confidentiality or integrity
// against attackers that can observe packets, but it does prevent attackers that cannot observe
// packets from spoofing Initial packets." - an Initial that does not authenticate under the
// Initial keys must not displace legitimate half-open state (R-19, L2)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x31;
    const ubyte[12] tokenIv = 0x13;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 2);

    ubyte[4096] d;
    ubyte[1500] resp;
    size_t len, respLen;
    QuicConnection[3] clients;
    QuicConnection*[3] servers;
    foreach (i; 0 .. 3)
    {
        const ubyte[8] dcid = cast(ubyte)(0x10 + i);
        const ubyte[8] scid = cast(ubyte)(0x50 + i);
        assert(QuicConnection.create(Side.client, clientCtx,
                ConnectionId(scid[]), ConnectionId(dcid[]), tp, 1_000_000 + i, clients[i]));
    }
    foreach (i; 0 .. 2)
    {
        assert(clients[i].pollTransmit(d[], 1_000_000 + i, len));
        assert(feed(ep, SocketAddr.ipv4(10, 0, 0, cast(ubyte)(1 + i), 4000),
                d[0 .. len], 1_000_000 + i, resp[], respLen, servers[i]) == TransportErrorCode
                .noError);
        assert(servers[i]!is null);
    }
    assert(ep.connectionCount == 2);
    const oldestCid = servers[0].localCid;

    // Forged Initial: valid header, garbage ciphertext, table is full.
    ubyte[1200] forged;
    forged[0] = 0xc0;
    forged[4] = 0x01;
    forged[5] = 8;
    forged[6 .. 14] = 0x77;
    forged[14] = 8;
    forged[15 .. 23] = 0x88;
    foreach (i; 24 .. 1200)
        forged[i] = cast(ubyte)(i & 0xff);
    forged[24] = 0x44; // 2-byte payload length 0x0400 -> exactly the rest of the datagram
    QuicConnection* m;
    foreach (n; 0 .. 4)
    {
        assert(feed(ep, SocketAddr.ipv4(10, 66, 6, 6, 666), forged[],
                2_000_000, resp[], respLen, m) == TransportErrorCode.noError);
        assert(m is null);
        assert(ep.connectionCount == 2, "an undecryptable Initial must not evict anything");
        assert(ep.findConnection(oldestCid) is servers[0]);
    }

    // An authentic Initial may evict the oldest half-open connection.
    assert(clients[2].pollTransmit(d[], 3_000_000, len));
    assert(feed(ep, SocketAddr.ipv4(10, 0, 0, 3, 4000), d[0 .. len], 3_000_000,
            resp[], respLen, servers[2]) == TransportErrorCode.noError);
    assert(servers[2]!is null);
    assert(ep.connectionCount == 2);
    assert(ep.findConnection(oldestCid) is null, "the oldest half-open slot was evicted");
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x41;
/// const ubyte[12] tokenIv = 0x14;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 4);
/// const SocketAddr addr = SocketAddr.ipv4(192, 0, 2, 77, 4433);
/// const ubyte[8] dcid = 0x61;
/// const ubyte[8] scid = 0x62;
/// QuicConnection client;
/// assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid[]),
///         ConnectionId(dcid[]), tp, 1_000_000, client));
/// ubyte[4096] initial, intact;
/// ubyte[1500] resp;
/// size_t len, intactLen, respLen;
/// QuicConnection* m;
/// assert(client.pollTransmit(initial[], 1_000_000, len));
/// ep.handleDatagram(addr, initial[0 .. len], 1_000_000, resp[], respLen, m);      // Retry
/// assert(client.handleDatagram(resp[0 .. respLen], 1_000_000) == TransportErrorCode.noError);
/// assert(client.pollTransmit(intact[], 1_001_000, intactLen));
/// // a corrupted copy of the token-bearing Initial is dropped ...
/// ubyte[4096] corrupted = intact;
/// corrupted[intactLen - 1] ^= 0xff;                // the AEAD tag
/// ep.handleDatagram(addr, corrupted[0 .. intactLen], 1_001_000, resp[], respLen, m);
/// assert(m is null && ep.connectionCount == 0);
/// // ... and did not burn the token: the intact one is still admitted
/// ep.handleDatagram(addr, intact[0 .. intactLen], 1_001_500, resp[], respLen, m);
/// assert(m !is null && ep.connectionCount == 1);
/// ---
// Spec: RFC 9000 Section 8.1.4 "Servers are encouraged to allow tokens to be used only once, if
// possible; tokens MAY include additional information about clients to further narrow
// applicability or reuse." - a token is spent by the Initial that carries it; an Initial
// that does not decrypt (corrupted or forged by an on-path attacker copying the token) must
// not burn the token of the legitimate client (R-30, anti-replay ordering)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x41;
    const ubyte[12] tokenIv = 0x14;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 4);

    const SocketAddr addr = SocketAddr.ipv4(192, 0, 2, 77, 4433);
    const ubyte[8] dcid = 0x61;
    const ubyte[8] scid = 0x62;
    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid[]),
            ConnectionId(dcid[]), tp, 1_000_000, client));
    ubyte[4096] d;
    ubyte[1500] resp;
    size_t len, respLen;
    QuicConnection* m;
    assert(client.pollTransmit(d[], 1_000_000, len));
    assert(feed(ep, addr, d[0 .. len], 1_000_000, resp[], respLen, m) == TransportErrorCode.noError);
    assert(respLen > 0 && m is null, "Retry");
    assert(client.handleDatagram(resp[0 .. respLen], 1_000_000) == TransportErrorCode.noError);

    ubyte[4096] withToken;
    size_t tokenLen;
    assert(client.pollTransmit(withToken[], 1_001_000, tokenLen));
    assert(tokenLen >= 1200);

    ubyte[4096] corrupted;
    corrupted[0 .. tokenLen] = withToken[0 .. tokenLen];
    corrupted[tokenLen - 1] ^= 0xff; // AEAD tag of the Initial
    assert(feed(ep, addr, corrupted[0 .. tokenLen], 1_001_000, resp[], respLen,
            m) == TransportErrorCode.noError);
    assert(m is null && ep.connectionCount == 0, "a corrupted Initial is dropped");

    assert(feed(ep, addr, withToken[0 .. tokenLen], 1_001_500, resp[], respLen,
            m) == TransportErrorCode.noError);
    assert(m !is null && ep.connectionCount == 1, "the valid token was not burned");

    // The valid one spent it: a replay (after the connection is gone) is rejected.
    ep.closeConnection(m.localCid);
    QuicConnection* again;
    assert(feed(ep, addr, withToken[0 .. tokenLen], 1_002_000, resp[], respLen,
            again) == TransportErrorCode.invalidToken);
    assert(again is null);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x51;
/// const ubyte[12] tokenIv = 0x15;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 4);   // Retry enabled
/// const SocketAddr addr = SocketAddr.ipv4(192, 0, 2, 88, 4434);
///
/// ConnectionId[2] scids;
/// foreach (i; 0 .. 2)
/// {
///     const ubyte[8] dcid = cast(ubyte)(0x70 + i);
///     const ubyte[8] scid = cast(ubyte)(0x80 + i);
///     QuicConnection client;
///     assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid[]), ConnectionId(dcid[]), tp, 1_000_000, client));
///     ubyte[4096] d;
///     ubyte[1500] resp;
///     size_t len, respLen;
///     QuicConnection* m;
///     assert(client.pollTransmit(d[], 1_000_000, len));
///     assert(feed(ep, addr, d[0 .. len], 1_000_000, resp[], respLen, m) == TransportErrorCode.noError);
///     PacketPrefix rp;
///     assert(parsePacketPrefix(resp[0 .. respLen], 8, rp) == WireError.none && rp.type == PacketType.retry);
///     scids[i] = rp.scid;
/// }
/// assert(scids[0].len == 16 && scids[0] != scids[1]);   // random, not derived from the address
/// ---
// Spec: RFC 9000 Section 5.1 "Connection IDs MUST NOT contain any information that can be used by
// an external observer (that is, one that does not cooperate with the issuer) to correlate them
// with other connection IDs for the same connection" - the Retry SCID is 16 random bytes, not
// derived from the client's IP, port or a counter (R-30, D7)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x51;
    const ubyte[12] tokenIv = 0x15;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 4);

    const SocketAddr addr = SocketAddr.ipv4(192, 0, 2, 88, 4434);
    ConnectionId[4] scids;
    foreach (i; 0 .. 4)
    {
        const ubyte[8] dcid = cast(ubyte)(0x70 + i);
        const ubyte[8] scid = cast(ubyte)(0x80 + i);
        QuicConnection client;
        assert(QuicConnection.create(Side.client, clientCtx,
                ConnectionId(scid[]), ConnectionId(dcid[]), tp, 1_000_000, client));
        ubyte[4096] d;
        ubyte[1500] resp;
        size_t len, respLen;
        QuicConnection* m;
        assert(client.pollTransmit(d[], 1_000_000, len));
        assert(feed(ep, addr, d[0 .. len], 1_000_000, resp[], respLen,
                m) == TransportErrorCode.noError);
        assert(respLen > 0 && m is null);
        PacketPrefix rp;
        assert(parsePacketPrefix(resp[0 .. respLen], 8, rp) == WireError.none);
        assert(rp.type == PacketType.retry);
        scids[i] = rp.scid;
        assert(scids[i].len == 16, "Retry SCID is 16 bytes");
        const s = scids[i].asSlice();
        assert(s[0 .. 4] != addr.ip[0 .. 4], "the SCID does not embed the client address");
        assert(!(s[4] == cast(ubyte)(addr.port >> 8) && s[5] == cast(ubyte)(addr.port & 0xff)),
                "the SCID does not embed the client port");
    }
    foreach (i; 0 .. 4)
        foreach (j; i + 1 .. 4)
        {
            assert(scids[i] != scids[j], "same address and port, different SCIDs");
            // Not a counter step: more than the two low counter bytes differ.
            size_t differing;
            foreach (k; 0 .. 16)
                differing += scids[i].asSlice()[k] != scids[j].asSlice()[k];
            assert(differing > 4, "SCIDs are not derived from a counter");
        }
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x31;
/// const ubyte[12] tokenIv = 0x13;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 2);
/// const SocketAddr addr = SocketAddr.ipv4(10, 0, 0, 3, 3);
/// const ubyte[16] c1 = 0x01, c2 = 0x02, c3 = 0x03;
/// const ConnectionId odcid = ConnectionId(c3[0 .. 8]);
/// const ConnectionId oldestCid = ConnectionId(c1[]);
/// const ConnectionId cid = ConnectionId(c3[]);
/// const SocketAddr addr1 = SocketAddr.ipv4(10, 0, 0, 1, 1);
/// const SocketAddr addr2 = SocketAddr.ipv4(10, 0, 0, 2, 2);
/// const ConnectionId cid2 = ConnectionId(c2[]);
/// assert(ep.allocateSlot(addr1, oldestCid, odcid, 10) !is null);
/// assert(ep.allocateSlot(addr2, cid2, odcid, 20) !is null);
/// auto staged = ep.allocateSlot(addr, cid, odcid, 30);   // table full: staged in the spare slot
/// assert(staged !is null && ep.findConnection(oldestCid) !is null);   // the victim is still there
/// ep.abortStaged();
/// ep.deallocateSlot(cid);                          // the new connection was refused
/// assert(ep.connectionCount == 2 && ep.evictedCount == 0);
/// assert(ep.findConnection(oldestCid) !is null);
/// ---
// Spec: RFC 9000 Section 8.1 - an unvalidated address holds a slot only while it is not needed;
// a new connection that is refused after its Initial decrypted (Initial keys are public, so
// decrypting proves nothing) must not have evicted a legitimate half-open one (R-19, L2)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x31;
    const ubyte[12] tokenIv = 0x13;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 2);

    const SocketAddr a1 = SocketAddr.ipv4(10, 0, 0, 1, 1),
        a2 = SocketAddr.ipv4(10, 0, 0, 2, 2), a3 = SocketAddr.ipv4(10, 0, 0, 3, 3);
    const ubyte[16] c1 = 0x01, c2 = 0x02, c3 = 0x03, c4 = 0x04;
    const ConnectionId id1 = ConnectionId(c1[]), id2 = ConnectionId(c2[]),
        id3 = ConnectionId(c3[]), id4 = ConnectionId(c4[]), odcid = ConnectionId(c4[0 .. 8]);
    assert(ep.allocateSlot(a1, id1, odcid, 10) !is null);
    assert(ep.allocateSlot(a2, id2, odcid, 20) !is null);
    assert(ep.connectionCount == 2);

    // Refused after staging: nobody is evicted and the count returns to the capacity.
    auto staged = ep.allocateSlot(a3, id3, odcid, 30);
    assert(staged !is null);
    assert(ep.findConnection(id1) !is null && ep.findConnection(id2) !is null,
            "the victim survives until the new connection is admitted");
    ep.abortStaged();
    ep.deallocateSlot(id3);
    assert(ep.connectionCount == 2 && ep.evictedCount == 0, "a refused staging evicts nobody");
    assert(ep.findConnection(id1) !is null && ep.findConnection(id2) !is null);

    // Admitted: the oldest half-open slot (id1) goes, the count stays at the capacity.
    staged = ep.allocateSlot(a3, id4, odcid, 40);
    assert(staged !is null);
    ep.commitStaged();
    assert(ep.connectionCount == 2);
    assert(ep.evictedCount == 1, "the committed eviction is counted");
    assert(ep.findConnection(id1) is null, "the oldest half-open slot is evicted on admission");
    assert(ep.findConnection(id2) !is null && ep.findConnection(id4) !is null);
}

version (unittest)
{
    /// Marks every active connection's peer address as validated, so the per-host cap cannot
    /// evict any of them.
    private void validateHalfOpen(ref QuicEndpoint ep) @trusted @nogc nothrow
    {
        foreach (ref slot; ep.slots)
            if (slot.active)
                slot.conn.peerAddressValidated = true;
    }

    /// Feeds a fresh client's first Initial from `addr` into `ep`; returns the admitted
    /// connection or null.
    private QuicConnection* admitFreshClient(ref QuicEndpoint ep, ref TlsContext clientCtx,
            ref const TransportParameters tp, SocketAddr addr, ubyte seed, ulong now) @trusted @nogc nothrow
    {
        const ubyte[8] dcid = seed;
        const ubyte[8] scid = cast(ubyte)(seed ^ 0xff);
        QuicConnection client;
        if (!QuicConnection.create(Side.client, clientCtx,
                ConnectionId(scid[]), ConnectionId(dcid[]), tp, now, client))
            return null;
        ubyte[4096] d;
        ubyte[1500] resp;
        size_t len, respLen;
        QuicConnection* m;
        if (!client.pollTransmit(d[], now, len))
            return null;
        feed(ep, addr, d[0 .. len], now, resp[], respLen, m);
        return m;
    }
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x61;
/// const ubyte[12] tokenIv = 0x16;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 32);
/// foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)         // one host fills its half-open allowance
///     admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203, 0, 113, 5, cast(ushort)(5000 + i)),
///             cast(ubyte)(0x20 + i), 1_000_000 + i);
/// validateHalfOpen(ep);                            // none of them can be evicted
/// // the next half-open connection of that host is dropped, another host is still served
/// const SocketAddr host9 = SocketAddr.ipv4(203, 0, 113, 5, 6000);
/// const SocketAddr otherHost = SocketAddr.ipv4(203, 0, 113, 6, 5000);
/// assert(admitFreshClient(ep, clientCtx, tp, host9, 0x40, 2_000_000) is null);
/// assert(admitFreshClient(ep, clientCtx, tp, otherHost, 0x41, 2_000_001) !is null);
/// ---
// Spec: RFC 9000 Section 8.1 "Connection establishment implicitly provides address
// validation for both endpoints." - until then (handshaking), one remote host (any port) cannot hold
// more than MAX_HALF_OPEN_PER_HOST handshaking slots, and a refused Initial does not burn its
// Retry token (PC-6)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x61;
    const ubyte[12] tokenIv = 0x16;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 32);

    QuicConnection*[MAX_HALF_OPEN_PER_HOST] held;
    foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)
    {
        held[i] = admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203, 0,
                113, 5, cast(ushort)(5000 + i)), cast(ubyte)(0x20 + i), 1_000_000 + i);
        assert(held[i]!is null);
    }
    assert(ep.connectionCount == MAX_HALF_OPEN_PER_HOST);

    // Same host, new port: with every half-open slot validated nothing can be evicted, so the
    // Initial is dropped, nothing allocated, no reply.
    validateHalfOpen(ep);
    assert(admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203, 0, 113, 5,
            6000), 0x40, 2_000_000) is null);
    assert(ep.connectionCount == MAX_HALF_OPEN_PER_HOST);
    // Another host is unaffected.
    assert(admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203, 0, 113, 6,
            5000), 0x41, 2_000_001) !is null);
    assert(ep.connectionCount == MAX_HALF_OPEN_PER_HOST + 1);

    // A Retry token whose Initial is refused by the cap is not spent.
    ep.requireRetry = true;
    const SocketAddr host = SocketAddr.ipv4(203, 0, 113, 5, 7000);
    const ubyte[8] dcid = 0x71;
    const ubyte[8] scid = 0x72;
    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid[]),
            ConnectionId(dcid[]), tp, 3_000_000, client));
    ubyte[4096] d, withToken;
    ubyte[1500] resp;
    size_t len, respLen, tokenLen;
    QuicConnection* m;
    assert(client.pollTransmit(d[], 3_000_000, len));
    assert(feed(ep, host, d[0 .. len], 3_000_000, resp[], respLen, m) == TransportErrorCode.noError);
    assert(respLen > 0 && m is null, "Retry");
    assert(client.handleDatagram(resp[0 .. respLen], 3_000_000) == TransportErrorCode.noError);
    assert(client.pollTransmit(withToken[], 3_001_000, tokenLen));
    assert(feed(ep, host, withToken[0 .. tokenLen], 3_001_000, resp[], respLen,
            m) == TransportErrorCode.noError);
    assert(m is null && respLen == 0, "refused by the per-host cap");

    ep.closeConnection(held[0].localCid);
    assert(feed(ep, host, withToken[0 .. tokenLen], 3_002_000, resp[], respLen,
            m) == TransportErrorCode.noError);
    assert(m !is null, "the token survived the refused attempt");
    // Now it is spent.
    ep.closeConnection(m.localCid);
    QuicConnection* again;
    assert(feed(ep, host, withToken[0 .. tokenLen], 3_003_000, resp[], respLen,
            again) == TransportErrorCode.invalidToken);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x62;
/// const ubyte[12] tokenIv = 0x17;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
/// ubyte[60] pkt;                                   // a short header packet for an unknown connection
/// pkt[0] = 0x40;
/// pkt[1 .. 17] = 0x99;
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* m;
/// const ulong t0 = 10_000_000;
/// foreach (i; 0 .. STATELESS_RESET_BURST)          // one host, whatever ports it uses
/// {
///     const SocketAddr peer = SocketAddr.ipv4(198, 51, 100, 1, cast(ushort)(100 + i));
///     ep.handleDatagram(peer, pkt[], t0, resp[], respLen, m);
///     assert(respLen == 43);                       // within the burst a reset is sent
/// }
/// const SocketAddr late = SocketAddr.ipv4(198, 51, 100, 1, 9999);
/// ep.handleDatagram(late, pkt[], t0, resp[], respLen, m);
/// assert(respLen == 0);                            // the next one is not
/// ep.handleDatagram(late, pkt[], t0 + STATELESS_RESET_REFILL_MICROS, resp[], respLen, m);
/// assert(respLen == 43);                           // one token is back after the refill interval
/// ---
// Spec: RFC 9000 Section 10.3.3 "An endpoint can remember the number of Stateless Resets that it
// has sent and stop generating new Stateless Resets once a limit is reached. Using separate
// limits for different remote addresses will ensure that Stateless Resets can be used to close
// connections when other peers or connections have exhausted limits." (PC-7)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x62;
    const ubyte[12] tokenIv = 0x17;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);

    ubyte[1500] resp;
    size_t respLen;
    QuicConnection* m;
    ubyte[60] pkt;
    pkt[0] = 0x40;
    pkt[1 .. 17] = 0x99;

    const ulong t0 = 10_000_000;
    // One host exhausts its burst, whatever ports it uses.
    foreach (i; 0 .. STATELESS_RESET_BURST)
    {
        assert(feed(ep, SocketAddr.ipv4(198, 51, 100, 1, cast(ushort)(100 + i)),
                pkt[], t0, resp[], respLen, m) == TransportErrorCode.noError);
        assert(respLen == 43, "within the burst a reset is sent");
    }
    assert(feed(ep, SocketAddr.ipv4(198, 51, 100, 1, 9999), pkt[], t0, resp[], respLen, m) == TransportErrorCode
            .noError);
    assert(respLen == 0, "limit reached for this host");

    // Another host has its own limit.
    assert(feed(ep, SocketAddr.ipv4(198, 51, 100, 2, 1), pkt[], t0, resp[], respLen, m) == TransportErrorCode
            .noError);
    assert(respLen == 43);

    // Tokens come back with time: one per refill interval.
    assert(feed(ep, SocketAddr.ipv4(198, 51, 100, 1, 1), pkt[],
            t0 + STATELESS_RESET_REFILL_MICROS, resp[], respLen, m) == TransportErrorCode.noError);
    assert(respLen == 43);
    assert(feed(ep, SocketAddr.ipv4(198, 51, 100, 1, 1), pkt[],
            t0 + STATELESS_RESET_REFILL_MICROS, resp[], respLen, m) == TransportErrorCode.noError);
    assert(respLen == 0);

    // The endpoint as a whole is limited too: spoofed sources cannot sidestep the per-host limit.
    const ulong t1 = t0 + 100_000_000;
    size_t sent;
    foreach (i; 0 .. 4 * STATELESS_RESET_GLOBAL_BURST)
    {
        assert(feed(ep, SocketAddr.ipv4(192, 0, 2, cast(ubyte)(1 + i % 200), 1),
                pkt[], t1, resp[], respLen, m) == TransportErrorCode.noError);
        if (respLen == 43)
            sent++;
    }
    assert(sent == STATELESS_RESET_GLOBAL_BURST, "the endpoint-wide burst caps the total");
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x63;
/// const ubyte[12] tokenIv = 0x18;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 64);
/// ubyte[16] ip = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1];   // 2001:db8:0:1::1
/// foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)         // each from its own /128 of one /64
/// {
///     ip[15] = cast(ubyte)(i + 1);
///     admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv6(ip, cast(ushort)(4000 + i)),
///             cast(ubyte)(0x50 + i), 1_000_000 + i);
/// }
/// validateHalfOpen(ep);
/// ip[15] = 0xee;                                   // yet another interface id: still the same host
/// assert(admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv6(ip, 4100), 0x60, 2_000_000) is null);
/// foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)         // the IPv4 host 10.1.1.1 ...
///     admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(10, 1, 1, 1, cast(ushort)(5000 + i)),
///             cast(ubyte)(0x70 + i), 3_000_000 + i);
/// validateHalfOpen(ep);
/// ubyte[16] mapped = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 1, 1, 1];
/// assert(admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv6(mapped, 6000), 0x90, 3_100_000) is null);
/// ---
// Spec: RFC 9000 Section 8.1 "Connection establishment implicitly provides address validation for
// both endpoints." - until then a peer must not multiply its identity: an IPv6 host is its /64
// (one subscriber owns 2^64 addresses), an IPv4-mapped IPv6 address is the IPv4 host (Auditor M-2)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x63;
    const ubyte[12] tokenIv = 0x18;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 64);

    static SocketAddr v6(ubyte prefixLow, ubyte iface, ushort port) @safe pure @nogc nothrow
    {
        ubyte[16] ip = [
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, prefixLow, 0, 0, 0, 0, 0, 0, 0, iface
        ];
        return SocketAddr.ipv6(ip, port);
    }

    foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)
        assert(admitFreshClient(ep, clientCtx, tp, v6(1, cast(ubyte)(i + 1),
                cast(ushort)(4000 + i)), cast(ubyte)(0x50 + i), 1_000_000 + i) !is null);
    assert(ep.connectionCount == MAX_HALF_OPEN_PER_HOST);
    // Same /64, yet another interface identifier: the same host.
    validateHalfOpen(ep);
    assert(admitFreshClient(ep, clientCtx, tp, v6(1, 0xee, 4100), 0x60, 2_000_000) is null);
    assert(ep.connectionCount == MAX_HALF_OPEN_PER_HOST);
    // A different /64 is another host.
    assert(admitFreshClient(ep, clientCtx, tp, v6(2, 1, 4100), 0x61, 2_000_001) !is null);

    // IPv4-mapped IPv6 counts against the IPv4 host, and the reverse.
    foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)
        assert(admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(10, 1, 1, 1,
                cast(ushort)(5000 + i)), cast(ubyte)(0x70 + i), 3_000_000 + i) !is null);
    validateHalfOpen(ep);
    ubyte[16] mappedIp = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 1, 1, 1];
    assert(admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv6(mappedIp, 6000),
            0x90, 3_100_000) is null, "::ffff:10.1.1.1 is the host 10.1.1.1");
    ubyte[16] notMapped = [
        0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0xff, 0xff, 10, 1, 1, 1
    ];
    assert(admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv6(notMapped, 6000), 0x91,
            3_100_001) !is null, "a non-mapped address with the same tail is another host");
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x64;
/// const ubyte[12] tokenIv = 0x19;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* matched;
///
/// ubyte[60] pkt;
/// pkt[0] = 0x40;
/// pkt[1 .. 17] = 0x98;                       // a short header for a CID nobody knows
/// const ulong t0 = 10_000_000;
///
/// foreach (i; 0 .. STATELESS_RESET_BURST)    // eight hosts inside one /64 use up its bucket
/// {
///     ubyte[16] ip = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, cast(ubyte)(i + 1)];
///     assert(feed(ep, SocketAddr.ipv6(ip, 1), pkt[], t0, resp[], respLen, matched) == TransportErrorCode.noError);
///     assert(respLen == 43);
/// }
/// ubyte[16] sibling = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 7, 0xaa, 0, 0, 0, 0, 0, 0, 1];
/// assert(feed(ep, SocketAddr.ipv6(sibling, 2), pkt[], t0, resp[], respLen, matched) == TransportErrorCode.noError);
/// assert(respLen == 0);                      // another address of the same /64: no tokens left
/// ---
// Spec: RFC 9000 Section 10.3.3 "Using separate limits for different remote addresses will ensure
// that Stateless Resets can be used to close connections when other peers or connections have
// exhausted limits." - a peer is its IPv6 /64 or, for an IPv4-mapped address, its IPv4 address,
// so rotating addresses inside its own prefix does not buy it new tokens (Auditor M-2)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x64;
    const ubyte[12] tokenIv = 0x19;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
    ubyte[1500] resp;
    size_t respLen;
    QuicConnection* m;
    ubyte[60] pkt;
    pkt[0] = 0x40;
    pkt[1 .. 17] = 0x98;
    const ulong t0 = 10_000_000;

    foreach (i; 0 .. STATELESS_RESET_BURST)
    {
        ubyte[16] ip = [
            0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0,
            cast(ubyte)(i + 1)
        ];
        assert(feed(ep, SocketAddr.ipv6(ip, 1), pkt[], t0, resp[], respLen,
                m) == TransportErrorCode.noError);
        assert(respLen == 43);
    }
    ubyte[16] sibling = [
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 7, 0xaa, 0, 0, 0, 0, 0, 0, 1
    ];
    assert(feed(ep, SocketAddr.ipv6(sibling, 2), pkt[], t0, resp[], respLen,
            m) == TransportErrorCode.noError);
    assert(respLen == 0, "a sibling address of the same /64 has no tokens of its own");
    ubyte[16] other = [
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 1
    ];
    assert(feed(ep, SocketAddr.ipv6(other, 2), pkt[], t0, resp[], respLen,
            m) == TransportErrorCode.noError);
    assert(respLen == 43, "another /64 has its own bucket");

    foreach (i; 0 .. STATELESS_RESET_BURST)
        assert(feed(ep, SocketAddr.ipv4(198, 51, 100, 9, cast(ushort)(i + 1)),
                pkt[], t0, resp[], respLen, m) == TransportErrorCode.noError && respLen == 43);
    ubyte[16] mappedIp = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 198, 51, 100, 9
    ];
    assert(feed(ep, SocketAddr.ipv6(mappedIp, 9), pkt[], t0, resp[], respLen,
            m) == TransportErrorCode.noError);
    assert(respLen == 0, "::ffff:198.51.100.9 shares the bucket of 198.51.100.9");
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// tp.maxIdleTimeout = 0;                           // the idle timer is off: only the deadline remains
/// const ubyte[32] tokenSecret = 0x65;
/// const ubyte[12] tokenIv = 0x1a;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 1);
/// const ulong t0 = 1_000_000;
/// QuicConnection* m = admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203, 0, 113, 40, 4000),
///         0x41, t0);
/// m.peerAddressValidated = true;                   // validated, yet still handshaking
/// ep.onTimeout(t0 + HANDSHAKE_TIMEOUT_MICROS - 1); // still waiting
/// assert(ep.connectionCount == 1);
/// ep.onTimeout(t0 + HANDSHAKE_TIMEOUT_MICROS);     // deadline: the slot is reclaimed
/// assert(ep.connectionCount == 0);
/// ---
// Spec: RFC 9000 Section 8.1 "Connection establishment implicitly provides address validation for
// both endpoints." and Section 10.1 "Each endpoint advertises a max_idle_timeout, but the
// effective value at an endpoint is computed as the minimum of the two advertised values (or the
// sole advertised value, if only one endpoint advertises a non-zero value)." - with no idle
// timeout at all, and whether or not its address was validated, a half-open connection is closed
// after HANDSHAKE_TIMEOUT_MICROS counted from its allocation, not restarted by more Initials
// (Auditor M-2)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    tp.maxIdleTimeout = 0;
    const ubyte[32] tokenSecret = 0x65;
    const ubyte[12] tokenIv = 0x1a;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 1);

    const SocketAddr host = SocketAddr.ipv4(203, 0, 113, 40, 4000);
    const ubyte[8] dcid = 0x41;
    const ubyte[8] scid = 0x42;
    QuicConnection client;
    assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid[]),
            ConnectionId(dcid[]), tp, 1_000_000, client));
    ubyte[4096] d;
    ubyte[1500] resp;
    size_t len, respLen;
    QuicConnection* m;
    assert(client.pollTransmit(d[], 1_000_000, len));
    assert(feed(ep, host, d[0 .. len], 1_000_000, resp[], respLen, m) == TransportErrorCode.noError);
    assert(m !is null && ep.connectionCount == 1);
    m.peerAddressValidated = true; // validated, yet still handshaking

    // Another Initial for the same connection late in the period does not extend it.
    assert(feed(ep, host, d[0 .. len], 1_000_000 + HANDSHAKE_TIMEOUT_MICROS - 500_000,
            resp[], respLen, m) == TransportErrorCode.noError);
    ep.onTimeout(1_000_000 + HANDSHAKE_TIMEOUT_MICROS - 1);
    assert(ep.connectionCount == 1, "still inside the handshake period");
    ep.onTimeout(1_000_000 + HANDSHAKE_TIMEOUT_MICROS);
    assert(ep.connectionCount == 0, "a handshake that never finishes frees its slot");

    // Without onTimeout being driven, the next Initial reclaims an expired half-open slot
    // even though its address was validated and the table is full.
    QuicConnection* first = admitFreshClient(ep, clientCtx, tp, host, 0x43, 20_000_000);
    assert(first !is null && ep.connectionCount == 1);
    first.peerAddressValidated = true;
    QuicConnection* second = admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203,
            0, 113, 41, 4000), 0x44, 20_000_000 + HANDSHAKE_TIMEOUT_MICROS);
    assert(second !is null && ep.connectionCount == 1, "expired slot reclaimed for the new Initial");
    assert(ep.evictedCount == 0, "reclaiming an expired slot is not an eviction");
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
///         "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x66;
/// const ubyte[12] tokenIv = 0x1b;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 2);
/// const SocketAddr addr = SocketAddr.ipv4(192, 0, 2, 99, 4433);
/// ubyte[4096] firstToken;
/// size_t firstLen;
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* m;
/// enum size_t admissions = 64 + RETRY_NONCE_MEMORY + 2;   // more than the nonce memory holds
/// foreach (i; 0 .. admissions)
/// {
///     const ulong now = 1_000_000 + i * 10;
///     const ubyte[8] dcid = [0x80, 0, 0, 0, 0, 0, cast(ubyte)(i >> 8), cast(ubyte) i];
///     const ubyte[8] scid = [0x81, 0, 0, 0, 0, 0, cast(ubyte)(i >> 8), cast(ubyte) i];
///     QuicConnection client;
///     assert(QuicConnection.create(Side.client, clientCtx, ConnectionId(scid[]),
///             ConnectionId(dcid[]), tp, now, client));
///     ubyte[4096] initial, withToken;
///     size_t len, tokenLen;
///     assert(client.pollTransmit(initial[], now, len));
///     ep.handleDatagram(addr, initial[0 .. len], now, resp[], respLen, m);          // Retry
///     assert(client.handleDatagram(resp[0 .. respLen], now) == TransportErrorCode.noError);
///     assert(client.pollTransmit(withToken[], now + 1, tokenLen));
///     ep.handleDatagram(addr, withToken[0 .. tokenLen], now + 1, resp[], respLen, m);   // admitted
///     assert(m !is null);
///     if (i == 0)
///     {
///         firstToken[0 .. tokenLen] = withToken[0 .. tokenLen];
///         firstLen = tokenLen;
///     }
///     ep.closeConnection(m.localCid);
/// }
/// // the very first token is still refused
/// QuicConnection* again;
/// assert(ep.handleDatagram(addr, firstToken[0 .. firstLen], 1_000_000 + admissions * 10 + 5,
///         resp[], respLen, again) == TransportErrorCode.invalidToken);
/// ---
// Spec: RFC 9000 Section 8.1.4 "Servers are encouraged to allow tokens to be used only once, if
// possible; tokens MAY include additional information about clients to further narrow
// applicability or reuse." - a spent Retry token stays spent for its whole lifetime however many connections
// are admitted in between (the memory of spent nonces is bounded, and overwriting a live entry
// raises a floor below which tokens are refused) (Auditor L-3)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x66;
    const ubyte[12] tokenIv = 0x1b;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 2);

    const SocketAddr addr = SocketAddr.ipv4(192, 0, 2, 99, 4433);
    ubyte[4096] firstToken;
    size_t firstLen;
    ubyte[1500] resp;
    size_t respLen;
    QuicConnection* m;
    enum size_t admissions = 64 + RETRY_NONCE_MEMORY + 2;
    foreach (i; 0 .. admissions)
    {
        const ulong now = 1_000_000 + i * 10;
        ubyte[8] dcid = [0x80, 0, 0, 0, 0, 0, cast(ubyte)(i >> 8), cast(ubyte) i];
        ubyte[8] scid = [0x81, 0, 0, 0, 0, 0, cast(ubyte)(i >> 8), cast(ubyte) i];
        QuicConnection client;
        assert(QuicConnection.create(Side.client, clientCtx,
                ConnectionId(scid[]), ConnectionId(dcid[]), tp, now, client));
        ubyte[4096] d, withToken;
        size_t len, tokenLen;
        assert(client.pollTransmit(d[], now, len));
        assert(feed(ep, addr, d[0 .. len], now, resp[], respLen, m) == TransportErrorCode.noError);
        assert(respLen > 0 && m is null, "Retry");
        assert(client.handleDatagram(resp[0 .. respLen], now) == TransportErrorCode.noError);
        assert(client.pollTransmit(withToken[], now + 1, tokenLen));
        assert(feed(ep, addr, withToken[0 .. tokenLen], now + 1, resp[], respLen,
                m) == TransportErrorCode.noError);
        assert(m !is null, "admitted");
        if (i == 0)
        {
            firstToken[0 .. tokenLen] = withToken[0 .. tokenLen];
            firstLen = tokenLen;
        }
        ep.closeConnection(m.localCid);
    }
    QuicConnection* again;
    assert(feed(ep, addr, firstToken[0 .. firstLen], 1_000_000 + admissions * 10 + 5,
            resp[], respLen, again) == TransportErrorCode.invalidToken,
            "the first token is still spent");
    assert(again is null);
}

/// Example:
/// ---
/// static assert(STATELESS_RESET_GLOBAL_REFILL_MICROS < STATELESS_RESET_REFILL_MICROS);
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x67;
/// const ubyte[12] tokenIv = 0x1c;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* matched;
///
/// ubyte[60] pkt;
/// pkt[0] = 0x40;
/// pkt[1 .. 17] = 0x97;
///
/// // Drain the global bucket with many distinct hosts, one reset each.
/// const ulong t0 = 10_000_000;
/// foreach (i; 0 .. 2 * STATELESS_RESET_GLOBAL_BURST)
///     feed(ep, SocketAddr.ipv4(192, 0, 2, cast(ubyte)(1 + i), 1), pkt[], t0, resp[], respLen, matched);
///
/// // One second later the endpoint-wide bucket is full again.
/// size_t sent;
/// foreach (i; 0 .. 2 * STATELESS_RESET_GLOBAL_BURST)
/// {
///     feed(ep, SocketAddr.ipv4(198, 51, 100, cast(ubyte)(1 + i), 1), pkt[], t0 + 1_000_000, resp[], respLen, matched);
///     sent += respLen == 43;
/// }
/// assert(sent == STATELESS_RESET_GLOBAL_BURST);
/// ---
// Spec: RFC 9000 Section 10.3.3 "An endpoint can remember the number of Stateless Resets that it
// has sent and stop generating new Stateless Resets once a limit is reached." - the endpoint-wide
// budget refills faster than any single host's, so one host can never use up the whole budget
// (PC-7)
@nogc unittest
{
    static assert(STATELESS_RESET_GLOBAL_REFILL_MICROS < STATELESS_RESET_REFILL_MICROS);
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x67;
    const ubyte[12] tokenIv = 0x1c;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
    ubyte[1500] resp;
    size_t respLen;
    QuicConnection* m;
    ubyte[60] pkt;
    pkt[0] = 0x40;
    pkt[1 .. 17] = 0x97;

    // Drain the global bucket with many distinct hosts, one reset each.
    const ulong t0 = 10_000_000;
    size_t drained;
    foreach (i; 0 .. 2 * STATELESS_RESET_GLOBAL_BURST)
    {
        feed(ep, SocketAddr.ipv4(192, 0, 2, cast(ubyte)(1 + i), 1), pkt[], t0, resp[], respLen, m);
        drained += respLen == 43;
    }
    assert(drained == STATELESS_RESET_GLOBAL_BURST);

    // One second later the endpoint-wide bucket is full again.
    const ulong t1 = t0 + 1_000_000;
    size_t sent;
    foreach (i; 0 .. 2 * STATELESS_RESET_GLOBAL_BURST)
    {
        feed(ep, SocketAddr.ipv4(198, 51, 100, cast(ubyte)(1 + i), 1), pkt[],
                t1, resp[], respLen, m);
        sent += respLen == 43;
    }
    assert(sent == STATELESS_RESET_GLOBAL_BURST, "global refill outpaces a single host's");
    // ...whereas the one host that was refilling at its own rate has 10 tokens.
    size_t oneHost;
    foreach (i; 0 .. 20)
    {
        feed(ep, SocketAddr.ipv4(203, 0, 113, 77, cast(ushort)(1 + i)), pkt[],
                t1 + 10_000_000, resp[], respLen, m);
        oneHost += respLen == 43;
    }
    assert(oneHost == STATELESS_RESET_BURST, "a single host stays within its own burst");
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x68;
/// const ubyte[12] tokenIv = 0x1d;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 32);
///
/// // An attacker fills the cap of one host with Initials that spoof the victim's address ...
/// const SocketAddr victim = SocketAddr.ipv4(203, 0, 113, 9, 4000);
/// QuicConnection*[MAX_HALF_OPEN_PER_HOST] spoofed;
/// foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)
///     spoofed[i] = admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203, 0, 113, 9,
///             cast(ushort)(5000 + i)), cast(ubyte)(0x20 + i), 1_000_000 + i);
/// const ConnectionId oldest = spoofed[0].localCid;
///
/// // ... the real client behind that address is still admitted, the oldest spoofed slot goes.
/// QuicConnection* genuine = admitFreshClient(ep, clientCtx, tp, victim, 0x50, 2_000_000);
/// assert(genuine !is null && ep.connectionCount == MAX_HALF_OPEN_PER_HOST);
/// assert(ep.evictedCount == 1 && ep.findConnection(oldest) is null);
/// ---
// Spec: RFC 9000 Section 21.2 "During the creation of a connection, QUIC only provides protection
// against attacks from off the network path." - an off-path attacker can send decryptable
// Initials from the victim's address, so at the per-host cap the host's oldest half-open slot
// with an unvalidated address makes room for the new Initial instead of the new Initial being
// dropped (a lockout); when all of the host's half-open slots are validated it is dropped
// (Auditor M-1, R-19)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x68;
    const ubyte[12] tokenIv = 0x1d;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 32);

    const SocketAddr victim = SocketAddr.ipv4(203, 0, 113, 9, 4000);
    QuicConnection*[MAX_HALF_OPEN_PER_HOST] spoofed;
    foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)
    {
        spoofed[i] = admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203,
                0, 113, 9, cast(ushort)(5000 + i)), cast(ubyte)(0x20 + i), 1_000_000 + i);
        assert(spoofed[i]!is null);
    }
    const ConnectionId oldest = spoofed[0].localCid;
    const ConnectionId second = spoofed[1].localCid;

    QuicConnection* genuine = admitFreshClient(ep, clientCtx, tp, victim, 0x50, 2_000_000);
    assert(genuine !is null, "the victim's Initial is admitted at the cap");
    assert(ep.connectionCount == MAX_HALF_OPEN_PER_HOST);
    assert(ep.evictedCount == 1);
    assert(ep.findConnection(oldest) is null, "the oldest spoofed slot was evicted");
    assert(ep.findConnection(second) !is null, "only one slot is evicted");

    // Every half-open slot of the host validated: nothing may be evicted, the Initial is dropped.
    foreach (ref slot; ep.slots)
        if (slot.active)
            slot.conn.peerAddressValidated = true;
    assert(admitFreshClient(ep, clientCtx, tp, victim, 0x51, 3_000_000) is null);
    assert(ep.evictedCount == 1 && ep.connectionCount == MAX_HALF_OPEN_PER_HOST);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TlsContext clientCtx = TlsContext.createClientInsecure();
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x69;
/// const ubyte[12] tokenIv = 0x1e;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, MAX_HALF_OPEN_PER_HOST);   // table = cap
///
/// const SocketAddr victim = SocketAddr.ipv4(203, 0, 113, 10, 4000);
/// foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)
///     admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203, 0, 113, 10,
///             cast(ushort)(5000 + i)), cast(ubyte)(0x20 + i), 1_000_000 + i);
/// assert(ep.connectionCount == ep.capacity);
///
/// // The table is full as well: the real Initial is staged in the spare slot and the host's
/// // oldest half-open slot is evicted when it is admitted.
/// assert(admitFreshClient(ep, clientCtx, tp, victim, 0x50, 2_000_000) !is null);
/// assert(ep.connectionCount == ep.capacity && ep.evictedCount == 1);
/// ---
// Spec: RFC 9000 Section 21.2 "During the creation of a connection, QUIC only provides protection
// against attacks from off the network path." - the per-host eviction also works when the whole
// connection table is full, where the new connection is staged in the spare slot (Auditor M-1)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    TlsContext clientCtx = TlsContext.createClientInsecure();
    assert(serverCtx.isValid && clientCtx.isValid);
    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    const ubyte[32] tokenSecret = 0x69;
    const ubyte[12] tokenIv = 0x1e;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, MAX_HALF_OPEN_PER_HOST);

    const SocketAddr victim = SocketAddr.ipv4(203, 0, 113, 10, 4000);
    foreach (i; 0 .. MAX_HALF_OPEN_PER_HOST)
        assert(admitFreshClient(ep, clientCtx, tp, SocketAddr.ipv4(203, 0, 113,
                10, cast(ushort)(5000 + i)), cast(ubyte)(0x20 + i), 1_000_000 + i) !is null);
    assert(ep.connectionCount == ep.capacity);

    assert(admitFreshClient(ep, clientCtx, tp, victim, 0x50, 2_000_000) !is null);
    assert(ep.connectionCount == ep.capacity);
    assert(ep.evictedCount == 1);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x6a;
/// const ubyte[12] tokenIv = 0x1f;
///
/// ulong seen;
/// foreach (i; 0 .. 64)
/// {
///     QuicEndpoint ep;
///     ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 4);
///     seen |= ep.retryNonceCounter;       // the random start never reaches the upper half
///     ep.cleanup();
///     assert(ep.retryNonceCounter == 0);  // and does not outlive the endpoint
/// }
/// assert((seen >> 63) == 0);
/// ---
// Spec: RFC 9001 Section 5.3 "The nonce, N, is formed by combining the packet protection IV
// with the packet number." - a Retry token reuses its counter as the AEAD nonce, so the counter
// must not wrap and repeat a nonce: it starts in the lower half of the 64-bit range, and the
// state is cleared by cleanup() (Auditor L, item 5)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x6a;
    const ubyte[12] tokenIv = 0x1f;

    ulong seen;
    foreach (i; 0 .. 64)
    {
        QuicEndpoint ep;
        ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 4);
        seen |= ep.retryNonceCounter;
        ep.cleanup();
        assert(ep.retryNonceCounter == 0, "cleanup() clears the nonce counter");
    }
    assert((seen >> 63) == 0, "the counter starts below 2^63");
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x6b;
/// const ubyte[12] tokenIv = 0x20;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 4);
///
/// // A token is accepted up to and including the age RETRY_TOKEN_LIFETIME_MICROS, so its nonce
/// // is remembered up to and including that moment.
/// const ulong spentAt = 5_000_000;
/// ep.recordRetryNonce(42, spentAt);
/// assert(ep.isRetryNonceUsed(42, spentAt + RETRY_TOKEN_LIFETIME_MICROS));
/// assert(!ep.isRetryNonceUsed(42, spentAt + RETRY_TOKEN_LIFETIME_MICROS + 1));
/// ---
// Spec: RFC 9000 Section 8.1.4 "Servers are encouraged to allow tokens to be used only once, if
// possible; tokens MAY include additional information about clients to further narrow
// applicability or reuse." - token verification accepts a token whose age equals the lifetime,
// so a spent nonce must still be refused at exactly that age, not forgotten one tick early
// (Auditor L, item 5)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x6b;
    const ubyte[12] tokenIv = 0x20;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, true, 4);

    const ulong spentAt = 5_000_000;
    ep.recordRetryNonce(42, spentAt);
    assert(ep.isRetryNonceUsed(42, spentAt + RETRY_TOKEN_LIFETIME_MICROS - 1));
    assert(ep.isRetryNonceUsed(42, spentAt + RETRY_TOKEN_LIFETIME_MICROS));
    assert(!ep.isRetryNonceUsed(42, spentAt + RETRY_TOKEN_LIFETIME_MICROS + 1));
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x6c;
/// const ubyte[12] tokenIv = 0x21;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* matched;
///
/// ubyte[60] pkt;
/// pkt[0] = 0x40;
/// pkt[1 .. 17] = 0x99;                            // a short header for a CID nobody knows
/// const SocketAddr flooder = SocketAddr.ipv4(198, 51, 100, 7, 4000);
/// foreach (i; 0 .. 4 * STATELESS_RESET_BURST)
///     ep.handleDatagram(flooder, pkt[], 10_000_000, resp[], respLen, matched);
/// assert(ep.resetTokensComputed == STATELESS_RESET_BURST);   // refused packets cost no HMAC
/// ---
// Spec: RFC 9000 Section 10.3.3 "An endpoint can remember the number of Stateless Resets that it
// has sent and stop generating new Stateless Resets once a limit is reached." - the limit is
// checked before the reset token (an HMAC) is derived, so unmatched packets beyond the limit
// cost no cryptography (Auditor L, item 6)
@nogc unittest
{
    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x6c;
    const ubyte[12] tokenIv = 0x21;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
    ubyte[1500] resp;
    size_t respLen;
    QuicConnection* matched;

    ubyte[60] pkt;
    pkt[0] = 0x40;
    pkt[1 .. 17] = 0x99;
    const SocketAddr flooder = SocketAddr.ipv4(198, 51, 100, 7, 4000);
    size_t sent;
    foreach (i; 0 .. 4 * STATELESS_RESET_BURST)
    {
        assert(feed(ep, flooder, pkt[], 10_000_000, resp[], respLen,
                matched) == TransportErrorCode.noError);
        sent += respLen == 43;
    }
    assert(sent == STATELESS_RESET_BURST);
    assert(ep.resetTokensComputed == STATELESS_RESET_BURST, "refused packets cost no HMAC");
}
