module slate.quic.connection.packet_packer;

/**
 * Outbound packet packing and frame serialization for QuicConnection.
 */

import slate.quic.crypto.kdf : Side, CipherSuite, EncryptionLevel,
    QuicCryptoError, deriveKeyMaterial, KeyMaterial, deriveNextApplicationSecret;
import slate.quic.crypto.packet_keys : protectPacket;
import slate.quic.wire.cid : ConnectionId, TransportErrorCode;
import slate.quic.wire.packet : PacketType, encodeLongHeader, encodeShortHeader, QUIC_VERSION_1;
import slate.quic.wire.frame : Frame, FrameType, AckRange, AckFrame,
    StreamFrame, CryptoFrame, ConnectionCloseFrame, PathChallengeFrame,
    PathResponseFrame, HandshakeDoneFrame, ResetStreamFrame, StopSendingFrame, encodeFrame;
import slate.quic.stream.id : StreamId;
import slate.quic.stream.send_buffer : TransmitChunk;
import slate.quic.recovery.loss_detection : PacketNumberSpace;
import slate.quic.crypto.header_protection : packetNumberLength;
import slate.quic.connection.connection : ConnectionState;
import slate.quic.connection.sent_frames : SentFrameKind, SentFrameDesc, MAX_FRAMES_PER_PACKET;
import slate.quic.crypto.c_openssl : OPENSSL_cleanse;

/// Smallest UDP payload carrying a client Initial or an ack-eliciting server Initial
/// (RFC 9000 Section 14.1).
enum size_t MIN_INITIAL_DATAGRAM_SIZE = 1200;

/// An Initial packet whose frames are collected but which is not yet sealed.
struct PendingInitial
{
    ubyte[4096] plaintext;
    size_t plainLen;
    SentFrameDesc[MAX_FRAMES_PER_PACKET] sentFramesList;
    ubyte frameCount;
    bool ackPacked;
    bool pingPacked;
    bool ackEliciting;
    ulong pn;
    size_t pnLen;
    const(ubyte)[] token;
}

