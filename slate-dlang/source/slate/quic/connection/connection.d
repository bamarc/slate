module slate.quic.connection.connection;

/**
 * QUIC Connection State Machine (RFC 9000 & RFC 9001).
 *
 * Implements a deterministic, Sans-I/O QUIC Connection supporting Server and Client
 * roles, coalesced packet ingestion and packing, anti-amplification budget enforcement,
 * automatic CRYPTO and STREAM frame loss retransmission, path validation, 1-RTT key updates,
 * and graceful connection teardown.
 */

import slate.quic.crypto.kdf : Side, CipherSuite, EncryptionLevel, QuicCryptoError,
    deriveInitialSecret, deriveClientInitialSecret, deriveServerInitialSecret,
    deriveKeyMaterial, KeyMaterial, hashLength, deriveNextApplicationSecret;
import slate.quic.crypto.aead : AeadKey, verifyRetryIntegrityTag;
import slate.quic.crypto.packet_keys : DirectionalKeys, Keys, KeyPhaseUpdater,
    protectPacket, unprotectPacket, unprotectPacketWithAead;
import slate.quic.crypto.tls_session : TlsContext, TlsSession;

import slate.quic.wire.varint : VARINT_MAX, WireError;
import slate.quic.wire.cid : ConnectionId, TransportErrorCode;
import slate.quic.wire.packet : PacketType, PacketPrefix, DecodedPacketHeader,
    CoalescedPacketIterator, parsePacketPrefix, completeHeaderAfterUnprotect,
    encodeLongHeader, encodeShortHeader, QUIC_VERSION_1;
import slate.quic.wire.frame : Frame, FrameType, FrameIterator, AckRange, AckFrame,
    StreamFrame, CryptoFrame, ConnectionCloseFrame, PathChallengeFrame, PathResponseFrame,
    HandshakeDoneFrame, ResetStreamFrame, StopSendingFrame, MaxDataFrame, MaxStreamDataFrame,
    MaxStreamsFrame, encodeFrame, decodeFrame, validateFrameInPacket;
import slate.quic.wire.transport_params : TransportParameters, encodeTransportParams,
    decodeTransportParams;

import slate.quic.stream.id : StreamId, StreamDirection, SendStreamState;
import slate.quic.stream.recv_buffer : RecvBuffer;
import slate.quic.stream.send_buffer : SendBuffer, TransmitChunk;
import slate.quic.stream.stream_map : StreamMap, QuicStream;

import slate.quic.recovery.ack_ranges : AckRangeSet;
import slate.quic.recovery.loss_detection : LossDetector, PacketNumberSpace, SentPacketInfo, NUM_SPACES;

import slate.quic.connection.events : ConnectionEventType, ConnectionEvent, ConnectionEventQueue;
import slate.quic.connection.sent_frames : SentFrameKind, SentFrameDesc, SentPacketRecord,
    SentFrameTracker, MAX_FRAMES_PER_PACKET;

public enum ConnectionState : ubyte
{
    handshaking,
    active,
    closing,
    draining,
    closed
}

public enum size_t MIN_INITIAL_DATAGRAM_LEN = 1200;

/**
 * Sans-I/O QUIC Connection state machine.
 */
public struct QuicConnection
{
    @disable this(this);

    Side localSide;
    ConnectionState state = ConnectionState.closed;

    ConnectionId localCid;
    ConnectionId remoteCid;
    ConnectionId initialDcid;

    TransportParameters localParams;
    TransportParameters peerParams;
    bool peerParamsReceived = false;

    TlsSession tls;

    // Keys indexed by EncryptionLevel: [0: initial, 1: earlyData, 2: handshake, 3: oneRtt]
    Keys[4] levelKeys;
    bool[4] hasReadKeys = [false, false, false, false];
    bool[4] hasWriteKeys = [false, false, false, false];

    KeyPhaseUpdater keyUpdater;
    bool keyUpdaterInitialized = false;

    ubyte[48] localAppSecret;
    ubyte[48] remoteAppSecret;
    size_t appSecretLen = 0;
    ubyte localKeyPhase = 0;
    ubyte remoteKeyPhase = 0;

    bool retryReceived = false;
    ConnectionId retryScid;

    // Buffers indexed by PacketNumberSpace: [0: initial, 1: handshake, 2: applicationData]
    RecvBuffer[3] cryptoRecv;
    SendBuffer[3] cryptoSend;

    StreamMap streams;
    AckRangeSet[3] ackRanges;
    LossDetector lossDetector;
    SentFrameTracker sentFrames;
    ConnectionEventQueue events;

    ulong[3] nextPn = [0, 0, 0];

    // Anti-amplification and address validation (RFC 9000 Section 8.1 & Section 14.1)
    bool peerAddressValidated = false;
    ulong totalBytesReceived = 0;
    ulong totalBytesSent = 0;

    // Handshake and control flags
    bool handshakeConfirmed = false;
    bool handshakeDoneQueued = false;
    bool handshakeDoneInFlight = false;
    bool handshakeDoneAcked = false;

    bool hasPendingPathResponse = false;
    ubyte[8] pendingPathResponseData;

    bool hasPendingPathChallenge = false;
    ubyte[8] pendingPathChallengeData;

    bool pingQueued = false;

    ulong closeErrorCode = 0;
    ulong closeFrameType = 0;
    bool closeIsApp = false;
    bool closePacketSent = false;

    ulong lastRxTimeMicros = 0;
    ulong drainingEndTimeMicros = 0;

    ubyte[128] retryTokenBuf;
    size_t retryTokenLen = 0;

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        tls.cleanup();
        foreach (ref k; levelKeys)
            k.cleanup();
        keyUpdater.cleanup();

