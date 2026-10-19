module slate.quic.recovery.ack_ranges;

/**
 * QUIC Received Packet Number Tracking and ACK Frame Generation (RFC 9000 Section 13.2, RFC 9002 Section 5).
 *
 * Implements a descending AckRangeSet with interval coalescing, ack-eliciting packet
 * counting (RFC 9000 Section 13.2.1 immediate ACK after 2 ack-eliciting packets),
 * and AckFrame construction with encoded ackDelay.
 */

public import slate.quic.wire.frame : AckFrame, AckRange, MAX_ACK_RANGES;
public import slate.quic.wire.varint : VARINT_MAX;

/**
 * Disjoint descending packet number tracker for generating ACK frames.
 */
public struct AckRangeSet
{
    AckRange[MAX_ACK_RANGES] ranges;
    size_t numRanges = 0;
    ulong largestReceivedTimeMicros = 0;
    uint ackElicitingSinceLastAck = 0;
    bool ackNeeded = false;
    /// Packet numbers below this floor are dropped as already seen: raised when a range is
    /// evicted from the full table, so an evicted packet cannot be replayed (RFC 9000 §13.2.3).
    ulong minTrackedPn = 0;

    @property ulong largestReceived() const @safe pure @nogc nothrow
    {
        return numRanges > 0 ? ranges[0].largest : 0;
    }

    @property bool hasPendingAck() const @safe pure @nogc nothrow
    {
        return numRanges > 0 && (ackElicitingSinceLastAck > 0 || ackNeeded);
    }

    @property bool empty() const @safe pure @nogc nothrow
    {
        return numRanges == 0;
    }

    /**
     * Inserts a packet number, coalescing adjacent or overlapping intervals.
     * Returns true only if the packet number is now recorded. Returns false for a duplicate and
     * for a packet number the full range table cannot hold (older than every tracked range):
     * such a packet is not acknowledged, so it also neither counts towards the ack-eliciting
     * total nor sets `ackNeeded`.
     */
    bool insert(ulong pn, bool isAckEliciting, ulong nowMicros) @safe pure @nogc nothrow
    {
        if (pn > VARINT_MAX || isDuplicateOrTooOld(pn))
            return false;

        // 1. Check if pn is already covered
        foreach (i; 0 .. numRanges)
        {
            if (pn >= ranges[i].smallest && pn <= ranges[i].largest)
                return false; // Duplicate
        }

        // 2. Try to expand an existing range
        ptrdiff_t expandedIdx = -1;
        foreach (i; 0 .. numRanges)
        {
            if (pn == ranges[i].largest + 1)
            {
                ranges[i].largest = pn;
                expandedIdx = cast(ptrdiff_t) i;
                break;
            }
            if (pn + 1 == ranges[i].smallest)
            {
                ranges[i].smallest = pn;
                expandedIdx = cast(ptrdiff_t) i;
                break;
            }
        }

        if (expandedIdx != -1)
        {
            // Range expanded; check if it now touches neighbor ranges
            const size_t idx = cast(size_t) expandedIdx;
            // Can it merge with predecessor (idx - 1)?
            if (idx > 0 && ranges[idx].largest + 1 == ranges[idx - 1].smallest)
            {
                ranges[idx - 1].smallest = ranges[idx].smallest;
                for (size_t k = idx; k + 1 < numRanges; k++)
                {
                    ranges[k] = ranges[k + 1];
                }
                numRanges--;
            }
            // Can it merge with successor (idx + 1)?
        else if (idx + 1 < numRanges && ranges[idx].smallest == ranges[idx + 1].largest + 1)
            {
                ranges[idx].smallest = ranges[idx + 1].smallest;
                for (size_t k = idx + 1; k + 1 < numRanges; k++)
                {
                    ranges[k] = ranges[k + 1];
                }
                numRanges--;
            }
        }
        else
        {
            // 3. Insert new single-packet range [pn, pn] in descending order of largest
            size_t insertIdx = numRanges;
            foreach (i; 0 .. numRanges)
            {
                if (pn > ranges[i].largest)
                {
                    insertIdx = i;
                    break;
                }
            }

            if (numRanges < MAX_ACK_RANGES)
            {
                for (size_t k = numRanges; k > insertIdx; k--)
                {
                    ranges[k] = ranges[k - 1];
                }
                ranges[insertIdx] = AckRange(pn, pn);
                numRanges++;
            }
            else
            {
                // Range set is full: only keep if pn > smallest in table
                if (insertIdx >= MAX_ACK_RANGES)
                    return false; // evicted on arrival: not recorded
                // The evicted range (the oldest) is forgotten: raise the floor above it.
                const ulong evictedEnd = ranges[MAX_ACK_RANGES - 1].largest + 1;
                if (evictedEnd > minTrackedPn)
                    minTrackedPn = evictedEnd;
                for (size_t k = MAX_ACK_RANGES - 1; k > insertIdx; k--)
                {
                    ranges[k] = ranges[k - 1];
                }
                ranges[insertIdx] = AckRange(pn, pn);
            }
        }

        // 4. Update largest packet received time
        if (numRanges > 0 && pn == ranges[0].largest)
        {
            largestReceivedTimeMicros = nowMicros;
        }

        // 5. Update ack-eliciting packet count (RFC 9000 Section 13.2.1)
        if (isAckEliciting)
        {
            ackElicitingSinceLastAck++;
            if (ackElicitingSinceLastAck >= 2)
                ackNeeded = true;
        }

        return true;
    }

