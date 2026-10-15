module slate.quic.stream.stream_map;

/**
 * QUIC Multiplexed Stream Map and Concurrency Management (RFC 9000 Section 2, Section 3, Section 4).
 *
 * Implements stream lifecycle management, stream limit enforcement (STREAM_LIMIT_ERROR 0x04),
 * stream state validation (STREAM_STATE_ERROR 0x05), implicit lower-indexed stream opening,
 * connection-level and stream-level flow control coordination (FLOW_CONTROL_ERROR 0x03),
 * and round-robin transmit polling.
 */

public import slate.quic.stream.id;
public import slate.quic.stream.recv_buffer;
public import slate.quic.stream.send_buffer;
public import slate.quic.stream.flow_control;
public import slate.quic.wire.frame;
public import slate.quic.wire.transport_params : TransportParameters;
public import slate.quic.wire.cid : TransportErrorCode;
public import slate.quic.wire.varint : VARINT_MAX;
public import slate.quic.crypto.kdf : Side;

import core.stdc.stdlib : calloc, realloc, free;

public enum size_t MAX_CONCURRENT_STREAMS_CEILING = 1024;

/**
 * Full state and buffers for a single multiplexed QUIC stream.
 */
public struct QuicStream
{
    @disable this(this);

    StreamId id;
    SendStreamState sendState = SendStreamState.ready;
    RecvStreamState recvState = RecvStreamState.recv;

    RecvBuffer recvBuf;
    SendBuffer sendBuf;
    FlowController flowCtrl;

    ulong applicationErrorCode = 0;
    bool resetReceived = false;
    bool stopSendingReceived = false;
    bool resetSent = false;
    bool stopSendingSent = false;
    bool resetQueued = false;
    bool stopSendingQueued = false;

    this(StreamId id, ulong initialLocalWindow, ulong initialRemoteWindow) @safe @nogc nothrow
    {
        this.id = id;
        this.flowCtrl = FlowController(initialLocalWindow, initialRemoteWindow);
        this.recvBuf = RecvBuffer(DEFAULT_MAX_BUFFER_CAPACITY);
    }

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        recvBuf.cleanup();
        sendBuf.cleanup();
    }

    void moveFrom(ref QuicStream other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        this.id = other.id;
        this.sendState = other.sendState;
        this.recvState = other.recvState;
        this.recvBuf.moveFrom(other.recvBuf);
        this.sendBuf.moveFrom(other.sendBuf);
        this.flowCtrl = other.flowCtrl;
        this.applicationErrorCode = other.applicationErrorCode;
        this.resetReceived = other.resetReceived;
        this.stopSendingReceived = other.stopSendingReceived;
        this.resetSent = other.resetSent;
        this.stopSendingSent = other.stopSendingSent;
        this.resetQueued = other.resetQueued;
        this.stopSendingQueued = other.stopSendingQueued;
    }
}

/**
 * Multiplexed stream table and concurrency manager.
 */
public struct StreamMap
{
    @disable this(this);

    Side localSide = Side.client;

    FlowController connFlow;

    ulong localMaxStreamsBidi = 0;
    ulong localMaxStreamsUni = 0;
    ulong remoteMaxStreamsBidi = 0;
    ulong remoteMaxStreamsUni = 0;

    ulong initialMaxStreamDataBidiLocal = 0;
    ulong initialMaxStreamDataBidiRemote = 0;
    ulong initialMaxStreamDataUni = 0;

    ulong nextLocalBidiIndex = 0;
    ulong nextLocalUniIndex = 0;
    ulong nextExpectedPeerBidiIndex = 0;
    ulong nextExpectedPeerUniIndex = 0;

    private QuicStream* streams = null;
    private size_t m_streamCount = 0;
    private size_t m_capacity = 0;
    private size_t nextPollIndex = 0;

    this(
        Side localSide,
        ulong initialMaxData,
        ulong initialMaxStreamDataBidiLocal,
        ulong initialMaxStreamDataBidiRemote,
        ulong initialMaxStreamDataUni,
        ulong localMaxStreamsBidi,
        ulong localMaxStreamsUni,
        ulong remoteMaxStreamsBidi = 0,
        ulong remoteMaxStreamsUni = 0
    ) @safe pure @nogc nothrow
    {
        this.localSide = localSide;
        this.connFlow = FlowController(initialMaxData, 0);
        this.initialMaxStreamDataBidiLocal = initialMaxStreamDataBidiLocal;
        this.initialMaxStreamDataBidiRemote = initialMaxStreamDataBidiRemote;
        this.initialMaxStreamDataUni = initialMaxStreamDataUni;

        this.localMaxStreamsBidi = localMaxStreamsBidi;
        this.localMaxStreamsUni = localMaxStreamsUni;
        this.remoteMaxStreamsBidi = remoteMaxStreamsBidi;
        this.remoteMaxStreamsUni = remoteMaxStreamsUni;
    }

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    public void cleanup() @trusted @nogc nothrow
    {
        if (streams !is null)
        {
            foreach (i; 0 .. m_streamCount)
            {
                streams[i].cleanup();
            }
            free(streams);
            streams = null;
        }
        m_streamCount = 0;
        m_capacity = 0;
    }

