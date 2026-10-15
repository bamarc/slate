module slate.quic.wire;

/**
 * QUIC Wire Primitives, Headers, Frames, and Transport Parameters (RFC 9000 & RFC 9001).
 *
 * Re-exports:
 * - slate.quic.wire.varint: 62-bit VarInt codec, WireReader, WireWriter
 * - slate.quic.wire.cid: ConnectionId (0..20 bytes), StatelessResetToken, TransportErrorCode
 * - slate.quic.wire.packet: PacketPrefix, DecodedPacketHeader, CoalescedPacketIterator, codecs
 * - slate.quic.wire.frame: All 20 RFC 9000 Section 19 frame types, FrameIterator, validation
 * - slate.quic.wire.transport_params: RFC 9000 Section 18 TransportParameters TLV codec
 */

public import slate.quic.wire.varint;
public import slate.quic.wire.cid;
public import slate.quic.wire.packet;
public import slate.quic.wire.frame;
public import slate.quic.wire.transport_params;

import slate.quic.crypto.kdf;
import slate.quic.crypto.aead;
import slate.quic.crypto.header_protection;
import slate.quic.crypto.packet_keys;
import slate.quic.crypto.tls_session;

/// Example:
// Spec: RFC 9001 Appendix A.2 & A.3 - Full Packet Wire-to-Frame Pipeline (covers E2, E3, E5, Scenario T5)
@nogc unittest
{
    // =========================================================================
    // Part 1: RFC 9001 Appendix A.2 - Client Initial (1200 bytes)
    // =========================================================================
    const ubyte[16] clientKey = [
        0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46,
        0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d
    ];
    const ubyte[12] clientIv = [
        0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b,
        0x46, 0xfb, 0x25, 0x5c
    ];
    const ubyte[16] clientHp = [
        0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10,
        0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2
    ];

    DirectionalKeys clientWriteKeys;
    clientWriteKeys.init(CipherSuite.TLS_AES_128_GCM_SHA256, clientKey, clientIv, clientHp);
    DirectionalKeys clientReadKeys;
    clientReadKeys.init(CipherSuite.TLS_AES_128_GCM_SHA256, clientKey, clientIv, clientHp);

    const ubyte[22] unprotHeaderA2 = [
        0xc3, 0x00, 0x00, 0x00, 0x01, 0x08, 0x83, 0x94,
        0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08, 0x00, 0x00,
        0x44, 0x9e, 0x00, 0x00, 0x00, 0x02
    ];

    const ubyte[245] cryptoFramePrefixA2 = [
        0x06, 0x00, 0x40, 0xf1, 0x01, 0x00, 0x00, 0xed, 0x03, 0x03, 0xeb, 0xf8,
        0xfa, 0x56, 0xf1, 0x29, 0x39, 0xb9, 0x58, 0x4a, 0x38, 0x96, 0x47, 0x2e,
        0xc4, 0x0b, 0xb8, 0x63, 0xcf, 0xd3, 0xe8, 0x68, 0x04, 0xfe, 0x3a, 0x47,
        0xf0, 0x6a, 0x2b, 0x69, 0x48, 0x4c, 0x00, 0x00, 0x04, 0x13, 0x01, 0x13,
        0x02, 0x01, 0x00, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x10, 0x00, 0x0e, 0x00,
        0x00, 0x0b, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f,
        0x6d, 0xff, 0x01, 0x00, 0x01, 0x00, 0x00, 0x0a, 0x00, 0x08, 0x00, 0x06,
        0x00, 0x1d, 0x00, 0x17, 0x00, 0x18, 0x00, 0x10, 0x00, 0x07, 0x00, 0x05,
        0x04, 0x61, 0x6c, 0x70, 0x6e, 0x00, 0x05, 0x00, 0x05, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20,
        0x93, 0x70, 0xb2, 0xc9, 0xca, 0xa4, 0x7f, 0xba, 0xba, 0xf4, 0x55, 0x9f,
        0xed, 0xba, 0x75, 0x3d, 0xe1, 0x71, 0xfa, 0x71, 0xf5, 0x0f, 0x1c, 0xe1,
        0x5d, 0x43, 0xe9, 0x94, 0xec, 0x74, 0xd7, 0x48, 0x00, 0x2b, 0x00, 0x03,
        0x02, 0x03, 0x04, 0x00, 0x0d, 0x00, 0x10, 0x00, 0x0e, 0x04, 0x03, 0x05,
        0x03, 0x06, 0x03, 0x02, 0x03, 0x08, 0x04, 0x08, 0x05, 0x08, 0x06, 0x00,
        0x2d, 0x00, 0x02, 0x01, 0x01, 0x00, 0x1c, 0x00, 0x02, 0x40, 0x01, 0x00,
        0x39, 0x00, 0x32, 0x04, 0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0x05, 0x04, 0x80, 0x00, 0xff, 0xff, 0x07, 0x04, 0x80, 0x00, 0xff,
        0xff, 0x08, 0x01, 0x10, 0x01, 0x04, 0x80, 0x00, 0x75, 0x30, 0x09, 0x01,
        0x10, 0x0f, 0x08, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08, 0x06,
        0x04, 0x80, 0x00, 0xff, 0xff
    ];

    ubyte[1200] pktBufferA2;
    pktBufferA2[0 .. 22] = unprotHeaderA2[];
    pktBufferA2[22 .. 22 + 245] = cryptoFramePrefixA2[];
    pktBufferA2[22 + 245 .. 22 + 1162] = 0; // PADDING

    size_t protLenA2 = 0;
    assert(protectPacket(clientWriteKeys, 2, 18, 4, pktBufferA2, 1162, protLenA2) == QuicCryptoError.none);
    assert(protLenA2 == 1200);

    // Pipeline Unpack: parsePacketPrefix -> unprotectPacket -> completeHeaderAfterUnprotect -> decodeFrame
    PacketPrefix prefixA2;
    assert(parsePacketPrefix(pktBufferA2[0 .. 1200], 0, prefixA2) == WireError.none);
    assert(prefixA2.type == PacketType.initial);
    assert(prefixA2.version_ == QUIC_VERSION_1);
    assert(prefixA2.totalPacketLen == 1200);
    assert(prefixA2.pnOffset == 18);

    ubyte[1200] unprotPktA2 = pktBufferA2;
    size_t decPnLenA2 = 0;
    ulong decPnA2 = 0;
    size_t decPayOffA2 = 0;
    size_t decPlainLenA2 = 0;
    assert(unprotectPacket(clientReadKeys, prefixA2.pnOffset, 0, unprotPktA2, decPnLenA2, decPnA2, decPayOffA2, decPlainLenA2) == QuicCryptoError.none);
    assert(decPnA2 == 2);
    assert(decPnLenA2 == 4);
    assert(decPlainLenA2 == 1162);

    DecodedPacketHeader hdrA2;
    TransportErrorCode teA2;
    assert(completeHeaderAfterUnprotect(unprotPktA2[0 .. decPayOffA2 + decPlainLenA2], prefixA2, 0, hdrA2, teA2) == WireError.none);
    assert(hdrA2.packetNumber == 2);
    assert(hdrA2.pnLen == 4);

    // Decode frames from decrypted plaintext
    const(ubyte)[] plaintextSliceA2 = unprotPktA2[decPayOffA2 .. decPayOffA2 + decPlainLenA2];
    FrameIterator fIterA2 = FrameIterator(plaintextSliceA2, PacketType.initial);
    Frame f1A2;
    WireError wErrA2;
    assert(fIterA2.next(f1A2, wErrA2, teA2));
    assert(f1A2.type == FrameType.crypto);
    assert(f1A2.crypto.offset == 0);
    assert(f1A2.crypto.data.length == 241);

    Frame f2A2;
    assert(fIterA2.next(f2A2, wErrA2, teA2));
    assert(f2A2.type == FrameType.padding);
    assert(f2A2.padding.length == (1162 - 245)); // 917 padding bytes
    assert(fIterA2.empty);

    // =========================================================================
    // Part 2: RFC 9001 Appendix A.3 - Server Initial (135 bytes)
    // =========================================================================
    const ubyte[16] serverKey = [
        0xcf, 0x3a, 0x53, 0x31, 0x65, 0x3c, 0x36, 0x4c,
        0x88, 0xf0, 0xf3, 0x79, 0xb6, 0x06, 0x7e, 0x37
    ];
    const ubyte[12] serverIv = [
        0x0a, 0xc1, 0x49, 0x3c, 0xa1, 0x90, 0x58, 0x53,
        0xb0, 0xbb, 0xa0, 0x3e
    ];
    const ubyte[16] serverHp = [
        0xc2, 0x06, 0xb8, 0xd9, 0xb9, 0xf0, 0xf3, 0x76,
        0x44, 0x43, 0x0b, 0x49, 0x0e, 0xea, 0xa3, 0x14
    ];

    DirectionalKeys serverWriteKeys;
    serverWriteKeys.init(CipherSuite.TLS_AES_128_GCM_SHA256, serverKey, serverIv, serverHp);
    DirectionalKeys serverReadKeys;
    serverReadKeys.init(CipherSuite.TLS_AES_128_GCM_SHA256, serverKey, serverIv, serverHp);

    const ubyte[20] headerA3 = [
        0xc1, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0xf0,
        0x67, 0xa5, 0x50, 0x2a, 0x42, 0x62, 0xb5, 0x00,
        0x40, 0x75, 0x00, 0x01
    ];
    const ubyte[99] payloadA3 = [
        0x02, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x40, 0x5a, 0x02, 0x00, 0x00,
        0x56, 0x03, 0x03, 0xee, 0xfc, 0xe7, 0xf7, 0xb3, 0x7b, 0xa1, 0xd1, 0x63,
        0x2e, 0x96, 0x67, 0x78, 0x25, 0xdd, 0xf7, 0x39, 0x88, 0xcf, 0xc7, 0x98,
        0x25, 0xdf, 0x56, 0x6d, 0xc5, 0x43, 0x0b, 0x9a, 0x04, 0x5a, 0x12, 0x00,
        0x13, 0x01, 0x00, 0x00, 0x2e, 0x00, 0x33, 0x00, 0x24, 0x00, 0x1d, 0x00,
        0x20, 0x9d, 0x3c, 0x94, 0x0d, 0x89, 0x69, 0x0b, 0x84, 0xd0, 0x8a, 0x60,
        0x99, 0x3c, 0x14, 0x4e, 0xca, 0x68, 0x4d, 0x10, 0x81, 0x28, 0x7c, 0x83,
        0x4d, 0x53, 0x11, 0xbc, 0xf3, 0x2b, 0xb9, 0xda, 0x1a, 0x00, 0x2b, 0x00,
        0x02, 0x03, 0x04
    ];

    ubyte[135] pktBufferA3;
    pktBufferA3[0 .. 20] = headerA3[];
    pktBufferA3[20 .. 119] = payloadA3[];

    size_t protLenA3 = 0;
    assert(protectPacket(serverWriteKeys, 1, 18, 2, pktBufferA3, 99, protLenA3) == QuicCryptoError.none);
    assert(protLenA3 == 135);

    // Pipeline Unpack: parsePacketPrefix -> unprotectPacket -> completeHeaderAfterUnprotect -> decodeFrame
    PacketPrefix prefixA3;
    assert(parsePacketPrefix(pktBufferA3[0 .. 135], 0, prefixA3) == WireError.none);
    assert(prefixA3.type == PacketType.initial);
    assert(prefixA3.version_ == QUIC_VERSION_1);
    assert(prefixA3.totalPacketLen == 135);
    assert(prefixA3.pnOffset == 18);

    ubyte[135] unprotPktA3 = pktBufferA3;
    size_t decPnLenA3 = 0;
    ulong decPnA3 = 0;
    size_t decPayOffA3 = 0;
    size_t decPlainLenA3 = 0;
    assert(unprotectPacket(serverReadKeys, prefixA3.pnOffset, 0, unprotPktA3, decPnLenA3, decPnA3, decPayOffA3, decPlainLenA3) == QuicCryptoError.none);
    assert(decPnA3 == 1);
    assert(decPnLenA3 == 2);
    assert(decPlainLenA3 == 99);

    DecodedPacketHeader hdrA3;
    TransportErrorCode teA3;
    assert(completeHeaderAfterUnprotect(unprotPktA3[0 .. decPayOffA3 + decPlainLenA3], prefixA3, 0, hdrA3, teA3) == WireError.none);
    assert(hdrA3.packetNumber == 1);
    assert(hdrA3.pnLen == 2);

    const(ubyte)[] plaintextSliceA3 = unprotPktA3[decPayOffA3 .. decPayOffA3 + decPlainLenA3];
    FrameIterator fIterA3 = FrameIterator(plaintextSliceA3, PacketType.initial);
    Frame f1A3;
    WireError wErrA3;
    assert(fIterA3.next(f1A3, wErrA3, teA3));
    assert(f1A3.type == FrameType.ack);
    assert(f1A3.ack.numRanges == 1);
    assert(f1A3.ack.ranges[0] == AckRange(0, 0));

    Frame f2A3;
    assert(fIterA3.next(f2A3, wErrA3, teA3));
    assert(f2A3.type == FrameType.crypto);
    assert(f2A3.crypto.offset == 0);
    assert(f2A3.crypto.data.length == 90);
    assert(fIterA3.empty);
}

