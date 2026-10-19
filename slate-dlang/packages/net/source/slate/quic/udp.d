module slate.quic.udp;

/**
 * Non-blocking OS UDP Socket Driver for Sans-I/O QuicConnection and QuicEndpoint.
 *
 * Encapsulates POSIX SOCK_DGRAM non-blocking I/O, monotonic microsecond clock,
 * and bounded packet drain loops while keeping QuicConnection and QuicEndpoint
 * 100% Sans-I/O.
 */

import slate.quic.endpoint.token : SocketAddr;
import slate.quic.connection.connection : QuicConnection, ConnectionState;
import slate.quic.endpoint.endpoint : QuicEndpoint;

version (Posix)
{
    private import core.sys.posix.sys.socket : socket, bind, getsockname, recvfrom, sendto,
        setsockopt, sockaddr, sockaddr_storage, socklen_t, AF_INET, AF_INET6,
        SOCK_DGRAM, SOL_SOCKET, SO_REUSEADDR, ssize_t, recvmsg, msghdr, MSG_TRUNC;
    private import core.sys.posix.sys.uio : iovec;
    private import core.sys.posix.netinet.in_ : sockaddr_in, sockaddr_in6, htons, ntohs;
    private import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
    private import core.sys.posix.unistd : posixClose = close, usleep;
    private import core.sys.posix.time : clock_gettime, CLOCK_MONOTONIC, timespec;
    private import core.stdc.errno : errno, EAGAIN, EWOULDBLOCK, EINTR;
}

public enum size_t MAX_UDP_PACKETS_PER_PUMP = 256;
public enum size_t MAX_UDP_DATAGRAM_BYTES = 2048;

/// `recvFrom` result: a datagram larger than the buffer arrived and was discarded (MSG_TRUNC).
public enum ptrdiff_t UDP_RECV_TRUNCATED = -2;
/// `recvFrom` result: a zero-length datagram arrived; it carries nothing and is skipped.
public enum ptrdiff_t UDP_RECV_EMPTY = -3;

/**
 * Returns the current OS monotonic clock timestamp in microseconds.
 */
public ulong monotonicMicros() @trusted @nogc nothrow
{
    version (Posix)
    {
        timespec ts;
        if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
        {
            return cast(ulong) ts.tv_sec * 1_000_000UL + cast(ulong)(ts.tv_nsec / 1000);
        }
    }
    return 0;
}

/**
 * RAII non-blocking UDP socket wrapper for QUIC datagram transport.
 */
public struct QuicUdpSocket
{
    @disable this(this);

private:
    int m_fd = -1;
    bool m_isIpv6 = false;
    size_t m_truncatedDrops;
    size_t m_emptyDrops;
    size_t m_recvErrors;
    size_t m_sendErrors;
    size_t m_sendBlocked;

    version (Posix)
    {
        static void toSockaddr(const ref SocketAddr addr, out sockaddr_storage ss,
                out socklen_t ssLen) @trusted pure @nogc nothrow
        {
            ss = sockaddr_storage.init;
            if (addr.isIpv6)
            {
                sockaddr_in6* sin6 = cast(sockaddr_in6*)&ss;
                sin6.sin6_family = AF_INET6;
                sin6.sin6_port = htons(addr.port);
                sin6.sin6_addr.s6_addr[0 .. 16] = addr.ip[0 .. 16];
                ssLen = cast(socklen_t) sockaddr_in6.sizeof;
            }
            else
            {
                sockaddr_in* sin = cast(sockaddr_in*)&ss;
                sin.sin_family = AF_INET;
                sin.sin_port = htons(addr.port);
                ubyte* ipDst = cast(ubyte*)&sin.sin_addr.s_addr;
                ipDst[0 .. 4] = addr.ip[0 .. 4];
                ssLen = cast(socklen_t) sockaddr_in.sizeof;
            }
        }

        static bool fromSockaddr(const ref sockaddr_storage ss, socklen_t ssLen,
                out SocketAddr outAddr) @trusted pure @nogc nothrow
        {
            outAddr = SocketAddr.init;
            if (ss.ss_family == AF_INET && ssLen >= sockaddr_in.sizeof)
            {
                const(sockaddr_in)* sin = cast(const(sockaddr_in)*)&ss;
                const(ubyte)* ipSrc = cast(const(ubyte)*)&sin.sin_addr.s_addr;
                outAddr = SocketAddr.ipv4(ipSrc[0], ipSrc[1], ipSrc[2],
                        ipSrc[3], ntohs(sin.sin_port));
                return true;
            }
            else if (ss.ss_family == AF_INET6 && ssLen >= sockaddr_in6.sizeof)
            {
                const(sockaddr_in6)* sin6 = cast(const(sockaddr_in6)*)&ss;
                outAddr = SocketAddr.ipv6(sin6.sin6_addr.s6_addr, ntohs(sin6.sin6_port));
                return true;
            }
            return false;
        }
    }

public:
     ~this() @trusted @nogc nothrow
    {
        close();
    }

