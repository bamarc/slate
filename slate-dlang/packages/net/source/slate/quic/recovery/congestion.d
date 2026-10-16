module slate.quic.recovery.congestion;

/**
 * QUIC Congestion Control - NewReno (RFC 9002 Section 7).
 *
 * Implements Slow Start, Congestion Avoidance, once-per-RTT recovery reduction,
 * minimum congestion window (kMinimumWindow = 2 * maxDatagramSize), persistent congestion
 * collapse, and space discard in-flight reclamation.
 */

public import slate.quic.wire.varint : VARINT_MAX;

public enum ulong DEFAULT_MAX_DATAGRAM_SIZE = 1200UL;

/**
 * RFC 9002 Section 7 NewReno congestion controller.
 */
public struct CongestionController
{
    ulong maxDatagramSize = DEFAULT_MAX_DATAGRAM_SIZE;
    ulong cwnd = 10 * DEFAULT_MAX_DATAGRAM_SIZE; // 12,000 bytes (RFC 9002 Section 7.2)
    ulong bytesInFlight = 0;
    ulong ssthresh = ulong.max;
    ulong congestionRecoveryStartTime = 0;

    this(ulong maxDatagramSize) @safe pure @nogc nothrow
    {
        this.maxDatagramSize = maxDatagramSize > 0 ? maxDatagramSize : DEFAULT_MAX_DATAGRAM_SIZE;
        this.cwnd = 10 * this.maxDatagramSize;
    }

    /**
     * Checks if a packet sent at timeSentMicros was sent during or before the current recovery period.
     * RFC 9002 Section 7.3.2: Recovery period.
     */
    bool inRecovery(ulong timeSentMicros) const @safe pure @nogc nothrow
    {
        return congestionRecoveryStartTime > 0 && timeSentMicros <= congestionRecoveryStartTime;
    }

    /**
     * Called when an in-flight packet is transmitted.
     */
    void onPacketSent(ulong sentBytes) @safe pure @nogc nothrow
    {
        if (sentBytes > (VARINT_MAX - bytesInFlight))
            bytesInFlight = VARINT_MAX;
        else
            bytesInFlight += sentBytes;
    }

    /**
     * Called when in-flight packets are acknowledged.
     */
    void onPacketAcked(ulong ackedBytes, ulong timeSentMicros) @safe pure @nogc nothrow
    {
        bytesInFlight = bytesInFlight >= ackedBytes ? (bytesInFlight - ackedBytes) : 0;

        // Do not increase cwnd if the packet was sent prior to or during recovery
        if (inRecovery(timeSentMicros))
            return;

        if (cwnd < ssthresh)
        {
            // Slow Start: increase cwnd by bytes acked
            if (ackedBytes > (VARINT_MAX - cwnd))
                cwnd = VARINT_MAX;
            else
                cwnd += ackedBytes;
        }
        else
        {
            // Congestion Avoidance: linear increase (maxDatagramSize * ackedBytes) / cwnd
            if (cwnd > 0)
            {
                ulong delta = 0;
                if (maxDatagramSize > 0 && ackedBytes <= (ulong.max / maxDatagramSize))
                    delta = (maxDatagramSize * ackedBytes) / cwnd;
                else
                    delta = (ackedBytes / cwnd) * maxDatagramSize;

                if (delta > (VARINT_MAX - cwnd))
                    cwnd = VARINT_MAX;
                else
                    cwnd += delta;
            }
        }
    }

    /**
     * Called when packets are declared lost.
     */
    void onPacketsLost(ulong lostBytes, ulong largestLostTimeSentMicros, ulong nowMicros) @safe pure @nogc nothrow
    {
        bytesInFlight = bytesInFlight >= lostBytes ? (bytesInFlight - lostBytes) : 0;
        onCongestionEvent(largestLostTimeSentMicros, nowMicros);
    }

    /**
     * Reduces cwnd at most once per RTT recovery window (RFC 9002 Section 7.3.2).
     */
    void onCongestionEvent(ulong timeSentMicros, ulong nowMicros) @safe pure @nogc nothrow
    {
        if (inRecovery(timeSentMicros))
            return; // Already entered recovery for packets in this flight

        congestionRecoveryStartTime = nowMicros;
        const ulong minWindow = 2 * maxDatagramSize;
        const ulong halfCwnd = cwnd / 2;
        ssthresh = halfCwnd > minWindow ? halfCwnd : minWindow;
        cwnd = ssthresh;
    }

    /**
     * Collapses cwnd upon persistent congestion (RFC 9002 Section 7.6.2).
     */
    void onPersistentCongestion() @safe pure @nogc nothrow
    {
        cwnd = 2 * maxDatagramSize;
        congestionRecoveryStartTime = 0;
    }

    /**
     * Reclaims in-flight bytes when a packet number space is discarded (RFC 9002 Section 6.4).
     */
    void onSpaceDiscarded(ulong unackedBytesInSpace) @safe pure @nogc nothrow
    {
        bytesInFlight = bytesInFlight >= unackedBytesInSpace ? (bytesInFlight - unackedBytesInSpace)
            : 0;
    }
}

/// Example:
// Spec: RFC 9002 Section 7 - NewReno Congestion Control and Single-Reduction Recovery (Scenario T6, covers U1, U3, E5, F5, F6)
@nogc unittest
{
    CongestionController cc;
    assert(cc.maxDatagramSize == 1200);
    assert(cc.cwnd == 12_000);
    assert(cc.bytesInFlight == 0);

    // Slow start: packet sent and acked
    cc.onPacketSent(1200);
    assert(cc.bytesInFlight == 1200);
    cc.onPacketAcked(1200, 10_000);
    assert(cc.bytesInFlight == 0);
    assert(cc.cwnd == 13_200); // 12_000 + 1200

    // Send two packets before recovery: PN 5 (t = 20ms) and PN 6 (t = 25ms)
    cc.onPacketSent(1200);
    cc.onPacketSent(1200);
    assert(cc.bytesInFlight == 2400);

    // Both declared lost at t = 100ms
    // First loss (PN 5 sent at t = 20_000)
    cc.onPacketsLost(1200, 20_000, 100_000);
    assert(cc.bytesInFlight == 1200);
    assert(cc.ssthresh == 6600); // 13_200 / 2
    assert(cc.cwnd == 6600);
    assert(cc.congestionRecoveryStartTime == 100_000);

    // Second loss in same flight (PN 6 sent at t = 25_000 <= 100_000)
    // Must NOT halve cwnd again!
    cc.onPacketsLost(1200, 25_000, 100_000);
    assert(cc.bytesInFlight == 0);
    assert(cc.cwnd == 6600); // Remained at 6600! Single reduction!
    assert(cc.ssthresh == 6600);

    // Packets sent after recovery period (t = 110_000 > 100_000)
    cc.onPacketSent(1200);
    // Since cwnd == ssthresh (6600), Congestion Avoidance governs:
    // delta = (1200 * 1200) / 6600 = 218
    cc.onPacketAcked(1200, 110_000);
    assert(cc.cwnd == 6600 + (1200 * 1200) / 6600);

    // Space discarded: reclaims unacked bytes cleanly
    cc.onPacketSent(2400);
    assert(cc.bytesInFlight == 2400);
    cc.onSpaceDiscarded(2400);
    assert(cc.bytesInFlight == 0);

    // Persistent congestion: collapses to 2 * maxDatagramSize (2400)
    cc.onPersistentCongestion();
    assert(cc.cwnd == 2400);
    assert(cc.congestionRecoveryStartTime == 0);
}