/// Example:
// Spec: RFC 9001 Section 4 & RFC 9000 Section 18 - End-to-End Sans-I/O TLS 1.3 Handshake Over Coalesced Wire Packets (covers E2, E3, E4, E5, Scenario T6)
@nogc unittest
{
    // Helpers to create OpenSSL TLS contexts in @nogc context using @trusted shim
    auto makeServerCtx = () @trusted @nogc nothrow {
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow {
        alias ClientFn = TlsContext function() @nogc nothrow;
        return (cast(ClientFn)&TlsContext.createClient)();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    assert(serverCtx.isValid);
    assert(clientCtx.isValid);

    // 1. Setup CIDs and Initial Keys
    const ubyte[8] dcidBytes = [0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08];
    const ubyte[8] scidBytes = [0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8];
    ConnectionId clientDcid = ConnectionId(dcidBytes[]);
    ConnectionId clientScid = ConnectionId(scidBytes[]);

    ubyte[32] initSecret;
    deriveInitialSecret(dcidBytes[], initSecret);

    ubyte[32] clientInitSec;
    deriveClientInitialSecret(initSecret, clientInitSec);
    KeyMaterial clientKm;
    deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, clientInitSec, clientKm);

    DirectionalKeys clientInitWrite;
    clientInitWrite.init(CipherSuite.TLS_AES_128_GCM_SHA256, clientKm.key[0 .. 16], clientKm.iv[0 .. 12], clientKm.hp[0 .. 16]);
    DirectionalKeys serverInitRead;
    serverInitRead.init(CipherSuite.TLS_AES_128_GCM_SHA256, clientKm.key[0 .. 16], clientKm.iv[0 .. 12], clientKm.hp[0 .. 16]);

    ubyte[32] serverInitSec;
    deriveServerInitialSecret(initSecret, serverInitSec);
    KeyMaterial serverKm;
    deriveKeyMaterial(CipherSuite.TLS_AES_128_GCM_SHA256, serverInitSec, serverKm);

    DirectionalKeys serverInitWrite;
    serverInitWrite.init(CipherSuite.TLS_AES_128_GCM_SHA256, serverKm.key[0 .. 16], serverKm.iv[0 .. 12], serverKm.hp[0 .. 16]);
    DirectionalKeys clientInitRead;
    clientInitRead.init(CipherSuite.TLS_AES_128_GCM_SHA256, serverKm.key[0 .. 16], serverKm.iv[0 .. 12], serverKm.hp[0 .. 16]);

    // 2. Encode Client and Server TransportParameters
    TransportParameters clientTp;
    clientTp.hasInitialSourceConnectionId = true;
    clientTp.initialSourceConnectionId = clientScid;
    clientTp.initialMaxData = 10_000_000;
    clientTp.initialMaxStreamsBidi = 100;

    ubyte[256] clientTpBuf;
    size_t clientTpLen = 0;
    assert(encodeTransportParams(clientTp, Side.client, clientTpBuf[], clientTpLen) == WireError.none);

    TransportParameters serverTp;
    serverTp.hasOriginalDestinationConnectionId = true;
    serverTp.originalDestinationConnectionId = clientDcid;
    serverTp.hasInitialSourceConnectionId = true;
    serverTp.initialSourceConnectionId = clientDcid;
    serverTp.initialMaxData = 20_000_000;
    serverTp.initialMaxStreamsBidi = 200;

    ubyte[256] serverTpBuf;
    size_t serverTpLen = 0;
    assert(encodeTransportParams(serverTp, Side.server, serverTpBuf[], serverTpLen) == WireError.none);

    // 3. Initialize TLS Sessions
    TlsSession serverSession;
    serverSession.init(serverCtx, Side.server, serverTpBuf[0 .. serverTpLen]);
    TlsSession clientSession;
    clientSession.init(clientCtx, Side.client, clientTpBuf[0 .. clientTpLen]);

    // 4. Flight 1 (Client -> Server Initial Packet)
    assert(clientSession.stepHandshake() == QuicCryptoError.none);
    ubyte[2048] cHelloBuf;
    const clientHello = clientSession.writeHandshake(EncryptionLevel.initial, cHelloBuf);
    assert(clientHello.length > 0);

    // Pack into CRYPTO frame + optional PADDING inside Protected Initial Packet
    Frame cCryptoFrame;
    cCryptoFrame.type = FrameType.crypto;
    cCryptoFrame.crypto.offset = 0;
    cCryptoFrame.crypto.data = clientHello;

    ubyte[3000] clientPacketBuf;
    size_t cPnOff = 0;
    size_t cHdrLen = 0;

    ubyte[2048] cPlaintext;
    size_t cFrameWritten = 0;
    assert(encodeFrame(cCryptoFrame, cPlaintext[], cFrameWritten) == WireError.none);
    const size_t cPlaintextLen = (cFrameWritten >= 1162) ? cFrameWritten : 1162;
    if (cFrameWritten < cPlaintextLen)
        cPlaintext[cFrameWritten .. cPlaintextLen] = 0; // PADDING

    assert(encodeLongHeader(
        PacketType.initial,
        QUIC_VERSION_1,
        clientDcid,
        clientScid,
        null, // token
        0UL,  // PN = 0
        2,    // PN len = 2
        cPlaintextLen,
        clientPacketBuf[],
        cPnOff,
        cHdrLen
    ) == WireError.none);

    clientPacketBuf[cHdrLen .. cHdrLen + cPlaintextLen] = cPlaintext[0 .. cPlaintextLen];
    size_t cProtLen = 0;
    assert(protectPacket(clientInitWrite, 0UL, cPnOff, 2, clientPacketBuf[], cPlaintextLen, cProtLen) == QuicCryptoError.none);

    // 5. Server unpacks Flight 1
    PacketPrefix sPref1;
    assert(parsePacketPrefix(clientPacketBuf[0 .. cProtLen], 0, sPref1) == WireError.none);
    assert(sPref1.type == PacketType.initial);

    size_t sDecPnLen1 = 0;
    ulong sDecPn1 = 0;
    size_t sDecPayOff1 = 0;
    size_t sDecPlainLen1 = 0;
    ubyte[3000] sRecvBuf1;
    sRecvBuf1[0 .. cProtLen] = clientPacketBuf[0 .. cProtLen];
    assert(unprotectPacket(serverInitRead, sPref1.pnOffset, 0, sRecvBuf1[0 .. cProtLen], sDecPnLen1, sDecPn1, sDecPayOff1, sDecPlainLen1) == QuicCryptoError.none);

    DecodedPacketHeader sHdr1;
    TransportErrorCode sTe1;
    assert(completeHeaderAfterUnprotect(sRecvBuf1[0 .. sDecPayOff1 + sDecPlainLen1], sPref1, 0, sHdr1, sTe1) == WireError.none);
    assert(sHdr1.packetNumber == 0UL);

    FrameIterator sIter1 = FrameIterator(sRecvBuf1[sDecPayOff1 .. sDecPayOff1 + sDecPlainLen1], PacketType.initial);
    Frame sF1;
    WireError sWe1;
    assert(sIter1.next(sF1, sWe1, sTe1));
    assert(sF1.type == FrameType.crypto);
    assert(serverSession.readHandshake(EncryptionLevel.initial, sF1.crypto.data) == QuicCryptoError.none);

    // Server decodes peer transport parameters received from ClientHello
    TransportParameters sDecodedPeerTp;
    assert(decodeTransportParams(serverSession.peerTransportParams, Side.client, sDecodedPeerTp, sTe1) == WireError.none);
    assert(sDecodedPeerTp.initialMaxData == 10_000_000);
    assert(sDecodedPeerTp.initialMaxStreamsBidi == 100);

    // 6. Server generates Flight 2 (Initial + Handshake) and coalesces them into a single datagram
    ubyte[2048] sInitFlightBuf;
    const sInitData = serverSession.writeHandshake(EncryptionLevel.initial, sInitFlightBuf);
    ubyte[4096] sHsFlightBuf;
    const sHsData = serverSession.writeHandshake(EncryptionLevel.handshake, sHsFlightBuf);

    assert(sInitData.length > 0);
    assert(sHsData.length > 0);

    TlsSession.LevelKeys serverHsKeys;
    assert(serverSession.pollNextKeys(serverHsKeys));
    assert(serverHsKeys.level == EncryptionLevel.handshake);

    ubyte[8192] coalescedDatagram;
    size_t coalescedLen = 0;

    // 6a. Server Initial Packet with ACK [0..0] and CRYPTO frame
    Frame sAckFrame;
    sAckFrame.type = FrameType.ack;
    sAckFrame.ack.numRanges = 1;
    sAckFrame.ack.ranges[0] = AckRange(0, 0);

    Frame sCryptoFrame1;
    sCryptoFrame1.type = FrameType.crypto;
    sCryptoFrame1.crypto.offset = 0;
    sCryptoFrame1.crypto.data = sInitData;

    ubyte[2048] sInitPlaintext;
    size_t sInitPlainLen = 0;
    size_t fBytes = 0;
    assert(encodeFrame(sAckFrame, sInitPlaintext[sInitPlainLen .. $], fBytes) == WireError.none);
    sInitPlainLen += fBytes;
    assert(encodeFrame(sCryptoFrame1, sInitPlaintext[sInitPlainLen .. $], fBytes) == WireError.none);
    sInitPlainLen += fBytes;

    size_t sInitPnOff = 0;
    size_t sInitHdrLen = 0;
    assert(encodeLongHeader(
        PacketType.initial,
        QUIC_VERSION_1,
        clientScid,
        clientDcid,
        null,
        1UL, // PN = 1
        2,
        sInitPlainLen,
        coalescedDatagram[coalescedLen .. $],
        sInitPnOff,
        sInitHdrLen
    ) == WireError.none);

    coalescedDatagram[coalescedLen + sInitHdrLen .. coalescedLen + sInitHdrLen + sInitPlainLen] = sInitPlaintext[0 .. sInitPlainLen];
    size_t sInitProtLen = 0;
    assert(protectPacket(serverInitWrite, 1UL, sInitPnOff, 2, coalescedDatagram[coalescedLen .. $], sInitPlainLen, sInitProtLen) == QuicCryptoError.none);
    coalescedLen += sInitProtLen;

    // 6b. Server Handshake Packet with CRYPTO frame
    Frame sCryptoFrame2;
    sCryptoFrame2.type = FrameType.crypto;
    sCryptoFrame2.crypto.offset = 0;
    sCryptoFrame2.crypto.data = sHsData;

    ubyte[4096] sHsPlaintext;
    size_t sHsPlainLen = 0;
    assert(encodeFrame(sCryptoFrame2, sHsPlaintext[], sHsPlainLen) == WireError.none);

    size_t sHsPnOff = 0;
    size_t sHsHdrLen = 0;
    assert(encodeLongHeader(
        PacketType.handshake,
        QUIC_VERSION_1,
        clientScid,
        clientDcid,
        null,
        0UL, // PN = 0
        2,
        sHsPlainLen,
        coalescedDatagram[coalescedLen .. $],
        sHsPnOff,
        sHsHdrLen
    ) == WireError.none);

    coalescedDatagram[coalescedLen + sHsHdrLen .. coalescedLen + sHsHdrLen + sHsPlainLen] = sHsPlaintext[0 .. sHsPlainLen];
    size_t sHsProtLen = 0;
    assert(protectPacket(serverHsKeys.writeKeys, 0UL, sHsPnOff, 2, coalescedDatagram[coalescedLen .. $], sHsPlainLen, sHsProtLen) == QuicCryptoError.none);
    coalescedLen += sHsProtLen;

    // 7. Client processes Coalesced Datagram using CoalescedPacketIterator
    CoalescedPacketIterator cSplitter = CoalescedPacketIterator(coalescedDatagram[0 .. coalescedLen], clientScid.len);
    const(ubyte)[] sPktSlice1;
    PacketPrefix sPktPref1;
    WireError splitErr;
    assert(cSplitter.next(sPktSlice1, sPktPref1, splitErr));
    assert(sPktPref1.type == PacketType.initial);

    // Unprotect Server Initial
    ubyte[8192] cUnprotBuf;
    cUnprotBuf[0 .. sPktSlice1.length] = sPktSlice1[];
    size_t cDecPnLen1 = 0;
    ulong cDecPn1 = 0;
    size_t cDecPayOff1 = 0;
    size_t cDecPlainLen1 = 0;
    assert(unprotectPacket(clientInitRead, sPktPref1.pnOffset, 0, cUnprotBuf[0 .. sPktSlice1.length], cDecPnLen1, cDecPn1, cDecPayOff1, cDecPlainLen1) == QuicCryptoError.none);

    FrameIterator cIter1 = FrameIterator(cUnprotBuf[cDecPayOff1 .. cDecPayOff1 + cDecPlainLen1], PacketType.initial);
    Frame cF1;
    assert(cIter1.next(cF1, splitErr, sTe1));
    assert(cF1.type == FrameType.ack);
    Frame cF2;
    assert(cIter1.next(cF2, splitErr, sTe1));
    assert(cF2.type == FrameType.crypto);
    assert(clientSession.readHandshake(EncryptionLevel.initial, cF2.crypto.data) == QuicCryptoError.none);

    // Client polls Handshake keys
    TlsSession.LevelKeys clientHsKeys;
    assert(clientSession.pollNextKeys(clientHsKeys));
    assert(clientHsKeys.level == EncryptionLevel.handshake);

    // Second packet in coalesced datagram is Server Handshake
    const(ubyte)[] sPktSlice2;
    PacketPrefix sPktPref2;
    assert(cSplitter.next(sPktSlice2, sPktPref2, splitErr));
    assert(sPktPref2.type == PacketType.handshake);
    assert(cSplitter.empty);

    cUnprotBuf[0 .. sPktSlice2.length] = sPktSlice2[];
    size_t cDecPnLen2 = 0;
    ulong cDecPn2 = 0;
    size_t cDecPayOff2 = 0;
    size_t cDecPlainLen2 = 0;
    assert(unprotectPacket(clientHsKeys.readKeys, sPktPref2.pnOffset, 0, cUnprotBuf[0 .. sPktSlice2.length], cDecPnLen2, cDecPn2, cDecPayOff2, cDecPlainLen2) == QuicCryptoError.none);

    FrameIterator cIter2 = FrameIterator(cUnprotBuf[cDecPayOff2 .. cDecPayOff2 + cDecPlainLen2], PacketType.handshake);
    Frame cF3;
    assert(cIter2.next(cF3, splitErr, sTe1));
    assert(cF3.type == FrameType.crypto);
    assert(clientSession.readHandshake(EncryptionLevel.handshake, cF3.crypto.data) == QuicCryptoError.none);

    // Client decodes server transport parameters
    TransportParameters cDecodedPeerTp;
    assert(decodeTransportParams(clientSession.peerTransportParams, Side.server, cDecodedPeerTp, sTe1) == WireError.none);
    assert(cDecodedPeerTp.initialMaxData == 20_000_000);
    assert(cDecodedPeerTp.initialMaxStreamsBidi == 200);
    assert(clientSession.isHandshakeComplete);

    // Client polls 1-RTT keys
    TlsSession.LevelKeys client1RttKeys;
    assert(clientSession.pollNextKeys(client1RttKeys));
    assert(client1RttKeys.level == EncryptionLevel.oneRtt);

    // 8. Flight 3: Client Finished to Server
    ubyte[1024] cHsFlightBuf;
    const clientFinished = clientSession.writeHandshake(EncryptionLevel.handshake, cHsFlightBuf);
    assert(clientFinished.length > 0);

    Frame cFinFrame;
    cFinFrame.type = FrameType.crypto;
    cFinFrame.crypto.offset = 0;
    cFinFrame.crypto.data = clientFinished;

    ubyte[512] cFinPlaintext;
    size_t cFinPlainLen = 0;
    assert(encodeFrame(cFinFrame, cFinPlaintext[], cFinPlainLen) == WireError.none);

    ubyte[512] cFinPacketBuf;
    size_t cFinPnOff = 0;
    size_t cFinHdrLen = 0;
    assert(encodeLongHeader(
        PacketType.handshake,
        QUIC_VERSION_1,
        clientDcid,
        clientScid,
        null,
        1UL, // PN = 1
        2,
        cFinPlainLen,
        cFinPacketBuf[],
        cFinPnOff,
        cFinHdrLen
    ) == WireError.none);

    cFinPacketBuf[cFinHdrLen .. cFinHdrLen + cFinPlainLen] = cFinPlaintext[0 .. cFinPlainLen];
    size_t cFinProtLen = 0;
    assert(protectPacket(clientHsKeys.writeKeys, 1UL, cFinPnOff, 2, cFinPacketBuf[], cFinPlainLen, cFinProtLen) == QuicCryptoError.none);

    // Server receives and unprotects Client Finished
    PacketPrefix sFinPref;
    assert(parsePacketPrefix(cFinPacketBuf[0 .. cFinProtLen], 0, sFinPref) == WireError.none);
    size_t sFinDecPnLen; ulong sFinDecPn; size_t sFinPayOff; size_t sFinPlainLen;
    assert(unprotectPacket(serverHsKeys.readKeys, sFinPref.pnOffset, 0, cFinPacketBuf[0 .. cFinProtLen], sFinDecPnLen, sFinDecPn, sFinPayOff, sFinPlainLen) == QuicCryptoError.none);

    FrameIterator sFinIter = FrameIterator(cFinPacketBuf[sFinPayOff .. sFinPayOff + sFinPlainLen], PacketType.handshake);
    Frame sFinF;
    assert(sFinIter.next(sFinF, splitErr, sTe1));
    assert(sFinF.type == FrameType.crypto);
    assert(serverSession.readHandshake(EncryptionLevel.handshake, sFinF.crypto.data) == QuicCryptoError.none);

    assert(serverSession.isHandshakeComplete);

    // Server polls 1-RTT keys
    TlsSession.LevelKeys server1RttKeys;
    assert(serverSession.pollNextKeys(server1RttKeys));
    assert(server1RttKeys.level == EncryptionLevel.oneRtt);

    // 9. 1-RTT Short Header Packet Exchange with STREAM frame
    Frame streamMsg;
    streamMsg.type = FrameType.stream;
    streamMsg.stream.streamId = 4;
    streamMsg.stream.hasOffset = false;
    streamMsg.stream.hasLength = true;
    streamMsg.stream.fin = true;
    streamMsg.stream.data = cast(const(ubyte)[]) "Hello from QUIC 1-RTT!";

    ubyte[128] streamPayloadBuf;
    size_t streamPayloadLen = 0;
    assert(encodeFrame(streamMsg, streamPayloadBuf[], streamPayloadLen) == WireError.none);

    ubyte[256] oneRttPktBuf;
    size_t oneRttPnOff = 0;
    size_t oneRttHdrLen = 0;
    assert(encodeShortHeader(
        clientScid,
        0UL,   // PN = 0
        1,     // PN len = 1
        false, // keyPhase = 0
        false, // spinBit = 0
        oneRttPktBuf[],
        oneRttPnOff,
        oneRttHdrLen
    ) == WireError.none);

    oneRttPktBuf[oneRttHdrLen .. oneRttHdrLen + streamPayloadLen] = streamPayloadBuf[0 .. streamPayloadLen];
    size_t oneRttProtLen = 0;
    assert(protectPacket(server1RttKeys.writeKeys, 0UL, oneRttPnOff, 1, oneRttPktBuf[], streamPayloadLen, oneRttProtLen) == QuicCryptoError.none);

    // Client receives, parses, unprotects, and validates 1-RTT Short Header packet
    PacketPrefix cOneRttPref;
    assert(parsePacketPrefix(oneRttPktBuf[0 .. oneRttProtLen], clientScid.len, cOneRttPref) == WireError.none);
    assert(cOneRttPref.type == PacketType.oneRttShort);

    size_t cOneRttDecPnLen; ulong cOneRttDecPn; size_t cOneRttPayOff; size_t cOneRttPlainLen;
    assert(unprotectPacket(client1RttKeys.readKeys, cOneRttPref.pnOffset, 0, oneRttPktBuf[0 .. oneRttProtLen], cOneRttDecPnLen, cOneRttDecPn, cOneRttPayOff, cOneRttPlainLen) == QuicCryptoError.none);
    assert(cOneRttDecPn == 0UL);
    assert(cOneRttDecPnLen == 1);

    DecodedPacketHeader cOneRttHdr;
    assert(completeHeaderAfterUnprotect(oneRttPktBuf[0 .. cOneRttPayOff + cOneRttPlainLen], cOneRttPref, 0, cOneRttHdr, sTe1) == WireError.none);
    assert(cOneRttHdr.packetNumber == 0UL);
    assert(cOneRttHdr.keyPhase == false);

    FrameIterator cOneRttIter = FrameIterator(oneRttPktBuf[cOneRttPayOff .. cOneRttPayOff + cOneRttPlainLen], PacketType.oneRttShort);
    Frame cRecvStream;
    assert(cOneRttIter.next(cRecvStream, splitErr, sTe1));
    assert(cRecvStream.type == FrameType.stream);
    assert(cRecvStream.stream.streamId == 4);
    assert(cRecvStream.stream.data == cast(const(ubyte)[]) "Hello from QUIC 1-RTT!");
    assert(cRecvStream.stream.fin == true);
    assert(cOneRttIter.empty);
}
