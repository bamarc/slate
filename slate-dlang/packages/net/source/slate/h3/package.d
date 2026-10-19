module slate.h3;

/**
 * Umbrella module for HTTP/3 and QPACK protocol layer (RFC 9114 & RFC 9204).
 */

public import slate.h3.error;
public import slate.h3.qpack;
public import slate.h3.frame;
public import slate.h3.connection;

version (unittest)
{
    import slate.quic.connection : QuicConnection, ConnectionEvent, ConnectionEventType;
    import slate.quic.crypto.tls_session : TlsContext;
    import slate.quic.crypto.kdf : Side;
    import slate.quic.wire.cid : ConnectionId, TransportErrorCode;
    import slate.quic.wire.transport_params : TransportParameters;
    import slate.quic.stream.id : StreamId, StreamDirection;

    private struct TestQuicPair
    {
        QuicConnection client;
        QuicConnection server;
        ulong now = 1_000_000;

        void pump() @trusted @nogc nothrow
        {
            ubyte[4096] buf;
            size_t len = 0;
            foreach (_; 0 .. 40)
            {
                bool hadTraffic = false;
                // Datagrams are capped at 1200 bytes, so drain each direction completely.
                while (client.pollTransmit(buf[], now, len) && len > 0)
                {
                    server.handleDatagram(buf[0 .. len], now);
                    hadTraffic = true;
                }
                while (server.pollTransmit(buf[], now, len) && len > 0)
                {
                    client.handleDatagram(buf[0 .. len], now);
                    hadTraffic = true;
                }
                now += 1000;
                if (!hadTraffic)
                    break;
            }
        }
    }

    private bool initTestQuicPair(out TestQuicPair pair, ulong requestWindow = 1_000_000) @trusted @nogc nothrow
    {
        TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
        if (!serverCtx.isValid)
            serverCtx = TlsContext.createServer("packages/net/test/fixtures/quic_cert.pem",
                    "packages/net/test/fixtures/quic_key.pem");
        if (!serverCtx.isValid)
            serverCtx = TlsContext.createServer("slate-dlang/packages/net/test/fixtures/quic_cert.pem",
                    "slate-dlang/packages/net/test/fixtures/quic_key.pem");
        if (!serverCtx.isValid)
            return false;

        TlsContext clientCtx = TlsContext.createClientInsecure();
        if (!clientCtx.isValid)
            return false;

        const ubyte[8] dcidBytes = [
            0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08
        ];
        const ubyte[8] scidBytes = [
            0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8
        ];
        ConnectionId clientDcid = ConnectionId(dcidBytes[]);
        ConnectionId clientScid = ConnectionId(scidBytes[]);

        TransportParameters clientTp;
        clientTp.hasInitialSourceConnectionId = true;
        clientTp.initialSourceConnectionId = clientScid;
        clientTp.initialMaxData = 10_000_000;
        clientTp.initialMaxStreamsBidi = 100;
        clientTp.initialMaxStreamsUni = 100;
        clientTp.initialMaxStreamDataBidiLocal = 1_000_000;
        clientTp.initialMaxStreamDataBidiRemote = 1_000_000;
        clientTp.initialMaxStreamDataUni = 1_000_000;

        TransportParameters serverTp;
        serverTp.hasOriginalDestinationConnectionId = true;
        serverTp.originalDestinationConnectionId = clientDcid;
        serverTp.hasInitialSourceConnectionId = true;
        serverTp.initialSourceConnectionId = clientDcid;
        serverTp.initialMaxData = 20_000_000 + 4 * requestWindow;
        serverTp.initialMaxStreamsBidi = 100;
        serverTp.initialMaxStreamsUni = 100;
        serverTp.initialMaxStreamDataBidiLocal = 1_000_000;
        serverTp.initialMaxStreamDataBidiRemote = requestWindow;
        serverTp.initialMaxStreamDataUni = 1_000_000;

        ulong now = 1_000_000;
        pair.now = now;

        if (!QuicConnection.create(Side.client, clientCtx, clientScid,
                clientDcid, clientTp, now, pair.client))
            return false;
        if (!QuicConnection.create(Side.server, serverCtx, clientDcid,
                ConnectionId.init, serverTp, now, pair.server))
            return false;

        // Handshake flights (each may span several datagrams of <= 1200 bytes)
        pair.pump();
        now = pair.now;

        now += 10_000;
        pair.now = now;
        return pair.client.handshakeConfirmed;
    }
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);                // QUIC handshake, SETTINGS exchanged
/// const H3HeaderField[4] getHeaders = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/")
/// ];
/// StreamId reqStream;
/// assert(client.sendRequest(quic.client, getHeaders[], null, true, reqStream));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
/// assert(ev.streamId == reqStream && ev.headerCount == 4 && ev.headers[3].value == "/");
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
/// // the server answers with a 200 and a body; the client sees headers, data, and the end
/// const ubyte[] respBody = cast(const(ubyte)[]) "Hello HTTP/3!";
/// assert(server.sendResponse(quic.server, reqStream, 200, null, respBody, true));
/// quic.pump();
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.headersReceived);
/// assert(ev.headers[0].name == ":status" && ev.headers[0].value == "200");
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.dataReceived);
/// assert(ev.data == respBody);
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.requestFinished);
/// ---
// Spec: RFC 9114 Section 4.1, Section 6.2, Section 7.2.4 - End-to-End Client <-> Server HTTP/3 Request/Response Multiplexing (covers Scenario T3, U1, U2, U3, E3, E4, F7)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic), "QUIC Handshake failed");

    H3Connection clientH3 = H3Connection(Side.client);
    H3Connection serverH3 = H3Connection(Side.server);

    // 1. Initialize HTTP/3 on both endpoints (opens Control, QpackEnc, QpackDec streams)
    assert(clientH3.initConnection(quic.client));
    assert(serverH3.initConnection(quic.server));

    quic.pump();

    // Both endpoints receive peer SETTINGS
    H3Event ev;
    assert(clientH3.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.peerSettingsReceived);

    assert(serverH3.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.peerSettingsReceived);

    // 2. Client sends GET "/" request on stream 0
    const H3HeaderField[4] getHeaders = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/")
    ];
    StreamId reqStream1;
    assert(clientH3.sendRequest(quic.client, getHeaders[], null, true, reqStream1));

    quic.pump();

    // Server receives HEADERS and requestFinished
    assert(serverH3.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(ev.streamId == reqStream1);
    assert(ev.headerCount == 4);
    assert(ev.headers[0].name == ":method" && ev.headers[0].value == "GET");
    assert(ev.headers[3].name == ":path" && ev.headers[3].value == "/");

    assert(serverH3.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.requestFinished);
    assert(ev.streamId == reqStream1);

    // 3. Server sends 200 OK response with body "Hello HTTP/3!"
    const H3HeaderField[1] respHeaders = [
        H3HeaderField("content-type", "text/plain")
    ];
    const ubyte[] respBody = cast(const(ubyte)[]) "Hello HTTP/3!";
    assert(serverH3.sendResponse(quic.server, reqStream1, 200, respHeaders[], respBody, true));

    quic.pump();

    // Client receives response headers, body, and requestFinished
    assert(clientH3.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.headersReceived);

    assert(ev.streamId == reqStream1);
    assert(ev.headers[0].name == ":status" && ev.headers[0].value == "200");

    assert(clientH3.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.dataReceived);
    assert(ev.streamId == reqStream1);
    assert(ev.data == respBody);

    assert(clientH3.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.requestFinished);
    assert(ev.streamId == reqStream1);

    // 4. Client sends POST "/api/echo" with body and content-length
    const H3HeaderField[6] postHeaders = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"),
        H3HeaderField(":path", "/api/echo"), H3HeaderField("content-length",
                "9"), H3HeaderField("content-type", "text/plain")
    ];
    const ubyte[] postBody = cast(const(ubyte)[]) "Echo Body";
    StreamId reqStream2;
    assert(clientH3.sendRequest(quic.client, postHeaders[], postBody, true, reqStream2));

    quic.pump();

    // Server receives POST headers, data, and requestFinished
    assert(serverH3.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(ev.streamId == reqStream2);

    assert(serverH3.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.dataReceived);
    assert(ev.streamId == reqStream2);
    assert(ev.data == postBody);

    assert(serverH3.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.requestFinished);
    assert(ev.streamId == reqStream2);
}

/// Example:
/// ---
/// // a peer whose first control-stream frame is DATA instead of SETTINGS breaks the connection
/// TestQuicPair quic;
/// assert(initTestQuicPair(quic));
/// H3Connection server = H3Connection(Side.server);
/// StreamId controlStream;
/// assert(quic.client.openStream(StreamDirection.unidirectional, controlStream)
///         == TransportErrorCode.noError);
/// const ubyte[1] controlType = [0x00];
/// assert(quic.client.streamWrite(controlStream, controlType[], false));
/// const ubyte[6] dataFrame = [0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD];   // DATA, not SETTINGS
/// assert(quic.client.streamWrite(controlStream, dataFrame[], false));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.missingSettings);
/// assert(server.isClosed);
/// ---
// Spec: RFC 9114 Section 6.2.1, Section 7.2.4 - Control Stream & Critical Stream Protocol Violation Enforcement (covers Scenario T4, U1, U2, U3, W1, F1, F2)
@nogc unittest
{
    // 1. Peer sends DATA as the FIRST frame on Control Stream -> H3ErrorCode.missingSettings (0x010a)
    TestQuicPair quic1;
    assert(initTestQuicPair(quic1));
    H3Connection server1 = H3Connection(Side.server);

    // Open a peer unidirectional stream (type 0x00 = control)
    StreamId badControlStream;
    assert(quic1.client.openStream(StreamDirection.unidirectional,
            badControlStream) == TransportErrorCode.noError);

    // Send control type 0x00 followed by DATA frame (0x00, len 4) instead of SETTINGS frame (0x04)
    ubyte[1] typeByte = [0x00];
    assert(quic1.client.streamWrite(badControlStream, typeByte[], false));

    ubyte[6] badDataFrame = [0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD];
    assert(quic1.client.streamWrite(badControlStream, badDataFrame[], false));

    quic1.pump();

    H3Event ev;
    assert(server1.pollEvent(quic1.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.missingSettings);
    assert(server1.isClosed);

    // 2. Peer sends duplicate SETTINGS frame on Control Stream -> H3ErrorCode.frameUnexpected (0x0105)
    TestQuicPair quic2;
    assert(initTestQuicPair(quic2));
    H3Connection client2 = H3Connection(Side.client);
    H3Connection server2 = H3Connection(Side.server);
    assert(client2.initConnection(quic2.client));
    assert(server2.initConnection(quic2.server));
    quic2.pump();
    assert(server2.pollEvent(quic2.server, ev)); // SETTINGS 1

    // Client injects a second SETTINGS frame onto its localControlStreamId
    ubyte[4] dupSettings = [0x04, 0x02, 0x06, 0x64]; // SETTINGS frame
    assert(quic2.client.streamWrite(client2.localControlStreamId, dupSettings[], false));
    quic2.pump();

    assert(server2.pollEvent(quic2.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.frameUnexpected);

    // 3. Peer closes (FIN) its Control Stream -> H3ErrorCode.closedCriticalStream (0x0104)
    TestQuicPair quic3;
    assert(initTestQuicPair(quic3));
    H3Connection server3 = H3Connection(Side.server);
    StreamId cStream;
    assert(quic3.client.openStream(StreamDirection.unidirectional,
            cStream) == TransportErrorCode.noError);
    // Send type 0x00 + FIN immediately
    assert(quic3.client.streamWrite(cStream, typeByte[], true));
    quic3.pump();

    assert(server3.pollEvent(quic3.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.closedCriticalStream);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
///
/// // The request declares content-length: 5 but sends 10 bytes of DATA.
/// const H3HeaderField[5] headers = [
///     H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/bad-length"),
///     H3HeaderField("content-length", "5")
/// ];
/// const ubyte[10] tenBytes = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
/// StreamId badStream;
/// assert(client.sendRequest(quic.client, headers[], tenBytes[], true, badStream));
/// quic.pump();
///
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.streamReset);
/// assert(ev.streamId == badStream && ev.errorCode == H3ErrorCode.messageError);
/// assert(!server.isClosed);   // only the request stream failed
/// ---
// Spec: RFC 9114 Section 4.1.2 - malformed requests are stream errors of type H3_MESSAGE_ERROR
// (R-12, W4; formerly asserted a connection abort)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));

    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    // Content-length mismatch: header declares content-length: 5, but sends 10 bytes DATA
    const H3HeaderField[5] headers = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"),
        H3HeaderField(":path", "/bad-length"),
        H3HeaderField("content-length", "5")
    ];
    const ubyte[10] tenBytes = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    StreamId badStream;
    assert(client.sendRequest(quic.client, headers[], tenBytes[], true, badStream));

    quic.pump();

    // Server receives HEADERS, then DATA length > 5 resets only this stream with messageError
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.headersReceived);

    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.streamReset);
    assert(ev.streamId == badStream);
    assert(ev.errorCode == H3ErrorCode.messageError);
    assert(!server.isClosed);
    assert(!server.pollEvent(quic.server, ev)); // no data/finished events for the reset stream

    // The peer is told via RESET_STREAM (+ STOP_SENDING) carrying H3_MESSAGE_ERROR. Once the
    // RESET_STREAM lets the peer reap the stream, a STOP_SENDING behind it is stale and not
    // reported again, so the RESET_STREAM is the observable signal.
    quic.pump();
    bool sawReset = false;
    ConnectionEvent qev;
    while (quic.client.pollEvent(qev))
    {
        if ((qev.type == ConnectionEventType.streamReset
                || qev.type == ConnectionEventType.stopSending) && qev.streamId == badStream.id)
        {
            assert(qev.errorCode == H3ErrorCode.messageError);
            sawReset = sawReset || qev.type == ConnectionEventType.streamReset;
        }
    }
    assert(sawReset);

    // The connection stays usable: a well-formed request on a new stream is served.
    const H3HeaderField[4] okHdrs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/ok")
    ];
    StreamId okStream;
    assert(client.sendRequest(quic.client, okHdrs[], null, true, okStream));
    quic.pump();
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(ev.streamId == okStream);
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.requestFinished);
    assert(!server.isClosed);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// assert(server.sendGoaway(quic.server, 4));       // no request above stream 4 will be handled
/// quic.pump();
/// H3Event ev;
/// assert(client.pollEvent(quic.client, ev));
/// assert(ev.type == H3EventType.goawayReceived && ev.streamId == StreamId(4));
/// ---
// Spec: RFC 9114 Section 7.2.6 - Graceful HTTP/3 GOAWAY Shutdown (covers Scenario T6, U1, U2, U3, E4)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));

    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    // Server sends GOAWAY with StreamId 4
    assert(server.sendGoaway(quic.server, 4));

    quic.pump();

    // Client receives goawayReceived
    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.goawayReceived);
    assert(ev.streamId == StreamId(4));
}

