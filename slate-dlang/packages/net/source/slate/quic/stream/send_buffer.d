module slate.quic.stream.send_buffer;

/**
 * QUIC Stream Retransmittable Send Buffer (RFC 9000 Section 2.2, Section 13.3).
 *
 * Implements a transmit buffer backed by C-heap memory, tracking unsent stream data,
 * lost ranges (prioritized for retransmission per RFC 9000 Section 13.3), and
 * acknowledged ranges.
 */

public import slate.quic.wire.cid : TransportErrorCode;
public import slate.quic.wire.varint : VARINT_MAX;

import core.stdc.stdlib : calloc, realloc, free;
import core.stdc.string : memmove;

public enum size_t MAX_SEND_RANGES = 64;

/**
 * Contiguous byte slice emitted for transmission.
 */
public struct TransmitChunk
{
    ulong offset;
    const(ubyte)[] data;
    bool fin;
}

/**
 * Disjoint half-open stream range [start, end$(RPAREN).
 */
public struct SendRange
{
    ulong start;
    ulong end;
}

/**
 * Retransmittable stream send buffer.
 */
public struct SendBuffer
{
    @disable this(this);

    private ubyte* data = null;
    private size_t capacity = 0;
    private ulong bufferStartOffset = 0;
    private ulong m_writeOffset = 0;
    private ulong m_unsentOffset = 0;

    private bool m_finQueued = false;
    private bool m_finSent = false;
    private bool m_finAcked = false;
    private bool m_finLost = false;

    private SendRange[MAX_SEND_RANGES] lostRanges;
    private size_t numLostRanges = 0;

    private SendRange[MAX_SEND_RANGES] ackedRanges;
    private size_t numAckedRanges = 0;

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    public void cleanup() @trusted @nogc nothrow
    {
        if (data !is null)
        {
            free(data);
            data = null;
        }
        capacity = 0;
        bufferStartOffset = 0;
        m_writeOffset = 0;
        m_unsentOffset = 0;
        m_finQueued = false;
        m_finSent = false;
        m_finAcked = false;
        m_finLost = false;
        numLostRanges = 0;
        numAckedRanges = 0;
    }

    void moveFrom(ref SendBuffer other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        this.data = other.data;
        this.capacity = other.capacity;
        this.bufferStartOffset = other.bufferStartOffset;
        this.m_writeOffset = other.m_writeOffset;
        this.m_unsentOffset = other.m_unsentOffset;
        this.m_finQueued = other.m_finQueued;
        this.m_finSent = other.m_finSent;
        this.m_finAcked = other.m_finAcked;
        this.m_finLost = other.m_finLost;
        this.lostRanges = other.lostRanges;
        this.numLostRanges = other.numLostRanges;
        this.ackedRanges = other.ackedRanges;
        this.numAckedRanges = other.numAckedRanges;

        other.data = null;
        other.capacity = 0;
        other.bufferStartOffset = 0;
        other.m_writeOffset = 0;
        other.m_unsentOffset = 0;
        other.m_finQueued = false;
        other.m_finSent = false;
        other.m_finAcked = false;
        other.m_finLost = false;
        other.numLostRanges = 0;
        other.numAckedRanges = 0;
    }

    @property ulong writeOffset() const @safe pure @nogc nothrow
    {
        return m_writeOffset;
    }

    @property ulong unsentOffset() const @safe pure @nogc nothrow
    {
        return m_unsentOffset;
    }

    @property bool finQueued() const @safe pure @nogc nothrow
    {
        return m_finQueued;
    }

    @property bool finSent() const @safe pure @nogc nothrow
    {
        return m_finSent;
    }

    @property bool finAcked() const @safe pure @nogc nothrow
    {
        return m_finAcked;
    }

    @property size_t lostRangeCount() const @safe pure @nogc nothrow
    {
        return numLostRanges;
    }

    @property bool hasPendingBytes() const @safe pure @nogc nothrow
    {
        return numLostRanges > 0 || m_unsentOffset < m_writeOffset || (m_finQueued && !m_finSent);
    }

