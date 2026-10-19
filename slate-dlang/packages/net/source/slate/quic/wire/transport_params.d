module slate.quic.wire.transport_params;

/**
 * QUIC Transport Parameters (RFC 9000 Section 18).
 *
 * Implements TLV serialization, parsing, duplicate-ID detection,
 * client-forbidden parameter rejection, bounds validation, and unknown/GREASE skipping.
 */

public import slate.quic.wire.varint;
public import slate.quic.wire.cid;
public import slate.quic.crypto.kdf : Side;

public enum TransportParameterId : ulong
{
    originalDestinationConnectionId = 0x00,
    maxIdleTimeout = 0x01,
    statelessResetToken = 0x02,
    maxUdpPayloadSize = 0x03,
    initialMaxData = 0x04,
    initialMaxStreamDataBidiLocal = 0x05,
    initialMaxStreamDataBidiRemote = 0x06,
    initialMaxStreamDataUni = 0x07,
    initialMaxStreamsBidi = 0x08,
    initialMaxStreamsUni = 0x09,
    ackDelayExponent = 0x0a,
    maxAckDelay = 0x0b,
    disableActiveMigration = 0x0c,
    preferredAddress = 0x0d,
    activeConnectionIdLimit = 0x0e,
    initialSourceConnectionId = 0x0f,
    retrySourceConnectionId = 0x10,
}

public struct TransportParameters
{
    ulong maxIdleTimeout = 0;
    ulong maxUdpPayloadSize = 65527;
    ulong initialMaxData = 0;
    ulong initialMaxStreamDataBidiLocal = 0;
    ulong initialMaxStreamDataBidiRemote = 0;
    ulong initialMaxStreamDataUni = 0;
    ulong initialMaxStreamsBidi = 0;
    ulong initialMaxStreamsUni = 0;
    ulong ackDelayExponent = 3;
    ulong maxAckDelay = 25;
    bool disableActiveMigration = false;
    ulong activeConnectionIdLimit = 2;

    bool hasInitialSourceConnectionId = false;
    ConnectionId initialSourceConnectionId;

    bool hasOriginalDestinationConnectionId = false;
    ConnectionId originalDestinationConnectionId;

    bool hasStatelessResetToken = false;
    StatelessResetToken statelessResetToken;

    bool hasRetrySourceConnectionId = false;
    ConnectionId retrySourceConnectionId;
}

private WireError writeVarIntParam(ref WireWriter writer, ulong paramId, ulong value) @safe pure @nogc nothrow
{
    const size_t valLen = varIntLen(value);
    WireError err = writer.writeVarInt(paramId);
    if (err != WireError.none)
        return err;
    err = writer.writeVarInt(valLen);
    if (err != WireError.none)
        return err;
    return writer.writeVarInt(value);
}

private WireError writeCidParam(ref WireWriter writer, ulong paramId, const ref ConnectionId cid) @safe pure @nogc nothrow
{
    WireError err = writer.writeVarInt(paramId);
    if (err != WireError.none)
        return err;
    err = writer.writeVarInt(cid.len);
    if (err != WireError.none)
        return err;
    if (cid.len > 0)
        return writer.writeBytes(cid.asSlice());
    return WireError.none;
}

/**
 * Encodes TransportParameters into RFC 9000 Section 18 TLV wire format.
 */
