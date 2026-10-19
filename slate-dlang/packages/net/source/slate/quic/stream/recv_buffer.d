module slate.quic.stream.recv_buffer;

/**
 * QUIC Stream and Crypto Receive Buffer (RFC 9000 Section 2.2, Section 4.5).
 *
 * Implements an out-of-order byte-range reassembly buffer backed by C-heap memory,
 * tracking up to 64 disjoint intervals, enforcing strict RFC 9000 final size validation
 * (FINAL_SIZE_ERROR 0x06), and protecting against memory exhaustion via bounded buffer limits.
 */

public import slate.quic.wire.cid : TransportErrorCode;
public import slate.quic.wire.varint : VARINT_MAX;

import core.stdc.stdlib : calloc, realloc, free;
import core.stdc.string : memmove;

/**
 * Disjoint half-open received interval [start, end$(RPAREN).
 */
public struct RecvInterval
{
    ulong start;
    ulong end;
}

public enum size_t MAX_INTERVALS = 64;
public enum size_t DEFAULT_MAX_BUFFER_CAPACITY = 16 * 1024 * 1024; // 16 MB
public enum size_t CRYPTO_BUFFER_CAPACITY = 64 * 1024; // 64 KiB (RFC 9000 Section 19.6, F-06)

/**
 * Retransmission-safe, out-of-order reassembly buffer for QUIC streams and crypto streams.
 */
public struct RecvBuffer
{
    @disable this(this);

    private ubyte* data = null;
    private size_t capacity = 0;
    private ulong bufferStartOffset = 0;
    private ulong m_readOffset = 0;
    private ulong m_highestReceivedOffset = 0;
    private bool m_hasFinalSize = false;
    private bool m_abandoned = false;
    private ulong m_finalSize = 0;
    private size_t m_maxBufferCapacity = DEFAULT_MAX_BUFFER_CAPACITY;

    private RecvInterval[MAX_INTERVALS] intervals;
    private size_t numIntervals = 0;

