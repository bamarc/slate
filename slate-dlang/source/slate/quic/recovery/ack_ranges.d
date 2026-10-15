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

    @property ulong largestReceived() const @safe pure @nogc nothrow
    {
        return numRanges > 0 ? ranges[0].largest : 0;
    }

    @property bool hasPendingAck() const @safe pure @nogc nothrow
    {
        return numRanges > 0;
    }

    @property bool empty() const @safe pure @nogc nothrow
    {
        return numRanges == 0;
    }

    /**
     * Inserts a packet number, coalescing adjacent or overlapping intervals.
     * Returns false if the packet number was already recorded (duplicate).
     */
    bool insert(ulong pn, bool isAckEliciting, ulong nowMicros) @safe pure @nogc nothrow
    {
        if (pn > VARINT_MAX)
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
                if (insertIdx < MAX_ACK_RANGES)
                {
                    for (size_t k = MAX_ACK_RANGES - 1; k > insertIdx; k--)
                    {
                        ranges[k] = ranges[k - 1];
                    }
                    ranges[insertIdx] = AckRange(pn, pn);
                }
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

        const ulong rawDelay = nowMicros >= largestReceivedTimeMicros ? (nowMicros - largestReceivedTimeMicros) : 0;
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

        ackElicitingSinceLastAck = 0;
        ackNeeded = false;
        return true;
    }

    void clear() @safe pure @nogc nothrow
    {
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
        other.clear();
    }
}

/// Example:
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
    assert(!set.ackNeeded);
    assert(set.ackElicitingSinceLastAck == 0);
}
