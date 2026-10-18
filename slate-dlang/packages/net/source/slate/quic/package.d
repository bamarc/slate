module slate.quic;

/**
 * QUIC Protocol Suite (RFC 9000, RFC 9001, RFC 9002).
 *
 * Re-exports:
 * - slate.quic.crypto: Cryptographic primitives, HP/AEAD, initial keys, TLS context
 * - slate.quic.wire: Packet headers, CID, frame codecs, transport parameters
 * - slate.quic.stream: Streams, send/recv buffers, stream map, flow control
 * - slate.quic.recovery: ACK ranges, RTT estimator, NewReno congestion control, loss detection
 * - slate.quic.connection: Sans-I/O QuicConnection state machine and event queue
 * - slate.quic.endpoint: Server QuicEndpoint router, Retry token codec, Version Negotiation
 */

public import slate.quic.crypto;
public import slate.quic.wire;
public import slate.quic.stream;
public import slate.quic.recovery;
public import slate.quic.connection;
public import slate.quic.endpoint;
public import slate.quic.udp;

/// Example:
// Spec: RFC 9000 Section 5 - Top-Level QUIC Umbrella Re-exports and Sanity Checks
@nogc unittest
{
    // Verify top-level re-exports compile and link cleanly in @nogc
    uint v = QUIC_VERSION_1;
    assert(v == 0x00000001);

    TransportParameters tp;
    assert(tp.initialMaxData == 0);

    SocketAddr addr = SocketAddr.ipv4(127, 0, 0, 1, 4433);
    assert(!addr.isIpv6);
    assert(addr.port == 4433);

    QuicEndpoint endpoint;
    assert(endpoint.connectionCount == 0);
}