    this(size_t maxBufferCapacity) @safe pure @nogc nothrow
    {
        if (maxBufferCapacity == 0 || maxBufferCapacity > DEFAULT_MAX_BUFFER_CAPACITY)
            this.m_maxBufferCapacity = DEFAULT_MAX_BUFFER_CAPACITY;
        else
            this.m_maxBufferCapacity = maxBufferCapacity;
    }

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
        m_readOffset = 0;
        m_highestReceivedOffset = 0;
        m_hasFinalSize = false;
        m_abandoned = false;
        m_finalSize = 0;
        numIntervals = 0;
    }

    void moveFrom(ref RecvBuffer other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        this.data = other.data;
        this.capacity = other.capacity;
        this.bufferStartOffset = other.bufferStartOffset;
        this.m_readOffset = other.m_readOffset;
        this.m_highestReceivedOffset = other.m_highestReceivedOffset;
        this.m_hasFinalSize = other.m_hasFinalSize;
        this.m_abandoned = other.m_abandoned;
        this.m_finalSize = other.m_finalSize;
        this.m_maxBufferCapacity = other.m_maxBufferCapacity;
        this.intervals = other.intervals;
        this.numIntervals = other.numIntervals;

        other.data = null;
        other.capacity = 0;
        other.bufferStartOffset = 0;
        other.m_readOffset = 0;
        other.m_highestReceivedOffset = 0;
        other.m_hasFinalSize = false;
        other.m_abandoned = false;
        other.m_finalSize = 0;
        other.numIntervals = 0;
    }

    @property ulong readOffset() const @safe pure @nogc nothrow
    {
        return m_readOffset;
    }

    @property ulong highestReceivedOffset() const @safe pure @nogc nothrow
    {
        return m_highestReceivedOffset;
    }

    @property bool hasFinalSize() const @safe pure @nogc nothrow
    {
        return m_hasFinalSize;
    }

    @property ulong finalSize() const @safe pure @nogc nothrow
    {
        return m_finalSize;
    }

    @property size_t maxBufferCapacity() const @safe pure @nogc nothrow
    {
        return m_maxBufferCapacity;
    }

    @property size_t intervalCount() const @safe pure @nogc nothrow
    {
        return numIntervals;
    }

    /// Whether the receive side was abandoned (`abandon`): arriving bytes are validated and counted
    /// but never stored.
    @property bool abandoned() const @safe pure @nogc nothrow
    {
        return m_abandoned;
    }

    /**
     * Gives up reading this stream: frees every buffered byte and treats all bytes received so far
     * as consumed. Later `ingest` calls still enforce the final size rules (RFC 9000 Section 4.5)
     * but store nothing and advance `readOffset` to the highest received offset, so the stream
     * completes as soon as its final size is known.
     */
    void abandon() @trusted @nogc nothrow
    {
        if (data !is null)
        {
            free(data);
            data = null;
        }
        capacity = 0;
        numIntervals = 0;
        m_abandoned = true;
        m_readOffset = m_highestReceivedOffset;
        bufferStartOffset = m_readOffset;
    }

    /**
     * Ingests a slice of bytes at the given stream offset, with an optional FIN flag.
     * Enforces strict RFC 9000 Section 4.5 final size error rules and buffer limits.
     */
    TransportErrorCode ingest(ulong offset, const(ubyte)[] chunk, bool fin,
            TransportErrorCode limitError = TransportErrorCode.flowControlError) @trusted @nogc nothrow
    {
        // 1. Integer overflow protection
        if (offset > VARINT_MAX || chunk.length > (VARINT_MAX - offset))
            return TransportErrorCode.finalSizeError;

        const ulong endOffset = offset + chunk.length;

        // 2. RFC 9000 Section 4.5: Final size validation
        if (m_hasFinalSize)
        {
            if (endOffset > m_finalSize)
                return TransportErrorCode.finalSizeError;
            if (fin && endOffset != m_finalSize)
                return TransportErrorCode.finalSizeError;
        }

        if (fin)
        {
            if (endOffset < m_highestReceivedOffset)
                return TransportErrorCode.finalSizeError;
        }

        // An abandoned stream stores nothing: only the offsets and the final size are tracked.
        if (m_abandoned)
        {
            if (endOffset > m_highestReceivedOffset)
                m_highestReceivedOffset = endOffset;
            if (fin)
            {
                m_hasFinalSize = true;
                m_finalSize = endOffset;
            }
            m_readOffset = m_highestReceivedOffset;
            return TransportErrorCode.noError;
        }

        // 3. Buffer capacity / flow control limit check
        if (endOffset > m_readOffset && (endOffset - m_readOffset) > m_maxBufferCapacity)
            return limitError;

        // 4. Determine relevant byte range [insertStart, insertEnd)
        const ulong insertStart = offset > m_readOffset ? offset : m_readOffset;
        const ulong insertEnd = endOffset;

        // 5. If there is payload to store beyond readOffset, ensure buffer space and copy
        if (insertStart < insertEnd)
        {
            // CRITICAL: Pre-check whether interval slot exists BEFORE mutating data or capacity
            if (!canInsertInterval(insertStart, insertEnd))
                return limitError;

            if (data is null)
            {
                bufferStartOffset = m_readOffset;
            }

            const size_t needed = cast(size_t)(insertEnd - bufferStartOffset);
            if (needed > capacity)
            {
                size_t newCap = capacity == 0 ? 1024 : capacity;
                while (newCap < needed && newCap < m_maxBufferCapacity)
                {
                    newCap *= 2;
                }
                if (newCap < needed)
                    newCap = needed;

                ubyte* p = cast(ubyte*) realloc(data, newCap);
                if (p is null)
                    return TransportErrorCode.internalError;

                if (newCap > capacity)
                    p[capacity .. newCap] = 0;

                data = p;
                capacity = newCap;
            }

            const size_t sliceOffset = cast(size_t)(insertStart - offset);
            const size_t copyLen = cast(size_t)(insertEnd - insertStart);
            const size_t bufIndex = cast(size_t)(insertStart - bufferStartOffset);

            data[bufIndex .. bufIndex + copyLen] = chunk[sliceOffset .. sliceOffset + copyLen];

            // 6. Merge interval into intervals list
            mergeInterval(insertStart, insertEnd);
        }

        // 7. Update highest received offset and final size
        if (endOffset > m_highestReceivedOffset)
            m_highestReceivedOffset = endOffset;

        if (fin)
        {
            m_hasFinalSize = true;
            m_finalSize = endOffset;
        }

        return TransportErrorCode.noError;
    }

    /**
     * Handles receiving a RESET_STREAM frame with a declared final size.
     * Enforces RFC 9000 Section 4.5 rules.
     */
    TransportErrorCode onReset(ulong declaredFinalSize) @safe pure @nogc nothrow
    {
        if (declaredFinalSize > VARINT_MAX)
            return TransportErrorCode.finalSizeError;

        if (declaredFinalSize < m_highestReceivedOffset)
            return TransportErrorCode.finalSizeError;

        if (m_hasFinalSize && declaredFinalSize != m_finalSize)
            return TransportErrorCode.finalSizeError;

        m_hasFinalSize = true;
        m_finalSize = declaredFinalSize;
        m_highestReceivedOffset = declaredFinalSize;
        if (m_abandoned)
            m_readOffset = declaredFinalSize;
        return TransportErrorCode.noError;
    }

    /**
     * Returns the count of contiguous bytes available to read starting from readOffset.
     */
    size_t readableBytes() const @safe pure @nogc nothrow
    {
        if (numIntervals == 0)
            return 0;

        if (intervals[0].start <= m_readOffset && intervals[0].end > m_readOffset)
        {
            return cast(size_t)(intervals[0].end - m_readOffset);
        }

        return 0;
    }

    /**
     * Reads available contiguous bytes into outBuf, advancing readOffset.
     */
    size_t read(ubyte[] outBuf, out bool finReached) @trusted @nogc nothrow
    {
        const size_t avail = readableBytes();
        if (avail == 0)
        {
            finReached = m_hasFinalSize && (m_readOffset == m_finalSize);
            return 0;
        }

        const size_t toCopy = outBuf.length < avail ? outBuf.length : avail;
        const size_t bufIndex = cast(size_t)(m_readOffset - bufferStartOffset);

        outBuf[0 .. toCopy] = data[bufIndex .. bufIndex + toCopy];
        m_readOffset += toCopy;

        // Update intervals table
        if (m_readOffset >= intervals[0].end)
        {
            // First interval completely consumed
            if (numIntervals > 1)
            {
                intervals[0 .. numIntervals - 1] = intervals[1 .. numIntervals];
            }
            numIntervals--;
        }
        else
        {
            intervals[0].start = m_readOffset;
        }

        // Compact buffer if needed
        compactBuffer();

        finReached = m_hasFinalSize && (m_readOffset == m_finalSize);
        return toCopy;
    }

    private void compactBuffer() @trusted @nogc nothrow
    {
        if (m_readOffset == bufferStartOffset || data is null)
            return;

        if (numIntervals == 0)
        {
            bufferStartOffset = m_readOffset;
            return;
        }

        // If at least 4KB has been consumed, shift unread data left (F-16)
        if (m_readOffset - bufferStartOffset >= 4096)
        {
            foreach (i; 0 .. numIntervals)
            {
                if (intervals[i].end <= m_readOffset)
                    continue;

                const ulong intStart = intervals[i].start > m_readOffset
                    ? intervals[i].start : m_readOffset;
                const size_t srcOff = cast(size_t)(intStart - bufferStartOffset);
                const size_t dstOff = cast(size_t)(intStart - m_readOffset);
                const size_t len = cast(size_t)(intervals[i].end - intStart);
                if (srcOff != dstOff && srcOff + len <= capacity && dstOff + len <= capacity)
                {
                    memmove(data + dstOff, data + srcOff, len);
                }
            }
            bufferStartOffset = m_readOffset;
        }
    }

    private bool canInsertInterval(ulong start, ulong end) const @safe pure @nogc nothrow
    {
        if (start >= end)
            return true;

        foreach (i; 0 .. numIntervals)
        {
            // Touch or overlap: !(intervals[i].end < start || intervals[i].start > end)
            if (!(intervals[i].end < start || intervals[i].start > end))
                return true; // Merges into existing interval without allocating a new slot
        }

        // New disjoint interval:
        if (start == m_readOffset)
        {
            // Head-of-line contiguous chunk is permitted to use the final slot
            return numIntervals < MAX_INTERVALS;
        }
        else
        {
            // Out-of-order chunk must preserve 1 slot for head-of-line data to prevent deadlock
            return numIntervals < (MAX_INTERVALS - 1);
        }
    }

    private bool mergeInterval(ulong start, ulong end) @safe pure @nogc nothrow
    {
        if (start >= end)
            return true;

        // Find overlapping or touching range [first, last]
        ptrdiff_t first = -1;
        ptrdiff_t last = -1;

        foreach (i; 0 .. numIntervals)
        {
            if (!(intervals[i].end < start || intervals[i].start > end))
            {
                if (first == -1)
                    first = cast(ptrdiff_t) i;
                last = cast(ptrdiff_t) i;
            }
        }

        if (first != -1)
        {
            ulong mergedStart = start < intervals[first].start ? start : intervals[first].start;
            ulong mergedEnd = end > intervals[last].end ? end : intervals[last].end;

            intervals[first] = RecvInterval(mergedStart, mergedEnd);

            if (last > first)
            {
                const size_t removed = last - first;
                const size_t remaining = numIntervals - (last + 1);
                foreach (j; 0 .. remaining)
                {
                    intervals[first + 1 + j] = intervals[last + 1 + j];
                }
                numIntervals -= removed;
            }
            return true;
        }

        // No overlap: insert in sorted position
        if (numIntervals >= MAX_INTERVALS)
            return false;

        size_t insertIdx = numIntervals;
        foreach (i; 0 .. numIntervals)
        {
            if (intervals[i].start > end)
            {
                insertIdx = i;
                break;
            }
        }

        for (size_t i = numIntervals; i > insertIdx; i--)
        {
            intervals[i] = intervals[i - 1];
        }
        intervals[insertIdx] = RecvInterval(start, end);
        numIntervals++;
        return true;
    }
}

