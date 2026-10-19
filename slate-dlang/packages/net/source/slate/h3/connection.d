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

import core.stdc.stdlib : calloc, realloc, free, malloc;
import core.stdc.string : memmove;

private struct HeapBuffer
{
    ubyte[] slice;

    static HeapBuffer allocate(size_t cap) @trusted @nogc nothrow
    {
        if (cap == 0)
            return HeapBuffer(null);
        void* p = malloc(cap);
        if (p is null)
            return HeapBuffer(null);
        return HeapBuffer((cast(ubyte*) p)[0 .. cap]);
    }

    void free() @trusted @nogc nothrow
    {
        if (slice.ptr !is null)
        {
            .free(slice.ptr);
            slice = null;
        }
    }
}

public enum H3EventType : ubyte
{
    none = 0,
    peerSettingsReceived,
    headersReceived,
    dataReceived,
    requestFinished,
    goawayReceived,
    connectionClosed,
    /// A request stream was reset locally because of a stream error (RFC 9114 Section 4.1.2);
    /// `errorCode` carries the HTTP/3 error code sent in RESET_STREAM/STOP_SENDING.
    streamReset
}

/**
 * An event emitted by H3Connection.
 *
 * Lifetime: `headers` (names and values) and `data` are slices of buffers owned by the
 * stream's tracker. They stay valid until the next call to `H3Connection.pollEvent` on the same
 * connection; copy what must outlive that call. `sendRequest` and `sendResponse` never
 * invalidate them.
 */
public struct H3Event
{
    H3EventType type = H3EventType.none;
    StreamId streamId;
    ulong errorCode = 0;
    H3Settings settings;

    /// Decoded field lines of a `headersReceived` event (at most `MAX_H3_HEADERS`); a slice of
    /// the stream's buffer, valid until the next `pollEvent`.
    const(H3HeaderField)[] headers;
    size_t headerCount = 0;

    const(ubyte)[] data;
    bool fin = false;
}

public enum size_t MAX_STREAM_BUFFER_SIZE = 1024 * 1024; // 1 MiB
public enum size_t MAX_CONTROL_FRAME_SIZE = 16 * 1024; // 16 KiB
public enum size_t MAX_TRACKED_STREAMS = 256;
/// Largest piece of a DATA frame delivered in one `dataReceived` event (plan D5).
public enum size_t H3_MAX_DATA_CHUNK = 16 * 1024;
/// Unconsumed bytes per stream above which no more data is pulled from QUIC (plan D3);
/// QUIC flow-control credit is then returned only as frames are consumed.
/// Field section limit applied (and advertised) when the application configures none.
public enum size_t H3_DEFAULT_MAX_FIELD_SECTION_SIZE = 64 * 1024; // 64 KiB
public enum size_t H3_RECV_HIGH_WATER = 64 * 1024; // 64 KiB

