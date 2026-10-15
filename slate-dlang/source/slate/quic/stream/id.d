module slate.quic.stream.id;

/**
 * QUIC Stream ID Classification and Stream States (RFC 9000 Section 2.1, Section 3.1, Section 3.2).
 *
 * Implements 62-bit Stream ID bitfield classification (Client/Server initiator,
 * Bidirectional/Unidirectional directionality, stream index) and RFC 9000 stream state enums.
 */

public import slate.quic.wire.cid : TransportErrorCode;
public import slate.quic.wire.varint : VARINT_MAX;
public import slate.quic.crypto.kdf : Side;

/**
 * Stream directionality (RFC 9000 Section 2.1).
 */
public enum StreamDirection : ubyte
{
    bidirectional = 0,
    unidirectional = 1
}

/**
 * Send stream states (RFC 9000 Section 3.1).
 */
public enum SendStreamState : ubyte
{
    ready = 0,
    send = 1,
    dataSent = 2,
    resetSent = 3,
    dataRecvd = 4,
    resetRecvd = 5
}

/**
 * Receive stream states (RFC 9000 Section 3.2).
 */
public enum RecvStreamState : ubyte
{
    recv = 0,
    sizeKnown = 1,
    dataRecvd = 2,
    resetRecvd = 3,
    dataRead = 4,
    resetRead = 5
}

/**
 * QUIC Stream Identifier (RFC 9000 Section 2.1).
 *
 * Bit 0x01: 0 = Client-initiated, 1 = Server-initiated.
 * Bit 0x02: 0 = Bidirectional, 1 = Unidirectional.
 * Bits 2..61: 60-bit stream index within that initiator/directionality space.
 */
public struct StreamId
{
    ulong id;

    invariant
    {
        assert(id <= VARINT_MAX, "StreamId must not exceed VARINT_MAX (62-bit integer)");
    }

    this(ulong id) @safe pure @nogc nothrow
    {
        assert(id <= VARINT_MAX, "StreamId must not exceed VARINT_MAX");
        this.id = id;
    }

    /**
     * Determines whether the stream was initiated by the Client or Server.
     */
    Side initiator() const @safe pure @nogc nothrow
    {
        return (id & 0x01) == 0 ? Side.client : Side.server;
    }

    /**
     * Determines whether the stream is bidirectional or unidirectional.
     */
    StreamDirection directionality() const @safe pure @nogc nothrow
    {
        return (id & 0x02) == 0 ? StreamDirection.bidirectional : StreamDirection.unidirectional;
    }

    /**
     * True if the stream is bidirectional.
     */
    bool isBidirectional() const @safe pure @nogc nothrow
    {
        return (id & 0x02) == 0;
    }

    /**
     * True if the stream is unidirectional.
     */
    bool isUnidirectional() const @safe pure @nogc nothrow
    {
        return (id & 0x02) != 0;
    }

    /**
     * True if initiated by the client.
     */
    bool isClientInitiated() const @safe pure @nogc nothrow
    {
        return (id & 0x01) == 0;
    }

    /**
     * True if initiated by the server.
     */
    bool isServerInitiated() const @safe pure @nogc nothrow
    {
        return (id & 0x01) != 0;
    }

    /**
     * Extracts the 60-bit sequential stream index within its initiator/directionality pool.
     */
    ulong streamIndex() const @safe pure @nogc nothrow
    {
        return id >> 2;
    }

    /**
     * Checks if the local endpoint side can send data on this stream.
     * RFC 9000 Section 2.1: Endpoints can send on bidirectional streams,
     * or on unidirectional streams that they initiated themselves.
     */
    bool canSend(Side localSide) const @safe pure @nogc nothrow
    {
        return isBidirectional() || (initiator() == localSide);
    }

    /**
     * Checks if the local endpoint side can receive data on this stream.
     * RFC 9000 Section 2.1: Endpoints can receive on bidirectional streams,
     * or on unidirectional streams initiated by their peer.
     */
    bool canReceive(Side localSide) const @safe pure @nogc nothrow
    {
        return isBidirectional() || (initiator() != localSide);
    }

    /**
     * Constructs a StreamId from initiator, directionality, and index.
     */
    static StreamId make(Side initiator, StreamDirection dir, ulong index) @safe pure @nogc nothrow
    {
        assert(index <= (VARINT_MAX >> 2), "Stream index exceeds 60-bit maximum");
        ulong val = (index << 2);
        if (dir == StreamDirection.unidirectional)
            val |= 0x02;
        if (initiator == Side.server)
            val |= 0x01;
        return StreamId(val);
    }

