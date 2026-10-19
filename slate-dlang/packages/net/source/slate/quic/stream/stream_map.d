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
    /// High-water mark of the stream bytes already returned to connection flow control (by
    /// reads, RESET_STREAM or `abandonRecv`). Every path credits only the bytes above it, so no
    /// byte is credited twice (RFC 9000 Section 4.1).
    ulong connCreditedOffset = 0;
    /// The application gave up this receive side (`StreamMap.abandonRecv`): later bytes are
    /// counted and credited as they arrive instead of being buffered.
    bool recvAbandoned = false;

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
        this.connCreditedOffset = other.connCreditedOffset;
        this.recvAbandoned = other.recvAbandoned;
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

    ulong localInitialMaxStreamDataBidiLocal = 0;
    ulong localInitialMaxStreamDataBidiRemote = 0;
    ulong localInitialMaxStreamDataUni = 0;

    ulong peerInitialMaxStreamDataBidiLocal = 0;
    ulong peerInitialMaxStreamDataBidiRemote = 0;
    ulong peerInitialMaxStreamDataUni = 0;

    bool maxStreamsBidiPending = false;
    bool maxStreamsUniPending = false;

    ulong nextLocalBidiIndex = 0;
    ulong nextLocalUniIndex = 0;
    ulong nextExpectedPeerBidiIndex = 0;
    ulong nextExpectedPeerUniIndex = 0;

    private QuicStream* streams = null;
    private size_t m_streamCount = 0;
    private size_t m_capacity = 0;
    private size_t nextPollIndex = 0;

    this(Side localSide, ulong initialMaxData, ulong initialMaxStreamDataBidiLocal,
            ulong initialMaxStreamDataBidiRemote, ulong initialMaxStreamDataUni,
            ulong localMaxStreamsBidi, ulong localMaxStreamsUni,
            ulong remoteMaxStreamsBidi = 0, ulong remoteMaxStreamsUni = 0,
            ulong peerInitialMaxStreamDataBidiLocal = ulong.max,
            ulong peerInitialMaxStreamDataBidiRemote = ulong.max,
            ulong peerInitialMaxStreamDataUni = ulong.max) @safe pure @nogc nothrow
    {
        this.localSide = localSide;
        this.connFlow = FlowController(initialMaxData, 0);
        this.localInitialMaxStreamDataBidiLocal = initialMaxStreamDataBidiLocal;
        this.localInitialMaxStreamDataBidiRemote = initialMaxStreamDataBidiRemote;
        this.localInitialMaxStreamDataUni = initialMaxStreamDataUni;

        this.localMaxStreamsBidi = localMaxStreamsBidi;
        this.localMaxStreamsUni = localMaxStreamsUni;
        this.remoteMaxStreamsBidi = remoteMaxStreamsBidi;
        this.remoteMaxStreamsUni = remoteMaxStreamsUni;

        this.peerInitialMaxStreamDataBidiLocal = (peerInitialMaxStreamDataBidiLocal != ulong.max)
            ? peerInitialMaxStreamDataBidiLocal : initialMaxStreamDataBidiLocal;
        this.peerInitialMaxStreamDataBidiRemote = (peerInitialMaxStreamDataBidiRemote != ulong.max)
            ? peerInitialMaxStreamDataBidiRemote : initialMaxStreamDataBidiRemote;
        this.peerInitialMaxStreamDataUni = (peerInitialMaxStreamDataUni != ulong.max)
            ? peerInitialMaxStreamDataUni : initialMaxStreamDataUni;
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
        this.localInitialMaxStreamDataBidiLocal = other.localInitialMaxStreamDataBidiLocal;
        this.localInitialMaxStreamDataBidiRemote = other.localInitialMaxStreamDataBidiRemote;
        this.localInitialMaxStreamDataUni = other.localInitialMaxStreamDataUni;
        this.peerInitialMaxStreamDataBidiLocal = other.peerInitialMaxStreamDataBidiLocal;
        this.peerInitialMaxStreamDataBidiRemote = other.peerInitialMaxStreamDataBidiRemote;
        this.peerInitialMaxStreamDataUni = other.peerInitialMaxStreamDataUni;
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
     * Whether `sid` names a stream that was opened earlier and has since been reaped. Frames
     * for such streams are stale retransmissions and are ignored (RFC 9000 Section 3.2,
     * Section 13.3; plan D6). Only meaningful when `getStream(sid)` is null.
     */
    bool isReapedStream(StreamId sid) const @safe pure @nogc nothrow
    {
        ulong next;
        if (sid.initiator == localSide)
            next = sid.isBidirectional ? nextLocalBidiIndex : nextLocalUniIndex;
        else
            next = sid.isBidirectional ? nextExpectedPeerBidiIndex : nextExpectedPeerUniIndex;
        return sid.streamIndex < next;
    }

    /**
     * Applies negotiated peer transport parameters to connection and stream flow controllers.
     */
    void applyPeerTransportParams(ref const TransportParameters peerParams) @trusted @nogc nothrow
    {
        connFlow.updateRemoteMaxData(peerParams.initialMaxData);
        remoteMaxStreamsBidi = peerParams.initialMaxStreamsBidi;
        remoteMaxStreamsUni = peerParams.initialMaxStreamsUni;
        peerInitialMaxStreamDataBidiRemote = peerParams.initialMaxStreamDataBidiRemote;
        peerInitialMaxStreamDataBidiLocal = peerParams.initialMaxStreamDataBidiLocal;
        peerInitialMaxStreamDataUni = peerParams.initialMaxStreamDataUni;

        foreach (i; 0 .. m_streamCount)
        {
            const sid = streams[i].id;
            if (sid.isBidirectional)
            {
                if (sid.initiator == localSide)
                {
                    // Locally initiated bidi stream: remote peer gave initialMaxStreamDataBidiRemote
                    streams[i].flowCtrl.updateRemoteMaxData(
                            peerParams.initialMaxStreamDataBidiRemote);
                }
                else
                {
                    // Peer initiated bidi stream: remote peer gave initialMaxStreamDataBidiLocal
                    streams[i].flowCtrl.updateRemoteMaxData(
                            peerParams.initialMaxStreamDataBidiLocal);
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
     * Accounts for `count` bytes the application consumed from `s` (stream and connection
     * credit). Bytes of a stream the peer already reset or the application abandoned were
     * credited to the connection then, so only the stream-level counter advances for them.
     */
    void onApplicationRead(ref QuicStream s, size_t count) @safe pure @nogc nothrow
    {
        if (count == 0)
            return;
        s.flowCtrl.onBytesRead(count);
        creditConnection(s, s.flowCtrl.readOffset);
    }

    /**
     * Returns the stream bytes below `target` that were not credited yet to connection flow
     * control. `target` never exceeds what the stream received, so the connection's read offset
     * cannot overtake the bytes it has received (a peer could otherwise inflate MAX_DATA).
     */
    private void creditConnection(ref QuicStream s, ulong target) @safe pure @nogc nothrow
    {
        if (target > s.flowCtrl.highestReceived)
            target = s.flowCtrl.highestReceived;
        if (target <= s.connCreditedOffset)
            return;
        connFlow.onBytesRead(cast(size_t)(target - s.connCreditedOffset));
        s.connCreditedOffset = target;
        assert(connFlow.readOffset <= connFlow.highestReceived,
                "connection credit exceeds received bytes");
    }

    /**
     * Gives up the receive side of `sid` (the application discards the stream, e.g. after a local
     * reset): buffered bytes are freed and every byte received so far, and every byte that still
     * arrives, is returned to stream and connection flow control exactly once (RFC 9000
     * Section 4.1), so the connection window cannot leak and the stream can be reaped once its
     * final size is known. Returns false when the stream is unknown or has no receive side.
     */
    bool abandonRecv(StreamId sid) @trusted @nogc nothrow
    {
        QuicStream* s = getStream(sid);
        if (s is null || !sid.canReceive(localSide))
            return false;
        if (!s.recvAbandoned)
        {
            s.recvAbandoned = true;
            s.recvBuf.abandon();
            creditAbandoned(*s);
        }
        reapClosedStreams();
        return true;
    }

    /// Returns the received-but-unread bytes of an abandoned stream to flow control, once.
    private void creditAbandoned(ref QuicStream s) @safe pure @nogc nothrow
    {
        const ulong pending = s.flowCtrl.highestReceived > s.flowCtrl.readOffset
            ? s.flowCtrl.highestReceived - s.flowCtrl.readOffset : 0;
        if (pending > 0)
            s.flowCtrl.onBytesRead(cast(size_t) pending);
        creditConnection(s, s.flowCtrl.highestReceived);
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
                // F-17: use highest sent offset (unsentOffset) as finalSize
                f.resetStream.finalSize = streams[i].sendBuf.unsentOffset;
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
     * Polls pending flow control updates (MAX_DATA, MAX_STREAM_DATA, MAX_STREAMS) (F-05).
     */
    bool pollFlowControlFrame(out Frame f) @trusted @nogc nothrow
    {
        ulong nextMaxData = 0;
        if (connFlow.shouldSendMaxDataUpdate(nextMaxData))
        {
            f.type = FrameType.maxData;
            f.maxData.maximumData = nextMaxData;
            return true;
        }

        foreach (i; 0 .. m_streamCount)
        {
            ulong nextStreamMax = 0;
            if (streams[i].flowCtrl.shouldSendMaxDataUpdate(nextStreamMax))
            {
                f.type = FrameType.maxStreamData;
                f.maxStreamData.streamId = streams[i].id.id;
                f.maxStreamData.maximumStreamData = nextStreamMax;
                return true;
            }
        }

        if (maxStreamsBidiPending)
        {
            maxStreamsBidiPending = false;
            f.type = FrameType.maxStreamsBidi;
            f.maxStreams.maximumStreams = localMaxStreamsBidi;
            f.maxStreams.isBidirectional = true;
            return true;
        }

        if (maxStreamsUniPending)
        {
            maxStreamsUniPending = false;
            f.type = FrameType.maxStreamsUni;
            f.maxStreams.maximumStreams = localMaxStreamsUni;
            f.maxStreams.isBidirectional = false;
            return true;
        }

        return false;
    }

    private const(QuicStream)[] activeStreams() const @trusted pure @nogc nothrow
    {
        return streams ? streams[0 .. m_streamCount] : null;
    }

    @property bool hasPendingFlowControl() const @safe pure @nogc nothrow
    {
        if (connFlow.hasPendingMaxDataUpdate())
            return true;
        foreach (ref const(QuicStream) s; activeStreams())
        {
            if (s.flowCtrl.hasPendingMaxDataUpdate())
                return true;
        }
        return maxStreamsBidiPending || maxStreamsUniPending;
    }

    /**
     * Opens a new locally-initiated stream if allowed by remote limits.
     */
    TransportErrorCode openLocalStream(StreamDirection dir, out StreamId outId) @trusted @nogc nothrow
    {
        if (m_streamCount >= MAX_CONCURRENT_STREAMS_CEILING)
        {
            reapClosedStreams();
            if (m_streamCount >= MAX_CONCURRENT_STREAMS_CEILING)
                return TransportErrorCode.internalError;
        }

        const bool isBidi = (dir == StreamDirection.bidirectional);
        const ulong maxAllowed = isBidi ? remoteMaxStreamsBidi : remoteMaxStreamsUni;
        const ulong nextIndex = isBidi ? nextLocalBidiIndex : nextLocalUniIndex;

        if (nextIndex >= maxAllowed)
            return TransportErrorCode.streamLimitError;

        outId = StreamId.make(localSide, dir, nextIndex);
        ulong localWindow = isBidi ? localInitialMaxStreamDataBidiLocal : 0;
        ulong remoteWindow = isBidi ? peerInitialMaxStreamDataBidiRemote
            : peerInitialMaxStreamDataUni;

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

        const ulong nextExpected = sid.isBidirectional
            ? nextExpectedPeerBidiIndex : nextExpectedPeerUniIndex;
        if (idx < nextExpected)
            return TransportErrorCode.noError;

        const ulong streamsToOpen = idx - nextExpected + 1;
        if (streamsToOpen > MAX_CONCURRENT_STREAMS_CEILING
                || m_streamCount + streamsToOpen > MAX_CONCURRENT_STREAMS_CEILING)
        {
            reapClosedStreams();
            if (streamsToOpen > MAX_CONCURRENT_STREAMS_CEILING
                    || m_streamCount + streamsToOpen > MAX_CONCURRENT_STREAMS_CEILING)
                return TransportErrorCode.streamLimitError;
        }

        for (ulong cur = nextExpected; cur <= idx; cur++)
        {
            StreamId curSid = StreamId.make(peerSide, sid.directionality, cur);
            if (getStream(curSid) is null)
            {
                ulong localWin = sid.isBidirectional
                    ? localInitialMaxStreamDataBidiRemote : localInitialMaxStreamDataUni;
                ulong remoteWin = sid.isBidirectional ? peerInitialMaxStreamDataBidiLocal : 0;
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
            // Locally initiated: a reaped stream gets a stale retransmission (ignored); a
            // stream that was never opened is a STREAM_STATE_ERROR (RFC 9000 Section 19.8).
            if (sid.initiator != peerSide)
                return isReapedStream(sid) ? TransportErrorCode.noError
                    : TransportErrorCode.streamStateError;

            // Stream limit check
            const ulong maxAllowed = sid.isBidirectional ? localMaxStreamsBidi : localMaxStreamsUni;
            const ulong idx = sid.streamIndex;
            if (idx >= maxAllowed)
                return TransportErrorCode.streamLimitError;

            const ulong nextExpected = sid.isBidirectional
                ? nextExpectedPeerBidiIndex : nextExpectedPeerUniIndex;
            if (idx < nextExpected)
            {
                // Stream was already closed/cleaned up, ignore data (RFC 9000 Section 3.2)
                return TransportErrorCode.noError;
            }

            // ATOMIC PRE-CHECK: check ceiling and flow control BEFORE opening implicit streams
            const ulong needed = idx - nextExpected + 1;
            if (needed > MAX_CONCURRENT_STREAMS_CEILING
                    || m_streamCount + needed > MAX_CONCURRENT_STREAMS_CEILING)
            {
                reapClosedStreams();
                if (needed > MAX_CONCURRENT_STREAMS_CEILING
                        || m_streamCount + needed > MAX_CONCURRENT_STREAMS_CEILING)
                    return TransportErrorCode.streamLimitError;
            }

            const ulong initialRemoteWin = sid.isBidirectional
                ? localInitialMaxStreamDataBidiRemote : localInitialMaxStreamDataUni;
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

        if (stream.recvAbandoned)
            creditAbandoned(*stream);

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
        bool ignored;
        return onResetStreamFrame(frame, ignored);
    }

    /// ditto; `ignored` is set when the frame referenced an already reaped stream.
    TransportErrorCode onResetStreamFrame(ref const ResetStreamFrame frame, out bool ignored) @trusted @nogc nothrow
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
            {
                if (!isReapedStream(sid))
                    return TransportErrorCode.streamStateError;
                ignored = true;
                return TransportErrorCode.noError;
            }

            const ulong maxAllowed = sid.isBidirectional ? localMaxStreamsBidi : localMaxStreamsUni;
            const ulong idx = sid.streamIndex;
            if (idx >= maxAllowed)
                return TransportErrorCode.streamLimitError;

            const ulong nextExpected = sid.isBidirectional
                ? nextExpectedPeerBidiIndex : nextExpectedPeerUniIndex;
            if (idx < nextExpected)
            {
                // Stream was already closed/cleaned up
                ignored = true;
                return TransportErrorCode.noError;
            }

            // ATOMIC PRE-CHECK: check ceiling and flow control BEFORE opening implicit streams
            const ulong needed = idx - nextExpected + 1;
            if (needed > MAX_CONCURRENT_STREAMS_CEILING
                    || m_streamCount + needed > MAX_CONCURRENT_STREAMS_CEILING)
            {
                reapClosedStreams();
                if (needed > MAX_CONCURRENT_STREAMS_CEILING
                        || m_streamCount + needed > MAX_CONCURRENT_STREAMS_CEILING)
                    return TransportErrorCode.streamLimitError;
            }

            const ulong initialRemoteWin = sid.isBidirectional
                ? localInitialMaxStreamDataBidiRemote : localInitialMaxStreamDataUni;
            if (frame.finalSize > initialRemoteWin)
                return TransportErrorCode.flowControlError;

            if (frame.finalSize > 0
                    && !connFlow.checkReceiveAllowed(connFlow.highestReceived + frame.finalSize))
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

        // RFC 9000 Section 4.1: data the application will never read still consumed connection
        // credit; return `final size - bytes read` once, or the connection window leaks (R-13).
        creditConnection(*stream, frame.finalSize);

        if (stream.recvAbandoned)
            creditAbandoned(*stream);

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
        bool ignored;
        return onStopSendingFrame(frame, ignored);
    }

    /// ditto; `ignored` is set when the frame referenced an already reaped stream.
    TransportErrorCode onStopSendingFrame(ref const StopSendingFrame frame, out bool ignored) @safe @nogc nothrow
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
                ignored = true;
                return TransportErrorCode.noError;
            }
            else
            {
                if (isReapedStream(sid))
                {
                    ignored = true;
                    return TransportErrorCode.noError;
                }
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
        {
            stream.sendState = SendStreamState.resetSent;
            stream.resetQueued = true;
        }

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
                if (isReapedStream(sid))
                    return TransportErrorCode.noError;
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
            if (streams[i].resetQueued || streams[i].stopSendingQueued)
                return true;
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
            if (stream.sendState == SendStreamState.resetRecvd
                    || stream.sendState == SendStreamState.resetSent)
                continue;

            // Retransmissions of lost ranges are exempt from flow control limits (RFC 9000 Section 4.1)
            size_t availableLimit = maxBytes;
            if (stream.sendBuf.lostRangeCount == 0)
            {
                const size_t connCredit = connFlow.sendCredit();
                const size_t streamCredit = stream.flowCtrl.sendCredit();
                const size_t credit = connCredit < streamCredit ? connCredit : streamCredit;
                // With no credit only a bare FIN (no unsent bytes) may still be sent; otherwise
                // a blocked stream would emit empty STREAM frames forever (RFC 9000 Section 4.1).
                if (credit == 0 && (!stream.sendBuf.finQueued
                        || stream.sendBuf.unsentOffset < stream.sendBuf.writeOffset))
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

    /**
     * Determines whether a stream has completed both transmission and reception lifecycle.
     */
    bool isStreamClosed(ref const QuicStream s) const @safe pure @nogc nothrow
    {
        if (s.resetQueued || s.stopSendingQueued)
            return false;

        // RFC 9000 Section 3.1: RESET_STREAM is retransmitted until acknowledged, so a stream in
        // `resetSent` must stay in the table (R-14); only `resetRecvd` (acked) ends it.
        const bool sendDone = (s.sendState == SendStreamState.resetRecvd || s.sendState == SendStreamState.dataRecvd
                || (s.sendState != SendStreamState.resetSent && s.sendBuf.isAllAcked()));

        const bool recvDone = (s.recvState == RecvStreamState.resetRecvd || s.recvState == RecvStreamState.resetRead
                || s.recvState == RecvStreamState.dataRead || (s.recvBuf.hasFinalSize
                    && s.recvBuf.readOffset == s.recvBuf.finalSize));

        if (s.id.isBidirectional)
            return sendDone && recvDone;

        if (s.id.initiator == localSide)
            return sendDone;
        else
            return recvDone;
    }

    /**
     * Reaps completed closed streams from the table to free capacity.
     */
    size_t reapClosedStreams() @trusted @nogc nothrow
    {
        if (m_streamCount == 0)
            return 0;

        size_t reaped = 0;
        size_t writeIdx = 0;
        foreach (readIdx; 0 .. m_streamCount)
        {
            if (isStreamClosed(streams[readIdx]))
            {
                if (streams[readIdx].id.initiator != localSide)
                {
                    if (streams[readIdx].id.isBidirectional)
                    {
                        if (localMaxStreamsBidi < VARINT_MAX)
                            localMaxStreamsBidi++;
                        maxStreamsBidiPending = true;
                    }
                    else
                    {
                        if (localMaxStreamsUni < VARINT_MAX)
                            localMaxStreamsUni++;
                        maxStreamsUniPending = true;
                    }
                }
                streams[readIdx].cleanup();
                reaped++;
            }
            else
            {
                if (writeIdx != readIdx)
                {
                    streams[writeIdx].moveFrom(streams[readIdx]);
                }
                writeIdx++;
            }
        }
        m_streamCount = writeIdx;
        if (nextPollIndex >= m_streamCount)
            nextPollIndex = 0;
        return reaped;
    }

    private bool addStream(StreamId id, ulong localWin, ulong remoteWin) @trusted @nogc nothrow
    {
        if (m_streamCount >= MAX_CONCURRENT_STREAMS_CEILING)
        {
            reapClosedStreams();
            if (m_streamCount >= MAX_CONCURRENT_STREAMS_CEILING)
                return false;
        }

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
/// ---
/// StreamMap sm = StreamMap(Side.server, 100, 60, 60, 60, 2, 1);   // two peer bidi streams, one uni
///
/// // A STREAM frame on peer bidi stream 4 (index 1) implicitly opens stream 0 as well.
/// ubyte[10] payload;
/// StreamFrame sf4;
/// sf4.streamId = 4;
/// sf4.data = payload[];
/// assert(sm.onStreamFrame(sf4) == TransportErrorCode.noError);
/// assert(sm.streamCount == 2);
///
/// // Stream 8 (index 2) is past the advertised limit.
/// StreamFrame sf8;
/// sf8.streamId = 8;
/// sf8.data = payload[];
/// assert(sm.onStreamFrame(sf8) == TransportErrorCode.streamLimitError);
/// ---
// Spec: RFC 9000 Section 2.1, Section 3, Section 4 - StreamMap Concurrency, Implicit Opening, Directionality & Flow Control (Scenario T3, covers U1, U2, U3, E3, W1, W2, W3, F2, F3)
@nogc unittest
{
    // Server StreamMap
    StreamMap sm = StreamMap(Side.server, 100, // initialMaxData
            60, // initialMaxStreamDataBidiLocal
            60, // initialMaxStreamDataBidiRemote
            60, // initialMaxStreamDataUni
            2, // localMaxStreamsBidi (allows client bidi streams index 0 and 1: ids 0 and 4)
            1 // localMaxStreamsUni (allows client uni stream index 0: id 2)
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
/// ---
/// StreamMap sm1 = StreamMap(Side.client, 1000, 500, 500, 500, 10, 10, 10, 10);
/// StreamId sid;
/// assert(sm1.openLocalStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
///
/// StreamMap sm2;
/// sm2.moveFrom(sm1);
/// assert(sm1.streamCount == 0);                 // the source no longer owns the streams
/// assert(sm2.streamCount == 1 && sm2.getStream(sid) !is null);
/// ---
// Spec: StreamMap Move Semantics and Memory Management (covers U2, G4)
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
/// ---
/// StreamMap sm = StreamMap(Side.server, 100, 60, 60, 60, 4, 4);
/// ubyte[30] bytes;
/// StreamFrame sf;
/// sf.streamId = 0;
/// sf.data = bytes[];
/// assert(sm.onStreamFrame(sf) == TransportErrorCode.noError);   // 30 bytes counted
///
/// ResetStreamFrame rst;
/// rst.streamId = 0;
/// rst.applicationErrorCode = 42;
/// rst.finalSize = 50;
/// assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
/// assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);   // idempotent, counted once
/// assert(sm.connFlow.highestReceived == 50);
///
/// rst.finalSize = 51;   // a different final size is a connection error
/// assert(sm.onResetStreamFrame(rst) == TransportErrorCode.finalSizeError);
/// ---
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
/// ---
/// StreamMap sm = StreamMap(Side.server, 1000, 200, 200, 200, 4, 4);
/// MaxStreamDataFrame msd;
/// msd.streamId = 4;                      // peer bidi stream that is not open yet: opened implicitly
/// msd.maximumStreamData = 500;
/// assert(sm.onMaxStreamDataFrame(msd) == TransportErrorCode.noError);
/// assert(sm.streamCount == 2 && sm.getStream(StreamId(4)).flowCtrl.remoteMaxData == 500);
///
/// msd.streamId = VARINT_MAX + 1;         // not a valid stream ID
/// assert(sm.onMaxStreamDataFrame(msd) == TransportErrorCode.frameEncodingError);
/// msd.streamId = 3;                      // server uni stream: the peer cannot send on it
/// assert(sm.onMaxStreamDataFrame(msd) == TransportErrorCode.streamStateError);
/// msd.streamId = 9;                      // server bidi stream the server never opened
/// assert(sm.onMaxStreamDataFrame(msd) == TransportErrorCode.streamStateError);   // an unopened peer-initiated stream is refused
/// ---
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
/// ---
/// StreamMap sm = StreamMap(Side.client, 50, 50, 50, 50, 4, 4, 4, 4);
/// sm.connFlow.updateRemoteMaxData(20);     // 20 bytes of connection credit
/// StreamId sid, polledId;
/// assert(sm.openLocalStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// QuicStream* s = sm.getStream(sid);
/// ubyte[20] data;
/// assert(s.sendBuf.write(data[], false));
/// TransmitChunk chunk;
/// assert(sm.pollWritable(polledId, 100, chunk) && chunk.data.length == 20);   // all credit used
///
/// // A retransmission costs no credit; a bare FIN needs none either.
/// s.sendBuf.onRangeLost(0, 10, false);
/// assert(sm.pollWritable(polledId, 100, chunk) && chunk.offset == 0 && chunk.data.length == 10);
/// assert(s.sendBuf.write(null, true));
/// assert(sm.pollWritable(polledId, 100, chunk) && chunk.fin && chunk.data.length == 0);
/// assert(s.sendState == SendStreamState.dataSent);
/// ---
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
/// ---
/// StreamMap sm = StreamMap(Side.server, 100, 50, 50, 50, 4, 4);
/// ubyte[60] big;
/// StreamFrame sf;
/// sf.streamId = 4;
/// sf.data = big[];                         // 60 bytes against a 50-byte stream limit
/// assert(sm.onStreamFrame(sf) == TransportErrorCode.flowControlError);
/// assert(sm.streamCount == 0);             // rejected atomically: no stream was opened
///
/// sf.offset = VARINT_MAX;                  // offset + length overflows the 2^62 - 1 limit
/// assert(sm.onStreamFrame(sf) == TransportErrorCode.finalSizeError);
/// assert(sm.streamCount == 0);
/// ---
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

/// Example:
/// ---
/// StreamMap sm = StreamMap(Side.client, 50, 50, 50, 50, 4, 4, 4, 4);
/// StreamId sid;
/// assert(sm.openLocalStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// QuicStream* s = sm.getStream(sid);
/// assert(!sm.hasPendingWritable);
///
/// s.resetQueued = true;                    // RESET_STREAM waiting to be sent
/// assert(sm.hasPendingWritable);
/// s.resetQueued = false;
/// s.stopSendingQueued = true;              // STOP_SENDING waiting to be sent
/// assert(sm.hasPendingWritable);   // ... and a queued STOP_SENDING too
/// ---
// Spec: RFC 9000 Section 3.2, Section 3.3 - Immediate Control Frame Transmission via hasPendingWritable (covers Scenario T3, U1, U3)
@nogc unittest
{
    StreamMap sm = StreamMap(Side.client, 50, 50, 50, 50, 4, 4, 4, 4);
    StreamId sid;
    assert(sm.openLocalStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    QuicStream* s = sm.getStream(sid);
    assert(s !is null);
    assert(!sm.hasPendingWritable);

    // Queue RESET_STREAM
    s.resetQueued = true;
    assert(sm.hasPendingWritable);

    s.resetQueued = false;
    assert(!sm.hasPendingWritable);

    // Queue STOP_SENDING
    s.stopSendingQueued = true;
    assert(sm.hasPendingWritable);
}

/// Example:
/// ---
/// StreamMap sm = StreamMap(Side.client, 100_000, 10_000, 10_000, 10_000, 2000, 2000, 2000, 2000);
/// sm.connFlow.updateRemoteMaxData(100_000);
/// StreamId sid, polledSid;
/// assert(sm.openLocalStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// QuicStream* s = sm.getStream(sid);
/// ubyte[100] data;
/// assert(s.sendBuf.write(data[], false));
/// TransmitChunk chunk;
/// assert(sm.pollWritable(polledSid, 50, chunk) && chunk.data.length == 50);
///
/// // The peer asks to stop: a RESET_STREAM with the highest sent offset as final size is queued.
/// StopSendingFrame ssf;
/// ssf.streamId = sid.id;
/// ssf.applicationErrorCode = 0xbeef;
/// assert(sm.onStopSendingFrame(ssf) == TransportErrorCode.noError);
/// Frame ctrl;
/// assert(sm.pollControlFrame(ctrl) && ctrl.type == FrameType.resetStream);
/// assert(ctrl.resetStream.applicationErrorCode == 0xbeef && ctrl.resetStream.finalSize == 50);
/// ---
// Spec: RFC 9000 Section 3.5, Section 4.5 - STOP_SENDING Response and Lifetime Sequential Stream Reaping (covers F-08, F-09, F-17)
@nogc unittest
{
    // 1. Verify STOP_SENDING queues RESET_STREAM with final size = highest sent offset
    StreamMap sm = StreamMap(Side.client, 100_000, 10_000, 10_000, 10_000, 2000, 2000, 2000, 2000);
    sm.connFlow.updateRemoteMaxData(100_000);
    StreamId sid;
    assert(sm.openLocalStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    QuicStream* s = sm.getStream(sid);
    assert(s !is null);

    ubyte[100] writeData;
    assert(s.sendBuf.write(writeData[], false));
    StreamId polledSid;
    TransmitChunk chunk;
    assert(sm.pollWritable(polledSid, 50, chunk));
    assert(chunk.data.length == 50);
    assert(s.sendState == SendStreamState.send);

    StopSendingFrame ssf;
    ssf.streamId = sid.id;
    ssf.applicationErrorCode = 0xbeef;
    assert(sm.onStopSendingFrame(ssf) == TransportErrorCode.noError);
    assert(s.resetQueued);
    assert(s.sendState == SendStreamState.resetSent);

    Frame ctrlFrame;
    assert(sm.pollControlFrame(ctrlFrame));
    assert(ctrlFrame.type == FrameType.resetStream);
    assert(ctrlFrame.resetStream.streamId == sid.id);
    assert(ctrlFrame.resetStream.applicationErrorCode == 0xbeef);
    assert(ctrlFrame.resetStream.finalSize == 50); // highest sent offset

    // 2. Verify >1024 lifetime sequential streams reap closed streams
    StreamMap smSeq = StreamMap(Side.client, 10_000_000, 1000, 1000, 1000, 2000, 2000, 2000, 2000);
    foreach (i; 0 .. 1100)
    {
        StreamId curSid;
        assert(smSeq.openLocalStream(StreamDirection.bidirectional,
                curSid) == TransportErrorCode.noError);
        QuicStream* curStream = smSeq.getStream(curSid);
        assert(curStream !is null);
        // Mark stream complete
        curStream.sendState = SendStreamState.dataRecvd;
        curStream.recvState = RecvStreamState.dataRead;
    }
    // Stream table should have successfully accommodated 1100 streams through closed stream reaping!
    assert(smSeq.streamCount <= MAX_CONCURRENT_STREAMS_CEILING);
}

/// Example:
/// ---
/// StreamMap sm = StreamMap(Side.client, 100_000, 10_000, 10_000, 10_000, 4, 4, 4, 4);
/// StreamId sid;
/// assert(sm.openLocalStream(StreamDirection.unidirectional, sid) == TransportErrorCode.noError);
/// StreamFrame sf;
/// sf.streamId = sid.id;                    // the peer must not send on our send-only stream
/// assert(sm.onStreamFrame(sf) == TransportErrorCode.streamStateError);
///
/// // Everything sent and acknowledged: the stream is reaped, and the answer stays the same.
/// sm.getStream(sid).sendState = SendStreamState.dataRecvd;
/// assert(sm.reapClosedStreams() == 1 && sm.isReapedStream(sid));
/// assert(sm.onStreamFrame(sf) == TransportErrorCode.streamStateError);   // reaped: the same answer
///
/// StopSendingFrame ssf;                    // STOP_SENDING is legal for a send-only stream
/// ssf.streamId = sid.id;
/// assert(sm.onStopSendingFrame(ssf) == TransportErrorCode.noError);   // a stale one is ignored
/// ---
// Spec: RFC 9000 Section 19.8 / Section 19.4 - a peer that sends STREAM or RESET_STREAM on a
// stream the endpoint opened as send-only commits STREAM_STATE_ERROR; the direction check
// precedes the reaped-stream shortcut (Round 2 item 7, verified: the check is already first)
@nogc unittest
{
    StreamMap sm = StreamMap(Side.client, 100_000, 10_000, 10_000, 10_000, 4, 4, 4, 4);
    StreamId sid;
    assert(sm.openLocalStream(StreamDirection.unidirectional, sid) == TransportErrorCode.noError);

    StreamFrame sf;
    sf.streamId = sid.id;
    ubyte[4] payload = [1, 2, 3, 4];
    sf.data = payload[];
    ResetStreamFrame rf;
    rf.streamId = sid.id;
    rf.finalSize = 0;
    StopSendingFrame ssf;
    ssf.streamId = sid.id;

    // Live stream: invalid direction.
    assert(sm.onStreamFrame(sf) == TransportErrorCode.streamStateError);
    assert(sm.onResetStreamFrame(rf) == TransportErrorCode.streamStateError);

    // Reap it (everything sent and acknowledged), then ask again.
    QuicStream* s = sm.getStream(sid);
    assert(s !is null);
    s.sendState = SendStreamState.dataRecvd;
    assert(sm.reapClosedStreams() == 1);
    assert(sm.getStream(sid) is null && sm.isReapedStream(sid));
    assert(sm.onStreamFrame(sf) == TransportErrorCode.streamStateError);
    assert(sm.onResetStreamFrame(rf) == TransportErrorCode.streamStateError);

    // STOP_SENDING is a legal frame for a send-only stream: a stale one is ignored.
    assert(sm.onStopSendingFrame(ssf) == TransportErrorCode.noError);
}

/// Example:
/// ---
/// StreamMap sm = StreamMap(Side.server, 1000, 1000, 1000, 1000, 4, 4);
/// ubyte[400] bytes;
/// StreamFrame sf;
/// sf.streamId = 0;
/// sf.data = bytes[];
/// assert(sm.onStreamFrame(sf) == TransportErrorCode.noError);
///
/// // The application reads 100 of the 400 bytes.
/// QuicStream* s = sm.getStream(StreamId(0));
/// ubyte[100] sink;
/// bool fin;
/// sm.onApplicationRead(*s, s.recvBuf.read(sink[], fin));
///
/// // The peer resets the stream with final size 600: the unread 500 bytes are credited back.
/// ResetStreamFrame rst;
/// rst.streamId = 0;
/// rst.finalSize = 600;
/// assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
/// assert(sm.connFlow.readOffset == 600);          // MAX_DATA can follow
/// assert(sm.connFlow.hasPendingMaxDataUpdate());
/// assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);   // duplicate
/// assert(sm.connFlow.readOffset == 600);          // a duplicate credits nothing
/// ---
// Spec: RFC 9000 Section 4.1 / Section 4.5 - bytes that counted against connection flow control
// are returned when the stream is reset (final size - bytes already read), exactly once (R-13, E5)
@nogc unittest
{
    StreamMap sm = StreamMap(Side.server, 1000, 1000, 1000, 1000, 4, 4);
    ubyte[400] chunk;
    StreamFrame sf;
    sf.streamId = 0;
    sf.offset = 0;
    sf.data = chunk[];
    assert(sm.onStreamFrame(sf) == TransportErrorCode.noError);

    // The application reads 100 bytes (credited through the normal path).
    QuicStream* s = sm.getStream(StreamId(0));
    assert(s !is null);
    ubyte[100] sink;
    bool fin;
    const n = s.recvBuf.read(sink[], fin);
    assert(n == 100);
    sm.onApplicationRead(*s, n);
    assert(sm.connFlow.readOffset == 100);
    assert(!sm.connFlow.hasPendingMaxDataUpdate());

    // Peer resets with final size 600: 500 bytes (600 - 100 read) are returned.
    ResetStreamFrame rst;
    rst.streamId = 0;
    rst.finalSize = 600;
    assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
    assert(sm.connFlow.readOffset == 600);
    assert(sm.connFlow.hasPendingMaxDataUpdate());

    // A duplicate RESET_STREAM and a later read of buffered bytes must not credit again.
    assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
    assert(sm.connFlow.readOffset == 600);
    const m = s.recvBuf.read(sink[], fin);
    sm.onApplicationRead(*s, m);
    assert(sm.connFlow.readOffset == 600);
}

/// Example:
/// ---
/// StreamMap sm = StreamMap(Side.client, 1000, 1000, 1000, 1000, 4, 4, 4, 4);
/// StreamId sid;
/// assert(sm.openLocalStream(StreamDirection.unidirectional, sid) == TransportErrorCode.noError);
/// QuicStream* s = sm.getStream(sid);
///
/// s.sendState = SendStreamState.resetSent;        // RESET_STREAM sent, not yet acknowledged
/// assert(sm.reapClosedStreams() == 0);            // must stay: it may need retransmission
/// s.sendState = SendStreamState.resetRecvd;       // acknowledged
/// assert(sm.reapClosedStreams() == 1 && sm.getStream(sid) is null);
/// ---
// Spec: RFC 9000 Section 3.1 (Sending Stream States: "Reset Sent" ends in "Reset Recvd" only once
// the peer acknowledged RESET_STREAM) - the stream is not reaped while the frame is
// unacknowledged, so a lost RESET_STREAM can still be retransmitted (R-14, S2)
@nogc unittest
{
    StreamMap sm = StreamMap(Side.client, 1000, 1000, 1000, 1000, 4, 4, 4, 4);
    StreamId sid;
    assert(sm.openLocalStream(StreamDirection.unidirectional, sid) == TransportErrorCode.noError);
    QuicStream* s = sm.getStream(sid);
    assert(s !is null);
    s.sendState = SendStreamState.resetSent;
    s.resetQueued = false;
    assert(sm.reapClosedStreams() == 0);
    assert(sm.getStream(sid) !is null);

    s.sendState = SendStreamState.resetRecvd;
    assert(sm.reapClosedStreams() == 1);
    assert(sm.getStream(sid) is null);
}

/// Example:
/// ---
/// StreamMap sm = StreamMap(Side.server, 600, 500, 500, 500, 4, 4, 4, 4);
/// ubyte[300] bytes;
/// StreamFrame f;
/// f.streamId = 0;
/// f.data = bytes[0 .. 100];
/// assert(sm.onStreamFrame(f) == TransportErrorCode.noError);
///
/// assert(sm.abandonRecv(StreamId(0)));            // the application discards the stream
/// assert(sm.connFlow.readOffset == 100);          // the buffered bytes are credited ...
/// f.offset = 100;
/// f.data = bytes[0 .. 200];
/// assert(sm.onStreamFrame(f) == TransportErrorCode.noError);   // later bytes are credited too
/// assert(sm.connFlow.readOffset == sm.connFlow.highestReceived);   // ... and so are later ones
/// assert(sm.abandonRecv(StreamId(0)));
/// assert(sm.connFlow.readOffset == 300);          // exactly once
/// ---
// Spec: RFC 9000 Section 4.1 "A receiver maintains a cumulative sum of bytes received on all
// streams, which is used to check for violations of the advertised connection or stream data
// limits." - bytes the application will never read must still return their connection credit
// exactly once, and an abandoned receive side completes at its final size (PB-4, M2)
@nogc unittest
{
    StreamMap sm = StreamMap(Side.server, 600, 500, 500, 500, 4, 4, 4, 4);
    ubyte[300] chunk;
    StreamFrame f;
    f.streamId = 0;
    f.offset = 0;
    f.data = chunk[0 .. 100];
    assert(sm.onStreamFrame(f) == TransportErrorCode.noError);
    assert(sm.connFlow.highestReceived == 100 && sm.connFlow.readOffset == 0);

    // Unknown streams and send-only streams have nothing to abandon.
    assert(!sm.abandonRecv(StreamId(4)));
    StreamId sendOnly;
    assert(sm.openLocalStream(StreamDirection.unidirectional,
            sendOnly) == TransportErrorCode.noError);
    assert(!sm.abandonRecv(sendOnly));

    assert(sm.abandonRecv(StreamId(0)));
    QuicStream* s = sm.getStream(StreamId(0));
    assert(s !is null && s.recvBuf.readableBytes == 0, "buffered bytes were discarded");
    assert(sm.connFlow.readOffset == 100, "buffered bytes were credited");
    ulong nextMax;
    assert(!sm.connFlow.shouldSendMaxDataUpdate(nextMax),
            "under half of the window consumed: no update yet");
    assert(sm.abandonRecv(StreamId(0)));
    assert(sm.connFlow.readOffset == 100, "abandoning twice must not credit twice");

    // Bytes that arrive later are credited as they arrive, not buffered.
    f.offset = 100;
    f.data = chunk[0 .. 200];
    assert(sm.onStreamFrame(f) == TransportErrorCode.noError);
    assert(sm.connFlow.highestReceived == 300 && sm.connFlow.readOffset == 300);
    assert(s.recvBuf.readableBytes == 0);
    Frame fc;
    assert(sm.pollFlowControlFrame(fc) && fc.type == FrameType.maxData,
            "the returned credit is announced to the peer (MAX_DATA)");
    // Retransmitted bytes do not credit again.
    f.offset = 0;
    f.data = chunk[0 .. 300];
    assert(sm.onStreamFrame(f) == TransportErrorCode.noError);
    assert(sm.connFlow.readOffset == 300);

    // Final size rules still apply to an abandoned stream.
    f.offset = 300;
    f.data = chunk[0 .. 0];
    f.fin = true;
    assert(sm.onStreamFrame(f) == TransportErrorCode.noError);
    ResetStreamFrame bad;
    bad.streamId = 0;
    bad.finalSize = 301;
    assert(sm.onResetStreamFrame(bad) == TransportErrorCode.finalSizeError);

    // Its receive side is done at the final size, so the stream (whose send side is done too)
    // can be reaped; the peer's stream slot is returned.
    assert(!sm.isStreamClosed(*s), "a bidirectional stream also needs its send side done");
    s.sendState = SendStreamState.dataRecvd;
    assert(sm.isStreamClosed(*s));
    assert(sm.reapClosedStreams() == 1);
    assert(sm.getStream(StreamId(0)) is null);

    // A RESET_STREAM that raises the final size of an abandoned stream credits the difference.
    f.streamId = 4;
    f.offset = 0;
    f.fin = false;
    f.data = chunk[0 .. 50];
    assert(sm.onStreamFrame(f) == TransportErrorCode.noError);
    assert(sm.abandonRecv(StreamId(4)));
    const before = sm.connFlow.readOffset;
    ResetStreamFrame rst;
    rst.streamId = 4;
    rst.applicationErrorCode = 1;
    rst.finalSize = 120;
    assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
    assert(sm.connFlow.readOffset == before + 70, "bytes up to the final size are credited once");
    assert(sm.connFlow.readOffset == sm.connFlow.highestReceived);
}

/// Example:
/// ---
/// StreamMap sm = StreamMap(Side.server, 2000, 1000, 1000, 1000, 4, 4, 4, 4);
/// ubyte[400] bytes;
/// StreamFrame f;
/// f.streamId = 0;
/// f.data = bytes[];
/// assert(sm.onStreamFrame(f) == TransportErrorCode.noError);
///
/// ResetStreamFrame rst;
/// rst.streamId = 0;
/// rst.finalSize = 400;
/// assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);   // credits final size - read
/// assert(sm.abandonRecv(StreamId(0)));                                 // credits nothing more
/// assert(sm.connFlow.readOffset == 400);
/// assert(sm.connFlow.readOffset <= sm.connFlow.highestReceived);
/// ---
// Spec: RFC 9000 Section 4.1 "A receiver maintains a cumulative sum of bytes received on all
// streams, which is used to check for violations of the advertised connection or stream data
// limits." - the connection credit of a stream is bounded by the bytes it received, in either
// order of RESET_STREAM and abandonRecv and after partial application reads (PB-4, M2)
@nogc unittest
{
    foreach (resetFirst; [true, false])
    {
        foreach (partialRead; [0, 150])
        {
            StreamMap sm = StreamMap(Side.server, 2000, 1000, 1000, 1000, 4, 4, 4, 4);
            ubyte[400] chunk;
            StreamFrame f;
            f.streamId = 0;
            f.offset = 0;
            f.data = chunk[0 .. 400];
            assert(sm.onStreamFrame(f) == TransportErrorCode.noError);
            QuicStream* s = sm.getStream(StreamId(0));
            assert(s !is null);
            if (partialRead > 0)
            {
                ubyte[150] sink;
                bool fin;
                const n = s.recvBuf.read(sink[], fin);
                assert(n == partialRead);
                sm.onApplicationRead(*s, n);
                assert(sm.connFlow.readOffset == partialRead);
            }
            ResetStreamFrame rst;
            rst.streamId = 0;
            rst.applicationErrorCode = 7;
            rst.finalSize = 400;
            if (resetFirst)
            {
                assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
                assert(sm.connFlow.readOffset == 400);
                assert(sm.abandonRecv(StreamId(0)));
            }
            else
            {
                assert(sm.abandonRecv(StreamId(0)));
                assert(sm.connFlow.readOffset == 400);
                assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
            }
            assert(sm.connFlow.highestReceived == 400);
            assert(sm.connFlow.readOffset == 400,
                    "every byte is credited exactly once, in either order");
            assert(sm.connFlow.readOffset <= sm.connFlow.highestReceived);
            assert(s.connCreditedOffset == 400);

            // Nothing is credited again by duplicates, late reads or a second abandon.
            assert(sm.onResetStreamFrame(rst) == TransportErrorCode.noError);
            assert(sm.abandonRecv(StreamId(0)));
            sm.onApplicationRead(*s, 10);
            assert(sm.connFlow.readOffset == 400);
        }
    }
}
