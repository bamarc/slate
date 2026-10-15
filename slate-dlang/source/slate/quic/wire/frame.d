module slate.quic.wire.frame;

/**
 * QUIC Frames Encoding and Decoding (RFC 9000 Section 19 & Section 12.4).
 *
 * Implements all 20 RFC 9000 core frame types, multi-range ACK encoding/decoding,
 * bounds and underflow validations, and packet type legality enforcement.
 */

public import slate.quic.wire.varint;
public import slate.quic.wire.cid;
public import slate.quic.wire.packet : PacketType;

public enum FrameType : ulong
{
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ackEcn = 0x03,
    resetStream = 0x04,
    stopSending = 0x05,
    crypto = 0x06,
    newToken = 0x07,
    stream0 = 0x08,
    stream1 = 0x09,
    stream2 = 0x0a,
    stream3 = 0x0b,
    stream4 = 0x0c,
    stream5 = 0x0d,
    stream6 = 0x0e,
    stream7 = 0x0f,
    streamBase = 0x08,
    stream = 0x08,
    maxData = 0x10,
    maxStreamData = 0x11,
    maxStreamsBidi = 0x12,
    maxStreamsUni = 0x13,
    dataBlocked = 0x14,
    streamDataBlocked = 0x15,
    streamsBlockedBidi = 0x16,
    streamsBlockedUni = 0x17,
    newConnectionId = 0x18,
    retireConnectionId = 0x19,
    pathChallenge = 0x1a,
    pathResponse = 0x1b,
    connectionCloseQuic = 0x1c,
    connectionCloseApp = 0x1d,
    handshakeDone = 0x1e
}

public struct PaddingFrame
{
    size_t length;
}

public struct PingFrame
{
}

public enum size_t MAX_ACK_RANGES = 32;

public struct AckRange
{
    ulong smallest;
    ulong largest;
}

public struct AckFrame
{
    ulong ackDelay;
    AckRange[MAX_ACK_RANGES] ranges;
    size_t numRanges;
    bool hasEcn;
    ulong ect0;
    ulong ect1;
    ulong ecnCe;

    @property ulong largestAcknowledged() const @safe pure @nogc nothrow
    {
        return (numRanges > 0) ? ranges[0].largest : 0;
    }
}

public struct ResetStreamFrame
{
    ulong streamId;
    ulong applicationErrorCode;
    ulong finalSize;
}

public struct StopSendingFrame
{
    ulong streamId;
    ulong applicationErrorCode;
}

public struct CryptoFrame
{
    ulong offset;
    const(ubyte)[] data;
}

public struct NewTokenFrame
{
    const(ubyte)[] token;
}

public struct StreamFrame
{
    ulong streamId;
    ulong offset;
    const(ubyte)[] data;
    bool hasOffset;
    bool hasLength;
    bool fin;
}

public struct MaxDataFrame
{
    ulong maximumData;
}

public struct MaxStreamDataFrame
{
    ulong streamId;
    ulong maximumStreamData;
}

public struct MaxStreamsFrame
{
    bool isBidirectional;
    ulong maximumStreams;
}

public struct DataBlockedFrame
{
    ulong maximumData;
}

public struct StreamDataBlockedFrame
{
    ulong streamId;
    ulong maximumStreamData;
}

public struct StreamsBlockedFrame
{
    bool isBidirectional;
    ulong streamLimit;
}

public struct NewConnectionIdFrame
{
    ulong sequenceNumber;
    ulong retirePriorTo;
    ConnectionId cid;
    StatelessResetToken statelessResetToken;
}

public struct RetireConnectionIdFrame
{
    ulong sequenceNumber;
}

public struct PathChallengeFrame
{
    ubyte[8] data;
}

public struct PathResponseFrame
{
    ubyte[8] data;
}

public struct ConnectionCloseFrame
{
    bool isApplication;
    ulong errorCode;
    ulong frameType;
    const(char)[] reasonPhrase;
}

public struct HandshakeDoneFrame
{
}

public struct Frame
{
    FrameType type;

    PaddingFrame padding;
    PingFrame ping;
    AckFrame ack;
    ResetStreamFrame resetStream;
    StopSendingFrame stopSending;
    CryptoFrame crypto;
    NewTokenFrame newToken;
    StreamFrame stream;
    MaxDataFrame maxData;
    MaxStreamDataFrame maxStreamData;
    MaxStreamsFrame maxStreams;
    DataBlockedFrame dataBlocked;
    StreamDataBlockedFrame streamDataBlocked;
    StreamsBlockedFrame streamsBlocked;
    NewConnectionIdFrame newConnectionId;
    RetireConnectionIdFrame retireConnectionId;
    PathChallengeFrame pathChallenge;
    PathResponseFrame pathResponse;
    ConnectionCloseFrame connectionClose;
    HandshakeDoneFrame handshakeDone;
}

/**
 * Checks if a frame type is permitted in a given QUIC packet type (RFC 9000 Section 12.4 Table 3).
 */