    void moveFrom(ref StreamMap other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        this.localSide = other.localSide;
        this.connFlow = other.connFlow;
        this.localMaxStreamsBidi = other.localMaxStreamsBidi;
        this.localMaxStreamsUni = other.localMaxStreamsUni;
        this.remoteMaxStreamsBidi = other.remoteMaxStreamsBidi;
        this.remoteMaxStreamsUni = other.remoteMaxStreamsUni;
        this.initialMaxStreamDataBidiLocal = other.initialMaxStreamDataBidiLocal;
        this.initialMaxStreamDataBidiRemote = other.initialMaxStreamDataBidiRemote;
        this.initialMaxStreamDataUni = other.initialMaxStreamDataUni;
        this.nextLocalBidiIndex = other.nextLocalBidiIndex;
        this.nextLocalUniIndex = other.nextLocalUniIndex;
        this.nextExpectedPeerBidiIndex = other.nextExpectedPeerBidiIndex;
        this.nextExpectedPeerUniIndex = other.nextExpectedPeerUniIndex;
        this.streams = other.streams;
        this.m_streamCount = other.m_streamCount;
        this.m_capacity = other.m_capacity;
        this.nextPollIndex = other.nextPollIndex;

        other.streams = null;
        other.m_streamCount = 0;
        other.m_capacity = 0;
    }

    @property size_t streamCount() const @safe pure @nogc nothrow
    {
        return m_streamCount;
    }

    QuicStream* getStream(StreamId id) @trusted @nogc nothrow
    {
        foreach (i; 0 .. m_streamCount)
        {
            if (streams[i].id == id)
                return &streams[i];
        }
        return null;
    }

    const(QuicStream)* getStream(StreamId id) const @trusted @nogc nothrow
    {
        foreach (i; 0 .. m_streamCount)
        {
            if (streams[i].id == id)
                return &streams[i];
        }
        return null;
    }

    /**
     * Applies negotiated peer transport parameters to connection and stream flow controllers.
     */
    void applyPeerTransportParams(ref const TransportParameters peerParams) @trusted @nogc nothrow
    {
        connFlow.updateRemoteMaxData(peerParams.initialMaxData);
        remoteMaxStreamsBidi = peerParams.initialMaxStreamsBidi;
        remoteMaxStreamsUni = peerParams.initialMaxStreamsUni;
        initialMaxStreamDataBidiRemote = peerParams.initialMaxStreamDataBidiRemote;
        initialMaxStreamDataBidiLocal = peerParams.initialMaxStreamDataBidiLocal;
        initialMaxStreamDataUni = peerParams.initialMaxStreamDataUni;

        foreach (i; 0 .. m_streamCount)
        {
            const sid = streams[i].id;
            if (sid.isBidirectional)
            {
                if (sid.initiator == localSide)
                {
                    // Locally initiated bidi stream: remote peer gave initialMaxStreamDataBidiRemote
                    streams[i].flowCtrl.updateRemoteMaxData(peerParams.initialMaxStreamDataBidiRemote);
                }
                else
                {
                    // Peer initiated bidi stream: remote peer gave initialMaxStreamDataBidiLocal
                    streams[i].flowCtrl.updateRemoteMaxData(peerParams.initialMaxStreamDataBidiLocal);
                }
            }
            else
            {
                // Uni stream
                if (sid.initiator == localSide)
                {
                    streams[i].flowCtrl.updateRemoteMaxData(peerParams.initialMaxStreamDataUni);
                }
            }
        }
    }

    /**
     * Polls pending control frames (RESET_STREAM or STOP_SENDING) for any stream.
     */
    bool pollControlFrame(out Frame f) @trusted @nogc nothrow
    {
        foreach (i; 0 .. m_streamCount)
        {
            if (streams[i].resetQueued)
            {
                streams[i].resetQueued = false;
                streams[i].resetSent = true;
                f.type = FrameType.resetStream;
                f.resetStream.streamId = streams[i].id.id;
                f.resetStream.applicationErrorCode = streams[i].applicationErrorCode;
                f.resetStream.finalSize = streams[i].sendBuf.writeOffset;
                return true;
            }
            if (streams[i].stopSendingQueued)
            {
                streams[i].stopSendingQueued = false;
                streams[i].stopSendingSent = true;
                f.type = FrameType.stopSending;
                f.stopSending.streamId = streams[i].id.id;
                f.stopSending.applicationErrorCode = streams[i].applicationErrorCode;
                return true;
            }
        }
        return false;
    }