/// Example:
/// ---
/// // "world" arrives before "hello", then the FIN fixes the final size at 15
/// RecvBuffer buf;
/// buf.ingest(10, cast(const(ubyte)[]) "world", false);
/// buf.ingest(0, cast(const(ubyte)[]) "hello", false);
/// buf.ingest(3, cast(const(ubyte)[]) "lo, my wo", false);   // overlaps and bridges the gap
/// buf.ingest(15, null, true);
/// ubyte[32] outBuf;
/// bool finReached;
/// size_t n = buf.read(outBuf[], finReached);
/// assert(n == 15 && finReached);
/// assert(buf.onReset(14) == TransportErrorCode.finalSizeError);   // below what was received
/// assert(buf.onReset(16) == TransportErrorCode.finalSizeError);   // differs from the FIN
/// assert(buf.onReset(15) == TransportErrorCode.noError);
/// ---
// Spec: RFC 9000 Section 2.2 & Section 4.5 - Out-of-Order Reassembly & Final Size Validation (Scenario T1, covers U1, U2, U3, E1, W1, F1, F4)
@nogc unittest
{
    RecvBuffer buf;

    // Ingest [10..15] ("world")
    const(ubyte)[] chunkWorld = cast(const(ubyte)[]) "world";
    TransportErrorCode err = buf.ingest(10, chunkWorld, false);
    assert(err == TransportErrorCode.noError);
    assert(buf.highestReceivedOffset == 15);
    assert(!buf.hasFinalSize);
    assert(buf.readableBytes() == 0); // Gap at [0..10]

    // Ingest [0..5] ("hello")
    const(ubyte)[] chunkHello = cast(const(ubyte)[]) "hello";
    err = buf.ingest(0, chunkHello, false);
    assert(err == TransportErrorCode.noError);
    assert(buf.highestReceivedOffset == 15);
    assert(buf.readableBytes() == 5); // [0..5] ready

    // Ingest overlapping [3..12] ("lo, my wo", 9 bytes)
    const(ubyte)[] chunkOverlap = cast(const(ubyte)[]) "lo, my wo";
    err = buf.ingest(3, chunkOverlap, false);
    assert(err == TransportErrorCode.noError);
    assert(buf.readableBytes() == 15); // Gap [5..10] bridged, now [0..15] contiguous!

    // Ingest empty chunk at offset 15 with FIN=true
    err = buf.ingest(15, null, true);
    assert(err == TransportErrorCode.noError);
    assert(buf.hasFinalSize);
    assert(buf.finalSize == 15);

    // Read full message: "hello, my world" (15 bytes)
    ubyte[32] outBuf;
    bool finReached = false;
    size_t n = buf.read(outBuf[], finReached);
    assert(n == 15);
    assert(finReached);
    assert(cast(string) outBuf[0 .. 15] == "hello, my world");
    assert(buf.readOffset == 15);

    // Final size error enforcement:
    // 1. Ingesting any byte at offset >= 15 returns finalSizeError (0x06)
    ubyte[1] extra = [0xff];
    assert(buf.ingest(15, extra[], false) == TransportErrorCode.finalSizeError);
    assert(buf.ingest(20, extra[], false) == TransportErrorCode.finalSizeError);

    // 2. Conflicting FIN at offset 14 returns finalSizeError
    assert(buf.ingest(14, null, true) == TransportErrorCode.finalSizeError);

    // 3. FIN smaller than highestReceivedOffset returns finalSizeError
    RecvBuffer buf2;
    assert(buf2.ingest(0, chunkHello[], false) == TransportErrorCode.noError); // highestReceived = 5
    assert(buf2.ingest(4, null, true) == TransportErrorCode.finalSizeError);

    // 4. onReset with invalid final size
    assert(buf.onReset(14) == TransportErrorCode.finalSizeError);
    assert(buf.onReset(16) == TransportErrorCode.finalSizeError);
    assert(buf.onReset(15) == TransportErrorCode.noError);
}

