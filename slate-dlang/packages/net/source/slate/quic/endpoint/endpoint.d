module slate.quic.endpoint.endpoint;

/**
 * QUIC Server Endpoint Connection Router (RFC 9000 Section 6, 8.1, 10.3 & 14.1).
 *
 * Implements a Sans-I/O connection multiplexer and packet dispatcher supporting:
 * - Version Negotiation packet emission for unknown QUIC versions
 * - Stateless Retry token emission and validation (zero-allocation defense against DoS)
 * - Stateless Reset packet emission for unrecognized Short Header packets
 * - Coalesced packet routing across multiple concurrent QuicConnection instances
 */

import slate.quic.crypto.tls_session : TlsContext;
import slate.quic.crypto.aead : computeRetryIntegrityTag;
import slate.quic.wire.cid : ConnectionId, StatelessResetToken, TransportErrorCode;
import slate.quic.wire.packet : PacketType, PacketPrefix, parsePacketPrefix,
    encodeVersionNegotiationPacket, encodeRetryPacket, QUIC_VERSION_1, WireError;
import slate.quic.wire.transport_params : TransportParameters;
import slate.quic.crypto.kdf : Side;
import slate.quic.connection.connection : QuicConnection, ConnectionState;
import slate.quic.endpoint.token : SocketAddr, RetryTokenPayload, RetryTokenCodec;

/**
 * Slot holding a managed server QuicConnection entry.
 */
public struct ConnectionSlot
{
    bool active;
    SocketAddr peerAddr;
    ConnectionId localCid;
    QuicConnection conn;
}

/**
 * Sans-I/O Server QuicEndpoint routing datagrams to QuicConnection state machines.
 */