    void close() @trusted @nogc nothrow
    {
        version (Posix)
        {
            if (m_fd >= 0)
            {
                posixClose(m_fd);
                m_fd = -1;
            }
        }
        else
        {
            m_fd = -1;
        }
        m_isIpv6 = false;
    }

    void cleanup() @trusted @nogc nothrow
    {
        close();
    }

    void moveFrom(ref QuicUdpSocket other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;
        close();
        m_fd = other.m_fd;
        m_isIpv6 = other.m_isIpv6;
        m_truncatedDrops = other.m_truncatedDrops;
        m_emptyDrops = other.m_emptyDrops;
        m_recvErrors = other.m_recvErrors;
        m_sendErrors = other.m_sendErrors;
        m_sendBlocked = other.m_sendBlocked;
        other.m_fd = -1;
        other.m_isIpv6 = false;
        other.m_truncatedDrops = other.m_emptyDrops = other.m_recvErrors = 0;
        other.m_sendErrors = other.m_sendBlocked = 0;
    }

    /// Datagrams dropped because they exceeded the receive buffer (MSG_TRUNC).
    @property size_t truncatedDrops() const @safe pure @nogc nothrow
    {
        return m_truncatedDrops;
    }

    /// Zero-length datagrams skipped.
    @property size_t emptyDrops() const @safe pure @nogc nothrow
    {
        return m_emptyDrops;
    }

    /// Receive calls that failed with a socket error (not EAGAIN).
    @property size_t recvErrors() const @safe pure @nogc nothrow
    {
        return m_recvErrors;
    }

    /// Sends that failed with a socket error; the datagram was not transmitted.
    @property size_t sendErrors() const @safe pure @nogc nothrow
    {
        return m_sendErrors;
    }

    /// Sends refused because the socket buffer was full (EAGAIN); the datagram was not sent.
    @property size_t sendBlocked() const @safe pure @nogc nothrow
    {
        return m_sendBlocked;
    }

    @property bool isOpen() const @safe pure @nogc nothrow
    {
        return m_fd >= 0;
    }

    @property int fd() const @safe pure @nogc nothrow
    {
        return m_fd;
    }

    /**
     * Binds a non-blocking UDP socket to the given IPv4 or IPv6 SocketAddr.
     */
    bool bind(const ref SocketAddr bindAddr) @trusted @nogc nothrow
    {
        close();
        version (Posix)
        {
            const int domain = bindAddr.isIpv6 ? AF_INET6 : AF_INET;
            const int sockFd = socket(domain, SOCK_DGRAM, 0);
            if (sockFd < 0)
                return false;

            const int flags = fcntl(sockFd, F_GETFL, 0);
            if (flags < 0 || fcntl(sockFd, F_SETFL, flags | O_NONBLOCK) < 0)
            {
                posixClose(sockFd);
                return false;
            }

            if (bindAddr.port != 0)
            {
                int reuse = 1;
                setsockopt(sockFd, SOL_SOCKET, SO_REUSEADDR, &reuse, cast(socklen_t) int.sizeof);
            }

            sockaddr_storage ss;
            socklen_t ssLen = 0;
            toSockaddr(bindAddr, ss, ssLen);

            if (.bind(sockFd, cast(const(sockaddr)*)&ss, ssLen) != 0)
            {
                posixClose(sockFd);
                return false;
            }

            m_fd = sockFd;
            m_isIpv6 = bindAddr.isIpv6;
            return true;
        }
        else
        {
            return false;
        }
    }

    /**
     * Convenience helper to bind an IPv4 UDP socket.
     */
    bool bindIpv4(ubyte a, ubyte b, ubyte c, ubyte d, ushort port) @trusted @nogc nothrow
    {
        const SocketAddr addr = SocketAddr.ipv4(a, b, c, d, port);
        return bind(addr);
    }

