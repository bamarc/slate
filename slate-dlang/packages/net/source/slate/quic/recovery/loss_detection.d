module slate.quic.recovery.loss_detection;

/**
 * QUIC Loss Detection and Probe Timeout (PTO) (RFC 9002 Section 6).
 *
 * Implements packet threshold loss detection (kPacketThreshold = 3),
 * time threshold loss detection (kTimeThreshold = 9/8 * RTT),
 * Probe Timeout (PTO) timer computation with exponential backoff (1 << ptoCount),
 * and packet number space discard per RFC 9002 Section 6.4.
 */

public import slate.quic.wire.frame : AckFrame, AckRange, MAX_ACK_RANGES;
public import slate.quic.wire.cid : TransportErrorCode;
public import slate.quic.wire.varint : VARINT_MAX;
public import slate.quic.recovery.rtt;
public import slate.quic.recovery.congestion;

import core.stdc.stdlib : calloc, realloc, free;

public enum ulong PACKET_THRESHOLD = 3UL; // kPacketThreshold = 3 (RFC 9002 Section 6.1.1)
public enum size_t NUM_SPACES = 3;

/**
 * QUIC packet number spaces (RFC 9002 Section 2).
 */
public enum PacketNumberSpace : ubyte
{
    initial = 0,
    handshake = 1,
    applicationData = 2
}

/**
 * Metadata recorded for each transmitted packet.
 */
public struct SentPacketInfo
{
    ulong pn = 0;
    ulong timeSentMicros = 0;
    uint sentBytes = 0;
    bool isAckEliciting = false;
    bool inFlight = false;
    bool acked = false;
    bool lost = false;
    PacketNumberSpace space = PacketNumberSpace.initial;
}

/**
 * Sans-I/O loss detector and congestion manager.
 */
public struct LossDetector
{
    @disable this(this);

    private SentPacketInfo*[NUM_SPACES] sentPackets = [null, null, null];
    private size_t[NUM_SPACES] sentCount = [0, 0, 0];
    private size_t[NUM_SPACES] sentCapacity = [0, 0, 0];

    ulong[NUM_SPACES] largestSentPn = [0, 0, 0];
    bool[NUM_SPACES] hasSentPn = [false, false, false];
    ulong[NUM_SPACES] largestAckedPn = [0, 0, 0];
    bool[NUM_SPACES] hasAckedPn = [false, false, false];
    ulong[NUM_SPACES] lossTimeMicros = [0, 0, 0];
    ulong[NUM_SPACES] lastAckElicitingTimeMicros = [0, 0, 0];
    uint ptoCount = 0;