/// Example:
/// ---
/// // a client may not open a second control stream
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// StreamId duplicate;
/// assert(quic.client.openStream(StreamDirection.unidirectional, duplicate)
///         == TransportErrorCode.noError);
/// const ubyte[1] controlType = [0x00];
/// assert(quic.client.streamWrite(duplicate, controlType[], false));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.streamCreationError);
/// ---
// Spec: RFC 9114 Section 6.2.1, Section 6.2.2 - Duplicate & Unauthorized Critical Unidirectional Streams (covers D8.3, [HIGH-7])
@nogc unittest
{
    // 1. Client attempts to open a second Control Stream (0x00) -> streamCreationError (0x0103)
    TestQuicPair quic1;
    assert(initTestQuicPair(quic1));
    H3Connection client1 = H3Connection(Side.client);
    H3Connection server1 = H3Connection(Side.server);
    assert(client1.initConnection(quic1.client));
    assert(server1.initConnection(quic1.server));
    quic1.pump();

    H3Event ev;
    assert(server1.pollEvent(quic1.server, ev)); // initial settings

    StreamId dupControl;
    assert(quic1.client.openStream(StreamDirection.unidirectional,
            dupControl) == TransportErrorCode.noError);
    ubyte[1] controlType = [0x00];
    assert(quic1.client.streamWrite(dupControl, controlType[], false));
    quic1.pump();

    assert(server1.pollEvent(quic1.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.streamCreationError);

    // 2. Client attempts to open a Push Stream (0x01) -> streamCreationError (0x0103)
    TestQuicPair quic2;
    assert(initTestQuicPair(quic2));
    H3Connection server2 = H3Connection(Side.server);
    StreamId pushStream;
    assert(quic2.client.openStream(StreamDirection.unidirectional,
            pushStream) == TransportErrorCode.noError);
    ubyte[1] pushType = [0x01];
    assert(quic2.client.streamWrite(pushStream, pushType[], false));
    quic2.pump();

    assert(server2.pollEvent(quic2.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.streamCreationError);
}

/// Example:
/// ---
/// // a reserved HTTP/2 frame after SETTINGS on the control stream breaks the connection
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// const ubyte[2] reservedFrame = [0x02, 0x00];     // frame type 0x02 (HTTP/2 PRIORITY), length 0
/// assert(quic.client.streamWrite(client.localControlStreamId, reservedFrame[], false));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.frameUnexpected);
/// // so does a DATA frame in front of HEADERS on a request stream
/// TestQuicPair quic2;
/// H3Connection client2 = H3Connection(Side.client);
/// H3Connection server2 = H3Connection(Side.server);
/// initH3Pair(quic2, client2, server2);
/// StreamId req;
/// assert(quic2.client.openStream(StreamDirection.bidirectional, req) == TransportErrorCode.noError);
/// const ubyte[4] earlyData = [0x00, 0x02, 0xAA, 0xBB];
/// assert(quic2.client.streamWrite(req, earlyData[], false));
/// quic2.pump();
/// assert(server2.pollEvent(quic2.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.frameUnexpected);
/// ---
// Spec: RFC 9114 Section 6.2.1, Section 7.2.8 - First Frame Precedence & Forbidden Frames on Control/Request Streams (covers D8.5, D6, [HIGH-10])
@nogc unittest
{
    // 1. Reserved HTTP/2 frame 0x02 as FIRST frame on Control Stream -> missingSettings (0x010a)
    TestQuicPair quic1;
    assert(initTestQuicPair(quic1));
    H3Connection server1 = H3Connection(Side.server);
    StreamId ctrl1;
    assert(quic1.client.openStream(StreamDirection.unidirectional,
            ctrl1) == TransportErrorCode.noError);
    ubyte[3] firstH2Frame = [0x00, 0x02, 0x00]; // StreamType 0x00 + FrameType 0x02 + Len 0
    assert(quic1.client.streamWrite(ctrl1, firstH2Frame[], false));
    quic1.pump();

    H3Event ev;
    assert(server1.pollEvent(quic1.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.missingSettings);

    // 2. Reserved HTTP/2 frame 0x02 AFTER SETTINGS frame on Control Stream -> frameUnexpected (0x0105)
    TestQuicPair quic2;
    assert(initTestQuicPair(quic2));
    H3Connection client2 = H3Connection(Side.client);
    H3Connection server2 = H3Connection(Side.server);
    assert(client2.initConnection(quic2.client));
    assert(server2.initConnection(quic2.server));
    quic2.pump();
    assert(server2.pollEvent(quic2.server, ev)); // peerSettingsReceived

    ubyte[2] afterH2Frame = [0x02, 0x00]; // FrameType 0x02 + Len 0
    assert(quic2.client.streamWrite(client2.localControlStreamId, afterH2Frame[], false));
    quic2.pump();

    assert(server2.pollEvent(quic2.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.frameUnexpected);

    // 3. PUSH_PROMISE (0x05) on Request Stream -> frameUnexpected (0x0105)
    TestQuicPair quic3;
    assert(initTestQuicPair(quic3));
    H3Connection server3 = H3Connection(Side.server);
    StreamId req3;
    assert(quic3.client.openStream(StreamDirection.bidirectional,
            req3) == TransportErrorCode.noError);
    ubyte[2] pushPromiseFrame = [0x05, 0x00]; // Type 0x05 + Len 0
    assert(quic3.client.streamWrite(req3, pushPromiseFrame[], false));
    quic3.pump();

    assert(server3.pollEvent(quic3.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.frameUnexpected);

    // 4. DATA frame before HEADERS on Request Stream -> frameUnexpected (0x0105)
    TestQuicPair quic4;
    assert(initTestQuicPair(quic4));
    H3Connection server4 = H3Connection(Side.server);
    StreamId req4;
    assert(quic4.client.openStream(StreamDirection.bidirectional,
            req4) == TransportErrorCode.noError);
    ubyte[4] earlyData = [0x00, 0x02, 0xAA, 0xBB]; // DATA + Len 2
    assert(quic4.client.streamWrite(req4, earlyData[], false));
    quic4.pump();

    assert(server4.pollEvent(quic4.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.frameUnexpected);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// assert(initTestQuicPair(quic));
/// H3Connection server = H3Connection(Side.server);
/// StreamId req;
/// assert(quic.client.openStream(StreamDirection.bidirectional, req) == TransportErrorCode.noError);
/// const ubyte[1] truncHeader = [0x40];             // a two-byte varint cut off after one byte
/// assert(quic.client.streamWrite(req, truncHeader[], true));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.frameError);
/// // a clean FIN without any HEADERS is an incomplete request instead
/// TestQuicPair quic2;
/// assert(initTestQuicPair(quic2));
/// H3Connection server2 = H3Connection(Side.server);
/// StreamId req2;
/// assert(quic2.client.openStream(StreamDirection.bidirectional, req2) == TransportErrorCode.noError);
/// const ubyte[0] nothing;
/// assert(quic2.client.streamWrite(req2, nothing[], true));
/// quic2.pump();
/// assert(server2.pollEvent(quic2.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.requestIncomplete);
/// ---
// Spec: RFC 9114 Section 7.1, Section 4.1.2 - Truncated Frame & Request Incomplete Rejection (covers D8.6, [HIGH-11])
@nogc unittest
{
    // 1. Truncated frame header at stream FIN -> frameError (0x0106)
    TestQuicPair quic1;
    assert(initTestQuicPair(quic1));
    H3Connection server1 = H3Connection(Side.server);
    StreamId req1;
    assert(quic1.client.openStream(StreamDirection.bidirectional,
            req1) == TransportErrorCode.noError);
    ubyte[1] truncHeader = [0x40]; // 2-byte varint prefix
    assert(quic1.client.streamWrite(req1, truncHeader[], true));
    quic1.pump();

    H3Event ev;
    assert(server1.pollEvent(quic1.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.frameError);

    // 2. Truncated frame payload at stream FIN -> frameError (0x0106)
    TestQuicPair quic2;
    assert(initTestQuicPair(quic2));
    H3Connection server2 = H3Connection(Side.server);
    StreamId req2;
    assert(quic2.client.openStream(StreamDirection.bidirectional,
            req2) == TransportErrorCode.noError);
    ubyte[4] truncPayload = [0x01, 0x0A, 0x00, 0x00];
    assert(quic2.client.streamWrite(req2, truncPayload[], true));
    quic2.pump();

    assert(server2.pollEvent(quic2.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.frameError);

    // 3. Clean FIN with zero headers on Request Stream -> requestIncomplete (0x010d)
    TestQuicPair quic3;
    assert(initTestQuicPair(quic3));
    H3Connection server3 = H3Connection(Side.server);
    StreamId req3;
    assert(quic3.client.openStream(StreamDirection.bidirectional,
            req3) == TransportErrorCode.noError);
    ubyte[0] emptyBuf;
    assert(quic3.client.streamWrite(req3, emptyBuf[], true));
    quic3.pump();

    assert(server3.pollEvent(quic3.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.requestIncomplete);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// const H3HeaderField[5] reqHdrs = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/stream"),
///     H3HeaderField("te", "trailers")
/// ];
/// StreamId reqStream;
/// assert(client.sendRequest(quic.client, reqHdrs[], null, true, reqStream));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
/// // the response is HEADERS, DATA and a trailing HEADERS section
/// assert(server.sendResponse(quic.server, reqStream, 200, null, cast(const(ubyte)[]) "Part1", false));
/// const H3HeaderField[1] trailers = [H3HeaderField("x-checksum", "sha256-abc")];
/// assert(server.sendTrailers(quic.server, reqStream, trailers[]));
/// quic.pump();
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.headersReceived);
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.dataReceived);
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.headersReceived);
/// assert(ev.headers[0].name == "x-checksum" && ev.headers[0].value == "sha256-abc");
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.requestFinished);
/// ---
// Spec: RFC 9114 Section 4.1, Section 4.3 - Trailing Headers (Trailers) & Multiple Coalesced DATA Frames (covers D8.7, [HIGH-1], [HIGH-10])
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    // Client sends GET "/" request
    const H3HeaderField[5] reqHdrs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"),
        H3HeaderField(":path", "/stream"), H3HeaderField("te", "trailers")
    ];
    StreamId reqStream;
    assert(client.sendRequest(quic.client, reqHdrs[], null, true, reqStream));
    quic.pump();

    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.requestFinished);

    // Server sends 200 OK headers + 2 DATA frames + Trailers in one flight
    const H3HeaderField[1] respHdrs = [
        H3HeaderField("content-type", "application/octet-stream")
    ];
    assert(server.sendResponse(quic.server, reqStream, 200, respHdrs[],
            cast(const(ubyte)[]) "Part1", false));

    // Write second DATA frame manually
    ubyte[16] dataHdr;
    size_t dhl = 0;
    assert(encodeH3FrameHeader(H3FrameType.data, 5, dataHdr[], dhl));
    assert(quic.server.streamWrite(reqStream, dataHdr[0 .. dhl], false));
    assert(quic.server.streamWrite(reqStream, cast(const(ubyte)[]) "Part2", false));

    // Write trailing headers (trailers)
    const H3HeaderField[1] trailers = [
        H3HeaderField("x-checksum", "sha256-abc")
    ];
    assert(server.sendTrailers(quic.server, reqStream, trailers[]));

    quic.pump();

    // Client polls: headersReceived -> dataReceived ("Part1") -> dataReceived ("Part2") -> headersReceived (trailers) -> requestFinished
    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(ev.headers[0].name == ":status" && ev.headers[0].value == "200");

    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.dataReceived);
    assert(ev.data == cast(const(ubyte)[]) "Part1");

    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.dataReceived);
    assert(ev.data == cast(const(ubyte)[]) "Part2");

    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(ev.headerCount == 1);
    assert(ev.headers[0].name == "x-checksum" && ev.headers[0].value == "sha256-abc");

    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.requestFinished);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// assert(server.sendGoaway(quic.server, 8));
/// quic.pump();
/// H3Event ev;
/// assert(client.pollEvent(quic.client, ev));
/// assert(ev.type == H3EventType.goawayReceived && ev.streamId == StreamId(8));
/// // a later GOAWAY may not raise the identifier: the client closes with H3_ID_ERROR
/// server.localGoawaySent = false;
/// assert(server.sendGoaway(quic.server, 12));
/// quic.pump();
/// assert(client.pollEvent(quic.client, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.idError);
/// ---
// Spec: RFC 9114 Section 5.2 - GOAWAY Stream ID Security Validation (covers [HIGH-12.2])
@nogc unittest
{
    // 1. Peer sends GOAWAY with invalid stream ID for client (odd stream ID 1) -> idError (0x0108)
    TestQuicPair quic1;
    assert(initTestQuicPair(quic1));
    H3Connection client1 = H3Connection(Side.client);
    H3Connection server1 = H3Connection(Side.server);
    assert(client1.initConnection(quic1.client));
    assert(server1.initConnection(quic1.server));
    quic1.pump();

    H3Event ev;
    assert(client1.pollEvent(quic1.client, ev));
    assert(server1.pollEvent(quic1.server, ev));

    assert(server1.sendGoaway(quic1.server, 1));
    quic1.pump();

    assert(client1.pollEvent(quic1.client, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.idError);

    // 2. Peer sends GOAWAY with increasing identifier -> idError (0x0108)
    TestQuicPair quic2;
    assert(initTestQuicPair(quic2));
    H3Connection client2 = H3Connection(Side.client);
    H3Connection server2 = H3Connection(Side.server);
    assert(client2.initConnection(quic2.client));
    assert(server2.initConnection(quic2.server));
    quic2.pump();
    assert(client2.pollEvent(quic2.client, ev));
    assert(server2.pollEvent(quic2.server, ev));

    assert(server2.sendGoaway(quic2.server, 8));
    quic2.pump();
    assert(client2.pollEvent(quic2.client, ev));
    assert(ev.type == H3EventType.goawayReceived);
    assert(ev.streamId == StreamId(8));

    server2.localGoawaySent = false;
    assert(server2.sendGoaway(quic2.server, 12));
    quic2.pump();

    assert(client2.pollEvent(quic2.client, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.idError);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// const H3HeaderField[4] hdrs = [
///     H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "example.com"), H3HeaderField(":path", "/upload")
/// ];
/// StreamId req;
/// assert(quic.client.openStream(StreamDirection.bidirectional, req) == TransportErrorCode.noError);
/// ubyte[256] qpackBuf;
/// const size_t qpackLen = encodeQpackFieldSection(hdrs[], qpackBuf[], false);
/// ubyte[16] frameHdr;
/// size_t fhl;
/// assert(encodeH3FrameHeader(H3FrameType.headers, qpackLen, frameHdr[], fhl));
/// // the HEADERS frame arrives in three pieces; nothing is reported until it is complete
/// H3Event ev;
/// assert(quic.client.streamWrite(req, frameHdr[0 .. 1], false));
/// quic.pump();
/// assert(!server.pollEvent(quic.server, ev));
/// assert(quic.client.streamWrite(req, frameHdr[1 .. fhl], false));
/// assert(quic.client.streamWrite(req, qpackBuf[0 .. 5], false));
/// quic.pump();
/// assert(!server.pollEvent(quic.server, ev));
/// assert(quic.client.streamWrite(req, qpackBuf[5 .. qpackLen], false));
/// quic.pump();
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.headersReceived && ev.streamId == req);
/// ---
// Spec: RFC 9114 Section 7.1, Section 4.1 - Fragmented Frame Delivery Across Multiple QUIC Flights & Multi-Flight Streaming Response (covers Scenario T3, F7)
@nogc unittest
{
    // 1. Fragmented frame delivery: split HEADERS and DATA across multiple writes/pumps
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    StreamId reqStream;
    assert(quic.client.openStream(StreamDirection.bidirectional,
            reqStream) == TransportErrorCode.noError);

    const H3HeaderField[4] hdrs = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"),
        H3HeaderField(":path", "/upload")
    ];
    ubyte[256] qpackBuf;
    const size_t qpackLen = encodeQpackFieldSection(hdrs[], qpackBuf[], false);

    ubyte[16] frameHdr;
    size_t fhl = 0;
    assert(encodeH3FrameHeader(H3FrameType.headers, qpackLen, frameHdr[], fhl));

    // Send partial HEADERS frame header (first byte only)
    assert(quic.client.streamWrite(reqStream, frameHdr[0 .. 1], false));
    quic.pump();
    assert(!server.pollEvent(quic.server, ev)); // Should buffer, no event yet

    // Send rest of HEADERS frame header + partial QPACK payload (first 5 bytes)
    assert(quic.client.streamWrite(reqStream, frameHdr[1 .. fhl], false));
    assert(quic.client.streamWrite(reqStream, qpackBuf[0 .. 5], false));
    quic.pump();
    assert(!server.pollEvent(quic.server, ev));

    // Send remainder of QPACK payload
    assert(quic.client.streamWrite(reqStream, qpackBuf[5 .. qpackLen], false));
    quic.pump();
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(ev.streamId == reqStream);

    // Send partial DATA frame (header only)
    ubyte[16] dataHdr;
    size_t dhl = 0;
    assert(encodeH3FrameHeader(H3FrameType.data, 4, dataHdr[], dhl));
    assert(quic.client.streamWrite(reqStream, dataHdr[0 .. dhl], false));
    quic.pump();
    assert(!server.pollEvent(quic.server, ev));

    // Send DATA payload with fin = true
    assert(quic.client.streamWrite(reqStream, cast(const(ubyte)[]) "body", true));
    quic.pump();
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.dataReceived);
    assert(ev.data == cast(const(ubyte)[]) "body");
    assert(ev.fin);
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.requestFinished);

    // 2. Multi-flight streaming response: Part 1 with fin = false after client request ACKed, then Part 2 with fin = true
    TestQuicPair quic2;
    assert(initTestQuicPair(quic2));
    H3Connection client2 = H3Connection(Side.client);
    H3Connection server2 = H3Connection(Side.server);
    assert(client2.initConnection(quic2.client));
    assert(server2.initConnection(quic2.server));
    quic2.pump();
    assert(client2.pollEvent(quic2.client, ev));
    assert(server2.pollEvent(quic2.server, ev));

    StreamId req2;
    assert(client2.sendRequest(quic2.client, hdrs[], null, true, req2));
    quic2.pump(); // Server receives request and ACKs client request
    assert(server2.pollEvent(quic2.server, ev)); // headersReceived
    assert(server2.pollEvent(quic2.server, ev)); // requestFinished

    // Server sends 200 OK + Part 1 with fin = false
    const H3HeaderField[1] respHdrs = [
        H3HeaderField("content-type", "text/plain")
    ];
    assert(server2.sendResponse(quic2.server, req2, 200, respHdrs[],
            cast(const(ubyte)[]) "Part1", false));
    quic2.pump(); // Deliver Flight 1

    assert(client2.pollEvent(quic2.client, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(client2.pollEvent(quic2.client, ev));
    assert(ev.type == H3EventType.dataReceived);
    assert(ev.data == cast(const(ubyte)[]) "Part1");
    assert(!ev.fin); // fin MUST be false!
    assert(!client2.pollEvent(quic2.client, ev)); // Not finished yet

    // Server sends Part 2 with fin = true in Flight 2
    assert(encodeH3FrameHeader(H3FrameType.data, 5, dataHdr[], dhl));
    assert(quic2.server.streamWrite(req2, dataHdr[0 .. dhl], false));
    assert(quic2.server.streamWrite(req2, cast(const(ubyte)[]) "Part2", true));
    quic2.pump(); // Deliver Flight 2

    assert(client2.pollEvent(quic2.client, ev));
    assert(ev.type == H3EventType.dataReceived);
    assert(ev.data == cast(const(ubyte)[]) "Part2");
    assert(ev.fin);
    assert(client2.pollEvent(quic2.client, ev));
    assert(ev.type == H3EventType.requestFinished);
}

/// Example:
/// ---
/// // a second QPACK encoder stream is refused
/// TestQuicPair quic;
/// assert(initTestQuicPair(quic));
/// H3Connection server = H3Connection(Side.server);
/// StreamId enc1, enc2;
/// assert(quic.client.openStream(StreamDirection.unidirectional, enc1) == TransportErrorCode.noError);
/// assert(quic.client.openStream(StreamDirection.unidirectional, enc2) == TransportErrorCode.noError);
/// const ubyte[1] encType = [0x02];
/// assert(quic.client.streamWrite(enc1, encType[], false));
/// assert(quic.client.streamWrite(enc2, encType[], false));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.streamCreationError);
/// // closing the control stream is a critical-stream error
/// TestQuicPair quic2;
/// H3Connection client2 = H3Connection(Side.client);
/// H3Connection server2 = H3Connection(Side.server);
/// initH3Pair(quic2, client2, server2);
/// quic2.client.resetStream(client2.localControlStreamId, 0);
/// quic2.pump();
/// assert(server2.pollEvent(quic2.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.closedCriticalStream);
/// ---
// Spec: RFC 9114 Section 6.2, Section 7.2 - Critical Streams, Control Stream Invariants & Forbidden Frames (covers Scenario T4, F1, F2, F3)
@nogc unittest
{
    H3Event ev;

    // 1. Duplicate QPACK Encoder (0x02) and Decoder (0x03) streams -> streamCreationError
    TestQuicPair quic1;
    assert(initTestQuicPair(quic1));
    H3Connection server1 = H3Connection(Side.server);
    StreamId sEnc1, sEnc2;
    assert(quic1.client.openStream(StreamDirection.unidirectional,
            sEnc1) == TransportErrorCode.noError);
    assert(quic1.client.openStream(StreamDirection.unidirectional,
            sEnc2) == TransportErrorCode.noError);
    ubyte[1] encType = [0x02];
    assert(quic1.client.streamWrite(sEnc1, encType[], false));
    assert(quic1.client.streamWrite(sEnc2, encType[], false));
    quic1.pump();
    assert(server1.pollEvent(quic1.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.streamCreationError);

    TestQuicPair quic2;
    assert(initTestQuicPair(quic2));
    H3Connection server2 = H3Connection(Side.server);
    StreamId sDec1, sDec2;
    assert(quic2.client.openStream(StreamDirection.unidirectional,
            sDec1) == TransportErrorCode.noError);
    assert(quic2.client.openStream(StreamDirection.unidirectional,
            sDec2) == TransportErrorCode.noError);
    ubyte[1] decType = [0x03];
    assert(quic2.client.streamWrite(sDec1, decType[], false));
    assert(quic2.client.streamWrite(sDec2, decType[], false));
    quic2.pump();
    assert(server2.pollEvent(quic2.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.streamCreationError);

    // 2. Closing (FIN) QPACK Encoder and Decoder streams -> closedCriticalStream (0x0104)
    TestQuicPair quic3;
    assert(initTestQuicPair(quic3));
    H3Connection server3 = H3Connection(Side.server);
    StreamId sEnc3;
    assert(quic3.client.openStream(StreamDirection.unidirectional,
            sEnc3) == TransportErrorCode.noError);
    assert(quic3.client.streamWrite(sEnc3, encType[], true)); // FIN immediately
    quic3.pump();
    assert(server3.pollEvent(quic3.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.closedCriticalStream);

    TestQuicPair quic4;
    assert(initTestQuicPair(quic4));
    H3Connection server4 = H3Connection(Side.server);
    StreamId sDec4;
    assert(quic4.client.openStream(StreamDirection.unidirectional,
            sDec4) == TransportErrorCode.noError);
    assert(quic4.client.streamWrite(sDec4, decType[], true)); // FIN immediately
    quic4.pump();
    assert(server4.pollEvent(quic4.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.closedCriticalStream);

    // 3. Peer RESET_STREAM on critical stream -> closedCriticalStream (0x0104)
    TestQuicPair quic5;
    assert(initTestQuicPair(quic5));
    H3Connection client5 = H3Connection(Side.client);
    H3Connection server5 = H3Connection(Side.server);
    assert(client5.initConnection(quic5.client));
    assert(server5.initConnection(quic5.server));
    quic5.pump();
    assert(client5.pollEvent(quic5.client, ev));
    assert(server5.pollEvent(quic5.server, ev));

    quic5.client.resetStream(client5.localControlStreamId, 0);
    quic5.pump();
    assert(server5.pollEvent(quic5.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.closedCriticalStream);

    // 4. Peer STOP_SENDING on local critical stream -> closedCriticalStream (0x0104)
    TestQuicPair quic6;
    assert(initTestQuicPair(quic6));
    H3Connection client6 = H3Connection(Side.client);
    H3Connection server6 = H3Connection(Side.server);
    assert(client6.initConnection(quic6.client));
    assert(server6.initConnection(quic6.server));
    quic6.pump();
    assert(client6.pollEvent(quic6.client, ev));
    assert(server6.pollEvent(quic6.server, ev));

    quic6.server.stopSending(client6.localControlStreamId, 0);
    quic6.pump();
    assert(client6.pollEvent(quic6.client, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.closedCriticalStream);

    // 5. GOAWAY (0x07) as FIRST frame on Control Stream -> missingSettings (0x010a)
    TestQuicPair quic7;
    assert(initTestQuicPair(quic7));
    H3Connection server7 = H3Connection(Side.server);
    StreamId ctrl7;
    assert(quic7.client.openStream(StreamDirection.unidirectional,
            ctrl7) == TransportErrorCode.noError);
    ubyte[3] firstGoaway = [0x00, 0x07, 0x01]; // streamType=0, frameType=0x07, len=1
    assert(quic7.client.streamWrite(ctrl7, firstGoaway[], false));
    quic7.pump();
    assert(server7.pollEvent(quic7.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.missingSettings);

    // 6. DATA (0x00), HEADERS (0x01), PUSH_PROMISE (0x05), server MAX_PUSH_ID (0x0d) on Control Stream after SETTINGS -> frameUnexpected (0x0105)
    const ulong[4] ctrlForbidden = [0x00, 0x01, 0x05, 0x0d];
    foreach (badType; ctrlForbidden)
    {
        TestQuicPair q;
        assert(initTestQuicPair(q));
        H3Connection cl = H3Connection(Side.client);
        H3Connection srv = H3Connection(Side.server);
        assert(cl.initConnection(q.client));
        assert(srv.initConnection(q.server));
        q.pump();
        assert(cl.pollEvent(q.client, ev));
        assert(srv.pollEvent(q.server, ev));

        ubyte[3] badFrame = [cast(ubyte) badType, 0x01, 0x00];
        if (badType == 0x0d)
        {
            // Server sends MAX_PUSH_ID to client
            assert(q.server.streamWrite(srv.localControlStreamId, badFrame[], false));
            q.pump();
            assert(cl.pollEvent(q.client, ev));
            assert(ev.type == H3EventType.connectionClosed);
            assert(ev.errorCode == H3ErrorCode.frameUnexpected);
        }
        else
        {
            assert(q.client.streamWrite(cl.localControlStreamId, badFrame[], false));
            q.pump();
            assert(srv.pollEvent(q.server, ev));
            assert(ev.type == H3EventType.connectionClosed);
            assert(ev.errorCode == H3ErrorCode.frameUnexpected);
        }
    }

    // 7. SETTINGS (0x04), GOAWAY (0x07), MAX_PUSH_ID (0x0d), CANCEL_PUSH (0x03) on Request Stream -> frameUnexpected (0x0105)
    const ulong[4] reqForbidden = [0x04, 0x07, 0x0d, 0x03];
    foreach (badType; reqForbidden)
    {
        TestQuicPair q;
        assert(initTestQuicPair(q));
        H3Connection srv = H3Connection(Side.server);
        StreamId req;
        assert(q.client.openStream(StreamDirection.bidirectional, req) == TransportErrorCode
                .noError);
        ubyte[3] badFrame = [cast(ubyte) badType, 0x01, 0x00];
        assert(q.client.streamWrite(req, badFrame[], false));
        q.pump();
        assert(srv.pollEvent(q.server, ev));
        assert(ev.type == H3EventType.connectionClosed);
        assert(ev.errorCode == H3ErrorCode.frameUnexpected);
    }
}

/// Example:
/// ---
/// TestQuicPair quic;
/// assert(initTestQuicPair(quic));
/// H3Connection server = H3Connection(Side.server);
/// StreamId req;
/// assert(quic.client.openStream(StreamDirection.bidirectional, req) == TransportErrorCode.noError);
///
/// // A request without :path, sent by hand as a HEADERS frame.
/// const H3HeaderField[3] missingPath = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "example.com")
/// ];
/// ubyte[256] qpackBuf;
/// const size_t qlen = encodeQpackFieldSection(missingPath[], qpackBuf[], false);
/// ubyte[16] fhdr;
/// size_t fhl;
/// assert(encodeH3FrameHeader(H3FrameType.headers, qlen, fhdr[], fhl));
/// assert(quic.client.streamWrite(req, fhdr[0 .. fhl], false));
/// assert(quic.client.streamWrite(req, qpackBuf[0 .. qlen], false));
/// quic.pump();
///
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.streamReset);
/// assert(ev.streamId == req && ev.errorCode == H3ErrorCode.messageError);
/// assert(!server.isClosed);
/// ---
// Spec: RFC 9114 Section 4.1.2, Section 4.3 - malformed messages are stream errors of type
// H3_MESSAGE_ERROR (R-12, W4; formerly asserted a connection abort; covers F5)
@nogc unittest
{
    H3Event ev;

    static void testBadHeaders(const(H3HeaderField)[] badHdrs) @nogc
    {
        TestQuicPair quic;
        assert(initTestQuicPair(quic));
        H3Connection server = H3Connection(Side.server);
        StreamId req;
        assert(quic.client.openStream(StreamDirection.bidirectional,
                req) == TransportErrorCode.noError);

        ubyte[256] qpackBuf;
        const size_t qlen = encodeQpackFieldSection(badHdrs, qpackBuf[], false);
        ubyte[16] fhdr;
        size_t fhl = 0;
        assert(encodeH3FrameHeader(H3FrameType.headers, qlen, fhdr[], fhl));

        assert(quic.client.streamWrite(req, fhdr[0 .. fhl], false));
        assert(quic.client.streamWrite(req, qpackBuf[0 .. qlen], false));
        quic.pump();

        H3Event localEv;
        assert(server.pollEvent(quic.server, localEv));
        assert(localEv.type == H3EventType.streamReset);
        assert(localEv.streamId == req);
        assert(localEv.errorCode == H3ErrorCode.messageError);
        assert(!server.isClosed);
        assert(!server.pollEvent(quic.server, localEv));
    }

    // (a) Missing :path
    const H3HeaderField[3] missingPath = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com")
    ];
    testBadHeaders(missingPath[]);

    // (b) Pseudo-header after regular header
    const H3HeaderField[4] latePseudo = [
        H3HeaderField(":method", "GET"), H3HeaderField("accept", "*/*"),
        H3HeaderField(":scheme", "https"), H3HeaderField(":path", "/")
    ];
    testBadHeaders(latePseudo[]);

    // (c) Duplicate :method
    const H3HeaderField[5] dupMethod = [
        H3HeaderField(":method", "GET"), H3HeaderField(":method", "POST"),
        H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"), H3HeaderField(":path", "/")
    ];
    testBadHeaders(dupMethod[]);

    // (d) Uppercase header name "Accept"
    const H3HeaderField[4] upperCaseName = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("Accept", "text/html")
    ];
    testBadHeaders(upperCaseName[]);

    // (e) CRLF injection in header value
    const H3HeaderField[4] crlfInValue = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("custom", "val\r\ninjected")
    ];
    testBadHeaders(crlfInValue[]);

    // (f) content-length underrun at stream FIN (content-length: 10 with 5 bytes DATA and fin = true)
    TestQuicPair quicF;
    assert(initTestQuicPair(quicF));
    H3Connection serverF = H3Connection(Side.server);
    StreamId reqF;
    assert(quicF.client.openStream(StreamDirection.bidirectional,
            reqF) == TransportErrorCode.noError);

    const H3HeaderField[5] clHdrs = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"),
        H3HeaderField(":path", "/upload"), H3HeaderField("content-length", "10")
    ];
    ubyte[256] qpackBufF;
    const size_t qlenF = encodeQpackFieldSection(clHdrs[], qpackBufF[], false);
    ubyte[16] fhdrF;
    size_t fhlF = 0;
    assert(encodeH3FrameHeader(H3FrameType.headers, qlenF, fhdrF[], fhlF));
    assert(quicF.client.streamWrite(reqF, fhdrF[0 .. fhlF], false));
    assert(quicF.client.streamWrite(reqF, qpackBufF[0 .. qlenF], false));
    quicF.pump();

    assert(serverF.pollEvent(quicF.server, ev));
    assert(ev.type == H3EventType.headersReceived);

    // Send only 5 bytes DATA with fin = true
    ubyte[16] dhdrF;
    size_t dhlF = 0;
    assert(encodeH3FrameHeader(H3FrameType.data, 5, dhdrF[], dhlF));
    assert(quicF.client.streamWrite(reqF, dhdrF[0 .. dhlF], false));
    assert(quicF.client.streamWrite(reqF, cast(const(ubyte)[]) "12345", true));
    quicF.pump();

    assert(serverF.pollEvent(quicF.server, ev));
    assert(ev.type == H3EventType.streamReset);
    assert(ev.streamId == reqF);
    assert(ev.errorCode == H3ErrorCode.messageError);
    assert(!serverF.isClosed);
}

/// Example:
/// ---
/// const H3HeaderField[5] authHostMatch = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "example.com"), H3HeaderField(":path", "/"),
///     H3HeaderField("host", "example.com")
/// ];
/// const H3HeaderField[5] dupHost = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":path", "/"), H3HeaderField("host", "example.com"),
///     H3HeaderField("host", "example.com")
/// ];
/// const H3HeaderField[4] emptyHost = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":path", "/"), H3HeaderField("host", "")
/// ];
/// assert(validateHeaders(authHostMatch[], false) == H3ErrorCode.noError);   // :authority == host
/// assert(validateHeaders(dupHost[], false) == H3ErrorCode.messageError);
/// assert(validateHeaders(emptyHost[], false) == H3ErrorCode.messageError);
/// ---
// Spec: RFC 9114 Section 4.3.1 - :authority and Host Header Validation (F-48)
@nogc unittest
{
    // (a) Missing both :authority and host
    const H3HeaderField[3] noAuthNoHost = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/")
    ];
    assert(validateHeaders(noAuthNoHost[], false) == H3ErrorCode.messageError);

    // (b) Mismatch between :authority and host
    const H3HeaderField[5] authHostMismatch = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"), H3HeaderField(":path",
                "/"), H3HeaderField("host", "other.com")
    ];
    assert(validateHeaders(authHostMismatch[], false) == H3ErrorCode.messageError);

    // (c) Matching :authority and host is valid
    const H3HeaderField[5] authHostMatch = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"), H3HeaderField(":path",
                "/"), H3HeaderField("host", "example.com")
    ];
    assert(validateHeaders(authHostMatch[], false) == H3ErrorCode.noError);

    // (d) Duplicate host header
    const H3HeaderField[5] dupHost = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("host", "example.com"),
        H3HeaderField("host", "example.com")
    ];
    assert(validateHeaders(dupHost[], false) == H3ErrorCode.messageError);

    // (e) Empty host header value
    const H3HeaderField[4] emptyHost = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("host", "")
    ];
    assert(validateHeaders(emptyHost[], false) == H3ErrorCode.messageError);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// StreamId greaseStream;