bool isFrameAllowedInPacket(FrameType type, PacketType packetType) @safe pure @nogc nothrow
{
    switch (packetType)
    {
        case PacketType.initial:
            return (type == FrameType.padding
                || type == FrameType.ping
                || type == FrameType.ack
                || type == FrameType.ackEcn
                || type == FrameType.crypto
                || type == FrameType.connectionCloseQuic);

        case PacketType.handshake:
            return (type == FrameType.padding
                || type == FrameType.ping
                || type == FrameType.ack
                || type == FrameType.ackEcn
                || type == FrameType.crypto
                || type == FrameType.connectionCloseQuic);

        case PacketType.zeroRtt:
            return (type == FrameType.padding
                || type == FrameType.ping
                || type == FrameType.resetStream
                || type == FrameType.stopSending
                || (type >= FrameType.stream0 && type <= FrameType.stream7)
                || type == FrameType.maxData
                || type == FrameType.maxStreamData
                || type == FrameType.maxStreamsBidi
                || type == FrameType.maxStreamsUni
                || type == FrameType.dataBlocked
                || type == FrameType.streamDataBlocked
                || type == FrameType.streamsBlockedBidi
                || type == FrameType.streamsBlockedUni
                || type == FrameType.newConnectionId
                || type == FrameType.retireConnectionId
                || type == FrameType.pathChallenge
                || type == FrameType.connectionCloseQuic
                || type == FrameType.connectionCloseApp);

        case PacketType.oneRttShort:
            return (type <= FrameType.handshakeDone);

        case PacketType.retry:
        case PacketType.versionNegotiation:
        default:
            return false;
    }
}

/**
 * Validates frame legality within enclosing packet type (RFC 9000 Section 12.4).
 */
TransportErrorCode validateFrameInPacket(FrameType type, PacketType packetType) @safe pure @nogc nothrow
{
    if (isFrameAllowedInPacket(type, packetType))
        return TransportErrorCode.noError;
    return TransportErrorCode.protocolViolation;
}

/**
 * Encodes a QUIC frame into wire format (RFC 9000 Section 19).
 */