    /**
     * Queries the bound local address and ephemeral port via getsockname.
     */
    SocketAddr localAddr() const @trusted @nogc nothrow
    {
        if (m_fd < 0)
            return SocketAddr.init;

        version (Posix)
        {
            sockaddr_storage ss;
            socklen_t ssLen = cast(socklen_t) sockaddr_storage.sizeof;
            if (getsockname(m_fd, cast(sockaddr*)&ss, &ssLen) != 0)
                return SocketAddr.init;

            SocketAddr addr;
            if (fromSockaddr(ss, ssLen, addr))
                return addr;
        }
        return SocketAddr.init;
    }

    /**
     * Receives a single UDP datagram in non-blocking mode.
     *
     * Returns:
     *   > 0 : number of bytes received
     *     0 : no datagram available (EAGAIN / EWOULDBLOCK / EINTR)
     *    `UDP_RECV_TRUNCATED` : the datagram did not fit `buf` and was discarded (MSG_TRUNC)
     *    `UDP_RECV_EMPTY` : a zero-length datagram, nothing to process
     *    -1 : socket error (counted in `recvErrors`)
     */
    ptrdiff_t recvFrom(ubyte[] buf, out SocketAddr peerAddr) @trusted @nogc nothrow
    {
        peerAddr = SocketAddr.init;
        if (m_fd < 0 || buf.length == 0)
            return -1;

        version (Posix)
        {
            sockaddr_storage ss;
            iovec iov;
            iov.iov_base = buf.ptr;
            iov.iov_len = buf.length;
            msghdr msg;
            msg.msg_name = &ss;
            msg.msg_namelen = cast(socklen_t) sockaddr_storage.sizeof;
            msg.msg_iov = &iov;
            msg.msg_iovlen = 1;
            const ssize_t n = recvmsg(m_fd, &msg, 0);
            if (n < 0)
            {
                const int err = errno;
                if (err == EAGAIN || err == EWOULDBLOCK || err == EINTR)
                    return 0;
                m_recvErrors++;
                return -1;
            }
            // The kernel cut the datagram to the buffer: the rest is gone, so what is left is
            // not a datagram the peer sent and must not reach the QUIC layer.
            if ((msg.msg_flags & MSG_TRUNC) != 0)
            {
                m_truncatedDrops++;
                return UDP_RECV_TRUNCATED;
            }
            if (n == 0)
            {
                m_emptyDrops++;
                return UDP_RECV_EMPTY;
            }
            fromSockaddr(ss, msg.msg_namelen, peerAddr);
            return cast(ptrdiff_t) n;
        }
        else
        {
            return -1;
        }
    }

    /**
     * Sends a single UDP datagram to peerAddr in non-blocking mode.
     *
     * Returns:
     *   > 0 : number of bytes transmitted
     *     0 : socket send buffer full (EAGAIN / EWOULDBLOCK, counted in `sendBlocked`)
     *   < 0 : socket error (counted in `sendErrors`)
     */
    ptrdiff_t sendTo(const(ubyte)[] data, const ref SocketAddr peerAddr) @trusted @nogc nothrow
    {
        if (m_fd < 0 || data.length == 0)
        {
            m_sendErrors++;
            return -1;
        }

        version (Posix)
        {
            sockaddr_storage ss;
            socklen_t ssLen = 0;
            toSockaddr(peerAddr, ss, ssLen);

            const ssize_t n = sendto(m_fd, data.ptr, data.length, 0,
                    cast(const(sockaddr)*)&ss, ssLen);
            if (n > 0)
                return cast(ptrdiff_t) n;

            const int err = errno;
            if (n == 0 || err == EAGAIN || err == EWOULDBLOCK || err == EINTR)
            {
                m_sendBlocked++;
                return 0;
            }
            m_sendErrors++;
            return -1;
        }
        else
        {
            m_sendErrors++;
            return -1;
        }
    }

