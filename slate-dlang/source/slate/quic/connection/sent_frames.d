module slate.quic.connection.sent_frames;

/**
 * QUIC Sent Frame Ledger (RFC 9000 Section 13.3).
 *
 * Tracks individual frames packed into transmitted packets, bridging LossDetector's
 * packet-level ACK/loss notifications back to SendBuffer byte offsets and connection flags.
 */

import core.stdc.stdlib : calloc, realloc, free;
import slate.quic.recovery.loss_detection : PacketNumberSpace, NUM_SPACES;

public enum SentFrameKind : ubyte
{
    crypto,
    stream,
    handshakeDone,
    ping,
    maxData,
    maxStreamData
}

public struct SentFrameDesc
{
    SentFrameKind kind;
    ulong streamId;
    ulong offset;
    uint length;
    bool fin;
}

public enum size_t MAX_FRAMES_PER_PACKET = 8;
public enum size_t MAX_TRACKED_PACKETS_PER_SPACE = 1024;

public struct SentPacketRecord
{
    ulong pn;
    bool active;
    ubyte frameCount;
    SentFrameDesc[MAX_FRAMES_PER_PACKET] frames;
}

/**
 * Per-space C-heap ledger of sent packet frames.
 */
public struct SentFrameTracker
{
    @disable this(this);

private:
    SentPacketRecord*[NUM_SPACES] m_records = [null, null, null];
    size_t[NUM_SPACES] m_count = [0, 0, 0];
    size_t[NUM_SPACES] m_capacity = [0, 0, 0];

    void compact(size_t s) @trusted @nogc nothrow
    {
        if (s >= NUM_SPACES || m_records[s] is null || m_count[s] == 0)
            return;

        size_t writeIdx = 0;
        foreach (readIdx; 0 .. m_count[s])
        {
            if (m_records[s][readIdx].active)
            {
                if (writeIdx != readIdx)
                {
                    m_records[s][writeIdx] = m_records[s][readIdx];
                }
                writeIdx++;
            }
        }
        m_count[s] = writeIdx;
    }

public:
    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        foreach (s; 0 .. NUM_SPACES)
        {
            if (m_records[s] !is null)
            {
                free(m_records[s]);
                m_records[s] = null;
            }
            m_count[s] = 0;
            m_capacity[s] = 0;
        }
    }

    void moveFrom(ref SentFrameTracker other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        foreach (s; 0 .. NUM_SPACES)
        {
            this.m_records[s] = other.m_records[s];
            this.m_count[s] = other.m_count[s];
            this.m_capacity[s] = other.m_capacity[s];

            other.m_records[s] = null;
            other.m_count[s] = 0;
            other.m_capacity[s] = 0;
        }
    }

    /**
     * Records a packet and its transmitted frames in the given space.
     */
    bool recordPacket(
        PacketNumberSpace space,
        ulong pn,
        const(SentFrameDesc)[] frames
    ) @trusted @nogc nothrow
    {
        const size_t s = cast(size_t) space;
        if (s >= NUM_SPACES)
            return false;

        // If at capacity, compact inactive records first
        if (m_count[s] >= m_capacity[s])
        {
            compact(s);
        }

        // If still full, expand up to MAX_TRACKED_PACKETS_PER_SPACE
        if (m_count[s] >= m_capacity[s])
        {
            if (m_capacity[s] >= MAX_TRACKED_PACKETS_PER_SPACE)
                return false; // Hard ceiling to prevent memory exhaustion

            size_t newCap = (m_capacity[s] == 0) ? 32 : (m_capacity[s] * 2);
            if (newCap > MAX_TRACKED_PACKETS_PER_SPACE)
                newCap = MAX_TRACKED_PACKETS_PER_SPACE;

            SentPacketRecord* p = cast(SentPacketRecord*) realloc(m_records[s], newCap * SentPacketRecord.sizeof);
            if (p is null)
                return false;

            m_records[s] = p;
            m_capacity[s] = newCap;
        }

        SentPacketRecord* rec = &m_records[s][m_count[s]];
        rec.pn = pn;
        rec.active = true;

        const size_t n = (frames.length < MAX_FRAMES_PER_PACKET) ? frames.length : MAX_FRAMES_PER_PACKET;
        rec.frameCount = cast(ubyte) n;
        foreach (i; 0 .. n)
        {
            rec.frames[i] = frames[i];
        }

        m_count[s]++;
        return true;
    }

    /**
     * Finds and retires an active packet record by packet number.
     * Marks the record inactive and returns the frame descriptors.
     */
    bool takePacket(
        PacketNumberSpace space,
        ulong pn,
        out SentPacketRecord rec
    ) @trusted @nogc nothrow
    {
        rec = SentPacketRecord.init;
        const size_t s = cast(size_t) space;
        if (s >= NUM_SPACES || m_records[s] is null)
            return false;

        // Search backward from newest (most likely to ACK recently sent)
        foreach_reverse (i; 0 .. m_count[s])
        {
            if (m_records[s][i].active && m_records[s][i].pn == pn)
            {
                rec = m_records[s][i];
                m_records[s][i].active = false;
                return true;
            }
        }

        return false;
    }

    /**
     * Discards all tracked packets for a packet number space upon key discard.
     */
    void discardSpace(PacketNumberSpace space) @trusted @nogc nothrow
    {
        const size_t s = cast(size_t) space;
        if (s >= NUM_SPACES)
            return;

        if (m_records[s] !is null)
        {
            free(m_records[s]);
            m_records[s] = null;
        }
        m_count[s] = 0;
        m_capacity[s] = 0;
    }

    /**
     * Returns count of records currently tracked in space.
     */
    size_t count(PacketNumberSpace space) const @safe pure @nogc nothrow
    {
        const size_t s = cast(size_t) space;
        return (s < NUM_SPACES) ? m_count[s] : 0;
    }
}