WireError encodeTransportParams(const ref TransportParameters params, Side mySide,
        ubyte[] outBuf, out size_t bytesWritten) @safe pure @nogc nothrow
{
    bytesWritten = 0;
    if (params.maxUdpPayloadSize < 1200)
        return WireError.transportParameterError;
    if (params.ackDelayExponent > 20)
        return WireError.transportParameterError;
    if (params.maxAckDelay >= (1UL << 14))
        return WireError.transportParameterError;
    if (params.activeConnectionIdLimit < 2)
        return WireError.transportParameterError;

    WireWriter writer = WireWriter(outBuf);
    WireError wErr;

    // 0x00 original_destination_connection_id (server only)
    if (mySide == Side.server && params.hasOriginalDestinationConnectionId)
    {
        wErr = writeCidParam(writer, TransportParameterId.originalDestinationConnectionId,
                params.originalDestinationConnectionId);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x01 max_idle_timeout
    if (params.maxIdleTimeout > 0)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.maxIdleTimeout,
                params.maxIdleTimeout);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x02 stateless_reset_token (server only)
    if (mySide == Side.server && params.hasStatelessResetToken)
    {
        wErr = writer.writeVarInt(TransportParameterId.statelessResetToken);
        if (wErr != WireError.none)
            return wErr;
        wErr = writer.writeVarInt(16);
        if (wErr != WireError.none)
            return wErr;
        wErr = writer.writeBytes(params.statelessResetToken[]);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x03 max_udp_payload_size (default 65527)
    if (params.maxUdpPayloadSize != 65527)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.maxUdpPayloadSize,
                params.maxUdpPayloadSize);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x04 initial_max_data
    if (params.initialMaxData > 0)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.initialMaxData,
                params.initialMaxData);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x05 initial_max_stream_data_bidi_local
    if (params.initialMaxStreamDataBidiLocal > 0)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.initialMaxStreamDataBidiLocal,
                params.initialMaxStreamDataBidiLocal);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x06 initial_max_stream_data_bidi_remote
    if (params.initialMaxStreamDataBidiRemote > 0)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.initialMaxStreamDataBidiRemote,
                params.initialMaxStreamDataBidiRemote);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x07 initial_max_stream_data_uni
    if (params.initialMaxStreamDataUni > 0)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.initialMaxStreamDataUni,
                params.initialMaxStreamDataUni);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x08 initial_max_streams_bidi
    if (params.initialMaxStreamsBidi > 0)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.initialMaxStreamsBidi,
                params.initialMaxStreamsBidi);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x09 initial_max_streams_uni
    if (params.initialMaxStreamsUni > 0)
    {
        wErr = writeVarIntParam(writer,
                TransportParameterId.initialMaxStreamsUni, params.initialMaxStreamsUni);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x0a ack_delay_exponent (default 3)
    if (params.ackDelayExponent != 3)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.ackDelayExponent,
                params.ackDelayExponent);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x0b max_ack_delay (default 25)
    if (params.maxAckDelay != 25)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.maxAckDelay, params.maxAckDelay);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x0c disable_active_migration
    if (params.disableActiveMigration)
    {
        wErr = writer.writeVarInt(TransportParameterId.disableActiveMigration);
        if (wErr != WireError.none)
            return wErr;
        wErr = writer.writeVarInt(0);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x0e active_connection_id_limit (default 2)
    if (params.activeConnectionIdLimit != 2)
    {
        wErr = writeVarIntParam(writer, TransportParameterId.activeConnectionIdLimit,
                params.activeConnectionIdLimit);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x0f initial_source_connection_id
    if (params.hasInitialSourceConnectionId)
    {
        wErr = writeCidParam(writer, TransportParameterId.initialSourceConnectionId,
                params.initialSourceConnectionId);
        if (wErr != WireError.none)
            return wErr;
    }

    // 0x10 retry_source_connection_id (server only)
    if (mySide == Side.server && params.hasRetrySourceConnectionId)
    {
        wErr = writeCidParam(writer, TransportParameterId.retrySourceConnectionId,
                params.retrySourceConnectionId);
        if (wErr != WireError.none)
            return wErr;
    }

    bytesWritten = writer.bytesWritten;
    return WireError.none;
}

/**
 * Decodes TransportParameters from RFC 9000 Section 18 TLV wire format.
 *
 * peerSide indicates whether the peer sending these parameters was Client or Server.
 */
WireError decodeTransportParams(const(ubyte)[] buf, Side peerSide,
        out TransportParameters params, out TransportErrorCode err) @safe pure @nogc nothrow
{
    params = TransportParameters.init;
    err = TransportErrorCode.noError;

    WireReader reader = WireReader(buf);
    ulong seenLowMask = 0;
    ulong[64] seenHighIds;
    size_t numSeenHigh = 0;

    while (reader.remaining > 0)
    {
        ulong paramId = 0;
        WireError wErr = reader.readVarInt(paramId);
        if (wErr != WireError.none)
        {
            err = TransportErrorCode.transportParameterError;
            return wErr;
        }

        // Duplicate parameter detection (RFC 9000 Section 18.2)
        if (paramId < 64)
        {
            const ulong bit = 1UL << paramId;
            if ((seenLowMask & bit) != 0)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            seenLowMask |= bit;
        }
        else
        {
            foreach (i; 0 .. numSeenHigh)
            {
                if (seenHighIds[i] == paramId)
                {
                    err = TransportErrorCode.transportParameterError;
                    return WireError.transportParameterError;
                }
            }
            if (numSeenHigh < seenHighIds.length)
            {
                seenHighIds[numSeenHigh++] = paramId;
            }
        }

        ulong paramLen = 0;
        wErr = reader.readVarInt(paramLen);
        if (wErr != WireError.none)
        {
            err = TransportErrorCode.transportParameterError;
            return wErr;
        }

        const(ubyte)[] valSlice;
        wErr = reader.readSlice(cast(size_t) paramLen, valSlice);
        if (wErr != WireError.none)
        {
            err = TransportErrorCode.transportParameterError;
            return wErr;
        }

        // RFC 9000 Section 18.2: Client MUST NOT send server-only parameters
        if (peerSide == Side.client)
        {
            if (paramId == TransportParameterId.originalDestinationConnectionId
                    || paramId == TransportParameterId.statelessResetToken
                    || paramId == TransportParameterId.preferredAddress
                    || paramId == TransportParameterId.retrySourceConnectionId)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
        }

        switch (paramId)
        {
        case TransportParameterId.originalDestinationConnectionId:
            if (valSlice.length > MAX_CID_LEN)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            params.originalDestinationConnectionId = ConnectionId(valSlice);
            params.hasOriginalDestinationConnectionId = true;
            break;

        case TransportParameterId.maxIdleTimeout:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.maxIdleTimeout, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.statelessResetToken:
            if (valSlice.length != 16)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            params.statelessResetToken[] = valSlice[0 .. 16];
            params.hasStatelessResetToken = true;
            break;

        case TransportParameterId.maxUdpPayloadSize:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.maxUdpPayloadSize, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length
                    || params.maxUdpPayloadSize < 1200)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.initialMaxData:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.initialMaxData, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.initialMaxStreamDataBidiLocal:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.initialMaxStreamDataBidiLocal, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.initialMaxStreamDataBidiRemote:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.initialMaxStreamDataBidiRemote, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.initialMaxStreamDataUni:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.initialMaxStreamDataUni, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.initialMaxStreamsBidi:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.initialMaxStreamsBidi, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length
                    || params.initialMaxStreamsBidi > (1UL << 60))
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.initialMaxStreamsUni:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.initialMaxStreamsUni, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length
                    || params.initialMaxStreamsUni > (1UL << 60))
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.ackDelayExponent:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.ackDelayExponent, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length
                    || params.ackDelayExponent > 20)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.maxAckDelay:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.maxAckDelay, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length || params.maxAckDelay
                    >= 16384)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.disableActiveMigration:
            if (valSlice.length != 0)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            params.disableActiveMigration = true;
            break;

        case TransportParameterId.activeConnectionIdLimit:
            size_t readBytes = 0;
            wErr = decodeVarInt(valSlice, params.activeConnectionIdLimit, readBytes);
            if (wErr != WireError.none || readBytes != valSlice.length
                    || params.activeConnectionIdLimit < 2)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        case TransportParameterId.initialSourceConnectionId:
            if (valSlice.length > MAX_CID_LEN)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            params.initialSourceConnectionId = ConnectionId(valSlice);
            params.hasInitialSourceConnectionId = true;
            break;

        case TransportParameterId.retrySourceConnectionId:
            if (valSlice.length > MAX_CID_LEN)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            params.retrySourceConnectionId = ConnectionId(valSlice);
            params.hasRetrySourceConnectionId = true;
            break;

        case TransportParameterId.preferredAddress:
            // RFC 9000 Section 18.2:
            // IPv4 (4) + IPv4 port (2) + IPv6 (16) + IPv6 port (2) + cid_len (1) + cid (cid_len) + stateless_reset_token (16)
            // Minimum length: 4 + 2 + 16 + 2 + 1 + 1 + 16 = 42 bytes (the CID is never empty).
            if (valSlice.length < 42)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            const ubyte cidLen = valSlice[24];
            // A zero-length connection ID is a violation too (Section 18.2, R-21).
            if (cidLen == 0 || cidLen > MAX_CID_LEN || valSlice.length != 41 + cidLen)
            {
                err = TransportErrorCode.transportParameterError;
                return WireError.transportParameterError;
            }
            break;

        default:
            // RFC 9000 Section 18.1: Unknown / GREASE parameters MUST be ignored
            break;
        }
    }

    return WireError.none;
}