    /**
     * Opens a new locally-initiated stream if allowed by remote limits.
     */
    TransportErrorCode openLocalStream(StreamDirection dir, out StreamId outId) @trusted @nogc nothrow
    {
        if (m_streamCount >= MAX_CONCURRENT_STREAMS_CEILING)
            return TransportErrorCode.internalError;

        const bool isBidi = (dir == StreamDirection.bidirectional);
        const ulong maxAllowed = isBidi ? remoteMaxStreamsBidi : remoteMaxStreamsUni;
        const ulong nextIndex = isBidi ? nextLocalBidiIndex : nextLocalUniIndex;

        if (nextIndex >= maxAllowed)
            return TransportErrorCode.streamLimitError;

        outId = StreamId.make(localSide, dir, nextIndex);
        ulong localWindow = isBidi ? initialMaxStreamDataBidiLocal : 0;
        ulong remoteWindow = isBidi ? initialMaxStreamDataBidiRemote : initialMaxStreamDataUni;

        if (!addStream(outId, localWindow, remoteWindow))
            return TransportErrorCode.internalError;

        if (isBidi)
            nextLocalBidiIndex++;
        else
            nextLocalUniIndex++;

        return TransportErrorCode.noError;
    }

    /**
     * Helper to open peer-initiated streams up to and including sid.streamIndex.
     */
    private TransportErrorCode openPeerStreamsUpTo(StreamId sid) @trusted @nogc nothrow
    {
        const Side peerSide = (localSide == Side.client) ? Side.server : Side.client;
        if (sid.initiator != peerSide)
            return TransportErrorCode.streamStateError;

        const ulong maxAllowed = sid.isBidirectional ? localMaxStreamsBidi : localMaxStreamsUni;
        const ulong idx = sid.streamIndex;
        if (idx >= maxAllowed)
            return TransportErrorCode.streamLimitError;

        const ulong nextExpected = sid.isBidirectional ? nextExpectedPeerBidiIndex : nextExpectedPeerUniIndex;
        if (idx < nextExpected)
            return TransportErrorCode.noError;

        const ulong streamsToOpen = idx - nextExpected + 1;
        if (streamsToOpen > MAX_CONCURRENT_STREAMS_CEILING || m_streamCount + streamsToOpen > MAX_CONCURRENT_STREAMS_CEILING)
            return TransportErrorCode.streamLimitError;

        for (ulong cur = nextExpected; cur <= idx; cur++)
        {
            StreamId curSid = StreamId.make(peerSide, sid.directionality, cur);
            if (getStream(curSid) is null)
            {
                ulong localWin = sid.isBidirectional ? initialMaxStreamDataBidiRemote : initialMaxStreamDataUni;
                ulong remoteWin = sid.isBidirectional ? initialMaxStreamDataBidiLocal : 0;
                if (!addStream(curSid, localWin, remoteWin))
                    return TransportErrorCode.internalError;
            }
        }

        if (sid.isBidirectional)
            nextExpectedPeerBidiIndex = idx + 1;
        else
            nextExpectedPeerUniIndex = idx + 1;

        return TransportErrorCode.noError;
    }

