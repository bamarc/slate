module slate.quic.wire.frame_test;

import slate.quic.wire.frame;
import slate.quic.wire.varint;
import slate.quic.wire.cid;
import slate.quic.wire.packet : PacketType;

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
    const ubyte[8] newCidBytes = [
        0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11
    ];
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
    writer.writeVarInt(5); // largestAcked = 5
    writer.writeVarInt(0); // ackDelay = 0
    writer.writeVarInt(0); // rangeCount = 0
    writer.writeVarInt(10); // firstRange = 10 > largestAcked 5!
    assert(decodeFrame(writer.writtenSlice, outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 2. NEW_CONNECTION_ID with retirePriorTo > sequenceNumber
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x18);
    writer.writeVarInt(2); // seq = 2
    writer.writeVarInt(5); // retirePriorTo = 5 > seq!
    writer.writeU8(8); // cidLen
    static const ubyte[8] dummyCid = [1, 2, 3, 4, 5, 6, 7, 8];
    static const ubyte[16] dummyToken = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ];
    writer.writeBytes(dummyCid[]);
    writer.writeBytes(dummyToken[]);
    assert(decodeFrame(writer.writtenSlice, outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 3. NEW_CONNECTION_ID with cidLen == 0
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x18);
    writer.writeVarInt(2);
    writer.writeVarInt(1);
    writer.writeU8(0); // cidLen = 0!
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
    writer.writeVarInt(0); // token length = 0!
    assert(decodeFrame(writer.writtenSlice, outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 6. Packet type legality check (RFC 9000 Section 12.4 Table 3)
    assert(validateFrameInPacket(FrameType.stream,
            PacketType.initial) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.handshakeDone,
            PacketType.initial) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.crypto, PacketType.initial) == TransportErrorCode
            .noError);

    // 0-RTT frame checks per RFC 9000 Table 3 (DEFECT-1)
    assert(validateFrameInPacket(FrameType.newConnectionId,
            PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.retireConnectionId,
            PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.pathChallenge,
            PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.connectionCloseQuic,
            PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.connectionCloseApp,
            PacketType.zeroRtt) == TransportErrorCode.noError);
    assert(validateFrameInPacket(FrameType.stream, PacketType.zeroRtt) == TransportErrorCode
            .noError);

    assert(validateFrameInPacket(FrameType.ack,
            PacketType.zeroRtt) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.crypto,
            PacketType.zeroRtt) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.pathResponse,
            PacketType.zeroRtt) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.newToken,
            PacketType.zeroRtt) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(FrameType.handshakeDone,
            PacketType.zeroRtt) == TransportErrorCode.protocolViolation);

    // 1-RTT short header checks (DEFECT-1)
    assert(validateFrameInPacket(FrameType.stream,
            PacketType.oneRttShort) == TransportErrorCode.noError);
    assert(validateFrameInPacket(cast(FrameType) 0x1f,
            PacketType.oneRttShort) == TransportErrorCode.protocolViolation);
    assert(validateFrameInPacket(cast(FrameType) 0x99,
            PacketType.oneRttShort) == TransportErrorCode.protocolViolation);

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

/// Example:
// Spec: RFC 9000 Section 19 / F-36, F-37, F-38, F-42 - Frame Encoding & Decoding Hardening
@nogc unittest
{
    ubyte[128] buf;
    size_t written = 0;
    Frame outF;
    size_t readLen = 0;
    TransportErrorCode te;

    // 1. Non-minimal frame-type varint rejection (F-42)
    // PING (0x01) encoded as 2-byte varint: 0x40, 0x01
    static immutable ubyte[2] nonMinimalPing = [0x40, 0x01];
    assert(decodeFrame(nonMinimalPing[], outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 2. Excess ACK ranges rejection on decode (F-42)
    WireWriter writer = WireWriter(buf[]);
    writer.writeVarInt(0x02); // ACK
    writer.writeVarInt(100); // largestAcked
    writer.writeVarInt(0); // ackDelay
    writer.writeVarInt(MAX_ACK_RANGES + 1); // excess ranges!
    assert(decodeFrame(writer.writtenSlice, outF, readLen, te) == WireError.invalidFrame);
    assert(te == TransportErrorCode.frameEncodingError);

    // 3. Excess ACK ranges rejection on encode (F-36)
    Frame excessAck;
    excessAck.type = FrameType.ack;
    excessAck.ack.numRanges = MAX_ACK_RANGES + 1;
    assert(encodeFrame(excessAck, buf[], written) == WireError.invalidFrame);

    // 4. Discriminant honoring (F-37)
    Frame uniStreams;
    uniStreams.type = FrameType.maxStreamsUni;
    uniStreams.maxStreams.isBidirectional = true; // contradictory flag must be overridden by type
    uniStreams.maxStreams.maximumStreams = 10;
    assert(encodeFrame(uniStreams, buf[], written) == WireError.none);
    assert(buf[0] == 0x13); // maxStreamsUni frame type byte

    Frame appClose;
    appClose.type = FrameType.connectionCloseApp;
    appClose.connectionClose.isApplication = false; // contradictory flag must be overridden
    appClose.connectionClose.errorCode = 42;
    appClose.connectionClose.reasonPhrase = "bye";
    assert(encodeFrame(appClose, buf[], written) == WireError.none);
    assert(buf[0] == 0x1d); // connectionCloseApp frame type byte

    // 5. Semantic encode rejection on invalid NEW_CONNECTION_ID (F-38)
    Frame badNcid;
    badNcid.type = FrameType.newConnectionId;
    badNcid.newConnectionId.sequenceNumber = 1;
    badNcid.newConnectionId.retirePriorTo = 2; // retirePriorTo > seq
    assert(encodeFrame(badNcid, buf[], written) == WireError.invalidFrame);

    // 6. Semantic encode rejection on MAX_STREAMS > 2^60 (F-38)
    Frame badMaxStreams;
    badMaxStreams.type = FrameType.maxStreamsBidi;
    badMaxStreams.maxStreams.maximumStreams = (1UL << 60) + 1;
    assert(encodeFrame(badMaxStreams, buf[], written) == WireError.invalidFrame);
}