    RttEstimator rtt;
    CongestionController cc;

    ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        foreach (s; 0 .. NUM_SPACES)
        {
            if (sentPackets[s]!is null)
            {
                free(sentPackets[s]);
                sentPackets[s] = null;
            }
            sentCount[s] = 0;
            sentCapacity[s] = 0;
            largestSentPn[s] = 0;
            hasSentPn[s] = false;
            largestAckedPn[s] = 0;
            hasAckedPn[s] = false;
            lossTimeMicros[s] = 0;
            lastAckElicitingTimeMicros[s] = 0;
        }
        ptoCount = 0;
    }

    void moveFrom(ref LossDetector other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        foreach (s; 0 .. NUM_SPACES)
        {
            this.sentPackets[s] = other.sentPackets[s];
            this.sentCount[s] = other.sentCount[s];
            this.sentCapacity[s] = other.sentCapacity[s];
            this.largestSentPn[s] = other.largestSentPn[s];
            this.hasSentPn[s] = other.hasSentPn[s];
            this.largestAckedPn[s] = other.largestAckedPn[s];
            this.hasAckedPn[s] = other.hasAckedPn[s];
            this.lossTimeMicros[s] = other.lossTimeMicros[s];
            this.lastAckElicitingTimeMicros[s] = other.lastAckElicitingTimeMicros[s];

            other.sentPackets[s] = null;
            other.sentCount[s] = 0;
            other.sentCapacity[s] = 0;
            other.largestSentPn[s] = 0;
            other.hasSentPn[s] = false;
            other.largestAckedPn[s] = 0;
            other.hasAckedPn[s] = false;
            other.lossTimeMicros[s] = 0;
            other.lastAckElicitingTimeMicros[s] = 0;
        }

        this.ptoCount = other.ptoCount;
        this.rtt = other.rtt;
        this.cc = other.cc;
    }

    /**
     * Records a transmitted packet.
     */
    void onPacketSent(PacketNumberSpace space, ulong pn, uint sentBytes,
            bool isAckEliciting, bool inFlight, ulong nowMicros) @trusted @nogc nothrow
    {
        const size_t s = cast(size_t) space;
        if (s >= NUM_SPACES)
            return;

        if (sentCount[s] >= sentCapacity[s])
        {
            size_t newCap = sentCapacity[s] == 0 ? 32 : sentCapacity[s] * 2;
            SentPacketInfo* p = cast(SentPacketInfo*) realloc(sentPackets[s],
                    newCap * SentPacketInfo.sizeof);
            if (p is null)
                return;
            sentPackets[s] = p;
            sentCapacity[s] = newCap;
        }

        sentPackets[s][sentCount[s]] = SentPacketInfo(pn, nowMicros, sentBytes,
                isAckEliciting, inFlight, false, false, space);
        sentCount[s]++;

        if (!hasSentPn[s] || pn > largestSentPn[s])
        {
            largestSentPn[s] = pn;
            hasSentPn[s] = true;
        }

        if (inFlight)
        {
            cc.onPacketSent(sentBytes);
        }

        if (isAckEliciting)
        {
            lastAckElicitingTimeMicros[s] = nowMicros;
        }
    }

    /**
     * Processes an incoming ACK frame, detecting newly acknowledged and newly lost packets.
     * Enforces RFC 9000 Section 13.2 and Section 19.3.1 error validation.
     */
    TransportErrorCode onAckReceived(PacketNumberSpace space,
            ref const AckFrame ack, ubyte ackDelayExponent, ulong maxAckDelayMicros,
            bool handshakeConfirmed, ulong nowMicros, scope SentPacketInfo[] newlyAckedOut,
            out size_t ackedCount, scope SentPacketInfo[] newlyLostOut, out size_t lostCount) @trusted @nogc nothrow
    {
        const size_t s = cast(size_t) space;
        if (s >= NUM_SPACES)
            return TransportErrorCode.internalError;

        if (ack.numRanges == 0 || ack.numRanges > MAX_ACK_RANGES)
            return TransportErrorCode.frameEncodingError;

        foreach (r; 0 .. ack.numRanges)
        {
            if (ack.ranges[r].smallest > ack.ranges[r].largest)
                return TransportErrorCode.frameEncodingError;
            if (r > 0 && ack.ranges[r - 1].smallest <= ack.ranges[r].largest + 1)
                return TransportErrorCode.frameEncodingError;
        }

        // RFC 9000 Section 13.2 & Section 19.3.1: An ACK frame acknowledging an unsent packet is a PROTOCOL_VIOLATION
        if (!hasSentPn[s] || ack.largestAcknowledged > largestSentPn[s])
            return TransportErrorCode.protocolViolation;

        ackedCount = 0;
        lostCount = 0;

        ulong largestAckedSentTime = 0;
        bool largestAckedNewlyAcked = false;
        bool anyAckElicitingNewlyAcked = false;

        // 1. Mark newly acknowledged packets
        foreach (i; 0 .. sentCount[s])
        {
            SentPacketInfo* p = &sentPackets[s][i];
            if (p.acked || p.lost)
                continue;

            // Check if p.pn is in any ACK range
            bool isAcked = false;
            foreach (r; 0 .. ack.numRanges)
            {
                if (p.pn >= ack.ranges[r].smallest && p.pn <= ack.ranges[r].largest)
                {
                    isAcked = true;
                    break;
                }
            }

            if (isAcked)
            {
                p.acked = true;
                if (p.isAckEliciting)
                    anyAckElicitingNewlyAcked = true;

                if (p.pn == ack.largestAcknowledged)
                {
                    largestAckedSentTime = p.timeSentMicros;
                    largestAckedNewlyAcked = true;
                }

                if (p.inFlight)
                {
                    cc.onPacketAcked(p.sentBytes, p.timeSentMicros);
                    p.inFlight = false;
                }

                if (ackedCount < newlyAckedOut.length)
                {
                    newlyAckedOut[ackedCount] = *p;
                    ackedCount++;
                }
            }
        }

        // 2. Update largest acknowledged packet number
        if (!hasAckedPn[s] || ack.largestAcknowledged > largestAckedPn[s])
        {
            largestAckedPn[s] = ack.largestAcknowledged;
            hasAckedPn[s] = true;
        }

        // 3. RTT Estimator update (RFC 9002 Section 5.1 & Section 5.3)
        // Only update if largest is newly acked AND at least one newly acked packet was ack-eliciting
        if (largestAckedNewlyAcked && anyAckElicitingNewlyAcked)
        {
            const ulong rttSample = nowMicros >= largestAckedSentTime ? (
                    nowMicros - largestAckedSentTime) : 0;
            ulong ackDelayMicros = 0;
            if (ackDelayExponent >= 62 || ack.ackDelay > (ulong.max >> ackDelayExponent))
                ackDelayMicros = ulong.max;
            else
                ackDelayMicros = ack.ackDelay << ackDelayExponent;

            rtt.update(rttSample, ackDelayMicros, maxAckDelayMicros, handshakeConfirmed);
        }

        // 4. Reset PTO counter on new ACK that acknowledges an ack-eliciting packet (RFC 9002 Section 6.2.1)
        if (anyAckElicitingNewlyAcked)
            ptoCount = 0;

        // 5. Detect lost packets
        ulong totalLostBytes = 0;
        ulong largestLostTime = 0;
        ulong earliestLostTime = 0;
        detectLostPackets(space, nowMicros, newlyLostOut, lostCount,
                totalLostBytes, largestLostTime, earliestLostTime);

        // 6. Notify congestion controller of lost bytes and check persistent congestion (RFC 9002 Section 7.6)
        if (totalLostBytes > 0)
        {
            cc.onPacketsLost(totalLostBytes, largestLostTime, nowMicros);

            if (space == PacketNumberSpace.applicationData && rtt.hasSample)
            {
                const ulong maxRttVar = 4 * rtt.rttVar > GRANULARITY_MICROS
                    ? 4 * rtt.rttVar : GRANULARITY_MICROS;
                const ulong ptoBase = rtt.smoothedRtt + maxRttVar + maxAckDelayMicros;
                const ulong persistentCongestionDuration = ptoBase * 3;
                if (persistentCongestionDuration > 0 && largestLostTime >= earliestLostTime
                        && (largestLostTime - earliestLostTime) >= persistentCongestionDuration)
                {
                    cc.onPersistentCongestion();
                }
            }
        }

        // 7. Compact acknowledged/lost packets prefix
        compactSentPackets(space);

        return TransportErrorCode.noError;
    }

    /**
     * Declares packets lost via packet threshold or time threshold (RFC 9002 Section 6.1).
     */
    void detectLostPackets(PacketNumberSpace space, ulong nowMicros,
            scope SentPacketInfo[] newlyLostOut, ref size_t lostCount,
            out ulong totalLostBytes, out ulong largestLostTime, out ulong earliestLostTime) @trusted @nogc nothrow
    {
        totalLostBytes = 0;
        largestLostTime = 0;
        earliestLostTime = 0;

        const size_t s = cast(size_t) space;
        if (s >= NUM_SPACES || !hasAckedPn[s])
            return;

        const ulong largestAcked = largestAckedPn[s];
        const ulong maxRtt = rtt.latestRtt > rtt.smoothedRtt ? rtt.latestRtt : rtt.smoothedRtt;
        ulong lossDelay = (9 * maxRtt) / 8;
        if (lossDelay < GRANULARITY_MICROS)
            lossDelay = GRANULARITY_MICROS;

        lossTimeMicros[s] = 0;

        foreach (i; 0 .. sentCount[s])
        {
            SentPacketInfo* p = &sentPackets[s][i];
            if (p.acked || p.lost || !p.inFlight)
                continue;

            if (p.pn < largestAcked)
            {
                // RFC 9002 Section 6.1.1: Packet threshold (kPacketThreshold = 3)
                const bool packetThresholdLost = (largestAcked >= p.pn + PACKET_THRESHOLD);
                // RFC 9002 Section 6.1.2: Time threshold (kTimeThreshold = 9/8 * RTT)
                const bool timeThresholdLost = (nowMicros >= p.timeSentMicros + lossDelay);

                if (packetThresholdLost || timeThresholdLost)
                {
                    p.lost = true;
                    p.inFlight = false;
                    totalLostBytes += p.sentBytes;
                    if (earliestLostTime == 0 || p.timeSentMicros < earliestLostTime)
                        earliestLostTime = p.timeSentMicros;
                    if (p.timeSentMicros > largestLostTime)
                        largestLostTime = p.timeSentMicros;

                    if (lostCount < newlyLostOut.length)
                    {
                        newlyLostOut[lostCount] = *p;
                        lostCount++;
                    }
                }
                else
                {
                    // Arm loss timer at timeSent + lossDelay
                    const ulong pLossTime = p.timeSentMicros + lossDelay;
                    if (lossTimeMicros[s] == 0 || pLossTime < lossTimeMicros[s])
                    {
                        lossTimeMicros[s] = pLossTime;
                    }
                }
            }
        }
    }

    /**
     * Computes the next deadline (in monotonic microseconds) for the recovery timer.
     * Returns 0 if no timer is armed.
     */
    ulong nextTimeoutMicros(ulong maxAckDelayMicros, bool handshakeConfirmed) const @trusted pure @nogc nothrow
    {
        // 1. Loss timer has highest priority (RFC 9002 Section 6.2.1)
        ulong earliestLossTime = 0;
        foreach (s; 0 .. NUM_SPACES)
        {
            if (lossTimeMicros[s] > 0)
            {
                if (earliestLossTime == 0 || lossTimeMicros[s] < earliestLossTime)
                    earliestLossTime = lossTimeMicros[s];
            }
        }
        if (earliestLossTime > 0)
            return earliestLossTime;

        // 2. PTO timer for spaces with in-flight ack-eliciting packets
        ulong earliestPto = 0;
        foreach (s; 0 .. NUM_SPACES)
        {
            bool hasInFlightAckEliciting = false;
            foreach (i; 0 .. sentCount[s])
            {
                if (sentPackets[s][i].inFlight
                        && sentPackets[s][i].isAckEliciting
                        && !sentPackets[s][i].acked && !sentPackets[s][i].lost)
                {
                    hasInFlightAckEliciting = true;
                    break;
                }
            }

            if (hasInFlightAckEliciting)
            {
                const bool includeMaxAck = (s == PacketNumberSpace.applicationData
                        && handshakeConfirmed);
                const ulong ptoBase = rtt.ptoBaseMicros(maxAckDelayMicros, includeMaxAck);
                const uint shift = ptoCount < 30 ? ptoCount : 30;

                ulong backoff = ptoBase;
                if (shift > 0 && backoff > (ulong.max >> shift))
                    backoff = ulong.max;
                else
                    backoff <<= shift;

                ulong ptoDeadline = lastAckElicitingTimeMicros[s];
                if (backoff > ulong.max - ptoDeadline)
                    ptoDeadline = ulong.max;
                else
                    ptoDeadline += backoff;

                if (earliestPto == 0 || ptoDeadline < earliestPto)
                    earliestPto = ptoDeadline;
            }
        }

        // Handshake anti-deadlock PTO: if unconfirmed and in-flight is 0, arm PTO on the lowest active space (D-06)
        if (!handshakeConfirmed && earliestPto == 0)
        {
            foreach (s; 0 .. 2) // Initial or Handshake space
            {
                if (hasSentPn[s] || lastAckElicitingTimeMicros[s] > 0)
                {
                    const ulong ptoBase = rtt.ptoBaseMicros(maxAckDelayMicros, false);
                    const uint shift = ptoCount < 30 ? ptoCount : 30;
                    ulong backoff = ptoBase;
                    if (shift > 0 && backoff > (ulong.max >> shift))
                        backoff = ulong.max;
                    else
                        backoff <<= shift;

                    ulong ptoDeadline = lastAckElicitingTimeMicros[s];
                    if (backoff > ulong.max - ptoDeadline)
                        ptoDeadline = ulong.max;
                    else
                        ptoDeadline += backoff;

                    if (earliestPto == 0 || ptoDeadline < earliestPto)
                        earliestPto = ptoDeadline;
                    break;
                }
            }
        }

        return earliestPto;
    }

    /**
     * Called when the recovery timer expires.
     */
    void onTimeout(ulong nowMicros, scope SentPacketInfo[] newlyLostOut,
            out size_t lostCount, ulong maxAckDelayMicros = 25_000) @trusted @nogc nothrow
    {
        lostCount = 0;

        // 1. If any space's loss timer has expired, trigger detectLostPackets
        bool lossTimerFired = false;
        foreach (s; 0 .. NUM_SPACES)
        {
            if (lossTimeMicros[s] > 0 && lossTimeMicros[s] <= nowMicros)
            {
                lossTimerFired = true;
                ulong spaceLostBytes = 0;
                ulong spaceLargestLostTime = 0;
                ulong spaceEarliestLostTime = 0;
                detectLostPackets(cast(PacketNumberSpace) s, nowMicros, newlyLostOut,
                        lostCount, spaceLostBytes, spaceLargestLostTime, spaceEarliestLostTime);

                if (spaceLostBytes > 0)
                {
                    cc.onPacketsLost(spaceLostBytes, spaceLargestLostTime, nowMicros);
                    if (s == PacketNumberSpace.applicationData && rtt.hasSample)
                    {
                        const ulong maxRttVar = 4 * rtt.rttVar > GRANULARITY_MICROS
                            ? 4 * rtt.rttVar : GRANULARITY_MICROS;
                        const ulong ptoBase = rtt.smoothedRtt + maxRttVar + maxAckDelayMicros;
                        const ulong persistentDuration = ptoBase * 3;
                        if (persistentDuration > 0 && spaceLargestLostTime >= spaceEarliestLostTime
                                && (spaceLargestLostTime - spaceEarliestLostTime) >= persistentDuration)
                        {
                            cc.onPersistentCongestion();
                        }
                    }
                }
                compactSentPackets(cast(PacketNumberSpace) s);
            }
        }

        // 2. If no loss timer expired, it is a PTO expiry
        if (!lossTimerFired)
        {
            if (ptoCount < 32)
                ptoCount++;
        }
    }

    /**
     * Discards a packet number space upon key discard or handshake confirmation (RFC 9002 Section 6.4).
     */
    void discardSpace(PacketNumberSpace space) @trusted @nogc nothrow
    {
        const size_t s = cast(size_t) space;
        if (s >= NUM_SPACES)
            return;

        // Reclaim in-flight bytes from congestion controller
        ulong unackedInFlight = 0;
        foreach (i; 0 .. sentCount[s])
        {
            if (sentPackets[s][i].inFlight)
                unackedInFlight += sentPackets[s][i].sentBytes;
        }

        if (unackedInFlight > 0)
        {
            cc.onSpaceDiscarded(unackedInFlight);
        }

        if (sentPackets[s]!is null)
        {
            free(sentPackets[s]);
            sentPackets[s] = null;
        }
        sentCount[s] = 0;
        sentCapacity[s] = 0;
        largestSentPn[s] = 0;
        hasSentPn[s] = false;
        lossTimeMicros[s] = 0;
        lastAckElicitingTimeMicros[s] = 0;
        hasAckedPn[s] = false;
        largestAckedPn[s] = 0;
    }

    private void compactSentPackets(PacketNumberSpace space) @trusted @nogc nothrow
    {
        const size_t s = cast(size_t) space;
        if (s >= NUM_SPACES || sentCount[s] == 0)
            return;

        size_t keepIdx = sentCount[s];
        foreach (i; 0 .. sentCount[s])
        {
            if (!sentPackets[s][i].acked && !sentPackets[s][i].lost)
            {
                keepIdx = i;
                break;
            }
        }

        if (keepIdx > 0 && keepIdx < sentCount[s])
        {
            const size_t remaining = sentCount[s] - keepIdx;
            foreach (j; 0 .. remaining)
            {
                sentPackets[s][j] = sentPackets[s][keepIdx + j];
            }
            sentCount[s] = remaining;
        }
        else if (keepIdx == sentCount[s])
        {
            sentCount[s] = 0;
        }
    }
}