    /**
     * Pumps incoming UDP datagrams, timers, and all pending outgoing packets
     * for a single QuicConnection (bounded by maxPackets per call).
     */
    size_t pumpConnection(ref QuicConnection conn, const ref SocketAddr remoteAddr,
            ulong nowMicros = 0, size_t maxPackets = MAX_UDP_PACKETS_PER_PUMP) @trusted @nogc nothrow
    {
        if (m_fd < 0)
            return 0;

        const ulong now = (nowMicros > 0) ? nowMicros : monotonicMicros();
        const size_t limit = (maxPackets > 0 && maxPackets <= MAX_UDP_PACKETS_PER_PUMP) ? maxPackets
            : MAX_UDP_PACKETS_PER_PUMP;

        size_t totalProcessed = 0;
        ubyte[MAX_UDP_DATAGRAM_BYTES] buf;

        // 1. Drain incoming UDP datagrams (verifying peer source address)
        foreach (i; 0 .. limit)
        {
            SocketAddr srcAddr;
            const ptrdiff_t n = recvFrom(buf[], srcAddr);
            if (n == UDP_RECV_TRUNCATED || n == UDP_RECV_EMPTY)
                continue; // dropped and counted: the next datagram may be fine
            if (n <= 0)
                break;

            if (remoteAddr.port != 0 && srcAddr.port != remoteAddr.port)
                continue;
            if (remoteAddr.isIpv6 != srcAddr.isIpv6)
                continue;
            if (!remoteAddr.isIpv6)
            {
                const ubyte[4] anyV4 = [0, 0, 0, 0];
                if (remoteAddr.ip[0 .. 4] != anyV4 && srcAddr.ip[0 .. 4] != remoteAddr.ip[0 .. 4])
                    continue;
            }
            else
            {
                const ubyte[16] anyV6 = 0;
                if (remoteAddr.ip != anyV6 && srcAddr.ip != remoteAddr.ip)
                    continue;
            }

            conn.handleDatagram(buf[0 .. cast(size_t) n], now);
            totalProcessed++;
        }

        // 2. Advance connection timers if deadline reached
        const ulong nextDeadline = conn.nextTimeoutMicros(now);
        if (nextDeadline > 0 && now >= nextDeadline)
        {
            conn.onTimeout(now);
        }

        // 3. Drain all pending outgoing QUIC packets
        foreach (i; 0 .. limit)
        {
            size_t txLen = 0;
            if (!conn.pollTransmit(buf[], now, txLen) || txLen == 0)
                break;
            const ptrdiff_t sent = sendTo(buf[0 .. txLen], remoteAddr);
            if (sent <= 0)
                break;
            totalProcessed++;
        }

        return totalProcessed;
    }

    /**
     * Pumps incoming UDP datagrams, stateless responses, timers, and all pending
     * outgoing connection packets for a server QuicEndpoint (bounded by maxPackets).
     */
    size_t pumpEndpoint(ref QuicEndpoint endpoint, ulong nowMicros = 0,
            size_t maxPackets = MAX_UDP_PACKETS_PER_PUMP) @trusted @nogc nothrow
    {
        if (m_fd < 0)
            return 0;

        const ulong now = (nowMicros > 0) ? nowMicros : monotonicMicros();
        const size_t limit = (maxPackets > 0 && maxPackets <= MAX_UDP_PACKETS_PER_PUMP) ? maxPackets
            : MAX_UDP_PACKETS_PER_PUMP;

        size_t totalProcessed = 0;
        ubyte[MAX_UDP_DATAGRAM_BYTES] rxBuf;
        ubyte[MAX_UDP_DATAGRAM_BYTES] txBuf;

        // 1. Drain incoming UDP datagrams and emit stateless responses (Retry / VN / Reset)
        foreach (i; 0 .. limit)
        {
            SocketAddr peerAddr;
            const ptrdiff_t n = recvFrom(rxBuf[], peerAddr);
            if (n == UDP_RECV_TRUNCATED || n == UDP_RECV_EMPTY)
                continue; // dropped and counted: the next datagram may be fine
            if (n <= 0)
                break;

            size_t respLen = 0;
            QuicConnection* matched = null;
            endpoint.handleDatagram(peerAddr, rxBuf[0 .. cast(size_t) n], now,
                    txBuf[], respLen, matched);
            totalProcessed++;

            if (respLen > 0)
            {
                sendTo(txBuf[0 .. respLen], peerAddr);
            }
        }

        // 2. Advance endpoint connection timers
        endpoint.onTimeout(now);

        // 3. Drain all pending outgoing packets across active connections
        foreach (i; 0 .. limit)
        {
            SocketAddr peerAddr;
            size_t txLen = 0;
            if (!endpoint.pollTransmit(peerAddr, txBuf[], now, txLen) || txLen == 0)
                break;
            const ptrdiff_t sent = sendTo(txBuf[0 .. txLen], peerAddr);
            if (sent == 0)
                break; // the socket buffer is full (counted in sendBlocked)
            if (sent < 0)
                continue; // this peer's send failed (counted in sendErrors); others may still go
            totalProcessed++;
        }

        return totalProcessed;
    }
}