/// assert(quic.client.openStream(StreamDirection.unidirectional, greaseStream)
///         == TransportErrorCode.noError);
/// const ubyte[1] greaseType = [0x21];              // 0x1f * 0 + 0x21: a reserved stream type
/// assert(quic.client.streamWrite(greaseStream, greaseType[], false));
/// ubyte[1024] junk = 0xAA;
/// assert(quic.client.streamWrite(greaseStream, junk[], true));
/// quic.pump();
/// // the stream is read and discarded: no event, no error
/// H3Event ev;
/// assert(!server.pollEvent(quic.server, ev));
/// assert(!server.isClosed);
/// ---
// Spec: RFC 9114 Section 6.2 - GREASE Unidirectional Stream 1 MiB Direct Drain (F-50)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    // Open GREASE unidirectional stream (type 0x1f * N + 0x21, e.g. 0x21 = 33)
    StreamId greaseStream;
    assert(quic.client.openStream(StreamDirection.unidirectional,
            greaseStream) == TransportErrorCode.noError);
    ubyte[1] greaseType = [0x21];
    assert(quic.client.streamWrite(greaseStream, greaseType[], false));
    quic.pump();
    assert(!server.pollEvent(quic.server, ev));

    // Send 1 MiB of GREASE payload in 64 KiB chunks
    ubyte[65536] junk;
    foreach (ref b; junk)
        b = 0xAA;
    foreach (i; 0 .. 16)
    {
        const bool isFin = (i == 15);
        assert(quic.client.streamWrite(greaseStream, junk[], isFin));
        quic.pump();
        assert(!server.pollEvent(quic.server, ev));
        assert(!server.isClosed);
    }
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// // the encoder stream carries instructions towards the peer's decoder; the decoder stream
/// // carries acknowledgements back. A client writing 0x01 (Section Acknowledgment) on its
/// // decoder stream while the server never referenced a dynamic table entry is an error
/// const ubyte[1] sectionAck = [0x01];
/// assert(quic.client.streamWrite(client.localQpackDecStreamId, sectionAck[], false));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.connectionClosed
///         && ev.errorCode == H3ErrorCode.qpackDecoderStreamError);
/// ---
// Spec: RFC 9114 Section 6.2, RFC 9204 - QPACK Stream Data Rejection When Table Cap is 0 (F-49)
@nogc unittest
{
    // Client sends data on QPACK encoder stream -> qpackEncoderStreamError (0x0201)
    TestQuicPair quic1;
    assert(initTestQuicPair(quic1));
    H3Connection client1 = H3Connection(Side.client);
    H3Connection server1 = H3Connection(Side.server);
    assert(client1.initConnection(quic1.client));
    assert(server1.initConnection(quic1.server));
    quic1.pump();

    H3Event ev;
    assert(server1.pollEvent(quic1.server, ev));

    // Send instruction byte on client's existing QPACK encoder stream
    ubyte[1] encPayload = [0x80]; // Set dynamic table cap
    assert(quic1.client.streamWrite(client1.localQpackEncStreamId, encPayload[], false));
    quic1.pump();

    assert(server1.pollEvent(quic1.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.qpackEncoderStreamError);

    // Client sends data on QPACK decoder stream -> qpackDecoderStreamError (0x0202)
    TestQuicPair quic2;
    assert(initTestQuicPair(quic2));
    H3Connection client2 = H3Connection(Side.client);
    H3Connection server2 = H3Connection(Side.server);
    assert(client2.initConnection(quic2.client));
    assert(server2.initConnection(quic2.server));
    quic2.pump();
    assert(server2.pollEvent(quic2.server, ev));

    ubyte[1] decPayload = [0x01]; // Section ack
    assert(quic2.client.streamWrite(client2.localQpackDecStreamId, decPayload[], false));
    quic2.pump();

    assert(server2.pollEvent(quic2.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.qpackDecoderStreamError);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// ubyte[16] frameHdr;
/// ubyte[8] payload;
/// size_t hdrLen, payLen;
/// H3Event ev;
/// // MAX_PUSH_ID 10 is accepted ...
/// assert(encodeVarInt(10, payload[], payLen) == WireError.none);
/// assert(encodeH3FrameHeader(H3FrameType.maxPushId, payLen, frameHdr[], hdrLen));
/// assert(quic.client.streamWrite(client.localControlStreamId, frameHdr[0 .. hdrLen], false));
/// assert(quic.client.streamWrite(client.localControlStreamId, payload[0 .. payLen], false));
/// quic.pump();
/// assert(!server.pollEvent(quic.server, ev) && server.maxPushId == 10);
/// // ... a smaller value afterwards is H3_ID_ERROR
/// assert(encodeVarInt(5, payload[], payLen) == WireError.none);
/// assert(encodeH3FrameHeader(H3FrameType.maxPushId, payLen, frameHdr[], hdrLen));
/// assert(quic.client.streamWrite(client.localControlStreamId, frameHdr[0 .. hdrLen], false));
/// assert(quic.client.streamWrite(client.localControlStreamId, payload[0 .. payLen], false));
/// quic.pump();
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.idError);
/// ---
// Spec: RFC 9114 Section 4.6, Section 7.2.7 - MAX_PUSH_ID Monotonic Increase & Rejection of Decreases (F-54)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    // Client sends MAX_PUSH_ID 10 on control stream
    ubyte[16] fhdr;
    size_t fhl = 0;
    ubyte[8] p1;
    size_t pl1 = 0;
    assert(encodeVarInt(10, p1[], pl1) == WireError.none);
    assert(encodeH3FrameHeader(H3FrameType.maxPushId, pl1, fhdr[], fhl));
    assert(quic.client.streamWrite(client.localControlStreamId, fhdr[0 .. fhl], false));
    assert(quic.client.streamWrite(client.localControlStreamId, p1[0 .. pl1], false));
    quic.pump();

    assert(!server.pollEvent(quic.server, ev));
    assert(server.hasMaxPushId && server.maxPushId == 10);

    // Client sends MAX_PUSH_ID 5 (decrease) -> idError (0x0108)
    ubyte[8] p2;
    size_t pl2 = 0;
    assert(encodeVarInt(5, p2[], pl2) == WireError.none);
    assert(encodeH3FrameHeader(H3FrameType.maxPushId, pl2, fhdr[], fhl));
    assert(quic.client.streamWrite(client.localControlStreamId, fhdr[0 .. fhl], false));
    assert(quic.client.streamWrite(client.localControlStreamId, p2[0 .. pl2], false));
    quic.pump();

    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.idError);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// const H3HeaderField[4] req = [
///     H3HeaderField(":method", "DELETE"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "example.com"), H3HeaderField(":path", "/item/1")
/// ];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, req[], null, true, sid));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && server.pollEvent(quic.server, ev));
/// // a 204 with a Content-Length and no body is not malformed
/// const H3HeaderField[1] respHdrs = [H3HeaderField("content-length", "100")];
/// assert(server.sendResponse(quic.server, sid, 204, respHdrs[], null, true));
/// quic.pump();
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.headersReceived);
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.requestFinished);
/// assert(!client.isClosed);
/// ---
// Spec: RFC 9114 Section 4.1.2 - 204 No Content with Content-Length Permitted Without Data (F-55)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    const H3HeaderField[4] getReq = [
        H3HeaderField(":method", "DELETE"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"),
        H3HeaderField(":path", "/item/1")
    ];
    StreamId reqId;
    assert(client.sendRequest(quic.client, getReq[], null, true, reqId));
    quic.pump();

    assert(server.pollEvent(quic.server, ev));
    assert(server.pollEvent(quic.server, ev));

    // Server responds 204 No Content with non-zero Content-Length: 0 or 100, and 0 bytes DATA
    const H3HeaderField[1] respHdrs = [H3HeaderField("content-length", "100")];
    assert(server.sendResponse(quic.server, reqId, 204, respHdrs[], null, true));
    quic.pump();

    // Client receives headersReceived and requestFinished without error
    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(ev.headers[0].value == "204");
    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.requestFinished);
    assert(!client.isClosed);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// const H3HeaderField[4] req = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "example.com"), H3HeaderField(":path", "/test")