/// Example:
/// ---
/// TransportParameters inParams;
/// inParams.maxIdleTimeout = 30_000;
/// inParams.activeConnectionIdLimit = 4;
/// const ubyte[8] scidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
/// inParams.hasInitialSourceConnectionId = true;
/// inParams.initialSourceConnectionId = ConnectionId(scidBytes[]);
///
/// ubyte[256] wireBuf;
/// size_t totalWireLen;
/// assert(encodeTransportParams(inParams, Side.server, wireBuf[], totalWireLen) == WireError.none);
///
/// TransportParameters outParams;
/// TransportErrorCode te;
/// assert(decodeTransportParams(wireBuf[0 .. totalWireLen], Side.client, outParams, te) == WireError.none);
/// assert(outParams.activeConnectionIdLimit == 4);
/// assert(outParams.initialSourceConnectionId == ConnectionId(scidBytes[]));
/// ---
// Spec: RFC 9000 Section 18 - Transport Parameters TLV Round-Trip & GREASE Skipping (covers U1, U2, U3, E4, Scenario T4)
@nogc unittest
{
    TransportParameters inParams;
    inParams.maxIdleTimeout = 30_000;
    inParams.maxUdpPayloadSize = 1452;
    inParams.initialMaxData = 10_000_000;
    inParams.initialMaxStreamDataBidiLocal = 1_000_000;
    inParams.initialMaxStreamDataBidiRemote = 1_000_000;
    inParams.initialMaxStreamDataUni = 500_000;
    inParams.initialMaxStreamsBidi = 100;
    inParams.initialMaxStreamsUni = 50;
    inParams.ackDelayExponent = 5;
    inParams.maxAckDelay = 50;
    inParams.disableActiveMigration = true;
    inParams.activeConnectionIdLimit = 4;

    const ubyte[8] scidBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    inParams.hasInitialSourceConnectionId = true;
    inParams.initialSourceConnectionId = ConnectionId(scidBytes[]);

    ubyte[512] wireBuf;
    size_t written = 0;
    assert(encodeTransportParams(inParams, Side.client, wireBuf[], written) == WireError.none);

    // Append unknown/GREASE parameter (ID 0x1b2a, length 4, value 0xdeadbeef)
    WireWriter writer = WireWriter(wireBuf[written .. $]);
    assert(writer.writeVarInt(0x1b2a) == WireError.none);
    assert(writer.writeVarInt(4) == WireError.none);
    static const ubyte[4] greaseVal = [0xde, 0xad, 0xbe, 0xef];
    assert(writer.writeBytes(greaseVal[]) == WireError.none);
    const size_t totalWireLen = written + writer.bytesWritten;

    // Decode as server receiving client params
    TransportParameters outParams;
    TransportErrorCode te;
    WireError err = decodeTransportParams(wireBuf[0 .. totalWireLen], Side.client, outParams, te);
    assert(err == WireError.none);
    assert(te == TransportErrorCode.noError);

    assert(outParams.maxIdleTimeout == 30_000);
    assert(outParams.maxUdpPayloadSize == 1452);
    assert(outParams.initialMaxData == 10_000_000);
    assert(outParams.initialMaxStreamDataBidiLocal == 1_000_000);
    assert(outParams.initialMaxStreamDataBidiRemote == 1_000_000);
    assert(outParams.initialMaxStreamDataUni == 500_000);
    assert(outParams.initialMaxStreamsBidi == 100);
    assert(outParams.initialMaxStreamsUni == 50);
    assert(outParams.ackDelayExponent == 5);
    assert(outParams.maxAckDelay == 50);
    assert(outParams.disableActiveMigration == true);
    assert(outParams.activeConnectionIdLimit == 4);
    assert(outParams.hasInitialSourceConnectionId == true);
    assert(outParams.initialSourceConnectionId == ConnectionId(scidBytes[]));
}

