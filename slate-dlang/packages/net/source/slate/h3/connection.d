module slate.h3.connection;

/**
 * Sans-I/O HTTP/3 Connection State Machine (RFC 9114).
 *
 * Implements local and remote Control, QPACK Encoder, and QPACK Decoder unidirectional streams,
 * mandatory initial SETTINGS exchange, bidirectional request/response framing,
 * RFC 9114 Section 4.3 pseudo-header and message validation, and graceful GOAWAY shutdown.
 */

public import slate.h3.error;
public import slate.h3.qpack;
public import slate.h3.frame;

import slate.quic.connection : QuicConnection, ConnectionEventType, ConnectionEvent;
import slate.quic.stream.id : StreamId, StreamDirection;
import slate.quic.wire.cid : TransportErrorCode;
import slate.quic.crypto.kdf : Side;
import slate.quic.wire.varint : decodeVarInt, encodeVarInt, WireError, varIntLen;

import core.stdc.stdlib : calloc, realloc, free;
import core.stdc.string : memmove;

public enum H3EventType : ubyte
{
    none = 0,
    peerSettingsReceived,
    headersReceived,
    dataReceived,
    requestFinished,
    goawayReceived,
    connectionClosed
}

/**
 * An event emitted by H3Connection.
 */
public struct H3Event
{
    H3EventType type = H3EventType.none;
    StreamId streamId;
    ulong errorCode = 0;
    H3Settings settings;

    H3HeaderField[MAX_H3_HEADERS] headers;
    size_t headerCount = 0;

    const(ubyte)[] data;
    bool fin = false;
}

public enum size_t MAX_STREAM_BUFFER_SIZE = 1024 * 1024; // 1 MiB
public enum size_t MAX_CONTROL_FRAME_SIZE = 16 * 1024; // 16 KiB
public enum size_t MAX_TRACKED_STREAMS = 256;

private enum size_t EVENT_QUEUE_CAPACITY = 64;

private struct H3EventQueue
{
    H3Event[EVENT_QUEUE_CAPACITY] buffer;
    size_t head = 0;
    size_t tail = 0;
    size_t count = 0;

    bool push(H3Event ev) @safe pure nothrow @nogc
    {
        if (count >= EVENT_QUEUE_CAPACITY)
            return false;
        buffer[tail] = ev;
        tail = (tail + 1) % EVENT_QUEUE_CAPACITY;
        count++;
        return true;
    }

    void forcePush(H3Event ev) @safe pure nothrow @nogc
    {
        if (count < EVENT_QUEUE_CAPACITY)
        {
            push(ev);
            return;
        }
        buffer[tail] = ev;
        tail = (tail + 1) % EVENT_QUEUE_CAPACITY;
        head = (head + 1) % EVENT_QUEUE_CAPACITY;
    }

    bool poll(out H3Event ev) @safe pure nothrow @nogc
    {
        if (count == 0)
            return false;
        ev = buffer[head];
        head = (head + 1) % EVENT_QUEUE_CAPACITY;
        count--;
        return true;
    }

    @property bool empty() const @safe pure nothrow @nogc
    {
        return count == 0;
    }
}

private enum H3StreamKind : ubyte
{
    unknown = 0,
    control,
    qpackEncoder,
    qpackDecoder,
    push,
    request
}

/**
 * State and buffers for an active HTTP/3 stream.
 */
private struct H3StreamTracker
{
    StreamId id;
    H3StreamKind kind = H3StreamKind.unknown;
    bool typeDecoded = false;
    bool initialHeadersReceived = false;
    bool trailersReceived = false;
    bool finReceived = false;
    bool requestFinishedEmitted = false;

    bool hasContentLength = false;
    ulong expectedContentLength = 0;
    ulong receivedDataBytes = 0;

    ubyte* recvBuf = null;
    size_t recvBufLen = 0;
    size_t recvBufCapacity = 0;

    char* strBuf = null;
    size_t strBufCapacity = 0;

    ubyte* dataBuf = null;
    size_t dataBufLen = 0;
    size_t dataBufCapacity = 0;

    void cleanup() @trusted @nogc nothrow
    {
        if (recvBuf !is null)
        {
            free(recvBuf);
            recvBuf = null;
        }
        recvBufLen = 0;
        recvBufCapacity = 0;

        if (strBuf !is null)
        {
            free(strBuf);
            strBuf = null;
        }
        strBufCapacity = 0;

        if (dataBuf !is null)
        {
            free(dataBuf);
            dataBuf = null;
        }
        dataBufLen = 0;
        dataBufCapacity = 0;
    }

    bool appendRecv(const(ubyte)[] data) @trusted @nogc nothrow
    {
        if (data.length == 0)
            return true;
        if (data.length > MAX_STREAM_BUFFER_SIZE || recvBufLen > MAX_STREAM_BUFFER_SIZE
                - data.length)
            return false;
        if (recvBufLen + data.length > recvBufCapacity)
        {
            size_t newCap = recvBufCapacity == 0 ? 512 : recvBufCapacity * 2;
            while (newCap < recvBufLen + data.length)
                newCap *= 2;
            if (newCap > MAX_STREAM_BUFFER_SIZE)
                newCap = MAX_STREAM_BUFFER_SIZE;
            ubyte* p = cast(ubyte*) realloc(recvBuf, newCap);
            if (p is null)
                return false;
            recvBuf = p;
            recvBufCapacity = newCap;
        }
        recvBuf[recvBufLen .. recvBufLen + data.length] = data[];
        recvBufLen += data.length;
        return true;
    }

    void consumeRecv(size_t bytes) @trusted @nogc nothrow
    {
        if (bytes >= recvBufLen)
        {
            recvBufLen = 0;
            return;
        }
        memmove(recvBuf, recvBuf + bytes, recvBufLen - bytes);
        recvBufLen -= bytes;
    }

    bool ensureStrBufCapacity(size_t cap) @trusted @nogc nothrow
    {
        if (strBufCapacity >= cap)
            return true;
        size_t newCap = strBufCapacity == 0 ? 1024 : strBufCapacity * 2;
        if (newCap < cap)
            newCap = cap;
        char* p = cast(char*) realloc(strBuf, newCap);
        if (p is null)
            return false;
        strBuf = p;
        strBufCapacity = newCap;
        return true;
    }

    bool ensureDataBufCapacity(size_t cap) @trusted @nogc nothrow
    {
        if (dataBufCapacity >= cap)
            return true;
        size_t newCap = dataBufCapacity == 0 ? 4096 : dataBufCapacity * 2;
        if (newCap < cap)
            newCap = cap;
        ubyte* p = cast(ubyte*) realloc(dataBuf, newCap);
        if (p is null)
            return false;
        dataBuf = p;
        dataBufCapacity = newCap;
        return true;
    }
}

/**
 * Checks whether ch is a valid HTTP token character (RFC 9110 Section 5.6.2).
 * Lowercase only for HTTP/3 field names.
 */
