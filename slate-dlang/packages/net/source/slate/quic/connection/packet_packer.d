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

mixin template QuicPacketPacker()
{
    import slate.quic.crypto.header_protection : packetNumberLength;

    /**
     * Packs pending outgoing frames into coalesced packets within outDatagram.
     */
    bool pollTransmit(ubyte[] outDatagram, ulong nowMicros, out size_t bytesWritten) @trusted @nogc nothrow
    {
        bytesWritten = 0;
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

        // 1. Initial Packet
        if (hasWriteKeys[0] && coalescedLen < maxAllowed)
        {
            size_t pktLen = 0;
            if (packInitialPacket(outDatagram[coalescedLen .. maxAllowed], nowMicros, pktLen))
            {
                coalescedLen += pktLen;
            }
        }

        // 2. Handshake Packet
        if (hasWriteKeys[2] && coalescedLen < maxAllowed)
        {
            size_t pktLen = 0;
            if (packHandshakePacket(outDatagram[coalescedLen .. maxAllowed], nowMicros, pktLen))
            {
                coalescedLen += pktLen;
                // Client discards Initial keys upon sending first Handshake packet (RFC 9001 §4.9.1)
                if (localSide == Side.client && (hasReadKeys[0] || hasWriteKeys[0]))
                {
                    discardSpace(PacketNumberSpace.initial);
                }
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

        if (coalescedLen == 0)
            return false;

        totalBytesSent += coalescedLen;
        bytesWritten = coalescedLen;
        return true;
    }

    private bool packInitialPacket(ubyte[] outBuf, ulong nowMicros, out size_t pktLen) @trusted @nogc nothrow
    {
        pktLen = 0;
        const bool hasAck = ackRanges[0].hasPendingAck;
        const bool hasCrypto = cryptoSend[0].hasPendingBytes;

        if (!hasAck && !hasCrypto && !pingQueued)
            return false;

        ubyte[4096] plaintext;
        size_t plainLen = 0;
        SentFrameDesc[MAX_FRAMES_PER_PACKET] sentFramesList;
        ubyte frameCount = 0;

        // PING frame
        bool pingPacked = false;
        if (pingQueued && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
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
            if (ackRanges[0].buildAckFrame(nowMicros, cast(ubyte) localParams.ackDelayExponent, ack))
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
        const size_t estimatedHdrLen = 1 + 4 + (1 + remoteCid.len) + (
                1 + localCid.len) + (localSide == Side.client && retryTokenLen > 0
                ? 2 + retryTokenLen : 1) + 2;
        const size_t maxPlain = (outBuf.length > estimatedHdrLen + 16) ? (
                outBuf.length - estimatedHdrLen - 16) : 0;
        const size_t availPlain = (maxPlain < plaintext.length) ? maxPlain : plaintext.length;
        const size_t availCrypto = (availPlain > plainLen + 16) ? (availPlain - plainLen - 16) : 0;

        if (hasCrypto && availCrypto > 0 && plainLen < plaintext.length
                && frameCount < MAX_FRAMES_PER_PACKET)
        {
            TransmitChunk chunk;
            if (cryptoSend[0].pollTransmit(availCrypto, chunk))
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

        const ulong pn = nextPn[0];
        const ulong largestAcked = lossDetector.hasAckedPn[0] ? lossDetector.largestAckedPn[0] : 0;
        const size_t pnLen = packetNumberLength(pn, largestAcked);
        size_t pnOff = 0;
        size_t hdrLen = 0;

        const(ubyte)[] token = (localSide == Side.client && retryTokenLen > 0) ? retryTokenBuf[0
            .. retryTokenLen] : null;

        // Encode header first with preliminary plainLen to determine exact headerLen
        if (encodeLongHeader(PacketType.initial, QUIC_VERSION_1, remoteCid,
                localCid, token, pn, pnLen, plainLen, outBuf, pnOff, hdrLen) != 0)
            return false;

        // Padding: Client Initial datagram must be padded to >= 1200 bytes (RFC 9000 §14.1)
        if (localSide == Side.client && outBuf.length >= 1200)
        {
            if (hdrLen + plainLen + 16 < 1200)
            {
                const size_t targetPlain = 1200 - hdrLen - 16;
                plaintext[plainLen .. targetPlain] = 0;
                plainLen = targetPlain;

                // Re-encode header with padded plainLen
                if (encodeLongHeader(PacketType.initial, QUIC_VERSION_1, remoteCid,
                        localCid, token, pn, pnLen, plainLen, outBuf, pnOff, hdrLen) != 0)
                    return false;
            }
        }

        if (outBuf.length < hdrLen + plainLen + 16)
            return false;

        outBuf[hdrLen .. hdrLen + plainLen] = plaintext[0 .. plainLen];

        size_t protLen = 0;
        if (protectPacket(levelKeys[0].local, pn, pnOff, pnLen, outBuf,
                plainLen, protLen) != QuicCryptoError.none)
            return false;

        if (ackPacked)
            ackRanges[0].onAckSent();
        if (pingPacked)
            pingQueued = false;

        nextPn[0]++;
        sentFrames.recordPacket(PacketNumberSpace.initial, pn, sentFramesList[0 .. frameCount]);
        lossDetector.onPacketSent(PacketNumberSpace.initial, pn,
                cast(uint) protLen, frameCount > 0, frameCount > 0, nowMicros);

        pktLen = protLen;
        return true;
    }

    private bool packHandshakePacket(ubyte[] outBuf, ulong nowMicros, out size_t pktLen) @trusted @nogc nothrow
    {
        pktLen = 0;
        const bool hasAck = ackRanges[1].hasPendingAck;
        const bool hasCrypto = cryptoSend[1].hasPendingBytes;

        if (!hasAck && !hasCrypto && !pingQueued)
            return false;

        ubyte[4096] plaintext;
        size_t plainLen = 0;
        SentFrameDesc[MAX_FRAMES_PER_PACKET] sentFramesList;
        ubyte frameCount = 0;

        // PING frame
        bool pingPacked = false;
        if (pingQueued && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
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

        if (hasCrypto && availCrypto > 0 && plainLen < plaintext.length
                && frameCount < MAX_FRAMES_PER_PACKET)
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
        sentFrames.recordPacket(PacketNumberSpace.handshake, pn, sentFramesList[0 .. frameCount]);
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
        if (pingQueued && plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET)
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
        while (plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET
                && streams.pollControlFrame(ctrlFrame))
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
        while (plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET
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
        if (handshakeDoneQueued && plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET)
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
        if (hasPendingPathResponse && plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET)
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
        if (hasPendingPathChallenge && plainLen < availPlain && frameCount < MAX_FRAMES_PER_PACKET)
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
        if (hasCrypto && availCrypto > 0 && plainLen < availPlain
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
        if (hasStream && lossDetector.cc.canSend && plainLen < availPlain
                && frameCount < MAX_FRAMES_PER_PACKET)
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
        const ulong rawRtt = (lossDetector.rtt.smoothedRtt > 0) ? lossDetector.rtt.smoothedRtt
            : 100_000;
        const ulong clampedRtt = (rawRtt > ulong.max / 6) ? (ulong.max / 6) : rawRtt;
        const ulong drainDur = 3 * clampedRtt;
        drainingEndTimeMicros = (ulong.max - nowMicros < drainDur) ? ulong.max
            : (nowMicros + drainDur);

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

    bool initiateKeyUpdate() @trusted @nogc nothrow
    {
        if (!hasWriteKeys[3] || appSecretLen == 0)
            return false;

        ubyte[48] nextLocalSec;
        deriveNextApplicationSecret(tls.negotiatedCipher,
                localAppSecret[0 .. appSecretLen], nextLocalSec[0 .. appSecretLen]);
        KeyMaterial nextKm;
        deriveKeyMaterial(tls.negotiatedCipher, nextLocalSec[0 .. appSecretLen], nextKm);

        levelKeys[3].local.aead.init(tls.negotiatedCipher,
                nextKm.key[0 .. nextKm.keyLen], nextKm.iv[0 .. 12]);
        localAppSecret[0 .. appSecretLen] = nextLocalSec[0 .. appSecretLen];
        localKeyPhase ^= 1;

        OPENSSL_cleanse(nextLocalSec.ptr, nextLocalSec.length);
        OPENSSL_cleanse(nextKm.key.ptr, nextKm.key.length);
        OPENSSL_cleanse(nextKm.iv.ptr, nextKm.iv.length);
        OPENSSL_cleanse(nextKm.hp.ptr, nextKm.hp.length);
        return true;
    }
}

// Spec: RFC 9000 Section 10 & RFC 9001 Section 4.9 - Path challenge and closing state transitions
/// Example:
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
