module slate.h3.error;

/**
 * HTTP/3 and QPACK Error Codes (RFC 9114 Section 8.1, RFC 9204 Section 6)
 * and Unidirectional Stream Types (RFC 9114 Section 6.2).
 */

public enum H3ErrorCode : ulong
{
    noError = 0x0100,
    generalProtocolError = 0x0101,
    internalError = 0x0102,
    streamCreationError = 0x0103,
    closedCriticalStream = 0x0104,
    frameUnexpected = 0x0105,
    frameError = 0x0106,
    excessiveLoad = 0x0107,
    idError = 0x0108,
    settingsError = 0x0109,
    missingSettings = 0x010a,
    requestRejected = 0x010b,
    requestCancelled = 0x010c,
    requestIncomplete = 0x010d,
    messageError = 0x010e,
    connectError = 0x010f,
    versionFallback = 0x0110,

    // QPACK Error Codes (RFC 9204 Section 6)
    qpackDecompressionFailed = 0x0200,
    qpackEncoderStreamError = 0x0201,
    qpackDecoderStreamError = 0x0202
}

public enum H3UniStreamType : ulong
{
    control = 0x00,
    push = 0x01,
    qpackEncoder = 0x02,
    qpackDecoder = 0x03
}

/**
 * Checks whether an integer value is an HTTP/3 or QPACK GREASE value (RFC 9114 Section 9, RFC 9204 Section 7).
 * Values of the form 0x1f * N + 0x21 are reserved for GREASE.
 */
public bool isGreaseValue(ulong value) @safe pure nothrow @nogc
{
    if (value < 0x21)
        return false;
    return ((value - 0x21) % 0x1f) == 0;
}

/// Example:
// Spec: RFC 9114 Section 8.1, RFC 9204 Section 6 - HTTP/3 and QPACK Error Codes (covers U1, U3)
@nogc unittest
{
    assert(cast(ulong) H3ErrorCode.noError == 0x0100);
    assert(cast(ulong) H3ErrorCode.generalProtocolError == 0x0101);
    assert(cast(ulong) H3ErrorCode.internalError == 0x0102);
    assert(cast(ulong) H3ErrorCode.streamCreationError == 0x0103);
    assert(cast(ulong) H3ErrorCode.closedCriticalStream == 0x0104);
    assert(cast(ulong) H3ErrorCode.frameUnexpected == 0x0105);
    assert(cast(ulong) H3ErrorCode.frameError == 0x0106);
    assert(cast(ulong) H3ErrorCode.excessiveLoad == 0x0107);
    assert(cast(ulong) H3ErrorCode.idError == 0x0108);
    assert(cast(ulong) H3ErrorCode.settingsError == 0x0109);
    assert(cast(ulong) H3ErrorCode.missingSettings == 0x010a);
    assert(cast(ulong) H3ErrorCode.requestRejected == 0x010b);
    assert(cast(ulong) H3ErrorCode.requestCancelled == 0x010c);
    assert(cast(ulong) H3ErrorCode.requestIncomplete == 0x010d);
    assert(cast(ulong) H3ErrorCode.messageError == 0x010e);
    assert(cast(ulong) H3ErrorCode.connectError == 0x010f);
    assert(cast(ulong) H3ErrorCode.versionFallback == 0x0110);

    assert(cast(ulong) H3ErrorCode.qpackDecompressionFailed == 0x0200);
    assert(cast(ulong) H3ErrorCode.qpackEncoderStreamError == 0x0201);
    assert(cast(ulong) H3ErrorCode.qpackDecoderStreamError == 0x0202);
}

/// Example:
// Spec: RFC 9114 Section 6.2, Section 9 - Stream Types and GREASE Values (covers U1, U3, E2)
@nogc unittest
{
    assert(cast(ulong) H3UniStreamType.control == 0x00);
    assert(cast(ulong) H3UniStreamType.push == 0x01);
    assert(cast(ulong) H3UniStreamType.qpackEncoder == 0x02);
    assert(cast(ulong) H3UniStreamType.qpackDecoder == 0x03);

    // GREASE formula: 0x1f * N + 0x21
    assert(isGreaseValue(0x21)); // N = 0
    assert(isGreaseValue(0x40)); // N = 1 (0x21 + 31)
    assert(isGreaseValue(0x5F)); // N = 2
    assert(isGreaseValue(0x1F * 10 + 0x21));

    assert(!isGreaseValue(0x00));
    assert(!isGreaseValue(0x20));
    assert(!isGreaseValue(0x22));
    assert(!isGreaseValue(0x3F));
    assert(!isGreaseValue(0x41));
}