public struct QuicEndpoint
{
    @disable this(this);

private:
    ConnectionSlot* m_slots;
    size_t m_capacity;
    size_t m_activeCount;
    TlsContext* m_tlsCtx;
    TransportParameters m_serverParams;
    RetryTokenCodec m_tokenCodec;
    bool m_requireRetry;
    StatelessResetToken m_resetToken;
    uint[4] m_supportedVersions;
    size_t m_numSupportedVersions;
    ulong m_retryNonceCounter;
    ulong[64] m_usedRetryNonces;
    size_t m_usedRetryCount;
    size_t m_nextPollIndex;

public:
     ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        if (m_slots !is null)
        {
            foreach (i; 0 .. m_capacity)
            {
                if (m_slots[i].active)
                {
                    m_slots[i].conn.cleanup();
                    m_slots[i].active = false;
                }
            }
            import core.stdc.stdlib : free;

            free(m_slots);
            m_slots = null;
        }
        m_activeCount = 0;
        m_capacity = 0;
        m_tokenCodec.cleanup();
        m_tlsCtx = null;
        m_usedRetryCount = 0;
        m_nextPollIndex = 0;
        foreach (ref n; m_usedRetryNonces)
            n = 0;
    }

    void moveFrom(ref QuicEndpoint other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        this.m_slots = other.m_slots;
        this.m_capacity = other.m_capacity;
        this.m_activeCount = other.m_activeCount;
        this.m_tlsCtx = other.m_tlsCtx;
        this.m_serverParams = other.m_serverParams;
        this.m_tokenCodec.moveFrom(other.m_tokenCodec);
        this.m_requireRetry = other.m_requireRetry;
        this.m_resetToken = other.m_resetToken;
        this.m_supportedVersions = other.m_supportedVersions;
        this.m_numSupportedVersions = other.m_numSupportedVersions;
        this.m_retryNonceCounter = other.m_retryNonceCounter;
        this.m_usedRetryNonces = other.m_usedRetryNonces;
        this.m_usedRetryCount = other.m_usedRetryCount;
        this.m_nextPollIndex = other.m_nextPollIndex;

        other.m_slots = null;
        other.m_capacity = 0;
        other.m_activeCount = 0;
        other.m_tlsCtx = null;
        other.m_retryNonceCounter = 0;
        other.m_usedRetryCount = 0;
        other.m_nextPollIndex = 0;
        foreach (ref n; other.m_usedRetryNonces)
            n = 0;
    }

    /**
     * Initializes the server QuicEndpoint with TLS context, transport parameters,
     * Retry token codec secrets, Stateless Reset token, and connection capacity.
     */
    void init(ref TlsContext tlsCtx, ref const TransportParameters params, const ref ubyte[32] tokenSecret,
            const ref ubyte[12] tokenIv, const ref StatelessResetToken resetToken,
            bool requireRetry = false, size_t capacity = 128) @trusted @nogc nothrow
    {
        cleanup();

        import core.stdc.stdlib : calloc;

        m_capacity = (capacity > 0) ? capacity : 128;
        m_slots = cast(ConnectionSlot*) calloc(m_capacity, ConnectionSlot.sizeof);
        if (m_slots is null)
            return;

        m_tlsCtx = &tlsCtx;
        m_serverParams = params;
        m_tokenCodec.init(tokenSecret, tokenIv);
        m_resetToken = resetToken;
        m_requireRetry = requireRetry;
        m_activeCount = 0;
        m_nextPollIndex = 0;

        import slate.quic.crypto.c_openssl : RAND_bytes;

        RAND_bytes(cast(ubyte*)&m_retryNonceCounter, ulong.sizeof);

        m_supportedVersions[0] = QUIC_VERSION_1;
        m_numSupportedVersions = 1;
    }

    @property size_t connectionCount() const @safe pure @nogc nothrow
    {
        return m_activeCount;
    }

    @property size_t capacity() const @safe pure @nogc nothrow
    {
        return m_capacity;
    }

    @property bool requireRetry() const @safe pure @nogc nothrow
    {
        return m_requireRetry;
    }

    @property void requireRetry(bool req) @safe pure @nogc nothrow
    {
        m_requireRetry = req;
    }

    @property const(StatelessResetToken) statelessResetToken() const @safe pure @nogc nothrow
    {
        return m_resetToken;
    }

    /**
     * Finds active connection by server's local connection ID.
     */
    QuicConnection* findConnection(const ref ConnectionId cid) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return null;

        foreach (ref slot; m_slots[0 .. m_capacity])
        {
            if (slot.active && (slot.localCid == cid || slot.conn.localCid == cid))
            {
                return &slot.conn;
            }
        }
        return null;
    }

    /**
     * Finds active connection by client's SocketAddr.
     */
    QuicConnection* findConnectionByPeer(const ref SocketAddr peerAddr) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return null;

        foreach (ref slot; m_slots[0 .. m_capacity])
        {
            if (slot.active && slot.peerAddr == peerAddr)
            {
                return &slot.conn;
            }
        }
        return null;
    }

    /**
     * Returns the slice of connection slots managed by this endpoint.
     */
    @property ConnectionSlot[] slots() return @trusted @nogc nothrow pure
    {
        if (m_slots is null || m_capacity == 0)
            return null;
        return m_slots[0 .. m_capacity];
    }

    /**
     * Explicitly closes and deallocates a connection by connection ID.
     */
    void closeConnection(const ref ConnectionId cid) @trusted @nogc nothrow
    {
        deallocateSlot(cid);
    }

    /**
     * Advances timers across all active connections and cleans up expired connections.
     */
    void onTimeout(ulong nowMicros) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return;

        foreach (ref slot; m_slots[0 .. m_capacity])
        {
            if (slot.active)
            {
                slot.conn.onTimeout(nowMicros);
                if (slot.conn.state == ConnectionState.closed)
                {
                    slot.conn.cleanup();
                    slot.active = false;
                    slot.localCid = ConnectionId.init;
                    m_activeCount--;
                }
            }
        }
    }

    /**
     * Ingests an incoming UDP datagram from peerAddr.
     *
     * Handles Version Negotiation, Stateless Retry, Stateless Reset, and connection routing.
     */
    TransportErrorCode handleDatagram(const ref SocketAddr peerAddr, const(ubyte)[] datagram, ulong nowMicros,
            ubyte[] outResponse, out size_t responseLen, out QuicConnection* matchedConn) @trusted @nogc nothrow
    {
        responseLen = 0;
        matchedConn = null;

        if (datagram.length == 0)
            return TransportErrorCode.noError;

        const bool isLong = (datagram[0] & 0x80) != 0;

        // 1. Universal Long Header Version Negotiation (RFC 9000 Section 6 & 17.2)
        if (isLong && datagram.length >= 7)
        {
            const uint ver = (cast(uint) datagram[1] << 24) | (cast(
                    uint) datagram[2] << 16) | (cast(uint) datagram[3] << 8) | cast(uint) datagram[4];

            if (ver != 0) // 0 is Version Negotiation itself
            {
                bool versionSupported = false;
                foreach (i; 0 .. m_numSupportedVersions)
                {
                    if (ver == m_supportedVersions[i])
                    {
                        versionSupported = true;
                        break;
                    }
                }

                if (!versionSupported)
                {
                    const ubyte dcidLen = datagram[5];
                    if (dcidLen <= 20 && datagram.length >= 6 + dcidLen + 1)
                    {
                        ConnectionId pktDcid = ConnectionId(datagram[6 .. 6 + dcidLen]);
                        const size_t scidOff = 6 + dcidLen;
                        const ubyte scidLen = datagram[scidOff];
                        if (scidLen <= 20 && datagram.length >= scidOff + 1 + scidLen)
                        {
                            ConnectionId pktScid = ConnectionId(
                                    datagram[scidOff + 1 .. scidOff + 1 + scidLen]);
                            const err = encodeVersionNegotiationPacket(pktScid, pktDcid,
                                    m_supportedVersions[0 .. m_numSupportedVersions],
                                    outResponse, responseLen);
                            return (err == WireError.none) ? TransportErrorCode.noError
                                : TransportErrorCode.internalError;
                        }
                    }
                    return TransportErrorCode.noError;
                }
            }
        }

        if (!isLong)
        {
            // Route Short Header to active connection by checking slot.localCid (F-12)
            if (m_slots !is null)
            {
                foreach (ref slot; m_slots[0 .. m_capacity])
                {
                    if (slot.active)
                    {
                        const ubyte cidLen = slot.localCid.len;
                        if (cidLen > 0 && datagram.length >= 1 + cidLen)
                        {
                            if (datagram[1 .. 1 + cidLen] == slot.localCid.asSlice())
                            {
                                matchedConn = &slot.conn;
                                return slot.conn.handleDatagram(datagram, nowMicros);
                            }
                        }
                    }
                }
            }

            // 3. Unmatched Short Header (RFC 9000 Section 10.3: Stateless Reset) (F-25)
            import slate.quic.crypto.c_openssl : CRYPTO_memcmp, RAND_bytes;

            if (datagram.length >= 16 && CRYPTO_memcmp(datagram.ptr + datagram.length - 16,
                    m_resetToken.ptr, 16) == 0)
                return TransportErrorCode.noError;

            if (datagram.length >= 44 && outResponse.length >= 43)
            {
                const size_t resetLen = 43;
                outResponse[0] = 0x40 | 0x1a; // Short header with Fixed bit = 1
                RAND_bytes(outResponse.ptr + 1, resetLen - 17);
                outResponse[resetLen - 16 .. resetLen] = m_resetToken[];
                responseLen = resetLen;
            }
            return TransportErrorCode.noError;
        }

        PacketPrefix prefix;
        const parseErr = parsePacketPrefix(datagram, 8, prefix);
        if (parseErr != WireError.none)
            return TransportErrorCode.noError;

        // 2. Route Long Header to existing active connection
        if (m_slots !is null)
        {
            foreach (ref slot; m_slots[0 .. m_capacity])
            {
                if (slot.active)
                {
                    if (slot.localCid == prefix.dcid || slot.conn.localCid == prefix.dcid)
                    {
                        matchedConn = &slot.conn;
                        return slot.conn.handleDatagram(datagram, nowMicros);
                    }
                }
            }
        }

        // 4. Client Initial Packet (RFC 9000 Section 14.1 & Section 17.2)
        if (prefix.type == PacketType.initial)
        {
            // Drop undersized Client Initial (< 1200 bytes) silently
            if (datagram.length < 1200)
                return TransportErrorCode.noError;

            if (m_requireRetry)
            {
                // 4a. Client Initial without Retry Token -> Emit Stateless Retry (RFC 9000 §8.1.2)
                if (prefix.token.length == 0)
                {
                    m_retryNonceCounter++;
                    ubyte[8] retryScidBytes;
                    retryScidBytes[0 .. 4] = peerAddr.ip[0 .. 4];
                    retryScidBytes[4] = cast(ubyte)(peerAddr.port >> 8);
                    retryScidBytes[5] = cast(ubyte)(peerAddr.port & 0xff);
                    retryScidBytes[6] = cast(ubyte)(m_retryNonceCounter & 0xff);
                    retryScidBytes[7] = cast(ubyte)((m_retryNonceCounter >> 8) & 0xff);
                    if (retryScidBytes[0 .. 8] == prefix.dcid.asSlice())
                    {
                        retryScidBytes[6] ^= 0x5a;
                    }
                    ConnectionId retryScid = ConnectionId(retryScidBytes[]);

                    RetryTokenPayload rPayload;
                    rPayload.clientAddr = peerAddr;
                    rPayload.origDcid = prefix.dcid;
                    rPayload.retryScid = retryScid;
                    rPayload.issuedMicros = nowMicros;

                    ubyte[128] tokenBuf;
                    size_t tokenLen = 0;
                    if (!m_tokenCodec.sealToken(rPayload, m_retryNonceCounter,
                            tokenBuf[], tokenLen))
                        return TransportErrorCode.internalError;

                    ubyte[16] dummyTag;
                    if (encodeRetryPacket(QUIC_VERSION_1, prefix.scid, retryScid,
                            tokenBuf[0 .. tokenLen], dummyTag, outResponse, responseLen) != WireError
                            .none)
                    {
                        return TransportErrorCode.internalError;
                    }

                    // Compute and place RFC 9001 Section 5.8 Retry Integrity Tag
                    ubyte[16] tag;
                    computeRetryIntegrityTag(prefix.dcid.asSlice(),
                            outResponse[0 .. responseLen - 16], tag);
                    outResponse[responseLen - 16 .. responseLen] = tag[];
                    return TransportErrorCode.noError; // 0 connection state allocated!
                }
                else
                {
                    // 4b. Client Initial with Retry Token -> Verify Token (RFC 9000 §8.1.3)
                    RetryTokenPayload verified;
                    const ulong maxLifetime = 30_000_000; // 30 seconds
                    const vErr = m_tokenCodec.verifyToken(prefix.token,
                            peerAddr, prefix.dcid, nowMicros, maxLifetime, verified);
                    if (vErr != TransportErrorCode.noError)
                    {
                        return vErr;
                    }

                    // Check for token replay (F-13)
                    const size_t checkCount = (m_usedRetryCount < 64) ? m_usedRetryCount : 64;
                    foreach (i; 0 .. checkCount)
                    {
                        if (m_usedRetryNonces[i] == verified.nonceCounter)
                        {
                            return TransportErrorCode.invalidToken;
                        }
                    }
                    m_usedRetryNonces[m_usedRetryCount % 64] = verified.nonceCounter;
                    m_usedRetryCount++;

                    // Valid Retry token! Allocate new Server connection with addressValidated = true
                    TransportParameters tp = m_serverParams;
                    tp.hasOriginalDestinationConnectionId = true;
                    tp.originalDestinationConnectionId = verified.origDcid;
                    tp.hasRetrySourceConnectionId = true;
                    tp.retrySourceConnectionId = verified.retryScid;
                    tp.hasInitialSourceConnectionId = true;
                    tp.initialSourceConnectionId = prefix.dcid;

                    QuicConnection* newConn = allocateSlot(peerAddr, prefix.dcid, nowMicros);
                    if (newConn is null)
                        return TransportErrorCode.internalError;

                    if (!QuicConnection.create(Side.server, *m_tlsCtx, prefix.dcid,
                            ConnectionId.init, tp, nowMicros, *newConn, true))
                    {
                        deallocateSlot(prefix.dcid);
                        return TransportErrorCode.internalError;
                    }

                    const err = newConn.handleDatagram(datagram, nowMicros);
                    if (err != TransportErrorCode.noError || newConn.ackRanges[0].empty)
                    {
                        deallocateSlot(prefix.dcid);
                        matchedConn = null;
                        return err;
                    }

                    matchedConn = newConn;
                    return err;
                }
            }
            else
            {
                // Normal Client Initial without Retry
                TransportParameters tp = m_serverParams;
                tp.hasOriginalDestinationConnectionId = true;
                tp.originalDestinationConnectionId = prefix.dcid;
                tp.hasInitialSourceConnectionId = true;
                tp.initialSourceConnectionId = prefix.dcid;

                QuicConnection* newConn = allocateSlot(peerAddr, prefix.dcid, nowMicros);
                if (newConn is null)
                    return TransportErrorCode.internalError;

                if (!QuicConnection.create(Side.server, *m_tlsCtx, prefix.dcid,
                        ConnectionId.init, tp, nowMicros, *newConn, false))
                {
                    deallocateSlot(prefix.dcid);
                    return TransportErrorCode.internalError;
                }

                const err = newConn.handleDatagram(datagram, nowMicros);
                if (err != TransportErrorCode.noError || newConn.ackRanges[0].empty)
                {
                    deallocateSlot(prefix.dcid);
                    matchedConn = null;
                    return err;
                }

                matchedConn = newConn;
                return err;
            }
        }

        return TransportErrorCode.noError;
    }

    /**
     * Polls pending outgoing transmissions across all active connections.
     */
    bool pollTransmit(out SocketAddr outPeerAddr, ubyte[] outDatagram,
            ulong nowMicros, out size_t bytesWritten) @trusted @nogc nothrow
    {
        outPeerAddr = SocketAddr.init;
        bytesWritten = 0;

        if (m_slots is null || outDatagram.length == 0 || m_capacity == 0)
            return false;

        const size_t startIdx = m_nextPollIndex % m_capacity;
        foreach (step; 0 .. m_capacity)
        {
            const size_t idx = (startIdx + step) % m_capacity;
            ref ConnectionSlot slot = m_slots[idx];
            if (slot.active)
            {
                if (slot.conn.pollTransmit(outDatagram, nowMicros, bytesWritten))
                {
                    outPeerAddr = slot.peerAddr;
                    m_nextPollIndex = (idx + 1) % m_capacity;
                    return true;
                }
            }
        }

        return false;
    }