/// ];
/// H3Event ev;
/// // far more requests than the initial stream limit: finished streams return their credit
/// foreach (i; 0 .. 300)
/// {
///     StreamId sid;
///     assert(client.sendRequest(quic.client, req[], null, true, sid));
///     quic.pump();
///     assert(server.pollEvent(quic.server, ev) && server.pollEvent(quic.server, ev));
///     assert(server.sendResponse(quic.server, sid, 200, null, cast(const(ubyte)[]) "ok", true));
///     quic.pump();
///     assert(!server.pollEvent(quic.server, ev));   // draining releases the finished stream
///     quic.pump();
///     foreach (_; 0 .. 3)
///         assert(client.pollEvent(quic.client, ev));
///     assert(!client.pollEvent(quic.client, ev));
/// }
/// ---
// Spec: RFC 9114 Section 4.1 - 300 Sequential Requests Reaping Finished Streams and Replenishing MAX_STREAMS (F-46, D-02, D-12)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    const H3HeaderField[4] reqHdrs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"),
        H3HeaderField(":path", "/test")
    ];

    foreach (iter; 0 .. 300)
    {
        StreamId sid;
        assert(client.sendRequest(quic.client, reqHdrs[], null, true, sid));
        quic.pump();

        assert(server.pollEvent(quic.server, ev)); // headersReceived
        assert(server.pollEvent(quic.server, ev)); // requestFinished

        assert(server.sendResponse(quic.server, sid, 200, null, cast(const(ubyte)[]) "ok", true));
        quic.pump();
        // Drain so the finished stream is released and MAX_STREAMS credit is returned.
        assert(!server.pollEvent(quic.server, ev));
        quic.pump();

        assert(client.pollEvent(quic.client, ev)); // headersReceived
        assert(client.pollEvent(quic.client, ev)); // dataReceived
        assert(client.pollEvent(quic.client, ev)); // requestFinished
        // Draining the queue releases the finished stream (sendRequest itself never does).
        assert(!client.pollEvent(quic.client, ev));
    }
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// // a server may not open request streams: the client aborts with H3_STREAM_CREATION_ERROR
/// StreamId srvBidi;
/// assert(quic.server.openStream(StreamDirection.bidirectional, srvBidi) == TransportErrorCode.noError);
/// const ubyte[4] dummy = [0, 0, 0, 0];
/// assert(quic.server.streamWrite(srvBidi, dummy[], false));
/// quic.pump();
/// H3Event ev;
/// assert(client.pollEvent(quic.client, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.streamCreationError);
/// ---
// Spec: RFC 9114 Section 6.1 - Client Rejection of Server-Initiated Bidirectional Streams (F-52)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    // Server opens a bidirectional stream (server-initiated bidi, type 0x01)
    StreamId srvBidi;
    assert(quic.server.openStream(StreamDirection.bidirectional,
            srvBidi) == TransportErrorCode.noError);
    ubyte[4] dummy = [0x00, 0x00, 0x00, 0x00];
    assert(quic.server.streamWrite(srvBidi, dummy[], false));
    quic.pump();

    // Client detects server-initiated bidi and aborts with streamCreationError (0x0103)
    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.streamCreationError);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// assert(server.sendGoaway(quic.server, 0));