    /**
     * Appends application data to the stream buffer, optionally queueing FIN.
     */
    bool write(const(ubyte)[] chunk, bool fin) @trusted @nogc nothrow
    {
        if (m_finQueued)
            return false; // Cannot write after FIN

        if (m_writeOffset > VARINT_MAX || chunk.length > (VARINT_MAX - m_writeOffset))
            return false;

        const ulong endOffset = m_writeOffset + chunk.length;

        if (chunk.length > 0)
        {
            const size_t needed = cast(size_t)(endOffset - bufferStartOffset);
            if (needed > capacity)
            {
                size_t newCap = capacity == 0 ? 1024 : capacity;
                while (newCap < needed)
                {
                    newCap *= 2;
                }
                ubyte* p = cast(ubyte*) realloc(data, newCap);
                if (p is null)
                    return false;
                data = p;
                capacity = newCap;
            }

            const size_t bufIndex = cast(size_t)(m_writeOffset - bufferStartOffset);
            data[bufIndex .. bufIndex + chunk.length] = chunk[];
            m_writeOffset = endOffset;
        }

        if (fin)
            m_finQueued = true;

        return true;
    }

    /**
     * Polls the next chunk of data to transmit.
     * RFC 9000 Section 13.3: Priority 1 is lost data retransmission; Priority 2 is new unsent data.
     * Also permits emitting a 0-byte FIN chunk even when maxBytes == 0.
     */
    bool pollTransmit(size_t maxBytes, out TransmitChunk chunk) @trusted @nogc nothrow
    {
        // Priority 1: Retransmit lost ranges
        if (numLostRanges > 0)
        {
            ulong lostStart = lostRanges[0].start;
            if (lostStart < bufferStartOffset)
                lostStart = bufferStartOffset;

            const ulong lostEnd = lostRanges[0].end;
            if (lostEnd <= lostStart)
            {
                if (numLostRanges > 1)
                {
                    lostRanges[0 .. numLostRanges - 1] = lostRanges[1 .. numLostRanges];
                }
                numLostRanges--;
                return pollTransmit(maxBytes, chunk);
            }

            const size_t available = cast(size_t)(lostEnd - lostStart);
            const size_t toEmit = maxBytes < available ? maxBytes : available;

            chunk.offset = lostStart;
            const size_t bufIdx = cast(size_t)(lostStart - bufferStartOffset);
            if (toEmit > 0 && data !is null && (bufIdx + toEmit) <= capacity)
            {
                chunk.data = data[bufIdx .. bufIdx + toEmit];
            }
            else
            {
                chunk.data = null;
            }

            if (toEmit == available)
            {
                if (numLostRanges > 1)
                {
                    lostRanges[0 .. numLostRanges - 1] = lostRanges[1 .. numLostRanges];
                }
                numLostRanges--;
            }
            else
            {
                lostRanges[0].start = lostStart + toEmit;
            }

            if (m_finQueued && !m_finAcked && m_finLost && (lostStart + toEmit == m_writeOffset))
            {
                chunk.fin = true;
                m_finLost = false;
            }
            else
            {
                chunk.fin = false;
            }

            return true;
        }

        // Defect 1: Standalone lost FIN with zero remaining lost bytes
        if (numLostRanges == 0 && m_finQueued && !m_finAcked && m_finLost)
        {
            chunk.offset = m_writeOffset;
            chunk.data = null;
            chunk.fin = true;
            m_finLost = false;
            return true;
        }

        // Priority 2: Unsent data or queued unsent FIN
        if (m_unsentOffset < m_writeOffset || (m_finQueued && !m_finSent))
        {
            const size_t available = cast(size_t)(m_writeOffset - m_unsentOffset);
            const size_t toEmit = maxBytes < available ? maxBytes : available;

            chunk.offset = m_unsentOffset;
            const size_t bufIdx = cast(size_t)(m_unsentOffset - bufferStartOffset);
            if (toEmit > 0 && data !is null && (bufIdx + toEmit) <= capacity)
            {
                chunk.data = data[bufIdx .. bufIdx + toEmit];
            }
            else
            {
                chunk.data = null;
            }

            m_unsentOffset += toEmit;

            if (m_unsentOffset == m_writeOffset && m_finQueued)
            {
                chunk.fin = true;
                m_finSent = true;
            }
            else
            {
                chunk.fin = false;
            }

            return true;
        }

        return false;
    }