private:
    QuicConnection* allocateSlot(const ref SocketAddr peerAddr,
            const ref ConnectionId localCid, ulong nowMicros) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return null;

        // 1. First pass: find an inactive slot
        foreach (ref slot; m_slots[0 .. m_capacity])
        {
            if (!slot.active)
            {
                slot.active = true;
                slot.peerAddr = peerAddr;
                slot.localCid = localCid;
                m_activeCount++;
                return &slot.conn;
            }
        }

        // 2. Second pass: reclaim closed or expired draining connections (F-25, D-09)
        foreach (ref slot; m_slots[0 .. m_capacity])
        {
            if (slot.active && (slot.conn.state == ConnectionState.closed
                    || (slot.conn.state == ConnectionState.draining
                    && nowMicros >= slot.conn.drainingEndTimeMicros)))
            {
                slot.conn.cleanup();
                slot.active = true;
                slot.peerAddr = peerAddr;
                slot.localCid = localCid;
                return &slot.conn;
            }
        }

        return null;
    }

    void deallocateSlot(const ref ConnectionId localCid) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return;

        foreach (ref slot; m_slots[0 .. m_capacity])
        {
            if (slot.active && (slot.localCid == localCid || slot.conn.localCid == localCid))
            {
                slot.conn.cleanup();
                slot.active = false;
                slot.localCid = ConnectionId.init;
                m_activeCount--;
                return;
            }
        }
    }
}