/// quic.pump();
/// H3Event ev;
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.goawayReceived);
/// // after GOAWAY the client sends no new request ...
/// const H3HeaderField[4] reqHdrs = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "example.com"), H3HeaderField(":path", "/")
/// ];
/// StreamId sid;
/// assert(!client.sendRequest(quic.client, reqHdrs[], null, true, sid));
/// // ... and the server cannot raise the identifier it announced
/// assert(!server.sendGoaway(quic.server, 4));
/// ---
// Spec: RFC 9114 Section 5.2 - GOAWAY Enforcement: Reject sendRequest After GOAWAY & Enforce Monotonic Decreases (F-53)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    // Server sends GOAWAY with StreamId 0
    assert(server.sendGoaway(quic.server, 0));
    quic.pump();

    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.goawayReceived);

    // Client attempts sendRequest after GOAWAY -> must be rejected
    const H3HeaderField[4] reqHdrs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"), H3HeaderField(":path", "/")
    ];
    StreamId sid;
    assert(!client.sendRequest(quic.client, reqHdrs[], null, true, sid));

    // Server attempts sendGoaway with larger stream ID (increase) -> rejected
    assert(!server.sendGoaway(quic.server, 4));
}

/// Example:
/// ---
/// // the control stream ends in the middle of a frame header
/// TestQuicPair quic;
/// assert(initTestQuicPair(quic));
/// H3Connection server = H3Connection(Side.server);
/// StreamId ctlStream;
/// assert(quic.client.openStream(StreamDirection.unidirectional, ctlStream)
///         == TransportErrorCode.noError);
/// const ubyte[2] partialFrame = [0x00, 0x04];      // stream type 0x00, then a lone frame type byte
/// assert(quic.client.streamWrite(ctlStream, partialFrame[], true));   // FIN
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.connectionClosed && ev.errorCode == H3ErrorCode.frameError);
/// ---
// Spec: RFC 9114 Section 6.2.1 - Control Stream Frame Parsing Before FIN & Critical Stream Closure (F-51)
@nogc unittest
{
    // Peer opens Control Stream, writes incomplete frame header, and sends FIN -> frameError (0x0106)
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection server = H3Connection(Side.server);
    H3Event ev;

    StreamId ctlStream;
    assert(quic.client.openStream(StreamDirection.unidirectional,
            ctlStream) == TransportErrorCode.noError);
    // Write stream type 0x00, but partial frame header (1 byte of frame type 0x04) with FIN = true
    ubyte[2] partialFrame = [0x00, 0x04];
    assert(quic.client.streamWrite(ctlStream, partialFrame[], true));
    quic.pump();

    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.frameError);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// char[8000] bigVal = 'a';
/// const H3HeaderField[5] bigHdrs = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "example.com"), H3HeaderField(":path", "/"),
///     H3HeaderField("x-large", bigVal[])
/// ];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, bigHdrs[], null, true, sid));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
/// assert(ev.headers[4].name == "x-large" && ev.headers[4].value.length == 8000);
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
/// // once the peer announced a smaller SETTINGS_MAX_FIELD_SECTION_SIZE the same request is refused
/// client.peerSettings.maxFieldSectionSize = 100;
/// StreamId badSid;
/// assert(!client.sendRequest(quic.client, bigHdrs[], null, true, badSid));
/// ---
// Spec: RFC 9114 Section 4.3.1, Section 7.2.4.1 - 8 KiB HTTP/3 Header Block & maxFieldSectionSize Enforcement (F-56, D-11, D-12)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();

    H3Event ev;
    assert(client.pollEvent(quic.client, ev));
    assert(server.pollEvent(quic.server, ev));

    // Construct 8 KiB header value
    char[8000] bigVal;
    foreach (ref c; bigVal)
        c = 'a';

    const H3HeaderField[5] bigHdrs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"), H3HeaderField(":path",
                "/"), H3HeaderField("x-large", bigVal[])
    ];

    StreamId sid;
    assert(client.sendRequest(quic.client, bigHdrs[], null, true, sid));
    quic.pump();

    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.headersReceived);
    assert(ev.headerCount == 5);
    assert(ev.headers[4].name == "x-large");
    assert(ev.headers[4].value.length == 8000);
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.requestFinished);

    // Verify rejection when outbound headers exceed peerSettings.maxFieldSectionSize
    client.peerSettings.maxFieldSectionSize = 100;
    StreamId badSid;
    assert(!client.sendRequest(quic.client, bigHdrs[], null, true, badSid));
}

version (unittest)
{
    /// Brings up an H3 client/server pair over a handshaken TestQuicPair and drains SETTINGS.
    private void initH3Pair(ref TestQuicPair quic, ref H3Connection client, ref H3Connection server) @nogc nothrow
    {
        assert(initTestQuicPair(quic));
        assert(client.initConnection(quic.client));
        assert(server.initConnection(quic.server));
        quic.pump();
        H3Event ev;
        assert(client.pollEvent(quic.client, ev));
        assert(ev.type == H3EventType.peerSettingsReceived);
        assert(server.pollEvent(quic.server, ev));
        assert(ev.type == H3EventType.peerSettingsReceived);
    }
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
///
/// const H3HeaderField[4] reqHdrs = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/x")
/// ];
/// StreamId streamA, streamB;
/// assert(client.sendRequest(quic.client, reqHdrs[], null, true, streamA));
/// assert(client.sendRequest(quic.client, reqHdrs[], null, true, streamB));
/// quic.pump();
/// H3Event ev;
/// while (server.pollEvent(quic.server, ev)) {}   // drain the request events
///
/// // Response A declares content-length: 3 but carries 5 bytes; response B is fine.
/// const H3HeaderField[1] badCl = [H3HeaderField("content-length", "3")];
/// assert(server.sendResponse(quic.server, streamA, 200, badCl[], cast(const(ubyte)[]) "12345", false));
/// assert(server.sendResponse(quic.server, streamB, 200, null, cast(const(ubyte)[]) "ok", true));
/// quic.pump();
///
/// bool aReset, bFinished;
/// while (client.pollEvent(quic.client, ev))
/// {
///     aReset = aReset || (ev.streamId == streamA && ev.type == H3EventType.streamReset
///             && ev.errorCode == H3ErrorCode.messageError);
///     bFinished = bFinished || (ev.streamId == streamB && ev.type == H3EventType.requestFinished);
/// }
/// assert(aReset && bFinished && !client.isClosed);
/// ---
// Spec: RFC 9114 Section 4.1.2 - a malformed response is a stream error of type
// H3_MESSAGE_ERROR, not a connection error (R-12, W4, Scenario T9)
@nogc unittest
{
    TestQuicPair quic;
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    initH3Pair(quic, client, server);

    const H3HeaderField[4] reqHdrs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/x")
    ];
    StreamId streamA, streamB;
    assert(client.sendRequest(quic.client, reqHdrs[], null, true, streamA));
    assert(client.sendRequest(quic.client, reqHdrs[], null, true, streamB));
    quic.pump();

    H3Event ev;
    size_t serverEvents = 0;
    while (server.pollEvent(quic.server, ev))
    {
        assert(ev.type == H3EventType.headersReceived || ev.type == H3EventType.requestFinished);
        serverEvents++;
    }
    assert(serverEvents == 4);

    // Stream A: content-length 3 but 5 bytes of DATA, and the server keeps sending (no FIN).
    const H3HeaderField[1] badCl = [H3HeaderField("content-length", "3")];
    assert(server.sendResponse(quic.server, streamA, 200, badCl[],
            cast(const(ubyte)[]) "12345", false));
    assert(server.sendResponse(quic.server, streamB, 200, null, cast(const(ubyte)[]) "ok", true));
    quic.pump();

    bool aReset = false, aFinished = false;
    bool bHeaders = false, bData = false, bFinished = false;
    while (client.pollEvent(quic.client, ev))
    {
        assert(ev.type != H3EventType.connectionClosed);
        if (ev.streamId == streamA)
        {
            if (ev.type == H3EventType.streamReset)
            {
                assert(ev.errorCode == H3ErrorCode.messageError);
                assert(!aReset);
                aReset = true;
            }
            else if (ev.type == H3EventType.requestFinished)
                aFinished = true;
        }
        else if (ev.streamId == streamB)
        {
            if (ev.type == H3EventType.headersReceived)
                bHeaders = true;
            else if (ev.type == H3EventType.dataReceived)
            {
                assert(ev.data == cast(const(ubyte)[]) "ok");
                bData = true;
            }
            else if (ev.type == H3EventType.requestFinished)
                bFinished = true;
            else
                assert(false, "unexpected event on stream B");
        }
    }
    assert(aReset && !aFinished);
    assert(bHeaders && bData && bFinished);
    assert(!client.isClosed);

    // The server learns about the stream error through STOP_SENDING (H3_MESSAGE_ERROR).
    quic.pump();
    bool sawStop = false;
    ConnectionEvent qev;
    while (quic.server.pollEvent(qev))
    {
        if (qev.type == ConnectionEventType.stopSending && qev.streamId == streamA.id)
        {
            assert(qev.errorCode == H3ErrorCode.messageError);
            sawStop = true;
        }
        assert(qev.type != ConnectionEventType.connectionClosed);
    }
    assert(sawStop);

    // Late peer data on the reset stream is discarded without events or a connection error.
    ubyte[6] lateData = [0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF];
    cast(void) quic.server.streamWrite(streamA, lateData[], true);
    quic.pump();
    while (client.pollEvent(quic.client, ev))
        assert(ev.streamId != streamA && ev.type != H3EventType.connectionClosed);
    assert(!client.isClosed);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
///
/// const H3HeaderField[4] headReq = [
///     H3HeaderField(":method", "HEAD"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/big")
/// ];
/// const H3HeaderField[1] cl = [H3HeaderField("content-length", "1234")];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, headReq[], null, true, sid));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
///
/// // The response to HEAD announces 1234 bytes but has no DATA: that is allowed.
/// assert(server.sendResponse(quic.server, sid, 200, cl[], null, true));
/// quic.pump();
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.headersReceived && ev.fin);
/// assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.requestFinished);
/// assert(!client.isClosed);
/// ---
// Spec: RFC 9114 Section 4.1.2 and RFC 9110 Section 9.3.2 / 8.6 - a response to HEAD has no
// content; a non-zero content-length is permitted without DATA (R-08, E4, Scenario T8)
@nogc unittest
{
    TestQuicPair quic;
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    initH3Pair(quic, client, server);

    const H3HeaderField[4] headReq = [
        H3HeaderField(":method", "HEAD"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/big")
    ];
    const H3HeaderField[4] getReq = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/big")
    ];
    const H3HeaderField[1] cl = [H3HeaderField("content-length", "1234")];

    // T8: HEAD + content-length + FIN without DATA -> success.
    StreamId headSid;
    assert(client.sendRequest(quic.client, headReq[], null, true, headSid));
    quic.pump();
    H3Event ev;
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
    assert(server.sendResponse(quic.server, headSid, 200, cl[], null, true));
    quic.pump();

    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.headersReceived && ev.streamId == headSid);
    assert(ev.fin);
    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.requestFinished && ev.streamId == headSid);
    assert(!client.pollEvent(quic.client, ev));
    assert(!client.isClosed);

    // W: the same response to GET is a content-length underrun -> stream reset.
    StreamId getSid;
    assert(client.sendRequest(quic.client, getReq[], null, true, getSid));
    quic.pump();
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
    assert(server.sendResponse(quic.server, getSid, 200, cl[], null, true));
    quic.pump();
    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.streamReset && ev.streamId == getSid);
    assert(ev.errorCode == H3ErrorCode.messageError);
    assert(!client.isClosed);

    // W: DATA in a response to HEAD is malformed -> stream reset.
    StreamId headSid2;
    assert(client.sendRequest(quic.client, headReq[], null, true, headSid2));
    quic.pump();
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
    assert(server.sendResponse(quic.server, headSid2, 200, null, cast(const(ubyte)[]) "body", true));
    quic.pump();
    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.headersReceived && ev.streamId == headSid2);
    assert(client.pollEvent(quic.client, ev));
    assert(ev.type == H3EventType.streamReset && ev.streamId == headSid2);
    assert(ev.errorCode == H3ErrorCode.messageError);
    assert(!client.isClosed);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