    /**
     * Processes an incoming STREAM frame from the peer.
     * Enforces RFC 9000 directionality, stream limits, implicit stream opening,
     * and stream/connection flow control atomically.
     */
    TransportErrorCode onStreamFrame(ref const StreamFrame frame) @trusted @nogc nothrow
    {
        if (frame.streamId > VARINT_MAX)
            return TransportErrorCode.frameEncodingError;

        const StreamId sid = StreamId(frame.streamId);
        const Side peerSide = (localSide == Side.client) ? Side.server : Side.client;

        // 1. Directionality check: peer must be permitted to send data on this stream
        if (!sid.canSend(peerSide))
            return TransportErrorCode.streamStateError;

        // Check frame offset bounds
        if (frame.offset > VARINT_MAX || frame.data.length > (VARINT_MAX - frame.offset))
            return TransportErrorCode.finalSizeError;

        const ulong endOffset = frame.offset + frame.data.length;

        QuicStream* stream = getStream(sid);
        if (stream is null)
        {
            // Must be peer-initiated
            if (sid.initiator != peerSide)
                return TransportErrorCode.streamStateError;

            // Stream limit check
            const ulong maxAllowed = sid.isBidirectional ? localMaxStreamsBidi : localMaxStreamsUni;
            const ulong idx = sid.streamIndex;
            if (idx >= maxAllowed)
                return TransportErrorCode.streamLimitError;

            const ulong nextExpected = sid.isBidirectional ? nextExpectedPeerBidiIndex : nextExpectedPeerUniIndex;
            if (idx < nextExpected)
            {
                // Stream was already closed/cleaned up, ignore data (RFC 9000 Section 3.2)
                return TransportErrorCode.noError;
            }

            // ATOMIC PRE-CHECK: check ceiling and flow control BEFORE opening implicit streams
            const ulong needed = idx - nextExpected + 1;
            if (needed > MAX_CONCURRENT_STREAMS_CEILING || m_streamCount + needed > MAX_CONCURRENT_STREAMS_CEILING)
                return TransportErrorCode.streamLimitError;

            const ulong initialRemoteWin = sid.isBidirectional ? initialMaxStreamDataBidiRemote : initialMaxStreamDataUni;
            if (endOffset > initialRemoteWin)
                return TransportErrorCode.flowControlError;

            if (endOffset > 0 && !connFlow.checkReceiveAllowed(connFlow.highestReceived + endOffset))
                return TransportErrorCode.flowControlError;

            TransportErrorCode openErr = openPeerStreamsUpTo(sid);
            if (openErr != TransportErrorCode.noError)
                return openErr;

            stream = getStream(sid);
            if (stream is null)
                return TransportErrorCode.internalError;
        }

        // 3. Flow control validation for existing stream
        if (!stream.flowCtrl.checkReceiveAllowed(endOffset))
            return TransportErrorCode.flowControlError;

        ulong connDelta = 0;
        if (endOffset > stream.flowCtrl.highestReceived)
            connDelta = endOffset - stream.flowCtrl.highestReceived;

        if (connDelta > 0 && !connFlow.checkReceiveAllowed(connFlow.highestReceived + connDelta))
            return TransportErrorCode.flowControlError;

        // 4. Ingest into stream receive buffer (enforces finalSizeError atomically)
        TransportErrorCode err = stream.recvBuf.ingest(frame.offset, frame.data, frame.fin);
        if (err != TransportErrorCode.noError)
            return err;

        // 5. Commit flow control updates on success
        stream.flowCtrl.commitReceive(endOffset);
        if (connDelta > 0)
            connFlow.commitReceive(connFlow.highestReceived + connDelta);

        // Update stream receive state
        if (stream.recvState == RecvStreamState.recv)
        {
            if (frame.fin)
                stream.recvState = RecvStreamState.sizeKnown;
        }

        return TransportErrorCode.noError;
    }

    /**
     * Processes an incoming RESET_STREAM frame from the peer.
     */
    TransportErrorCode onResetStreamFrame(ref const ResetStreamFrame frame) @trusted @nogc nothrow
    {
        if (frame.streamId > VARINT_MAX)
            return TransportErrorCode.frameEncodingError;
        if (frame.finalSize > VARINT_MAX)
            return TransportErrorCode.finalSizeError;

        const StreamId sid = StreamId(frame.streamId);
        const Side peerSide = (localSide == Side.client) ? Side.server : Side.client;

        if (!sid.canSend(peerSide))
            return TransportErrorCode.streamStateError;

        QuicStream* stream = getStream(sid);
        if (stream is null)
        {
            if (sid.initiator != peerSide)
                return TransportErrorCode.streamStateError;

            const ulong maxAllowed = sid.isBidirectional ? localMaxStreamsBidi : localMaxStreamsUni;
            const ulong idx = sid.streamIndex;
            if (idx >= maxAllowed)
                return TransportErrorCode.streamLimitError;

            const ulong nextExpected = sid.isBidirectional ? nextExpectedPeerBidiIndex : nextExpectedPeerUniIndex;
            if (idx < nextExpected)
            {
                // Stream was already closed/cleaned up
                return TransportErrorCode.noError;
            }

            // ATOMIC PRE-CHECK: check ceiling and flow control BEFORE opening implicit streams
            const ulong needed = idx - nextExpected + 1;
            if (needed > MAX_CONCURRENT_STREAMS_CEILING || m_streamCount + needed > MAX_CONCURRENT_STREAMS_CEILING)
                return TransportErrorCode.streamLimitError;

            const ulong initialRemoteWin = sid.isBidirectional ? initialMaxStreamDataBidiRemote : initialMaxStreamDataUni;
            if (frame.finalSize > initialRemoteWin)
                return TransportErrorCode.flowControlError;

            if (frame.finalSize > 0 && !connFlow.checkReceiveAllowed(connFlow.highestReceived + frame.finalSize))
                return TransportErrorCode.flowControlError;

            TransportErrorCode openErr = openPeerStreamsUpTo(sid);
            if (openErr != TransportErrorCode.noError)
                return openErr;

            stream = getStream(sid);
            if (stream is null)
                return TransportErrorCode.internalError;
        }

        // Flow control check with final size for existing stream
        if (!stream.flowCtrl.checkReceiveAllowed(frame.finalSize))
            return TransportErrorCode.flowControlError;

        ulong connDelta = 0;
        if (frame.finalSize > stream.flowCtrl.highestReceived)
            connDelta = frame.finalSize - stream.flowCtrl.highestReceived;

        if (connDelta > 0 && !connFlow.checkReceiveAllowed(connFlow.highestReceived + connDelta))
            return TransportErrorCode.flowControlError;

        TransportErrorCode err = stream.recvBuf.onReset(frame.finalSize);
        if (err != TransportErrorCode.noError)
            return err;

        stream.flowCtrl.commitReceive(frame.finalSize);
        if (connDelta > 0)
            connFlow.commitReceive(connFlow.highestReceived + connDelta);

        stream.resetReceived = true;
        stream.applicationErrorCode = frame.applicationErrorCode;
        stream.recvState = RecvStreamState.resetRecvd;

        return TransportErrorCode.noError;
    }