public bool isValidHttpTokenChar(ubyte ch) @safe pure nothrow @nogc
{
    if (ch >= 'a' && ch <= 'z')
        return true;
    if (ch >= '0' && ch <= '9')
        return true;
    switch (ch)
    {
    case '!':
    case '#':
    case '$':
    case '%':
    case '&':
    case '\'':
    case '*':
    case '+':
    case '-':
    case '.':
    case '^':
    case '_':
    case '`':
    case '|':
    case '~':
        return true;
    default:
        return false;
    }
}

/**
 * Validates an HTTP/3 header field value (RFC 9114 Section 10.3 & RFC 9110 Section 5.5).
 */
public bool isValidHeaderValue(const(char)[] val) @safe pure nothrow @nogc
{
    if (val.length == 0)
        return true;
    // Leading or trailing space / tab forbidden (RFC 9110 / RFC 9114 §10.3)
    if (val[0] == ' ' || val[0] == '\t' || val[$ - 1] == ' ' || val[$ - 1] == '\t')
        return false;
    foreach (ch; cast(const(ubyte)[]) val)
    {
        // NUL, CR, LF, and CTL characters (< 0x20 except 0x09 tab, and 0x7F DEL) forbidden
        if (ch == '\0' || ch == '\r' || ch == '\n' || (ch < 0x20 && ch != '\t') || ch == 0x7F)
            return false;
    }
    return true;
}

/**
 * Validates HTTP/3 pseudo-headers and header constraints (RFC 9114 Section 4.3).
 */
public H3ErrorCode validateHeaders(const(H3HeaderField)[] headers,
        bool isResponse, out bool hasContentLength, out ulong expectedContentLength) @safe pure nothrow @nogc
{
    hasContentLength = false;
    expectedContentLength = 0;

    if (headers.length == 0)
        return H3ErrorCode.messageError;

    bool pastPseudo = false;
    bool hasMethod = false;
    bool hasScheme = false;
    bool hasPath = false;
    bool hasAuthority = false;
    bool hasStatus = false;
    bool isConnect = false;

    foreach (const ref h; headers)
    {
        if (h.name.length == 0)
            return H3ErrorCode.messageError;

        if (!isValidHeaderValue(h.value))
            return H3ErrorCode.messageError;

        if (h.name[0] == ':')
        {
            if (pastPseudo)
                return H3ErrorCode.messageError; // Pseudo-header after regular header
            if (h.name.length <= 1)
                return H3ErrorCode.messageError; // Empty pseudo-header name
            foreach (ch; cast(const(ubyte)[]) h.name[1 .. $])
            {
                if (!isValidHttpTokenChar(ch))
                    return H3ErrorCode.messageError;
            }

            if (isResponse)
            {
                if (h.name == ":status")
                {
                    if (hasStatus)
                        return H3ErrorCode.messageError; // Duplicate :status
                    hasStatus = true;
                    if (h.value.length != 3)
                        return H3ErrorCode.messageError;
                    foreach (ch; cast(const(ubyte)[]) h.value)
                    {
                        if (ch < '0' || ch > '9')
                            return H3ErrorCode.messageError;
                    }
                    if (h.value[0] < '1' || h.value[0] > '5')
                        return H3ErrorCode.messageError;
                    // RFC 9114 Section 4.3.2: 101 Switching Protocols forbidden in HTTP/3
                    if (h.value == "101")
                        return H3ErrorCode.messageError;
                }
                else
                {
                    return H3ErrorCode.messageError; // Unknown pseudo-header on response
                }
            }
            else
            {
                if (h.value.length == 0)
                    return H3ErrorCode.messageError; // Pseudo-header value must not be empty

                if (h.name == ":method")
                {
                    if (hasMethod)
                        return H3ErrorCode.messageError;
                    hasMethod = true;
                    if (h.value == "CONNECT")
                        isConnect = true;
                }
                else if (h.name == ":scheme")
                {
                    if (hasScheme)
                        return H3ErrorCode.messageError;
                    hasScheme = true;
                }
                else if (h.name == ":path")
                {
                    if (hasPath)
                        return H3ErrorCode.messageError;
                    hasPath = true;
                }
                else if (h.name == ":authority")
                {
                    if (hasAuthority)
                        return H3ErrorCode.messageError;
                    hasAuthority = true;
                }
                else
                {
                    return H3ErrorCode.messageError; // Unknown pseudo-header on request
                }
            }
        }
        else
        {
            pastPseudo = true;

            // Every character in regular header name must be valid token character
            foreach (ch; cast(const(ubyte)[]) h.name)
            {
                if (!isValidHttpTokenChar(ch))
                    return H3ErrorCode.messageError;
            }

            // Connection-specific headers forbidden (RFC 9114 Section 4.2)
            if (h.name == "connection" || h.name == "keep-alive" || h.name == "proxy-connection"
                    || h.name == "transfer-encoding" || h.name == "upgrade")
            {
                return H3ErrorCode.messageError;
            }

            // TE header check (RFC 9114 Section 4.2)
            if (h.name == "te" && h.value != "trailers")
                return H3ErrorCode.messageError;

            // Content-length validation (RFC 9114 Section 4.1.2)
            if (h.name == "content-length")
            {
                if (hasContentLength)
                    return H3ErrorCode.messageError; // Duplicate content-length
                if (h.value.length == 0)
                    return H3ErrorCode.messageError;

                ulong cl = 0;
                foreach (ch; cast(const(ubyte)[]) h.value)
                {
                    if (ch < '0' || ch > '9')
                        return H3ErrorCode.messageError;
                    const ulong digit = cast(ulong)(ch - '0');
                    if (ulong.max / 10 < cl || (ulong.max - digit) < cl * 10)
                        return H3ErrorCode.messageError;
                    cl = cl * 10 + digit;
                }
                hasContentLength = true;
                expectedContentLength = cl;
            }
        }
    }

    if (isResponse)
    {
        if (!hasStatus)
            return H3ErrorCode.messageError;
    }
    else
    {
        if (isConnect)
        {
            // RFC 9114 §4.4: CONNECT requests MUST contain :authority, MUST NOT contain :scheme or :path
            if (!hasAuthority || hasScheme || hasPath)
                return H3ErrorCode.messageError;
        }
        else
        {
            if (!hasMethod || !hasScheme || !hasPath)
                return H3ErrorCode.messageError;
        }
    }

    return H3ErrorCode.noError;
}

public H3ErrorCode validateHeaders(const(H3HeaderField)[] headers, bool isResponse) @safe pure nothrow @nogc
{
    bool hasCl = false;
    ulong cl = 0;
    return validateHeaders(headers, isResponse, hasCl, cl);
}

/**
 * Validates HTTP/3 trailing headers (RFC 9114 Section 4.3).
 * Pseudo-headers, connection-specific headers, and content-length are forbidden in trailers.
 */