///
/// const H3HeaderField[4] reqHdrs = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/sse")
/// ];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, reqHdrs[], null, true, sid));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
/// const H3HeaderField[1] ct = [H3HeaderField("content-type", "text/event-stream")];
/// assert(server.sendResponse(quic.server, sid, 200, ct[], null, false));
///
/// // The server keeps writing 8-byte DATA frames; the client consumes them as they arrive.
/// ubyte[10] frame = [0x00, 8, 1, 2, 3, 4, 5, 6, 7, 8];   // DATA, length 8, payload
/// assert(quic.server.streamWrite(sid, frame[], false));
/// quic.pump();
/// size_t bytesReceived;
/// while (client.pollEvent(quic.client, ev))
///     if (ev.type == H3EventType.dataReceived)
///         bytesReceived += ev.data.length;
/// assert(bytesReceived == 8 && !client.isClosed);
/// ---
// Spec: RFC 9000 Section 4.1 (flow control credit follows consumption) and RFC 9114
// Section 4.1 (any number of DATA frames per message) - back-pressure (R-07, S1, Scenario T7)
@nogc unittest
{
    TestQuicPair quic;
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    initH3Pair(quic, client, server);

    const H3HeaderField[4] reqHdrs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/sse")
    ];
    StreamId sid;
    assert(client.sendRequest(quic.client, reqHdrs[], null, true, sid));
    quic.pump();
    H3Event ev;
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
    const H3HeaderField[1] ct = [
        H3HeaderField("content-type", "text/event-stream")
    ];
    assert(server.sendResponse(quic.server, sid, 200, ct[], null, false));

    // 1.5 MB on the wire: more than MAX_STREAM_BUFFER_SIZE, so unbounded buffering must fail.
    enum size_t FRAME_COUNT = 150_000;
    enum size_t FRAMES_PER_WRITE = 1000;
    ubyte[FRAMES_PER_WRITE * 10] chunk;
    size_t framesWritten = 0;
    size_t bytesReceived = 0;
    size_t dataEvents = 0;
    bool headersSeen = false;
    bool finished = false;

    bool writeMore() @nogc nothrow
    {
        if (framesWritten >= FRAME_COUNT)
            return false;
        const size_t left = FRAME_COUNT - framesWritten;
        const size_t n = left < FRAMES_PER_WRITE ? left : FRAMES_PER_WRITE;
        foreach (k; 0 .. n)
        {
            const size_t f = framesWritten + k;
            chunk[k * 10] = 0x00; // DATA
            chunk[k * 10 + 1] = 8; // length
            foreach (j; 0 .. 8)
                chunk[k * 10 + 2 + j] = cast(ubyte)(f * 8 + j);
        }
        const bool fin = (framesWritten + n == FRAME_COUNT);
        assert(quic.server.streamWrite(sid, chunk[0 .. n * 10], fin));
        framesWritten += n;
        return true;
    }

    void handle(ref const H3Event e) @nogc nothrow
    {
        assert(e.type != H3EventType.connectionClosed, "connection aborted under load");
        assert(e.type != H3EventType.streamReset);
        assert(e.streamId == sid);
        if (e.type == H3EventType.headersReceived)
            headersSeen = true;
        else if (e.type == H3EventType.dataReceived)
        {
            assert(e.data.length == 8);
            foreach (b; e.data)
                assert(b == cast(ubyte)(bytesReceived++));
            dataEvents++;
        }
        else if (e.type == H3EventType.requestFinished)
            finished = true;
    }

    // Phase 1: the server writes faster than the application consumes.
    foreach (round; 0 .. 300)
    {
        writeMore();
        quic.pump();
        foreach (_; 0 .. 16)
        {
            if (!client.pollEvent(quic.client, ev))
                break;
            handle(ev);
        }
        assert(!client.isClosed);
    }

    // S1: H3 stopped pulling from QUIC, so unread bytes remain queued in the QUIC stream and
    // the H3 side has consumed only a bounded prefix of what the server sent.
    auto qs = quic.client.streams.getStream(sid);
    assert(qs !is null);
    assert(qs.recvBuf.readableBytes > 0);
    assert(qs.recvBuf.readOffset <= bytesReceived * 10 / 8 + H3_RECV_HIGH_WATER + 4096 + 512);

    // Phase 2: drain everything, pumping whenever no event is ready.
    size_t idle = 0;
    while (!finished && idle < 2000)
    {
        if (client.pollEvent(quic.client, ev))
        {
            handle(ev);
            idle = 0;
        }
        else
        {
            writeMore();
            quic.pump();
            idle++;
        }
    }
    assert(finished);
    assert(headersSeen);
    assert(dataEvents == FRAME_COUNT);
    assert(bytesReceived == FRAME_COUNT * 8);
    assert(!client.isClosed);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// const H3HeaderField[4] req = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/")
/// ];
/// client.occupyTrackerSlots(1);                    // one free tracker slot: the request goes out
/// StreamId first;
/// assert(client.sendRequest(quic.client, req[], null, true, first) && first.id == 0);
/// client.occupyTrackerSlots(0);                    // every tracker slot is taken
/// StreamId refused;
/// assert(!client.sendRequest(quic.client, req[], null, true, refused));   // refused up front
/// assert(!client.isClosed);
/// // no QUIC stream was opened for it, so the next stream id is still 4
/// StreamId probe;
/// assert(quic.client.openStream(StreamDirection.bidirectional, probe) == TransportErrorCode.noError);
/// assert(probe.id == 4);
/// ---
// Spec: Best practice: a request that cannot be tracked must fail before anything is written
// or opened - no half-open stream, no consumed stream id (RFC 9114 Section 4.1; L7, plan R-12)
@nogc unittest
{
    TestQuicPair quic;
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    initH3Pair(quic, client, server);

    const H3HeaderField[4] req = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/")
    ];

    // One free slot: the request goes through and takes the first stream id.
    client.occupyTrackerSlots(1);
    StreamId first;
    assert(client.sendRequest(quic.client, req[], null, true, first));
    assert(first.id == 0);

    // No free slot: refused, nothing on the wire, no stream id consumed, connection healthy.
    client.occupyTrackerSlots(0);
    StreamId refused;
    assert(!client.sendRequest(quic.client, req[], null, true, refused));
    assert(!client.isClosed);
    StreamId probe;
    assert(quic.client.openStream(StreamDirection.bidirectional,
            probe) == TransportErrorCode.noError);
    assert(probe.id == 4, "the refused request must not have opened a QUIC stream");
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// const H3HeaderField[4] req = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/")
/// ];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, req[], null, true, sid));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
/// assert(server.sendResponse(quic.server, sid, 200, null, cast(immutable(ubyte)[]) "body", false));
/// quic.pump();
///
/// // Take a data event, then exhaust the tracker slots: a refused sendRequest must not free the
/// // buffer behind the slice the caller still holds.
/// while (client.pollEvent(quic.client, ev) && ev.type != H3EventType.dataReceived) {}
/// const(ubyte)[] held = ev.data;
/// client.occupyTrackerSlots(0);
/// StreamId refused;
/// assert(!client.sendRequest(quic.client, req[], null, true, refused));
/// assert(held == cast(const(ubyte)[]) "body");
/// ---
// Spec: Best practice: event slices stay valid until the next pollEvent (the header slices of a
// headersReceived event end with the next poll) - sendRequest must never release the buffers
// behind the still-valid ones (use-after-free, Round 2 item 3; RFC 9114 Section 4.1)
@trusted @nogc unittest
{
    import core.stdc.stdlib : free, malloc;
    import core.stdc.string : memset;

    TestQuicPair quic;
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    initH3Pair(quic, client, server);

    const H3HeaderField[4] req = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/")
    ];
    StreamId sid;
    assert(client.sendRequest(quic.client, req[], null, true, sid));
    quic.pump();
    H3Event ev;
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
    const H3HeaderField[1] extra = [
        H3HeaderField("x-token", "0123456789abcdef")
    ];
    immutable(ubyte)[] body = cast(immutable(ubyte)[]) "payload-of-the-response";
    assert(server.sendResponse(quic.server, sid, 200, extra[], body, true));
    quic.pump();

    // The header slices are valid until the next pollEvent: read them now, before it.
    assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.headersReceived);
    size_t tokenLen = 0;
    foreach (ref h; ev.headers[0 .. ev.headerCount])
    {
        if (h.name == "x-token")
            tokenLen = h.value.length;
    }
    assert(tokenLen == 16);
    // Hold the data slice exactly as a caller would (valid until the next pollEvent).
    assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.dataReceived);
    const(ubyte)[] dataSlice = ev.data;
    ubyte[64] dataCopy;
    dataCopy[0 .. dataSlice.length] = dataSlice[];
    const size_t dataLen = dataSlice.length;
    assert(dataLen == body.length);

    // requestFinished is still queued; with every slot taken the request is refused rather
    // than a tracker being released under the caller's feet.
    client.occupyTrackerSlots(0);
    StreamId refused;
    assert(!client.sendRequest(quic.client, req[], null, true, refused));

    // Reuse freed memory the way an allocator would.
    ubyte*[16] junk;
    foreach (ref j; junk)
    {
        j = cast(ubyte*) malloc(4096);
        memset(j, 0xAA, 4096);
    }
    scope (exit)
        foreach (j; junk)
            free(j);

    assert(dataSlice[0 .. dataLen] == dataCopy[0 .. dataLen], "data slice was freed");

    // The terminal event is still delivered, and the finished stream is released afterwards.
    assert(client.pollEvent(quic.client, ev) && ev.type == H3EventType.requestFinished);
    assert(!client.pollEvent(quic.client, ev));
    StreamId next;
    assert(client.sendRequest(quic.client, req[], null, true, next));
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
///
/// const H3HeaderField[4] req = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/")
/// ];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, req[], null, true, sid));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
/// assert(server.sendResponse(quic.server, sid, 200, null, cast(immutable(ubyte)[]) "partial", false));
/// quic.pump();
/// while (client.pollEvent(quic.client, ev) && ev.type != H3EventType.dataReceived) {}
/// const(ubyte)[] held = ev.data;   // the caller keeps the slice ...
///
/// quic.server.resetStream(sid, cast(ulong) H3ErrorCode.requestCancelled);
/// quic.pump();                     // ... while the peer resets the stream
/// assert(held == cast(const(ubyte)[]) "partial");   // its buffer was not released
/// ---
// Spec: RFC 9114 Section 4.1.1 / Best practice: a peer RESET_STREAM must not release buffers
// behind events that were queued or just polled (Round 2 item 3, reset variant)
@trusted @nogc unittest
{
    import core.stdc.stdlib : free, malloc;
    import core.stdc.string : memset;

    TestQuicPair quic;
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    initH3Pair(quic, client, server);

    const H3HeaderField[4] req = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/")
    ];
    StreamId sid;
    assert(client.sendRequest(quic.client, req[], null, true, sid));
    quic.pump();
    H3Event ev;
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.requestFinished);
    immutable(ubyte)[] body = cast(immutable(ubyte)[]) "partial-response-body";
    assert(server.sendResponse(quic.server, sid, 200, null, body, false));
    quic.pump();

    ubyte[64] dataCopy;
    const(ubyte)[] dataSlice;
    bool gotData = false;
    while (client.pollEvent(quic.client, ev))
    {
        if (ev.type == H3EventType.dataReceived)
        {
            dataSlice = ev.data;
            dataCopy[0 .. dataSlice.length] = dataSlice[];
            gotData = true;
            break; // keep the slice, do not poll again yet
        }
    }
    assert(gotData);

    // The peer resets the stream while the caller still holds the slice.
    quic.server.resetStream(sid, cast(ulong) H3ErrorCode.requestCancelled);
    quic.pump();
    client.occupyTrackerSlots(0);
    StreamId refused;
    assert(!client.sendRequest(quic.client, req[], null, true, refused));
    ubyte*[16] junk;
    foreach (ref j; junk)
    {
        j = cast(ubyte*) malloc(4096);
        memset(j, 0xAA, 4096);
    }
    scope (exit)
        foreach (j; junk)
            free(j);
    assert(dataSlice == dataCopy[0 .. dataSlice.length], "data slice was freed");

    // The reset is processed by the next poll, which may now release the stream.
    while (client.pollEvent(quic.client, ev))
    {
    }
    assert(!client.pollEvent(quic.client, ev)); // releases the reset stream
    StreamId next;
    assert(client.sendRequest(quic.client, req[], null, true, next));
}