/// Example:
// Spec: RFC 9000 Section 13.3 - Sent Frame Tracking for ACK and Loss Recovery (covers U1, U2, U3, E2, F5, Scenario T2)
@nogc unittest
{
    SentFrameTracker tracker;

    SentFrameDesc[2] frames1;
    frames1[0] = SentFrameDesc(SentFrameKind.crypto, 0, 0, 100, false);
    frames1[1] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);

    assert(tracker.recordPacket(PacketNumberSpace.initial, 0, frames1[]));
    assert(tracker.count(PacketNumberSpace.initial) == 1);

    SentFrameDesc[1] frames2;
    frames2[0] = SentFrameDesc(SentFrameKind.stream, 4, 0, 250, true);
    assert(tracker.recordPacket(PacketNumberSpace.applicationData, 10, frames2[]));

    // Retrieve initial packet 0
    SentPacketRecord rec;
    assert(tracker.takePacket(PacketNumberSpace.initial, 0, rec));
    assert(rec.pn == 0);
    assert(rec.frameCount == 2);
    assert(rec.frames[0].kind == SentFrameKind.crypto);
    assert(rec.frames[0].length == 100);
    assert(rec.frames[1].kind == SentFrameKind.ping);

    // Second take of same packet must return false (already retired)
    SentPacketRecord rec2;
    assert(!tracker.takePacket(PacketNumberSpace.initial, 0, rec2));

    // Retrieve app data packet 10
    assert(tracker.takePacket(PacketNumberSpace.applicationData, 10, rec));
    assert(rec.pn == 10);
    assert(rec.frameCount == 1);
    assert(rec.frames[0].kind == SentFrameKind.stream);
    assert(rec.frames[0].streamId == 4);
    assert(rec.frames[0].fin);

    // Discard initial space
    tracker.discardSpace(PacketNumberSpace.initial);
    assert(tracker.count(PacketNumberSpace.initial) == 0);
}

/// Example:
// Best practice: Sent Frame Tracker Compaction & Bounded Capacity (covers U2, G4)
@nogc unittest
{
    SentFrameTracker tracker;
    SentFrameDesc[1] dummyFrame;
    dummyFrame[0] = SentFrameDesc(SentFrameKind.ping, 0, 0, 0, false);

    // Record 50 packets in applicationData
    foreach (ulong pn; 0 .. 50)
    {
        assert(tracker.recordPacket(PacketNumberSpace.applicationData, pn, dummyFrame[]));
    }
    assert(tracker.count(PacketNumberSpace.applicationData) == 50);

    // Take odd-numbered packets (retiring 25 packets)
    foreach (ulong pn; 0 .. 50)
    {
        if (pn % 2 != 0)
        {
            SentPacketRecord r;
            assert(tracker.takePacket(PacketNumberSpace.applicationData, pn, r));
        }
    }

    // Adding more packets triggers compaction
    foreach (ulong pn; 50 .. 75)
    {
        assert(tracker.recordPacket(PacketNumberSpace.applicationData, pn, dummyFrame[]));
    }

    // Even packets 0..48 are still retrievable
    foreach (ulong pn; 0 .. 50)
    {
        if (pn % 2 == 0)
        {
            SentPacketRecord r;
            assert(tracker.takePacket(PacketNumberSpace.applicationData, pn, r));
            assert(r.pn == pn);
        }
    }
}
