module slate.h3;

/**
 * Umbrella module for HTTP/3 and QPACK protocol layer (RFC 9114 & RFC 9204).
 */

public import slate.h3.error;
public import slate.h3.qpack;
public import slate.h3.frame;
public import slate.h3.connection;

import slate.quic.connection : QuicConnection;
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
        foreach (_; 0 .. 10)
        {
            bool hadTraffic = false;
            if (client.pollTransmit(buf[], now, len) && len > 0)
            {
                server.handleDatagram(buf[0 .. len], now);
                hadTraffic = true;
            }
            if (server.pollTransmit(buf[], now, len) && len > 0)
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

private bool initTestQuicPair(out TestQuicPair pair) @trusted @nogc nothrow
{
    alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
    alias ClientFn = TlsContext function() @nogc nothrow;

    TlsContext serverCtx = (cast(ServerFn)&TlsContext.createServer)(
            "test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    if (!serverCtx.isValid)
        serverCtx = (cast(ServerFn)&TlsContext.createServer)("packages/net/test/fixtures/quic_cert.pem",
                "packages/net/test/fixtures/quic_key.pem");
    if (!serverCtx.isValid)
        serverCtx = (cast(ServerFn)&TlsContext.createServer)("slate-dlang/packages/net/test/fixtures/quic_cert.pem",
                "slate-dlang/packages/net/test/fixtures/quic_key.pem");
    if (!serverCtx.isValid)
        return false;

    TlsContext clientCtx = (cast(ClientFn)&TlsContext.createClient)();
    if (!clientCtx.isValid)
        return false;

    const ubyte[8] dcidBytes = [0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08];
    const ubyte[8] scidBytes = [0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8];
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
    serverTp.initialMaxData = 20_000_000;
    serverTp.initialMaxStreamsBidi = 200;
    serverTp.initialMaxStreamsUni = 100;
    serverTp.initialMaxStreamDataBidiLocal = 1_000_000;
    serverTp.initialMaxStreamDataBidiRemote = 1_000_000;
    serverTp.initialMaxStreamDataUni = 1_000_000;

    ulong now = 1_000_000;
    pair.now = now;

    if (!QuicConnection.create(Side.client, clientCtx, clientScid, clientDcid,
            clientTp, now, pair.client))
        return false;
    if (!QuicConnection.create(Side.server, serverCtx, clientDcid,
            ConnectionId.init, serverTp, now, pair.server))
        return false;

    // Handshake 4 flights per RFC 9000 & connection_test.d
    ubyte[4096] dgramBuf;
    size_t dgramLen = 0;

    // Flight 1: Client Initial -> Server
    if (!pair.client.pollTransmit(dgramBuf[], now, dgramLen) || dgramLen == 0)
        return false;
    if (pair.server.handleDatagram(dgramBuf[0 .. dgramLen], now) != TransportErrorCode.noError)
        return false;

    // Flight 2: Server Initial + Handshake -> Client
    now += 10_000;
    if (!pair.server.pollTransmit(dgramBuf[], now, dgramLen) || dgramLen == 0)
        return false;
    if (pair.client.handleDatagram(dgramBuf[0 .. dgramLen], now) != TransportErrorCode.noError)
        return false;

    // Flight 3: Client Handshake -> Server
    now += 10_000;
    if (!pair.client.pollTransmit(dgramBuf[], now, dgramLen) || dgramLen == 0)
        return false;
    if (pair.server.handleDatagram(dgramBuf[0 .. dgramLen], now) != TransportErrorCode.noError)
        return false;

    // Flight 4: Server 1-RTT with HANDSHAKE_DONE -> Client
    now += 10_000;
    if (!pair.server.pollTransmit(dgramBuf[], now, dgramLen) || dgramLen == 0)
        return false;
    if (pair.client.handleDatagram(dgramBuf[0 .. dgramLen], now) != TransportErrorCode.noError)
        return false;

    now += 10_000;
    pair.now = now;
    return pair.client.handshakeConfirmed;
}

/// Example:
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
    const H3HeaderField[5] postHeaders = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
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
// Spec: RFC 9114 Section 4.1.2, Section 4.3 - HTTP/3 Message & Pseudo-Header Security Enforcement (covers Scenario T5, U1, U2, U3, W3, F5)
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
    const H3HeaderField[4] headers = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/bad-length"),
        H3HeaderField("content-length", "5")
    ];
    const ubyte[10] tenBytes = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    StreamId badStream;
    assert(client.sendRequest(quic.client, headers[], tenBytes[], true, badStream));

    quic.pump();

    // Server receives HEADERS, then when DATA length > 5 is detected, connection aborts with messageError
    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.headersReceived);

    assert(server.pollEvent(quic.server, ev));
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.messageError);
}

/// Example:
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
    const H3HeaderField[4] reqHdrs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
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
// Spec: RFC 9114 Section 4.1.2, Section 4.3 - Request Stream Malformed Headers & Content-Length Underrun (covers Scenario T5, F5)
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
        assert(localEv.type == H3EventType.connectionClosed);
        assert(localEv.errorCode == H3ErrorCode.messageError);
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
    assert(ev.type == H3EventType.connectionClosed);
    assert(ev.errorCode == H3ErrorCode.messageError);
}
