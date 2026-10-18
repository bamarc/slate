module slate.quic.stream.flow_control;

/**
 * QUIC Stream and Connection Flow Control (RFC 9000 Section 4).
 *
 * Implements credit accounting, monotonic limit updates, strict FLOW_CONTROL_ERROR (0x03)
 * enforcement, and window auto-tuning (MAX_DATA / MAX_STREAM_DATA generation when >50% consumed).
 */

public import slate.quic.wire.cid : TransportErrorCode;
public import slate.quic.wire.varint : VARINT_MAX;

/**
 * Flow controller for stream-level or connection-level byte budget.
 */
public struct FlowController
{
    // Receive side
    ulong highestReceived = 0;
    ulong readOffset = 0;
    ulong localMaxData = 0;
    ulong initialWindowSize = 0;

    bool updateQueued = false;

    // Send side
    ulong bytesSent = 0;
    ulong remoteMaxData = 0;

    this(ulong initialWindow, ulong initialRemoteMax = 0) @safe pure @nogc nothrow
    {
        this.initialWindowSize = initialWindow <= VARINT_MAX ? initialWindow : VARINT_MAX;
        this.localMaxData = this.initialWindowSize;
        this.remoteMaxData = initialRemoteMax <= VARINT_MAX ? initialRemoteMax : VARINT_MAX;
    }

    /**
     * Checks if receiving up to newHighestReceived is within local limits without mutating state.
     */
    bool checkReceiveAllowed(ulong newHighestReceived) const @safe pure @nogc nothrow
    {
        if (newHighestReceived > VARINT_MAX)
            return false;
        return newHighestReceived <= localMaxData;
    }

    /**
     * Atomically commits a new highest received offset.
     * Returns TransportErrorCode.flowControlError if limit exceeded.
     */
    TransportErrorCode commitReceive(ulong newHighestReceived) @safe pure @nogc nothrow
    {
        if (newHighestReceived > VARINT_MAX)
            return TransportErrorCode.flowControlError;

        if (newHighestReceived > localMaxData)
            return TransportErrorCode.flowControlError;

        if (newHighestReceived > highestReceived)
            highestReceived = newHighestReceived;

        return TransportErrorCode.noError;
    }

    /**
     * Called when the application consumes bytes from the receive buffer.
     */
    void onBytesRead(size_t count) @safe pure @nogc nothrow
    {
        if (count > (VARINT_MAX - readOffset))
            readOffset = VARINT_MAX;
        else
            readOffset += count;
    }

    /**
     * Rearms flow control update transmission on packet loss.
     */
    void rearm() @safe pure @nogc nothrow
    {
        if (initialWindowSize > 0)
            updateQueued = true;
    }

    /**
     * Checks if available receive window is below 50% of initialWindowSize without mutating state (D-01).
     */
    bool hasPendingMaxDataUpdate() const @safe pure @nogc nothrow
    {
        if (initialWindowSize == 0)
            return false;

        if (updateQueued)
            return true;

        const ulong availableWindow = localMaxData > readOffset ? (localMaxData - readOffset) : 0;
        if (availableWindow <= (initialWindowSize / 2))
        {
            ulong candidate = readOffset;
            if (candidate > (VARINT_MAX - initialWindowSize))
                candidate = VARINT_MAX;
            else
                candidate += initialWindowSize;

            return candidate > localMaxData;
        }

        return false;
    }

    /**
     * Checks if available receive window is below 50% of initialWindowSize.
     * If so, auto-tunes localMaxData and yields the new limit.
     */
    bool shouldSendMaxDataUpdate(out ulong nextMaxData) @safe pure @nogc nothrow
    {
        if (initialWindowSize == 0)
            return false;

        if (updateQueued)
        {
            updateQueued = false;
            nextMaxData = localMaxData;
            return true;
        }

        const ulong availableWindow = localMaxData > readOffset ? (localMaxData - readOffset) : 0;
        if (availableWindow <= (initialWindowSize / 2))
        {
            ulong candidate = readOffset;
            if (candidate > (VARINT_MAX - initialWindowSize))
                candidate = VARINT_MAX;
            else
                candidate += initialWindowSize;

            if (candidate > localMaxData)
            {
                localMaxData = candidate;
                nextMaxData = localMaxData;
                return true;
            }
        }

        return false;
    }