mixin template QuicPacketPacker()
{
    import slate.quic.connection.packet_packer : PendingInitial, MIN_INITIAL_DATAGRAM_SIZE;
    import slate.quic.crypto.header_protection : packetNumberLength;

    /**
     * Largest UDP payload this connection emits (plan D1): 1200 bytes, the size every QUIC
     * path must support (RFC 9000 Section 14), and never more than the peer's
     * max_udp_payload_size (Section 18.2), until path MTU discovery exists.
     */
    @property size_t maxDatagramSize() const @safe pure @nogc nothrow
    {
        enum size_t SAFE_DATAGRAM_SIZE = 1200;
        if (peerParamsReceived && peerParams.maxUdpPayloadSize < SAFE_DATAGRAM_SIZE)
            return cast(size_t) peerParams.maxUdpPayloadSize;
        return SAFE_DATAGRAM_SIZE;
    }

    /**
     * Packs pending outgoing frames into coalesced packets within outDatagram.
     * At most `maxDatagramSize` bytes are written, whatever the buffer size.
     *
     * A client must pass a buffer of at least 1200 bytes (`MIN_INITIAL_DATAGRAM_SIZE`) for as
     * long as its handshake is in progress: a datagram carrying a client Initial has to be
     * padded to that size (RFC 9000 Section 14.1), so a smaller buffer can never carry the
     * handshake. With a smaller buffer the call is a harmless no-op that returns false and consumes
     * no CRYPTO bytes, so the handshake never progresses. Servers may pass smaller buffers, but are then limited to what the
     * anti-amplification budget allows (RFC 9000 Section 8.1).
     */
    bool pollTransmit(ubyte[] outBuffer, ulong nowMicros, out size_t bytesWritten) @trusted @nogc nothrow
    {
        bytesWritten = 0;
        ubyte[] outDatagram = outBuffer.length > maxDatagramSize
            ? outBuffer[0 .. maxDatagramSize] : outBuffer;
        if (outDatagram.length == 0 || state == ConnectionState.draining
                || state == ConnectionState.closed)
            return false;

        drainTls();

        // Closing state: emit CONNECTION_CLOSE packet once and transition to draining
        if (state == ConnectionState.closing && !closePacketSent)
        {
            const size_t closeBudget = amplificationBudget();
            if (closeBudget == 0)
                return false;
            const size_t maxCloseAllowed = (closeBudget < outDatagram.length) ? closeBudget
                : outDatagram.length;
            return emitClosePacket(outDatagram[0 .. maxCloseAllowed], nowMicros, bytesWritten);
        }

        const size_t budget = amplificationBudget();
        if (budget == 0)
            return false;

        const size_t maxAllowed = (budget < outDatagram.length) ? budget : outDatagram.length;
        size_t coalescedLen = 0;

        // 1. Initial Packet: frames are collected first, but the packet is sealed only after the
        // packets coalesced behind it are known, so the datagram can be padded inside the
        // Initial (RFC 9000 Section 12.2 / 14.1) without ever protecting two plaintexts
        // under one packet number.
        PendingInitial pending;
        size_t initialLen = 0;
        if (hasWriteKeys[0] && coalescedLen < maxAllowed)
        {
            // A client Initial datagram must reach 1200 bytes (RFC 9000 Section 14.1): with less
            // room nothing is built, so no state changes and the data waits for a larger buffer.
            if (localSide == Side.client
                    && maxAllowed < MIN_INITIAL_DATAGRAM_SIZE && initialHasPendingWork())
                return false;
            // A server may not send an unpadded ack-eliciting Initial either (RFC 9000
            // Section 14.1), and its anti-amplification budget (Section 8.1) may be too small to
            // pad: the CRYPTO/PING work waits for more budget (PB-3) while other spaces proceed.
            const bool serverMustWait = localSide == Side.server
                && maxAllowed < MIN_INITIAL_DATAGRAM_SIZE
                && (cryptoSend[0].hasPendingBytes || pingQueued);
            // The Initial is sized to `maxAllowed` (buffer and anti-amplification budget), so it
            // fits by construction; should measuring still fail, the CRYPTO bytes are re-queued.
            if (!serverMustWait && buildInitialPacket(pending, nowMicros, maxAllowed)
                    && !measureInitialPacket(pending, outDatagram[0 .. maxAllowed], initialLen))
            {
                rollbackInitial(pending);
                initialLen = 0;
            }
        }
        const bool initialPending = initialLen > 0;
        coalescedLen = initialLen;

        // 2. Handshake Packet
        bool handshakePacked = false;
        if (hasWriteKeys[2] && coalescedLen < maxAllowed)
        {
            size_t pktLen = 0;
            if (packHandshakePacket(outDatagram[coalescedLen .. maxAllowed], nowMicros, pktLen))
            {
                coalescedLen += pktLen;
                handshakePacked = true;
            }
        }

        // 3. 1-RTT Application Data Packet
        if (hasWriteKeys[3] && coalescedLen < maxAllowed)
        {
            size_t pktLen = 0;
            if (packOneRttPacket(outDatagram[coalescedLen .. maxAllowed], nowMicros, pktLen))
            {
                coalescedLen += pktLen;
            }
        }

        if (initialPending)
        {
            // Datagrams carrying an ack-eliciting Initial, and every client Initial, are
            // expanded to 1200 bytes (RFC 9000 Section 14.1); a server may not exceed its
            // amplification budget, in which case maxAllowed is below 1200 and nothing is added.
            const size_t restLen = coalescedLen - initialLen;
            size_t minInitialLen = 0;
            if ((localSide == Side.client || pending.ackEliciting)
                    && maxAllowed >= MIN_INITIAL_DATAGRAM_SIZE)
                minInitialLen = restLen < MIN_INITIAL_DATAGRAM_SIZE ? MIN_INITIAL_DATAGRAM_SIZE - restLen
                    : 0;
            size_t finalLen = 0;
            size_t restAt = initialLen;
            if (sealInitialPacket(pending, outDatagram[0 .. maxAllowed],
                    restLen, initialLen, minInitialLen, nowMicros, finalLen, restAt))
            {
                coalescedLen = finalLen + restLen;
            }
            else
            {
                // Sealing failed before anything of the Initial was committed: re-queue its
                // CRYPTO bytes and send the already sealed packets behind it on their own.
                rollbackInitial(pending);
                if (restLen > 0)
                {
                    import core.stdc.string : memmove;

                    memmove(outDatagram.ptr, outDatagram.ptr + restAt, restLen);
                }
                coalescedLen = restLen;
            }
        }

        // Client discards Initial keys upon sending first Handshake packet (RFC 9001 §4.9.1)
        if (handshakePacked && localSide == Side.client && (hasReadKeys[0] || hasWriteKeys[0]))
        {
            discardSpace(PacketNumberSpace.initial);
        }

        if (coalescedLen == 0)
            return false;

        totalBytesSent += coalescedLen;
        bytesWritten = coalescedLen;
        return true;
    }

    /// Whether the Initial space has an ACK, CRYPTO bytes or a PING waiting.
    private bool initialHasPendingWork() const @safe @nogc nothrow
    {
        return ackRanges[0].hasPendingAck || cryptoSend[0].hasPendingBytes || pingQueued;
    }

    /// Re-queues the CRYPTO ranges of a collected but unsent Initial for retransmission.
    private void rollbackInitial(ref const PendingInitial pi) @trusted @nogc nothrow
    {
        foreach (ref const d; pi.sentFramesList[0 .. pi.frameCount])
        {
            if (d.kind == SentFrameKind.crypto)
                cryptoSend[0].onRangeLost(d.offset, d.length, d.fin);
        }
    }

    /**
     * Collects the frames of the next Initial packet, which must fit into `limit` bytes
     * including header and AEAD tag. Nothing is consumed unless the packet is returned.
     */
    package bool buildInitialPacket(ref PendingInitial pi, ulong nowMicros, size_t limit) @trusted @nogc nothrow
    {
        const bool hasAck = ackRanges[0].hasPendingAck;
        const bool hasCrypto = cryptoSend[0].hasPendingBytes;

        if (!hasAck && !hasCrypto && !pingQueued)
            return false;

        // R-18: no free slot in the sent-frame ledger => send no tracked frame (they stay queued)
        // instead of sending frames that could never be retransmitted. An ACK-only packet carries
        // nothing to retransmit and is never recorded, so it stays sendable (W6 liveness).
        const bool canTrack = sentFrames.reserve(PacketNumberSpace.initial);
        if (!canTrack && !hasAck)
            return false;

        ubyte[] plaintext = pi.plaintext[];
        size_t plainLen = 0;
        SentFrameDesc[] sentFramesList = pi.sentFramesList[];
        ubyte frameCount = 0;

        // Upper bound of the long header: flags, version, both CIDs, token field, a 2-byte
        // Length and a 4-byte packet number; the AEAD tag adds 16 bytes.
        const size_t estimatedHdrLen = 1 + 4 + (1 + remoteCid.len) + (
                1 + localCid.len) + (localSide == Side.client && retryTokenLen > 0
                ? 4 + retryTokenLen : 1) + 2 + 4;
        const size_t maxPlain = (limit > estimatedHdrLen + 16) ? (limit - estimatedHdrLen - 16) : 0;
        const size_t availPlain = (maxPlain < plaintext.length) ? maxPlain : plaintext.length;

        // PING frame
        bool pingPacked = false;
        if (canTrack && pingQueued && plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.ping;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0 && plainLen + wr <= availPlain)
            {
                plainLen += wr;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
                pingPacked = true;
            }
        }

        // ACK frame
        bool ackPacked = false;
        if (hasAck && plainLen < availPlain)
        {
            AckFrame ack;
            if (ackRanges[0].buildAckFrame(nowMicros, cast(ubyte) localParams.ackDelayExponent, ack))
            {
                Frame f;
                f.type = FrameType.ack;
                f.ack = ack;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0 && plainLen + wr <= availPlain)
                {
                    plainLen += wr;
                    ackPacked = true;
                }
            }
        }

        // CRYPTO frame (the frame header takes at most 16 bytes)
        const size_t availCrypto = (availPlain > plainLen + 16) ? (availPlain - plainLen - 16) : 0;

        if (canTrack && hasCrypto && availCrypto > 0
                && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            TransmitChunk chunk;
            if (cryptoSend[0].pollTransmit(availCrypto, chunk))
            {
                Frame f;
                f.type = FrameType.crypto;
                f.crypto.offset = chunk.offset;
                f.crypto.data = chunk.data;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0 && plainLen + wr <= availPlain)
                {
                    plainLen += wr;
                    sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.crypto,
                            0, chunk.offset, cast(uint) chunk.data.length, chunk.fin);
                }
                else
                {
                    cryptoSend[0].onRangeLost(chunk.offset, chunk.data.length, chunk.fin);
                }
            }
        }

        if (plainLen == 0)
            return false;

        pi.frameCount = frameCount;
        pi.ackPacked = ackPacked;
        pi.pingPacked = pingPacked;
        pi.ackEliciting = frameCount > 0;
        pi.pn = nextPn[0];
        const ulong largestAcked = lossDetector.hasAckedPn[0] ? lossDetector.largestAckedPn[0] : 0;
        pi.pnLen = packetNumberLength(pi.pn, largestAcked);
        // RFC 9001 Section 5.4.2: header protection samples 16 ciphertext bytes starting 4 bytes
        // after the packet number field, so payload + packet number must span at least 4 bytes;
        // a lone PING would not. PADDING frames (zero bytes) make up the difference (PB-2).
        if (plainLen + pi.pnLen < 4)
        {
            const size_t minPlain = 4 - pi.pnLen;
            plaintext[plainLen .. minPlain] = 0;
            plainLen = minPlain;
        }
        pi.plainLen = plainLen;
        pi.token = (localSide == Side.client && retryTokenLen > 0)
            ? retryTokenBuf[0 .. retryTokenLen] : null;
        return true;
    }

    /// Writes the Initial header for the pending packet at `plainLen` payload bytes.
    private bool encodeInitialHeader(ref const PendingInitial pi, size_t plainLen,
            ubyte[] outBuf, out size_t pnOff, out size_t hdrLen) @trusted @nogc nothrow
    {
        return encodeLongHeader(PacketType.initial, QUIC_VERSION_1, remoteCid,
                localCid, pi.token, pi.pn, pi.pnLen, plainLen, outBuf, pnOff, hdrLen) == 0;
    }

    /// Computes the sealed size of the pending Initial without padding; false if it cannot fit.
    package bool measureInitialPacket(ref const PendingInitial pi,
            ubyte[] outBuf, out size_t packetLen) @trusted @nogc nothrow
    {
        size_t pnOff, hdrLen;
        if (!encodeInitialHeader(pi, pi.plainLen, outBuf, pnOff, hdrLen))
            return false;
        if (outBuf.length < hdrLen + pi.plainLen + 16)
            return false;
        packetLen = hdrLen + pi.plainLen + 16;
        return true;
    }

    /**
     * Seals the pending Initial at the front of `outBuf`. The `restLen` bytes of packets already
     * coalesced behind it (starting at `measuredLen`) are shifted if PADDING grows the Initial
     * to `minPacketLen` bytes; `restAt` reports where they ended up. Commits the packet-number,
     * ACK and recovery state only on success, so a failure leaves the connection untouched.
     */
    package bool sealInitialPacket(ref PendingInitial pi, ubyte[] outBuf, size_t restLen,
            size_t measuredLen, size_t minPacketLen, ulong nowMicros,
            out size_t packetLen, out size_t restAt) @trusted @nogc nothrow
    {
        import core.stdc.string : memmove;

        restAt = measuredLen;

        size_t plainLen = pi.plainLen;
        size_t pnOff, hdrLen;
        if (minPacketLen > measuredLen)
        {
            plainLen += minPacketLen - measuredLen;
            if (!encodeInitialHeader(pi, plainLen, outBuf, pnOff, hdrLen))
                return false;
            // A longer Length field would overshoot the target; take it back out of the padding.
            if (hdrLen + plainLen + 16 > minPacketLen)
                plainLen -= hdrLen + plainLen + 16 - minPacketLen;
            pi.plaintext[pi.plainLen .. plainLen] = 0;
        }
        if (!encodeInitialHeader(pi, plainLen, outBuf, pnOff, hdrLen))
            return false;
        packetLen = hdrLen + plainLen + 16;
        if (packetLen + restLen > outBuf.length)
            return false;
        if (packetLen != measuredLen)
        {
            memmove(outBuf.ptr + packetLen, outBuf.ptr + measuredLen, restLen);
            restAt = packetLen;
        }

        outBuf[hdrLen .. hdrLen + plainLen] = pi.plaintext[0 .. plainLen];
        size_t protLen = 0;
        if (protectPacket(levelKeys[0].local, pi.pn, pnOff, pi.pnLen,
                outBuf[0 .. packetLen], plainLen, protLen) != QuicCryptoError.none)
            return false;

        if (pi.ackPacked)
            ackRanges[0].onAckSent();
        if (pi.pingPacked)
            pingQueued = false;

        nextPn[0]++;
        if (pi.frameCount > 0)
            sentFrames.recordPacket(PacketNumberSpace.initial, pi.pn,
                    pi.sentFramesList[0 .. pi.frameCount]);
        lossDetector.onPacketSent(PacketNumberSpace.initial, pi.pn,
                cast(uint) protLen, pi.frameCount > 0, pi.frameCount > 0, nowMicros);
        return true;
    }

    private bool packHandshakePacket(ubyte[] outBuf, ulong nowMicros, out size_t pktLen) @trusted @nogc nothrow
    {
        pktLen = 0;
        const bool hasAck = ackRanges[1].hasPendingAck;
        const bool hasCrypto = cryptoSend[1].hasPendingBytes;

        if (!hasAck && !hasCrypto && !pingQueued)
            return false;

        // R-18: no free slot in the sent-frame ledger => send no tracked frame (they stay queued)
        // instead of sending frames that could never be retransmitted. An ACK-only packet carries
        // nothing to retransmit and is never recorded, so it stays sendable (W6 liveness).
        const bool canTrack = sentFrames.reserve(PacketNumberSpace.handshake);
        if (!canTrack && !hasAck)
            return false;

        ubyte[4096] plaintext;
        size_t plainLen = 0;
        SentFrameDesc[MAX_FRAMES_PER_PACKET] sentFramesList;
        ubyte frameCount = 0;

        // PING frame
        bool pingPacked = false;
        if (canTrack && pingQueued && plainLen < plaintext.length
                && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.ping;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
            {
                plainLen += wr;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
                pingPacked = true;
            }
        }

        // ACK frame
        bool ackPacked = false;
        if (hasAck && plainLen < plaintext.length)
        {
            AckFrame ack;
            if (ackRanges[1].buildAckFrame(nowMicros, cast(ubyte) localParams.ackDelayExponent, ack))
            {
                Frame f;
                f.type = FrameType.ack;
                f.ack = ack;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
                {
                    plainLen += wr;
                    ackPacked = true;
                }
            }
        }

        // CRYPTO frame
        const size_t maxPlain = (outBuf.length > 64) ? (outBuf.length - 64) : 0;
        const size_t availPlain = (maxPlain < plaintext.length) ? maxPlain : plaintext.length;
        const size_t availCrypto = (availPlain > plainLen + 16) ? (availPlain - plainLen - 16) : 0;

        if (canTrack && hasCrypto && availCrypto > 0
                && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            TransmitChunk chunk;
            if (cryptoSend[1].pollTransmit(availCrypto, chunk))
            {
                Frame f;
                f.type = FrameType.crypto;
                f.crypto.offset = chunk.offset;
                f.crypto.data = chunk.data;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
                {
                    plainLen += wr;
                    sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.crypto,
                            0, chunk.offset, cast(uint) chunk.data.length, chunk.fin);
                }
            }
        }

        if (plainLen == 0)
            return false;

        const ulong pn = nextPn[1];
        const ulong largestAcked = lossDetector.hasAckedPn[1] ? lossDetector.largestAckedPn[1] : 0;
        const size_t pnLen = packetNumberLength(pn, largestAcked);
        if (plainLen + pnLen < 4)
        {
            const size_t minPlain = 4 - pnLen;
            plaintext[plainLen .. minPlain] = 0;
            plainLen = minPlain;
        }
        size_t pnOff = 0;
        size_t hdrLen = 0;

        if (encodeLongHeader(PacketType.handshake, QUIC_VERSION_1, remoteCid,
                localCid, null, pn, pnLen, plainLen, outBuf, pnOff, hdrLen) != 0)
            return false;

        if (outBuf.length < hdrLen + plainLen + 16)
            return false;

        outBuf[hdrLen .. hdrLen + plainLen] = plaintext[0 .. plainLen];

        size_t protLen = 0;
        if (protectPacket(levelKeys[2].local, pn, pnOff, pnLen, outBuf,
                plainLen, protLen) != QuicCryptoError.none)
            return false;

        if (ackPacked)
            ackRanges[1].onAckSent();
        if (pingPacked)
            pingQueued = false;

        nextPn[1]++;
        if (frameCount > 0)
            sentFrames.recordPacket(PacketNumberSpace.handshake, pn,
                    sentFramesList[0 .. frameCount]);
        lossDetector.onPacketSent(PacketNumberSpace.handshake, pn,
                cast(uint) protLen, frameCount > 0, frameCount > 0, nowMicros);

        pktLen = protLen;
        return true;
    }

    private bool packOneRttPacket(ubyte[] outBuf, ulong nowMicros, out size_t pktLen) @trusted @nogc nothrow
    {
        pktLen = 0;
        const bool hasAck = ackRanges[2].hasPendingAck;
        const bool hasCrypto = cryptoSend[2].hasPendingBytes;
        const bool hasStream = streams.hasPendingWritable;
        const bool hasFlowControl = streams.hasPendingFlowControl;

        if (!hasAck && !hasCrypto && !hasStream && !hasFlowControl && !handshakeDoneQueued
                && !hasPendingPathResponse && !hasPendingPathChallenge && !pingQueued)
            return false;

        // R-18: no free slot in the sent-frame ledger => send no tracked frame (they stay queued)
        // instead of sending frames that could never be retransmitted. An ACK-only packet carries
        // nothing to retransmit and is never recorded, so it stays sendable (W6 liveness).
        const bool canTrack = sentFrames.reserve(PacketNumberSpace.applicationData);
        if (!canTrack && !hasAck)
            return false;

        const size_t estimatedHdrLen = 1 + remoteCid.len + 4;
        const size_t maxPlain = (outBuf.length > estimatedHdrLen + 16) ? (
                outBuf.length - estimatedHdrLen - 16) : 0;
        const size_t availPlain = (maxPlain < 4096) ? maxPlain : 4096;
        if (availPlain == 0)
            return false;

        ubyte[4096] plaintext;
        size_t plainLen = 0;
        SentFrameDesc[MAX_FRAMES_PER_PACKET] sentFramesList;
        ubyte frameCount = 0;

        // PING frame
        bool pingPacked = false;
        if (canTrack && pingQueued && plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.ping;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. availPlain], wr) == 0)
            {
                plainLen += wr;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
                pingPacked = true;
            }
        }

        // Pending control frames (RESET_STREAM or STOP_SENDING) (D-04)
        Frame ctrlFrame;
        while (canTrack && plainLen < availPlain
                && frameCount < MAX_FRAMES_PER_PACKET && streams.pollControlFrame(ctrlFrame))
        {
            size_t wr = 0;
            if (encodeFrame(ctrlFrame, plaintext[plainLen .. availPlain], wr) == 0)
            {
                plainLen += wr;
                sentFramesList[frameCount++] = SentFrameDesc((ctrlFrame.type == FrameType.resetStream)
                        ? SentFrameKind.resetStream
                        : SentFrameKind.stopSending,
                        (ctrlFrame.type == FrameType.resetStream) ? ctrlFrame.resetStream.streamId
                        : ctrlFrame.stopSending.streamId, 0, 0, false);
            }
            else
            {
                QuicStream* qs = streams.getStream(StreamId((ctrlFrame.type == FrameType.resetStream)
                        ? ctrlFrame.resetStream.streamId : ctrlFrame.stopSending.streamId));
                if (qs !is null)
                {
                    if (ctrlFrame.type == FrameType.resetStream)
                        qs.resetQueued = true;
                    else
                        qs.stopSendingQueued = true;
                }
                break;
            }
        }

        // Pending flow control updates (MAX_DATA, MAX_STREAM_DATA, MAX_STREAMS) (F-05, D-02, D-04)
        Frame fcFrame;
        while (canTrack && plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET
                && streams.pollFlowControlFrame(fcFrame))
        {
            size_t wr = 0;
            if (encodeFrame(fcFrame, plaintext[plainLen .. availPlain], wr) == 0)
            {
                plainLen += wr;
                SentFrameKind kind;
                ulong sId = 0;
                if (fcFrame.type == FrameType.maxData)
                {
                    kind = SentFrameKind.maxData;
                }
                else if (fcFrame.type == FrameType.maxStreamData)
                {
                    kind = SentFrameKind.maxStreamData;
                    sId = fcFrame.maxStreamData.streamId;
                }
                else if (fcFrame.type == FrameType.maxStreamsBidi)
                {
                    kind = SentFrameKind.maxStreamsBidi;
                }
                else
                {
                    kind = SentFrameKind.maxStreamsUni;
                }
                sentFramesList[frameCount++] = SentFrameDesc(kind, sId, 0, 0, false);
            }
            else
            {
                if (fcFrame.type == FrameType.maxData)
                {
                    streams.connFlow.rearm();
                }
                else if (fcFrame.type == FrameType.maxStreamData)
                {
                    QuicStream* qs = streams.getStream(StreamId(fcFrame.maxStreamData.streamId));
                    if (qs !is null)
                        qs.flowCtrl.rearm();
                }
                else if (fcFrame.type == FrameType.maxStreamsBidi)
                {
                    streams.maxStreamsBidiPending = true;
                }
                else if (fcFrame.type == FrameType.maxStreamsUni)
                {
                    streams.maxStreamsUniPending = true;
                }
                break;
            }
        }

        // ACK frame
        bool ackPacked = false;
        if (hasAck && plainLen < availPlain)
        {
            AckFrame ack;
            if (ackRanges[2].buildAckFrame(nowMicros, cast(ubyte) localParams.ackDelayExponent, ack))
            {
                Frame f;
                f.type = FrameType.ack;
                f.ack = ack;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. availPlain], wr) == 0)
                {
                    plainLen += wr;
                    ackPacked = true;
                }
            }
        }

        // HANDSHAKE_DONE frame (Server only)
        if (canTrack && handshakeDoneQueued && plainLen < availPlain
                && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.handshakeDone;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. availPlain], wr) == 0)
            {
                plainLen += wr;
                handshakeDoneQueued = false;
                handshakeDoneInFlight = true;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.handshakeDone,
                        0, 0, 0, false);
            }
        }

        // PATH_RESPONSE frame
        if (canTrack && hasPendingPathResponse && plainLen < availPlain
                && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.pathResponse;
            f.pathResponse.data = pendingPathResponseData;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. availPlain], wr) == 0)
            {
                plainLen += wr;
                hasPendingPathResponse = false;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
            }
        }

        // PATH_CHALLENGE frame
        if (canTrack && hasPendingPathChallenge && plainLen < availPlain
                && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.pathChallenge;
            f.pathChallenge.data = pendingPathChallengeData;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. availPlain], wr) == 0)
            {
                plainLen += wr;
                hasPendingPathChallenge = false;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
            }
        }

        // CRYPTO frame (post-handshake 1-RTT)
        const size_t availCrypto = (availPlain > plainLen + 16) ? (availPlain - plainLen - 16) : 0;
        if (canTrack && hasCrypto && availCrypto > 0 && plainLen < availPlain
                && frameCount < MAX_FRAMES_PER_PACKET)
        {
            TransmitChunk chunk;
            if (cryptoSend[2].pollTransmit(availCrypto, chunk))
            {
                Frame f;
                f.type = FrameType.crypto;
                f.crypto.offset = chunk.offset;
                f.crypto.data = chunk.data;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. availPlain], wr) == 0)
                {
                    plainLen += wr;
                    sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.crypto,
                            0, chunk.offset, cast(uint) chunk.data.length, chunk.fin);
                }
            }
        }

        // STREAM frames (F-10: check lossDetector.cc.canSend)
        if (canTrack && hasStream && lossDetector.cc.canSend
                && plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET)
        {
            StreamId sid;
            TransmitChunk chunk;
            const size_t avail = (availPlain > plainLen + 32) ? (availPlain - plainLen - 32) : 0;
            if (avail > 0 && streams.pollWritable(sid, avail, chunk))
            {
                Frame f;
                f.type = FrameType.stream;
                f.stream.streamId = sid.id;
                f.stream.offset = chunk.offset;
                f.stream.data = chunk.data;
                f.stream.hasOffset = (chunk.offset > 0);
                f.stream.hasLength = true;
                f.stream.fin = chunk.fin;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. availPlain], wr) == 0)
                {
                    plainLen += wr;
                    sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.stream,
                            sid.id, chunk.offset, cast(uint) chunk.data.length, chunk.fin);
                }
            }
        }

        if (plainLen == 0)
            return false;

        const ulong pn = nextPn[2];
        const ulong largestAcked = lossDetector.hasAckedPn[2] ? lossDetector.largestAckedPn[2] : 0;
        const size_t pnLen = packetNumberLength(pn, largestAcked);
        if (plainLen + pnLen < 4)
        {
            const size_t minPlain = 4 - pnLen;
            plaintext[plainLen .. minPlain] = 0;
            plainLen = minPlain;
        }
        size_t pnOff = 0;
        size_t hdrLen = 0;
        const bool keyPhase = (localKeyPhase != 0);

        if (encodeShortHeader(remoteCid, pn, pnLen, keyPhase, false, outBuf, pnOff, hdrLen) != 0)
            return false;

        if (outBuf.length < hdrLen + plainLen + 16)
            return false;

        outBuf[hdrLen .. hdrLen + plainLen] = plaintext[0 .. plainLen];

        size_t protLen = 0;
        if (protectPacket(levelKeys[3].local, pn, pnOff, pnLen, outBuf,
                plainLen, protLen) != QuicCryptoError.none)
            return false;

        if (ackPacked)
            ackRanges[2].onAckSent();
        if (pingPacked)
            pingQueued = false;

        nextPn[2]++;
        if (frameCount > 0)
            sentFrames.recordPacket(PacketNumberSpace.applicationData, pn,
                    sentFramesList[0 .. frameCount]);
        lossDetector.onPacketSent(PacketNumberSpace.applicationData, pn,
                cast(uint) protLen, frameCount > 0, frameCount > 0, nowMicros);

        pktLen = protLen;
        return true;
    }

    private bool emitClosePacket(ubyte[] outBuf, ulong nowMicros, out size_t bytesWritten) @trusted @nogc nothrow
    {
        bytesWritten = 0;

        // Choose highest available encryption level
        size_t keyIdx = 0;
        PacketType pktType = PacketType.initial;
        PacketNumberSpace space = PacketNumberSpace.initial;

        if (hasWriteKeys[3])
        {
            keyIdx = 3;
            pktType = PacketType.oneRttShort;
            space = PacketNumberSpace.applicationData;
        }
        else if (hasWriteKeys[2])
        {
            keyIdx = 2;
            pktType = PacketType.handshake;
            space = PacketNumberSpace.handshake;
        }

        ubyte[256] plaintext;
        Frame f;
        if (space != PacketNumberSpace.applicationData && closeIsApp)
        {
            f.type = FrameType.connectionCloseQuic;
            f.connectionClose.errorCode = 0x0c; // APPLICATION_ERROR (RFC 9000 §10.2.3)
            f.connectionClose.frameType = 0;
            f.connectionClose.isApplication = false;
        }
        else
        {
            f.type = closeIsApp ? FrameType.connectionCloseApp : FrameType.connectionCloseQuic;
            f.connectionClose.errorCode = closeErrorCode;
            f.connectionClose.frameType = closeFrameType;
            f.connectionClose.isApplication = closeIsApp;
        }

        size_t plainLen = 0;
        if (encodeFrame(f, plaintext[], plainLen) != 0)
            return false;

        const ulong pn = nextPn[space];
        const ulong largestAcked = lossDetector.hasAckedPn[space]
            ? lossDetector.largestAckedPn[space] : 0;
        const size_t pnLen = packetNumberLength(pn, largestAcked);
        size_t pnOff = 0;
        size_t hdrLen = 0;

        if (pktType == PacketType.oneRttShort)
        {
            const bool keyPhase = (localKeyPhase != 0);
            if (encodeShortHeader(remoteCid, pn, pnLen, keyPhase, false, outBuf, pnOff, hdrLen) != 0)
                return false;
        }
        else
        {
            if (encodeLongHeader(pktType, QUIC_VERSION_1, remoteCid, localCid,
                    null, pn, pnLen, plainLen, outBuf, pnOff, hdrLen) != 0)
                return false;
        }

        if (outBuf.length < hdrLen + plainLen + 16)
            return false;

        outBuf[hdrLen .. hdrLen + plainLen] = plaintext[0 .. plainLen];

        size_t protLen = 0;
        if (protectPacket(levelKeys[keyIdx].local, pn, pnOff, pnLen, outBuf,
                plainLen, protLen) != QuicCryptoError.none)
            return false;

        nextPn[space]++;
        closePacketSent = true;
        state = ConnectionState.draining;
        drainingEndTimeMicros = drainingEndFor(nowMicros);

        totalBytesSent += protLen;
        bytesWritten = protLen;
        return true;
    }

    private void enterClosing(ulong errCode, ulong frameType, bool isApp) @safe pure @nogc nothrow
    {
        if (state == ConnectionState.closing
                || state == ConnectionState.draining || state == ConnectionState.closed)
            return;

        state = ConnectionState.closing;
        closeErrorCode = errCode;
        closeFrameType = frameType;
        closeIsApp = isApp;
        closePacketSent = false;
    }

    /**
     * Discards keys, buffers, and loss detection for a packet number space (RFC 9001 §4.9).
     */
    void discardSpace(PacketNumberSpace space) @trusted @nogc nothrow
    {
        size_t lvl = 0;
        if (space == PacketNumberSpace.initial)
            lvl = 0;
        else if (space == PacketNumberSpace.handshake)
            lvl = 2;
        else
            return;

        levelKeys[lvl].cleanup();
        hasReadKeys[lvl] = false;
        hasWriteKeys[lvl] = false;

        cryptoRecv[space].cleanup();
        cryptoSend[space].cleanup();
        ackRanges[space].clear();

        sentFrames.discardSpace(space);
        lossDetector.discardSpace(space);
    }

    void sendPathChallenge(const ref ubyte[8] data) @safe pure @nogc nothrow
    {
        hasPendingPathChallenge = true;
        pendingPathChallengeData = data;
    }

    /**
     * Starts a key update of the local write keys (RFC 9001 Section 6.1). Refused (false) before
     * the handshake is confirmed, and while a previous local update has not yet been confirmed by
     * an acknowledgment for a packet sent under its keys.
     */
    bool initiateKeyUpdate() @trusted @nogc nothrow
    {
        if (!hasWriteKeys[3] || appSecretLen == 0 || !handshakeConfirmed || !localPhaseAcked)
            return false;

        ubyte[48] nextLocalSec;
        KeyMaterial nextKm;
        AeadKey newAead;
        scope (exit)
        {
            OPENSSL_cleanse(nextLocalSec.ptr, nextLocalSec.length);
            OPENSSL_cleanse(nextKm.key.ptr, nextKm.key.length);
            OPENSSL_cleanse(nextKm.iv.ptr, nextKm.iv.length);
            OPENSSL_cleanse(nextKm.hp.ptr, nextKm.hp.length);
        }
        // Derive and install into a scratch key first: a failure leaves the current keys intact.
        if (!deriveNextApplicationSecret(tls.negotiatedCipher, localAppSecret[0 .. appSecretLen],
                nextLocalSec[0 .. appSecretLen]) || !deriveKeyMaterial(tls.negotiatedCipher,
                nextLocalSec[0 .. appSecretLen], nextKm) || !newAead.init(tls.negotiatedCipher,
                nextKm.key[0 .. nextKm.keyLen], nextKm.iv[0 .. 12]))
            return false;

        levelKeys[3].local.aead.moveFrom(newAead);
        localAppSecret[0 .. appSecretLen] = nextLocalSec[0 .. appSecretLen];
        localKeyPhase ^= 1;
        noteLocalKeyUpdate();
        return true;
    }
}