    /**
     * Builds an AckFrame from the current ranges, encoding the ackDelay.
     */
    bool buildAckFrame(ulong nowMicros, ubyte ackDelayExponent, out AckFrame frame) @safe pure @nogc nothrow
    {
        if (numRanges == 0)
            return false;

        const ulong rawDelay = nowMicros >= largestReceivedTimeMicros ? (
                nowMicros - largestReceivedTimeMicros) : 0;
        frame.ackDelay = ackDelayExponent >= 62 ? 0 : (rawDelay >> ackDelayExponent);
        frame.numRanges = numRanges;
        foreach (i; 0 .. numRanges)
        {
            frame.ranges[i] = ranges[i];
        }
        frame.hasEcn = false;
        frame.ect0 = 0;
        frame.ect1 = 0;
        frame.ecnCe = 0;

        return true;
    }

    /**
     * Called when an ACK frame is successfully packed and transmitted.
     * Clears pending ACK state (RFC 9000 Section 13.2.1).
     */
    void onAckSent() @safe pure @nogc nothrow
    {
        ackElicitingSinceLastAck = 0;
        ackNeeded = false;
    }

    /**
     * Checks if a packet number is already recorded in the ACK ranges.
     */
    bool contains(ulong pn) const @safe pure @nogc nothrow
    {
        if (pn > VARINT_MAX)
            return false;

        foreach (i; 0 .. numRanges)
        {
            if (pn >= ranges[i].smallest && pn <= ranges[i].largest)
                return true;
        }
        return false;
    }

    /**
     * True when a packet with this number must be dropped before any of its frames are
     * processed: it is recorded already, lies below the floor raised by evictions, or is older
     * than every range of a full table and so could not be recorded (RFC 9000 §13.2.3: "a
     * minimum packet number below which all packets are immediately dropped").
     */
    bool isDuplicateOrTooOld(ulong pn) const @safe pure @nogc nothrow
    {
        if (pn < minTrackedPn || contains(pn))
            return true;
        return numRanges == MAX_ACK_RANGES && pn + 1 < ranges[MAX_ACK_RANGES - 1].smallest;
    }

    void clear() @safe pure @nogc nothrow
    {
        minTrackedPn = 0;
        numRanges = 0;
        largestReceivedTimeMicros = 0;
        ackElicitingSinceLastAck = 0;
        ackNeeded = false;
    }

    void moveFrom(ref AckRangeSet other) @safe pure @nogc nothrow
    {
        this.ranges = other.ranges;
        this.numRanges = other.numRanges;
        this.largestReceivedTimeMicros = other.largestReceivedTimeMicros;
        this.ackElicitingSinceLastAck = other.ackElicitingSinceLastAck;
        this.ackNeeded = other.ackNeeded;
        this.minTrackedPn = other.minTrackedPn;
        other.clear();
    }
}