/// Example:
// Spec: RFC 9002 Section 6 - Packet Threshold (k=3), Time Threshold (9/8 RTT), PTO & Space Discard (Scenario T5, covers U1, U2, U3, E5, F6)
@nogc unittest
{
    LossDetector ld;
    ld.rtt.smoothedRtt = 80_000; // 80ms
    ld.rtt.latestRtt = 80_000;
    ld.rtt.hasSample = true;

    // Send 5 packets (PN 0..4) at t = 0..4ms
    foreach (pn; 0 .. 5)
    {
        ld.onPacketSent(PacketNumberSpace.applicationData, pn, 1200, true, // isAckEliciting
                true, // inFlight
                pn * 1_000 // nowMicros
                );
    }
    assert(ld.cc.bytesInFlight == 6000);

    // ACK arrives for PN 4 at t = 50ms
    AckFrame ack;
    ack.numRanges = 1;
    ack.ranges[0] = AckRange(4, 4);
    ack.ackDelay = 0;

    SentPacketInfo[8] newlyAcked;
    size_t ackedCount = 0;
    SentPacketInfo[8] newlyLost;
    size_t lostCount = 0;

    TransportErrorCode err = ld.onAckReceived(PacketNumberSpace.applicationData, ack,
            3, 25_000, true, 84_000, // 84_000 - 4_000 = 80_000 (80ms RTT sample matching smoothedRtt)
            newlyAcked[], ackedCount, newlyLost[], lostCount);
    assert(err == TransportErrorCode.noError);

    // PN 4 acked
    assert(ackedCount == 1);
    assert(newlyAcked[0].pn == 4);

    // PN 0 and PN 1 (4 - pn >= 3) are declared lost via kPacketThreshold = 3
    assert(lostCount == 2);
    assert(newlyLost[0].pn == 0);
    assert(newlyLost[1].pn == 1);

    // PN 2 and PN 3 remain in flight with loss timer armed
    // lossDelay = (9 * 80ms) / 8 = 90ms (90_000 micros)
    // PN 2 lossTime = timeSent (2_000) + 90_000 = 92_000 micros
    assert(ld.lossTimeMicros[PacketNumberSpace.applicationData] == 92_000);
    assert(ld.nextTimeoutMicros(25_000, true) == 92_000);

    // When time advances to t = 95ms (95_000 micros), onTimeout fires
    SentPacketInfo[8] timeoutLost;
    size_t timeoutLostCount = 0;
    ld.onTimeout(95_000, timeoutLost[], timeoutLostCount);

    // PN 2 and PN 3 declared lost via kTimeThreshold
    assert(timeoutLostCount == 2);
    assert(timeoutLost[0].pn == 2);
    assert(timeoutLost[1].pn == 3);
    assert(ld.cc.bytesInFlight == 0);

    // Discard space: verifies in-flight reclamation
    ld.onPacketSent(PacketNumberSpace.initial, 0, 1200, true, true, 100_000);
    assert(ld.cc.bytesInFlight == 1200);
    ld.discardSpace(PacketNumberSpace.initial);
    assert(ld.cc.bytesInFlight == 0);
}