/// Example:
/// ---
/// TestQuicPair quic;
/// assert(initTestQuicPair(quic));
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// assert(client.initConnection(quic.client) && server.initConnection(quic.server));
/// quic.pump();
///
/// // Set Dynamic Table Capacity 0 (0x20) on the encoder stream is legal with a zero-capacity table.
/// const ubyte[1] cap0 = [0x20];
/// assert(quic.client.streamWrite(client.localQpackEncStreamId, cap0[], false));
/// quic.pump();
/// H3Event ev;
/// while (server.pollEvent(quic.server, ev))
///     assert(ev.type != H3EventType.connectionClosed);
/// assert(!server.isClosed);
/// ---
// Spec: RFC 9204 Section 4.3.1 - Set Dynamic Table Capacity (`001` prefix, 0x20 for capacity 0) and
// Section 4.4.2 - Stream Cancellation (`01` prefix) are valid with a zero-capacity table, while
// insertions, Section Acknowledgment and Insert Count Increment are errors (R-22, U5)
@nogc unittest
{
    static bool survives(bool encoderStream, const(ubyte)[] payload) @nogc
    {
        TestQuicPair quic;
        if (!initTestQuicPair(quic))
            return false;
        H3Connection client = H3Connection(Side.client);
        H3Connection server = H3Connection(Side.server);
        if (!client.initConnection(quic.client) || !server.initConnection(quic.server))
            return false;
        quic.pump();
        H3Event ev;
        while (server.pollEvent(quic.server, ev))
        {
        }
        const sid = encoderStream ? client.localQpackEncStreamId : client.localQpackDecStreamId;
        if (!quic.client.streamWrite(sid, payload, false))
            return false;
        quic.pump();
        while (server.pollEvent(quic.server, ev))
        {
            if (ev.type == H3EventType.connectionClosed)
                return false;
        }
        return !server.isClosed;
    }

    const ubyte[1] cap0 = [0x20];
    const ubyte[1] cap5 = [0x25];
    const ubyte[1] insert = [0x80];
    const ubyte[1] duplicate = [0x00];
    assert(survives(true, cap0[]), "capacity 0 is legal");
    assert(!survives(true, cap5[]), "capacity above the limit");
    assert(!survives(true, insert[]), "insert needs capacity");
    assert(!survives(true, duplicate[]));

    const ubyte[1] cancel = [0x44];
    const ubyte[3] cancelLong = [0x7f, 0x80, 0x01]; // multi-byte stream id
    const ubyte[1] ack = [0x84];
    const ubyte[1] increment = [0x01];
    assert(survives(false, cancel[]), "stream cancellation is legal");
    assert(survives(false, cancelLong[]), "multi-byte stream ids are legal");
    assert(!survives(false, ack[]), "no dynamic table references exist to acknowledge");
    assert(!survives(false, increment[]), "nothing was inserted");
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// const H3HeaderField[4] headers = [
///     H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/abandoned")
/// ];
/// const ubyte[3] part = [1, 2, 3];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, headers[], part[], false, sid));
/// quic.pump();
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
/// while (server.pollEvent(quic.server, ev))
/// {
/// }
/// const baseline = server.trackedStreamCount;
/// // the peer abandons the incomplete request: the application is told, the tracker is released
/// quic.client.resetStream(sid, 0x10c);
/// quic.pump();
/// assert(server.pollEvent(quic.server, ev));
/// assert(ev.type == H3EventType.streamReset && ev.streamId == sid && ev.errorCode == 0x10c);
/// assert(!server.isClosed && !server.pollEvent(quic.server, ev));
/// assert(server.trackedStreamCount == baseline - 1);
/// ---
// Spec: RFC 9114 Section 4.1.1 / 4.1.2 - a request stream the peer resets before it completed is
// abandoned; the endpoint reports it (H3EventType.streamReset with the peer's code) and, per
// RFC 9000 Section 3.5, late data for the stream is ignored and never resurrects a tracker; a
// stream this endpoint reset itself is released without waiting for the peer's FIN (R-23, PB-4, E7)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();
    H3Event ev;
    while (server.pollEvent(quic.server, ev))
    {
    }
    while (client.pollEvent(quic.client, ev))
    {
    }

    const H3HeaderField[4] headers = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"),
        H3HeaderField(":path", "/abandoned")
    ];
    const ubyte[3] part = [1, 2, 3];
    StreamId sid;
    assert(client.sendRequest(quic.client, headers[], part[], false, sid));
    quic.pump();
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
    while (server.pollEvent(quic.server, ev))
    {
    }
    const baseline = server.trackedStreamCount; // control + QPACK streams
    assert(baseline >= 1);

    quic.client.resetStream(sid, 0x10c);
    quic.pump();
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.streamReset && ev.streamId == sid && ev.errorCode == 0x10c);
    assert(!server.isClosed);
    assert(!server.pollEvent(quic.server, ev));
    assert(server.trackedStreamCount == baseline - 1, "the reset stream is released");
    quic.pump();
    assert(!server.pollEvent(quic.server, ev), "late events do not resurrect it");
    assert(server.trackedStreamCount == baseline - 1);

    // A stream the server resets itself (content-length mismatch) is released without the
    // client ever sending a FIN.
    const H3HeaderField[5] lenHeaders = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path",
                "/bad"), H3HeaderField("content-length", "2")
    ];
    StreamId bad;
    assert(client.sendRequest(quic.client, lenHeaders[], part[], false, bad));
    quic.pump();
    bool sawReset = false;
    foreach (_; 0 .. 8)
    {
        if (!server.pollEvent(quic.server, ev))
            break;
        sawReset = sawReset || (ev.type == H3EventType.streamReset && ev.streamId == bad);
    }
    assert(sawReset);
    assert(!server.pollEvent(quic.server, ev));
    assert(server.trackedStreamCount == baseline - 1,
            "a locally reset stream is not pinned until the peer's FIN");
    quic.pump();
    assert(!server.pollEvent(quic.server, ev));
    assert(server.trackedStreamCount == baseline - 1);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
/// // a HEADERS frame of 150 000 bytes, far above the 64 KiB field-section limit
/// ubyte[150_005] frame;
/// const ubyte[5] head = [0x01, 0x80, 0x02, 0x49, 0xF0];
/// frame[0 .. 5] = head[];
/// StreamId sid;
/// assert(quic.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// assert(quic.client.streamWrite(sid, frame[], false));
/// quic.pump();
/// quic.client.resetStream(sid, 0x10c);             // and RESET_STREAM right behind it
/// H3Event ev;
/// foreach (_; 0 .. 60)
/// {
///     quic.pump();
///     while (server.pollEvent(quic.server, ev))
///     {
///     }
///     // connection credit never exceeds the bytes actually received
///     assert(quic.server.streams.connFlow.readOffset <= quic.server.streams.connFlow.highestReceived);
/// }
/// ---
// Spec: RFC 9000 Section 4.1 "A receiver maintains a cumulative sum of bytes received on all
// streams, which is used to check for violations of the advertised connection or stream data
// limits." - the connection window may only be extended for bytes that were received: an
// oversized HEADERS frame (the server abandons the stream) followed by the peer's RESET_STREAM
// must credit each byte once, so MAX_DATA never grows beyond the bytes consumed (PB-4, M2)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();
    H3Event ev;
    while (server.pollEvent(quic.server, ev))
    {
    }
    while (client.pollEvent(quic.client, ev))
    {
    }

    // HEADERS frame (type 0x01, 4-byte length 150 000) over the 64 KiB default limit.
    ubyte[150_005] frame;
    static immutable ubyte[5] head = [0x01, 0x80, 0x02, 0x49, 0xF0];
    frame[0 .. 5] = head[];
    StreamId sid;
    assert(quic.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    assert(quic.client.streamWrite(sid, frame[0 .. 5], false));
    assert(quic.client.streamWrite(sid, frame[5 .. $], false));
    quic.pump();
    quic.client.resetStream(sid, 0x10c);

    foreach (_; 0 .. 60)
    {
        quic.pump();
        while (server.pollEvent(quic.server, ev))
        {
        }
        while (client.pollEvent(quic.client, ev))
        {
        }
        assert(quic.server.streams.connFlow.readOffset <= quic.server.streams.connFlow.highestReceived,
                "connection credit must never exceed the bytes received");
    }
    assert(quic.server.streams.connFlow.highestReceived > 0, "the peer's data did arrive in QUIC");
    assert(quic.server.streams.connFlow.readOffset == quic.server.streams.connFlow.highestReceived,
            "the discarded bytes are credited exactly once");
}

/// Example:
/// ---
/// TestQuicPair quic;
/// assert(initTestQuicPair(quic));
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// assert(client.initConnection(quic.client) && server.initConnection(quic.server));
/// quic.pump();
///
/// // A POST declares content-length 2 but carries 200 000 body bytes: the server resets it early.
/// const H3HeaderField[5] headers = [
///     H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/probe"),
///     H3HeaderField("content-length", "2")
/// ];
/// ubyte[200_000] body;
/// StreamId sid;
/// assert(client.sendRequest(quic.client, headers[], body[], true, sid));
/// foreach (_; 0 .. 60)
/// {
///     quic.pump();
///     H3Event ev;
///     while (server.pollEvent(quic.server, ev)) {}
/// }
/// // The unread bytes were credited back to the connection.
/// assert(quic.server.streams.connFlow.readOffset == quic.server.streams.connFlow.highestReceived);
/// ---
// Spec: RFC 9000 Section 4.1 "A receiver maintains a cumulative sum of bytes received on all
// streams, which is used to check for violations of the advertised connection or stream data
// limits." - bytes of a locally reset request stream are never read by the application, so the
// QUIC layer must discard them and still return their connection credit (PB-4, M2)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();
    H3Event ev;
    while (server.pollEvent(quic.server, ev))
    {
    }
    while (client.pollEvent(quic.client, ev))
    {
    }

    // content-length 2 but 200 000 body bytes and the FIN: the server resets on the first DATA frame
    // header, long before the client's data has been read out of QUIC.
    const H3HeaderField[5] headers = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path",
                "/probe"), H3HeaderField("content-length", "2")
    ];
    ubyte[200_000] body;
    body[] = 0x5a;
    StreamId sid;
    assert(client.sendRequest(quic.client, headers[], body[], true, sid));
    bool sawReset = false;
    foreach (_; 0 .. 60)
    {
        quic.pump();
        while (server.pollEvent(quic.server, ev))
            sawReset = sawReset || (ev.type == H3EventType.streamReset && ev.streamId == sid);
        while (client.pollEvent(quic.client, ev))
        {
        }
    }
    assert(sawReset);
    assert(quic.server.streams.connFlow.highestReceived > 190_000,
            "the peer's data did arrive in QUIC");
    assert(quic.server.streams.connFlow.readOffset == quic.server.streams.connFlow.highestReceived,
            "every received byte of the abandoned stream was credited to the connection");
    assert(quic.server.streams.getStream(sid) is null, "the QUIC stream was reaped");

    // The connection stays usable: a new request is served.
    StreamId next;
    const H3HeaderField[4] ok = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/next")
    ];
    assert(client.sendRequest(quic.client, ok[], null, true, next));
    quic.pump();
    bool gotNext = false;
    while (server.pollEvent(quic.server, ev))
        gotNext = gotNext || (ev.type == H3EventType.headersReceived && ev.streamId == next);
    assert(gotNext);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// assert(initTestQuicPair(quic, 4 * 1024 * 1024));   // stream window above MAX_STREAM_BUFFER_SIZE
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// assert(client.initConnection(quic.client) && server.initConnection(quic.server));
/// quic.pump();
///
/// // A HEADERS frame announcing 3 000 000 bytes, followed by a flood of payload.
/// StreamId sid;
/// assert(quic.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[16] fh;
/// size_t fhLen;
/// assert(encodeH3FrameHeader(H3FrameType.headers, 3_000_000, fh[], fhLen));
/// assert(quic.client.streamWrite(sid, fh[0 .. fhLen], false));
/// ubyte[4000] chunk;
/// assert(quic.client.streamWrite(sid, chunk[], false));
/// quic.pump();
///
/// H3Event ev;
/// bool sawReset;
/// while (server.pollEvent(quic.server, ev))
///     sawReset = sawReset || ev.type == H3EventType.streamReset;
/// assert(sawReset && !server.isClosed);   // the stream fails at once, the connection stays up
/// ---
// Spec: RFC 9114 Section 4.2.2 "An HTTP/3 implementation MAY impose a limit on the maximum size of
// the message header it will accept on an individual HTTP message." - with a receive window
// larger than the stream buffer, the announced length alone must trigger the stream error; the
// frame is not "incomplete" and waiting for it must not buffer up to the window (which would
// abort the whole connection with excessiveLoad) (L1)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic, 4 * 1024 * 1024));
    assert(4 * 1024 * 1024 > MAX_STREAM_BUFFER_SIZE);
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();
    H3Event ev;
    while (server.pollEvent(quic.server, ev))
    {
    }
    while (client.pollEvent(quic.client, ev))
    {
    }

    StreamId sid;
    assert(quic.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    ubyte[16] fh;
    size_t fhLen;
    assert(encodeH3FrameHeader(H3FrameType.headers, 3_000_000, fh[], fhLen));
    assert(quic.client.streamWrite(sid, fh[0 .. fhLen], false));
    ubyte[4000] chunk;
    bool sawReset = false;
    foreach (i; 0 .. 1500)
    {
        // The window of the sender is large; a refused write just ends the flood early.
        const wrote = quic.client.streamWrite(sid, chunk[], false);
        if (i % 25 == 0 || !wrote)
        {
            quic.pump();
            while (server.pollEvent(quic.server, ev))
                sawReset = sawReset || (ev.type == H3EventType.streamReset
                        && ev.streamId == sid && ev.errorCode == cast(
                            ulong) H3ErrorCode.excessiveLoad);
        }
        assert(!server.isClosed,
                "an oversized field section is a stream error, never a connection error");
        if (sawReset)
            break;
    }
    assert(sawReset, "the stream is reset from the announced length");
    assert(server.scratchBytes == 0);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// initH3Pair(quic, client, server);
///
/// // A HEADERS frame announcing 100 000 bytes (over the 64 KiB default), 32 payload bytes sent.
/// StreamId sid;
/// assert(quic.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
/// ubyte[16] fh;
/// size_t fhLen;
/// assert(encodeH3FrameHeader(H3FrameType.headers, 100_000, fh[], fhLen));
/// ubyte[48] first = 0;
/// first[0 .. fhLen] = fh[0 .. fhLen];
/// assert(quic.client.streamWrite(sid, first[0 .. fhLen + 32], false));
/// quic.pump();
///
/// H3Event ev;
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.streamReset);
/// assert(ev.streamId == sid && !server.isClosed);
/// ---
// Spec: RFC 9114 Section 4.2.2 "An HTTP/3 implementation MAY impose a limit on the maximum size of
// the message header it will accept on an individual HTTP message." - the default limit (64 KiB)
// is applied from the frame header, before any of the field section is buffered, and the buffers
// behind delivered events are released (L1)
@nogc unittest
{
    TestQuicPair quic;
    assert(initTestQuicPair(quic));
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(client.initConnection(quic.client));
    assert(server.initConnection(quic.server));
    quic.pump();
    H3Event ev;
    while (server.pollEvent(quic.server, ev))
    {
    }
    while (client.pollEvent(quic.client, ev))
    {
    }
    const baseline = server.trackedStreamCount;
    assert(server.localSettings.maxFieldSectionSize == H3_DEFAULT_MAX_FIELD_SECTION_SIZE,
            "an unset limit gets the bounded default");

    // Raw request stream: HEADERS frame header announcing 100 000 bytes (> 64 KiB), 32 payload bytes
    // follow, the remaining payload is held back.
    StreamId sid;
    assert(quic.client.openStream(StreamDirection.bidirectional, sid) == TransportErrorCode.noError);
    ubyte[16] fh;
    size_t fhLen;
    assert(encodeH3FrameHeader(H3FrameType.headers, 100_000, fh[], fhLen));
    ubyte[48] first;
    first[0 .. fhLen] = fh[0 .. fhLen];
    first[fhLen .. $] = 0x00;
    assert(quic.client.streamWrite(sid, first[0 .. fhLen + 32], false));
    quic.pump();
    assert(server.pollEvent(quic.server, ev), "rejected before the payload arrived");
    assert(ev.type == H3EventType.streamReset && ev.streamId == sid
            && ev.errorCode == cast(ulong) H3ErrorCode.excessiveLoad);
    assert(!server.isClosed, "a stream error, not a connection error");
    assert(!server.pollEvent(quic.server, ev));
    assert(server.trackedStreamCount == baseline, "the reset stream holds no tracker");
    assert(server.scratchBytes == 0, "no header buffers were allocated for it");

    // The rest of the payload is skipped without being buffered or surfacing as events.
    ubyte[4000] rest;
    foreach (_; 0 .. 25)
        assert(quic.client.streamWrite(sid, rest[], false));
    assert(quic.client.streamWrite(sid, rest[0 .. 0], true));
    foreach (_; 0 .. 6)
    {
        quic.pump();
        assert(!server.pollEvent(quic.server, ev));
    }
    assert(server.trackedStreamCount == baseline);
    assert(quic.server.streams.connFlow.readOffset == quic.server.streams.connFlow.highestReceived);

    // A normal request's decoded header strings are released once the event was consumed.
    const H3HeaderField[4] ok = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/idle")
    ];
    StreamId idle;
    assert(client.sendRequest(quic.client, ok[], null, false, idle));
    quic.pump();
    assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.headersReceived);
    assert(server.scratchBytes > 0, "the event's slices are backed by scratch buffers");
    while (server.pollEvent(quic.server, ev))
    {
    }
    assert(server.scratchBytes == 0,
            "an idle request stream does not pin header buffers after delivery");
}