        foreach (i; 0 .. 4)
        {
            hasReadKeys[i] = false;
            hasWriteKeys[i] = false;
        }
        foreach (s; 0 .. 3)
        {
            cryptoRecv[s].cleanup();
            cryptoSend[s].cleanup();
            ackRanges[s].clear();
        }
        streams.cleanup();
        lossDetector.cleanup();
        sentFrames.cleanup();
        events.cleanup();
        appSecretLen = 0;
        state = ConnectionState.closed;
    }

    void moveFrom(ref QuicConnection other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        this.localSide = other.localSide;
        this.state = other.state;
        this.localCid = other.localCid;
        this.remoteCid = other.remoteCid;
        this.initialDcid = other.initialDcid;
        this.localParams = other.localParams;
        this.peerParams = other.peerParams;
        this.peerParamsReceived = other.peerParamsReceived;

        this.tls.moveFrom(other.tls);

        foreach (i; 0 .. 4)
        {
            this.levelKeys[i].moveFrom(other.levelKeys[i]);
            this.hasReadKeys[i] = other.hasReadKeys[i];
            this.hasWriteKeys[i] = other.hasWriteKeys[i];
            other.hasReadKeys[i] = false;
            other.hasWriteKeys[i] = false;
        }

        this.keyUpdater.moveFrom(other.keyUpdater);
        this.keyUpdaterInitialized = other.keyUpdaterInitialized;
        other.keyUpdaterInitialized = false;

        this.localAppSecret = other.localAppSecret;
        this.remoteAppSecret = other.remoteAppSecret;
        this.appSecretLen = other.appSecretLen;
        this.localKeyPhase = other.localKeyPhase;
        this.remoteKeyPhase = other.remoteKeyPhase;
        this.retryReceived = other.retryReceived;
        this.retryScid = other.retryScid;

        foreach (s; 0 .. 3)
        {
            this.cryptoRecv[s].moveFrom(other.cryptoRecv[s]);
            this.cryptoSend[s].moveFrom(other.cryptoSend[s]);
            this.ackRanges[s].moveFrom(other.ackRanges[s]);
            this.nextPn[s] = other.nextPn[s];
            other.nextPn[s] = 0;
        }

        this.streams.moveFrom(other.streams);
        this.lossDetector.moveFrom(other.lossDetector);
        this.sentFrames.moveFrom(other.sentFrames);
        this.events.moveFrom(other.events);

        this.peerAddressValidated = other.peerAddressValidated;
        this.totalBytesReceived = other.totalBytesReceived;
        this.totalBytesSent = other.totalBytesSent;

        this.handshakeConfirmed = other.handshakeConfirmed;
        this.handshakeDoneQueued = other.handshakeDoneQueued;
        this.handshakeDoneInFlight = other.handshakeDoneInFlight;
        this.handshakeDoneAcked = other.handshakeDoneAcked;

        this.hasPendingPathResponse = other.hasPendingPathResponse;
        this.pendingPathResponseData = other.pendingPathResponseData;
        this.hasPendingPathChallenge = other.hasPendingPathChallenge;
        this.pendingPathChallengeData = other.pendingPathChallengeData;
        this.pingQueued = other.pingQueued;

        this.closeErrorCode = other.closeErrorCode;
        this.closeFrameType = other.closeFrameType;
        this.closeIsApp = other.closeIsApp;
        this.closePacketSent = other.closePacketSent;

        this.lastRxTimeMicros = other.lastRxTimeMicros;
        this.drainingEndTimeMicros = other.drainingEndTimeMicros;

        this.retryTokenBuf = other.retryTokenBuf;
        this.retryTokenLen = other.retryTokenLen;
        other.retryTokenLen = 0;

        other.state = ConnectionState.closed;
    }

    /**
     * 3x Anti-Amplification budget calculation (RFC 9000 Section 8.1).
     */
    size_t amplificationBudget() const @safe pure @nogc nothrow
    {
        if (peerAddressValidated)
            return size_t.max;

        const ulong maxAllowed = (totalBytesReceived > ulong.max / 3) ? ulong.max : (3 * totalBytesReceived);
        if (maxAllowed > totalBytesSent)
        {
            const ulong avail = maxAllowed - totalBytesSent;
            return (avail > size_t.max) ? size_t.max : cast(size_t) avail;
        }
        return 0;
    }

    /**
     * Factory function initializing a Client or Server QuicConnection.
     */
    static bool create(
        Side side,
        ref TlsContext tlsCtx,
        ConnectionId localCid,
        ConnectionId remoteCid,
        ref const TransportParameters localParams,
        ulong nowMicros,
        out QuicConnection conn,
        bool addressValidated = false,
        const(ubyte)[] retryToken = null
    ) @trusted @nogc nothrow
    {
        conn.cleanup();

        conn.localSide = side;
        conn.state = ConnectionState.handshaking;
        conn.localCid = localCid;
        conn.remoteCid = remoteCid;
        conn.initialDcid = (side == Side.client) ? remoteCid : localCid;
        conn.localParams = localParams;
        conn.peerAddressValidated = (side == Side.client) ? true : addressValidated;
        conn.lastRxTimeMicros = nowMicros;

        if (retryToken.length > 0 && retryToken.length <= conn.retryTokenBuf.length)
        {
            conn.retryTokenBuf[0 .. retryToken.length] = retryToken[];
            conn.retryTokenLen = retryToken.length;
        }

        // 1. Derive Initial Secrets and Keys
        ubyte[32] initSecret;
        deriveInitialSecret(conn.initialDcid.asSlice(), initSecret);

        ubyte[32] clientInitSec;
        deriveClientInitialSecret(initSecret, clientInitSec);
        KeyMaterial clientKm;
        deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, clientInitSec, clientKm);

        ubyte[32] serverInitSec;
        deriveServerInitialSecret(initSecret, serverInitSec);
        KeyMaterial serverKm;
        deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, serverInitSec, serverKm);

        if (side == Side.client)
        {
            conn.levelKeys[0].local.init(CipherSuite.TLS_AES_128_GCM_SHA256, clientKm.key[0 .. 16], clientKm.iv[0 .. 12], clientKm.hp[0 .. 16]);
            conn.levelKeys[0].remote.init(CipherSuite.TLS_AES_128_GCM_SHA256, serverKm.key[0 .. 16], serverKm.iv[0 .. 12], serverKm.hp[0 .. 16]);
        }
        else
        {
            conn.levelKeys[0].local.init(CipherSuite.TLS_AES_128_GCM_SHA256, serverKm.key[0 .. 16], serverKm.iv[0 .. 12], serverKm.hp[0 .. 16]);
            conn.levelKeys[0].remote.init(CipherSuite.TLS_AES_128_GCM_SHA256, clientKm.key[0 .. 16], clientKm.iv[0 .. 12], clientKm.hp[0 .. 16]);
        }
        conn.levelKeys[0].initialized = true;
        conn.hasReadKeys[0] = true;
        conn.hasWriteKeys[0] = true;

        // 2. Encode local TransportParameters and initialize TlsSession
        ubyte[512] tpBuf;
        size_t tpLen = 0;
        if (encodeTransportParams(localParams, side, tpBuf[], tpLen) != 0)
            return false;

        conn.tls.init(tlsCtx, side, tpBuf[0 .. tpLen]);

        // 3. Initialize StreamMap
        conn.streams = StreamMap(
            side,
            localParams.initialMaxData,
            localParams.initialMaxStreamDataBidiLocal,
            localParams.initialMaxStreamDataBidiRemote,
            localParams.initialMaxStreamDataUni,
            localParams.initialMaxStreamsBidi,
            localParams.initialMaxStreamsUni,
            localParams.initialMaxStreamsBidi,
            localParams.initialMaxStreamsUni
        );

        // 4. If Client, run initial step to produce ClientHello in cryptoSend[0]
        if (side == Side.client)
        {
            conn.tls.stepHandshake();
            ubyte[2048] chBuf;
            const chData = conn.tls.writeHandshake(EncryptionLevel.initial, chBuf);
            if (chData.length > 0)
            {
                conn.cryptoSend[0].write(chData, false);
            }
        }

        return true;
    }

    /**
     * Ingests an incoming UDP datagram containing one or more coalesced QUIC packets.
     */
    TransportErrorCode handleDatagram(const(ubyte)[] datagram, ulong nowMicros) @trusted @nogc nothrow
    {
        if (state == ConnectionState.draining || state == ConnectionState.closed)
            return TransportErrorCode.noError;

        // RFC 9000 Section 14.1 & F2: Server drops undersized initial datagrams (< 1200 bytes)
        if (localSide == Side.server && !peerAddressValidated)
        {
            if (datagram.length < MIN_INITIAL_DATAGRAM_LEN)
            {
                return TransportErrorCode.noError; // Silently drop
            }
        }

        totalBytesReceived += datagram.length;
        lastRxTimeMicros = nowMicros;

        CoalescedPacketIterator splitter = CoalescedPacketIterator(datagram, localCid.len);
        const(ubyte)[] pktSlice;
        PacketPrefix prefix;
        WireError splitErr = WireError.none;

        while (splitter.next(pktSlice, prefix, splitErr))
        {
            const te = processSinglePacket(pktSlice, prefix, nowMicros);
            if (te != TransportErrorCode.noError)
            {
                enterClosing(te, 0, false);
                return te;
            }
        }

        if (splitErr != WireError.none && splitErr != WireError.unexpectedEof)
        {
            enterClosing(TransportErrorCode.protocolViolation, 0, false);
            return TransportErrorCode.protocolViolation;
        }

        return TransportErrorCode.noError;
    }

    private TransportErrorCode processSinglePacket(
        const(ubyte)[] packetBytes,
        ref const PacketPrefix prefix,
        ulong nowMicros
    ) @trusted @nogc nothrow
    {
        size_t keyIdx = 0;
        PacketNumberSpace space = PacketNumberSpace.initial;

        switch (prefix.type)
        {
            case PacketType.initial:
                keyIdx = 0;
                space = PacketNumberSpace.initial;
                break;
            case PacketType.handshake:
                keyIdx = 2; // EncryptionLevel.handshake
                space = PacketNumberSpace.handshake;
                break;
            case PacketType.oneRttShort:
                keyIdx = 3; // EncryptionLevel.oneRtt
                space = PacketNumberSpace.applicationData;
                break;
            case PacketType.retry:
                return handleRetryPacket(prefix, packetBytes);
            case PacketType.versionNegotiation:
                return TransportErrorCode.noError;
            default:
                return TransportErrorCode.noError;
        }

        // If keys are discarded or not yet available, skip packet safely
        if (!hasReadKeys[keyIdx])
            return TransportErrorCode.noError;

        // Scratch buffer for in-place packet unprotection
        ubyte[4096] unprotBuf;
        if (packetBytes.length > unprotBuf.length)
            return TransportErrorCode.internalError;

        unprotBuf[0 .. packetBytes.length] = packetBytes[];

        size_t decPnLen = 0;
        ulong decPn = 0;
        size_t decPayOff = 0;
        size_t decPlainLen = 0;

        const ulong largestAcked = lossDetector.hasAckedPn[space] ? lossDetector.largestAckedPn[space] : 0;

        // Unprotect packet header and payload
        QuicCryptoError cryptoErr = unprotectPacket(
            levelKeys[keyIdx].remote,
            prefix.pnOffset,
            largestAcked,
            unprotBuf[0 .. packetBytes.length],
            decPnLen,
            decPn,
            decPayOff,
            decPlainLen
        );

        if (cryptoErr != QuicCryptoError.none)
        {
            // If 1-RTT short header and AEAD tag mismatch, check for 1-RTT Key Phase update (RFC 9001 §6)
            if (prefix.type == PacketType.oneRttShort && appSecretLen > 0 && cryptoErr == QuicCryptoError.aeadTagMismatch)
            {
                ubyte[48] nextRemoteSec;
                deriveNextApplicationSecret(tls.negotiatedCipher, remoteAppSecret[0 .. appSecretLen], nextRemoteSec[0 .. appSecretLen]);
                KeyMaterial nextKm;
                deriveKeyMaterial(tls.negotiatedCipher, nextRemoteSec[0 .. appSecretLen], nextKm);
                AeadKey tempAead;
                tempAead.init(tls.negotiatedCipher, nextKm.key[0 .. nextKm.keyLen], nextKm.iv[0 .. 12]);

                unprotBuf[0 .. packetBytes.length] = packetBytes[];
                cryptoErr = unprotectPacketWithAead(
                    levelKeys[3].remote.hp,
                    tempAead,
                    prefix.pnOffset,
                    largestAcked,
                    unprotBuf[0 .. packetBytes.length],
                    decPnLen,
                    decPn,
                    decPayOff,
                    decPlainLen
                );

                if (cryptoErr == QuicCryptoError.none)
                {
                    const ubyte pktPhase = (unprotBuf[0] & 0x04) != 0 ? 1 : 0;
                    if (pktPhase != remoteKeyPhase)
                    {
                        // Commit rotated remote keys
                        remoteAppSecret[0 .. appSecretLen] = nextRemoteSec[0 .. appSecretLen];
                        levelKeys[3].remote.aead.moveFrom(tempAead);
                        remoteKeyPhase ^= 1;

                        // RFC 9001 §6.2: If peer initiated the key update, receiver must also update its write keys
                        if (localKeyPhase != remoteKeyPhase)
                        {
                            ubyte[48] nextLocalSec;
                            deriveNextApplicationSecret(tls.negotiatedCipher, localAppSecret[0 .. appSecretLen], nextLocalSec[0 .. appSecretLen]);
                            KeyMaterial nextLocalKm;
                            deriveKeyMaterial(tls.negotiatedCipher, nextLocalSec[0 .. appSecretLen], nextLocalKm);
                            levelKeys[3].local.aead.init(tls.negotiatedCipher, nextLocalKm.key[0 .. nextLocalKm.keyLen], nextLocalKm.iv[0 .. 12]);
                            localAppSecret[0 .. appSecretLen] = nextLocalSec[0 .. appSecretLen];
                            localKeyPhase = remoteKeyPhase;
                        }
                    }
                    else
                    {
                        cryptoErr = QuicCryptoError.aeadTagMismatch;
                    }
                }
            }

            if (cryptoErr != QuicCryptoError.none)
                return TransportErrorCode.noError; // Silently drop corrupted/unauthenticated packet
        }

        DecodedPacketHeader hdr;
        TransportErrorCode te = TransportErrorCode.noError;
        const completeErr = completeHeaderAfterUnprotect(
            unprotBuf[0 .. decPayOff + decPlainLen],
            prefix,
            largestAcked,
            hdr,
            te
        );
        if (completeErr != 0 || te != TransportErrorCode.noError)
            return te != TransportErrorCode.noError ? te : TransportErrorCode.protocolViolation;

        // Server updates remoteCid from first Client Initial
        if (localSide == Side.server && prefix.type == PacketType.initial && remoteCid.len == 0)
        {
            remoteCid = hdr.scid;
        }

        // Server address validation and key discard on Handshake packet (RFC 9001 §4.9.1 & F4)
        if (localSide == Side.server && prefix.type == PacketType.handshake)
        {
            peerAddressValidated = true;
            if (hasReadKeys[0] || hasWriteKeys[0])
            {
                discardSpace(PacketNumberSpace.initial);
            }
        }

        // Server confirms handshake upon receiving any 1-RTT packet from client (RFC 9001 §4.1.2)
        if (localSide == Side.server && prefix.type == PacketType.oneRttShort)
        {
            if (!handshakeConfirmed)
            {
                handshakeConfirmed = true;
                events.push(ConnectionEvent(ConnectionEventType.handshakeConfirmed, 0, 0, false));
            }
        }

        // Decode frames from decrypted plaintext
        const(ubyte)[] plaintext = unprotBuf[decPayOff .. decPayOff + decPlainLen];
        FrameIterator fIter = FrameIterator(plaintext, prefix.type);
        Frame frame;
        WireError wireErr = WireError.none;
        bool isAckEliciting = false;

        while (fIter.next(frame, wireErr, te))
        {
            if (frame.type != FrameType.ack && frame.type != FrameType.padding && frame.type != FrameType.connectionCloseQuic && frame.type != FrameType.connectionCloseApp)
            {
                isAckEliciting = true;
            }

            const frameTe = dispatchFrame(space, frame, nowMicros);
            if (frameTe != TransportErrorCode.noError)
                return frameTe;
        }

        if (wireErr != WireError.none)
        {
            return (te != TransportErrorCode.noError) ? te : TransportErrorCode.protocolViolation;
        }

        // Record received packet number in ACK ranges
        ackRanges[space].insert(hdr.packetNumber, isAckEliciting, nowMicros);

        return TransportErrorCode.noError;
    }

    private TransportErrorCode handleRetryPacket(ref const PacketPrefix prefix, const(ubyte)[] packetBytes) @trusted @nogc nothrow
    {
        if (localSide != Side.client || prefix.token.length == 0)
            return TransportErrorCode.noError;

        // RFC 9001 §5.8: Validate Retry Integrity Tag using original destination connection ID
        if (!verifyRetryIntegrityTag(initialDcid.asSlice(), packetBytes))
            return TransportErrorCode.noError;

        // Client saves Retry token and updates remote connection ID to Retry SCID
        if (prefix.token.length <= retryTokenBuf.length)
        {
            retryTokenBuf[0 .. prefix.token.length] = prefix.token[];
            retryTokenLen = prefix.token.length;
            remoteCid = prefix.scid;
            retryReceived = true;
            retryScid = prefix.scid;

            // RFC 9001 §5.2: Re-derive Initial secrets based on new Destination Connection ID (Retry SCID)
            ubyte[32] initSecret;
            deriveInitialSecret(remoteCid.asSlice(), initSecret);

            ubyte[32] clientInitSec;
            deriveClientInitialSecret(initSecret, clientInitSec);
            KeyMaterial clientKm;
            deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, clientInitSec, clientKm);

            ubyte[32] serverInitSec;
            deriveServerInitialSecret(initSecret, serverInitSec);
            KeyMaterial serverKm;
            deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, serverInitSec, serverKm);

            levelKeys[0].local.init(CipherSuite.TLS_AES_128_GCM_SHA256, clientKm.key[0 .. 16], clientKm.iv[0 .. 12], clientKm.hp[0 .. 16]);
            levelKeys[0].remote.init(CipherSuite.TLS_AES_128_GCM_SHA256, serverKm.key[0 .. 16], serverKm.iv[0 .. 12], serverKm.hp[0 .. 16]);

            // Mark cryptoSend[0] for retransmission from offset 0
            cryptoSend[0].onRangeLost(0, cryptoSend[0].writeOffset, false);
        }

        return TransportErrorCode.noError;
    }

    private TransportErrorCode dispatchFrame(PacketNumberSpace space, ref const Frame frame, ulong nowMicros) @trusted @nogc nothrow
    {
        switch (frame.type)
        {
            case FrameType.padding:
                return TransportErrorCode.noError;

            case FrameType.ping:
                return TransportErrorCode.noError;

            case FrameType.ack:
            case FrameType.ackEcn:
                return processAckFrame(space, frame.ack, nowMicros);

            case FrameType.crypto:
                return processCryptoFrame(space, frame.crypto, nowMicros);

            case FrameType.stream:
                return processStreamFrame(frame.stream);

            case FrameType.resetStream:
                const rErr = streams.onResetStreamFrame(frame.resetStream);
                if (rErr != TransportErrorCode.noError) return rErr;
                events.push(ConnectionEvent(ConnectionEventType.streamReset, frame.resetStream.streamId, frame.resetStream.applicationErrorCode, false));
                return TransportErrorCode.noError;

            case FrameType.stopSending:
                const sErr = streams.onStopSendingFrame(frame.stopSending);
                if (sErr != TransportErrorCode.noError) return sErr;
                events.push(ConnectionEvent(ConnectionEventType.stopSending, frame.stopSending.streamId, frame.stopSending.applicationErrorCode, false));
                return TransportErrorCode.noError;

            case FrameType.maxData:
                const mdErr = streams.onMaxDataFrame(frame.maxData);
                if (mdErr != TransportErrorCode.noError) return mdErr;
                events.push(ConnectionEvent(ConnectionEventType.streamWritable, 0, 0, false));
                return TransportErrorCode.noError;

            case FrameType.maxStreamData:
                const msdErr = streams.onMaxStreamDataFrame(frame.maxStreamData);
                if (msdErr != TransportErrorCode.noError) return msdErr;
                events.push(ConnectionEvent(ConnectionEventType.streamWritable, frame.maxStreamData.streamId, 0, false));
                return TransportErrorCode.noError;

            case FrameType.maxStreamsBidi:
            case FrameType.maxStreamsUni:
                const msErr = streams.onMaxStreamsFrame(frame.maxStreams);
                if (msErr != TransportErrorCode.noError) return msErr;
                return TransportErrorCode.noError;

            case FrameType.pathChallenge:
                hasPendingPathResponse = true;
                pendingPathResponseData = frame.pathChallenge.data;
                return TransportErrorCode.noError;

            case FrameType.pathResponse:
                if (hasPendingPathChallenge && frame.pathResponse.data == pendingPathChallengeData)
                {
                    hasPendingPathChallenge = false;
                }
                return TransportErrorCode.noError;

            case FrameType.handshakeDone:
                if (localSide == Side.server)
                    return TransportErrorCode.protocolViolation; // Server must not receive HANDSHAKE_DONE

                handshakeConfirmed = true;
                discardSpace(PacketNumberSpace.handshake);
                events.push(ConnectionEvent(ConnectionEventType.handshakeConfirmed, 0, 0, false));
                return TransportErrorCode.noError;

            case FrameType.connectionCloseQuic:
            case FrameType.connectionCloseApp:
                state = ConnectionState.draining;
                closeErrorCode = frame.connectionClose.errorCode;
                closeFrameType = frame.connectionClose.frameType;
                closeIsApp = frame.connectionClose.isApplication;
                const ulong rttVal = (lossDetector.rtt.smoothedRtt > 0) ? lossDetector.rtt.smoothedRtt : 100_000;
                drainingEndTimeMicros = nowMicros + 3 * rttVal;
                events.push(ConnectionEvent(ConnectionEventType.connectionClosed, 0, closeErrorCode, closeIsApp));
                return TransportErrorCode.noError;

            default:
                return TransportErrorCode.noError;
        }
    }

    private TransportErrorCode processAckFrame(
        PacketNumberSpace space,
        ref const AckFrame ack,
        ulong nowMicros
    ) @trusted @nogc nothrow
    {
        SentPacketInfo[128] newlyAcked;
        size_t ackedCount = 0;
        SentPacketInfo[128] newlyLost;
        size_t lostCount = 0;

        const te = lossDetector.onAckReceived(
            space,
            ack,
            3,
            localParams.maxAckDelay * 1000,
            handshakeConfirmed,
            nowMicros,
            newlyAcked[],
            ackedCount,
            newlyLost[],
            lostCount
        );

        if (te != TransportErrorCode.noError)
            return te;

        // Process newly acknowledged packets
        foreach (i; 0 .. ackedCount)
        {
            SentPacketRecord rec;
            if (sentFrames.takePacket(space, newlyAcked[i].pn, rec))
            {
                foreach (f; 0 .. rec.frameCount)
                {
                    const desc = rec.frames[f];
                    if (desc.kind == SentFrameKind.crypto)
                    {
                        cryptoSend[space].onRangeAcked(desc.offset, desc.length, desc.fin);
                    }
                    else if (desc.kind == SentFrameKind.stream)
                    {
                        QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                        if (qs !is null)
                        {
                            qs.sendBuf.onRangeAcked(desc.offset, desc.length, desc.fin);
                            if (qs.sendBuf.isAllAcked)
                            {
                                events.push(ConnectionEvent(ConnectionEventType.streamFinished, desc.streamId, 0, false));
                            }
                        }
                    }
                    else if (desc.kind == SentFrameKind.handshakeDone)
                    {
                        handshakeDoneAcked = true;
                        handshakeDoneInFlight = false;
                        if (localSide == Side.server)
                        {
                            if (!handshakeConfirmed)
                            {
                                handshakeConfirmed = true;
                                events.push(ConnectionEvent(ConnectionEventType.handshakeConfirmed, 0, 0, false));
                            }
                            discardSpace(PacketNumberSpace.handshake);
                        }
                    }
                }
            }
        }

        // Process newly lost packets
        foreach (i; 0 .. lostCount)
        {
            SentPacketRecord rec;
            if (sentFrames.takePacket(space, newlyLost[i].pn, rec))
            {
                foreach (f; 0 .. rec.frameCount)
                {
                    const desc = rec.frames[f];
                    if (desc.kind == SentFrameKind.crypto)
                    {
                        cryptoSend[space].onRangeLost(desc.offset, desc.length, desc.fin);
                    }
                    else if (desc.kind == SentFrameKind.stream)
                    {
                        QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                        if (qs !is null)
                        {
                            qs.sendBuf.onRangeLost(desc.offset, desc.length, desc.fin);
                        }
                    }
                    else if (desc.kind == SentFrameKind.handshakeDone)
                    {
                        handshakeDoneQueued = true;
                        handshakeDoneInFlight = false;
                    }
                }
            }
        }

        return TransportErrorCode.noError;
    }

    private TransportErrorCode processCryptoFrame(
        PacketNumberSpace space,
        ref const CryptoFrame crypto,
        ulong nowMicros
    ) @trusted @nogc nothrow
    {
        const ingErr = cryptoRecv[space].ingest(crypto.offset, crypto.data, false);
        if (ingErr != TransportErrorCode.noError)
            return ingErr;

        EncryptionLevel tlsLevel = EncryptionLevel.initial;
        if (space == PacketNumberSpace.handshake)
            tlsLevel = EncryptionLevel.handshake;
        else if (space == PacketNumberSpace.applicationData)
            tlsLevel = EncryptionLevel.oneRtt;

        // Drain contiguous bytes into TLS
        while (cryptoRecv[space].readableBytes() > 0)
        {
            ubyte[2048] cBuf;
            bool fin = false;
            const size_t n = cryptoRecv[space].read(cBuf[], fin);
            if (n > 0)
            {
                const cErr = tls.readHandshake(tlsLevel, cBuf[0 .. n]);
                if (tls.hasAlert)
                    return cast(TransportErrorCode) tls.quicErrorCode;
                if (cErr != QuicCryptoError.none)
                    return TransportErrorCode.protocolViolation;
            }
        }

        drainTls();

        // Check peer transport parameters
        if (!peerParamsReceived && tls.peerTransportParams.length > 0)
        {
            TransportErrorCode te = TransportErrorCode.noError;
            const Side peerSide = (localSide == Side.client) ? Side.server : Side.client;
            const wErr = decodeTransportParams(tls.peerTransportParams, peerSide, peerParams, te);
            if (wErr != WireError.none)
            {
                return (te != TransportErrorCode.noError) ? te : TransportErrorCode.transportParameterError;
            }

            // RFC 9000 §7.3 CID authentication
            if (peerParams.hasInitialSourceConnectionId && peerParams.initialSourceConnectionId != remoteCid)
            {
                return TransportErrorCode.transportParameterError;
            }
            if (localSide == Side.client && peerParams.hasOriginalDestinationConnectionId && peerParams.originalDestinationConnectionId != initialDcid)
            {
                return TransportErrorCode.transportParameterError;
            }
            if (retryReceived && peerParams.hasRetrySourceConnectionId && peerParams.retrySourceConnectionId != retryScid)
            {
                return TransportErrorCode.transportParameterError;
            }

            peerParamsReceived = true;
            streams.applyPeerTransportParams(peerParams);
        }

        // If TLS completed
        if (tls.isHandshakeComplete)
        {
            if (state == ConnectionState.handshaking)
            {
                state = ConnectionState.active;
            }
            if (localSide == Side.server && !handshakeDoneQueued && !handshakeDoneAcked)
            {
                handshakeDoneQueued = true;
            }
        }

        return TransportErrorCode.noError;
    }

    private TransportErrorCode processStreamFrame(ref const StreamFrame sf) @trusted @nogc nothrow
    {
        const te = streams.onStreamFrame(sf);
        if (te != TransportErrorCode.noError)
            return te;

        events.push(ConnectionEvent(ConnectionEventType.streamReadable, sf.streamId, 0, false));
        if (sf.fin)
        {
            events.push(ConnectionEvent(ConnectionEventType.streamFinished, sf.streamId, 0, false));
        }

        return TransportErrorCode.noError;
    }

    private void drainTls() @trusted @nogc nothrow
    {
        pollTlsKeys();
        pollTlsOutputs();
        pollTlsKeys();
    }

    private void pollTlsKeys() @trusted @nogc nothrow
    {
        TlsSession.LevelKeys polled;
        while (tls.pollNextKeys(polled))
        {
            if (polled.level == EncryptionLevel.handshake)
            {
                levelKeys[2].local.moveFrom(polled.writeKeys);
                levelKeys[2].remote.moveFrom(polled.readKeys);
                levelKeys[2].initialized = true;
                hasReadKeys[2] = true;
                hasWriteKeys[2] = true;
            }
            else if (polled.level == EncryptionLevel.oneRtt)
            {
                levelKeys[3].local.moveFrom(polled.writeKeys);
                levelKeys[3].remote.moveFrom(polled.readKeys);
                levelKeys[3].initialized = true;
                hasReadKeys[3] = true;
                hasWriteKeys[3] = true;

                // Initialize 1-RTT application traffic secrets
                const rSec = tls.appReadSecret();
                const wSec = tls.appWriteSecret();
                if (rSec.length > 0 && wSec.length > 0)
                {
                    appSecretLen = rSec.length;
                    remoteAppSecret[0 .. appSecretLen] = rSec[];
                    localAppSecret[0 .. appSecretLen] = wSec[];
                    localKeyPhase = 0;
                    remoteKeyPhase = 0;
                    keyUpdaterInitialized = true;
                }
            }
        }
    }

    private void pollTlsOutputs() @trusted @nogc nothrow
    {
        ubyte[2048] outBuf;

        const initOut = tls.writeHandshake(EncryptionLevel.initial, outBuf[]);
        if (initOut.length > 0)
        {
            cryptoSend[0].write(initOut, false);
        }

        const hsOut = tls.writeHandshake(EncryptionLevel.handshake, outBuf[]);
        if (hsOut.length > 0)
        {
            cryptoSend[1].write(hsOut, false);
        }

        const appOut = tls.writeHandshake(EncryptionLevel.oneRtt, outBuf[]);
        if (appOut.length > 0)
        {
            cryptoSend[2].write(appOut, false);
        }
    }

    /**
     * Packs pending outgoing frames into coalesced packets within outDatagram.
     */
    bool pollTransmit(ubyte[] outDatagram, ulong nowMicros, out size_t bytesWritten) @trusted @nogc nothrow
    {
        bytesWritten = 0;
        if (outDatagram.length == 0 || state == ConnectionState.draining || state == ConnectionState.closed)
            return false;

        drainTls();

        // Closing state: emit CONNECTION_CLOSE packet once and transition to draining
        if (state == ConnectionState.closing && !closePacketSent)
        {
            const size_t closeBudget = amplificationBudget();
            if (closeBudget == 0)
                return false;
            const size_t maxCloseAllowed = (closeBudget < outDatagram.length) ? closeBudget : outDatagram.length;
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
        if (pingQueued && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.ping;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
            {
                plainLen += wr;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
                pingQueued = false;
            }
        }

        // ACK frame
        if (hasAck && plainLen < plaintext.length)
        {
            AckFrame ack;
            if (ackRanges[0].buildAckFrame(nowMicros, 3, ack))
            {
                Frame f;
                f.type = FrameType.ack;
                f.ack = ack;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
                {
                    plainLen += wr;
                }
            }
        }

        // CRYPTO frame
        const size_t estimatedHdrLen = 1 + 4 + (1 + remoteCid.len) + (1 + localCid.len) + (localSide == Side.client && retryTokenLen > 0 ? 2 + retryTokenLen : 1) + 2;
        const size_t maxPlain = (outBuf.length > estimatedHdrLen + 16) ? (outBuf.length - estimatedHdrLen - 16) : 0;
        const size_t availPlain = (maxPlain < plaintext.length) ? maxPlain : plaintext.length;
        const size_t availCrypto = (availPlain > plainLen + 16) ? (availPlain - plainLen - 16) : 0;

        if (hasCrypto && availCrypto > 0 && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
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
                    sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.crypto, 0, chunk.offset, cast(uint) chunk.data.length, chunk.fin);
                }
            }
        }

        if (plainLen == 0)
            return false;

        const ulong pn = nextPn[0];
        const size_t pnLen = 2;
        size_t pnOff = 0;
        size_t hdrLen = 0;

        const(ubyte)[] token = (localSide == Side.client && retryTokenLen > 0) ? retryTokenBuf[0 .. retryTokenLen] : null;

        // Encode header first with preliminary plainLen to determine exact headerLen
        if (encodeLongHeader(
            PacketType.initial,
            QUIC_VERSION_1,
            remoteCid,
            localCid,
            token,
            pn,
            pnLen,
            plainLen,
            outBuf,
            pnOff,
            hdrLen
        ) != 0)
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
                if (encodeLongHeader(
                    PacketType.initial,
                    QUIC_VERSION_1,
                    remoteCid,
                    localCid,
                    token,
                    pn,
                    pnLen,
                    plainLen,
                    outBuf,
                    pnOff,
                    hdrLen
                ) != 0)
                    return false;
            }
        }

        if (outBuf.length < hdrLen + plainLen + 16)
            return false;

        outBuf[hdrLen .. hdrLen + plainLen] = plaintext[0 .. plainLen];

        size_t protLen = 0;
        if (protectPacket(levelKeys[0].local, pn, pnOff, pnLen, outBuf, plainLen, protLen) != QuicCryptoError.none)
            return false;

        nextPn[0]++;
        sentFrames.recordPacket(PacketNumberSpace.initial, pn, sentFramesList[0 .. frameCount]);
        lossDetector.onPacketSent(PacketNumberSpace.initial, pn, cast(uint) protLen, frameCount > 0, true, nowMicros);

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
        if (pingQueued && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.ping;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
            {
                plainLen += wr;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
                pingQueued = false;
            }
        }

        // ACK frame
        if (hasAck && plainLen < plaintext.length)
        {
            AckFrame ack;
            if (ackRanges[1].buildAckFrame(nowMicros, 3, ack))
            {
                Frame f;
                f.type = FrameType.ack;
                f.ack = ack;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
                {
                    plainLen += wr;
                }
            }
        }

        // CRYPTO frame
        const size_t maxPlain = (outBuf.length > 64) ? (outBuf.length - 64) : 0;
        const size_t availPlain = (maxPlain < plaintext.length) ? maxPlain : plaintext.length;
        const size_t availCrypto = (availPlain > plainLen + 16) ? (availPlain - plainLen - 16) : 0;

        if (hasCrypto && availCrypto > 0 && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
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
                    sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.crypto, 0, chunk.offset, cast(uint) chunk.data.length, chunk.fin);
                }
            }
        }

        if (plainLen == 0)
            return false;

        const ulong pn = nextPn[1];
        const size_t pnLen = 2;
        size_t pnOff = 0;
        size_t hdrLen = 0;

        if (encodeLongHeader(
            PacketType.handshake,
            QUIC_VERSION_1,
            remoteCid,
            localCid,
            null,
            pn,
            pnLen,
            plainLen,
            outBuf,
            pnOff,
            hdrLen
        ) != 0)
            return false;

        if (outBuf.length < hdrLen + plainLen + 16)
            return false;

        outBuf[hdrLen .. hdrLen + plainLen] = plaintext[0 .. plainLen];

        size_t protLen = 0;
        if (protectPacket(levelKeys[2].local, pn, pnOff, pnLen, outBuf, plainLen, protLen) != QuicCryptoError.none)
            return false;

        nextPn[1]++;
        sentFrames.recordPacket(PacketNumberSpace.handshake, pn, sentFramesList[0 .. frameCount]);
        lossDetector.onPacketSent(PacketNumberSpace.handshake, pn, cast(uint) protLen, frameCount > 0, true, nowMicros);

        pktLen = protLen;
        return true;
    }

    private bool packOneRttPacket(ubyte[] outBuf, ulong nowMicros, out size_t pktLen) @trusted @nogc nothrow
    {
        pktLen = 0;
        const bool hasAck = ackRanges[2].hasPendingAck;
        const bool hasCrypto = cryptoSend[2].hasPendingBytes;
        const bool hasStream = streams.hasPendingWritable;

        if (!hasAck && !hasCrypto && !hasStream && !handshakeDoneQueued && !hasPendingPathResponse && !hasPendingPathChallenge && !pingQueued)
            return false;

        ubyte[4096] plaintext;
        size_t plainLen = 0;
        SentFrameDesc[MAX_FRAMES_PER_PACKET] sentFramesList;
        ubyte frameCount = 0;

        // PING frame
        if (pingQueued && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.ping;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
            {
                plainLen += wr;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
                pingQueued = false;
            }
        }

        // Pending control frames (RESET_STREAM or STOP_SENDING)
        Frame ctrlFrame;
        while (streams.pollControlFrame(ctrlFrame) && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            size_t wr = 0;
            if (encodeFrame(ctrlFrame, plaintext[plainLen .. $], wr) == 0)
            {
                plainLen += wr;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.stream, (ctrlFrame.type == FrameType.resetStream) ? ctrlFrame.resetStream.streamId : ctrlFrame.stopSending.streamId, 0, 0, false);
            }
        }

        // ACK frame
        if (hasAck && plainLen < plaintext.length)
        {
            AckFrame ack;
            if (ackRanges[2].buildAckFrame(nowMicros, 3, ack))
            {
                Frame f;
                f.type = FrameType.ack;
                f.ack = ack;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
                {
                    plainLen += wr;
                }
            }
        }

        // HANDSHAKE_DONE frame (Server only)
        if (handshakeDoneQueued && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.handshakeDone;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
            {
                plainLen += wr;
                handshakeDoneQueued = false;
                handshakeDoneInFlight = true;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.handshakeDone, 0, 0, 0, false);
            }
        }

        // PATH_RESPONSE frame
        if (hasPendingPathResponse && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.pathResponse;
            f.pathResponse.data = pendingPathResponseData;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
            {
                plainLen += wr;
                hasPendingPathResponse = false;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
            }
        }

        // PATH_CHALLENGE frame
        if (hasPendingPathChallenge && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            Frame f;
            f.type = FrameType.pathChallenge;
            f.pathChallenge.data = pendingPathChallengeData;
            size_t wr = 0;
            if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
            {
                plainLen += wr;
                sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);
            }
        }

        // CRYPTO frame (post-handshake 1-RTT)
        const size_t maxPlain = (outBuf.length > 64) ? (outBuf.length - 64) : 0;
        const size_t availPlain = (maxPlain < plaintext.length) ? maxPlain : plaintext.length;
        const size_t availCrypto = (availPlain > plainLen + 16) ? (availPlain - plainLen - 16) : 0;

        if (hasCrypto && availCrypto > 0 && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            TransmitChunk chunk;
            if (cryptoSend[2].pollTransmit(availCrypto, chunk))
            {
                Frame f;
                f.type = FrameType.crypto;
                f.crypto.offset = chunk.offset;
                f.crypto.data = chunk.data;
                size_t wr = 0;
                if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
                {
                    plainLen += wr;
                    sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.crypto, 0, chunk.offset, cast(uint) chunk.data.length, chunk.fin);
                }
            }
        }

        // STREAM frames
        if (hasStream && plainLen < plaintext.length && frameCount < MAX_FRAMES_PER_PACKET)
        {
            StreamId sid;
            TransmitChunk chunk;
            const size_t avail = (plaintext.length - plainLen > 32) ? (plaintext.length - plainLen - 32) : 0;
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
                if (encodeFrame(f, plaintext[plainLen .. $], wr) == 0)
                {
                    plainLen += wr;
                    sentFramesList[frameCount++] = SentFrameDesc(SentFrameKind.stream, sid.id, chunk.offset, cast(uint) chunk.data.length, chunk.fin);
                }
            }
        }

        if (plainLen == 0)
            return false;

        const ulong pn = nextPn[2];
        const size_t pnLen = 1;
        size_t pnOff = 0;
        size_t hdrLen = 0;
        const bool keyPhase = (localKeyPhase != 0);

        if (encodeShortHeader(
            remoteCid,
            pn,
            pnLen,
            keyPhase,
            false,
            outBuf,
            pnOff,
            hdrLen
        ) != 0)
            return false;

        if (outBuf.length < hdrLen + plainLen + 16)
            return false;

        outBuf[hdrLen .. hdrLen + plainLen] = plaintext[0 .. plainLen];

        size_t protLen = 0;
        if (protectPacket(levelKeys[3].local, pn, pnOff, pnLen, outBuf, plainLen, protLen) != QuicCryptoError.none)
            return false;

        nextPn[2]++;
        sentFrames.recordPacket(PacketNumberSpace.applicationData, pn, sentFramesList[0 .. frameCount]);
        lossDetector.onPacketSent(PacketNumberSpace.applicationData, pn, cast(uint) protLen, frameCount > 0, true, nowMicros);

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
        f.type = closeIsApp ? FrameType.connectionCloseApp : FrameType.connectionCloseQuic;
        f.connectionClose.errorCode = closeErrorCode;
        f.connectionClose.frameType = closeFrameType;
        f.connectionClose.isApplication = closeIsApp;

        size_t plainLen = 0;
        if (encodeFrame(f, plaintext[], plainLen) != 0)
            return false;

        const ulong pn = nextPn[space];
        size_t pnOff = 0;
        size_t hdrLen = 0;

        if (pktType == PacketType.oneRttShort)
        {
            const bool keyPhase = (localKeyPhase != 0);
            if (encodeShortHeader(remoteCid, pn, 1, keyPhase, false, outBuf, pnOff, hdrLen) != 0)
                return false;
        }
        else
        {
            if (encodeLongHeader(pktType, QUIC_VERSION_1, remoteCid, localCid, null, pn, 2, plainLen, outBuf, pnOff, hdrLen) != 0)
                return false;
        }

        if (outBuf.length < hdrLen + plainLen + 16)
            return false;

        outBuf[hdrLen .. hdrLen + plainLen] = plaintext[0 .. plainLen];

        size_t protLen = 0;
        if (protectPacket(levelKeys[keyIdx].local, pn, pnOff, (pktType == PacketType.oneRttShort ? 1 : 2), outBuf, plainLen, protLen) != QuicCryptoError.none)
            return false;

        nextPn[space]++;
        closePacketSent = true;
        state = ConnectionState.draining;
        const ulong rttVal = (lossDetector.rtt.smoothedRtt > 0) ? lossDetector.rtt.smoothedRtt : 100_000;
        drainingEndTimeMicros = nowMicros + 3 * rttVal;

        totalBytesSent += protLen;
        bytesWritten = protLen;
        return true;
    }

    private void enterClosing(ulong errCode, ulong frameType, bool isApp) @safe pure @nogc nothrow
    {
        if (state == ConnectionState.closing || state == ConnectionState.draining || state == ConnectionState.closed)
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
        if (space == PacketNumberSpace.initial) lvl = 0;
        else if (space == PacketNumberSpace.handshake) lvl = 2;
        else return;

        levelKeys[lvl].cleanup();
        hasReadKeys[lvl] = false;
        hasWriteKeys[lvl] = false;

        cryptoRecv[space].cleanup();
        cryptoSend[space].cleanup();
        ackRanges[space].clear();

        sentFrames.discardSpace(space);
        lossDetector.discardSpace(space);
    }

    // --- Stream & Lifecycle APIs ---

    TransportErrorCode openStream(StreamDirection dir, out StreamId sid) @safe @nogc nothrow
    {
        return streams.openLocalStream(dir, sid);
    }

    bool streamWrite(StreamId sid, const(ubyte)[] data, bool fin) @safe @nogc nothrow
    {
        QuicStream* qs = streams.getStream(sid);
        if (qs is null)
            return false;
        return qs.sendBuf.write(data, fin);
    }

    ptrdiff_t streamRead(StreamId sid, ubyte[] outBuf, out bool finReached) @safe @nogc nothrow
    {
        finReached = false;
        QuicStream* qs = streams.getStream(sid);
        if (qs is null)
            return -1;
        return cast(ptrdiff_t) qs.recvBuf.read(outBuf, finReached);
    }

    void resetStream(StreamId sid, ulong appErrorCode) @safe @nogc nothrow
    {
        QuicStream* qs = streams.getStream(sid);
        if (qs !is null)
        {
            qs.resetQueued = true;
            qs.sendState = SendStreamState.resetSent;
            qs.applicationErrorCode = appErrorCode;
        }
    }

    void stopSending(StreamId sid, ulong appErrorCode) @safe @nogc nothrow
    {
        QuicStream* qs = streams.getStream(sid);
        if (qs !is null)
        {
            qs.stopSendingQueued = true;
            qs.applicationErrorCode = appErrorCode;
        }
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
        deriveNextApplicationSecret(tls.negotiatedCipher, localAppSecret[0 .. appSecretLen], nextLocalSec[0 .. appSecretLen]);
        KeyMaterial nextKm;
        deriveKeyMaterial(tls.negotiatedCipher, nextLocalSec[0 .. appSecretLen], nextKm);

        levelKeys[3].local.aead.init(tls.negotiatedCipher, nextKm.key[0 .. nextKm.keyLen], nextKm.iv[0 .. 12]);
        localAppSecret[0 .. appSecretLen] = nextLocalSec[0 .. appSecretLen];
        localKeyPhase ^= 1;
        return true;
    }

    void close(ulong errorCode, bool isApplicationClose = false) @safe pure @nogc nothrow
    {
        enterClosing(errorCode, 0, isApplicationClose);
    }

    bool pollEvent(out ConnectionEvent ev) @safe @nogc nothrow
    {
        return events.poll(ev);
    }

    ulong nextTimeoutMicros(ulong nowMicros) const @safe pure @nogc nothrow
    {
        if (state == ConnectionState.draining)
            return drainingEndTimeMicros;

        const ulong recTimeout = lossDetector.nextTimeoutMicros(localParams.maxAckDelay * 1000, handshakeConfirmed);
        return recTimeout;
    }

    void onTimeout(ulong nowMicros) @trusted @nogc nothrow
    {
        if (state == ConnectionState.draining && nowMicros >= drainingEndTimeMicros)
        {
            state = ConnectionState.closed;
            return;
        }

        // Idle timeout (RFC 9000 §10.1)
        ulong effectiveIdleTimeoutMicros = 0;
        if (localParams.maxIdleTimeout > 0 && peerParams.maxIdleTimeout > 0)
        {
            const ulong minMs = (localParams.maxIdleTimeout < peerParams.maxIdleTimeout) ? localParams.maxIdleTimeout : peerParams.maxIdleTimeout;
            effectiveIdleTimeoutMicros = minMs * 1000;
        }
        else if (localParams.maxIdleTimeout > 0)
        {
            effectiveIdleTimeoutMicros = localParams.maxIdleTimeout * 1000;
        }
        else if (peerParams.maxIdleTimeout > 0)
        {
            effectiveIdleTimeoutMicros = peerParams.maxIdleTimeout * 1000;
        }

        if (effectiveIdleTimeoutMicros > 0 && lastRxTimeMicros > 0 && nowMicros >= lastRxTimeMicros + effectiveIdleTimeoutMicros)
        {
            state = ConnectionState.closed;
            events.push(ConnectionEvent(ConnectionEventType.connectionClosed, 0, 0, false));
            return;
        }

        const uint prevPto = lossDetector.ptoCount;
        SentPacketInfo[128] newlyLost;
        size_t lostCount = 0;
        lossDetector.onTimeout(nowMicros, newlyLost[], lostCount);

        if (lossDetector.ptoCount > prevPto)
        {
            pingQueued = true;
        }

        // Discard or retransmit lost packets
        foreach (i; 0 .. lostCount)
        {
            foreach (s; 0 .. NUM_SPACES)
            {
                SentPacketRecord rec;
                if (sentFrames.takePacket(cast(PacketNumberSpace) s, newlyLost[i].pn, rec))
                {
                    foreach (f; 0 .. rec.frameCount)
                    {
                        const desc = rec.frames[f];
                        if (desc.kind == SentFrameKind.crypto)
                        {
                            cryptoSend[s].onRangeLost(desc.offset, desc.length, desc.fin);
                        }
                        else if (desc.kind == SentFrameKind.stream)
                        {
                            QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                            if (qs !is null)
                            {
                                qs.sendBuf.onRangeLost(desc.offset, desc.length, desc.fin);
                            }
                        }
                        else if (desc.kind == SentFrameKind.handshakeDone)
                        {
                            handshakeDoneQueued = true;
                            handshakeDoneInFlight = false;
                        }
                    }
                }
            }
        }
    }
}