/// Example:
// Spec: RFC 9000 Section 13.2 & Section 19.3.1 - CRITICAL-02 Regression: Optimistic/Phantom ACK Attack Defense
@nogc unittest
{
    LossDetector ld;
    ld.onPacketSent(PacketNumberSpace.applicationData, 0, 1200, true, true, 1000);
    assert(ld.cc.bytesInFlight == 1200);

    // Peer attempts to acknowledge unsent packet PN 9999
    AckFrame phantomAck;
    phantomAck.numRanges = 1;
    phantomAck.ranges[0] = AckRange(9999, 9999);

    SentPacketInfo[4] newlyAcked;
    size_t ackedCount = 0;
    SentPacketInfo[4] newlyLost;
    size_t lostCount = 0;

    TransportErrorCode err = ld.onAckReceived(PacketNumberSpace.applicationData, phantomAck,
            3, 25_000, true, 5000, newlyAcked[], ackedCount, newlyLost[], lostCount);
    assert(err == TransportErrorCode.protocolViolation);
    assert(!ld.hasAckedPn[PacketNumberSpace.applicationData]);
    assert(ld.cc.bytesInFlight == 1200); // Bytes in flight untouched!
}

/// Example:
// Spec: RFC 9002 Section 5.1 - Defect 5 Regression: Non-Ack-Eliciting ACK Does Not Update RTT
@nogc unittest
{
    LossDetector ld;
    ld.rtt.smoothedRtt = 100_000;
    ld.rtt.latestRtt = 100_000;
    ld.rtt.hasSample = true;

    // Send an ACK-only packet (not ack-eliciting)
    ld.onPacketSent(PacketNumberSpace.applicationData, 0, 50, false, false, 1000);

    AckFrame ack;
    ack.numRanges = 1;
    ack.ranges[0] = AckRange(0, 0);

    SentPacketInfo[4] acked;
    size_t ackedCount = 0;
    SentPacketInfo[4] lost;
    size_t lostCount = 0;

    TransportErrorCode err = ld.onAckReceived(PacketNumberSpace.applicationData,
            ack, 3, 25_000, true, 50_000, acked[], ackedCount, lost[], lostCount);
    assert(err == TransportErrorCode.noError);
    assert(ackedCount == 1);
    assert(ld.rtt.latestRtt == 100_000); // RTT NOT updated!
}