    bool opEquals(const StreamId other) const @safe pure @nogc nothrow
    {
        return id == other.id;
    }

    bool opEquals(ref const StreamId other) const @safe pure @nogc nothrow
    {
        return id == other.id;
    }
}

/// Example:
// Spec: RFC 9000 Section 2.1 - Stream Types and Identifiers (covers U1, U3, Scenario T3)
@nogc unittest
{
    // Stream 0: Client-initiated, Bidirectional (0x00)
    const s0 = StreamId(0);
    assert(s0.initiator == Side.client);
    assert(s0.directionality == StreamDirection.bidirectional);
    assert(s0.isBidirectional);
    assert(!s0.isUnidirectional);
    assert(s0.isClientInitiated);
    assert(!s0.isServerInitiated);
    assert(s0.streamIndex == 0);
    assert(s0.canSend(Side.client));
    assert(s0.canReceive(Side.client));
    assert(s0.canSend(Side.server));
    assert(s0.canReceive(Side.server));

    // Stream 1: Server-initiated, Bidirectional (0x01)
    const s1 = StreamId(1);
    assert(s1.initiator == Side.server);
    assert(s1.directionality == StreamDirection.bidirectional);
    assert(s1.streamIndex == 0);

    // Stream 2: Client-initiated, Unidirectional (0x02)
    const s2 = StreamId(2);
    assert(s2.initiator == Side.client);
    assert(s2.directionality == StreamDirection.unidirectional);
    assert(s2.isUnidirectional);
    assert(s2.streamIndex == 0);
    assert(s2.canSend(Side.client));
    assert(!s2.canReceive(Side.client));
    assert(!s2.canSend(Side.server));
    assert(s2.canReceive(Side.server));

    // Stream 3: Server-initiated, Unidirectional (0x03)
    const s3 = StreamId(3);
    assert(s3.initiator == Side.server);
    assert(s3.directionality == StreamDirection.unidirectional);
    assert(s3.streamIndex == 0);
    assert(!s3.canSend(Side.client));
    assert(s3.canReceive(Side.client));
    assert(s3.canSend(Side.server));
    assert(!s3.canReceive(Side.server));

    // Stream 4: Client-initiated, Bidirectional, Index 1
    const s4 = StreamId(4);
    assert(s4.initiator == Side.client);
    assert(s4.isBidirectional);
    assert(s4.streamIndex == 1);

    // StreamId.make verification
    assert(StreamId.make(Side.client, StreamDirection.bidirectional, 0) == s0);
    assert(StreamId.make(Side.server, StreamDirection.bidirectional, 0) == s1);
    assert(StreamId.make(Side.client, StreamDirection.unidirectional, 0) == s2);
    assert(StreamId.make(Side.server, StreamDirection.unidirectional, 0) == s3);
    assert(StreamId.make(Side.client, StreamDirection.bidirectional, 1) == s4);
}

/// Example:
// Spec: RFC 9000 Section 3.1 & Section 3.2 - Stream State Enumerations (covers U1, U3)
@nogc unittest
{
    SendStreamState sState = SendStreamState.ready;
    assert(sState == SendStreamState.ready);
    sState = SendStreamState.send;
    assert(sState == SendStreamState.send);
    sState = SendStreamState.dataSent;
    assert(sState == SendStreamState.dataSent);
    sState = SendStreamState.resetSent;
    assert(sState == SendStreamState.resetSent);
    sState = SendStreamState.dataRecvd;
    assert(sState == SendStreamState.dataRecvd);
    sState = SendStreamState.resetRecvd;
    assert(sState == SendStreamState.resetRecvd);

    RecvStreamState rState = RecvStreamState.recv;
    assert(rState == RecvStreamState.recv);
    rState = RecvStreamState.sizeKnown;
    assert(rState == RecvStreamState.sizeKnown);
    rState = RecvStreamState.dataRecvd;
    assert(rState == RecvStreamState.dataRecvd);
    rState = RecvStreamState.resetRecvd;
    assert(rState == RecvStreamState.resetRecvd);
    rState = RecvStreamState.dataRead;
    assert(rState == RecvStreamState.dataRead);
    rState = RecvStreamState.resetRead;
    assert(rState == RecvStreamState.resetRead);
}