    /**
     * Records a stream range as lost.
     */
    void onRangeLost(ulong offset, size_t len, bool finLostFlag) @safe pure @nogc nothrow
    {
        if (offset > VARINT_MAX || len > (VARINT_MAX - offset))
            return;

        if (offset < m_unsentOffset)
        {
            const ulong start = offset > bufferStartOffset ? offset : bufferStartOffset;
            const ulong rawEnd = offset + len;
            const ulong end = rawEnd < m_unsentOffset ? rawEnd : m_unsentOffset;
            if (end > start)
            {
                addLostRangeSubtractingAcked(start, end);
            }
        }

        if (finLostFlag && !m_finAcked)
        {
            m_finLost = true;
        }
    }

    /**
     * Records a stream range as acknowledged.
     */
    void onRangeAcked(ulong offset, size_t len, bool finAckedFlag) @trusted @nogc nothrow
    {
        if (offset > VARINT_MAX || len > (VARINT_MAX - offset))
            return;

        const ulong rawEnd = offset + len;
        const ulong end = rawEnd < m_unsentOffset ? rawEnd : m_unsentOffset;
        if (end > offset)
        {
            mergeAckedRange(offset, end);
            subtractFromLostRanges(offset, end);
            compactBufferOnAck();
        }

        if (finAckedFlag)
        {
            m_finAcked = true;
            m_finLost = false;
        }
    }

    /**
     * True if all written stream bytes and FIN have been acknowledged.
     */
    bool isAllAcked() const @safe pure @nogc nothrow
    {
        if (!m_finQueued || !m_finAcked)
            return false;

        if (m_writeOffset == 0)
            return true;

        if (numAckedRanges > 0 && ackedRanges[0].start == 0 && ackedRanges[0].end >= m_writeOffset)
            return true;

        return false;
    }

    private void compactBufferOnAck() @trusted @nogc nothrow
    {
        if (numAckedRanges == 0 || ackedRanges[0].start > bufferStartOffset || data is null)
            return;

        ulong newStart = ackedRanges[0].end < m_writeOffset ? ackedRanges[0].end : m_writeOffset;
        if (numLostRanges > 0 && lostRanges[0].start < newStart)
            newStart = lostRanges[0].start;

        if (newStart > bufferStartOffset)
        {
            const size_t shift = cast(size_t)(newStart - bufferStartOffset);
            const size_t remaining = cast(size_t)(m_writeOffset - newStart);
            if (shift >= 4096 || remaining == 0)
            {
                if (remaining > 0)
                {
                    memmove(data, data + shift, remaining);
                }
                bufferStartOffset = newStart;
            }
        }
    }

    private void addLostRangeSubtractingAcked(ulong start, ulong end) @safe pure @nogc nothrow
    {
        ulong cur = start;
        foreach (i; 0 .. numAckedRanges)
        {
            if (ackedRanges[i].end <= cur)
                continue;
            if (ackedRanges[i].start >= end)
                break;

            if (cur < ackedRanges[i].start)
            {
                mergeLostRange(cur, ackedRanges[i].start);
            }
            if (ackedRanges[i].end > cur)
            {
                cur = ackedRanges[i].end;
            }
            if (cur >= end)
                break;
        }

        if (cur < end)
        {
            mergeLostRange(cur, end);
        }
    }

    private void mergeLostRange(ulong start, ulong end) @safe pure @nogc nothrow
    {
        if (start >= end)
            return;

        ptrdiff_t first = -1;
        ptrdiff_t last = -1;

        foreach (i; 0 .. numLostRanges)
        {
            if (!(lostRanges[i].end < start || lostRanges[i].start > end))
            {
                if (first == -1)
                    first = cast(ptrdiff_t) i;
                last = cast(ptrdiff_t) i;
            }
        }

        if (first != -1)
        {
            ulong mergedStart = start < lostRanges[first].start ? start : lostRanges[first].start;
            ulong mergedEnd = end > lostRanges[last].end ? end : lostRanges[last].end;

            lostRanges[first] = SendRange(mergedStart, mergedEnd);
            if (last > first)
            {
                const size_t removed = last - first;
                const size_t remaining = numLostRanges - (last + 1);
                foreach (j; 0 .. remaining)
                {
                    lostRanges[first + 1 + j] = lostRanges[last + 1 + j];
                }
                numLostRanges -= removed;
            }
            return;
        }

        size_t insertIdx = numLostRanges;
        foreach (i; 0 .. numLostRanges)
        {
            if (lostRanges[i].start > end)
            {
                insertIdx = i;
                break;
            }
        }

        if (numLostRanges >= MAX_SEND_RANGES)
        {
            if (insertIdx < MAX_SEND_RANGES)
            {
                const ulong evictedStart = lostRanges[MAX_SEND_RANGES - 1].start;
                for (size_t i = MAX_SEND_RANGES - 1; i > insertIdx; i--)
                {
                    lostRanges[i] = lostRanges[i - 1];
                }
                lostRanges[insertIdx] = SendRange(start, end);
                if (evictedStart < m_unsentOffset)
                    m_unsentOffset = evictedStart;
            }
            else
            {
                if (start < m_unsentOffset)
                    m_unsentOffset = start;
            }
            return;
        }

        for (size_t i = numLostRanges; i > insertIdx; i--)
        {
            lostRanges[i] = lostRanges[i - 1];
        }
        lostRanges[insertIdx] = SendRange(start, end);
        numLostRanges++;
    }