    /**
     * Processes an incoming STOP_SENDING frame from the peer.
     */
    TransportErrorCode onStopSendingFrame(ref const StopSendingFrame frame) @safe @nogc nothrow
    {
        if (frame.streamId > VARINT_MAX)
            return TransportErrorCode.frameEncodingError;

        const StreamId sid = StreamId(frame.streamId);
        const Side peerSide = (localSide == Side.client) ? Side.server : Side.client;

        // Peer must be capable of receiving on this stream to issue STOP_SENDING
        if (!sid.canReceive(peerSide))
            return TransportErrorCode.streamStateError;

        QuicStream* stream = getStream(sid);
        if (stream is null)
        {
            if (sid.initiator == localSide)
            {
                const ulong nextLocal = sid.isBidirectional ? nextLocalBidiIndex : nextLocalUniIndex;
                if (sid.streamIndex >= nextLocal)
                    return TransportErrorCode.streamStateError;
                return TransportErrorCode.noError;
            }
            else
            {
                if (sid.streamIndex >= localMaxStreamsBidi)
                    return TransportErrorCode.streamLimitError;

                TransportErrorCode openErr = openPeerStreamsUpTo(sid);
                if (openErr != TransportErrorCode.noError)
                    return openErr;

                stream = getStream(sid);
                if (stream is null)
                    return TransportErrorCode.internalError;
            }
        }

        stream.stopSendingReceived = true;
        stream.applicationErrorCode = frame.applicationErrorCode;
        if (stream.sendState == SendStreamState.ready || stream.sendState == SendStreamState.send)
            stream.sendState = SendStreamState.resetSent;

        return TransportErrorCode.noError;
    }

    /**
     * Processes an incoming MAX_DATA frame.
     */
    TransportErrorCode onMaxDataFrame(ref const MaxDataFrame frame) @safe pure @nogc nothrow
    {
        if (frame.maximumData > VARINT_MAX)
            return TransportErrorCode.frameEncodingError;
        connFlow.updateRemoteMaxData(frame.maximumData);
        return TransportErrorCode.noError;
    }

    /**
     * Processes an incoming MAX_STREAM_DATA frame.
     */
    TransportErrorCode onMaxStreamDataFrame(ref const MaxStreamDataFrame frame) @safe @nogc nothrow
    {
        if (frame.streamId > VARINT_MAX || frame.maximumStreamData > VARINT_MAX)
            return TransportErrorCode.frameEncodingError;

        const StreamId sid = StreamId(frame.streamId);
        const Side peerSide = (localSide == Side.client) ? Side.server : Side.client;

        // Local side must be permitted to send data on this stream
        if (!sid.canSend(localSide))
            return TransportErrorCode.streamStateError;

        QuicStream* stream = getStream(sid);
        if (stream is null)
        {
            if (sid.initiator == localSide)
            {
                const ulong nextLocal = sid.isBidirectional ? nextLocalBidiIndex : nextLocalUniIndex;
                if (sid.streamIndex >= nextLocal)
                    return TransportErrorCode.streamStateError;
                return TransportErrorCode.noError;
            }
            else
            {
                if (sid.streamIndex >= localMaxStreamsBidi)
                    return TransportErrorCode.streamLimitError;

                TransportErrorCode openErr = openPeerStreamsUpTo(sid);
                if (openErr != TransportErrorCode.noError)
                    return openErr;

                stream = getStream(sid);
                if (stream is null)
                    return TransportErrorCode.internalError;
            }
        }

        stream.flowCtrl.updateRemoteMaxData(frame.maximumStreamData);
        return TransportErrorCode.noError;
    }

    /**
     * Processes an incoming MAX_STREAMS frame.
     */
    TransportErrorCode onMaxStreamsFrame(ref const MaxStreamsFrame frame) @safe pure @nogc nothrow
    {
        if (frame.maximumStreams > (1UL << 60))
            return TransportErrorCode.frameEncodingError;

        if (frame.isBidirectional)
        {
            if (frame.maximumStreams > remoteMaxStreamsBidi)
                remoteMaxStreamsBidi = frame.maximumStreams;
        }
        else
        {
            if (frame.maximumStreams > remoteMaxStreamsUni)
                remoteMaxStreamsUni = frame.maximumStreams;
        }
        return TransportErrorCode.noError;
    }