// Spec: RFC 9000 Section 10 & RFC 9001 Section 4.9 - Path challenge and closing state transitions
/// Example:
/// ---
/// import slate.quic.connection.connection : QuicConnection, ConnectionState;
///
/// QuicConnection conn;
/// conn.state = ConnectionState.active;
/// const ubyte[8] challengeData = [1, 2, 3, 4, 5, 6, 7, 8];
/// conn.sendPathChallenge(challengeData);
/// assert(conn.hasPendingPathChallenge);
/// conn.close(0x0A, true);   // an application close
/// assert(conn.state == ConnectionState.closing);
/// assert(conn.closeErrorCode == 0x0A && conn.closeIsApp);
/// conn.cleanup();
/// ---
@nogc unittest
{
    import slate.quic.connection.connection : QuicConnection, ConnectionState;

    QuicConnection conn;
    conn.state = ConnectionState.active;
    const ubyte[8] challengeData = [1, 2, 3, 4, 5, 6, 7, 8];
    conn.sendPathChallenge(challengeData);
    assert(conn.hasPendingPathChallenge);
    conn.close(0x0A, true);
    assert(conn.state == ConnectionState.closing);
    assert(conn.closeErrorCode == 0x0A);
    assert(conn.closeIsApp == true);
    conn.cleanup();
}