/// Example:
// Spec: RFC 9002 Section 6 - LossDetector Move Semantics and Memory Cleanup (covers U2, G4)
@nogc unittest
{
    LossDetector ld1;
    ld1.onPacketSent(PacketNumberSpace.handshake, 0, 1000, true, true, 1000);

    LossDetector ld2;
    ld2.moveFrom(ld1);
    assert(ld1.sentCount[PacketNumberSpace.handshake] == 0);
    assert(ld2.sentCount[PacketNumberSpace.handshake] == 1);
}

/// Example:
// Spec: RFC 9002 Section 6 & 7 - Defect F-18: >128 Acked Packets Accounting, PTO Reset Gating, and Persistent Congestion (covers E5, S1)
@nogc unittest
{
    LossDetector ld;
    ld.rtt.smoothedRtt = 10_000;
    ld.rtt.rttVar = 2_000;
    ld.rtt.latestRtt = 10_000;
    ld.rtt.hasSample = true;

    // Send 150 packets in applicationData space (1000 bytes each)
    foreach (ulong i; 0 .. 150)
    {
        ld.onPacketSent(PacketNumberSpace.applicationData, i, 1000, true, true, 1000 + i * 10);
    }
    assert(ld.cc.bytesInFlight == 150_000);

    // Set ptoCount to 3 to verify reset behavior
    ld.ptoCount = 3;

    // Receive an ACK covering all 150 packets [0..149]
    AckFrame ack;
    ack.numRanges = 1;
    ack.ranges[0] = AckRange(0, 149);

    // newlyAcked buffer size is only 16 (< 150)
    SentPacketInfo[16] smallAcked;
    size_t ackedCount = 0;
    SentPacketInfo[16] smallLost;
    size_t lostCount = 0;

    TransportErrorCode err = ld.onAckReceived(PacketNumberSpace.applicationData, ack,
            3, 25_000, true, 20_000, smallAcked[], ackedCount, smallLost[], lostCount);
    assert(err == TransportErrorCode.noError);

    // Buffer capped at 16
    assert(ackedCount == 16);
    // All 150 packets marked acked, bytesInFlight reduced to 0!
    assert(ld.cc.bytesInFlight == 0);
    // ptoCount reset because packets were ack-eliciting
    assert(ld.ptoCount == 0);

    // Now test that non-ack-eliciting packets do NOT reset ptoCount
    ld.ptoCount = 2;
    ld.onPacketSent(PacketNumberSpace.applicationData, 150, 50, false, false, 25_000);
    AckFrame nonAckElicitingAck;
    nonAckElicitingAck.numRanges = 1;
    nonAckElicitingAck.ranges[0] = AckRange(150, 150);

    ackedCount = 0;
    lostCount = 0;
    err = ld.onAckReceived(PacketNumberSpace.applicationData, nonAckElicitingAck,
            3, 25_000, true, 30_000, smallAcked[], ackedCount, smallLost[], lostCount);
    assert(err == TransportErrorCode.noError);
    assert(ackedCount == 1);
    // ptoCount must NOT be reset by non-ack-eliciting ACK!
    assert(ld.ptoCount == 2);

    // Test persistent congestion:
    // persistentCongestionDuration = (smoothed_rtt (10_000) + max(4*rttvar (8_000), 1000) + maxAckDelay (25_000)) * 3
    // = (10_000 + 8_000 + 25_000) * 3 = 43_000 * 3 = 129_000 micros.
    // Send packets at t = 100_000 and t = 250_000 (span = 150_000 > 129_000)
    ld.onPacketSent(PacketNumberSpace.applicationData, 200, 1000, true, true, 100_000);
    ld.onPacketSent(PacketNumberSpace.applicationData, 201, 1000, true, true, 250_000);
    ld.onPacketSent(PacketNumberSpace.applicationData, 202, 1000, true, true, 260_000);
    ld.onPacketSent(PacketNumberSpace.applicationData, 203, 1000, true, true, 270_000);
    ld.onPacketSent(PacketNumberSpace.applicationData, 204, 1000, true, true, 280_000);
    ld.onPacketSent(PacketNumberSpace.applicationData, 205, 1000, true, true, 290_000);

    // Receive ACK for PN 205 at t = 310_000; PN 200..202 will be declared lost (span from 100_000 to 260_000 = 160_000 > 129_000)
    AckFrame pcAck;
    pcAck.numRanges = 1;
    pcAck.ranges[0] = AckRange(205, 205);

    ackedCount = 0;
    lostCount = 0;
    err = ld.onAckReceived(PacketNumberSpace.applicationData, pcAck, 3, 25_000,
            true, 310_000, smallAcked[], ackedCount, smallLost[], lostCount);
    assert(err == TransportErrorCode.noError);
    assert(lostCount > 0);
    // Persistent congestion triggered: cwnd collapsed to 2 * maxDatagramSize = 2400
    assert(ld.cc.cwnd == 2 * ld.cc.maxDatagramSize);
}