public H3ErrorCode validateTrailers(const(H3HeaderField)[] trailers) @safe pure nothrow @nogc
{
    if (trailers.length == 0)
        return H3ErrorCode.noError;

    foreach (const ref h; trailers)
    {
        if (h.name.length == 0)
            return H3ErrorCode.messageError;
        // Pseudo-headers are forbidden in trailers (RFC 9114 Section 4.3)
        if (h.name[0] == ':')
            return H3ErrorCode.messageError;

        foreach (ch; cast(const(ubyte)[]) h.name)
        {
            if (!isValidHttpTokenChar(ch))
                return H3ErrorCode.messageError;
        }

        if (!isValidHeaderValue(h.value))
            return H3ErrorCode.messageError;

        // Connection-specific headers and content-length forbidden in trailers
        if (h.name == "connection" || h.name == "keep-alive" || h.name == "proxy-connection"
                || h.name == "transfer-encoding" || h.name == "upgrade"
                || h.name == "te" || h.name == "content-length")
        {
            return H3ErrorCode.messageError;
        }
    }

    return H3ErrorCode.noError;
}

private size_t formatStatus(ushort code, char[] outBuf) @safe pure nothrow @nogc
{
    if (outBuf.length < 3 || code < 100 || code > 999)
        return 0;
    outBuf[0] = cast(char)('0' + (code / 100));
    outBuf[1] = cast(char)('0' + ((code / 10) % 10));
    outBuf[2] = cast(char)('0' + (code % 10));
    return 3;
}

/**
 * Sans-I/O HTTP/3 Connection.
 */
public struct H3Connection
{
    @disable this(this);

    Side side;
    H3Settings localSettings;
    H3Settings peerSettings;
    bool peerSettingsReceived = false;

    StreamId localControlStreamId;
    StreamId localQpackEncStreamId;
    StreamId localQpackDecStreamId;
    bool localStreamsInitialized = false;

    StreamId peerControlStreamId;
    bool peerControlKnown = false;
    bool peerControlSettingsReceived = false;

    StreamId peerQpackEncStreamId;
    bool peerQpackEncKnown = false;

    StreamId peerQpackDecStreamId;
    bool peerQpackDecKnown = false;

    bool peerGoawayReceived = false;
    ulong peerGoawayStreamId = 0;

    bool localGoawaySent = false;
    ulong localGoawayStreamId = 0;

    bool connectionClosed = false;
    ulong closeErrorCode = 0;

    private H3StreamTracker* streams = null;
    private size_t streamCount = 0;
    private size_t streamCapacity = 0;

    private H3EventQueue events;

