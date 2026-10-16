module slate.quic.wire.cid;

/**
 * QUIC Connection IDs and Transport Error Codes (RFC 9000 Section 5.1 & Section 20.1).
 *
 * Implements the 0..20 byte ConnectionId value struct, StatelessResetToken alias,
 * and RFC 9000 transport error codes.
 */

public enum size_t MAX_CID_LEN = 20;

/**
 * 0..20 byte QUIC Connection Identifier (RFC 9000 Section 5.1 & Section 17.2).
 */
public struct ConnectionId
{
    ubyte[MAX_CID_LEN] bytes;
    ubyte len;

    invariant
    {
        assert(len <= MAX_CID_LEN, "ConnectionId length exceeds 20 bytes");
    }

    this(const(ubyte)[] slice) @safe pure @nogc nothrow
    {
        assert(slice.length <= MAX_CID_LEN, "ConnectionId length must not exceed 20 bytes");
        len = cast(ubyte) slice.length;
        if (len > 0)
        {
            bytes[0 .. len] = slice[0 .. len];
        }
    }

    static ConnectionId fromSlice(const(ubyte)[] slice) @safe pure @nogc nothrow
    {
        return ConnectionId(slice);
    }

    @property const(ubyte)[] asSlice() return const @safe pure @nogc nothrow
    {
        return bytes[0 .. len];
    }

    bool opEquals(ref const ConnectionId other) const @safe pure @nogc nothrow
    {
        if (len != other.len)
            return false;
        return asSlice() == other.asSlice();
    }

    bool opEquals(const ConnectionId other) const @safe pure @nogc nothrow
    {
        if (len != other.len)
            return false;
        return asSlice() == other.asSlice();
    }

    size_t toHash() const @safe pure @nogc nothrow
    {
        // FNV-1a hash over bytes
        size_t hash = 2166136261U;
        foreach (i; 0 .. len)
        {
            hash ^= bytes[i];
            hash *= 16777619U;
        }
        return hash;
    }
}

/**
 * 16-byte Stateless Reset Token (RFC 9000 Section 10.3).
 */
public alias StatelessResetToken = ubyte[16];

/**
 * QUIC Transport Error Codes (RFC 9000 Section 20.1).
 */
public enum TransportErrorCode : ulong
{
    noError = 0x00,
    internalError = 0x01,
    connectionRefused = 0x02,
    flowControlError = 0x03,
    streamLimitError = 0x04,
    streamStateError = 0x05,
    finalSizeError = 0x06,
    frameEncodingError = 0x07,
    transportParameterError = 0x08,
    connectionIdLimitError = 0x09,
    protocolViolation = 0x0a,
    invalidToken = 0x0b,
    applicationError = 0x0c,
    cryptoBufferExceeded = 0x0d,
    keyUpdateError = 0x0e,
    aeadLimitReached = 0x0f,
    noViablePath = 0x10,
    cryptoErrorBase = 0x0100
}

/**
 * Checks if an error code represents a TLS alert crypto error (RFC 9000 Section 20.1 & RFC 9001 Section 4.8).
 */
bool isCryptoError(ulong code) @safe pure @nogc nothrow
{
    return code >= TransportErrorCode.cryptoErrorBase
        && code <= (TransportErrorCode.cryptoErrorBase + 0xff);
}

/**
 * Maps a TLS alert code to a QUIC crypto error code (RFC 9001 Section 4.8).
 */
ulong cryptoErrorCode(ubyte alertCode) @safe pure @nogc nothrow
{
    return TransportErrorCode.cryptoErrorBase | cast(ulong) alertCode;
}

/**
 * Extracts the TLS alert code from a QUIC crypto error code.
 */
ubyte cryptoAlertCode(ulong errorCode) @safe pure @nogc nothrow
{
    return cast(ubyte)(errorCode & 0xff);
}

/// Example:
// Spec: RFC 9000 Section 5.1 & Section 17.2 - Connection ID Value Struct & Invariants (covers U1, U2, U3)
@nogc unittest
{
    // Empty CID (0-length)
    ConnectionId emptyCid;
    assert(emptyCid.len == 0);
    assert(emptyCid.asSlice().length == 0);

    // 8-byte CID
    const ubyte[8] raw8 = [0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08];
    ConnectionId cid8 = ConnectionId(raw8[]);
    assert(cid8.len == 8);
    assert(cid8.asSlice() == raw8[]);

    // 20-byte maximum CID
    const ubyte[20] raw20 = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14
    ];
    ConnectionId cid20 = ConnectionId.fromSlice(raw20[]);
    assert(cid20.len == 20);
    assert(cid20.asSlice() == raw20[]);

    // Equality & inequality
    ConnectionId cid8Copy = ConnectionId(raw8[]);
    assert(cid8 == cid8Copy);
    assert(cid8 != cid20);
    assert(cid8 != emptyCid);

    // Hash consistency
    assert(cid8.toHash() == cid8Copy.toHash());
}

/// Example:
// Spec: RFC 9000 Section 20.1 & RFC 9001 Section 4.8 - Transport Error Codes & Crypto Alerts (covers U1, U3)
@nogc unittest
{
    assert(TransportErrorCode.noError == 0x00);
    assert(TransportErrorCode.protocolViolation == 0x0a);
    assert(TransportErrorCode.cryptoBufferExceeded == 0x0d);
    assert(TransportErrorCode.noViablePath == 0x10);

    // Crypto error mapping
    const ulong err = cryptoErrorCode(120); // no_application_protocol alert
    assert(err == 0x0178);
    assert(isCryptoError(err));
    assert(cryptoAlertCode(err) == 120);

    assert(!isCryptoError(TransportErrorCode.protocolViolation));
    assert(!isCryptoError(0x0200));
}