    @property bool hasPendingWritable() const @trusted @nogc nothrow
    {
        foreach (i; 0 .. m_streamCount)
        {
            if (streams[i].id.canSend(localSide) && streams[i].sendBuf.hasPendingBytes)
                return true;
        }
        return false;
    }

    /**
     * Polls the next stream ready for transmission in round-robin order.
     */
    bool pollWritable(out StreamId readyStream, size_t maxBytes, out TransmitChunk chunk) @trusted @nogc nothrow
    {
        if (m_streamCount == 0)
            return false;

        const size_t startIdx = nextPollIndex % m_streamCount;
        foreach (step; 0 .. m_streamCount)
        {
            const size_t idx = (startIdx + step) % m_streamCount;
            QuicStream* stream = &streams[idx];

            if (!stream.id.canSend(localSide))
                continue;
            if (stream.sendState == SendStreamState.resetRecvd || stream.sendState == SendStreamState.resetSent)
                continue;

            // Retransmissions of lost ranges are exempt from flow control limits (RFC 9000 Section 4.1)
            size_t availableLimit = maxBytes;
            if (stream.sendBuf.lostRangeCount == 0)
            {
                const size_t connCredit = connFlow.sendCredit();
                const size_t streamCredit = stream.flowCtrl.sendCredit();
                const size_t credit = connCredit < streamCredit ? connCredit : streamCredit;
                if (credit == 0 && !stream.sendBuf.finQueued)
                    continue;
                if (credit < availableLimit)
                    availableLimit = credit;
            }

            const ulong prevUnsent = stream.sendBuf.unsentOffset;
            if (stream.sendBuf.pollTransmit(availableLimit, chunk))
            {
                // Charge ONLY newly sent bytes (never retransmissions)
                if (stream.sendBuf.unsentOffset > prevUnsent)
                {
                    const size_t newBytes = cast(size_t)(stream.sendBuf.unsentOffset - prevUnsent);
                    connFlow.onBytesSent(newBytes);
                    stream.flowCtrl.onBytesSent(newBytes);
                }

                if (chunk.fin)
                {
                    stream.sendState = SendStreamState.dataSent;
                }
                else if (stream.sendState == SendStreamState.ready)
                {
                    stream.sendState = SendStreamState.send;
                }

                readyStream = stream.id;
                nextPollIndex = (idx + 1) % m_streamCount;
                return true;
            }
        }

        return false;
    }

    private bool addStream(StreamId id, ulong localWin, ulong remoteWin) @trusted @nogc nothrow
    {
        if (m_streamCount >= MAX_CONCURRENT_STREAMS_CEILING)
            return false;

        if (m_streamCount >= m_capacity)
        {
            size_t newCap = m_capacity == 0 ? 16 : m_capacity * 2;
            if (newCap > MAX_CONCURRENT_STREAMS_CEILING)
                newCap = MAX_CONCURRENT_STREAMS_CEILING;

            QuicStream* p = cast(QuicStream*) calloc(newCap, QuicStream.sizeof);
            if (p is null)
                return false;

            if (streams !is null)
            {
                foreach (i; 0 .. m_streamCount)
                {
                    p[i].moveFrom(streams[i]);
                }
                free(streams);
            }
            streams = p;
            m_capacity = newCap;
        }

        QuicStream qs = QuicStream(id, localWin, remoteWin);
        streams[m_streamCount].moveFrom(qs);
        m_streamCount++;
        return true;
    }
}