    this(Side side, H3Settings localSettings = H3Settings.init) @safe pure nothrow @nogc
    {
        this.side = side;
        this.localSettings = localSettings;
    }

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        if (streams !is null)
        {
            foreach (i; 0 .. streamCount)
            {
                streams[i].cleanup();
            }
            free(streams);
            streams = null;
        }
        streamCount = 0;
        streamCapacity = 0;
    }

    void moveFrom(ref H3Connection other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;
        cleanup();

        this.side = other.side;
        this.localSettings = other.localSettings;
        this.peerSettings = other.peerSettings;
        this.peerSettingsReceived = other.peerSettingsReceived;
        this.localControlStreamId = other.localControlStreamId;
        this.localQpackEncStreamId = other.localQpackEncStreamId;
        this.localQpackDecStreamId = other.localQpackDecStreamId;
        this.localStreamsInitialized = other.localStreamsInitialized;
        this.peerControlStreamId = other.peerControlStreamId;
        this.peerControlKnown = other.peerControlKnown;
        this.peerControlSettingsReceived = other.peerControlSettingsReceived;
        this.peerQpackEncStreamId = other.peerQpackEncStreamId;
        this.peerQpackEncKnown = other.peerQpackEncKnown;
        this.peerQpackDecStreamId = other.peerQpackDecStreamId;
        this.peerQpackDecKnown = other.peerQpackDecKnown;
        this.peerGoawayReceived = other.peerGoawayReceived;
        this.peerGoawayStreamId = other.peerGoawayStreamId;
        this.localGoawaySent = other.localGoawaySent;
        this.localGoawayStreamId = other.localGoawayStreamId;
        this.connectionClosed = other.connectionClosed;
        this.closeErrorCode = other.closeErrorCode;
        this.streams = other.streams;
        this.streamCount = other.streamCount;
        this.streamCapacity = other.streamCapacity;
        this.events = other.events;

        other.streams = null;
        other.streamCount = 0;
        other.streamCapacity = 0;
    }

    @property bool isPeerSettingsReceived() const @safe pure nothrow @nogc
    {
        return peerSettingsReceived;
    }

    @property H3Settings getPeerSettings() const @safe pure nothrow @nogc
    {
        return peerSettings;
    }

    @property bool isClosed() const @safe pure nothrow @nogc
    {
        return connectionClosed;
    }

    @property ulong getCloseErrorCode() const @safe pure nothrow @nogc
    {
        return closeErrorCode;
    }

    /**
     * Initializes the HTTP/3 connection over QuicConnection by opening local Control (0x00),
     * QPACK Encoder (0x02), and QPACK Decoder (0x03) streams, and sending SETTINGS (RFC 9114 §6.2).
     */
    bool initConnection(ref QuicConnection quicConn) @safe @nogc nothrow
    {
        if (localStreamsInitialized)
            return true;

        if (quicConn.openStream(StreamDirection.unidirectional,
                localControlStreamId) != TransportErrorCode.noError)
            return false;
        if (quicConn.openStream(StreamDirection.unidirectional,
                localQpackEncStreamId) != TransportErrorCode.noError)
            return false;
        if (quicConn.openStream(StreamDirection.unidirectional,
                localQpackDecStreamId) != TransportErrorCode.noError)
            return false;

        // 1. Control Stream: Stream type 0x00 + SETTINGS frame
        ubyte[128] settingsPayload;
        size_t settingsPayloadLen = 0;
        if (!encodeSettingsPayload(localSettings, settingsPayload[], settingsPayloadLen))
            return false;

        ubyte[16] frameHeader;
        size_t frameHeaderLen = 0;
        if (!encodeH3FrameHeader(H3FrameType.settings, settingsPayloadLen,
                frameHeader[], frameHeaderLen))
            return false;

        ubyte[1] controlType = [cast(ubyte) H3UniStreamType.control];
        if (!quicConn.streamWrite(localControlStreamId, controlType[], false))
            return false;
        if (!quicConn.streamWrite(localControlStreamId, frameHeader[0 .. frameHeaderLen], false))
            return false;
        if (!quicConn.streamWrite(localControlStreamId,
                settingsPayload[0 .. settingsPayloadLen], false))
            return false;

        // 2. QPACK Encoder Stream: Stream type 0x02
        ubyte[1] encType = [cast(ubyte) H3UniStreamType.qpackEncoder];
        if (!quicConn.streamWrite(localQpackEncStreamId, encType[], false))
            return false;

        // 3. QPACK Decoder Stream: Stream type 0x03
        ubyte[1] decType = [cast(ubyte) H3UniStreamType.qpackDecoder];
        if (!quicConn.streamWrite(localQpackDecStreamId, decType[], false))
            return false;

        localStreamsInitialized = true;
        return true;
    }

    /**
     * Sends an HTTP/3 request over a newly opened bidirectional stream (RFC 9114 §4.1).
     */
    bool sendRequest(ref QuicConnection quicConn, const(H3HeaderField)[] headers,
            const(ubyte)[] body, bool fin, out StreamId streamId) @safe @nogc nothrow
    {
        if (connectionClosed)
            return false;

        H3ErrorCode err = validateHeaders(headers, false);
        if (err != H3ErrorCode.noError)
            return false;

        if (quicConn.openStream(StreamDirection.bidirectional,
                streamId) != TransportErrorCode.noError)
            return false;

        // Encode HEADERS frame
        ubyte[4096] qpackBuf;
        const size_t qpackLen = encodeQpackFieldSection(headers, qpackBuf[], true);
        if (qpackLen == 0)
            return false;

        ubyte[16] hdrFrameBuf;
        size_t hdrFrameLen = 0;
        if (!encodeH3FrameHeader(H3FrameType.headers, qpackLen, hdrFrameBuf[], hdrFrameLen))
            return false;

        const bool headersFin = fin && (body.length == 0);
        if (!quicConn.streamWrite(streamId, hdrFrameBuf[0 .. hdrFrameLen], false))
            return false;
        if (!quicConn.streamWrite(streamId, qpackBuf[0 .. qpackLen], headersFin))
            return false;

        // If body present, encode and write DATA frame
        if (body.length > 0)
        {
            ubyte[16] dataFrameBuf;
            size_t dataFrameLen = 0;
            if (!encodeH3FrameHeader(H3FrameType.data, body.length, dataFrameBuf[], dataFrameLen))
                return false;

            if (!quicConn.streamWrite(streamId, dataFrameBuf[0 .. dataFrameLen], false))
                return false;
            if (!quicConn.streamWrite(streamId, body, fin))
                return false;
        }

        return true;
    }

    /**
     * Sends an HTTP/3 response on an existing bidirectional stream (RFC 9114 §4.1).
     */
    bool sendResponse(ref QuicConnection quicConn, StreamId streamId, ushort statusCode,
            const(H3HeaderField)[] extraHeaders, const(ubyte)[] body, bool fin) @safe @nogc nothrow
    {
        if (connectionClosed)
            return false;

        char[3] statusStr;
        if (formatStatus(statusCode, statusStr[]) != 3)
            return false;

        H3HeaderField[MAX_H3_HEADERS] allHeaders;
        allHeaders[0] = H3HeaderField(":status", statusStr[]);
        size_t totalCount = 1;

        foreach (ref h; extraHeaders)
        {
            if (totalCount >= MAX_H3_HEADERS)
                return false;
            allHeaders[totalCount++] = h;
        }

        H3ErrorCode err = validateHeaders(allHeaders[0 .. totalCount], true);
        if (err != H3ErrorCode.noError)
            return false;

        ubyte[4096] qpackBuf;
        const size_t qpackLen = encodeQpackFieldSection(allHeaders[0 .. totalCount],
                qpackBuf[], true);
        if (qpackLen == 0)
            return false;

        ubyte[16] hdrFrameBuf;
        size_t hdrFrameLen = 0;
        if (!encodeH3FrameHeader(H3FrameType.headers, qpackLen, hdrFrameBuf[], hdrFrameLen))
            return false;

        const bool headersFin = fin && (body.length == 0);
        if (!quicConn.streamWrite(streamId, hdrFrameBuf[0 .. hdrFrameLen], false))
            return false;
        if (!quicConn.streamWrite(streamId, qpackBuf[0 .. qpackLen], headersFin))
            return false;

        if (body.length > 0)
        {
            ubyte[16] dataFrameBuf;
            size_t dataFrameLen = 0;
            if (!encodeH3FrameHeader(H3FrameType.data, body.length, dataFrameBuf[], dataFrameLen))
                return false;

            if (!quicConn.streamWrite(streamId, dataFrameBuf[0 .. dataFrameLen], false))
                return false;
            if (!quicConn.streamWrite(streamId, body, fin))
                return false;
        }

        return true;
    }

    /**
     * Sends a graceful GOAWAY frame on the Control Stream (RFC 9114 §7.2.6).
     */
    bool sendGoaway(ref QuicConnection quicConn, ulong streamId) @safe @nogc nothrow
    {
        if (localGoawaySent || !localStreamsInitialized || connectionClosed)
            return false;

        ubyte[16] goawayPayload;
        size_t payloadLen = 0;
        if (!encodeGoawayPayload(streamId, goawayPayload[], payloadLen))
            return false;

        ubyte[16] frameHeader;
        size_t headerLen = 0;
        if (!encodeH3FrameHeader(H3FrameType.goaway, payloadLen, frameHeader[], headerLen))
            return false;

        if (!quicConn.streamWrite(localControlStreamId, frameHeader[0 .. headerLen], false))
            return false;
        if (!quicConn.streamWrite(localControlStreamId, goawayPayload[0 .. payloadLen], false))
            return false;

        localGoawaySent = true;
        localGoawayStreamId = streamId;
        return true;
    }

    /**
     * Sends HTTP/3 trailing headers on an existing bidirectional stream (RFC 9114 §4.1).
     */
    bool sendTrailers(ref QuicConnection quicConn, StreamId streamId,
            const(H3HeaderField)[] trailers) @safe @nogc nothrow
    {
        if (connectionClosed)
            return false;
        if (validateTrailers(trailers) != H3ErrorCode.noError)
            return false;
        ubyte[4096] qpackBuf;
        const size_t qpackLen = encodeQpackFieldSection(trailers, qpackBuf[], true);
        if (qpackLen == 0)
            return false;
        ubyte[16] hdrFrameBuf;
        size_t hdrFrameLen = 0;
        if (!encodeH3FrameHeader(H3FrameType.headers, qpackLen, hdrFrameBuf[], hdrFrameLen))
            return false;
        if (!quicConn.streamWrite(streamId, hdrFrameBuf[0 .. hdrFrameLen], false))
            return false;
        if (!quicConn.streamWrite(streamId, qpackBuf[0 .. qpackLen], true))
            return false;
        return true;
    }

    /**
     * Aborts the HTTP/3 connection with an error code (RFC 9114 Section 8).
     */
    void abortConnection(ref QuicConnection quicConn, H3ErrorCode err) @safe @nogc nothrow
    {
        if (connectionClosed)
            return;
        connectionClosed = true;
        closeErrorCode = cast(ulong) err;
        quicConn.close(cast(ulong) err, true);
        events.forcePush(H3Event(H3EventType.connectionClosed, StreamId.init, cast(ulong) err));
    }

    /**
     * Polls the next H3Event, driving incoming streams from QuicConnection.
     */
    bool pollEvent(ref QuicConnection quicConn, out H3Event event) @trusted @nogc nothrow
    {
        if (events.poll(event))
            return true;

        if (connectionClosed)
            return false;

        // Poll incoming QUIC events
        ConnectionEvent qev;
        while (quicConn.pollEvent(qev))
        {
            if (qev.type == ConnectionEventType.connectionClosed)
            {
                connectionClosed = true;
                closeErrorCode = qev.errorCode;
                event = H3Event(H3EventType.connectionClosed, StreamId.init, qev.errorCode);
                return true;
            }

            if (qev.type == ConnectionEventType.streamReset)
            {
                const StreamId sid = StreamId(qev.streamId);
                if ((peerControlKnown && sid == peerControlStreamId) || (peerQpackEncKnown
                        && sid == peerQpackEncStreamId) || (peerQpackDecKnown
                        && sid == peerQpackDecStreamId))
                {
                    abortConnection(quicConn, H3ErrorCode.closedCriticalStream);
                    return events.poll(event);
                }
                H3StreamTracker* tr = findStream(sid);
                if (tr !is null && (tr.kind == H3StreamKind.control
                        || tr.kind == H3StreamKind.qpackEncoder
                        || tr.kind == H3StreamKind.qpackDecoder))
                {
                    abortConnection(quicConn, H3ErrorCode.closedCriticalStream);
                    return events.poll(event);
                }
            }

            if (qev.type == ConnectionEventType.stopSending)
            {
                const StreamId sid = StreamId(qev.streamId);
                if (localStreamsInitialized && (sid == localControlStreamId
                        || sid == localQpackEncStreamId || sid == localQpackDecStreamId))
                {
                    abortConnection(quicConn, H3ErrorCode.closedCriticalStream);
                    return events.poll(event);
                }
            }

            if (qev.type == ConnectionEventType.streamFinished)
            {
                const StreamId sid = StreamId(qev.streamId);
                if ((peerControlKnown && sid == peerControlStreamId) || (peerQpackEncKnown
                        && sid == peerQpackEncStreamId) || (peerQpackDecKnown
                        && sid == peerQpackDecStreamId))
                {
                    abortConnection(quicConn, H3ErrorCode.closedCriticalStream);
                    return events.poll(event);
                }
                H3StreamTracker* tr = findStream(sid);
                if (tr !is null && (tr.kind == H3StreamKind.control
                        || tr.kind == H3StreamKind.qpackEncoder
                        || tr.kind == H3StreamKind.qpackDecoder))
                {
                    abortConnection(quicConn, H3ErrorCode.closedCriticalStream);
                    return events.poll(event);
                }

                if (sid.canReceive(side))
                {
                    H3StreamTracker* tracker = getOrCreateStream(sid);
                    if (tracker is null)
                    {
                        abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                        return events.poll(event);
                    }

                    ubyte[4096] tmp;
                    bool finReached = false;
                    ptrdiff_t n = 0;
                    while ((n = quicConn.streamRead(sid, tmp[], finReached)) > 0)
                    {
                        if (!tracker.appendRecv(tmp[0 .. cast(size_t) n]))
                        {
                            abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                            return events.poll(event);
                        }
                        if (finReached)
                            break;
                    }
                    if (finReached)
                        tracker.finReceived = true;

                    processStream(tracker, quicConn);
                    if (events.poll(event))
                        return true;
                }
            }

            if (qev.type == ConnectionEventType.streamReadable)
            {
                const StreamId sid = StreamId(qev.streamId);
                H3StreamTracker* tracker = getOrCreateStream(sid);
                if (tracker is null)
                {
                    abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                    return events.poll(event);
                }

                ubyte[4096] tmp;
                bool finReached = false;
                ptrdiff_t n = 0;
                while ((n = quicConn.streamRead(sid, tmp[], finReached)) > 0)
                {
                    if (!tracker.appendRecv(tmp[0 .. cast(size_t) n]))
                    {
                        abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                        return events.poll(event);
                    }
                    if (finReached)
                        break;
                }
                if (finReached)
                    tracker.finReceived = true;

                processStream(tracker, quicConn);
                if (events.poll(event))
                    return true;
            }
        }

        // Process any remaining buffered stream data
        foreach (i; 0 .. streamCount)
        {
            if (streams[i].recvBufLen > 0 || (streams[i].kind == H3StreamKind.request
                    && streams[i].finReceived && !streams[i].requestFinishedEmitted))
            {
                processStream(&streams[i], quicConn);
                if (events.poll(event))
                    return true;
            }
        }

        return false;
    }

    private H3StreamTracker* findStream(StreamId sid) @trusted @nogc nothrow
    {
        foreach (i; 0 .. streamCount)
        {
            if (streams[i].id == sid)
                return &streams[i];
        }
        return null;
    }

    private H3StreamTracker* getOrCreateStream(StreamId sid) @trusted @nogc nothrow
    {
        H3StreamTracker* existing = findStream(sid);
        if (existing !is null)
            return existing;

        if (streamCount >= MAX_TRACKED_STREAMS)
            return null;

        if (streamCount >= streamCapacity)
        {
            size_t newCap = streamCapacity == 0 ? 16 : streamCapacity * 2;
            if (newCap > MAX_TRACKED_STREAMS)
                newCap = MAX_TRACKED_STREAMS;
            H3StreamTracker* p = cast(H3StreamTracker*) realloc(streams,
                    newCap * H3StreamTracker.sizeof);
            if (p is null)
                return null;
            streams = p;
            streamCapacity = newCap;
        }

        H3StreamTracker* tr = &streams[streamCount++];
        *tr = H3StreamTracker.init;
        tr.id = sid;
        if (sid.isBidirectional)
            tr.kind = H3StreamKind.request;
        return tr;
    }

    private void processStream(H3StreamTracker* tracker, ref QuicConnection quicConn) @trusted @nogc nothrow
    {
        if (connectionClosed || tracker is null)
            return;

        // Handle unidirectional stream type byte
        if (tracker.id.isUnidirectional && !tracker.typeDecoded)
        {
            if (tracker.recvBufLen == 0)
            {
                if (tracker.finReceived)
                {
                    abortConnection(quicConn, H3ErrorCode.frameError);
                }
                return;
            }

            ulong uniType = 0;
            size_t consumed = 0;
            if (decodeVarInt(tracker.recvBuf[0 .. tracker.recvBufLen], uniType,
                    consumed) != WireError.none)
            {
                if (tracker.finReceived)
                {
                    abortConnection(quicConn, H3ErrorCode.frameError);
                }
                return;
            }

            tracker.consumeRecv(consumed);
            tracker.typeDecoded = true;

            if (uniType == H3UniStreamType.control)
            {
                if (peerControlKnown)
                {
                    abortConnection(quicConn, H3ErrorCode.streamCreationError);
                    return;
                }
                peerControlKnown = true;
                peerControlStreamId = tracker.id;
                tracker.kind = H3StreamKind.control;
            }
            else if (uniType == H3UniStreamType.qpackEncoder)
            {
                if (peerQpackEncKnown)
                {
                    abortConnection(quicConn, H3ErrorCode.streamCreationError);
                    return;
                }
                peerQpackEncKnown = true;
                peerQpackEncStreamId = tracker.id;
                tracker.kind = H3StreamKind.qpackEncoder;
            }
            else if (uniType == H3UniStreamType.qpackDecoder)
            {
                if (peerQpackDecKnown)
                {
                    abortConnection(quicConn, H3ErrorCode.streamCreationError);
                    return;
                }
                peerQpackDecKnown = true;
                peerQpackDecStreamId = tracker.id;
                tracker.kind = H3StreamKind.qpackDecoder;
            }
            else if (uniType == H3UniStreamType.push)
            {
                // RFC 9114 Section 6.2.2 & 4.6
                if (side == Side.server)
                {
                    abortConnection(quicConn, H3ErrorCode.streamCreationError);
                    return;
                }
                else
                {
                    abortConnection(quicConn, H3ErrorCode.idError);
                    return;
                }
            }
            else
            {
                // GREASE or unknown unidirectional stream type (RFC 9114 Section 6.2)
                tracker.kind = H3StreamKind.unknown;
                tracker.recvBufLen = 0; // Discard immediately
            }
        }

        // Check if critical unidirectional stream closed
        if (tracker.id.isUnidirectional && tracker.finReceived)
        {
            if (tracker.kind == H3StreamKind.control || tracker.kind == H3StreamKind.qpackEncoder
                    || tracker.kind == H3StreamKind.qpackDecoder)
            {
                abortConnection(quicConn, H3ErrorCode.closedCriticalStream);
                return;
            }
        }

        // Non-control unidirectional streams discard unneeded bytes
        if (tracker.id.isUnidirectional && tracker.kind != H3StreamKind.control)
        {
            tracker.recvBufLen = 0;
            return;
        }

        // Process Control Stream frames
        if (tracker.kind == H3StreamKind.control)
        {
            while (tracker.recvBufLen > 0)
            {
                // First frame precedence check on Control Stream (D6.3):
                ulong peekType = 0;
                size_t peekConsumed = 0;
                if (decodeVarInt(tracker.recvBuf[0 .. tracker.recvBufLen],
                        peekType, peekConsumed) == WireError.none)
                {
                    if (!peerControlSettingsReceived && peekType != H3FrameType.settings)
                    {
                        abortConnection(quicConn, H3ErrorCode.missingSettings);
                        return;
                    }
                }

                size_t offset = 0;
                H3FrameHeader hdr;
                H3ErrorCode ferr = decodeH3FrameHeader(tracker.recvBuf[0 .. tracker.recvBufLen],
                        offset, hdr);
                if (ferr == H3ErrorCode.frameUnexpected)
                {
                    abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                    return;
                }
                if (ferr != H3ErrorCode.noError)
                    break;

                if (hdr.length > MAX_CONTROL_FRAME_SIZE)
                {
                    abortConnection(quicConn, H3ErrorCode.frameError);
                    return;
                }

                if (tracker.recvBufLen - offset < cast(size_t) hdr.length)
                    break;

                const size_t frameTotalBytes = offset + cast(size_t) hdr.length;
                const(ubyte)[] payload = tracker.recvBuf[offset .. offset + cast(size_t) hdr.length];

                if (!peerControlSettingsReceived)
                {
                    if (hdr.type != H3FrameType.settings)
                    {
                        abortConnection(quicConn, H3ErrorCode.missingSettings);
                        return;
                    }

                    H3Settings s;
                    H3ErrorCode serr = decodeSettingsPayload(payload, s);
                    if (serr != H3ErrorCode.noError)
                    {
                        abortConnection(quicConn, serr);
                        return;
                    }

                    tracker.consumeRecv(frameTotalBytes);
                    peerControlSettingsReceived = true;
                    peerSettingsReceived = true;
                    peerSettings = s;
                    events.push(H3Event(H3EventType.peerSettingsReceived, tracker.id, 0, s));
                }
                else
                {
                    if (hdr.type == H3FrameType.settings)
                    {
                        abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                        return;
                    }
                    if (hdr.type == H3FrameType.data || hdr.type == H3FrameType.headers
                            || hdr.type == H3FrameType.pushPromise)
                    {
                        abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                        return;
                    }
                    if (side == Side.client && hdr.type == H3FrameType.maxPushId)
                    {
                        abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                        return;
                    }
                    if (hdr.type == H3FrameType.cancelPush || hdr.type == H3FrameType.maxPushId)
                    {
                        if (payload.length == 0)
                        {
                            abortConnection(quicConn, H3ErrorCode.frameError);
                            return;
                        }
                        ulong pushId = 0;
                        size_t vConsumed = 0;
                        if (decodeVarInt(payload, pushId,
                                vConsumed) != WireError.none || vConsumed != payload.length)
                        {
                            abortConnection(quicConn, H3ErrorCode.frameError);
                            return;
                        }
                    }
                    if (hdr.type == H3FrameType.goaway)
                    {
                        ulong lastId = 0;
                        H3ErrorCode gerr = decodeGoawayPayload(payload, lastId);
                        if (gerr != H3ErrorCode.noError)
                        {
                            abortConnection(quicConn, gerr);
                            return;
                        }
                        if (side == Side.client && (lastId & 0x03) != 0)
                        {
                            abortConnection(quicConn, H3ErrorCode.idError);
                            return;
                        }
                        if (peerGoawayReceived && lastId > peerGoawayStreamId)
                        {
                            abortConnection(quicConn, H3ErrorCode.idError);
                            return;
                        }
                        peerGoawayReceived = true;
                        peerGoawayStreamId = lastId;
                        events.push(H3Event(H3EventType.goawayReceived, StreamId(lastId)));
                    }
                    tracker.consumeRecv(frameTotalBytes);
                    // GREASE and unknown frames are cleanly ignored
                }
            }

            if (tracker.finReceived && tracker.recvBufLen > 0)
            {
                abortConnection(quicConn, H3ErrorCode.frameError);
                return;
            }
            return;
        }

        // Process Bidirectional Request Stream frames
        if (tracker.kind == H3StreamKind.request)
        {
            while (tracker.recvBufLen > 0)
            {
                size_t offset = 0;
                H3FrameHeader hdr;
                H3ErrorCode ferr = decodeH3FrameHeader(tracker.recvBuf[0 .. tracker.recvBufLen],
                        offset, hdr);
                if (ferr == H3ErrorCode.frameUnexpected)
                {
                    abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                    return;
                }
                if (ferr != H3ErrorCode.noError)
                    break;

                // Frame length checks (Part B.8)
                const ulong maxHdrAllowed = localSettings.maxFieldSectionSize < 65536
                    ? localSettings.maxFieldSectionSize : 65536;
                if (hdr.type == H3FrameType.headers && hdr.length > maxHdrAllowed)
                {
                    abortConnection(quicConn, H3ErrorCode.qpackDecompressionFailed);
                    return;
                }
                if (hdr.length > MAX_STREAM_BUFFER_SIZE)
                {
                    abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                    return;
                }

                if (tracker.recvBufLen - offset < cast(size_t) hdr.length)
                    break;

                const size_t frameTotalBytes = offset + cast(size_t) hdr.length;
                const(ubyte)[] payload = tracker.recvBuf[offset .. offset + cast(size_t) hdr.length];

                // Forbidden frames on request stream (RFC 9114 Section 7.2)
                if (hdr.type == H3FrameType.settings || hdr.type == H3FrameType.goaway
                        || hdr.type == H3FrameType.cancelPush
                        || hdr.type == H3FrameType.maxPushId || hdr.type == H3FrameType.pushPromise)
                {
                    abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                    return;
                }

                if (hdr.type == H3FrameType.headers)
                {
                    if (tracker.trailersReceived)
                    {
                        abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                        return;
                    }

                    const size_t neededStrCap = maxHdrAllowed > 4096 ? cast(size_t) maxHdrAllowed
                        : 4096;
                    if (!tracker.ensureStrBufCapacity(neededStrCap))
                    {
                        abortConnection(quicConn, H3ErrorCode.internalError);
                        return;
                    }

                    H3HeaderField[MAX_H3_HEADERS] decHdrs;
                    size_t hCount = 0;
                    size_t strUsed = 0;
                    H3ErrorCode qerr = decodeQpackFieldSection(payload, decHdrs[], hCount,
                            tracker.strBuf[0 .. tracker.strBufCapacity],
                            strUsed, localSettings.maxFieldSectionSize);
                    if (qerr != H3ErrorCode.noError)
                    {
                        abortConnection(quicConn, qerr);
                        return;
                    }

                    if (!tracker.initialHeadersReceived)
                    {
                        const bool isResponse = (side == Side.client);
                        H3ErrorCode verr = validateHeaders(decHdrs[0 .. hCount], isResponse,
                                tracker.hasContentLength, tracker.expectedContentLength);
                        if (verr != H3ErrorCode.noError)
                        {
                            abortConnection(quicConn, verr);
                            return;
                        }

                        // Informational 1xx responses (except 101 which is rejected) allow subsequent final response
                        if (isResponse && decHdrs[0].value.length == 3 && decHdrs[0].value[0] == '1')
                        {
                            // Keep initialHeadersReceived false
                        }
                        else
                        {
                            tracker.initialHeadersReceived = true;
                        }
                    }
                    else
                    {
                        // Trailing headers
                        if (tracker.hasContentLength
                                && tracker.receivedDataBytes != tracker.expectedContentLength)
                        {
                            abortConnection(quicConn, H3ErrorCode.messageError);
                            return;
                        }

                        H3ErrorCode verr = validateTrailers(decHdrs[0 .. hCount]);
                        if (verr != H3ErrorCode.noError)
                        {
                            abortConnection(quicConn, verr);
                            return;
                        }
                        tracker.trailersReceived = true;
                    }

                    tracker.consumeRecv(frameTotalBytes);

                    if (tracker.finReceived && tracker.recvBufLen == 0)
                    {
                        if (tracker.hasContentLength
                                && tracker.receivedDataBytes != tracker.expectedContentLength)
                        {
                            abortConnection(quicConn, H3ErrorCode.messageError);
                            return;
                        }
                    }

                    H3Event ev;
                    ev.type = H3EventType.headersReceived;
                    ev.streamId = tracker.id;
                    ev.headers[0 .. hCount] = decHdrs[0 .. hCount];
                    ev.headerCount = hCount;
                    ev.fin = tracker.finReceived && (tracker.recvBufLen == 0);
                    events.push(ev);

                    if (tracker.finReceived && tracker.recvBufLen == 0
                            && !tracker.requestFinishedEmitted)
                    {
                        tracker.requestFinishedEmitted = true;
                        events.push(H3Event(H3EventType.requestFinished, tracker.id));
                    }
                    return;
                }
                else if (hdr.type == H3FrameType.data)
                {
                    if (!tracker.initialHeadersReceived || tracker.trailersReceived)
                    {
                        abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                        return;
                    }

                    if (ulong.max - tracker.receivedDataBytes < payload.length)
                    {
                        abortConnection(quicConn, H3ErrorCode.messageError);
                        return;
                    }

                    tracker.receivedDataBytes += payload.length;
                    if (tracker.hasContentLength
                            && tracker.receivedDataBytes > tracker.expectedContentLength)
                    {
                        abortConnection(quicConn, H3ErrorCode.messageError);
                        return;
                    }

                    tracker.dataBufLen = 0;
                    if (!tracker.ensureDataBufCapacity(payload.length))
                    {
                        abortConnection(quicConn, H3ErrorCode.internalError);
                        return;
                    }
                    tracker.dataBuf[0 .. payload.length] = payload[];
                    const(ubyte)[] dataSlice = tracker.dataBuf[0 .. payload.length];
                    tracker.dataBufLen = payload.length;

                    tracker.consumeRecv(frameTotalBytes);

                    if (tracker.finReceived && tracker.recvBufLen == 0)
                    {
                        if (tracker.hasContentLength
                                && tracker.receivedDataBytes != tracker.expectedContentLength)
                        {
                            abortConnection(quicConn, H3ErrorCode.messageError);
                            return;
                        }
                    }

                    H3Event ev;
                    ev.type = H3EventType.dataReceived;
                    ev.streamId = tracker.id;
                    ev.data = dataSlice;
                    ev.fin = tracker.finReceived && (tracker.recvBufLen == 0);
                    events.push(ev);

                    if (tracker.finReceived && tracker.recvBufLen == 0
                            && !tracker.requestFinishedEmitted)
                    {
                        tracker.requestFinishedEmitted = true;
                        events.push(H3Event(H3EventType.requestFinished, tracker.id));
                    }
                    return;
                }
                else
                {
                    // GREASE and unknown frames cleanly ignored
                    tracker.consumeRecv(frameTotalBytes);
                }
            }

            if (tracker.finReceived && tracker.recvBufLen > 0)
            {
                abortConnection(quicConn, H3ErrorCode.frameError);
                return;
            }

            if (tracker.finReceived && tracker.recvBufLen == 0 && !tracker.requestFinishedEmitted)
            {
                if (!tracker.initialHeadersReceived)
                {
                    abortConnection(quicConn, H3ErrorCode.requestIncomplete);
                    return;
                }
                if (tracker.hasContentLength
                        && tracker.receivedDataBytes != tracker.expectedContentLength)
                {
                    abortConnection(quicConn, H3ErrorCode.messageError);
                    return;
                }
                tracker.requestFinishedEmitted = true;
                events.push(H3Event(H3EventType.requestFinished, tracker.id));
            }
        }
    }
}