    private void mergeAckedRange(ulong start, ulong end) @safe pure @nogc nothrow
    {
        if (start >= end)
            return;

        ptrdiff_t first = -1;
        ptrdiff_t last = -1;

        foreach (i; 0 .. numAckedRanges)
        {
            if (!(ackedRanges[i].end < start || ackedRanges[i].start > end))
            {
                if (first == -1)
                    first = cast(ptrdiff_t) i;
                last = cast(ptrdiff_t) i;
            }
        }

        if (first != -1)
        {
            ulong mergedStart = start < ackedRanges[first].start ? start : ackedRanges[first].start;
            ulong mergedEnd = end > ackedRanges[last].end ? end : ackedRanges[last].end;

            ackedRanges[first] = SendRange(mergedStart, mergedEnd);
            if (last > first)
            {
                const size_t removed = last - first;
                const size_t remaining = numAckedRanges - (last + 1);
                foreach (j; 0 .. remaining)
                {
                    ackedRanges[first + 1 + j] = ackedRanges[last + 1 + j];
                }
                numAckedRanges -= removed;
            }
            return;
        }

        size_t insertIdx = numAckedRanges;
        foreach (i; 0 .. numAckedRanges)
        {
            if (ackedRanges[i].start > end)
            {
                insertIdx = i;
                break;
            }
        }

        if (numAckedRanges >= MAX_SEND_RANGES)
        {
            if (insertIdx < MAX_SEND_RANGES)
            {
                for (size_t i = MAX_SEND_RANGES - 1; i > insertIdx; i--)
                {
                    ackedRanges[i] = ackedRanges[i - 1];
                }
                ackedRanges[insertIdx] = SendRange(start, end);
            }
            return;
        }

        for (size_t i = numAckedRanges; i > insertIdx; i--)
        {
            ackedRanges[i] = ackedRanges[i - 1];
        }
        ackedRanges[insertIdx] = SendRange(start, end);
        numAckedRanges++;
    }

    private void subtractFromLostRanges(ulong start, ulong end) @safe pure @nogc nothrow
    {
        if (start >= end || numLostRanges == 0)
            return;

        size_t i = 0;
        while (i < numLostRanges)
        {
            if (end <= lostRanges[i].start || start >= lostRanges[i].end)
            {
                i++;
                continue;
            }

            if (start <= lostRanges[i].start && end >= lostRanges[i].end)
            {
                // Entire lost range acknowledged
                if (numLostRanges > 1)
                {
                    foreach (j; i .. numLostRanges - 1)
                    {
                        lostRanges[j] = lostRanges[j + 1];
                    }
                }
                numLostRanges--;
                continue;
            }

            if (start <= lostRanges[i].start && end < lostRanges[i].end)
            {
                lostRanges[i].start = end;
                i++;
                continue;
            }

            if (start > lostRanges[i].start && end >= lostRanges[i].end)
            {
                lostRanges[i].end = start;
                i++;
                continue;
            }

            // Split in two
            if (numLostRanges < MAX_SEND_RANGES)
            {
                const ulong origEnd = lostRanges[i].end;
                lostRanges[i].end = start;
                for (size_t k = numLostRanges; k > i + 1; k--)
                {
                    lostRanges[k] = lostRanges[k - 1];
                }
                lostRanges[i + 1] = SendRange(end, origEnd);
                numLostRanges++;
                i += 2;
            }
            else
            {
                lostRanges[i].end = start;
                if (end < m_unsentOffset)
                    m_unsentOffset = end;
                i++;
            }
        }
    }
}

