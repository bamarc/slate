module slate.quic.connection.events;

/**
 * QUIC Connection Events & Bounded Event Queue.
 *
 * Surfaces connection and stream state transitions to higher-level application
 * layers (such as HTTP/3 in slate.h3).
 */

import core.stdc.stdlib : calloc, free;

public enum ConnectionEventType : ubyte
{
    handshakeConfirmed = 0,
    streamReadable = 1,
    streamWritable = 2,
    streamFinished = 3,
    streamReset = 4,
    stopSending = 5,
    connectionClosed = 6
}

public struct ConnectionEvent
{
    ConnectionEventType type;
    ulong streamId;
    ulong errorCode;
    bool isApplicationClose;
}

public enum size_t EVENT_QUEUE_CAPACITY = 256;

/**
 * Bounded C-heap ring buffer for connection events with duplicate suppression.
 */
public struct ConnectionEventQueue
{
    @disable this(this);

private:
    ConnectionEvent* m_buffer = null;
    size_t m_capacity = 0;
    size_t m_head = 0;
    size_t m_tail = 0;
    size_t m_count = 0;

    void ensureAllocated() @trusted @nogc nothrow
    {
        if (m_buffer is null)
        {
            m_capacity = EVENT_QUEUE_CAPACITY;
            m_buffer = cast(ConnectionEvent*) calloc(m_capacity, ConnectionEvent.sizeof);
            m_head = 0;
            m_tail = 0;
            m_count = 0;
        }
    }

public:
     ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        if (m_buffer !is null)
        {
            free(m_buffer);
            m_buffer = null;
        }
        m_capacity = 0;
        m_head = 0;
        m_tail = 0;
        m_count = 0;
    }

    void moveFrom(ref ConnectionEventQueue other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        this.m_buffer = other.m_buffer;
        this.m_capacity = other.m_capacity;
        this.m_head = other.m_head;
        this.m_tail = other.m_tail;
        this.m_count = other.m_count;

        other.m_buffer = null;
        other.m_capacity = 0;
        other.m_head = 0;
        other.m_tail = 0;
        other.m_count = 0;
    }

    @property bool empty() const @safe pure @nogc nothrow
    {
        return m_count == 0;
    }

    @property size_t length() const @safe pure @nogc nothrow
    {
        return m_count;
    }

    @property size_t capacity() const @safe pure @nogc nothrow
    {
        return m_capacity;
    }

    void clear() @safe pure @nogc nothrow
    {
        m_head = 0;
        m_tail = 0;
        m_count = 0;
    }

    /**
     * Pushes an event onto the queue.
     * Deduplicates redundant consecutive streamReadable/streamWritable events for the same streamId.
     * If the queue is at capacity, drops the event safely to prevent unbounded growth.
     */
    bool push(ConnectionEvent ev) @trusted @nogc nothrow
    {
        ensureAllocated();
        if (m_buffer is null)
            return false;

        // Deduplicate redundant consecutive stream events for the same streamId
        if (m_count > 0 && (ev.type == ConnectionEventType.streamReadable
                || ev.type == ConnectionEventType.streamWritable))
        {
            const size_t lastIdx = (m_tail == 0 ? m_capacity : m_tail) - 1;
            const ConnectionEvent lastEv = m_buffer[lastIdx];
            if (lastEv.type == ev.type && lastEv.streamId == ev.streamId)
            {
                return true; // Already queued
            }
        }

        if (m_count >= m_capacity)
        {
            return false; // Queue full, drop event safely
        }

        m_buffer[m_tail] = ev;
        m_tail = (m_tail + 1) % m_capacity;
        m_count++;
        return true;
    }

    /**
     * Polls the next event from the queue.
     * Returns true if an event was popped, false if queue is empty.
     */
    bool poll(out ConnectionEvent ev) @trusted @nogc nothrow
    {
        ev = ConnectionEvent.init;
        if (m_count == 0 || m_buffer is null)
            return false;

        ev = m_buffer[m_head];
        m_head = (m_head + 1) % m_capacity;
        m_count--;
        return true;
    }
}

/// Example:
// Spec: RFC 9000 Section 5 - Connection Event Queue Operations and Deduplication (covers U1, U2, U3, E1)
@nogc unittest
{
    ConnectionEventQueue queue;
    assert(queue.empty);
    assert(queue.length == 0);

    // Push handshakeConfirmed
    ConnectionEvent ev1;
    ev1.type = ConnectionEventType.handshakeConfirmed;
    assert(queue.push(ev1));
    assert(!queue.empty);
    assert(queue.length == 1);

    // Push streamReadable
    ConnectionEvent ev2;
    ev2.type = ConnectionEventType.streamReadable;
    ev2.streamId = 4;
    assert(queue.push(ev2));
    assert(queue.length == 2);

    // Push duplicate streamReadable for same streamId -> must be suppressed
    assert(queue.push(ev2));
    assert(queue.length == 2);

    // Push streamReadable for different streamId -> allowed
    ConnectionEvent ev3;
    ev3.type = ConnectionEventType.streamReadable;
    ev3.streamId = 8;
    assert(queue.push(ev3));
    assert(queue.length == 3);

    // Poll events in FIFO order
    ConnectionEvent popped;
    assert(queue.poll(popped));
    assert(popped.type == ConnectionEventType.handshakeConfirmed);

    assert(queue.poll(popped));
    assert(popped.type == ConnectionEventType.streamReadable);
    assert(popped.streamId == 4);

    assert(queue.poll(popped));
    assert(popped.type == ConnectionEventType.streamReadable);
    assert(popped.streamId == 8);

    assert(!queue.poll(popped));
    assert(queue.empty);
}

/// Example:
// Best practice: Connection Event Queue Bounded Capacity & RAII Movement (covers U2, G4)
@nogc unittest
{
    ConnectionEventQueue q1;
    foreach (i; 0 .. EVENT_QUEUE_CAPACITY)
    {
        ConnectionEvent ev;
        ev.type = ConnectionEventType.streamReset;
        ev.streamId = i;
        ev.errorCode = 100 + i;
        assert(q1.push(ev));
    }
    assert(q1.length == EVENT_QUEUE_CAPACITY);

    // Overflow push must be rejected safely
    ConnectionEvent overflowEv;
    overflowEv.type = ConnectionEventType.stopSending;
    overflowEv.streamId = 9999;
    assert(!q1.push(overflowEv));
    assert(q1.length == EVENT_QUEUE_CAPACITY);

    // Test moveFrom
    ConnectionEventQueue q2;
    q2.moveFrom(q1);
    assert(q1.empty);
    assert(q1.length == 0);
    assert(q2.length == EVENT_QUEUE_CAPACITY);

    ConnectionEvent evOut;
    assert(q2.poll(evOut));
    assert(evOut.type == ConnectionEventType.streamReset);
    assert(evOut.streamId == 0);
    assert(evOut.errorCode == 100);
}