WireError encodeFrame(
    const ref Frame frame,
    ubyte[] outBuf,
    out size_t bytesWritten
) @safe pure @nogc nothrow
{
    bytesWritten = 0;
    WireWriter writer = WireWriter(outBuf);

    switch (frame.type)
    {
        case FrameType.padding:
            const size_t len = (frame.padding.length > 0) ? frame.padding.length : 1;
            if (writer.remaining < len)
                return WireError.bufferTooSmall;
            foreach (i; 0 .. len)
                writer.writeU8(0x00);
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.ping:
            if (writer.writeVarInt(0x01) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.ack:
        case FrameType.ackEcn:
            if (frame.ack.numRanges == 0)
                return WireError.invalidFrame;

            const ulong typeVal = frame.ack.hasEcn ? 0x03 : 0x02;
            if (writer.writeVarInt(typeVal) != WireError.none)
                return WireError.bufferTooSmall;

            const ulong largestAcked = frame.ack.ranges[0].largest;
            if (writer.writeVarInt(largestAcked) != WireError.none)
                return WireError.bufferTooSmall;

            if (writer.writeVarInt(frame.ack.ackDelay) != WireError.none)
                return WireError.bufferTooSmall;

            const ulong additionalRanges = frame.ack.numRanges - 1;
            if (writer.writeVarInt(additionalRanges) != WireError.none)
                return WireError.bufferTooSmall;

            if (frame.ack.ranges[0].largest < frame.ack.ranges[0].smallest)
                return WireError.invalidFrame;

            const ulong firstRange = frame.ack.ranges[0].largest - frame.ack.ranges[0].smallest;
            if (writer.writeVarInt(firstRange) != WireError.none)
                return WireError.bufferTooSmall;

            foreach (i; 1 .. frame.ack.numRanges)
            {
                if (frame.ack.ranges[i].largest < frame.ack.ranges[i].smallest)
                    return WireError.invalidFrame;

                if (frame.ack.ranges[i - 1].smallest < frame.ack.ranges[i].largest + 2)
                    return WireError.invalidFrame;

                const ulong gap = frame.ack.ranges[i - 1].smallest - frame.ack.ranges[i].largest - 2;
                const ulong rangeLen = frame.ack.ranges[i].largest - frame.ack.ranges[i].smallest;

                if (writer.writeVarInt(gap) != WireError.none)
                    return WireError.bufferTooSmall;
                if (writer.writeVarInt(rangeLen) != WireError.none)
                    return WireError.bufferTooSmall;
            }

            if (frame.ack.hasEcn)
            {
                if (writer.writeVarInt(frame.ack.ect0) != WireError.none)
                    return WireError.bufferTooSmall;
                if (writer.writeVarInt(frame.ack.ect1) != WireError.none)
                    return WireError.bufferTooSmall;
                if (writer.writeVarInt(frame.ack.ecnCe) != WireError.none)
                    return WireError.bufferTooSmall;
            }

            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.resetStream:
            if (writer.writeVarInt(0x04) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.resetStream.streamId) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.resetStream.applicationErrorCode) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.resetStream.finalSize) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.stopSending:
            if (writer.writeVarInt(0x05) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.stopSending.streamId) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.stopSending.applicationErrorCode) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.crypto:
            if (writer.writeVarInt(0x06) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.crypto.offset) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.crypto.data.length) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeBytes(frame.crypto.data) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.newToken:
            if (frame.newToken.token.length == 0)
                return WireError.invalidFrame;
            if (writer.writeVarInt(0x07) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.newToken.token.length) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeBytes(frame.newToken.token) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.stream0: .. case FrameType.stream7:
            const ulong typeByte = 0x08
                | (frame.stream.hasOffset ? 0x04 : 0)
                | (frame.stream.hasLength ? 0x02 : 0)
                | (frame.stream.fin ? 0x01 : 0);

            if (writer.writeVarInt(typeByte) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.stream.streamId) != WireError.none)
                return WireError.bufferTooSmall;
            if (frame.stream.hasOffset)
            {
                if (writer.writeVarInt(frame.stream.offset) != WireError.none)
                    return WireError.bufferTooSmall;
            }
            if (frame.stream.hasLength)
            {
                if (writer.writeVarInt(frame.stream.data.length) != WireError.none)
                    return WireError.bufferTooSmall;
            }
            if (writer.writeBytes(frame.stream.data) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.maxData:
            if (writer.writeVarInt(0x10) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.maxData.maximumData) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.maxStreamData:
            if (writer.writeVarInt(0x11) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.maxStreamData.streamId) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.maxStreamData.maximumStreamData) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.maxStreamsBidi:
        case FrameType.maxStreamsUni:
            const ulong msType = frame.maxStreams.isBidirectional ? 0x12 : 0x13;
            if (writer.writeVarInt(msType) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.maxStreams.maximumStreams) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.dataBlocked:
            if (writer.writeVarInt(0x14) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.dataBlocked.maximumData) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.streamDataBlocked:
            if (writer.writeVarInt(0x15) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.streamDataBlocked.streamId) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.streamDataBlocked.maximumStreamData) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.streamsBlockedBidi:
        case FrameType.streamsBlockedUni:
            const ulong sbType = frame.streamsBlocked.isBidirectional ? 0x16 : 0x17;
            if (writer.writeVarInt(sbType) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.streamsBlocked.streamLimit) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.newConnectionId:
            if (writer.writeVarInt(0x18) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.newConnectionId.sequenceNumber) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.newConnectionId.retirePriorTo) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeU8(frame.newConnectionId.cid.len) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeBytes(frame.newConnectionId.cid.asSlice()) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeBytes(frame.newConnectionId.statelessResetToken[]) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.retireConnectionId:
            if (writer.writeVarInt(0x19) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.retireConnectionId.sequenceNumber) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.pathChallenge:
            if (writer.writeVarInt(0x1a) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeBytes(frame.pathChallenge.data[]) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.pathResponse:
            if (writer.writeVarInt(0x1b) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeBytes(frame.pathResponse.data[]) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.connectionCloseQuic:
        case FrameType.connectionCloseApp:
            const ulong ccType = frame.connectionClose.isApplication ? 0x1d : 0x1c;
            if (writer.writeVarInt(ccType) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeVarInt(frame.connectionClose.errorCode) != WireError.none)
                return WireError.bufferTooSmall;
            if (!frame.connectionClose.isApplication)
            {
                if (writer.writeVarInt(frame.connectionClose.frameType) != WireError.none)
                    return WireError.bufferTooSmall;
            }
            if (writer.writeVarInt(frame.connectionClose.reasonPhrase.length) != WireError.none)
                return WireError.bufferTooSmall;
            if (writer.writeBytes(cast(const(ubyte)[]) frame.connectionClose.reasonPhrase) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        case FrameType.handshakeDone:
            if (writer.writeVarInt(0x1e) != WireError.none)
                return WireError.bufferTooSmall;
            bytesWritten = writer.bytesWritten;
            return WireError.none;

        default:
            return WireError.invalidFrame;
    }
}

/**
 * Decodes a single QUIC frame from wire format (RFC 9000 Section 19).
 */
WireError decodeFrame(
    const(ubyte)[] inBuf,
    out Frame frame,
    out size_t bytesRead,
    out TransportErrorCode err
) @safe pure @nogc nothrow
{
    frame = Frame.init;
    bytesRead = 0;
    err = TransportErrorCode.noError;

    if (inBuf.length == 0)
        return WireError.unexpectedEof;

    WireReader reader = WireReader(inBuf);
    ulong rawType = 0;
    WireError wErr = reader.readVarInt(rawType);
    if (wErr != WireError.none)
        return wErr;

    // Handle PADDING run (0x00)
    if (rawType == 0x00)
    {
        frame.type = FrameType.padding;
        size_t count = 1;
        ubyte nextB = 0;
        while (reader.peekU8(nextB) == WireError.none && nextB == 0x00)
        {
            reader.readU8(nextB);
            count++;
        }
        frame.padding.length = count;
        bytesRead = reader.position;
        return WireError.none;
    }

    if (rawType >= 0x08 && rawType <= 0x0f)
    {
        frame.type = FrameType.stream;
        const bool hasOff = (rawType & 0x04) != 0;
        const bool hasLen = (rawType & 0x02) != 0;
        const bool fin = (rawType & 0x01) != 0;

        frame.stream.hasOffset = hasOff;
        frame.stream.hasLength = hasLen;
        frame.stream.fin = fin;

        wErr = reader.readVarInt(frame.stream.streamId);
        if (wErr != WireError.none)
            return wErr;

        if (hasOff)
        {
            wErr = reader.readVarInt(frame.stream.offset);
            if (wErr != WireError.none)
                return wErr;
        }

        if (hasLen)
        {
            ulong dataLen = 0;
            wErr = reader.readVarInt(dataLen);
            if (wErr != WireError.none)
                return wErr;

            wErr = reader.readSlice(cast(size_t) dataLen, frame.stream.data);
            if (wErr != WireError.none)
                return wErr;
        }
        else
        {
            // Consumes remaining bytes in packet payload
            frame.stream.data = reader.unreadSlice;
            reader.readSlice(reader.remaining, frame.stream.data);
        }

        // RFC 9000 Section 19.8: offset + length must not exceed 2^62 - 1
        if (frame.stream.offset > VARINT_MAX || frame.stream.data.length > VARINT_MAX - frame.stream.offset)
        {
            err = TransportErrorCode.frameEncodingError;
            return WireError.invalidFrame;
        }

        bytesRead = reader.position;
        return WireError.none;
    }

    frame.type = cast(FrameType) rawType;
    switch (rawType)
    {
        case 0x01: // PING
            frame.type = FrameType.ping;
            bytesRead = reader.position;
            return WireError.none;

        case 0x02: // ACK
        case 0x03: // ACK_ECN
            frame.type = (rawType == 0x03) ? FrameType.ackEcn : FrameType.ack;
            frame.ack.hasEcn = (rawType == 0x03);

            ulong largestAcked = 0;
            wErr = reader.readVarInt(largestAcked);
            if (wErr != WireError.none)
                return wErr;

            wErr = reader.readVarInt(frame.ack.ackDelay);
            if (wErr != WireError.none)
                return wErr;

            ulong rangeCount = 0;
            wErr = reader.readVarInt(rangeCount);
            if (wErr != WireError.none)
                return wErr;

            ulong firstRange = 0;
            wErr = reader.readVarInt(firstRange);
            if (wErr != WireError.none)
                return wErr;

            if (firstRange > largestAcked)
            {
                err = TransportErrorCode.frameEncodingError;
                return WireError.invalidFrame;
            }

            frame.ack.ranges[0] = AckRange(largestAcked - firstRange, largestAcked);
            frame.ack.numRanges = 1;

            ulong curSmallest = frame.ack.ranges[0].smallest;
            foreach (i; 0 .. rangeCount)
            {
                ulong gap = 0;
                wErr = reader.readVarInt(gap);
                if (wErr != WireError.none)
                    return wErr;

                ulong rangeLen = 0;
                wErr = reader.readVarInt(rangeLen);
                if (wErr != WireError.none)
                    return wErr;

                if (curSmallest < 2 || gap + 2 > curSmallest)
                {
                    err = TransportErrorCode.frameEncodingError;
                    return WireError.invalidFrame;
                }

                const ulong nextLargest = curSmallest - gap - 2;
                if (rangeLen > nextLargest)
                {
                    err = TransportErrorCode.frameEncodingError;
                    return WireError.invalidFrame;
                }

                const ulong nextSmallest = nextLargest - rangeLen;
                if (frame.ack.numRanges < MAX_ACK_RANGES)
                {
                    frame.ack.ranges[frame.ack.numRanges++] = AckRange(nextSmallest, nextLargest);
                }
                curSmallest = nextSmallest;
            }

            if (frame.ack.hasEcn)
            {
                wErr = reader.readVarInt(frame.ack.ect0);
                if (wErr != WireError.none)
                    return wErr;
                wErr = reader.readVarInt(frame.ack.ect1);
                if (wErr != WireError.none)
                    return wErr;
                wErr = reader.readVarInt(frame.ack.ecnCe);
                if (wErr != WireError.none)
                    return wErr;
            }

            bytesRead = reader.position;
            return WireError.none;

        case 0x04: // RESET_STREAM
            frame.type = FrameType.resetStream;
            wErr = reader.readVarInt(frame.resetStream.streamId);
            if (wErr != WireError.none)
                return wErr;
            wErr = reader.readVarInt(frame.resetStream.applicationErrorCode);
            if (wErr != WireError.none)
                return wErr;
            wErr = reader.readVarInt(frame.resetStream.finalSize);
            if (wErr != WireError.none)
                return wErr;
            bytesRead = reader.position;
            return WireError.none;

        case 0x05: // STOP_SENDING
            frame.type = FrameType.stopSending;
            wErr = reader.readVarInt(frame.stopSending.streamId);
            if (wErr != WireError.none)
                return wErr;
            wErr = reader.readVarInt(frame.stopSending.applicationErrorCode);
            if (wErr != WireError.none)
                return wErr;
            bytesRead = reader.position;
            return WireError.none;

        case 0x06: // CRYPTO
            frame.type = FrameType.crypto;
            wErr = reader.readVarInt(frame.crypto.offset);
            if (wErr != WireError.none)
                return wErr;

            ulong dataLen = 0;
            wErr = reader.readVarInt(dataLen);
            if (wErr != WireError.none)
                return wErr;

            wErr = reader.readSlice(cast(size_t) dataLen, frame.crypto.data);
            if (wErr != WireError.none)
                return wErr;

            if (frame.crypto.offset > VARINT_MAX || frame.crypto.data.length > VARINT_MAX - frame.crypto.offset)
            {
                err = TransportErrorCode.frameEncodingError;
                return WireError.invalidFrame;
            }

            bytesRead = reader.position;
            return WireError.none;

        case 0x07: // NEW_TOKEN
            frame.type = FrameType.newToken;
            ulong tokLen = 0;
            wErr = reader.readVarInt(tokLen);
            if (wErr != WireError.none)
                return wErr;

            if (tokLen == 0)
            {
                err = TransportErrorCode.frameEncodingError;
                return WireError.invalidFrame;
            }

            wErr = reader.readSlice(cast(size_t) tokLen, frame.newToken.token);
            if (wErr != WireError.none)
                return wErr;

            bytesRead = reader.position;
            return WireError.none;

        case 0x10: // MAX_DATA
            frame.type = FrameType.maxData;
            wErr = reader.readVarInt(frame.maxData.maximumData);
            if (wErr != WireError.none)
                return wErr;
            bytesRead = reader.position;
            return WireError.none;

        case 0x11: // MAX_STREAM_DATA
            frame.type = FrameType.maxStreamData;
            wErr = reader.readVarInt(frame.maxStreamData.streamId);
            if (wErr != WireError.none)
                return wErr;
            wErr = reader.readVarInt(frame.maxStreamData.maximumStreamData);
            if (wErr != WireError.none)
                return wErr;
            bytesRead = reader.position;
            return WireError.none;

        case 0x12: // MAX_STREAMS_BIDI
        case 0x13: // MAX_STREAMS_UNI
            frame.type = (rawType == 0x12) ? FrameType.maxStreamsBidi : FrameType.maxStreamsUni;
            frame.maxStreams.isBidirectional = (rawType == 0x12);
            wErr = reader.readVarInt(frame.maxStreams.maximumStreams);
            if (wErr != WireError.none)
                return wErr;

            // RFC 9000 Section 19.11: stream count > 2^60 is invalid
            if (frame.maxStreams.maximumStreams > (1UL << 60))
            {
                err = TransportErrorCode.frameEncodingError;
                return WireError.invalidFrame;
            }
            bytesRead = reader.position;
            return WireError.none;

        case 0x14: // DATA_BLOCKED
            frame.type = FrameType.dataBlocked;
            wErr = reader.readVarInt(frame.dataBlocked.maximumData);
            if (wErr != WireError.none)
                return wErr;
            bytesRead = reader.position;
            return WireError.none;

        case 0x15: // STREAM_DATA_BLOCKED
            frame.type = FrameType.streamDataBlocked;
            wErr = reader.readVarInt(frame.streamDataBlocked.streamId);
            if (wErr != WireError.none)
                return wErr;
            wErr = reader.readVarInt(frame.streamDataBlocked.maximumStreamData);
            if (wErr != WireError.none)
                return wErr;
            bytesRead = reader.position;
            return WireError.none;

        case 0x16: // STREAMS_BLOCKED_BIDI
        case 0x17: // STREAMS_BLOCKED_UNI
            frame.type = (rawType == 0x16) ? FrameType.streamsBlockedBidi : FrameType.streamsBlockedUni;
            frame.streamsBlocked.isBidirectional = (rawType == 0x16);
            wErr = reader.readVarInt(frame.streamsBlocked.streamLimit);
            if (wErr != WireError.none)
                return wErr;

            // RFC 9000 Section 19.14: stream limit > 2^60 is invalid
            if (frame.streamsBlocked.streamLimit > (1UL << 60))
            {
                err = TransportErrorCode.frameEncodingError;
                return WireError.invalidFrame;
            }
            bytesRead = reader.position;
            return WireError.none;

        case 0x18: // NEW_CONNECTION_ID
            frame.type = FrameType.newConnectionId;
            wErr = reader.readVarInt(frame.newConnectionId.sequenceNumber);
            if (wErr != WireError.none)
                return wErr;

            wErr = reader.readVarInt(frame.newConnectionId.retirePriorTo);
            if (wErr != WireError.none)
                return wErr;

            if (frame.newConnectionId.retirePriorTo > frame.newConnectionId.sequenceNumber)
            {
                err = TransportErrorCode.frameEncodingError;
                return WireError.invalidFrame;
            }

            ubyte cidLen = 0;
            wErr = reader.readU8(cidLen);
            if (wErr != WireError.none)
                return wErr;

            if (cidLen == 0 || cidLen > MAX_CID_LEN)
            {
                err = TransportErrorCode.frameEncodingError;
                return WireError.invalidFrame;
            }

            const(ubyte)[] cidSlice;
            wErr = reader.readSlice(cidLen, cidSlice);
            if (wErr != WireError.none)
                return wErr;
            frame.newConnectionId.cid = ConnectionId(cidSlice);

            wErr = reader.readBytes(frame.newConnectionId.statelessResetToken[]);
            if (wErr != WireError.none)
                return wErr;

            bytesRead = reader.position;
            return WireError.none;

        case 0x19: // RETIRE_CONNECTION_ID
            frame.type = FrameType.retireConnectionId;
            wErr = reader.readVarInt(frame.retireConnectionId.sequenceNumber);
            if (wErr != WireError.none)
                return wErr;
            bytesRead = reader.position;
            return WireError.none;

        case 0x1a: // PATH_CHALLENGE
            frame.type = FrameType.pathChallenge;
            wErr = reader.readBytes(frame.pathChallenge.data[]);
            if (wErr != WireError.none)
                return wErr;
            bytesRead = reader.position;
            return WireError.none;

        case 0x1b: // PATH_RESPONSE
            frame.type = FrameType.pathResponse;
            wErr = reader.readBytes(frame.pathResponse.data[]);
            if (wErr != WireError.none)
                return wErr;
            bytesRead = reader.position;
            return WireError.none;

        case 0x1c: // CONNECTION_CLOSE (QUIC)
        case 0x1d: // CONNECTION_CLOSE (Application)
            frame.type = (rawType == 0x1c) ? FrameType.connectionCloseQuic : FrameType.connectionCloseApp;
            frame.connectionClose.isApplication = (rawType == 0x1d);

            wErr = reader.readVarInt(frame.connectionClose.errorCode);
            if (wErr != WireError.none)
                return wErr;

            if (!frame.connectionClose.isApplication)
            {
                wErr = reader.readVarInt(frame.connectionClose.frameType);
                if (wErr != WireError.none)
                    return wErr;
            }

            ulong reasonLen = 0;
            wErr = reader.readVarInt(reasonLen);
            if (wErr != WireError.none)
                return wErr;

            const(ubyte)[] reasonSlice;
            wErr = reader.readSlice(cast(size_t) reasonLen, reasonSlice);
            if (wErr != WireError.none)
                return wErr;
            frame.connectionClose.reasonPhrase = cast(const(char)[]) reasonSlice;

            bytesRead = reader.position;
            return WireError.none;

        case 0x1e: // HANDSHAKE_DONE
            frame.type = FrameType.handshakeDone;
            bytesRead = reader.position;
            return WireError.none;

        default:
            err = TransportErrorCode.frameEncodingError;
            return WireError.invalidFrame;
    }
}

/**
 * Sequential iterator for parsing frames from decrypted packet payload.
 */
public struct FrameIterator
{
private:
    const(ubyte)[] m_payload;
    PacketType m_packetType;

public:
    this(const(ubyte)[] payload, PacketType packetType) @safe pure @nogc nothrow
    {
        m_payload = payload;
        m_packetType = packetType;
    }

    @property bool empty() const @safe pure @nogc nothrow
    {
        return m_payload.length == 0;
    }

    bool next(
        out Frame frame,
        out WireError wireErr,
        out TransportErrorCode te
    ) @safe pure @nogc nothrow
    {
        frame = Frame.init;
        wireErr = WireError.none;
        te = TransportErrorCode.noError;

        if (m_payload.length == 0)
            return false;

        size_t bytesRead = 0;
        wireErr = decodeFrame(m_payload, frame, bytesRead, te);
        if (wireErr != WireError.none)
            return false;

        te = validateFrameInPacket(frame.type, m_packetType);
        if (te != TransportErrorCode.noError)
        {
            wireErr = WireError.forbiddenFrameInPacket;
            return false;
        }

        m_payload = m_payload[bytesRead .. $];
        return true;
    }
}

/// Example:
// Spec: RFC 9000 Section 19 - Frame Types Round-Trip & ACK Compression (covers U1, U2, U3, E3, Scenario T3)
@nogc unittest
{
    ubyte[512] buf;
    size_t written = 0;
    size_t readLen = 0;
    TransportErrorCode te;
    Frame outFrame;

    // 1. PADDING
    Frame pad;
    pad.type = FrameType.padding;
    pad.padding.length = 5;
    assert(encodeFrame(pad, buf[], written) == WireError.none);
    assert(written == 5);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.padding);
    assert(outFrame.padding.length == 5);

    // 2. PING
    Frame ping;
    ping.type = FrameType.ping;
    assert(encodeFrame(ping, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.ping);

    // 3. Multi-range ACK with ECN: ranges [10..12], [5..7], [0..2]
    Frame ack;
    ack.type = FrameType.ackEcn;
    ack.ack.hasEcn = true;
    ack.ack.ackDelay = 25;
    ack.ack.numRanges = 3;
    ack.ack.ranges[0] = AckRange(10, 12);
    ack.ack.ranges[1] = AckRange(5, 7);
    ack.ack.ranges[2] = AckRange(0, 2);
    ack.ack.ect0 = 100;
    ack.ack.ect1 = 200;
    ack.ack.ecnCe = 300;
    assert(encodeFrame(ack, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.ackEcn);
    assert(outFrame.ack.hasEcn);
    assert(outFrame.ack.ackDelay == 25);
    assert(outFrame.ack.numRanges == 3);
    assert(outFrame.ack.ranges[0] == AckRange(10, 12));
    assert(outFrame.ack.ranges[1] == AckRange(5, 7));
    assert(outFrame.ack.ranges[2] == AckRange(0, 2));
    assert(outFrame.ack.ect0 == 100);
    assert(outFrame.ack.ect1 == 200);
    assert(outFrame.ack.ecnCe == 300);

    // 4. RESET_STREAM
    Frame rst;
    rst.type = FrameType.resetStream;
    rst.resetStream.streamId = 4;
    rst.resetStream.applicationErrorCode = 0x101;
    rst.resetStream.finalSize = 1024;
    assert(encodeFrame(rst, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.resetStream);
    assert(outFrame.resetStream.streamId == 4);
    assert(outFrame.resetStream.applicationErrorCode == 0x101);
    assert(outFrame.resetStream.finalSize == 1024);

    // 5. STOP_SENDING
    Frame stop;
    stop.type = FrameType.stopSending;
    stop.stopSending.streamId = 8;
    stop.stopSending.applicationErrorCode = 0x202;
    assert(encodeFrame(stop, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.stopSending);
    assert(outFrame.stopSending.streamId == 8);
    assert(outFrame.stopSending.applicationErrorCode == 0x202);

    // 6. CRYPTO
    Frame cr;
    cr.type = FrameType.crypto;
    cr.crypto.offset = 100;
    cr.crypto.data = cast(const(ubyte)[]) "QUIC TLS DATA";
    assert(encodeFrame(cr, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.crypto);
    assert(outFrame.crypto.offset == 100);
    assert(outFrame.crypto.data == cast(const(ubyte)[]) "QUIC TLS DATA");

    // 7. NEW_TOKEN
    Frame tok;
    tok.type = FrameType.newToken;
    tok.newToken.token = cast(const(ubyte)[]) "token12345";
    assert(encodeFrame(tok, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.newToken);
    assert(outFrame.newToken.token == cast(const(ubyte)[]) "token12345");

    // 8. STREAM all 8 permutations (OFF, LEN, FIN): 0x08 .. 0x0f
    foreach (perm; 0 .. 8)
    {
        const bool hasOff = (perm & 0x04) != 0;
        const bool hasLen = (perm & 0x02) != 0;
        const bool fin = (perm & 0x01) != 0;

        Frame stm;
        stm.type = FrameType.stream;
        stm.stream.streamId = 1;
        stm.stream.hasOffset = hasOff;
        stm.stream.offset = hasOff ? 50 : 0;
        stm.stream.hasLength = hasLen;
        stm.stream.fin = fin;
        stm.stream.data = cast(const(ubyte)[]) "STREAM PAYLOAD";

        assert(encodeFrame(stm, buf[], written) == WireError.none);
        assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
        assert(outFrame.type == FrameType.stream);
        assert(outFrame.stream.streamId == 1);
        assert(outFrame.stream.hasOffset == hasOff);
        assert(outFrame.stream.offset == (hasOff ? 50 : 0));
        assert(outFrame.stream.hasLength == hasLen);
        assert(outFrame.stream.fin == fin);
        assert(outFrame.stream.data == cast(const(ubyte)[]) "STREAM PAYLOAD");
    }

    // ACK encode underflow guard: largest < smallest
    Frame badAck;
    badAck.type = FrameType.ack;
    badAck.ack.numRanges = 1;
    badAck.ack.ranges[0] = AckRange(10, 5); // largest 5 < smallest 10!
    assert(encodeFrame(badAck, buf[], written) == WireError.invalidFrame);

    badAck.ack.ranges[0] = AckRange(5, 10);
    badAck.ack.numRanges = 2;
    badAck.ack.ranges[1] = AckRange(4, 2); // largest 2 < smallest 4!
    assert(encodeFrame(badAck, buf[], written) == WireError.invalidFrame);

    // 9. MAX_DATA
    Frame md;
    md.type = FrameType.maxData;
    md.maxData.maximumData = 1_000_000;
    assert(encodeFrame(md, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.maxData);
    assert(outFrame.maxData.maximumData == 1_000_000);

    // 10. MAX_STREAM_DATA
    Frame msd;
    msd.type = FrameType.maxStreamData;
    msd.maxStreamData.streamId = 2;
    msd.maxStreamData.maximumStreamData = 500_000;
    assert(encodeFrame(msd, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.maxStreamData);
    assert(outFrame.maxStreamData.streamId == 2);
    assert(outFrame.maxStreamData.maximumStreamData == 500_000);

    // 11. MAX_STREAMS
    Frame ms;
    ms.type = FrameType.maxStreamsBidi;
    ms.maxStreams.isBidirectional = true;
    ms.maxStreams.maximumStreams = 100;
    assert(encodeFrame(ms, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.maxStreamsBidi);
    assert(outFrame.maxStreams.isBidirectional);
    assert(outFrame.maxStreams.maximumStreams == 100);

    // 12. DATA_BLOCKED
    Frame db;
    db.type = FrameType.dataBlocked;
    db.dataBlocked.maximumData = 2_000_000;
    assert(encodeFrame(db, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.dataBlocked);
    assert(outFrame.dataBlocked.maximumData == 2_000_000);

    // 13. STREAM_DATA_BLOCKED
    Frame sdb;
    sdb.type = FrameType.streamDataBlocked;
    sdb.streamDataBlocked.streamId = 3;
    sdb.streamDataBlocked.maximumStreamData = 250_000;
    assert(encodeFrame(sdb, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.streamDataBlocked);
    assert(outFrame.streamDataBlocked.streamId == 3);
    assert(outFrame.streamDataBlocked.maximumStreamData == 250_000);

    // 14. STREAMS_BLOCKED
    Frame sb;
    sb.type = FrameType.streamsBlockedUni;
    sb.streamsBlocked.isBidirectional = false;
    sb.streamsBlocked.streamLimit = 50;
    assert(encodeFrame(sb, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.streamsBlockedUni);
    assert(!outFrame.streamsBlocked.isBidirectional);
    assert(outFrame.streamsBlocked.streamLimit == 50);

    // 15. NEW_CONNECTION_ID
    const ubyte[8] newCidBytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11];
    Frame ncid;
    ncid.type = FrameType.newConnectionId;
    ncid.newConnectionId.sequenceNumber = 5;
    ncid.newConnectionId.retirePriorTo = 2;
    ncid.newConnectionId.cid = ConnectionId(newCidBytes[]);
    ncid.newConnectionId.statelessResetToken[] = 0x5a;
    assert(encodeFrame(ncid, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.newConnectionId);
    assert(outFrame.newConnectionId.sequenceNumber == 5);
    assert(outFrame.newConnectionId.retirePriorTo == 2);
    assert(outFrame.newConnectionId.cid == ConnectionId(newCidBytes[]));
    assert(outFrame.newConnectionId.statelessResetToken == ncid.newConnectionId.statelessResetToken);

    // 16. RETIRE_CONNECTION_ID
    Frame rcid;
    rcid.type = FrameType.retireConnectionId;
    rcid.retireConnectionId.sequenceNumber = 2;
    assert(encodeFrame(rcid, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.retireConnectionId);
    assert(outFrame.retireConnectionId.sequenceNumber == 2);

    // 17. PATH_CHALLENGE
    Frame pc;
    pc.type = FrameType.pathChallenge;
    pc.pathChallenge.data = [1, 2, 3, 4, 5, 6, 7, 8];
    assert(encodeFrame(pc, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.pathChallenge);
    assert(outFrame.pathChallenge.data == pc.pathChallenge.data);

    // 18. PATH_RESPONSE
    Frame pr;
    pr.type = FrameType.pathResponse;
    pr.pathResponse.data = [8, 7, 6, 5, 4, 3, 2, 1];
    assert(encodeFrame(pr, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.pathResponse);
    assert(outFrame.pathResponse.data == pr.pathResponse.data);

    // 19. CONNECTION_CLOSE
    Frame cc;
    cc.type = FrameType.connectionCloseQuic;
    cc.connectionClose.isApplication = false;
    cc.connectionClose.errorCode = cast(ulong) TransportErrorCode.flowControlError;
    cc.connectionClose.frameType = cast(ulong) FrameType.stream;
    cc.connectionClose.reasonPhrase = "flow control exceeded";
    assert(encodeFrame(cc, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.connectionCloseQuic);
    assert(outFrame.connectionClose.errorCode == cast(ulong) TransportErrorCode.flowControlError);
    assert(outFrame.connectionClose.frameType == cast(ulong) FrameType.stream);
    assert(outFrame.connectionClose.reasonPhrase == "flow control exceeded");

    // 20. HANDSHAKE_DONE
    Frame hd;
    hd.type = FrameType.handshakeDone;
    assert(encodeFrame(hd, buf[], written) == WireError.none);
    assert(decodeFrame(buf[0 .. written], outFrame, readLen, te) == WireError.none);
    assert(outFrame.type == FrameType.handshakeDone);
}

/// Example:
// Spec: RFC 9000 Section 12.4 & Section 19 - Frame Semantics, Packet Constraints & Truncation (covers W2, W3, G4, Scenario W3)
@nogc unittest
{
    ubyte[128] buf;
    size_t written = 0;
    Frame outF;
    size_t readLen = 0;
    TransportErrorCode te;

    // 1. ACK Range underflow: firstAckRange > largestAcked
    WireWriter writer = WireWriter(buf[]);
    writer.writeVarInt(0x02); // ACK
    writer.writeVarInt(5);    // largestAcked = 5
    writer.writeVarInt(0);    // ackDelay = 0
    writer.writeVarInt(0);    // rangeCount = 0
    writer.writeVarInt(10);   // firstRange = 10 > largestAcked 5!
    assert(decodeFrame(writer.writtenSlice, outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 2. NEW_CONNECTION_ID with retirePriorTo > sequenceNumber
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x18);
    writer.writeVarInt(2);    // seq = 2
    writer.writeVarInt(5);    // retirePriorTo = 5 > seq!
    writer.writeU8(8);        // cidLen
    static const ubyte[8] dummyCid = [1, 2, 3, 4, 5, 6, 7, 8];
    static const ubyte[16] dummyToken = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    writer.writeBytes(dummyCid[]);
    writer.writeBytes(dummyToken[]);
    assert(decodeFrame(writer.writtenSlice, outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 3. NEW_CONNECTION_ID with cidLen == 0
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x18);
    writer.writeVarInt(2);
    writer.writeVarInt(1);
    writer.writeU8(0);        // cidLen = 0!
    assert(decodeFrame(writer.writtenSlice, outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 4. MAX_STREAMS > 2^60
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x12);
    writer.writeVarInt((1UL << 60) + 1);
    assert(decodeFrame(writer.writtenSlice, outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 5. NEW_TOKEN empty
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x07);
    writer.writeVarInt(0);    // token length = 0!
    assert(decodeFrame(writer.writtenSlice, outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 6. Packet type legality check (RFC 9000 Section 12.4 Table 3)
    assert(validateFrameInPacket(FrameType.stream, PacketType.initial) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.handshakeDone, PacketType.initial) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.crypto, PacketType.initial) == TransportErrorCode.noError);

    // 0-RTT frame checks per RFC 9000 Table 3 (DEFECT-1)
    assert(validateFrameInPacket(FrameType.newConnectionId, PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.retireConnectionId, PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.pathChallenge, PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.connectionCloseQuic, PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.connectionCloseApp, PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.stream, PacketType.zeroRtt) == TransportErrorCode.noError);

    assert(validateFrameInPacket(FrameType.ack, PacketType.zeroRtt) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.crypto, PacketType.zeroRtt) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.pathResponse, PacketType.zeroRtt) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.newToken, PacketType.zeroRtt) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.handshakeDone, PacketType.zeroRtt) == TransportErrorCode.protocolViolation);

    // 1-RTT short header checks (DEFECT-1)
    assert(validateFrameInPacket(FrameType.stream, PacketType.oneRttShort) == TransportErrorCode.noError);
    assert(validateFrameInPacket(cast(FrameType) 0x1f, PacketType.oneRttShort) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(cast(FrameType) 0x99, PacketType.oneRttShort) == TransportErrorCode.protocolViolation);

    // 7. G4 Truncation safety across frame prefixes (DEFECT-5)
    Frame rst;
    rst.type = FrameType.resetStream;
    rst.resetStream.streamId = 1;
    rst.resetStream.applicationErrorCode = 2;
    rst.resetStream.finalSize = 3;
    assert(encodeFrame(rst, buf[], written) == WireError.none);

    foreach (truncLen; 0 .. written)
    {
        Frame truncF;
        size_t tr;
        TransportErrorCode tErr;
        assert(decodeFrame(buf[0 .. truncLen], truncF, tr, tErr) == WireError.unexpectedEof);
    }
}