/// Example:
// Spec: RFC 9000 Section 2.1, Section 3, Section 4 - StreamMap Concurrency, Implicit Opening, Directionality & Flow Control (Scenario T3, covers U1, U2, U3, E3, W1, W2, W3, F2, F3)
@nogc unittest
{
    // Server StreamMap
    StreamMap sm = StreamMap(
        Side.server,
        100, // initialMaxData
        60,  // initialMaxStreamDataBidiLocal
        60,  // initialMaxStreamDataBidiRemote
        60,  // initialMaxStreamDataUni
        2,   // localMaxStreamsBidi (allows client bidi streams index 0 and 1: ids 0 and 4)
        1    // localMaxStreamsUni (allows client uni stream index 0: id 2)
    );

    // 1. Client sends a STREAM frame on bidirectional stream 4 (index 1)
    ubyte[10] payload;
    StreamFrame sf4;
    sf4.streamId = 4;
    sf4.offset = 0;
    sf4.data = payload[];
    sf4.fin = false;

    TransportErrorCode err = sm.onStreamFrame(sf4);
    assert(err == TransportErrorCode.noError);

    // Stream 0 (index 0) and Stream 4 (index 1) are both opened!
    assert(sm.streamCount == 2);
    assert(sm.getStream(StreamId(0)) !is null);
    assert(sm.getStream(StreamId(4)) !is null);

    // 2. Client attempts to open bidirectional stream 8 (index 2 >= localMaxStreamsBidi 2)
    StreamFrame sf8;
    sf8.streamId = 8;
    sf8.offset = 0;
    sf8.data = payload[];
    assert(sm.onStreamFrame(sf8) == TransportErrorCode.streamLimitError);

    // 3. Client sends a STREAM frame on server-initiated unidirectional stream 3
    StreamFrame sf3;
    sf3.streamId = 3;
    sf3.offset = 0;
    sf3.data = payload[];
    assert(sm.onStreamFrame(sf3) == TransportErrorCode.streamStateError);

    // 4. Flow control: Client sends 65 bytes on stream 4 (> 60 limit)
    ubyte[65] bigPayload;
    StreamFrame sfOver;
    sfOver.streamId = 4;
    sfOver.offset = 0;
    sfOver.data = bigPayload[];
    assert(sm.onStreamFrame(sfOver) == TransportErrorCode.flowControlError);

    // 5. Connection flow control: 50 bytes on stream 0 + 55 bytes on stream 4 (> 100 conn limit)
    ubyte[50] p50;
    StreamFrame sf0;
    sf0.streamId = 0;
    sf0.offset = 0;
    sf0.data = p50[];
    assert(sm.onStreamFrame(sf0) == TransportErrorCode.noError);

    ubyte[55] p55;
    StreamFrame sf4_55;
    sf4_55.streamId = 4;
    sf4_55.offset = 0;
    sf4_55.data = p55[];
    assert(sm.onStreamFrame(sf4_55) == TransportErrorCode.flowControlError);

    // 6. Window update trigger: reading > 50% of window
    QuicStream* s0 = sm.getStream(StreamId(0));
    assert(s0 !is null);
    ubyte[50] outBuf;
    bool fin = false;
    assert(s0.recvBuf.read(outBuf[], fin) == 50);
    s0.flowCtrl.onBytesRead(50);
    sm.connFlow.onBytesRead(50);

    ulong nextConnMax = 0;
    assert(sm.connFlow.shouldSendMaxDataUpdate(nextConnMax));
    assert(nextConnMax == 150); // 50 + 100
}