private enum size_t EVENT_QUEUE_CAPACITY = 256;

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

    /// Whether an undelivered event refers to `sid` (its slices may still point into the
    /// stream's buffers).
    bool hasEventFor(StreamId sid) const @safe pure nothrow @nogc
    {
        foreach (i; 0 .. count)
        {
            if (buffer[(head + i) % EVENT_QUEUE_CAPACITY].streamId == sid)
                return true;
        }
        return false;
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
/**
 * Validates bytes received on the peer's QPACK encoder stream while our decoder's dynamic table
 * capacity limit is 0 (RFC 9204 Section 4.3): the only instruction that can be valid is Set
 * Dynamic Table Capacity with capacity 0 (`0x20`, Section 4.3.1); every insertion needs capacity
 * and a larger capacity exceeds the limit.
 */
private bool qpackEncoderBytesValid(const(ubyte)[] bytes) @safe @nogc nothrow pure
{
    foreach (b; bytes)
    {
        if (b != 0x20)
            return false;
    }
    return true;
}

/**
 * Validates bytes received on the peer's QPACK decoder stream. This endpoint never inserts into
 * the dynamic table, so Section Acknowledgment and Insert Count Increment (RFC 9204 Section 4.4.1,
 * 4.4.3) can only be errors, while Stream Cancellation (`01` pattern with a 6-bit prefix stream
 * ID, Section 4.4.2) is always legal. `cont` carries the number of continuation bytes of a
 * multi-byte integer across calls; an integer longer than 9 continuation bytes overflows
 * 62 bits and is rejected.
 */
private bool qpackDecoderBytesValid(const(ubyte)[] bytes, ref ubyte cont) @safe @nogc nothrow pure
{
    foreach (b; bytes)
    {
        if (cont > 0)
        {
            if (b & 0x80)
            {
                if (cont >= 9)
                    return false;
                cont++;
            }
            else
                cont = 0;
            continue;
        }
        if ((b & 0xc0) != 0x40)
            return false;
        if ((b & 0x3f) == 0x3f)
            cont = 1;
    }
    return true;
}

/// Frame types this endpoint interprets on the control stream (RFC 9114 Section 7.2); every
/// other type is ignored (Section 9).
private bool isKnownControlFrame(ulong type) @safe @nogc nothrow pure
{
    return type == H3FrameType.data || type == H3FrameType.headers || type == H3FrameType.cancelPush
        || type == H3FrameType.settings || type == H3FrameType.pushPromise
        || type == H3FrameType.goaway || type == H3FrameType.maxPushId;
}

private struct H3StreamTracker
{
    StreamId id;
    H3StreamKind kind = H3StreamKind.unknown;
    bool typeDecoded = false;
    bool initialHeadersReceived = false;
    bool trailersReceived = false;
    bool finReceived = false;
    bool requestFinishedEmitted = false;
    /// Set once this side reset the request stream (RFC 9114 Section 4.1.2 stream error);
    /// further peer data is discarded and no further events are emitted for the stream.
    bool locallyReset = false;
    /// The QUIC stream may still hold unread data that was left there for back-pressure.
    bool quicDataPending = false;
    /// Client side: the request on this stream used the HEAD method.
    bool isHeadRequest = false;
    /// Bytes of the frame being streamed (DATA, delivered in chunks, or an unknown frame that is
    /// skipped) that are still to come; the frame header was consumed already (plan D5).
    ulong frameRemaining = 0;
    /// `frameRemaining` belongs to a DATA frame (otherwise to a frame that is skipped).
    bool frameIsData = false;
    /// Decoder stream: continuation bytes of a Stream Cancellation integer still expected (R-22).
    ubyte qpackCont = 0;

    bool hasContentLength = false;
    ulong expectedContentLength = 0;
    ulong receivedDataBytes = 0;
    ushort responseStatus = 0;

    ubyte* recvBuf = null;
    size_t recvBufLen = 0;
    size_t recvReadOffset = 0;
    size_t recvBufCapacity = 0;

    char* strBuf = null;
    size_t strBufCapacity = 0;

    ubyte* dataBuf = null;
    size_t dataBufLen = 0;
    size_t dataBufCapacity = 0;

    /// Decoded field lines backing a `headersReceived` event (`MAX_H3_HEADERS` entries).
    H3HeaderField* hdrBuf = null;

    @property size_t readableBytes() const @safe pure nothrow @nogc
    {
        return recvBufLen > recvReadOffset ? recvBufLen - recvReadOffset : 0;
    }

    @property inout(ubyte)[] readableSlice() inout @trusted pure nothrow @nogc
    {
        return recvBufLen > recvReadOffset ? recvBuf[recvReadOffset .. recvBufLen] : null;
    }

    /**
     * Whether the response on this stream is defined to have no content: 1xx, 204, 304 or a
     * response to HEAD (RFC 9110 Section 6.4.1). Only meaningful on the client side.
     */
    bool responseHasNoContent(Side side) const @safe pure nothrow @nogc
    {
        return side == Side.client && (isHeadRequest || responseStatus == 204
                || responseStatus == 304 || (responseStatus >= 100 && responseStatus < 200));
    }

    void cleanup() @trusted @nogc nothrow
    {
        releaseRecv();

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
        if (hdrBuf !is null)
        {
            free(hdrBuf);
            hdrBuf = null;
        }
        responseStatus = 0;
    }

    bool appendRecv(const(ubyte)[] data) @trusted @nogc nothrow
    {
        if (data.length == 0)
            return true;
        // Reject before mutating anything: the cap applies to unread bytes (R-01).
        const size_t unread = readableBytes;
        if (data.length > MAX_STREAM_BUFFER_SIZE || unread > MAX_STREAM_BUFFER_SIZE - data.length)
            return false;
        const size_t needed = unread + data.length;

        // Compact consumed bytes away whenever the tail lacks room, so that the write
        // offset never exceeds the capacity (the cap alone only bounds unread bytes).
        if (recvReadOffset > 0 && (recvBufLen + data.length > recvBufCapacity
                || recvReadOffset > 4096))
        {
            if (unread > 0)
                memmove(recvBuf, recvBuf + recvReadOffset, unread);
            recvBufLen = unread;
            recvReadOffset = 0;
        }
        if (recvBufLen + data.length > recvBufCapacity)
        {
            size_t newCap = recvBufCapacity == 0 ? 512 : recvBufCapacity * 2;
            while (newCap < needed)
                newCap *= 2;
            if (newCap > MAX_STREAM_BUFFER_SIZE)
                newCap = MAX_STREAM_BUFFER_SIZE;
            ubyte* p = cast(ubyte*) realloc(recvBuf, newCap);
            if (p is null)
                return false;
            recvBuf = p;
            recvBufCapacity = newCap;
        }
        // Bounds-checked through the capacity slice as a second line of defence.
        recvBuf[0 .. recvBufCapacity][recvBufLen .. recvBufLen + data.length] = data[];
        recvBufLen += data.length;
        return true;
    }

    /**
     * Whether the buffered input starts with a complete frame (or with bytes that are
     * already a frame error), i.e. processing can make progress without more input. A HEADERS
     * frame announcing more than `maxFieldSection` bytes counts as complete: processing rejects it
     * from its header alone, so nothing more may be buffered for it.
     */
    bool hasCompleteFrame(ulong maxFieldSection = ulong.max) const @safe pure nothrow @nogc
    {
        const(ubyte)[] s = readableSlice;
        if (s.length == 0)
            return false;
        // Inside a streamed frame any byte is progress (D5).
        if (frameRemaining > 0)
            return true;
        size_t off = 0;
        H3FrameHeader hdr;
        const H3ErrorCode err = decodeH3FrameHeader(s, off, hdr);
        if (err == H3ErrorCode.frameError)
            return false; // truncated frame header
        if (err != H3ErrorCode.noError)
            return true;
        if (kind == H3StreamKind.request && hdr.type == H3FrameType.headers
                && hdr.length > maxFieldSection)
            return true;
        // Only frames whose payload must be parsed as a whole need it buffered; DATA and unknown
        // frames are streamed, and misplaced frames are rejected from their header alone.
        const bool whole = (kind == H3StreamKind.request) ? hdr.type == H3FrameType.headers
            : (kind == H3StreamKind.control
                    && (hdr.type == H3FrameType.settings || hdr.type == H3FrameType.goaway
                        || hdr.type == H3FrameType.cancelPush || hdr.type == H3FrameType.maxPushId));
        return !whole || hdr.length <= s.length - off;
    }

    /// Frees the buffers that backed delivered events (decoded strings, field lines, DATA chunk);
    /// call only when no queued event refers to this stream and the caller has moved on from
    /// the previously returned one (L1: a request stream must not pin them while it idles).
    void releaseScratch() @trusted @nogc nothrow
    {
        if (strBuf !is null)
        {
            free(strBuf);
            strBuf = null;
        }
        strBufCapacity = 0;
        if (hdrBuf !is null)
        {
            free(hdrBuf);
            hdrBuf = null;
        }
        if (dataBuf !is null)
        {
            free(dataBuf);
            dataBuf = null;
        }
        dataBufLen = 0;
        dataBufCapacity = 0;
    }

    /// Frees the receive buffer only; header/data buffers may back already emitted events.
    void releaseRecv() @trusted @nogc nothrow
    {
        if (recvBuf !is null)
        {
            free(recvBuf);
            recvBuf = null;
        }
        recvBufLen = 0;
        recvReadOffset = 0;
        recvBufCapacity = 0;
    }

    void consumeRecv(size_t bytes) @safe pure nothrow @nogc
    {
        recvReadOffset += bytes;
        if (recvReadOffset >= recvBufLen)
        {
            recvReadOffset = 0;
            recvBufLen = 0;
        }
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

    /// Allocates the field-line buffer on first use.
    bool ensureHdrBuf() @trusted @nogc nothrow
    {
        if (hdrBuf !is null)
            return true;
        hdrBuf = cast(H3HeaderField*) malloc(MAX_H3_HEADERS * H3HeaderField.sizeof);
        return hdrBuf !is null;
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

/// ASCII case-insensitive equality (HTTP token and host comparisons).
private bool equalsIgnoreAsciiCase(const(char)[] a, const(char)[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        const ca = (a[i] >= 'A' && a[i] <= 'Z') ? cast(char)(a[i] + 32) : a[i];
        const cb = (b[i] >= 'A' && b[i] <= 'Z') ? cast(char)(b[i] + 32) : b[i];
        if (ca != cb)
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

    const(char)[] schemeVal = null;
    const(char)[] authorityVal = null;
    const(char)[] hostVal = null;
    size_t hostCount = 0;

    foreach (const ref h; headers)
    {
        if (h.name.length == 0)
            return H3ErrorCode.messageError;

        if (!isValidHeaderValue(h.value))
            return H3ErrorCode.messageError;

        // RFC 9114 Section 4.2: field names are lowercase on the wire.
        foreach (ch; cast(const(ubyte)[]) h.name)
        {
            if (ch >= 'A' && ch <= 'Z')
                return H3ErrorCode.messageError;
        }

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
                    schemeVal = h.value;
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
                    authorityVal = h.value;
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

            // TE header check (RFC 9114 Section 4.2); the token is case-insensitive (RFC 9110
            // Section 10.1.4)
            if (h.name == "te" && !equalsIgnoreAsciiCase(h.value, "trailers"))
                return H3ErrorCode.messageError;

            // Host header tracking (RFC 9114 §4.3.1)
            if (h.name == "host")
            {
                hostCount++;
                if (h.value.length == 0)
                    return H3ErrorCode.messageError;
                hostVal = h.value;
            }

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

            // RFC 9114 §4.3.1: :authority and Host validation
            if (schemeVal == "http" || schemeVal == "https")
            {
                if (hostCount > 1)
                    return H3ErrorCode.messageError; // Duplicate host
                if (!hasAuthority && hostCount == 0)
                    return H3ErrorCode.messageError; // Neither :authority nor host
                if (hasAuthority && authorityVal.length == 0)
                    return H3ErrorCode.messageError; // Empty :authority
                // The host of an authority is case-insensitive (RFC 9110 Section 4.2.3).
                if (hasAuthority && hostCount > 0 && !equalsIgnoreAsciiCase(authorityVal, hostVal))
                    return H3ErrorCode.messageError; // Mismatched :authority and host
            }
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

    bool hasMaxPushId = false;
    ulong maxPushId = 0;

    bool connectionClosed = false;
    ulong closeErrorCode = 0;
    H3ErrorCode lastError = H3ErrorCode.noError;

    private H3StreamTracker* streams = null;
    private size_t streamCount = 0;
    private enum size_t REAPED_RING_SIZE = 1024;
    private ulong[REAPED_RING_SIZE] reapedRing;
    private size_t reapedHead = 0;
    private size_t reapedCount = 0;
    private size_t streamCapacity = 0;

    private H3EventQueue events;

    this(Side side, H3Settings localSettings = H3Settings.init) @safe pure nothrow @nogc
    {
        this.side = side;
        this.localSettings = localSettings;
        // An unset limit would let one request stream buffer up to the 1 MiB stream cap before
        // its field section is decoded; apply a bounded default instead (RFC 9114 Section 4.2.2,
        // advertised to the peer through SETTINGS_MAX_FIELD_SECTION_SIZE).
        if (this.localSettings.maxFieldSectionSize == ulong.max)
            this.localSettings.maxFieldSectionSize = H3_DEFAULT_MAX_FIELD_SECTION_SIZE;
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
        this.hasMaxPushId = other.hasMaxPushId;
        this.maxPushId = other.maxPushId;
        this.connectionClosed = other.connectionClosed;
        this.closeErrorCode = other.closeErrorCode;
        this.lastError = other.lastError;
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
     *
     * Returns false, without opening a stream, when the request cannot be sent right now. One
     * cause is that every tracker slot is taken: slots of finished streams are only released
     * by `pollEvent`, so when all slots hold finished-but-unreaped streams the caller must
     * call `pollEvent` (and handle its events) before retrying; retrying `sendRequest` alone
     * never frees them.
     */
    bool sendRequest(ref QuicConnection quicConn, const(H3HeaderField)[] headers,
            const(ubyte)[] body, bool fin, out StreamId streamId) @safe @nogc nothrow
    {
        if (connectionClosed || peerGoawayReceived || side != Side.client)
            return false;

        H3ErrorCode err = validateHeaders(headers, false);
        if (err != H3ErrorCode.noError)
            return false;

        // Everything that can fail before the wire is touched comes first: the HEADERS block
        // is encoded and a tracker slot is checked before a QUIC stream is opened, so a
        // failure leaves neither a half-open stream nor a consumed stream id behind.
        const size_t maxBufCap = peerSettings.maxFieldSectionSize < 65536
            ? cast(size_t) peerSettings.maxFieldSectionSize : 65536;
        if (maxBufCap == 0)
            return false;
        HeapBuffer buf = HeapBuffer.allocate(maxBufCap);
        if (buf.slice is null)
            return false;
        scope (exit)
            buf.free();
        ubyte[] qpackBuf = buf.slice;

        const size_t qpackLen = encodeQpackFieldSection(headers, qpackBuf, true);
        if (qpackLen == 0 || qpackLen > peerSettings.maxFieldSectionSize)
            return false;

        ubyte[16] hdrFrameBuf;
        size_t hdrFrameLen = 0;
        if (!encodeH3FrameHeader(H3FrameType.headers, qpackLen, hdrFrameBuf[], hdrFrameLen))
            return false;

        if (!hasTrackerSlot())
            return false;

        if (quicConn.openStream(StreamDirection.bidirectional,
                streamId) != TransportErrorCode.noError)
            return false;

        // Track the request before any byte is sent: a response to HEAD has no content
        // (RFC 9110 Section 9.3.2, RFC 9114 Section 4.1.2), and a stream that cannot be
        // tracked is never written to.
        H3StreamTracker* tracker = getOrCreateStream(streamId);
        if (tracker is null)
        {
            quicConn.resetStream(streamId, cast(ulong) H3ErrorCode.requestCancelled);
            return false;
        }
        foreach (const ref h; headers)
        {
            if (h.name == ":method")
            {
                tracker.isHeadRequest = (h.value == "HEAD");
                break;
            }
        }

        // A failed write abandons the stream: peer and tracker see a cancelled request.
        const bool headersFin = fin && (body.length == 0);
        if (!quicConn.streamWrite(streamId, hdrFrameBuf[0 .. hdrFrameLen],
                false) || !quicConn.streamWrite(streamId, qpackBuf[0 .. qpackLen], headersFin))
            return abandonRequest(quicConn, tracker);

        // If body present, encode and write DATA frame
        if (body.length > 0)
        {
            ubyte[16] dataFrameBuf;
            size_t dataFrameLen = 0;
            if (!encodeH3FrameHeader(H3FrameType.data, body.length, dataFrameBuf[],
                    dataFrameLen) || !quicConn.streamWrite(streamId, dataFrameBuf[0 .. dataFrameLen],
                    false) || !quicConn.streamWrite(streamId, body, fin))
                return abandonRequest(quicConn, tracker);
        }
        return true;
    }

    /// Cancels a request whose writes failed partway; always returns false for the caller.
    private bool abandonRequest(ref QuicConnection quicConn, H3StreamTracker* tracker) @trusted @nogc nothrow
    {
        if (!tracker.locallyReset)
        {
            quicConn.resetStream(tracker.id, cast(ulong) H3ErrorCode.requestCancelled);
            quicConn.stopSending(tracker.id, cast(ulong) H3ErrorCode.requestCancelled);
            quicConn.abandonRecv(tracker.id);
            tracker.locallyReset = true;
            tracker.requestFinishedEmitted = true;
            tracker.quicDataPending = false;
            tracker.releaseRecv();
        }
        return false;
    }

    /**
     * Whether a new tracker can be created. Finished streams are not released here: that
     * would free buffers behind event slices the caller has just polled (see `H3Event`).
     * They are released by the next `pollEvent`.
     */
    private bool hasTrackerSlot() const @safe @nogc nothrow
    {
        return streamCount < MAX_TRACKED_STREAMS;
    }

    /// Test seam: fills tracker slots with idle peer unidirectional streams until `free` remain.
    version (unittest) package void occupyTrackerSlots(size_t free) @trusted @nogc nothrow
    {
        ulong next = 1_000_003;
        while (streamCount + free < MAX_TRACKED_STREAMS)
        {
            auto tr = getOrCreateStream(StreamId(next));
            if (tr is null)
                break;
            tr.kind = H3StreamKind.unknown;
            next += 4;
        }
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

        // Encode HEADERS frame (D-11: dynamic buffer up to 64 KiB respecting peerSettings)
        const size_t maxBufCap = peerSettings.maxFieldSectionSize < 65536
            ? cast(size_t) peerSettings.maxFieldSectionSize : 65536;
        if (maxBufCap == 0)
            return false;
        HeapBuffer buf = HeapBuffer.allocate(maxBufCap);
        if (buf.slice is null)
            return false;
        scope (exit)
            buf.free();
        ubyte[] qpackBuf = buf.slice;

        const size_t qpackLen = encodeQpackFieldSection(allHeaders[0 .. totalCount], qpackBuf, true);
        if (qpackLen == 0 || qpackLen > peerSettings.maxFieldSectionSize)
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
        if (!localStreamsInitialized || connectionClosed)
            return false;
        if (localGoawaySent && streamId > localGoawayStreamId)
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
        // Encode HEADERS frame (D-11: dynamic buffer up to 64 KiB respecting peerSettings)
        const size_t maxBufCap = peerSettings.maxFieldSectionSize < 65536
            ? cast(size_t) peerSettings.maxFieldSectionSize : 65536;
        if (maxBufCap == 0)
            return false;
        HeapBuffer buf = HeapBuffer.allocate(maxBufCap);
        if (buf.slice is null)
            return false;
        scope (exit)
            buf.free();
        ubyte[] qpackBuf = buf.slice;

        const size_t qpackLen = encodeQpackFieldSection(trailers, qpackBuf, true);
        if (qpackLen == 0 || qpackLen > peerSettings.maxFieldSectionSize)
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
        lastError = err;
        quicConn.close(cast(ulong) err, true);
        events.forcePush(H3Event(H3EventType.connectionClosed, StreamId.init, cast(ulong) err));
    }

    /**
     * Polls the next H3Event, driving incoming streams from QuicConnection.
     *
     * The slices inside the returned event (`headers`, `data`) are valid until the next call
     * to `pollEvent`. Finished streams are released at the start of that next call, and only
     * once no undelivered event refers to them.
     */
    bool pollEvent(ref QuicConnection quicConn, out H3Event event) @trusted @nogc nothrow
    {
        reapFinishedStreams();
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
                if (tr !is null)
                {
                    if (tr.kind == H3StreamKind.control || tr.kind == H3StreamKind.qpackEncoder
                            || tr.kind == H3StreamKind.qpackDecoder)
                    {
                        abortConnection(quicConn, H3ErrorCode.closedCriticalStream);
                        return events.poll(event);
                    }
                    if (tr.kind == H3StreamKind.request)
                    {
                        // The buffers may back events that are still queued; the tracker is
                        // released by `reapFinishedStreams` once those are delivered.
                        // R-23: an incomplete request that the peer abandons is reported
                        // (a locally reset one was already, and a finished one needs no event).
                        const bool report = !tr.locallyReset && !tr.requestFinishedEmitted;
                        tr.finReceived = true;
                        tr.requestFinishedEmitted = true;
                        tr.quicDataPending = false;
                        tr.releaseRecv();
                        if (report)
                        {
                            if (!events.push(H3Event(H3EventType.streamReset,
                                    tr.id, qev.errorCode)))
                            {
                                abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                                return events.poll(event);
                            }
                            if (events.poll(event))
                                return true;
                        }
                    }
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

                if (side == Side.client && sid.isBidirectional && !sid.isClientInitiated)
                {
                    abortConnection(quicConn, H3ErrorCode.streamCreationError);
                    return events.poll(event);
                }

                if (side == Side.server && localGoawaySent
                        && sid.isBidirectional && sid.id >= localGoawayStreamId)
                {
                    quicConn.resetStream(sid, cast(ulong) H3ErrorCode.requestRejected);
                    quicConn.stopSending(sid, cast(ulong) H3ErrorCode.requestRejected);
                    continue;
                }

                if (sid.canReceive(side))
                {
                    // A stale notification for a stream that was already released must not
                    // resurrect it as a fresh, never-finishing tracker.
                    if (wasReaped(sid))
                        continue;
                    H3StreamTracker* tracker = getOrCreateStream(sid);
                    if (tracker is null)
                    {
                        abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                        return events.poll(event);
                    }

                    if (!drainQuicStream(tracker, quicConn))
                        return events.poll(event);

                    processStream(tracker, quicConn);
                    if (events.poll(event))
                        return true;
                }
            }

            if (qev.type == ConnectionEventType.streamReadable)
            {
                const StreamId sid = StreamId(qev.streamId);
                if (side == Side.client && sid.isBidirectional && !sid.isClientInitiated)
                {
                    abortConnection(quicConn, H3ErrorCode.streamCreationError);
                    return events.poll(event);
                }

                if (side == Side.server && localGoawaySent
                        && sid.isBidirectional && sid.id >= localGoawayStreamId)
                {
                    quicConn.resetStream(sid, cast(ulong) H3ErrorCode.requestRejected);
                    quicConn.stopSending(sid, cast(ulong) H3ErrorCode.requestRejected);
                    continue;
                }

                if (wasReaped(sid))
                    continue; // stale notification for a released stream
                H3StreamTracker* tracker = getOrCreateStream(sid);
                if (tracker is null)
                {
                    abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                    return events.poll(event);
                }

                if (!drainQuicStream(tracker, quicConn))
                    return events.poll(event);

                processStream(tracker, quicConn);
                if (events.poll(event))
                    return true;
            }
        }

        // Process any remaining buffered stream data, refilling streams that were left with
        // unread QUIC data by back-pressure (no new QUIC event will announce that data).
        foreach (i; 0 .. streamCount)
        {
            H3StreamTracker* tr = &streams[i];
            if (tr.quicDataPending)
            {
                if (!drainQuicStream(tr, quicConn))
                    return events.poll(event);
            }
            if (tr.readableBytes > 0 || (tr.kind == H3StreamKind.request
                    && tr.finReceived && !tr.requestFinishedEmitted))
            {
                processStream(tr, quicConn);
                if (events.poll(event))
                    return true;
            }
        }

        return false;
    }

    /**
     * Resets one request stream with a stream error (RFC 9114 Section 4.1.2, plan D4): sends
     * RESET_STREAM and STOP_SENDING carrying `err`, drops buffered input and emits
     * `H3EventType.streamReset`. Other streams and the connection stay open.
     */
    private void resetRequestStream(H3StreamTracker* tracker,
            ref QuicConnection quicConn, H3ErrorCode err) @trusted @nogc nothrow
    {
        if (tracker.locallyReset)
            return;
        quicConn.resetStream(tracker.id, cast(ulong) err);
        quicConn.stopSending(tracker.id, cast(ulong) err);
        quicConn.abandonRecv(tracker.id);
        tracker.locallyReset = true;
        tracker.requestFinishedEmitted = true;
        tracker.quicDataPending = false;
        tracker.releaseRecv();
        if (!events.push(H3Event(H3EventType.streamReset, tracker.id, cast(ulong) err)))
            abortConnection(quicConn, H3ErrorCode.excessiveLoad);
    }

    /// Largest HEADERS payload accepted: the advertised field section limit, capped by what a
    /// stream buffer can hold.
    private @property ulong maxFieldSectionLen() const @safe pure @nogc nothrow
    {
        return localSettings.maxFieldSectionSize < MAX_STREAM_BUFFER_SIZE - 16
            ? localSettings.maxFieldSectionSize : MAX_STREAM_BUFFER_SIZE - 16;
    }

    /**
     * Moves readable QUIC stream data into the tracker. Data of unknown unidirectional
     * streams and of locally reset request streams is read and discarded so that flow
     * control credit keeps flowing. Returns false if the connection was aborted.
     */
    private bool drainQuicStream(H3StreamTracker* tracker, ref QuicConnection quicConn) @trusted @nogc nothrow
    {
        const StreamId sid = tracker.id;
        ubyte[4096] tmp;
        bool finReached = false;
        tracker.quicDataPending = false;
        for (;;)
        {
            const bool discard = tracker.locallyReset || (tracker.typeDecoded
                    && tracker.kind == H3StreamKind.unknown);
            // Back-pressure (D3): leave data in QUIC while enough is buffered to make
            // progress. A frame that is still incomplete keeps being read (bounded by
            // MAX_STREAM_BUFFER_SIZE) so that processing can never stall.
            if (!discard && tracker.readableBytes >= H3_RECV_HIGH_WATER
                    && tracker.hasCompleteFrame(maxFieldSectionLen))
            {
                tracker.quicDataPending = true;
                break;
            }
            const ptrdiff_t n = quicConn.streamRead(sid, tmp[], finReached);
            if (n < 0)
            {
                // The QUIC stream is gone; a locally reset tracker can now be reclaimed.
                if (tracker.locallyReset)
                    tracker.finReceived = true;
                break;
            }
            if (n == 0)
                break;
            if (!discard)
            {
                if (!tracker.appendRecv(tmp[0 .. cast(size_t) n]))
                {
                    abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                    return false;
                }
                if (!tracker.typeDecoded && sid.isUnidirectional)
                {
                    processStream(tracker, quicConn);
                    if (connectionClosed)
                        return false;
                }
            }
            if (finReached)
                break;
        }
        if (finReached)
            tracker.finReceived = true;
        return true;
    }

    /// Number of request/control streams currently tracked (for tests and diagnostics).
    package @property size_t trackedStreamCount() const @safe @nogc nothrow pure
    {
        return streamCount;
    }

    private void reapFinishedStreams() @trusted @nogc nothrow
    {
        for (size_t i = 0; i < streamCount;)
        {
            H3StreamTracker* tr = &streams[i];
            // A stream reset locally has nothing left to wait for: its input is discarded, so it is
            // released once no event refers to it instead of being pinned until the peer's FIN (PB-4).
            const bool canReap = (tr.kind == H3StreamKind.request && tr.requestFinishedEmitted
                    && ((tr.finReceived && tr.readableBytes == 0) || tr.locallyReset)
                    && !events.hasEventFor(tr.id)) || (tr.kind == H3StreamKind.unknown
                    && tr.finReceived && tr.readableBytes == 0);
            if (canReap)
            {
                rememberReaped(tr.id);
                tr.cleanup();
                if (i + 1 < streamCount)
                    streams[i] = streams[streamCount - 1];
                streams[streamCount - 1] = H3StreamTracker.init;
                streamCount--;
            }
            else
            {
                // The previous event's slices are invalid from the next `pollEvent` on, so the
                // scratch buffers behind them need not stay allocated.
                if (!events.hasEventFor(tr.id))
                    tr.releaseScratch();
                i++;
            }
        }
    }

    /// Bytes currently held by the per-stream header and DATA scratch buffers (tests, L1).
    package @property size_t scratchBytes() const @trusted @nogc nothrow pure
    {
        size_t total = 0;
        foreach (ref const tr; streams[0 .. streamCount])
            total += tr.strBufCapacity + tr.dataBufCapacity + (tr.hdrBuf !is null
                    ? MAX_H3_HEADERS * H3HeaderField.sizeof : 0);
        return total;
    }

    /// Records a released request stream so that late QUIC notifications for it are ignored
    /// instead of resurrecting it as a fresh tracker. Bounded ring: notifications are bounded by
    /// the QUIC event queue, which is far smaller than the ring.
    private void rememberReaped(StreamId sid) @safe @nogc nothrow
    {
        reapedRing[reapedHead] = sid.id;
        reapedHead = (reapedHead + 1) % REAPED_RING_SIZE;
        if (reapedCount < REAPED_RING_SIZE)
            reapedCount++;
    }

    private bool wasReaped(StreamId sid) @trusted @nogc nothrow
    {
        if (findStream(sid) !is null)
            return false;
        foreach (i; 0 .. reapedCount)
        {
            if (reapedRing[i] == sid.id)
                return true;
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

        if (side == Side.client && sid.isBidirectional && !sid.isClientInitiated)
            return null;

        if (streamCount >= MAX_TRACKED_STREAMS)
        {
            reapFinishedStreams();
        }

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
        if (tracker.locallyReset)
        {
            tracker.consumeRecv(tracker.readableBytes);
            return;
        }

        // Handle unidirectional stream type byte
        if (tracker.id.isUnidirectional && !tracker.typeDecoded)
        {
            if (tracker.readableBytes == 0)
            {
                if (tracker.finReceived)
                {
                    abortConnection(quicConn, H3ErrorCode.frameError);
                }
                return;
            }

            ulong uniType = 0;
            size_t consumed = 0;
            if (decodeVarInt(tracker.readableSlice, uniType, consumed) != WireError.none)
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
                tracker.consumeRecv(tracker.readableBytes);
                return;
            }
        }

        // F-49 & F-50: Unidirectional streams other than control
        if (tracker.id.isUnidirectional && tracker.kind != H3StreamKind.control)
        {
            if (tracker.kind == H3StreamKind.qpackEncoder)
            {
                if (localSettings.qpackMaxTableCapacity == 0
                        && !qpackEncoderBytesValid(tracker.readableSlice))
                {
                    abortConnection(quicConn, H3ErrorCode.qpackEncoderStreamError);
                    return;
                }
                tracker.consumeRecv(tracker.readableBytes);
            }
            else if (tracker.kind == H3StreamKind.qpackDecoder)
            {
                if (!qpackDecoderBytesValid(tracker.readableSlice, tracker.qpackCont))
                {
                    abortConnection(quicConn, H3ErrorCode.qpackDecoderStreamError);
                    return;
                }
                tracker.consumeRecv(tracker.readableBytes);
            }
            else if (tracker.kind == H3StreamKind.unknown)
            {
                tracker.consumeRecv(tracker.readableBytes);
            }

            if (tracker.finReceived)
            {
                if (tracker.kind == H3StreamKind.qpackEncoder
                        || tracker.kind == H3StreamKind.qpackDecoder)
                {
                    abortConnection(quicConn, H3ErrorCode.closedCriticalStream);
                    return;
                }
            }
            return;
        }

        // F-51: Process Control Stream frames
        if (tracker.kind == H3StreamKind.control)
        {
            for (;;)
            {
                // An unknown frame is skipped as its bytes arrive; its length is not bounded by
                // MAX_CONTROL_FRAME_SIZE (RFC 9114 Section 9, plan D5).
                if (tracker.frameRemaining > 0)
                {
                    const size_t avail = tracker.readableBytes;
                    if (avail == 0)
                        break;
                    const size_t n = avail < tracker.frameRemaining ? avail
                        : cast(size_t) tracker.frameRemaining;
                    tracker.consumeRecv(n);
                    tracker.frameRemaining -= n;
                    continue;
                }
                if (tracker.readableBytes == 0)
                    break;
                const(ubyte)[] slice = tracker.readableSlice;
                // First frame precedence check on Control Stream (D6.3):
                ulong peekType = 0;
                size_t peekConsumed = 0;
                if (decodeVarInt(slice, peekType, peekConsumed) == WireError.none)
                {
                    if (!peerControlSettingsReceived && peekType != H3FrameType.settings)
                    {
                        abortConnection(quicConn, H3ErrorCode.missingSettings);
                        return;
                    }
                }

                size_t offset = 0;
                H3FrameHeader hdr;
                H3ErrorCode ferr = decodeH3FrameHeader(slice, offset, hdr);
                if (ferr == H3ErrorCode.frameUnexpected)
                {
                    abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                    return;
                }
                if (ferr != H3ErrorCode.noError)
                    break;

                // Frames this endpoint does not know are skipped without buffering (after SETTINGS).
                if (peerControlSettingsReceived && !isKnownControlFrame(hdr.type))
                {
                    tracker.consumeRecv(offset);
                    tracker.frameRemaining = hdr.length;
                    continue;
                }

                if (peerControlSettingsReceived && (hdr.type == H3FrameType.settings
                        || hdr.type == H3FrameType.data || hdr.type == H3FrameType.headers
                        || hdr.type == H3FrameType.pushPromise))
                {
                    abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                    return;
                }
                if (!peerControlSettingsReceived && hdr.type != H3FrameType.settings)
                {
                    abortConnection(quicConn, H3ErrorCode.missingSettings);
                    return;
                }

                if (hdr.length > MAX_CONTROL_FRAME_SIZE)
                {
                    abortConnection(quicConn, H3ErrorCode.frameError);
                    return;
                }

                if (slice.length - offset < cast(size_t) hdr.length)
                    break;

                const size_t frameTotalBytes = offset + cast(size_t) hdr.length;
                const(ubyte)[] payload = slice[offset .. offset + cast(size_t) hdr.length];

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
                    if (!events.push(H3Event(H3EventType.peerSettingsReceived, tracker.id, 0, s)))
                    {
                        abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                        return;
                    }
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
                        if (hdr.type == H3FrameType.maxPushId)
                        {
                            if (hasMaxPushId && pushId < maxPushId)
                            {
                                abortConnection(quicConn, H3ErrorCode.idError);
                                return;
                            }
                            hasMaxPushId = true;
                            maxPushId = pushId;
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
                        if (!events.push(H3Event(H3EventType.goawayReceived, StreamId(lastId))))
                        {
                            abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                            return;
                        }
                    }
                    tracker.consumeRecv(frameTotalBytes);
                    // GREASE and unknown frames are cleanly ignored
                }
            }

            // After parsing all complete frames: check FIN (F-51)
            if (tracker.finReceived)
            {
                if (tracker.readableBytes > 0)
                {
                    abortConnection(quicConn, H3ErrorCode.frameError);
                    return;
                }
                abortConnection(quicConn, H3ErrorCode.closedCriticalStream);
                return;
            }
            return;
        }

        // Process Bidirectional Request Stream frames
        if (tracker.kind == H3StreamKind.request)
        {
            for (;;)
            {
                // Inside a DATA frame (delivered in chunks as it arrives) or an unknown frame
                // (skipped incrementally): neither needs the frame to be buffered (plan D5).
                if (tracker.frameRemaining > 0)
                {
                    const size_t avail = tracker.readableBytes;
                    if (avail == 0)
                        break;
                    size_t n = avail < tracker.frameRemaining ? avail
                        : cast(size_t) tracker.frameRemaining;
                    if (!tracker.frameIsData)
                    {
                        tracker.consumeRecv(n);
                        tracker.frameRemaining -= n;
                        continue;
                    }
                    if (n > H3_MAX_DATA_CHUNK)
                        n = H3_MAX_DATA_CHUNK;

                    tracker.dataBufLen = 0;
                    if (!tracker.ensureDataBufCapacity(n))
                    {
                        abortConnection(quicConn, H3ErrorCode.internalError);
                        return;
                    }
                    tracker.dataBuf[0 .. n] = tracker.readableSlice[0 .. n];
                    tracker.dataBufLen = n;
                    tracker.consumeRecv(n);
                    tracker.frameRemaining -= n;
                    tracker.receivedDataBytes += n; // bounded by the length check at the frame header
                    const(ubyte)[] dataSlice = tracker.dataBuf[0 .. n];

                    const bool atEnd = tracker.finReceived
                        && tracker.readableBytes == 0 && tracker.frameRemaining == 0;
                    if (atEnd && tracker.hasContentLength
                            && tracker.receivedDataBytes != tracker.expectedContentLength)
                    {
                        resetRequestStream(tracker, quicConn, H3ErrorCode.messageError);
                        return;
                    }

                    H3Event ev;
                    ev.type = H3EventType.dataReceived;
                    ev.streamId = tracker.id;
                    ev.data = dataSlice;
                    ev.fin = atEnd;
                    if (!events.push(ev))
                    {
                        abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                        return;
                    }
                    if (atEnd && !tracker.requestFinishedEmitted)
                    {
                        tracker.requestFinishedEmitted = true;
                        if (!events.push(H3Event(H3EventType.requestFinished, tracker.id)))
                        {
                            abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                            return;
                        }
                    }
                    return;
                }
                if (tracker.readableBytes == 0)
                    break;

                const(ubyte)[] slice = tracker.readableSlice;
                size_t offset = 0;
                H3FrameHeader hdr;
                H3ErrorCode ferr = decodeH3FrameHeader(slice, offset, hdr);
                if (ferr == H3ErrorCode.frameUnexpected)
                {
                    abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                    return;
                }
                if (ferr != H3ErrorCode.noError)
                    break;

                // Forbidden frames on request stream (RFC 9114 Section 7.2)
                if (hdr.type == H3FrameType.settings || hdr.type == H3FrameType.goaway
                        || hdr.type == H3FrameType.cancelPush
                        || hdr.type == H3FrameType.maxPushId || hdr.type == H3FrameType.pushPromise)
                {
                    abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                    return;
                }

                if (hdr.type == H3FrameType.data)
                {
                    if (!tracker.initialHeadersReceived || tracker.trailersReceived)
                    {
                        abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                        return;
                    }
                    // The declared length is checked up front: a body that cannot match the
                    // message framing is a malformed message (RFC 9114 Section 4.1.2).
                    if (tracker.responseHasNoContent(side) || ulong.max - tracker.receivedDataBytes < hdr.length
                            || (tracker.hasContentLength
                                && tracker.receivedDataBytes + hdr.length
                                > tracker.expectedContentLength))
                    {
                        resetRequestStream(tracker, quicConn, H3ErrorCode.messageError);
                        return;
                    }
                    tracker.consumeRecv(offset);
                    tracker.frameRemaining = hdr.length;
                    tracker.frameIsData = true;
                    continue;
                }

                if (hdr.type != H3FrameType.headers)
                {
                    // GREASE and unknown frames are skipped as they arrive (RFC 9114 Section 9).
                    tracker.consumeRecv(offset);
                    tracker.frameRemaining = hdr.length;
                    tracker.frameIsData = false;
                    continue;
                }

                // A field section larger than SETTINGS_MAX_FIELD_SECTION_SIZE (or than the
                // stream buffer) is a stream error, not a connection error (RFC 9114 Section 4.2.2).
                if (hdr.length > maxFieldSectionLen)
                {
                    resetRequestStream(tracker, quicConn, H3ErrorCode.excessiveLoad);
                    return;
                }

                if (slice.length - offset < cast(size_t) hdr.length)
                    break;

                const size_t frameTotalBytes = offset + cast(size_t) hdr.length;
                const(ubyte)[] payload = slice[offset .. offset + cast(size_t) hdr.length];

                if (hdr.type == H3FrameType.headers)
                {
                    if (tracker.trailersReceived)
                    {
                        abortConnection(quicConn, H3ErrorCode.frameUnexpected);
                        return;
                    }

                    // Huffman expands at most 8/5, so twice the payload always holds the strings.
                    const size_t neededStrCap = payload.length * 2 > 4096 ? payload.length * 2
                        : 4096;
                    if (!tracker.ensureStrBufCapacity(neededStrCap) || !tracker.ensureHdrBuf())
                    {
                        abortConnection(quicConn, H3ErrorCode.internalError);
                        return;
                    }

                    H3HeaderField[] decHdrs = tracker.hdrBuf[0 .. MAX_H3_HEADERS];
                    size_t hCount = 0;
                    size_t strUsed = 0;
                    H3ErrorCode qerr = decodeQpackFieldSection(payload, decHdrs[], hCount,
                            tracker.strBuf[0 .. tracker.strBufCapacity],
                            strUsed, localSettings.maxFieldSectionSize);
                    if (qerr == H3ErrorCode.excessiveLoad)
                    {
                        // Too many field lines or too large a section: only this stream fails.
                        resetRequestStream(tracker, quicConn, qerr);
                        return;
                    }
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
                            resetRequestStream(tracker, quicConn, verr);
                            return;
                        }

                        if (isResponse)
                        {
                            foreach (ref h; decHdrs[0 .. hCount])
                            {
                                if (h.name == ":status" && h.value.length == 3)
                                {
                                    tracker.responseStatus = cast(ushort)(
                                            (h.value[0] - '0') * 100 + (
                                            h.value[1] - '0') * 10 + (h.value[2] - '0'));
                                    break;
                                }
                            }
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
                        const bool isNoBody = tracker.responseHasNoContent(side);
                        if (!isNoBody && tracker.hasContentLength
                                && tracker.receivedDataBytes != tracker.expectedContentLength)
                        {
                            resetRequestStream(tracker, quicConn, H3ErrorCode.messageError);
                            return;
                        }

                        H3ErrorCode verr = validateTrailers(decHdrs[0 .. hCount]);
                        if (verr != H3ErrorCode.noError)
                        {
                            resetRequestStream(tracker, quicConn, verr);
                            return;
                        }
                        tracker.trailersReceived = true;
                    }

                    tracker.consumeRecv(frameTotalBytes);

                    const bool isNoBody = tracker.responseHasNoContent(side);
                    if (tracker.finReceived && tracker.readableBytes == 0)
                    {
                        if (isNoBody)
                        {
                            if (tracker.receivedDataBytes != 0)
                            {
                                resetRequestStream(tracker, quicConn, H3ErrorCode.messageError);
                                return;
                            }
                        }
                        else if (tracker.hasContentLength
                                && tracker.receivedDataBytes != tracker.expectedContentLength)
                        {
                            resetRequestStream(tracker, quicConn, H3ErrorCode.messageError);
                            return;
                        }
                    }

                    H3Event ev;
                    ev.type = H3EventType.headersReceived;
                    ev.streamId = tracker.id;
                    ev.headers = decHdrs[0 .. hCount];
                    ev.headerCount = hCount;
                    ev.fin = tracker.finReceived && (tracker.readableBytes == 0);
                    if (!events.push(ev))
                    {
                        abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                        return;
                    }

                    if (tracker.finReceived && tracker.readableBytes == 0
                            && !tracker.requestFinishedEmitted)
                    {
                        tracker.requestFinishedEmitted = true;
                        if (!events.push(H3Event(H3EventType.requestFinished, tracker.id)))
                        {
                            abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                            return;
                        }
                    }
                    return;
                }
            }

            if (tracker.finReceived && (tracker.readableBytes > 0 || tracker.frameRemaining > 0))
            {
                // The stream ended inside a frame (RFC 9114 Section 7.1).
                abortConnection(quicConn, H3ErrorCode.frameError);
                return;
            }

            if (tracker.finReceived && tracker.readableBytes == 0
                    && !tracker.requestFinishedEmitted)
            {
                if (!tracker.initialHeadersReceived)
                {
                    abortConnection(quicConn, H3ErrorCode.requestIncomplete);
                    return;
                }
                const bool isNoBody = tracker.responseHasNoContent(side);
                if (isNoBody)
                {
                    if (tracker.receivedDataBytes != 0)
                    {
                        resetRequestStream(tracker, quicConn, H3ErrorCode.messageError);
                        return;
                    }
                }
                else if (tracker.hasContentLength
                        && tracker.receivedDataBytes != tracker.expectedContentLength)
                {
                    resetRequestStream(tracker, quicConn, H3ErrorCode.messageError);
                    return;
                }
                tracker.requestFinishedEmitted = true;
                if (!events.push(H3Event(H3EventType.requestFinished, tracker.id)))
                {
                    abortConnection(quicConn, H3ErrorCode.excessiveLoad);
                    return;
                }
            }
        }
    }
}

/// Example:
/// ---
/// const H3HeaderField[1] validTrailer = [H3HeaderField("x-checksum", "abcdef")];
/// const H3HeaderField[1] pseudoTrailer = [H3HeaderField(":status", "200")];
/// const H3HeaderField[1] clTrailer = [H3HeaderField("content-length", "10")];
/// assert(validateTrailers(validTrailer[]) == H3ErrorCode.noError);
/// assert(validateTrailers(pseudoTrailer[]) == H3ErrorCode.messageError);   // no pseudo-headers
/// assert(validateTrailers(clTrailer[]) == H3ErrorCode.messageError);       // no framing headers
/// ---
// Spec: RFC 9114 Section 4.1.2, Section 4.3 - HTTP/3 Pseudo-Headers, CRLF/NUL & Content-Length Validation (covers Scenario T5, U1, U3, W3, F5)
@nogc unittest
{
    // 1. Valid request headers
    const H3HeaderField[5] validReq = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"), H3HeaderField(":path",
                "/"), H3HeaderField("accept", "text/html")
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
    const H3HeaderField[6] validCl = [
        H3HeaderField(":method", "POST"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"),
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

    const H3HeaderField[5] goodTe = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "example.com"), H3HeaderField(":path",
                "/"), H3HeaderField("te", "trailers")
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
/// ---
/// H3Connection c1 = H3Connection(Side.client);
/// assert(!c1.isClosed && !c1.isPeerSettingsReceived);
///
/// H3Connection c2 = H3Connection(Side.server);
/// c2.moveFrom(c1);                 // c2 takes over the state, c1 is left empty
/// assert(!c2.isClosed);
/// ---
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

/// Example:
/// ---
/// H3StreamTracker t;
/// scope (exit)
///     t.cleanup();
///
/// ubyte[128] first;
/// assert(t.appendRecv(first[]));
/// t.consumeRecv(100);              // a 100-byte HEADERS frame was processed
/// assert(t.readableBytes == 28);
///
/// ubyte[4096] chunk;
/// assert(t.appendRecv(chunk[]));   // the next DATA bytes arrive in 4 KiB chunks
/// assert(t.recvBufLen <= t.recvBufCapacity);
/// assert(t.recvBufCapacity <= MAX_STREAM_BUFFER_SIZE);
/// ---
// Spec: Best practice: memory safety of peer-driven buffering - appendRecv must account for
// consumed bytes and never write beyond its allocation (R-01, W1, Scenario T1).
@nogc unittest
{
    H3StreamTracker t;
    scope (exit)
        t.cleanup();

    // A 100-byte frame plus the first 28 bytes of the following DATA frame header/payload.
    ubyte[128] first;
    foreach (i, ref b; first)
        b = cast(ubyte)(i + 1);
    assert(t.appendRecv(first[]));
    t.consumeRecv(100); // HEADERS frame processed; 28 unread bytes remain
    assert(t.readableBytes == 28);

    // Peer delivers the rest of a (1 MiB - 64)-byte DATA frame in 4 KiB chunks.
    const size_t frameTotal = MAX_STREAM_BUFFER_SIZE - 64;
    size_t delivered = 28;
    ubyte[4096] chunk;
    size_t chunkNo = 0;
    while (delivered < frameTotal)
    {
        const size_t want = frameTotal - delivered;
        const size_t n = want < chunk.length ? want : chunk.length;
        foreach (i; 0 .. n)
            chunk[i] = cast(ubyte)((delivered + i) * 7);
        assert(t.appendRecv(chunk[0 .. n]));
        delivered += n;
        chunkNo++;

        // Capacity/length invariant: the write never extends past the allocation.
        assert(t.recvBufLen <= t.recvBufCapacity);
        assert(t.recvBufCapacity <= MAX_STREAM_BUFFER_SIZE);
        assert(t.recvReadOffset <= t.recvBufLen);
        assert(t.readableBytes == delivered);
    }
    assert(chunkNo > 0);

    // Content integrity (doubles as a canary for any misplaced write).
    const(ubyte)[] r = t.readableSlice;
    assert(r.length == frameTotal);
    foreach (i; 0 .. 28)
        assert(r[i] == cast(ubyte)(i + 101));
    foreach (i; 28 .. frameTotal)
        assert(r[i] == cast(ubyte)(i * 7));

    // W1: an append that would exceed the cap fails and leaves the state untouched.
    const size_t lenBefore = t.recvBufLen;
    const size_t offBefore = t.recvReadOffset;
    const size_t capBefore = t.recvBufCapacity;
    ubyte[128] extra;
    assert(!t.appendRecv(extra[]));
    assert(t.recvBufLen == lenBefore && t.recvReadOffset == offBefore
            && t.recvBufCapacity == capBefore);

    // Exactly filling the remaining space is allowed.
    assert(t.appendRecv(extra[0 .. 64]));
    assert(t.readableBytes == MAX_STREAM_BUFFER_SIZE);
    assert(t.recvBufLen <= t.recvBufCapacity);
}

/// Example:
/// ---
/// H3StreamTracker t;
/// scope (exit)
///     t.cleanup();
/// t.kind = H3StreamKind.request;
/// ubyte[16] fh;
/// size_t fhLen;
/// assert(encodeH3FrameHeader(H3FrameType.headers, 100_000, fh[], fhLen));
/// assert(t.appendRecv(fh[0 .. fhLen]));      // only the header of a 100 000-byte HEADERS frame
/// assert(!t.hasCompleteFrame(200_000));      // within the limit: wait for the payload
/// assert(t.hasCompleteFrame(65_536));        // over the limit: reject without more input
/// ---
// Spec: RFC 9114 Section 4.2.2 "An HTTP/3 implementation MAY impose a limit on the maximum size of
// the message header it will accept on an individual HTTP message." - a HEADERS frame over the
// limit needs no further input to be rejected, so it counts as complete enough to process; one
// within the limit still waits for its payload (L1)
@nogc unittest
{
    H3StreamTracker t;
    scope (exit)
        t.cleanup();
    t.kind = H3StreamKind.request;
    ubyte[16] fh;
    size_t fhLen;
    assert(encodeH3FrameHeader(H3FrameType.headers, 100_000, fh[], fhLen));
    assert(t.appendRecv(fh[0 .. fhLen]));
    assert(!t.hasCompleteFrame(), "without a limit the payload is awaited");
    assert(!t.hasCompleteFrame(200_000), "within the limit the payload is awaited");
    assert(t.hasCompleteFrame(65_536), "over the limit: reject without more input");
    assert(t.hasCompleteFrame(99_999));
    assert(!t.hasCompleteFrame(100_000), "exactly at the limit is allowed");
}

/// Example:
/// ---
/// // ":authority: Example.COM" and "host: example.com" name the same authority.
/// H3HeaderField[5] req = [
///     H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
///     H3HeaderField(":authority", "Example.COM"), H3HeaderField(":path", "/"),
///     H3HeaderField("host", "example.com")
/// ];
/// assert(validateHeaders(req[], false) == H3ErrorCode.noError);
/// req[4] = H3HeaderField("host", "example.org");   // a different host is a mismatch
/// assert(validateHeaders(req[], false) == H3ErrorCode.messageError);
/// ---
// Spec: RFC 9110 Section 4.2.3 "The scheme and host are case-insensitive and normally provided
// in lowercase; all other components are compared in a case-sensitive manner." and RFC 9114
// Section 4.2 "The only exception to this is the TE header field, which MAY be present in an
// HTTP/3 request header; when it is, it MUST NOT contain any value other than "trailers"." (the
// value is a case-insensitive token) - :authority/host and TE must not be compared byte-wise;
// an upper-case field name is malformed (RFC 9114 Section 4.2) (R-39, W21)
@safe @nogc unittest
{
    H3HeaderField[6] req = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "Example.COM"), H3HeaderField(":path", "/"),
        H3HeaderField("host", "example.com"), H3HeaderField("te", "Trailers")
    ];
    assert(validateHeaders(req[], false) == H3ErrorCode.noError);

    // A different host is still a mismatch, and any other TE value is still refused.
    req[4] = H3HeaderField("host", "example.org");
    assert(validateHeaders(req[], false) == H3ErrorCode.messageError);
    req[4] = H3HeaderField("host", "EXAMPLE.com");
    req[5] = H3HeaderField("te", "gzip");
    assert(validateHeaders(req[], false) == H3ErrorCode.messageError);
    req[5] = H3HeaderField("te", "TRAILERS");
    assert(validateHeaders(req[], false) == H3ErrorCode.noError);

    // Upper-case field names are malformed, so "Host" cannot dodge the duplicate/mismatch checks.
    H3HeaderField[5] upper = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":authority", "a.example"), H3HeaderField(":path",
                "/"), H3HeaderField("Host", "b.example")
    ];
    assert(validateHeaders(upper[], false) == H3ErrorCode.messageError);
}