version (unittest)
{
    private struct H3Tally
    {
        size_t dataBytes;
        size_t dataEvents;
        size_t maxChunk;
        bool finished;
        bool closed;
        bool reset;
        ulong resetCode;
        size_t headerEvents;
        size_t headerCount;
        bool goaway;
    }

    /// Drains the server's events into `t`.
    private void tallyServer(ref TestQuicPair quic, ref H3Connection server, ref H3Tally t) @trusted @nogc nothrow
    {
        H3Event ev;
        while (server.pollEvent(quic.server, ev))
        {
            switch (ev.type)
            {
            case H3EventType.dataReceived:
                t.dataBytes += ev.data.length;
                t.dataEvents++;
                if (ev.data.length > t.maxChunk)
                    t.maxChunk = ev.data.length;
                break;
            case H3EventType.headersReceived:
                t.headerEvents++;
                t.headerCount = ev.headerCount;
                break;
            case H3EventType.requestFinished:
                t.finished = true;
                break;
            case H3EventType.streamReset:
                t.reset = true;
                t.resetCode = ev.errorCode;
                break;
            case H3EventType.goawayReceived:
                t.goaway = true;
                break;
            case H3EventType.connectionClosed:
                t.closed = true;
                t.resetCode = ev.errorCode;
                break;
            default:
                break;
            }
        }
    }

    /// Writes `total` filler bytes to the client's stream `sid` while the server consumes them.
    private bool feedStream(ref TestQuicPair quic, ref H3Connection server,
            StreamId sid, size_t total, bool fin, ref H3Tally t) @trusted @nogc nothrow
    {
        ubyte[32768] chunk = 0x5a;
        size_t sent = 0;
        size_t stalls = 0;
        while (sent < total)
        {
            const size_t n = (total - sent) < chunk.length ? total - sent : chunk.length;
            const bool last = fin && (sent + n == total);
            if (quic.client.streamWrite(sid, chunk[0 .. n], last))
                sent += n;
            else if (++stalls > 4000)
                return false;
            quic.pump();
            tallyServer(quic, server, t);
        }
        return true;
    }

    private bool newH3Pair(ref TestQuicPair quic, ref H3Connection client, ref H3Connection server) @trusted @nogc nothrow
    {
        if (!initTestQuicPair(quic))
            return false;
        if (!client.initConnection(quic.client) || !server.initConnection(quic.server))
            return false;
        quic.pump();
        return true;
    }
}

/// Example:
/// ---
/// enum size_t bodyLen = 1_310_720;   // > MAX_STREAM_BUFFER_SIZE
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// assert(newH3Pair(quic, client, server));
/// H3Tally t;
/// tallyServer(quic, server, t);
///
/// const H3HeaderField[5] headers = [
///     H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/big"),
///     H3HeaderField("content-length", "1310720")
/// ];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, headers[], null, false, sid));
/// ubyte[16] frameHdr;
/// size_t frameHdrLen;
/// assert(encodeH3FrameHeader(0x00, bodyLen, frameHdr[], frameHdrLen));
/// assert(quic.client.streamWrite(sid, frameHdr[0 .. frameHdrLen], false));
/// assert(feedStream(quic, server, sid, bodyLen, true, t));
/// quic.pump();
/// tallyServer(quic, server, t);
/// assert(t.dataBytes == bodyLen && t.maxChunk <= H3_MAX_DATA_CHUNK && t.finished);
/// ---
// Spec: RFC 9114 Section 7.2.1 - "DATA frames (type=0x00) convey arbitrary, variable-length
// sequences of bytes associated with HTTP request or response content." The length is a varint,
// so a frame may exceed the receive buffer: it is delivered in chunks, not buffered whole (R-27, D5)
@nogc unittest
{
    enum size_t bodyLen = 1_310_720; // > MAX_STREAM_BUFFER_SIZE
    TestQuicPair quic;
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(newH3Pair(quic, client, server));
    H3Tally t;
    tallyServer(quic, server, t);

    const H3HeaderField[5] headers = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"), H3HeaderField(":path",
                "/big"), H3HeaderField("content-length", "1310720")
    ];
    StreamId sid;
    assert(client.sendRequest(quic.client, headers[], null, false, sid));
    ubyte[16] frameHdr;
    size_t frameHdrLen = 0;
    assert(encodeH3FrameHeader(0x00, bodyLen, frameHdr[], frameHdrLen));
    assert(quic.client.streamWrite(sid, frameHdr[0 .. frameHdrLen], false));
    assert(feedStream(quic, server, sid, bodyLen, true, t));
    quic.pump();
    tallyServer(quic, server, t);

    assert(!t.closed && !t.reset && !server.isClosed);
    assert(t.dataBytes == bodyLen);
    assert(t.maxChunk <= H3_MAX_DATA_CHUNK && t.dataEvents > bodyLen / H3_MAX_DATA_CHUNK - 1);
    assert(t.finished);
}

/// Example:
/// ---
/// enum size_t unknownLen = 1_572_864;   // 1.5 MiB
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// assert(newH3Pair(quic, client, server));
/// H3Tally t;
/// tallyServer(quic, server, t);
///
/// const H3HeaderField[5] headers = [
///     H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/grease"),
///     H3HeaderField("content-length", "2")
/// ];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, headers[], null, false, sid));
/// ubyte[16] frameHdr;
/// size_t frameHdrLen;
/// assert(encodeH3FrameHeader(0x21, unknownLen, frameHdr[], frameHdrLen));   // unknown frame type
/// assert(quic.client.streamWrite(sid, frameHdr[0 .. frameHdrLen], false));
/// assert(feedStream(quic, server, sid, unknownLen, false, t));
/// quic.pump();
/// tallyServer(quic, server, t);
/// assert(!t.closed && !t.reset && !server.isClosed);   // skipped, not buffered
/// ---
// Spec: RFC 9114 Section 9 - "Implementations MUST ignore unknown or unsupported values in all
// extensible protocol elements." Frame types are extensible, so an unknown frame is skipped,
// whatever its length, without being buffered (R-27, D5)
@nogc unittest
{
    enum size_t unknownLen = 1_572_864;
    TestQuicPair quic;
    H3Connection client = H3Connection(Side.client);
    H3Connection server = H3Connection(Side.server);
    assert(newH3Pair(quic, client, server));
    H3Tally t;
    tallyServer(quic, server, t);

    const H3HeaderField[5] headers = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "localhost"),
        H3HeaderField(":path", "/grease"), H3HeaderField("content-length", "2")
    ];
    StreamId sid;
    assert(client.sendRequest(quic.client, headers[], null, false, sid));
    ubyte[16] frameHdr;
    size_t frameHdrLen = 0;
    assert(encodeH3FrameHeader(0x21, unknownLen, frameHdr[], frameHdrLen));
    assert(quic.client.streamWrite(sid, frameHdr[0 .. frameHdrLen], false));
    assert(feedStream(quic, server, sid, unknownLen, false, t));
    // A real DATA frame behind it still gets through and ends the request.
    ubyte[8] tail;
    size_t tailLen = 0;
    assert(encodeH3FrameHeader(0x00, 2, tail[], tailLen));
    tail[tailLen++] = 'o';
    tail[tailLen++] = 'k';
    assert(quic.client.streamWrite(sid, tail[0 .. tailLen], true));
    quic.pump();
    tallyServer(quic, server, t);

    assert(!t.closed && !t.reset && !server.isClosed);
    assert(t.dataBytes == 2 && t.finished);
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server);
/// assert(newH3Pair(quic, client, server));
///
/// // A 20 000-byte frame of an unknown type (0x21) on the control stream is skipped.
/// ubyte[16] frameHdr;
/// size_t frameHdrLen;
/// assert(encodeH3FrameHeader(0x21, 20_000, frameHdr[], frameHdrLen));
/// assert(quic.client.streamWrite(client.localControlStreamId, frameHdr[0 .. frameHdrLen], false));
/// ubyte[4000] filler = 0;
/// foreach (_; 0 .. 5)
/// {
///     assert(quic.client.streamWrite(client.localControlStreamId, filler[], false));
///     quic.pump();
/// }
/// assert(!server.isClosed);   // type 0x0d (MAX_PUSH_ID) at that size would be H3_FRAME_ERROR
/// ---
// Spec: RFC 9114 Section 9 - "Implementations MUST ignore unknown or unsupported values in all
// extensible protocol elements." An unknown frame on the control stream is skipped; only frames
// the endpoint interprets are held to the 16 KiB bound (R-27, D5)
@nogc unittest
{
    foreach (known; [false, true])
    {
        TestQuicPair quic;
        H3Connection client = H3Connection(Side.client);
        H3Connection server = H3Connection(Side.server);
        assert(newH3Pair(quic, client, server));
        H3Tally t;
        tallyServer(quic, server, t);

        ubyte[16] frameHdr;
        size_t frameHdrLen = 0;
        // MAX_PUSH_ID (0x0d) is interpreted; 0x21 is not.
        assert(encodeH3FrameHeader(known ? 0x0d : 0x21, 20_000, frameHdr[], frameHdrLen));
        assert(quic.client.streamWrite(client.localControlStreamId,
                frameHdr[0 .. frameHdrLen], false));
        ubyte[4000] filler = 0;
        foreach (_; 0 .. 5)
        {
            assert(quic.client.streamWrite(client.localControlStreamId, filler[], false));
            quic.pump();
            tallyServer(quic, server, t);
        }
        if (known)
        {
            assert(t.closed && t.resetCode == H3ErrorCode.frameError);
        }
        else
        {
            assert(!t.closed && !server.isClosed, "an unknown control frame is skipped");
            // The control stream keeps working behind the skipped frame.
            ubyte[8] goaway;
            size_t goawayLen = 0;
            assert(encodeH3FrameHeader(0x07, 1, goaway[], goawayLen));
            goaway[goawayLen++] = 0;
            assert(quic.client.streamWrite(client.localControlStreamId,
                    goaway[0 .. goawayLen], false));
            quic.pump();
            tallyServer(quic, server, t);
            assert(t.goaway && !t.closed);
        }
    }
}

/// Example:
/// ---
/// TestQuicPair quic;
/// H3Settings limited;
/// limited.maxFieldSectionSize = 200;
/// H3Connection client = H3Connection(Side.client);
/// H3Connection server = H3Connection(Side.server, limited);
/// assert(newH3Pair(quic, client, server));
/// H3Event ev;
/// while (server.pollEvent(quic.server, ev))        // the client's SETTINGS
/// {
/// }
///
/// char[400] big = 'a';
/// const H3HeaderField[5] headers = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "localhost"), H3HeaderField(":path", "/"),
///     H3HeaderField("x-big", cast(string) big[])
/// ];
/// StreamId sid;
/// assert(client.sendRequest(quic.client, headers[], null, true, sid));
/// quic.pump();
///
/// assert(server.pollEvent(quic.server, ev) && ev.type == H3EventType.streamReset);
/// assert(ev.errorCode == H3ErrorCode.excessiveLoad);   // the stream fails ...
/// assert(!server.isClosed);                            // ... the connection does not
/// ---
// Spec: RFC 9114 Section 4.2.2 - "An HTTP/3 implementation MAY impose a limit on the maximum size
// of the message header it will accept on an individual HTTP message." Exceeding the limit (or
// 256 field lines) fails only that stream with H3_EXCESSIVE_LOAD (Section 8.1), not the connection
// (R-27, D5)
@nogc unittest
{
    // (a) section larger than the local SETTINGS_MAX_FIELD_SECTION_SIZE
    {
        TestQuicPair quic;
        H3Settings limited;
        limited.maxFieldSectionSize = 200;
        H3Connection client = H3Connection(Side.client);
        H3Connection server = H3Connection(Side.server, limited);
        assert(newH3Pair(quic, client, server));
        H3Tally t;
        tallyServer(quic, server, t);
        char[400] big = 'a';
        const H3HeaderField[5] headers = [
            H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
            H3HeaderField(":authority", "localhost"), H3HeaderField(":path",
                    "/"), H3HeaderField("x-big", cast(string) big[])
        ];
        StreamId sid;
        // The client has not polled the server's SETTINGS yet, so it does not know the limit.
        assert(client.sendRequest(quic.client, headers[], null, true, sid));
        quic.pump();
        tallyServer(quic, server, t);
        assert(t.reset && t.resetCode == H3ErrorCode.excessiveLoad);
        assert(!t.closed && !server.isClosed, "only the stream fails");
        assert(t.headerEvents == 0);
    }

    // (b) 256 field lines are fine, 257 are a stream error
    foreach (count; [256, 257])
    {
        TestQuicPair quic;
        H3Connection client = H3Connection(Side.client);
        H3Connection server = H3Connection(Side.server);
        assert(newH3Pair(quic, client, server));
        H3Tally t;
        tallyServer(quic, server, t);

        H3HeaderField[257] fields;
        fields[0] = H3HeaderField(":method", "GET");
        fields[1] = H3HeaderField(":scheme", "https");
        fields[2] = H3HeaderField(":authority", "localhost");
        fields[3] = H3HeaderField(":path", "/");
        foreach (i; 4 .. count)
            fields[i] = H3HeaderField("x-h", "v");
        ubyte[8192] block;
        const size_t blockLen = encodeQpackFieldSection(fields[0 .. count], block[], true);
        assert(blockLen > 0);
        StreamId sid;
        assert(quic.client.openStream(StreamDirection.bidirectional,
                sid) == TransportErrorCode.noError);
        ubyte[16] frameHdr;
        size_t frameHdrLen = 0;
        assert(encodeH3FrameHeader(0x01, blockLen, frameHdr[], frameHdrLen));
        assert(quic.client.streamWrite(sid, frameHdr[0 .. frameHdrLen], false));
        assert(quic.client.streamWrite(sid, block[0 .. blockLen], true));
        quic.pump();
        tallyServer(quic, server, t);
        assert(!t.closed && !server.isClosed);
        if (count == 256)
        {
            assert(t.headerEvents == 1 && t.headerCount == 256 && !t.reset);
        }
        else
        {
            assert(t.reset && t.resetCode == H3ErrorCode.excessiveLoad && t.headerEvents == 0);
        }
    }
}