/// Example:
/// ---
/// // two loopback sockets: a datagram sent to the receiver's address arrives with the sender's address
/// QuicUdpSocket sender, receiver;
/// assert(sender.bindIpv4(127, 0, 0, 1, 0) && receiver.bindIpv4(127, 0, 0, 1, 0));
/// const SocketAddr receiverAddr = receiver.localAddr();
/// const ubyte[4] datagram = [1, 2, 3, 4];
/// assert(sender.sendTo(datagram[], receiverAddr) == cast(ptrdiff_t) datagram.length);
/// ubyte[64] buf;
/// SocketAddr from;
/// ptrdiff_t n;
/// foreach (attempt; 0 .. 1000)           // the datagram may need a moment to arrive
///     if ((n = receiver.recvFrom(buf[], from)) != 0)
///         break;
/// assert(n == 4 && buf[0 .. 4] == datagram[]);
/// ---
// Spec: RFC 9000 Section 7, Section 14 & Scenario T2 - Real OS UDP loopback handshake (ALPN "smsp/1") and multi-datagram stream delivery (covers U2, E1, G1, G2, G5)
@nogc unittest
{
    import slate.quic.endpoint.endpoint : SERVER_CID_LEN;
    import slate.quic.crypto.kdf : Side;
    import slate.quic.crypto.tls_session : TlsContext;
    import slate.quic.wire.cid : ConnectionId, TransportErrorCode;
    import slate.quic.wire.transport_params : TransportParameters;
    import slate.quic.stream.id : StreamDirection, StreamId;

    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    auto makeClientCtx = () @trusted @nogc nothrow{
        alias ClientFn = TlsContext function() @nogc nothrow;
        return TlsContext.createClientInsecure();
    };

    TlsContext serverCtx = makeServerCtx();
    TlsContext clientCtx = makeClientCtx();
    assert(serverCtx.isValid && clientCtx.isValid);

    QuicUdpSocket serverSock;
    QuicUdpSocket clientSock;
    assert(serverSock.bindIpv4(127, 0, 0, 1, 0), "Server UDP bind on 127.0.0.1:0 must succeed");
    assert(clientSock.bindIpv4(127, 0, 0, 1, 0), "Client UDP bind on 127.0.0.1:0 must succeed");

    const SocketAddr serverAddr = serverSock.localAddr();
    const SocketAddr clientAddr = clientSock.localAddr();
    assert(serverAddr.port > 0);
    assert(clientAddr.port > 0);
    assert(serverAddr.port != clientAddr.port);

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;
    tp.initialMaxStreamDataBidiLocal = 1_000_000;
    tp.initialMaxStreamDataBidiRemote = 1_000_000;
    tp.initialMaxStreamDataUni = 1_000_000;
    tp.initialMaxStreamsBidi = 100;
    tp.initialMaxStreamsUni = 100;

    const ubyte[32] tokenSecret = 0x42;
    const ubyte[12] tokenIv = 0x24;

    QuicEndpoint serverEp;
    serverEp.init(serverCtx, tp, tokenSecret, tokenIv, false, 16);

    const ubyte[8] dcidBytes = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
    const ubyte[8] scidBytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10, 0x20];
    ConnectionId clientDcid = ConnectionId(dcidBytes[]);
    ConnectionId clientScid = ConnectionId(scidBytes[]);

    TransportParameters clientTp = tp;
    clientTp.hasInitialSourceConnectionId = true;
    clientTp.initialSourceConnectionId = clientScid;

    const ulong t0 = monotonicMicros();
    assert(t0 > 0);

    QuicConnection clientConn;
    assert(QuicConnection.create(Side.client, clientCtx, clientScid,
            clientDcid, clientTp, t0, clientConn, false, null, "smsp/1"));

    // Pump 4-flight handshake over real OS loopback UDP sockets
    foreach (step; 0 .. 16)
    {
        const ulong now = monotonicMicros();
        clientSock.pumpConnection(clientConn, serverAddr, now);
        serverSock.pumpEndpoint(serverEp, now);
        if (clientConn.handshakeConfirmed && serverEp.connectionCount == 1)
            break;
    }

    assert(clientConn.state == ConnectionState.active);
    assert(clientConn.handshakeConfirmed);
    assert(clientConn.negotiatedAlpn == "smsp/1");
    assert(serverEp.connectionCount == 1);

    // The client adopted the CID the server chose (RFC 9000 Section 7.2), not its own DCID.
    assert(clientConn.remoteCid.len == SERVER_CID_LEN && clientConn.remoteCid != clientDcid);
    QuicConnection* serverConn = serverEp.findConnection(clientConn.remoteCid);
    assert(serverConn !is null);
    assert(serverConn.state == ConnectionState.active);
    assert(serverConn.negotiatedAlpn == "smsp/1");

    // Client sends PLAY control message on bidirectional Stream 0
    StreamId ctrlSid;
    assert(clientConn.openStream(StreamDirection.bidirectional,
            ctrlSid) == TransportErrorCode.noError);
    assert(ctrlSid.id == 0);
    const(ubyte)[] playMsg = cast(const(ubyte)[]) "PLAY 720p60";
    assert(clientConn.streamWrite(ctrlSid, playMsg, false));

    // Server opens unidirectional Stream 3 and sends a 6 KiB multi-datagram GOP payload
    StreamId gopSid;
    assert(serverConn.openStream(StreamDirection.unidirectional,
            gopSid) == TransportErrorCode.noError);
    assert(gopSid.id == 3);

    ubyte[6144] largePayload;
    foreach (i; 0 .. largePayload.length)
        largePayload[i] = cast(ubyte)((i * 37 + 13) & 0xFF);
    assert(serverConn.streamWrite(gopSid, largePayload[], true));

    // Pump UDP sockets and reassemble Stream 3 on client until finReached
    ubyte[6144] reassembled;
    size_t reassembledLen = 0;
    bool gopFin = false;
    bool serverGotPlay = false;

    foreach (round; 0 .. 64)
    {
        usleep(100);
        const ulong now = monotonicMicros();
        clientSock.pumpConnection(clientConn, serverAddr, now);
        serverSock.pumpEndpoint(serverEp, now);

        if (!serverGotPlay)
        {
            ubyte[64] ctrlBuf;
            bool ctrlFin = false;
            const ptrdiff_t nCtrl = serverConn.streamRead(ctrlSid, ctrlBuf[], ctrlFin);
            if (nCtrl == cast(ptrdiff_t) playMsg.length)
            {
                assert(ctrlBuf[0 .. nCtrl] == playMsg);
                serverGotPlay = true;
            }
        }

        while (!gopFin)
        {
            ubyte[2048] chunk;
            bool fin = false;
            const ptrdiff_t n = clientConn.streamRead(gopSid, chunk[], fin);
            if (n > 0)
            {
                assert(reassembledLen + cast(size_t) n <= reassembled.length);
                reassembled[reassembledLen .. reassembledLen + cast(size_t) n] = chunk[0 .. cast(
                            size_t) n];
                reassembledLen += cast(size_t) n;
            }
            if (fin)
            {
                gopFin = true;
                break;
            }
            if (n <= 0)
                break;
        }

        if (serverGotPlay && gopFin)
            break;
    }

    assert(serverGotPlay, "Server must receive Stream 0 PLAY message over UDP");
    assert(gopFin, "Client must receive FIN on multi-datagram unidirectional Stream 3");
    assert(reassembledLen == largePayload.length, "Client must reassemble all 6144 bytes");
    assert(reassembled[] == largePayload[], "Reassembled payload must match byte-for-byte");

    // Verify off-path UDP packet from a third socket is ignored by pumpConnection ([MEDIUM-01])
    QuicUdpSocket attackerSock;
    assert(attackerSock.bindIpv4(127, 0, 0, 1, 0));
    ubyte[32] bogusDgram = 0xFF;
    assert(attackerSock.sendTo(bogusDgram[], clientAddr) == cast(ptrdiff_t) bogusDgram.length);

    const uint prevPto = serverConn.lossDetector.ptoCount;
    const ulong nowAfter = monotonicMicros();
    clientSock.pumpConnection(clientConn, serverAddr, nowAfter);
    serverSock.pumpEndpoint(serverEp, nowAfter);
    assert(clientConn.state == ConnectionState.active,
            "Off-path UDP datagram must be ignored without tearing down clientConn");
    assert(serverConn.lossDetector.ptoCount == prevPto,
            "pumpEndpoint must not increment ptoCount when no recovery timer has expired");
}