/// Example:
// Spec: RFC 9114 Section 4.1.2, Section 4.3 - HTTP/3 Pseudo-Headers, CRLF/NUL & Content-Length Validation (covers Scenario T5, U1, U3, W3, F5)
@nogc unittest
{
    // 1. Valid request headers
    const H3HeaderField[4] validReq = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("accept", "text/html")
    ];
    bool hasCl = false;
    ulong cl = 0;
    assert(validateHeaders(validReq[], false, hasCl, cl) == H3ErrorCode.noError);
    assert(!hasCl);

    // 2. Missing :path on request
    const H3HeaderField[2] missingPath = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https")
    ];
    assert(validateHeaders(missingPath[], false) == H3ErrorCode.messageError);

    // 3. Pseudo-header after regular header
    const H3HeaderField[3] misplacedPseudo = [
        H3HeaderField(":method", "GET"),
        H3HeaderField("user-agent", "slate-h3/1.0"), H3HeaderField(":path", "/")
    ];
    assert(validateHeaders(misplacedPseudo[], false) == H3ErrorCode.messageError);

    // 4. Duplicate :method
    const H3HeaderField[4] dupMethod = [
        H3HeaderField(":method", "GET"), H3HeaderField(":method", "POST"),
        H3HeaderField(":scheme", "https"), H3HeaderField(":path", "/")
    ];
    assert(validateHeaders(dupMethod[], false) == H3ErrorCode.messageError);

    // 5. Uppercase character in header name "Accept"
    const H3HeaderField[4] upperName = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("Accept", "text/plain")
    ];
    assert(validateHeaders(upperName[], false) == H3ErrorCode.messageError);

    // 6. CRLF / NUL injection in header name or value
    const H3HeaderField[4] crlfVal = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("x-bad", "value\r\ninjected")
    ];
    assert(validateHeaders(crlfVal[], false) == H3ErrorCode.messageError);

    const H3HeaderField[4] nulVal = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("x-bad", "val\0ue")
    ];
    assert(validateHeaders(nulVal[], false) == H3ErrorCode.messageError);

    // 7. Forbidden HTTP/2 connection-specific header "connection"
    const H3HeaderField[4] forbiddenConn = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("connection", "keep-alive")
    ];
    assert(validateHeaders(forbiddenConn[], false) == H3ErrorCode.messageError);

    // 8. Content-Length parsing and validation
    const H3HeaderField[5] validCl = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/upload"), H3HeaderField("content-length",
                "1024"), H3HeaderField("content-type", "application/octet-stream")
    ];
    assert(validateHeaders(validCl[], false, hasCl, cl) == H3ErrorCode.noError);
    assert(hasCl && cl == 1024);

    const H3HeaderField[4] badCl = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/upload"),
        H3HeaderField("content-length", "not-a-number")
    ];
    assert(validateHeaders(badCl[], false) == H3ErrorCode.messageError);

    // 9. Valid response headers
    const H3HeaderField[2] validResp = [
        H3HeaderField(":status", "200"),
        H3HeaderField("content-type", "application/json")
    ];
    assert(validateHeaders(validResp[], true) == H3ErrorCode.noError);

    // 10. Missing :status on response
    const H3HeaderField[1] missingStatus = [
        H3HeaderField("content-type", "application/json")
    ];
    assert(validateHeaders(missingStatus[], true) == H3ErrorCode.messageError);

    // 11. Invalid :status digits or 101 Switching Protocols forbidden in HTTP/3
    const H3HeaderField[1] badStatus = [H3HeaderField(":status", "20A")];
    assert(validateHeaders(badStatus[], true) == H3ErrorCode.messageError);

    const H3HeaderField[1] status101 = [H3HeaderField(":status", "101")];
    assert(validateHeaders(status101[], true) == H3ErrorCode.messageError);

    // 12. Header value leading/trailing whitespace rejection (RFC 9114 §10.3 / D7)
    const H3HeaderField[4] leadWs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("x-space", " leading")
    ];
    assert(validateHeaders(leadWs[], false) == H3ErrorCode.messageError);

    const H3HeaderField[4] trailWs = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("x-space", "trailing ")
    ];
    assert(validateHeaders(trailWs[], false) == H3ErrorCode.messageError);

    // 13. Invalid header name token characters (spaces, colons inside name)
    const H3HeaderField[4] spaceName = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("bad name", "val")
    ];
    assert(validateHeaders(spaceName[], false) == H3ErrorCode.messageError);

    // 14. TE header: only "trailers" allowed
    const H3HeaderField[4] badTe = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("te", "gzip")
    ];
    assert(validateHeaders(badTe[], false) == H3ErrorCode.messageError);

    const H3HeaderField[4] goodTe = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/"), H3HeaderField("te", "trailers")
    ];
    assert(validateHeaders(goodTe[], false) == H3ErrorCode.noError);

    // 15. CONNECT method validation (RFC 9114 §4.4)
    const H3HeaderField[2] validConnect = [
        H3HeaderField(":method", "CONNECT"),
        H3HeaderField(":authority", "example.com:443")
    ];
    assert(validateHeaders(validConnect[], false) == H3ErrorCode.noError);

    const H3HeaderField[3] connectWithPath = [
        H3HeaderField(":method", "CONNECT"),
        H3HeaderField(":authority", "example.com:443"),
        H3HeaderField(":path", "/")
    ];
    assert(validateHeaders(connectWithPath[], false) == H3ErrorCode.messageError);

    // 16. Trailing headers validation (RFC 9114 §4.3)
    const H3HeaderField[1] validTrailer = [
        H3HeaderField("x-checksum", "abcdef")
    ];
    assert(validateTrailers(validTrailer[]) == H3ErrorCode.noError);

    const H3HeaderField[1] pseudoTrailer = [H3HeaderField(":status", "200")];
    assert(validateTrailers(pseudoTrailer[]) == H3ErrorCode.messageError);

    const H3HeaderField[1] clTrailer = [H3HeaderField("content-length", "10")];
    assert(validateTrailers(clTrailer[]) == H3ErrorCode.messageError);
}

/// Example:
// Spec: RFC 9114 Section 3 - H3Connection RAII Lifecycle, Move Semantics & High-Iteration Alloc/Free (covers U1, U2, U3, G4)
@nogc unittest
{
    // High iteration leak check: 1000 iterations of creation, mutation, and destruction
    foreach (iter; 0 .. 1000)
    {
        H3Connection c1 = H3Connection(Side.client);
        assert(!c1.isClosed);
        assert(!c1.isPeerSettingsReceived);

        H3Connection c2 = H3Connection(Side.server);
        c2.moveFrom(c1);
        assert(!c2.isClosed);
    }
}