/// Example:
// Spec: RFC 9000 Section 13.3 - Retransmission Priority & Full ACK Lifecycle (Scenario T2, covers U1, U2, U3, E2)
@nogc unittest
{
    SendBuffer buf;

    // 1000 bytes written with FIN = true
    ubyte[1000] payload;
    foreach (i; 0 .. 1000)
    {
        payload[i] = cast(ubyte)(i & 0xff);
    }
    assert(buf.write(payload[], true));
    assert(buf.writeOffset == 1000);
    assert(buf.finQueued);

    // pollTransmit chunk 1: [0..400]
    TransmitChunk chunk1;
    assert(buf.pollTransmit(400, chunk1));
    assert(chunk1.offset == 0);
    assert(chunk1.data.length == 400);
    assert(!chunk1.fin);
    assert(buf.unsentOffset == 400);

    // pollTransmit chunk 2: [400..800]
    TransmitChunk chunk2;
    assert(buf.pollTransmit(400, chunk2));
    assert(chunk2.offset == 400);
    assert(chunk2.data.length == 400);
    assert(!chunk2.fin);
    assert(buf.unsentOffset == 800);

    // [0..400] is marked lost via onRangeLost
    buf.onRangeLost(0, 400, false);
    assert(buf.lostRangeCount == 1);

    // Next pollTransmit(400) yields lost range [0..400] BEFORE unsent [800..1000]
    TransmitChunk chunkLost;
    assert(buf.pollTransmit(400, chunkLost));
    assert(chunkLost.offset == 0);
    assert(chunkLost.data.length == 400);
    assert(!chunkLost.fin);
    assert(buf.lostRangeCount == 0);
    assert(buf.unsentOffset == 800); // Unsent offset did not change!

    // Next pollTransmit(400) emits remaining unsent range [800..1000] + FIN
    TransmitChunk chunk3;
    assert(buf.pollTransmit(400, chunk3));
    assert(chunk3.offset == 800);
    assert(chunk3.data.length == 200);
    assert(chunk3.fin);
    assert(buf.unsentOffset == 1000);

    // No more data to transmit
    TransmitChunk chunkEmpty;
    assert(!buf.pollTransmit(400, chunkEmpty));

    // Full ACK Lifecycle: isAllAcked transitions to true only after all ranges + FIN are acknowledged
    assert(!buf.isAllAcked);

    buf.onRangeAcked(0, 400, false);
    assert(!buf.isAllAcked);

    buf.onRangeAcked(400, 400, false);
    assert(!buf.isAllAcked);

    buf.onRangeAcked(800, 200, true);
    assert(buf.isAllAcked);
}

/// Example:
// Spec: RFC 9000 Section 13.3 - CRITICAL-03 Regression: SendBuffer Underflow & Stale Range Lost Handling
@nogc unittest
{
    SendBuffer buf;
    ubyte[200] payload;
    assert(buf.write(payload[], true));

    TransmitChunk c1;
    assert(buf.pollTransmit(100, c1));
    // Acknowledge [0..100], which advances bufferStartOffset to 100 via compaction
    buf.onRangeAcked(0, 100, false);

    // Call onRangeLost with stale offset 0 < bufferStartOffset (100)
    buf.onRangeLost(0, 100, false);
    assert(buf.lostRangeCount == 0); // Stale range ignored, no underflow!

    // Transmit remaining [100..200]
    TransmitChunk c2;
    assert(buf.pollTransmit(100, c2));
    assert(c2.offset == 100);
    assert(c2.data.length == 100);
    assert(c2.fin);
}

/// Example:
// Spec: SendBuffer Move Semantics and Memory Management (covers U2, G4)
@nogc unittest
{
    SendBuffer b1;
    const(ubyte)[] text = cast(const(ubyte)[]) "send buffer data";
    assert(b1.write(text, true));

    SendBuffer b2;
    b2.moveFrom(b1);
    assert(b1.writeOffset == 0);
    assert(b2.writeOffset == text.length);

    TransmitChunk chunk;
    assert(b2.pollTransmit(64, chunk));
    assert(chunk.offset == 0);
    assert(chunk.data == text);
    assert(chunk.fin);
}