/// Example:
/// ---
/// QuicUdpSocket s1;
/// assert(s1.bindIpv4(127, 0, 0, 1, 0));
/// const ushort boundPort = s1.localAddr().port;
/// QuicUdpSocket s2;
/// s2.moveFrom(s1);                                 // the descriptor moves; the source is closed
/// assert(!s1.isOpen && s2.isOpen && s2.localAddr().port == boundPort);
/// s2.close();
/// assert(!s2.isOpen);
/// ---
// Spec: RFC 9000 Section 14 & Requirement REQ-UDP-001 (U2) - QuicUdpSocket RAII move semantics and closed-socket error handling (covers U2, G2, G5)
@nogc unittest
{
    QuicUdpSocket s1;
    assert(!s1.isOpen);
    SocketAddr dummyPeer = SocketAddr.ipv4(127, 0, 0, 1, 9999);
    ubyte[64] buf;
    assert(s1.recvFrom(buf[], dummyPeer) < 0);
    assert(s1.sendTo(buf[], dummyPeer) < 0);

    assert(s1.bindIpv4(127, 0, 0, 1, 0));
    assert(s1.isOpen);
    const ushort boundPort = s1.localAddr().port;
    assert(boundPort > 0);

    // Non-blocking recvFrom on empty socket returns 0 (EAGAIN/EWOULDBLOCK)
    assert(s1.recvFrom(buf[], dummyPeer) == 0);

    QuicUdpSocket s2;
    s2.moveFrom(s1);
    assert(!s1.isOpen);
    assert(s2.isOpen);
    assert(s2.localAddr().port == boundPort);

    s2.close();
    assert(!s2.isOpen);

    // Verify IPv6 loopback address round-trip if IPv6 is enabled on host
    const ubyte[16] ipv6Loopback = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    ];
    const SocketAddr bind6 = SocketAddr.ipv6(ipv6Loopback, 0);
    QuicUdpSocket s6;
    if (s6.bind(bind6))
    {
        const SocketAddr local6 = s6.localAddr();
        assert(local6.isIpv6);
        assert(local6.port > 0);
        assert(local6.ip == ipv6Loopback);
        s6.close();
    }
}