/// Example:
/// ---
/// RecvBuffer buf = RecvBuffer(1024);
/// ubyte[10] smallData;
/// assert(buf.ingest(2000, smallData[], false) == TransportErrorCode.flowControlError);
/// assert(buf.ingest(VARINT_MAX, smallData[], false) == TransportErrorCode.finalSizeError);
/// assert(buf.ingest(VARINT_MAX - 5, smallData[], false) == TransportErrorCode.finalSizeError);
/// ---
// Spec: RFC 9000 Section 4.1 - Buffer Flow Control Bounding and Integer Overflow (covers U1, W1, W2)
@nogc unittest
{
    // Bounded buffer capacity
    RecvBuffer buf = RecvBuffer(1024);
    ubyte[10] smallData;

    // Exceeding maxBufferCapacity
    assert(buf.ingest(2000, smallData[], false) == TransportErrorCode.flowControlError);

    // Integer overflow defense
    assert(buf.ingest(VARINT_MAX, smallData[], false) == TransportErrorCode.finalSizeError);
    assert(buf.ingest(VARINT_MAX - 5, smallData[], false) == TransportErrorCode.finalSizeError);
}

/// Example:
/// ---
/// RecvBuffer b1;
/// const(ubyte)[] msg = cast(const(ubyte)[]) "test data";
/// assert(b1.ingest(0, msg, true) == TransportErrorCode.noError);
/// RecvBuffer b2;
/// b2.moveFrom(b1);                                // b2 now owns the data, b1 is empty
/// assert(b2.highestReceivedOffset == msg.length);
/// ubyte[16] outBuf;
/// bool fin;
/// size_t n = b2.read(outBuf[], fin);
/// assert(n == msg.length && fin);
/// assert(cast(string) outBuf[0 .. n] == "test data");
/// ---
// Spec: RecvBuffer Move Semantics and Memory Cleanup (covers U2, G4)
@nogc unittest
{
    RecvBuffer b1;
    const(ubyte)[] msg = cast(const(ubyte)[]) "test data";
    assert(b1.ingest(0, msg, true) == TransportErrorCode.noError);

    RecvBuffer b2;
    b2.moveFrom(b1);
    assert(b1.readOffset == 0);
    assert(b2.highestReceivedOffset == msg.length);

    ubyte[16] outBuf;
    bool fin = false;
    size_t n = b2.read(outBuf[], fin);
    assert(n == msg.length);
    assert(fin);
    assert(cast(string) outBuf[0 .. n] == "test data");
}