/// Example:
// Best practice: StreamMap Move Semantics and Memory Management (covers U2, G4)
@nogc unittest
{
    StreamMap sm1 = StreamMap(Side.client, 1000, 500, 500, 500, 10, 10, 10, 10);
    StreamId sid;
    assert(sm1.openLocalStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    assert(sm1.streamCount == 1);

    StreamMap sm2;
    sm2.moveFrom(sm1);
    assert(sm1.streamCount == 0);
    assert(sm2.streamCount == 1);
    assert(sm2.getStream(sid) !is null);
}

/// Example:
// Spec: RFC 9000 Section 3.2, Section 4.5 - Idempotent RESET_STREAM and Reordered STREAM Flow Control (covers HIGH-03)
@nogc unittest
{
    // Server StreamMap
    StreamMap sm = StreamMap(Side.server, 100, 60, 60, 60, 4, 4);

    // Stream 0 receives 30 bytes
    ubyte[30] p30;
    StreamFrame sf0;
    sf0.streamId = 0;
    sf0.offset = 0;
    sf0.data = p30[];
    assert(sm.onStreamFrame(sf0) == TransportErrorCode.noError);
    assert(sm.connFlow.highestReceived == 30);

    // Stream 0 is reset with finalSize = 50. Increases connFlow by 20 bytes to 50.
    ResetStreamFrame rst;
    rst.streamId = 0;
    rst.applicationErrorCode = 42;
    rst.finalSize = 50;
    assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
    assert(sm.connFlow.highestReceived == 50);

    // Duplicate RESET_STREAM with finalSize = 50 must succeed idempotently without double-counting connFlow
    assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
    assert(sm.connFlow.highestReceived == 50);

    // Reordered STREAM frame for stream 0 (bytes 10..40) must NOT double-count connFlow
    ubyte[30] pReorder;
    StreamFrame sfReorder;
    sfReorder.streamId = 0;
    sfReorder.offset = 10;
    sfReorder.data = pReorder[];
    assert(sm.onStreamFrame(sfReorder) == TransportErrorCode.noError);
    assert(sm.connFlow.highestReceived == 50);

    // RESET_STREAM with different finalSize must return finalSizeError
    ResetStreamFrame rstConflict;
    rstConflict.streamId = 0;
    rstConflict.applicationErrorCode = 42;
    rstConflict.finalSize = 60;
    assert(sm.onResetStreamFrame(rstConflict) == TransportErrorCode.finalSizeError);
}

/// Example:
// Spec: RFC 9000 Section 3.2, Section 19.10 - Unopened Stream MAX_STREAM_DATA and Directionality (covers Defect 2, HIGH-05)
@nogc unittest
{
    // Server StreamMap
    StreamMap sm = StreamMap(Side.server, 1000, 200, 200, 200, 4, 4);

    // 1. MAX_STREAM_DATA for unopened peer-initiated bidi stream 4 (index 1 < localMaxStreamsBidi 4)
    MaxStreamDataFrame msdf;
    msdf.streamId = 4;
    msdf.maximumStreamData = 500;
    assert(sm.onMaxStreamDataFrame(msdf) == TransportErrorCode.noError);

    // Implicit streams 0 and 4 were opened
    assert(sm.streamCount == 2);
    QuicStream* s4 = sm.getStream(StreamId(4));
    assert(s4 !is null);
    assert(s4.flowCtrl.remoteMaxData == 500);

    // 2. MAX_STREAM_DATA for stream with streamId > VARINT_MAX
    MaxStreamDataFrame msdfBadId;
    msdfBadId.streamId = VARINT_MAX + 1;
    msdfBadId.maximumStreamData = 100;
    assert(sm.onMaxStreamDataFrame(msdfBadId) == TransportErrorCode.frameEncodingError);

    // 3. MAX_STREAM_DATA on server-initiated uni stream (peer cannot send)
    MaxStreamDataFrame msdfServerUni;
    msdfServerUni.streamId = 3; // server uni
    msdfServerUni.maximumStreamData = 100;
    assert(sm.onMaxStreamDataFrame(msdfServerUni) == TransportErrorCode.streamStateError);

    // 4. MAX_STREAM_DATA on uncreated local stream (server bidi index 2, not yet opened by server)
    MaxStreamDataFrame msdfUncreated;
    msdfUncreated.streamId = 9; // server bidi index 2 (server bidi: 2*4 + 1 = 9)
    msdfUncreated.maximumStreamData = 100;
    assert(sm.onMaxStreamDataFrame(msdfUncreated) == TransportErrorCode.streamStateError);
}

/// Example:
// Spec: RFC 9000 Section 4.1, Section 3.1 - Retransmission Zero Flow-Control Charge and 0-byte FIN (covers Defect 3)
@nogc unittest
{
    StreamMap sm = StreamMap(Side.client, 50, 50, 50, 50, 4, 4, 4, 4);
    sm.connFlow.updateRemoteMaxData(20); // 20 bytes connection credit

    StreamId sid;
    assert(sm.openLocalStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    QuicStream* s = sm.getStream(sid);
    assert(s !is null);

    ubyte[20] data20;
    assert(s.sendBuf.write(data20[], false));

    // Poll 20 bytes: consumes all 20 bytes of credit
    StreamId polledId;
    TransmitChunk chunk;
    assert(sm.pollWritable(polledId, 100, chunk));
    assert(chunk.data.length == 20);
    assert(sm.connFlow.sendCredit() == 0);
    assert(s.sendState == SendStreamState.send);

    // Mark range [0..10] lost
    s.sendBuf.onRangeLost(0, 10, false);
    assert(s.sendBuf.lostRangeCount == 1);

    // Poll writable: retransmission must succeed even though credit is 0!
    TransmitChunk retransmitChunk;
    assert(sm.pollWritable(polledId, 100, retransmitChunk));
    assert(retransmitChunk.offset == 0);
    assert(retransmitChunk.data.length == 10);
    // Flow credit must NOT be charged for retransmitted bytes!
    assert(sm.connFlow.sendCredit() == 0);

    // Write FIN with no additional data
    assert(s.sendBuf.write(null, true));
    TransmitChunk finChunk;
    assert(sm.pollWritable(polledId, 100, finChunk));
    assert(finChunk.fin);
    assert(finChunk.data.length == 0);
    assert(s.sendState == SendStreamState.dataSent);
}

/// Example:
// Spec: RFC 9000 Section 2.1, Section 4.5 - Atomic Frame Pre-validation (covers HIGH-05)
@nogc unittest
{
    // Server StreamMap with capacity
    StreamMap sm = StreamMap(Side.server, 100, 50, 50, 50, 4, 4);

    // Stream frame on unopened stream 4 with payload 60 > initial max stream data 50
    ubyte[60] bigPayload;
    StreamFrame sfOver;
    sfOver.streamId = 4;
    sfOver.offset = 0;
    sfOver.data = bigPayload[];

    // Frame must be rejected atomically: no streams should be opened!
    assert(sm.onStreamFrame(sfOver) == TransportErrorCode.flowControlError);
    assert(sm.streamCount == 0);
    assert(sm.getStream(StreamId(0)) is null);
    assert(sm.getStream(StreamId(4)) is null);

    // Stream frame with invalid VARINT_MAX offset on unopened stream
    StreamFrame sfBadOffset;
    sfBadOffset.streamId = 4;
    sfBadOffset.offset = VARINT_MAX;
    sfBadOffset.data = bigPayload[];
    assert(sm.onStreamFrame(sfBadOffset) == TransportErrorCode.finalSizeError);
    assert(sm.streamCount == 0);
}
