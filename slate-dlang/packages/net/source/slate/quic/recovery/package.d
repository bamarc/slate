module slate.quic.recovery;

/**
 * QUIC Loss Detection and Congestion Recovery (RFC 9002).
 *
 * Re-exports:
 * - slate.quic.recovery.ack_ranges: AckRangeSet descending tracking and AckFrame builder
 * - slate.quic.recovery.rtt: RttEstimator with RFC 9002 Section 5.3 calculations
 * - slate.quic.recovery.congestion: CongestionController with NewReno and single-reduction recovery
 * - slate.quic.recovery.loss_detection: LossDetector with packet/time threshold loss and PTO
 */

public import slate.quic.recovery.ack_ranges;
public import slate.quic.recovery.rtt;
public import slate.quic.recovery.congestion;
public import slate.quic.recovery.loss_detection;

import slate.quic.stream.send_buffer;
import slate.quic.stream.recv_buffer;
import slate.quic.stream.stream_map : StreamMap;
import slate.quic.stream.id : StreamId, StreamDirection;
import slate.quic.crypto.kdf : Side;
import slate.quic.wire.cid : TransportErrorCode;
import slate.quic.wire.frame : AckFrame;

/// Example:
// Spec: RFC 9000 Section 13.3 & RFC 9002 Section 6 - End-to-End Stream Retransmission and Loss Recovery Loop (covers U1, U2, U3, E1, E2, E4, E5, Scenario T1-T6)
@nogc unittest
{
    SendBuffer sendBuf;
    RecvBuffer recvBuf;
    LossDetector lossDetector;
    AckRangeSet ackRanges;

    // Sender queues 500 bytes with FIN
    ubyte[500] appData;
    foreach (i; 0 .. 500)
    {
        appData[i] = cast(ubyte)(i & 0xff);
    }
    assert(sendBuf.write(appData[], true));

    // Transmit packets 0..4 (100 bytes each)
    TransmitChunk chunk0, chunk1, chunk2, chunk3, chunk4;
    assert(sendBuf.pollTransmit(100, chunk0));
    lossDetector.onPacketSent(PacketNumberSpace.applicationData, 0, 100, true, true, 10_000);

    assert(sendBuf.pollTransmit(100, chunk1));
    lossDetector.onPacketSent(PacketNumberSpace.applicationData, 1, 100, true, true, 11_000);
    // (Packet 1 is dropped in transit)

    assert(sendBuf.pollTransmit(100, chunk2));
    lossDetector.onPacketSent(PacketNumberSpace.applicationData, 2, 100, true, true, 12_000);

    assert(sendBuf.pollTransmit(100, chunk3));
    lossDetector.onPacketSent(PacketNumberSpace.applicationData, 3, 100, true, true, 13_000);

    assert(sendBuf.pollTransmit(100, chunk4));
    lossDetector.onPacketSent(PacketNumberSpace.applicationData, 4, 100, true, true, 14_000);

    // Receiver ingests packets 0, 2, 3, 4
    assert(recvBuf.ingest(chunk0.offset, chunk0.data, chunk0.fin) == TransportErrorCode.noError);
    assert(ackRanges.insert(0, true, 20_000));

    assert(recvBuf.ingest(chunk2.offset, chunk2.data, chunk2.fin) == TransportErrorCode.noError);
    assert(ackRanges.insert(2, true, 22_000));

    assert(recvBuf.ingest(chunk3.offset, chunk3.data, chunk3.fin) == TransportErrorCode.noError);
    assert(ackRanges.insert(3, true, 23_000));

    assert(recvBuf.ingest(chunk4.offset, chunk4.data, chunk4.fin) == TransportErrorCode.noError);
    assert(ackRanges.insert(4, true, 24_000));

    // Receiver can only read 100 bytes so far due to gap at [100..200]
    assert(recvBuf.readableBytes() == 100);

    // Receiver generates ACK frame
    AckFrame ack;
    assert(ackRanges.buildAckFrame(25_000, 3, ack));
    assert(ack.largestAcknowledged == 4);

    // Sender processes ACK frame
    SentPacketInfo[8] newlyAcked;
    size_t ackedCount = 0;
    SentPacketInfo[8] newlyLost;
    size_t lostCount = 0;

    assert(lossDetector.onAckReceived(PacketNumberSpace.applicationData, ack, 3,
            25_000, true, 30_000, newlyAcked[], ackedCount, newlyLost[], lostCount) == TransportErrorCode
            .noError);

    // Packet 1 declared lost via kPacketThreshold = 3 (4 - 1 >= 3)
    assert(lostCount == 1);
    assert(newlyLost[0].pn == 1);

    // Sender notifies SendBuffer of acked ranges
    sendBuf.onRangeAcked(chunk0.offset, chunk0.data.length, chunk0.fin);
    sendBuf.onRangeAcked(chunk2.offset, chunk2.data.length, chunk2.fin);
    sendBuf.onRangeAcked(chunk3.offset, chunk3.data.length, chunk3.fin);
    sendBuf.onRangeAcked(chunk4.offset, chunk4.data.length, chunk4.fin);

    // Sender notifies SendBuffer of lost packet 1 [100..200]
    sendBuf.onRangeLost(100, 100, false);

    // Sender retransmits lost range as packet 5
    TransmitChunk chunkRetransmit;
    assert(sendBuf.pollTransmit(100, chunkRetransmit));
    assert(chunkRetransmit.offset == 100);
    assert(chunkRetransmit.data.length == 100);
    lossDetector.onPacketSent(PacketNumberSpace.applicationData, 5, 100, true, true, 31_000);

    // Receiver ingests packet 5
    assert(recvBuf.ingest(chunkRetransmit.offset, chunkRetransmit.data,
            chunkRetransmit.fin) == TransportErrorCode.noError);
    assert(ackRanges.insert(5, true, 40_000));

    // Receiver now has full contiguous 500 bytes and FIN!
    assert(recvBuf.readableBytes() == 500);

    ubyte[512] receivedMessage;
    bool finReached = false;
    size_t bytesRead = recvBuf.read(receivedMessage[], finReached);
    assert(bytesRead == 500);
    assert(finReached);
    assert(receivedMessage[0 .. bytesRead] == appData[]);

    // Sender gets final ACK for retransmission
    sendBuf.onRangeAcked(100, 100, false);
    assert(sendBuf.isAllAcked);
}

/// Example:
// Best practice: High-Iteration Creation/Destruction and Memory Cleanup (covers U2, G4)
@nogc unittest
{
    foreach (iter; 0 .. 1000)
    {
        RecvBuffer rbuf;
        ubyte[4] chunk = [1, 2, 3, 4];
        assert(rbuf.ingest(0, chunk[], false) == TransportErrorCode.noError);

        SendBuffer sbuf;
        assert(sbuf.write(chunk[], true));

        StreamMap smap = StreamMap(Side.client, 65536, 16384, 16384, 16384, 16, 16, 16, 16);
        StreamId sid;
        assert(smap.openLocalStream(StreamDirection.bidirectional,
                sid) == TransportErrorCode.noError);

        LossDetector ld;
        ld.onPacketSent(PacketNumberSpace.applicationData, 0, 1200, true, true, 1000);
    }
}