/// Example:
/// ---
/// // a zero-length frame far ahead must not corrupt the data still buffered
/// RecvBuffer buf;
/// ubyte[4100] payload = 0x5a;
/// assert(buf.ingest(0, payload[], false) == TransportErrorCode.noError);
/// assert(buf.ingest(65536, null, false) == TransportErrorCode.noError);
/// ubyte[4096] readBuf;
/// bool fin;
/// assert(buf.read(readBuf[], fin) == 4096);       // compacts the buffer
/// ubyte[16] remainingBuf;
/// size_t rem = buf.read(remainingBuf[], fin);
/// assert(rem == 4);
/// assert(remainingBuf[0 .. 4] == payload[4096 .. 4100]);
/// assert(buf.readOffset == 4100);
/// ---
// Spec: RFC 9000 Section 2.2 - CRITICAL-01 Regression: Zero-Length High-Offset Frame Memmove OOB Defense
@nogc unittest
{
    RecvBuffer buf;

    // 1. Ingest 4100 bytes at offset 0
    ubyte[4100] payload;
    foreach (i; 0 .. 4100)
    {
        payload[i] = cast(ubyte)(i & 0x7f);
    }
    assert(buf.ingest(0, payload[], false) == TransportErrorCode.noError);

    // 2. Ingest 0-length frame at offset 65536
    assert(buf.ingest(65536, null, false) == TransportErrorCode.noError);
    assert(buf.highestReceivedOffset == 65536);

    // 3. Read 4096 bytes: triggers compactBuffer()
    ubyte[4096] readBuf;
    bool fin = false;
    size_t n = buf.read(readBuf[], fin);
    assert(n == 4096);
    assert(!fin);
    assert(buf.readOffset == 4096);

    // 4. Verify remaining 4 bytes are fully intact and zero out-of-bounds access occurred
    ubyte[16] remainingBuf;
    size_t rem = buf.read(remainingBuf[], fin);
    assert(rem == 4);
    assert(remainingBuf[0 .. 4] == payload[4096 .. 4100]);
    assert(buf.readOffset == 4100);
}