/// Example:
// Spec: RFC 9000 Section 6 - Version Negotiation Packet Routing (covers U1, U2, U3, E4)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    TlsContext serverCtx = makeServerCtx();
    assert(serverCtx.isValid);

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

    QuicEndpoint endpoint;
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, resetToken, false, 16);
    assert(endpoint.capacity == 16);
    assert(endpoint.connectionCount == 0);

    const SocketAddr clientAddr = SocketAddr.ipv4(127, 0, 0, 1, 44333);
    const ubyte[8] dcidBytes = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
    const ubyte[8] scidBytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    // Packet with unsupported version 0x1a2a3a4a
    ubyte[1200] unknownVerPacket;
    unknownVerPacket[0] = 0xc0; // Long header
    unknownVerPacket[1] = 0x1a;
    unknownVerPacket[2] = 0x2a;
    unknownVerPacket[3] = 0x3a;
    unknownVerPacket[4] = 0x4a; // Version
    unknownVerPacket[5] = 8;
    unknownVerPacket[6 .. 14] = dcidBytes[];
    unknownVerPacket[14] = 8;
    unknownVerPacket[15 .. 23] = scidBytes[];

    ubyte[1500] respBuf;
    size_t respLen = 0;
    QuicConnection* matched = null;
    assert(endpoint.handleDatagram(clientAddr, unknownVerPacket[], 1_000_000,
            respBuf[], respLen, matched) == TransportErrorCode.noError);
    assert(matched is null);
    assert(respLen > 0);

    // Verify response is Version Negotiation packet
    PacketPrefix vnPrefix;
    assert(parsePacketPrefix(respBuf[0 .. respLen], 8, vnPrefix) == WireError.none);
    assert(vnPrefix.type == PacketType.versionNegotiation);
    assert(vnPrefix.dcid == scid);
    assert(vnPrefix.scid == dcid);
    assert(endpoint.connectionCount == 0);
}

