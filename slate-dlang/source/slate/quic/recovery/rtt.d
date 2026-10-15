module slate.quic.recovery.rtt;

/**
 * QUIC Round-Trip Time (RTT) Estimation (RFC 9002 Section 5).
 *
 * Implements smoothed_rtt, rttvar, min_rtt, ack_delay validation, and Probe Timeout (PTO)
 * base calculation per RFC 9002 Section 5.3 and Section 6.2.
 */

public enum ulong INITIAL_RTT_MICROS = 333_000UL; // 333ms (RFC 9002 Section 6.2.2)
public enum ulong GRANULARITY_MICROS = 1_000UL;   // 1ms timer granularity (RFC 9002 Section 6.1.2)

/**
 * Deterministic microsecond RTT estimator.
 */
public struct RttEstimator
{
    ulong minRtt = ulong.max;
    ulong smoothedRtt = INITIAL_RTT_MICROS;
    ulong rttVar = INITIAL_RTT_MICROS / 2;
    ulong latestRtt = 0;
    bool hasSample = false;

    /**
     * Updates RTT metrics with a new sample per RFC 9002 Section 5.3.
     */
    void update(
        ulong latestRttMicros,
        ulong ackDelayMicros,
        ulong maxAckDelayMicros,
        bool handshakeConfirmed
    ) @safe pure @nogc nothrow
    {
        latestRtt = latestRttMicros;

        if (!hasSample)
        {
            hasSample = true;
            minRtt = latestRtt;
            smoothedRtt = latestRtt;
            rttVar = latestRtt / 2;
            return;
        }

        if (latestRtt < minRtt)
            minRtt = latestRtt;

        ulong ackDelay = 0;
        if (handshakeConfirmed)
        {
            ackDelay = ackDelayMicros < maxAckDelayMicros ? ackDelayMicros : maxAckDelayMicros;
        }

        ulong adjustedRtt = latestRtt;
        if (latestRtt >= ackDelay && (latestRtt - ackDelay) >= minRtt)
        {
            adjustedRtt = latestRtt - ackDelay;
        }

        const ulong absDiff = smoothedRtt > adjustedRtt ? (smoothedRtt - adjustedRtt) : (adjustedRtt - smoothedRtt);
        if (rttVar <= (ulong.max - absDiff) / 3)
            rttVar = (3 * rttVar + absDiff) / 4;
        else
            rttVar = rttVar - (rttVar / 4) + (absDiff / 4);

        if (smoothedRtt <= (ulong.max - adjustedRtt) / 7)
            smoothedRtt = (7 * smoothedRtt + adjustedRtt) / 8;
        else
            smoothedRtt = smoothedRtt - (smoothedRtt / 8) + (adjustedRtt / 8);
    }

    /**
     * Computes the Probe Timeout (PTO) base duration per RFC 9002 Section 6.2.1:
     * PTO = smoothed_rtt + max(4*rttvar, kGranularity) + (includeMaxAckDelay ? max_ack_delay : 0).
     */
    ulong ptoBaseMicros(ulong maxAckDelayMicros, bool includeMaxAckDelay = true) const @safe pure @nogc nothrow
    {
        const ulong fourVar = rttVar <= (ulong.max / 4) ? (4 * rttVar) : ulong.max;
        const ulong varPart = (fourVar > GRANULARITY_MICROS) ? fourVar : GRANULARITY_MICROS;
        const ulong addDelay = includeMaxAckDelay ? maxAckDelayMicros : 0;

        ulong pto = smoothedRtt;
        if (varPart > (ulong.max - pto))
            pto = ulong.max;
        else
            pto += varPart;

        if (addDelay > (ulong.max - pto))
            pto = ulong.max;
        else
            pto += addDelay;

        return pto;
    }
}

/// Example:
// Spec: RFC 9002 Section 5.3 & Section 6.2.1 - RTT Estimator and PTO Calculation (Scenario T4, covers U1, U3, E4)
@nogc unittest
{
    RttEstimator rtt;
    assert(!rtt.hasSample);
    assert(rtt.smoothedRtt == INITIAL_RTT_MICROS);
    assert(rtt.rttVar == INITIAL_RTT_MICROS / 2);

    // Initial sample: 100ms (100_000 micros)
    rtt.update(100_000, 0, 25_000, false);
    assert(rtt.hasSample);
    assert(rtt.latestRtt == 100_000);
    assert(rtt.minRtt == 100_000);
    assert(rtt.smoothedRtt == 100_000);
    assert(rtt.rttVar == 50_000);

    // Second sample: 120ms (120_000 micros), ackDelay = 20ms (20_000), maxAckDelay = 25ms, handshakeConfirmed = true
    rtt.update(120_000, 20_000, 25_000, true);
    assert(rtt.latestRtt == 120_000);
    assert(rtt.minRtt == 100_000);
    // adjustedRtt = 120_000 - 20_000 = 100_000
    // absDiff = |100_000 - 100_000| = 0
    // rttVar = (3 * 50_000 + 0) / 4 = 37_500
    // smoothedRtt = (7 * 100_000 + 100_000) / 8 = 100_000
    assert(rtt.rttVar == 37_500);
    assert(rtt.smoothedRtt == 100_000);

    // PTO Base: smoothedRtt (100_000) + 4 * rttVar (150_000) + maxAckDelay (25_000) = 275_000 micros (275ms)
    assert(rtt.ptoBaseMicros(25_000, true) == 275_000);

    // PTO Base without maxAckDelay (Initial and Handshake spaces): 250_000 micros (250ms)
    assert(rtt.ptoBaseMicros(25_000, false) == 250_000);
}