/// Example:
/// ---
/// QuicUdpSocket rx, tx;
/// assert(rx.bindIpv4(127, 0, 0, 1, 0) && tx.bindIpv4(127, 0, 0, 1, 0));
/// const SocketAddr rxAddr = rx.localAddr();
/// ubyte[3000] big = 0x5a;
/// assert(tx.sendTo(big[], rxAddr) == 3000);
///
/// ubyte[64] small;                       // the buffer is smaller than the datagram
/// SocketAddr peer;
/// assert(rx.recvFrom(small[], peer) == UDP_RECV_TRUNCATED);
/// assert(rx.truncatedDrops == 1);        // MSG_TRUNC was seen and the datagram dropped
/// assert(rx.recvFrom(small[], peer) == 0);   // it is consumed, not retried
/// ---
// Spec: RFC 9000 Section 14 "UDP datagrams MUST NOT be fragmented at the IP layer." and
// Section 12.2 (a datagram is delivered to QUIC whole) - the kernel silently cuts a datagram to
// the receive buffer; what is left is not what the peer sent, so a truncated datagram must be
// detected with MSG_TRUNC and discarded instead of being passed to the QUIC layer (R-40, W22)
@nogc unittest
{
    QuicUdpSocket rx, tx;
    assert(rx.bindIpv4(127, 0, 0, 1, 0) && tx.bindIpv4(127, 0, 0, 1, 0));
    const SocketAddr rxAddr = rx.localAddr();
    ubyte[3000] big = 0x5a;
    assert(tx.sendTo(big[], rxAddr) == 3000);
    ubyte[64] small;
    SocketAddr peer;
    assert(rx.recvFrom(small[], peer) == UDP_RECV_TRUNCATED);
    assert(rx.truncatedDrops == 1);
    assert(rx.recvFrom(small[], peer) == 0, "the truncated datagram is consumed, not retried");

    // A datagram that exactly fits is not truncated.
    assert(tx.sendTo(small[], rxAddr) == 64);
    assert(rx.recvFrom(small[], peer) == 64);
    assert(rx.truncatedDrops == 1);
}