/// Example:
/// ---
/// AckRangeSet set;
/// assert(set.insert(0, true, 10_000));
/// assert(set.insert(2, true, 11_000));          // two ack-eliciting packets: an ACK is due
/// foreach (pn; [5, 6, 7])
///     assert(set.insert(pn, false, 12_000));
/// assert(set.insert(1, false, 15_000));         // bridges [0] and [2] into [0 .. 2]
/// assert(!set.insert(5, false, 15_500));        // duplicates are refused
///
/// AckFrame frame;
/// assert(set.buildAckFrame(16_000, 3, frame));
/// assert(frame.numRanges == 2 && frame.ranges[0].largest == 7 && frame.ranges[1].largest == 2);
///
/// set.onAckSent();
/// assert(!set.ackNeeded && set.ackElicitingSinceLastAck == 0 && !set.hasPendingAck);
/// ---
// Spec: RFC 9000 Section 13.2 & RFC 9002 Section 5 - AckRangeSet Out-of-Order Coalescing & ACK Frame Building (Scenario T4, covers U1, U3, E4)
@nogc unittest
{
    AckRangeSet set;

    // Packets [0, 2, 5, 6, 7, 1] arrive out of order
    assert(set.insert(0, true, 10_000));
    assert(set.insert(2, true, 11_000));
    assert(set.ackNeeded); // 2 ack-eliciting packets arrived

    assert(set.insert(5, false, 12_000));
    assert(set.insert(6, false, 13_000));
    assert(set.insert(7, true, 14_000)); // largestReceived = 7 at t = 14_000
    assert(set.largestReceived == 7);

    // Now insert 1: bridges [0..0] and [2..2] into [0..2]
    assert(set.insert(1, false, 15_000));

    // Duplicate detection
    assert(!set.insert(5, false, 15_500));
    assert(!set.insert(1, false, 15_500));

    // Verify contains
    assert(set.contains(0));
    assert(set.contains(1));
    assert(set.contains(2));
    assert(set.contains(5));
    assert(set.contains(6));
    assert(set.contains(7));
    assert(!set.contains(3));
    assert(!set.contains(4));
    assert(!set.contains(8));

    // Build ACK frame at t = 16_000 with ackDelayExponent = 3
    // rawDelay = 16_000 - 14_000 = 2_000 microseconds
    // encoded ackDelay = 2000 >> 3 = 250
    AckFrame frame;
    assert(set.buildAckFrame(16_000, 3, frame));

    assert(frame.numRanges == 2);
    // Descending order: [5..7] and [0..2]
    assert(frame.ranges[0].smallest == 5);
    assert(frame.ranges[0].largest == 7);
    assert(frame.ranges[1].smallest == 0);
    assert(frame.ranges[1].largest == 2);
    assert(frame.largestAcknowledged == 7);
    assert(frame.ackDelay == 250);

    // buildAckFrame does not clear ackNeeded until onAckSent is called
    assert(set.ackNeeded);
    assert(set.ackElicitingSinceLastAck > 0);
    assert(set.hasPendingAck);

    set.onAckSent();
    assert(!set.ackNeeded);
    assert(set.ackElicitingSinceLastAck == 0);
    assert(!set.hasPendingAck);
}

