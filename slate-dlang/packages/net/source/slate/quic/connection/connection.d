module slate.quic.connection.connection;

/**
 * QUIC Connection State Machine (RFC 9000 & RFC 9001).
 *
 * Implements a deterministic, Sans-I/O QUIC Connection supporting Server and Client
 * roles, coalesced packet ingestion and packing, anti-amplification budget enforcement,
 * automatic CRYPTO and STREAM frame loss retransmission, path validation, 1-RTT key updates,
 * and graceful connection teardown.
 */

import slate.quic.crypto.kdf : Side, CipherSuite, EncryptionLevel,
    QuicCryptoError, deriveInitialSecret, deriveClientInitialSecret,
    deriveServerInitialSecret, deriveKeyMaterial, KeyMaterial, hashLength,
    deriveNextApplicationSecret;
import slate.quic.crypto.aead : AeadKey, verifyRetryIntegrityTag;
import slate.quic.crypto.packet_keys : DirectionalKeys, Keys, protectPacket,
    unprotectPacket, unprotectPacketWithAead;
import slate.quic.crypto.tls_session : TlsContext, TlsSession;

import slate.quic.wire.varint : VARINT_MAX, WireError;
import slate.quic.wire.cid : ConnectionId, TransportErrorCode;
import slate.quic.wire.packet : PacketType, PacketPrefix, DecodedPacketHeader,
    CoalescedPacketIterator, parsePacketPrefix,
    completeHeaderAfterUnprotect, encodeLongHeader, encodeShortHeader, QUIC_VERSION_1;
import slate.quic.wire.frame : Frame, FrameType, FrameIterator, AckRange,
    AckFrame, StreamFrame, CryptoFrame, ConnectionCloseFrame,
    PathChallengeFrame, PathResponseFrame, HandshakeDoneFrame, ResetStreamFrame, StopSendingFrame, MaxDataFrame,
    MaxStreamDataFrame, MaxStreamsFrame, encodeFrame, decodeFrame, validateFrameInPacket;
import slate.quic.wire.transport_params : TransportParameters,
    encodeTransportParams, decodeTransportParams;

import slate.quic.stream.id : StreamId, StreamDirection, SendStreamState, RecvStreamState;
import slate.quic.stream.recv_buffer : RecvBuffer, CRYPTO_BUFFER_CAPACITY;
import slate.quic.stream.send_buffer : SendBuffer, TransmitChunk;
import slate.quic.stream.stream_map : StreamMap, QuicStream;

import slate.quic.recovery.ack_ranges : AckRangeSet;
import slate.quic.recovery.loss_detection : LossDetector, PacketNumberSpace,
    SentPacketInfo, NUM_SPACES;

import slate.quic.connection.events : ConnectionEventType, ConnectionEvent, ConnectionEventQueue;
import slate.quic.connection.sent_frames : SentFrameKind, SentFrameDesc, SentPacketRecord,
    SentFrameTracker, MAX_FRAMES_PER_PACKET, MAX_TRACKED_PACKETS_PER_SPACE;