/// Example:
/// ---
/// import slate.quic.crypto.tls_session : TlsContext;
/// import slate.quic.wire.transport_params : TransportParameters;
///
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x42;
/// const ubyte[12] tokenIv = 0x24;
/// QuicEndpoint ep;
/// ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
///
/// QuicUdpSocket rx, tx;
/// assert(rx.bindIpv4(127, 0, 0, 1, 0) && tx.bindIpv4(127, 0, 0, 1, 0));
/// const SocketAddr rxAddr = rx.localAddr();
/// ubyte[3000] big = 0x77;                // oversized: truncated and dropped
/// assert(tx.sendTo(big[], rxAddr) == 3000);
/// ubyte[20] junk = 0x11;                 // a real datagram behind it
/// assert(tx.sendTo(junk[], rxAddr) == 20);
///
/// assert(rx.pumpEndpoint(ep, monotonicMicros()) == 1);   // only the real one reaches the endpoint
/// assert(rx.truncatedDrops == 1);
/// ---
// Spec: RFC 9000 Section 12.2 / Section 14 - an empty or oversized datagram is a datagram like
// any other the receive loop must get past: a zero-length datagram (recvfrom returns 0) must not
// end the loop and strand the datagrams queued behind it (R-40, W22)
@nogc unittest
{
    import core.sys.posix.sys.socket : sendto, sockaddr;
    import slate.quic.crypto.tls_session : TlsContext;
    import slate.quic.wire.transport_params : TransportParameters;

    TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem",
            "test/fixtures/quic_key.pem");
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x42;
    const ubyte[12] tokenIv = 0x24;
    QuicEndpoint ep;
    ep.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);

    QuicUdpSocket rx, tx;
    assert(rx.bindIpv4(127, 0, 0, 1, 0) && tx.bindIpv4(127, 0, 0, 1, 0));
    const SocketAddr rxAddr = rx.localAddr();

    // Zero-length datagram: sendTo refuses it, so use the raw syscall.
    sockaddr_storage ss;
    socklen_t ssLen;
    QuicUdpSocket.toSockaddr(rxAddr, ss, ssLen);
    assert(sendto(tx.m_fd, null, 0, 0, cast(const(sockaddr)*)&ss, ssLen) == 0);
    ubyte[3000] big = 0x77;
    assert(tx.sendTo(big[], rxAddr) == 3000);
    ubyte[20] junk = 0x11;
    assert(tx.sendTo(junk[], rxAddr) == 20);

    const ulong now = monotonicMicros();
    assert(rx.pumpEndpoint(ep, now) == 1, "only the real datagram is handed to the endpoint");
    assert(rx.emptyDrops == 1 && rx.truncatedDrops == 1);
    ubyte[64] probe;
    SocketAddr peer;
    assert(rx.recvFrom(probe[], peer) == 0, "nothing is left queued behind the empty datagram");
}

/// Example:
/// ---
/// QuicUdpSocket tx, rx;
/// assert(tx.bindIpv4(127, 0, 0, 1, 0) && rx.bindIpv4(127, 0, 0, 1, 0));
/// const SocketAddr rxAddr = rx.localAddr();
///
/// ubyte[70_000] tooBig = 0x01;           // above the 65 507-byte UDP limit
/// assert(tx.sendTo(tooBig[], rxAddr) < 0);
/// assert(tx.sendErrors == 1 && tx.sendBlocked == 0);   // a hard error, not a full buffer
///
/// ubyte[10] ok = 0x02;
/// assert(tx.sendTo(ok[], rxAddr) == 10);
/// assert(tx.sendErrors == 1);            // a good send changes nothing
/// ---
// Spec: RFC 9000 Section 14 (datagrams are sent as UDP datagrams) - a failed send must be
// visible to the caller rather than silently dropped: the error is returned and counted, and a
// send refused by a full buffer is counted apart from a hard error (R-40, W22)
@nogc unittest
{
    QuicUdpSocket tx, rx;
    assert(tx.bindIpv4(127, 0, 0, 1, 0) && rx.bindIpv4(127, 0, 0, 1, 0));
    const SocketAddr rxAddr = rx.localAddr();
    ubyte[70_000] tooBig = 0x01;
    assert(tx.sendTo(tooBig[], rxAddr) < 0);
    assert(tx.sendErrors == 1);
    assert(tx.sendBlocked == 0);

    ubyte[10] ok = 0x02;
    assert(tx.sendTo(ok[], rxAddr) == 10);
    assert(tx.sendErrors == 1);

    // A closed socket cannot send either, and says so.
    QuicUdpSocket closed;
    assert(closed.sendTo(ok[], rxAddr) < 0 && closed.sendErrors == 1);
}