/// Example:
/// ---
/// ubyte[256] buf;
/// TransportParameters tp;
/// TransportErrorCode te;
///
/// WireWriter writer = WireWriter(buf[]);
/// writer.writeVarInt(0x01);   // max_idle_timeout
/// writer.writeVarInt(1);
/// writer.writeU8(10);
/// writer.writeVarInt(0x01);   // the same parameter again
/// writer.writeVarInt(1);   // length 1
/// writer.writeU8(20);
/// assert(decodeTransportParams(writer.writtenSlice, Side.server, tp, te) == WireError.transportParameterError);
/// assert(te == TransportErrorCode.transportParameterError);
/// ---
// Spec: RFC 9000 Section 18.2 - Bounds Validation, Duplicate IDs & Client Restrictions (covers W3, G4, Scenario W3)
@nogc unittest
{
    ubyte[256] buf;
    TransportParameters tp;
    TransportErrorCode te;

    // 1. Duplicate Parameter ID
    WireWriter writer = WireWriter(buf[]);
    writer.writeVarInt(0x01); // max_idle_timeout
    writer.writeVarInt(1);
    writer.writeU8(10);
    writer.writeVarInt(0x01); // duplicate max_idle_timeout!
    writer.writeVarInt(1);
    writer.writeU8(20);
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // 2. max_udp_payload_size < 1200
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x03);
    writer.writeVarInt(2);
    writer.writeVarInt(1199); // < 1200!
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // 3. ack_delay_exponent > 20
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x0a);
    writer.writeVarInt(1);
    writer.writeVarInt(21); // > 20!
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // 4. max_ack_delay >= 16384 (2^14)
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x0b);
    writer.writeVarInt(4);
    writer.writeVarInt(16384); // >= 16384!
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // 5. active_connection_id_limit < 2
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x0e);
    writer.writeVarInt(1);
    writer.writeVarInt(1); // < 2!
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // 6. Client sent server-only stateless_reset_token (0x02)
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x02);
    writer.writeVarInt(16);
    static const ubyte[16] dummyToken = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    ];
    writer.writeBytes(dummyToken[]);
    // peerSide is client -> rejected!
    assert(decodeTransportParams(writer.writtenSlice, Side.client, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // But peerSide is server -> accepted!
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp, te) == WireError.none);
    assert(tp.hasStatelessResetToken);
    assert(tp.statelessResetToken == dummyToken);

    // 7. G4 Truncation safety across TLV prefixes
    foreach (truncLen; 1 .. writer.bytesWritten)
    {
        TransportParameters truncTp;
        TransportErrorCode truncTe;
        assert(decodeTransportParams(writer.writtenSlice[0 .. truncLen],
                Side.server, truncTp, truncTe) == WireError.unexpectedEof);
    }

    // 8. Duplicate parameter ID 0 (originalDestinationConnectionId)
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x00);
    writer.writeVarInt(4);
    writer.writeBytes(dummyToken[0 .. 4]);
    writer.writeVarInt(0x00); // duplicate ID 0!
    writer.writeVarInt(4);
    writer.writeBytes(dummyToken[0 .. 4]);
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // 9. initial_max_streams_bidi > 2^60
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x08);
    writer.writeVarInt(8);
    writer.writeVarIntWithLen((1UL << 60) + 1, 8);
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // 10. initial_max_streams_uni > 2^60
    writer = WireWriter(buf[]);
    writer.writeVarInt(0x09);
    writer.writeVarInt(8);
    writer.writeVarIntWithLen((1UL << 60) + 1, 8);
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // 11. More than 64 GREASE parameters (RFC 9000 Section 18.1 - MUST NOT fail valid peers, F-43)
    ubyte[1024] greaseBuf;
    WireWriter gw = WireWriter(greaseBuf[]);
    foreach (i; 0 .. 65)
    {
        gw.writeVarInt(100 + i); // paramId >= 64, distinct
        gw.writeVarInt(1);
        gw.writeU8(cast(ubyte) i);
    }
    assert(decodeTransportParams(gw.writtenSlice, Side.server, tp, te) == WireError.none);

    // 12. preferredAddress validation (F-39)
    // Server sent preferredAddress with < 41 bytes
    writer = WireWriter(buf[]);
    writer.writeVarInt(TransportParameterId.preferredAddress);
    writer.writeVarInt(40); // 40 < 41!
    ubyte[40] shortPref = 0;
    writer.writeBytes(shortPref[]);
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // Spec: RFC 9000 Section 18.2 - "a server MUST NOT include a zero-length connection ID in
    // this transport parameter. A client MUST treat a violation of these requirements as a
    // connection error of type TRANSPORT_PARAMETER_ERROR" (R-21, W8)
    writer = WireWriter(buf[]);
    writer.writeVarInt(TransportParameterId.preferredAddress);
    writer.writeVarInt(41);
    ubyte[41] zeroCidPref = 0;
    zeroCidPref[24] = 0; // cidLen = 0
    writer.writeBytes(zeroCidPref[]);
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);

    // Valid preferredAddress with a 1-byte CID: 4 + 2 + 16 + 2 + 1 + 1 + 16 = 42 bytes
    writer = WireWriter(buf[]);
    writer.writeVarInt(TransportParameterId.preferredAddress);
    writer.writeVarInt(42);
    ubyte[42] validPref = 0;
    validPref[24] = 1; // cidLen = 1
    writer.writeBytes(validPref[]);
    assert(decodeTransportParams(writer.writtenSlice, Side.server, tp, te) == WireError.none);

    // Client sent preferredAddress -> rejected!
    assert(decodeTransportParams(writer.writtenSlice, Side.client, tp,
            te) == WireError.transportParameterError);
    assert(te == TransportErrorCode.transportParameterError);
}
