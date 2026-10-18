module slate.quic.connection;

/**
 * QUIC Connection State Machine and Subsystem Umbrella (RFC 9000 & RFC 9001).
 *
 * Re-exports:
 * - slate.quic.connection.events: ConnectionEventType, ConnectionEvent, ConnectionEventQueue
 * - slate.quic.connection.sent_frames: SentFrameKind, SentFrameDesc, SentPacketRecord, SentFrameTracker
 * - slate.quic.connection.connection: QuicConnection Sans-I/O state machine
 */

public import slate.quic.connection.events;
public import slate.quic.connection.sent_frames;
public import slate.quic.connection.connection;

version (unittest)
{
    import slate.quic.crypto.kdf : Side;
    import slate.quic.crypto.tls_session : TlsContext;
    import slate.quic.wire.cid : ConnectionId;
    import slate.quic.wire.transport_params : TransportParameters;
}

/// Example:
// Spec: High-Iteration Creation/Destruction and Zero-Leak Lifecycle (covers U2, G4)
@nogc unittest
{
    TlsContext clientCtx = TlsContext.createClientInsecure();
    const ubyte[8] dcidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    const ubyte[8] scidBytes = [9, 10, 11, 12, 13, 14, 15, 16];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);
    TransportParameters tp;

    foreach (iter; 0 .. 50)
    {
        QuicConnection conn;
        assert(QuicConnection.create(Side.client, clientCtx, scid, dcid, tp, 1000, conn));
        assert(conn.state == ConnectionState.handshaking);
    }
}