/// Example:
// Spec: RFC 9000 Section 10.3 - Stateless Reset Emission for Unrecognized Short Header (covers U1, U2, U3, E4)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    TlsContext serverCtx = makeServerCtx();
    assert(serverCtx.isValid);

    TransportParameters tp;
    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    const ubyte[16] resetToken = [
        0xde, 0xad, 0xbe, 0xef, 0xfe, 0xed, 0xfa, 0xce, 0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0xde, 0xf0
    ];

    QuicEndpoint endpoint;
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, resetToken, false, 16);

    const SocketAddr clientAddr = SocketAddr.ipv4(10, 0, 0, 5, 54321);

    // Unrecognized Short Header packet of length 50 (>= 43)
    ubyte[50] unknownShortPkt;
    unknownShortPkt[0] = 0x40; // Short header (Header form = 0, Fixed bit = 1)
    unknownShortPkt[1 .. 9] = 0x77; // Unknown DCID

    ubyte[1500] respBuf;
    size_t respLen = 0;
    QuicConnection* matched = null;
    assert(endpoint.handleDatagram(clientAddr, unknownShortPkt[], 1_000_000,
            respBuf[], respLen, matched) == TransportErrorCode.noError);
    assert(matched is null);
    assert(respLen >= 43, "Stateless Reset must be at least 43 bytes");
    assert((respBuf[0] & 0x80) == 0, "Stateless Reset must be short header form");
    assert((respBuf[0] & 0x40) != 0, "Stateless Reset must have fixed bit 1");

    // The last 16 bytes must match resetToken
    assert(respBuf[respLen - 16 .. respLen] == resetToken[]);
}