import slate.quic.crypto.c_openssl : OPENSSL_cleanse;
import slate.quic.connection.packet_packer : QuicPacketPacker;

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

    AeadKey prevRemoteAead;
    bool hasPrevRemoteAead = false;

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
        if (hasPrevRemoteAead)
        {
            prevRemoteAead.cleanup();
            hasPrevRemoteAead = false;
        }

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
        OPENSSL_cleanse(localAppSecret.ptr, localAppSecret.length);
        OPENSSL_cleanse(remoteAppSecret.ptr, remoteAppSecret.length);
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

        if (other.hasPrevRemoteAead)
        {
            this.prevRemoteAead.moveFrom(other.prevRemoteAead);
            this.hasPrevRemoteAead = true;
            other.hasPrevRemoteAead = false;
        }

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

        const ulong maxAllowed = (totalBytesReceived > ulong.max / 3) ? ulong.max
            : (3 * totalBytesReceived);
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
    static bool create(Side side, ref TlsContext tlsCtx, ConnectionId localCid,
            ConnectionId remoteCid, ref const TransportParameters localParams,
            ulong nowMicros, out QuicConnection conn, bool addressValidated = false,
            const(ubyte)[] retryToken = null, const(char)[] clientAlpn = "h3",
            const(char)[] serverName = null) @trusted @nogc nothrow
    {
        conn.cleanup();

        conn.localSide = side;
        conn.state = ConnectionState.handshaking;
        conn.localCid = localCid;
        conn.remoteCid = remoteCid;
        conn.initialDcid = (side == Side.client) ? remoteCid : localCid;

        TransportParameters effLocalParams = localParams;
        if (!effLocalParams.hasInitialSourceConnectionId)
        {
            effLocalParams.hasInitialSourceConnectionId = true;
            effLocalParams.initialSourceConnectionId = localCid;
        }
        if (side == Side.server && !effLocalParams.hasOriginalDestinationConnectionId)
        {
            effLocalParams.hasOriginalDestinationConnectionId = true;
            effLocalParams.originalDestinationConnectionId = conn.initialDcid;
        }
        conn.localParams = effLocalParams;

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
            conn.levelKeys[0].local.init(CipherSuite.TLS_AES_128_GCM_SHA256,
                    clientKm.key[0 .. 16], clientKm.iv[0 .. 12], clientKm.hp[0 .. 16]);
            conn.levelKeys[0].remote.init(CipherSuite.TLS_AES_128_GCM_SHA256,
                    serverKm.key[0 .. 16], serverKm.iv[0 .. 12], serverKm.hp[0 .. 16]);
        }
        else
        {
            conn.levelKeys[0].local.init(CipherSuite.TLS_AES_128_GCM_SHA256,
                    serverKm.key[0 .. 16], serverKm.iv[0 .. 12], serverKm.hp[0 .. 16]);
            conn.levelKeys[0].remote.init(CipherSuite.TLS_AES_128_GCM_SHA256,
                    clientKm.key[0 .. 16], clientKm.iv[0 .. 12], clientKm.hp[0 .. 16]);
        }
        conn.levelKeys[0].initialized = true;
        conn.hasReadKeys[0] = true;
        conn.hasWriteKeys[0] = true;

        // 2. Encode local TransportParameters and initialize TlsSession
        ubyte[512] tpBuf;
        size_t tpLen = 0;
        if (encodeTransportParams(conn.localParams, side, tpBuf[], tpLen) != 0)
            return false;

        conn.tls.init(tlsCtx, side, tpBuf[0 .. tpLen], clientAlpn, serverName);

        // 3. Initialize StreamMap
        conn.streams = StreamMap(side, localParams.initialMaxData,
                localParams.initialMaxStreamDataBidiLocal, localParams.initialMaxStreamDataBidiRemote,
                localParams.initialMaxStreamDataUni, localParams.initialMaxStreamsBidi,
                localParams.initialMaxStreamsUni, 0, 0);

        foreach (s; 0 .. 3)
        {
            conn.cryptoRecv[s] = RecvBuffer(CRYPTO_BUFFER_CAPACITY);
        }

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
     * Returns the negotiated ALPN protocol string for this connection, or empty slice if not negotiated.
     */
    @property const(char)[] negotiatedAlpn() const return @trusted @nogc nothrow
    {
        return tls.negotiatedAlpn;
    }

    /**
     * Ingests an incoming UDP datagram containing one or more coalesced QUIC packets.
     */
    TransportErrorCode handleDatagram(const(ubyte)[] datagram, ulong nowMicros) @trusted @nogc nothrow
    {
        if (state == ConnectionState.draining || state == ConnectionState.closed)
            return TransportErrorCode.noError;

        // RFC 9000 Section 14.1 & F2: Server drops undersized initial datagrams (< 1200 bytes)
        if (localSide == Side.server && !peerAddressValidated && datagram.length > 0)
        {
            const bool isInitial = (datagram[0] & 0x80) != 0 && ((datagram[0] & 0x30) >> 4) == 0;
            if (isInitial && datagram.length < MIN_INITIAL_DATAGRAM_LEN)
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

        // F-26: Silently drop trailing unparseable coalesced bytes without connection abort
        return TransportErrorCode.noError;
    }

    private TransportErrorCode processSinglePacket(const(ubyte)[] packetBytes,
            ref const PacketPrefix prefix, ulong nowMicros) @trusted @nogc nothrow
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
            return TransportErrorCode.noError; // Silently drop oversized packet (F-26)

        unprotBuf[0 .. packetBytes.length] = packetBytes[];

        size_t decPnLen = 0;
        ulong decPn = 0;
        size_t decPayOff = 0;
        size_t decPlainLen = 0;

        const ulong largestReceived = !ackRanges[space].empty ? ackRanges[space].largestReceived : 0;

        // Unprotect packet header and payload
        QuicCryptoError cryptoErr = unprotectPacket(levelKeys[keyIdx].remote, prefix.pnOffset, largestReceived,
                unprotBuf[0 .. packetBytes.length], decPnLen, decPn, decPayOff, decPlainLen);

        if (cryptoErr != QuicCryptoError.none)
        {
            // If 1-RTT short header and AEAD tag mismatch, check for 1-RTT Key Phase update (RFC 9001 §6)
            if (prefix.type == PacketType.oneRttShort && appSecretLen > 0
                    && cryptoErr == QuicCryptoError.aeadTagMismatch)
            {
                // Try previous remote AEAD key first (F-23)
                if (hasPrevRemoteAead)
                {
                    unprotBuf[0 .. packetBytes.length] = packetBytes[];
                    cryptoErr = unprotectPacketWithAead(levelKeys[3].remote.hp,
                            prevRemoteAead, prefix.pnOffset, largestReceived,
                            unprotBuf[0 .. packetBytes.length], decPnLen,
                            decPn, decPayOff, decPlainLen);
                }

                if (cryptoErr != QuicCryptoError.none)
                {
                    ubyte[48] nextRemoteSec;
                    deriveNextApplicationSecret(tls.negotiatedCipher,
                            remoteAppSecret[0 .. appSecretLen], nextRemoteSec[0 .. appSecretLen]);
                    KeyMaterial nextKm;
                    deriveKeyMaterial(tls.negotiatedCipher, nextRemoteSec[0 .. appSecretLen],
                            nextKm);
                    AeadKey tempAead;
                    tempAead.init(tls.negotiatedCipher,
                            nextKm.key[0 .. nextKm.keyLen], nextKm.iv[0 .. 12]);

                    unprotBuf[0 .. packetBytes.length] = packetBytes[];
                    cryptoErr = unprotectPacketWithAead(levelKeys[3].remote.hp,
                            tempAead, prefix.pnOffset, largestReceived,
                            unprotBuf[0 .. packetBytes.length], decPnLen,
                            decPn, decPayOff, decPlainLen);

                    if (cryptoErr == QuicCryptoError.none)
                    {
                        const ubyte pktPhase = (unprotBuf[0] & 0x04) != 0 ? 1 : 0;
                        if (pktPhase != remoteKeyPhase)
                        {
                            // Commit rotated remote keys, retaining previous key (F-23)
                            remoteAppSecret[0 .. appSecretLen] = nextRemoteSec[0 .. appSecretLen];
                            if (hasPrevRemoteAead)
                                prevRemoteAead.cleanup();
                            prevRemoteAead.moveFrom(levelKeys[3].remote.aead);
                            hasPrevRemoteAead = true;
                            levelKeys[3].remote.aead.moveFrom(tempAead);
                            remoteKeyPhase ^= 1;

                            // RFC 9001 §6.2: If peer initiated the key update, receiver must also update its write keys
                            if (localKeyPhase != remoteKeyPhase)
                            {
                                ubyte[48] nextLocalSec;
                                deriveNextApplicationSecret(tls.negotiatedCipher,
                                        localAppSecret[0 .. appSecretLen],
                                        nextLocalSec[0 .. appSecretLen]);
                                KeyMaterial nextLocalKm;
                                deriveKeyMaterial(tls.negotiatedCipher,
                                        nextLocalSec[0 .. appSecretLen], nextLocalKm);
                                levelKeys[3].local.aead.init(tls.negotiatedCipher,
                                        nextLocalKm.key[0 .. nextLocalKm.keyLen],
                                        nextLocalKm.iv[0 .. 12]);
                                localAppSecret[0 .. appSecretLen] = nextLocalSec[0 .. appSecretLen];
                                localKeyPhase = remoteKeyPhase;

                                OPENSSL_cleanse(nextLocalSec.ptr, nextLocalSec.length);
                                OPENSSL_cleanse(nextLocalKm.key.ptr, nextLocalKm.key.length);
                                OPENSSL_cleanse(nextLocalKm.iv.ptr, nextLocalKm.iv.length);
                                OPENSSL_cleanse(nextLocalKm.hp.ptr, nextLocalKm.hp.length);
                            }
                        }
                        else
                        {
                            cryptoErr = QuicCryptoError.aeadTagMismatch;
                        }
                    }

                    OPENSSL_cleanse(nextRemoteSec.ptr, nextRemoteSec.length);
                    OPENSSL_cleanse(nextKm.key.ptr, nextKm.key.length);
                    OPENSSL_cleanse(nextKm.iv.ptr, nextKm.iv.length);
                    OPENSSL_cleanse(nextKm.hp.ptr, nextKm.hp.length);
                }
            }

            if (cryptoErr != QuicCryptoError.none)
                return TransportErrorCode.noError; // Silently drop corrupted/unauthenticated packet
        }

        DecodedPacketHeader hdr;
        TransportErrorCode te = TransportErrorCode.noError;
        const completeErr = completeHeaderAfterUnprotect(unprotBuf[0 .. decPayOff + decPlainLen],
                prefix, largestReceived, hdr, te);
        if (completeErr != 0 || te != TransportErrorCode.noError)
            return te != TransportErrorCode.noError ? te : TransportErrorCode.protocolViolation;

        // Duplicate packet check (F-20): silently ignore
        if (ackRanges[space].contains(hdr.packetNumber))
            return TransportErrorCode.noError;

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
            if (frame.type != FrameType.ack && frame.type != FrameType.padding
                    && frame.type != FrameType.connectionCloseQuic
                    && frame.type != FrameType.connectionCloseApp)
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

    package TransportErrorCode handleRetryPacket(ref const PacketPrefix prefix,
            const(ubyte)[] packetBytes) @trusted @nogc nothrow
    {
        if (localSide != Side.client || prefix.token.length == 0)
            return TransportErrorCode.noError;

        // RFC 9000 §17.2.5.2: A client MUST treat receipt of a second Retry packet as PROTOCOL_VIOLATION
        if (retryReceived)
            return TransportErrorCode.protocolViolation;

        // RFC 9000 §17.2.5.2: Discard if SCID matches client's DCID or SCID
        if (prefix.scid == remoteCid || prefix.scid == initialDcid)
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

            levelKeys[0].local.init(CipherSuite.TLS_AES_128_GCM_SHA256,
                    clientKm.key[0 .. 16], clientKm.iv[0 .. 12], clientKm.hp[0 .. 16]);
            levelKeys[0].remote.init(CipherSuite.TLS_AES_128_GCM_SHA256,
                    serverKm.key[0 .. 16], serverKm.iv[0 .. 12], serverKm.hp[0 .. 16]);

            // RFC 9000 §17.2.5.2: Discard sent Initial packets, discard loss detection, and reset Initial packet number
            nextPn[0] = 0;
            sentFrames.discardSpace(PacketNumberSpace.initial);
            lossDetector.discardSpace(PacketNumberSpace.initial);
            ackRanges[0].clear();

            // Mark cryptoSend[0] for retransmission from offset 0
            cryptoSend[0].onRangeLost(0, cryptoSend[0].writeOffset, false);
        }

        return TransportErrorCode.noError;
    }

    package TransportErrorCode dispatchFrame(PacketNumberSpace space,
            ref const Frame frame, ulong nowMicros) @trusted @nogc nothrow
    {
        switch (frame.type)
        {
        case FrameType.newToken:
            if (localSide == Side.server)
                return TransportErrorCode.protocolViolation; // RFC 9000 §19.7
            return TransportErrorCode.noError;

        case FrameType.padding:
            return TransportErrorCode.noError;

        case FrameType.ping:
            return TransportErrorCode.noError;

        case FrameType.ack:
        case FrameType.ackEcn:
            return processAckFrame(space,
                    frame.ack, nowMicros);

        case FrameType.crypto:
            return processCryptoFrame(space, frame.crypto, nowMicros);

        case FrameType.stream:
            return processStreamFrame(frame.stream);

        case FrameType.resetStream:
            const rErr = streams.onResetStreamFrame(frame.resetStream);
            if (rErr != TransportErrorCode.noError)
                return rErr;
            streams.reapClosedStreams();
            events.push(ConnectionEvent(ConnectionEventType.streamReset,
                    frame.resetStream.streamId, frame.resetStream.applicationErrorCode, false));
            return TransportErrorCode.noError;

        case FrameType.stopSending:
            const sErr = streams.onStopSendingFrame(frame.stopSending);
            if (sErr != TransportErrorCode.noError)
                return sErr;
            events.push(ConnectionEvent(ConnectionEventType.stopSending,
                    frame.stopSending.streamId, frame.stopSending.applicationErrorCode, false));
            return TransportErrorCode.noError;

        case FrameType.maxData:
            const mdErr = streams.onMaxDataFrame(frame.maxData);
            if (mdErr != TransportErrorCode.noError)
                return mdErr;
            events.push(ConnectionEvent(ConnectionEventType.streamWritable, 0, 0, false));
            return TransportErrorCode.noError;

        case FrameType.maxStreamData:
            const msdErr = streams.onMaxStreamDataFrame(frame.maxStreamData);
            if (msdErr != TransportErrorCode.noError)
                return msdErr;
            events.push(ConnectionEvent(ConnectionEventType.streamWritable,
                    frame.maxStreamData.streamId, 0, false));
            return TransportErrorCode.noError;

        case FrameType.maxStreamsBidi:
        case FrameType.maxStreamsUni:
            const msErr = streams.onMaxStreamsFrame(frame.maxStreams);
            if (msErr != TransportErrorCode.noError)
                return msErr;
            return TransportErrorCode.noError;

        case FrameType.pathChallenge:
            hasPendingPathResponse = true;
            pendingPathResponseData = frame.pathChallenge.data;
            return TransportErrorCode.noError;

        case FrameType.pathResponse:
            if (hasPendingPathChallenge
                    && frame.pathResponse.data == pendingPathChallengeData)
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

        case FrameType.newConnectionId:
            if (frame.newConnectionId.cid.len < 1
                    || frame.newConnectionId.cid.len > 20)
                return TransportErrorCode.frameEncodingError;
            if (frame.newConnectionId.retirePriorTo > frame.newConnectionId.sequenceNumber)
                return TransportErrorCode.protocolViolation;
            return TransportErrorCode.noError;

        case FrameType.retireConnectionId:
            if (frame.retireConnectionId.sequenceNumber > VARINT_MAX)
                return TransportErrorCode.frameEncodingError;
            if (frame.retireConnectionId.sequenceNumber > 0)
                return TransportErrorCode.protocolViolation;
            return TransportErrorCode.noError;

        case FrameType.connectionCloseQuic:
        case FrameType.connectionCloseApp:
            state = ConnectionState.draining;
            closeErrorCode = frame.connectionClose.errorCode;
            closeFrameType = frame.connectionClose.frameType;
            closeIsApp = frame.connectionClose.isApplication;
            const ulong rawRtt = (lossDetector.rtt.smoothedRtt > 0) ? lossDetector.rtt.smoothedRtt
                : 100_000;
            const ulong clampedRtt = (rawRtt > ulong.max / 6) ? (ulong.max / 6) : rawRtt;
            const ulong drainDur = 3 * clampedRtt;
            drainingEndTimeMicros = (ulong.max - nowMicros < drainDur) ? ulong.max
                : (nowMicros + drainDur);
            events.push(ConnectionEvent(ConnectionEventType.connectionClosed,
                    0, closeErrorCode, closeIsApp));
            return TransportErrorCode.noError;

        default:
            return TransportErrorCode.noError;
        }
    }

    private TransportErrorCode processAckFrame(PacketNumberSpace space,
            ref const AckFrame ack, ulong nowMicros) @trusted @nogc nothrow
    {
        SentPacketInfo[MAX_TRACKED_PACKETS_PER_SPACE] newlyAcked;
        size_t ackedCount = 0;
        SentPacketInfo[MAX_TRACKED_PACKETS_PER_SPACE] newlyLost;
        size_t lostCount = 0;

        const ubyte ackDelayExp = peerParamsReceived ? cast(ubyte) peerParams.ackDelayExponent : 3;
        const ulong maxAckDelayMicros = peerParamsReceived ? (peerParams.maxAckDelay * 1000)
            : 25_000;
        const te = lossDetector.onAckReceived(space, ack, ackDelayExp, maxAckDelayMicros,
                handshakeConfirmed, nowMicros, newlyAcked[], ackedCount, newlyLost[], lostCount);

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
                                events.push(ConnectionEvent(ConnectionEventType.streamFinished,
                                        desc.streamId, 0, false));
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
                                events.push(ConnectionEvent(ConnectionEventType.handshakeConfirmed,
                                        0, 0, false));
                            }
                            discardSpace(PacketNumberSpace.handshake);
                        }
                    }
                    else if (desc.kind == SentFrameKind.resetStream)
                    {
                        QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                        if (qs !is null)
                        {
                            qs.sendState = SendStreamState.resetRecvd;
                        }
                    }
                }
            }
        }

        // Reap closed streams once acknowledged (D-02)
        streams.reapClosedStreams();

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
                    else if (desc.kind == SentFrameKind.resetStream)
                    {
                        QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                        if (qs !is null && qs.sendState == SendStreamState.resetSent)
                        {
                            qs.resetQueued = true;
                        }
                    }
                    else if (desc.kind == SentFrameKind.stopSending)
                    {
                        QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                        if (qs !is null)
                        {
                            qs.stopSendingQueued = true;
                        }
                    }
                    else if (desc.kind == SentFrameKind.maxData)
                    {
                        streams.connFlow.rearm();
                    }
                    else if (desc.kind == SentFrameKind.maxStreamData)
                    {
                        QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                        if (qs !is null)
                        {
                            qs.flowCtrl.rearm();
                        }
                    }
                    else if (desc.kind == SentFrameKind.maxStreamsBidi)
                    {
                        streams.maxStreamsBidiPending = true;
                    }
                    else if (desc.kind == SentFrameKind.maxStreamsUni)
                    {
                        streams.maxStreamsUniPending = true;
                    }
                }
            }
        }

        return TransportErrorCode.noError;
    }

    package TransportErrorCode processCryptoFrame(PacketNumberSpace space,
            ref const CryptoFrame crypto, ulong nowMicros) @trusted @nogc nothrow
    {
        const ingErr = cryptoRecv[space].ingest(crypto.offset, crypto.data,
                false, TransportErrorCode.cryptoBufferExceeded);
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
                return (te != TransportErrorCode.noError) ? te
                    : TransportErrorCode.transportParameterError;
            }

            // RFC 9000 §7.3 CID authentication (F-14)
            if (!peerParams.hasInitialSourceConnectionId
                    || peerParams.initialSourceConnectionId != remoteCid)
            {
                return TransportErrorCode.transportParameterError;
            }

            if (localSide == Side.client)
            {
                if (!peerParams.hasOriginalDestinationConnectionId
                        || peerParams.originalDestinationConnectionId != initialDcid)
                {
                    return TransportErrorCode.transportParameterError;
                }
                if (retryReceived)
                {
                    if (!peerParams.hasRetrySourceConnectionId
                            || peerParams.retrySourceConnectionId != retryScid)
                    {
                        return TransportErrorCode.transportParameterError;
                    }
                }
                else if (peerParams.hasRetrySourceConnectionId)
                {
                    return TransportErrorCode.transportParameterError;
                }
            }
            else // localSide == Side.server (peer is client)
            {
                if (peerParams.hasOriginalDestinationConnectionId
                        || peerParams.hasRetrySourceConnectionId)
                {
                    return TransportErrorCode.transportParameterError;
                }
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

    package TransportErrorCode processStreamFrame(ref const StreamFrame sf) @trusted @nogc nothrow
    {
        QuicStream* qsBefore = streams.getStream(StreamId(sf.streamId));
        if (qsBefore !is null && (qsBefore.recvState == RecvStreamState.resetRecvd
                || qsBefore.recvState == RecvStreamState.resetRead
                || qsBefore.recvState == RecvStreamState.dataRead))
        {
            return TransportErrorCode.noError;
        }

        const te = streams.onStreamFrame(sf);
        if (te != TransportErrorCode.noError)
            return te;

        QuicStream* qs = streams.getStream(StreamId(sf.streamId));
        if (qs !is null)
        {
            if (qs.recvState != RecvStreamState.resetRecvd
                    && qs.recvState != RecvStreamState.resetRead
                    && qs.recvState != RecvStreamState.dataRead)
            {
                if (qs.recvBuf.readableBytes > 0)
                {
                    events.push(ConnectionEvent(ConnectionEventType.streamReadable,
                            sf.streamId, 0, false));
                }
                if (qs.recvBuf.hasFinalSize
                        && (qs.recvBuf.readOffset + qs.recvBuf.readableBytes == qs
                            .recvBuf.finalSize))
                {
                    events.push(ConnectionEvent(ConnectionEventType.streamFinished,
                            sf.streamId, 0, false));
                }
            }
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

    mixin QuicPacketPacker;

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
        const size_t n = qs.recvBuf.read(outBuf, finReached);
        if (n > 0)
        {
            qs.flowCtrl.onBytesRead(n);
            streams.connFlow.onBytesRead(n);
        }
        if (finReached)
        {
            qs.recvState = RecvStreamState.dataRead;
            streams.reapClosedStreams();
        }
        return cast(ptrdiff_t) n;
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

    bool pollEvent(out ConnectionEvent ev) @safe @nogc nothrow
    {
        return events.poll(ev);
    }

    void close(ulong errorCode = 0, bool isApp = true) @safe pure @nogc nothrow
    {
        enterClosing(errorCode, 0, isApp);
    }

    private ulong effectiveIdleTimeoutMicros() const @safe pure @nogc nothrow
    {
        enum ulong MAX_SAFE_IDLE_TIMEOUT_MS = ulong.max / 2000;
        ulong ms = 0;
        if (localParams.maxIdleTimeout > 0 && peerParams.maxIdleTimeout > 0)
        {
            ms = (localParams.maxIdleTimeout < peerParams.maxIdleTimeout) ? localParams.maxIdleTimeout
                : peerParams.maxIdleTimeout;
        }
        else if (localParams.maxIdleTimeout > 0)
            ms = localParams.maxIdleTimeout;
        else if (peerParams.maxIdleTimeout > 0)
            ms = peerParams.maxIdleTimeout;
        else
            return 0;

        if (ms > MAX_SAFE_IDLE_TIMEOUT_MS)
            ms = MAX_SAFE_IDLE_TIMEOUT_MS;
        return ms * 1000;
    }

    ulong nextTimeoutMicros(ulong nowMicros) const @safe pure @nogc nothrow
    {
        if (state == ConnectionState.draining)
            return drainingEndTimeMicros;

        const ulong maxAckDelayMicros = peerParamsReceived ? (peerParams.maxAckDelay * 1000) : (
                localParams.maxAckDelay * 1000);
        const ulong recDeadline = lossDetector.nextTimeoutMicros(maxAckDelayMicros,
                handshakeConfirmed);
        const ulong idleMicros = effectiveIdleTimeoutMicros();
        if (idleMicros > 0 && lastRxTimeMicros > 0)
        {
            const ulong idleDeadline = (ulong.max - lastRxTimeMicros < idleMicros) ? ulong.max
                : (lastRxTimeMicros + idleMicros);
            if (recDeadline == 0 || idleDeadline < recDeadline)
                return idleDeadline;
        }
        return recDeadline;
    }

    void onTimeout(ulong nowMicros) @trusted @nogc nothrow
    {
        if (state == ConnectionState.draining && nowMicros >= drainingEndTimeMicros)
        {
            state = ConnectionState.closed;
            return;
        }

        // Idle timeout (RFC 9000 §10.1)
        const ulong idleMicros = effectiveIdleTimeoutMicros();
        if (idleMicros > 0 && lastRxTimeMicros > 0)
        {
            const ulong idleDeadline = (ulong.max - lastRxTimeMicros < idleMicros) ? ulong.max
                : (lastRxTimeMicros + idleMicros);
            if (nowMicros >= idleDeadline)
            {
                state = ConnectionState.closed;
                events.push(ConnectionEvent(ConnectionEventType.connectionClosed, 0, 0, false));
                return;
            }
        }

        const ulong maxAckDelayMicros = peerParamsReceived ? (peerParams.maxAckDelay * 1000) : (
                localParams.maxAckDelay * 1000);
        const ulong recDeadline = lossDetector.nextTimeoutMicros(maxAckDelayMicros,
                handshakeConfirmed);
        if (recDeadline == 0 || nowMicros < recDeadline)
            return;

        const uint prevPto = lossDetector.ptoCount;
        SentPacketInfo[MAX_TRACKED_PACKETS_PER_SPACE] newlyLost;
        size_t lostCount = 0;
        lossDetector.onTimeout(nowMicros, newlyLost[], lostCount, maxAckDelayMicros);

        if (lossDetector.ptoCount > prevPto)
        {
            pingQueued = true;
        }

        // Discard or retransmit lost packets (F-11, F-17, F-05, D-02)
        foreach (i; 0 .. lostCount)
        {
            const PacketNumberSpace sp = newlyLost[i].space;
            SentPacketRecord rec;
            if (sentFrames.takePacket(sp, newlyLost[i].pn, rec))
            {
                foreach (f; 0 .. rec.frameCount)
                {
                    const desc = rec.frames[f];
                    if (desc.kind == SentFrameKind.crypto)
                    {
                        cryptoSend[cast(size_t) sp].onRangeLost(desc.offset, desc.length, desc.fin);
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
                    else if (desc.kind == SentFrameKind.resetStream)
                    {
                        QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                        if (qs !is null && qs.sendState == SendStreamState.resetSent)
                        {
                            qs.resetQueued = true;
                        }
                    }
                    else if (desc.kind == SentFrameKind.stopSending)
                    {
                        QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                        if (qs !is null)
                        {
                            qs.stopSendingQueued = true;
                        }
                    }
                    else if (desc.kind == SentFrameKind.maxData)
                    {
                        streams.connFlow.rearm();
                    }
                    else if (desc.kind == SentFrameKind.maxStreamData)
                    {
                        QuicStream* qs = streams.getStream(StreamId(desc.streamId));
                        if (qs !is null)
                        {
                            qs.flowCtrl.rearm();
                        }
                    }
                    else if (desc.kind == SentFrameKind.maxStreamsBidi)
                    {
                        streams.maxStreamsBidiPending = true;
                    }
                    else if (desc.kind == SentFrameKind.maxStreamsUni)
                    {
                        streams.maxStreamsUniPending = true;
                    }
                }
            }
        }
    }
}

// Spec: RFC 9000 Section 8.1 - Anti-Amplification Limits & Section 10.1 Idle Timeout Overflow Safety
/// Example:
@nogc unittest
{
    QuicConnection conn;
    assert(conn.state == ConnectionState.closed);
    assert(conn.amplificationBudget() == 0);
    conn.totalBytesReceived = 1200;
    assert(conn.amplificationBudget() == 3600);
    conn.totalBytesSent = 1000;
    assert(conn.amplificationBudget() == 2600);
    conn.peerAddressValidated = true;
    assert(conn.amplificationBudget() == size_t.max);

    // Verify 62-bit peer maxIdleTimeout varint does not overflow effectiveIdleTimeoutMicros or prematurely close
    conn.state = ConnectionState.active;
    conn.localParams.maxIdleTimeout = 0;
    conn.peerParams.maxIdleTimeout = (1UL << 62) - 1;
    conn.lastRxTimeMicros = 1_000_000;
    assert(conn.effectiveIdleTimeoutMicros() > 1_000_000_000_000UL);
    assert(conn.nextTimeoutMicros(1_000_500) > 1_000_500);
    conn.onTimeout(1_000_500);
    assert(conn.state == ConnectionState.active);
    conn.cleanup();
}