/// Example:
/// ---
/// AckRangeSet set;
/// // MAX_ACK_RANGES single-packet ranges, two numbers apart: 2000, 1998, ...
/// foreach (i; 0 .. MAX_ACK_RANGES)
///     assert(set.insert(1000 + 2 * (MAX_ACK_RANGES - i), false, 10));
/// const ulong lowest = set.ranges[MAX_ACK_RANGES - 1].smallest;
///
/// // A packet older than every tracked range cannot be stored, so it is not reported as recorded.
/// assert(!set.insert(lowest - 10, true, 20));
/// assert(!set.contains(lowest - 10) && !set.ackNeeded);
/// ---
// Spec: RFC 9000 Section 13.2.3 "A receiver limits the number of ACK Ranges (Section 19.3.1) it
// remembers and sends in ACK frames, both to limit the size of ACK frames and to avoid resource
// exhaustion." (bounded state) and RFC 9002 Section 2 - a packet number that is not tracked cannot be
// acknowledged, so insert() must not report it as recorded nor schedule an ACK for it (R-44, W25)
@nogc unittest
{
    AckRangeSet set;
    // MAX_ACK_RANGES ranges, each a single packet two numbers apart: 2000, 1998, ...
    foreach (i; 0 .. MAX_ACK_RANGES)
        assert(set.insert(1000 + 2 * (MAX_ACK_RANGES - i), false, 10));
    assert(set.numRanges == MAX_ACK_RANGES);
    const ulong lowest = set.ranges[MAX_ACK_RANGES - 1].smallest;

    // Older than every tracked range: refused, state untouched, nothing scheduled.
    assert(!set.insert(lowest - 10, true, 20));
    assert(!set.contains(lowest - 10));
    assert(set.numRanges == MAX_ACK_RANGES && set.ranges[MAX_ACK_RANGES - 1].smallest == lowest);
    assert(!set.ackNeeded && set.ackElicitingSinceLastAck == 0);

    // A newer packet is stored and pushes the oldest range out.
    assert(set.insert(lowest + 2 * MAX_ACK_RANGES + 10, true, 30));
    assert(set.contains(lowest + 2 * MAX_ACK_RANGES + 10));
    assert(!set.contains(lowest));

    // A packet adjacent to a tracked range merges and is stored even when the table is full.
    const ulong top = set.ranges[0].largest;
    assert(set.insert(top + 1, false, 40) && set.contains(top + 1));
}

/// Example:
/// ---
/// AckRangeSet set;
/// // Single-packet ranges two apart fill the table: 2, 4, ..., 2 * MAX_ACK_RANGES.
/// foreach (i; 1 .. MAX_ACK_RANGES + 1)
///     assert(set.insert(2 * i, true, 10));
///
/// // One more gap evicts the oldest range [2, 2] and raises the duplicate floor above it.
/// assert(set.insert(2 * MAX_ACK_RANGES + 2, true, 20));
/// assert(!set.contains(2) && set.minTrackedPn == 3);
/// assert(set.isDuplicateOrTooOld(2));   // the evicted packet is dropped, not reprocessed
/// assert(!set.insert(2, true, 30));     // and is not recorded again
/// ---
// Spec: RFC 9000 Section 13.2.3 "The data required for detecting duplicates can be limited by
// maintaining a minimum packet number below which all packets are immediately dropped." and
// Section 13.2 "A receiver MUST discard a newly unprotected packet unless it is certain that it
// has not processed another packet with the same packet number from the same packet number
// space." - a range evicted from the full table must raise the floor (W27)
@nogc unittest
{
    AckRangeSet set;
    // Single-packet ranges two apart: 2, 4, ..., 2 * MAX_ACK_RANGES.
    foreach (i; 1 .. MAX_ACK_RANGES + 1)
        assert(set.insert(2 * i, true, 10));
    assert(set.numRanges == MAX_ACK_RANGES && set.minTrackedPn == 0);
    assert(!set.isDuplicateOrTooOld(1), "an unseen gap packet is not a duplicate while tracked");

    // One more gap pushes the oldest range [2,2] out of the table.
    const ulong newest = 2 * MAX_ACK_RANGES + 2;
    assert(set.insert(newest, true, 20));
    assert(set.numRanges == MAX_ACK_RANGES);
    assert(!set.contains(2), "range [2,2] was evicted");
    assert(set.minTrackedPn == 3, "floor = evicted largest + 1");

    // Replay of the evicted packet, and anything older, is dropped.
    assert(set.isDuplicateOrTooOld(2));
    assert(set.isDuplicateOrTooOld(1));
    assert(!set.insert(2, true, 30));
    assert(!set.insert(1, true, 30));
    // A packet above the floor that was never seen is still new.
    assert(!set.isDuplicateOrTooOld(5));
    assert(set.insert(5, false, 40));

    // clear() forgets the floor with the ranges (a discarded packet number space).
    set.clear();
    assert(set.minTrackedPn == 0 && !set.isDuplicateOrTooOld(2));
}