/// Example:
/// ---
/// // 63 disjoint chunks fill the interval table; the next gap chunk is refused,
/// // but the chunk at the read offset is still accepted
/// RecvBuffer buf;
/// ubyte[1] oneByte = [0xaa];
/// foreach (i; 1 .. 64)
///     buf.ingest(cast(ulong)(i * 4), oneByte[], false);
/// assert(buf.intervalCount == 63);
/// assert(buf.ingest(500, oneByte[], false) == TransportErrorCode.flowControlError);
/// assert(buf.ingest(0, oneByte[], false) == TransportErrorCode.noError);
/// assert(buf.readableBytes() == 1);
/// ---
// Spec: RFC 9000 Section 2.2 - HIGH-01 Regression: Head-of-Line Contiguous Slot Reservation
@nogc unittest
{
    RecvBuffer buf;

    // Fill intervals with 63 disjoint out-of-order chunks at even offsets > 0
    ubyte[1] oneByte = [0xaa];
    foreach (i; 1 .. 64)
    {
        ulong off = cast(ulong)(i * 4);
        assert(buf.ingest(off, oneByte[], false) == TransportErrorCode.noError);
    }
    assert(buf.intervalCount == 63);

    // Another out-of-order chunk is rejected to preserve the head-of-line slot
    assert(buf.ingest(500, oneByte[], false) == TransportErrorCode.flowControlError);
    assert(buf.intervalCount == 63);

    // Contiguous chunk at m_readOffset (0) is accepted and does not deadlock!
    assert(buf.ingest(0, oneByte[], false) == TransportErrorCode.noError);
    assert(buf.readableBytes() == 1);
}