    /**
     * Available sending credit in bytes.
     */
    size_t sendCredit() const @safe pure @nogc nothrow
    {
        if (remoteMaxData > bytesSent)
        {
            const ulong credit = remoteMaxData - bytesSent;
            return credit > size_t.max ? size_t.max : cast(size_t) credit;
        }
        return 0;
    }

    /**
     * Updates bytes sent on the transmission side.
     */
    void onBytesSent(size_t count) @safe pure @nogc nothrow
    {
        if (count > (VARINT_MAX - bytesSent))
            bytesSent = VARINT_MAX;
        else
            bytesSent += count;
    }

    /**
     * Updates remote peer's advertised maximum data limit monotonically (RFC 9000 Section 4.1).
     */
    void updateRemoteMaxData(ulong newMax) @safe pure @nogc nothrow
    {
        if (newMax > VARINT_MAX)
            return;

        if (newMax > remoteMaxData)
            remoteMaxData = newMax;
    }
}

/// Example:
// Spec: RFC 9000 Section 4.1 & Section 4.2 - Flow Control Accounting and Window Updates (Scenario T3, covers U1, U3, E3, W2)
@nogc unittest
{
    // Receive window of 100 bytes, send limit of 60 bytes
    FlowController fc = FlowController(100, 60);

    // Initial send credit
    assert(fc.sendCredit() == 60);
    fc.onBytesSent(25);
    assert(fc.sendCredit() == 35);
    fc.onBytesSent(35);
    assert(fc.sendCredit() == 0);

    // Monotonic remote update
    fc.updateRemoteMaxData(50); // Older/smaller value ignored
    assert(fc.sendCredit() == 0);
    fc.updateRemoteMaxData(120); // Expanded limit
    assert(fc.sendCredit() == 60);

    // Receive checks and commit
    assert(fc.checkReceiveAllowed(80));
    assert(fc.commitReceive(80) == TransportErrorCode.noError);
    assert(fc.highestReceived == 80);

    // Exceeding local limit (100)
    assert(!fc.checkReceiveAllowed(101));
    assert(fc.commitReceive(101) == TransportErrorCode.flowControlError);
    assert(fc.highestReceived == 80); // State unchanged on error!

    // Window auto-tuning: read 60 bytes (>50% of initialWindow 100)
    fc.onBytesRead(60);
    ulong newMax = 0;
    assert(fc.shouldSendMaxDataUpdate(newMax));
    assert(newMax == 160); // readOffset (60) + initialWindowSize (100)
    assert(fc.localMaxData == 160);

    // Immediate second check should return false
    assert(!fc.shouldSendMaxDataUpdate(newMax));
}

/// Example:
// Spec: RFC 9000 Section 4.1 - Integer Overflow Defense in Flow Control (covers U1, W2)
@nogc unittest
{
    FlowController fc = FlowController(1000, 1000);
    assert(fc.commitReceive(VARINT_MAX + 1) == TransportErrorCode.flowControlError);
    assert(!fc.checkReceiveAllowed(VARINT_MAX + 1));
}

/// Example:
// Spec: RFC 9000 Section 4.2 - Non-Mutating Pending Flow Control Window Query (D-01)
@nogc unittest
{
    FlowController fc = FlowController(100, 100);
    assert(!fc.hasPendingMaxDataUpdate());

    // Reading 60 bytes drops available window below 50%
    fc.onBytesRead(60);
    assert(fc.hasPendingMaxDataUpdate());
    // Calling it multiple times must be non-mutating!
    assert(fc.hasPendingMaxDataUpdate());
    assert(fc.localMaxData == 100);

    ulong newMax = 0;
    assert(fc.shouldSendMaxDataUpdate(newMax));
    assert(newMax == 160);
    assert(fc.localMaxData == 160);

    // After emission, no pending update
    assert(!fc.hasPendingMaxDataUpdate());
    assert(!fc.shouldSendMaxDataUpdate(newMax));

    // Rearm makes it pending again
    fc.rearm();
    assert(fc.hasPendingMaxDataUpdate());
    assert(fc.hasPendingMaxDataUpdate());
    assert(fc.shouldSendMaxDataUpdate(newMax));
    assert(newMax == 160);
    assert(!fc.hasPendingMaxDataUpdate());
}
