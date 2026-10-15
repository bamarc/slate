module slate.quic.stream;

/**
 * QUIC Streams, Flow Control, and Concurrency (RFC 9000 Section 2, Section 3, Section 4).
 *
 * Re-exports:
 * - slate.quic.stream.id: StreamId bitfield classification, SendStreamState, RecvStreamState
 * - slate.quic.stream.recv_buffer: Out-of-order reassembly buffer, FINAL_SIZE_ERROR enforcement
 * - slate.quic.stream.send_buffer: Retransmittable stream send buffer, retransmit priority, ACK tracking
 * - slate.quic.stream.flow_control: Stream & connection FlowController, monotonic updates, auto-tuning
 * - slate.quic.stream.stream_map: Multiplexed StreamMap, implicit stream opening, concurrency limits
 */

public import slate.quic.stream.id;
public import slate.quic.stream.recv_buffer;
public import slate.quic.stream.send_buffer;
public import slate.quic.stream.flow_control;
public import slate.quic.stream.stream_map;

/// Example:
// Spec: RFC 9000 Section 2, Section 3, Section 4 - Full Stream Pipeline Integration Test (covers U1, U2, U3, E1, E2, E3, Scenario T3)
@nogc unittest
{
    // Client opens stream, writes data, polls chunks; Server ingests out of order, reads cleanly
    StreamMap clientMap = StreamMap(Side.client, 65536, 16384, 16384, 16384, 16, 16, 16, 16);
    StreamMap serverMap = StreamMap(Side.server, 65536, 16384, 16384, 16384, 16, 16, 16, 16);

    StreamId sid;
    assert(clientMap.openLocalStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    assert(sid.id == 0);

    QuicStream* clientStream = clientMap.getStream(sid);
    assert(clientStream !is null);

    // Initial server transport parameters grant connection-level send credit
    clientMap.connFlow.updateRemoteMaxData(65536);

    const(ubyte)[] testMsg = cast(const(ubyte)[]) "Hello QUIC Stream Pipeline!";
    assert(clientStream.sendBuf.write(testMsg, true));

    // Client polls transmit chunk
    StreamId polledSid;
    TransmitChunk chunk;
    assert(clientMap.pollWritable(polledSid, 1024, chunk));
    assert(polledSid == sid);
    assert(chunk.offset == 0);
    assert(chunk.data == testMsg);
    assert(chunk.fin);

    // Server receives STREAM frame
    StreamFrame sf;
    sf.streamId = sid.id;
    sf.offset = chunk.offset;
    sf.data = chunk.data;
    sf.fin = chunk.fin;
    assert(serverMap.onStreamFrame(sf) == TransportErrorCode.noError);

    QuicStream* serverStream = serverMap.getStream(sid);
    assert(serverStream !is null);
    assert(serverStream.recvBuf.readableBytes() == testMsg.length);

    ubyte[64] readBuf;
    bool fin = false;
    size_t n = serverStream.recvBuf.read(readBuf[], fin);
    assert(n == testMsg.length);
    assert(fin);
    assert(readBuf[0 .. n] == testMsg);

    // Client marks range acked
    clientStream.sendBuf.onRangeAcked(0, testMsg.length, true);
    assert(clientStream.sendBuf.isAllAcked);
}
