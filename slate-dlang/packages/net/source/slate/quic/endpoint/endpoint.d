module slate.quic.endpoint.endpoint;

/**
 * QUIC Server Endpoint Connection Router (RFC 9000 Section 6, 8.1, 10.3 & 14.1).
 *
 * Implements a Sans-I/O connection multiplexer and packet dispatcher supporting:
 * - Version Negotiation packet emission for unknown QUIC versions
 * - Stateless Retry token emission and validation (zero-allocation defense against DoS)
 * - Stateless Reset packet emission for unrecognized Short Header packets
 * - Coalesced packet routing across multiple concurrent QuicConnection instances
 */

import slate.quic.crypto.tls_session : TlsContext;
import slate.quic.crypto.aead : computeRetryIntegrityTag;
import slate.quic.wire.cid : ConnectionId, StatelessResetToken, TransportErrorCode;
import slate.quic.wire.packet : PacketType, PacketPrefix, parsePacketPrefix,
    encodeVersionNegotiationPacket, encodeRetryPacket, QUIC_VERSION_1, WireError;
import slate.quic.wire.transport_params : TransportParameters;
import slate.quic.crypto.kdf : Side;
import slate.quic.connection.connection : QuicConnection, ConnectionState;
import slate.quic.endpoint.token : SocketAddr, RetryTokenPayload, RetryTokenCodec;

/**
 * Slot holding a managed server QuicConnection entry.
 */
public struct ConnectionSlot
{
    bool active;
    SocketAddr peerAddr;
    /// The connection ID this endpoint chose (always `SERVER_CID_LEN` bytes, RFC 9000 Section 5.1).
    ConnectionId localCid;
    /// DCID of the client's current Initial (the client-chosen one, or the Retry SCID); routes
    /// long header packets only, never short headers (RFC 9000 Section 7.2).
    ConnectionId origDcid;
    /// When the slot was allocated; orders half-open slots for eviction (R-19).
    ulong createdMicros;
    QuicConnection conn;
}

/// Smallest datagram that can carry a client Initial (RFC 9000 Section 14.1); datagrams
/// shorter than this never elicit a Version Negotiation packet (R-19).
private enum size_t MIN_VN_TRIGGER_DATAGRAM = 1200;

/// Length of every connection ID this endpoint issues. One fixed length lets an unmatched short
/// header packet be parsed without any per-connection state, and lets the static-key stateless
/// reset token cover the whole CID (RFC 9000 Section 10.3.2: the same token MUST NOT serve
/// multiple connection IDs).
public enum size_t SERVER_CID_LEN = 16;

/// Smallest DCID a client may put in its first Initial (RFC 9000 Section 7.2).
private enum size_t MIN_CLIENT_INITIAL_DCID_LEN = 8;

/// Most half-open (still handshaking) connections one remote host may hold at once. Initials
/// beyond it are dropped, so a single source cannot fill the table (RFC 9000 Section 8.1). A
/// "host" is an IPv4 address or the /64 prefix of an IPv6 address (see `hostKeyOf`).
public enum size_t MAX_HALF_OPEN_PER_HOST = 8;

/// A connection that is still handshaking this long after its slot was allocated is closed and
/// its slot reclaimed, whether or not its address was validated and whatever idle timeout the
/// transport parameters negotiate (including none). The clock starts when the slot is allocated
/// and is not restarted by further Initial packets. 10 s is several multiples of a handshake over
/// a slow path (three flights plus loss recovery) while still bounding how long a peer that never
/// finishes can hold a slot (RFC 9000 Section 8.1, Section 10.1).
public enum ulong HANDSHAKE_TIMEOUT_MICROS = 10_000_000;

/// Lifetime of a Retry token; also how long its nonce must be remembered.
public enum ulong RETRY_TOKEN_LIFETIME_MICROS = 30_000_000;

/// Spent Retry nonces remembered for replay detection. A nonce is forgotten once its token has
/// expired; if the memory is full of live entries the oldest is overwritten and every nonce up to
/// it is refused from then on (`m_retryNonceFloor`), so a replay is never accepted, at worst a
/// slow client has to request a new Retry under extreme admission rates.
public enum size_t RETRY_NONCE_MEMORY = 128;

/// Stateless Resets one remote host may trigger in a burst, and how often a token comes back.
/// RFC 9000 Section 10.3.3: "An endpoint can remember the number of Stateless Resets that it has
/// sent and stop generating new Stateless Resets once a limit is reached. Using separate limits
/// for different remote addresses will ensure that Stateless Resets can be used to close
/// connections when other peers or connections have exhausted limits."
public enum uint STATELESS_RESET_BURST = 8;
/// ditto
public enum ulong STATELESS_RESET_REFILL_MICROS = 100_000;
/// Stateless Resets the whole endpoint may send in a burst (spoofed sources cannot dodge the
/// per-host limit by cycling addresses), refilled at the same rate.
public enum uint STATELESS_RESET_GLOBAL_BURST = 64;
/// ditto; tokens return ten times as fast as for one host, so one host (limited to one token per
/// `STATELESS_RESET_REFILL_MICROS`) can only ever use a tenth of the endpoint-wide rate.
public enum ulong STATELESS_RESET_GLOBAL_REFILL_MICROS = STATELESS_RESET_REFILL_MICROS / 10;
static assert(STATELESS_RESET_GLOBAL_REFILL_MICROS * 10 <= STATELESS_RESET_REFILL_MICROS);
private enum size_t RESET_BUCKETS = 64;

/// A token bucket.
private struct TokenBucket
{
    uint tokens;
    ulong lastMicros;

    /// Takes one token if available, after refilling for the time elapsed since `lastMicros`.
    bool take(ulong nowMicros, uint burst, ulong refillMicros) @safe pure @nogc nothrow
    {
        if (nowMicros > lastMicros)
        {
            const ulong add = (nowMicros - lastMicros) / refillMicros;
            if (add > 0)
            {
                tokens = (add >= burst - tokens) ? burst : cast(uint)(tokens + add);
                lastMicros += add * refillMicros;
            }
        }
        if (tokens == 0)
            return false;
        tokens--;
        return true;
    }
}

/// Per-host Stateless Reset bucket.
private struct HostResetBucket
{
    bool used;
    HostKey key;
    TokenBucket bucket;
}

/// What counts as one remote host for per-host limits.
private struct HostKey
{
    bool isIpv6;
    ubyte[8] bytes;
}

/// The host of an address: without the port (a spoofing peer varies ports freely); an IPv6
/// address by its /64 prefix, since one subscriber is routinely assigned a whole /64 and could
/// otherwise rotate through 2^64 addresses; an IPv4-mapped IPv6 address (::ffff:a.b.c.d) by its
/// IPv4 address, so the same machine cannot appear as two hosts.
private HostKey hostKeyOf(const ref SocketAddr a) @safe pure @nogc nothrow
{
    HostKey k;
    if (!a.isIpv6)
    {
        k.bytes[0 .. 4] = a.ip[0 .. 4];
        return k;
    }
    const bool mapped = a.ip[0 .. 10] == (ubyte[10]).init && a.ip[10] == 0xff && a.ip[11] == 0xff;
    if (mapped)
    {
        k.bytes[0 .. 4] = a.ip[12 .. 16];
        return k;
    }
    k.isIpv6 = true;
    k.bytes[] = a.ip[0 .. 8];
    return k;
}

/// True for a connection that is still handshaking past `HANDSHAKE_TIMEOUT_MICROS`.
private bool handshakeExpired(const ref ConnectionSlot slot, ulong nowMicros) @safe pure @nogc nothrow
{
    return slot.active && slot.conn.state == ConnectionState.handshaking
        && nowMicros > slot.createdMicros
        && nowMicros - slot.createdMicros >= HANDSHAKE_TIMEOUT_MICROS;
}

/**
 * Sans-I/O Server QuicEndpoint routing datagrams to QuicConnection state machines.
 */
public struct QuicEndpoint
{
    @disable this(this);

private:
    ConnectionSlot* m_slots;
    size_t m_capacity;
    /// Slots allocated: one more than `m_capacity`, the spare stages a new connection while the
    /// slot it will replace is still intact (R-19).
    @property size_t m_physical() const @safe pure @nogc nothrow
    {
        return m_capacity == 0 ? 0 : m_capacity + 1;
    }

    /// Half-open slot to evict once the connection staged in the spare slot is admitted.
    ConnectionSlot* m_stagedVictim;
    size_t m_activeCount;
    TlsContext* m_tlsCtx;
    TransportParameters m_serverParams;
    RetryTokenCodec m_tokenCodec;
    bool m_requireRetry;
    ubyte[32] m_resetKey;
    uint[4] m_supportedVersions;
    size_t m_numSupportedVersions;
    ulong m_retryNonceCounter;
    ulong[RETRY_NONCE_MEMORY] m_usedRetryNonces;
    /// When each remembered nonce's token expires; 0 marks an unused entry.
    ulong[RETRY_NONCE_MEMORY] m_usedRetryExpiry;
    ulong m_retryNonceFloor;
    size_t m_nextPollIndex;
    size_t m_evictedCount;
    size_t m_resetTokensComputed;
    HostResetBucket[RESET_BUCKETS] m_resetBuckets;
    TokenBucket m_globalReset;
    bool m_globalResetInit;

public:
     ~this() @trusted @nogc nothrow
    {
        cleanup();
    }

    void cleanup() @trusted @nogc nothrow
    {
        if (m_slots !is null)
        {
            foreach (i; 0 .. m_physical)
            {
                if (m_slots[i].active)
                {
                    m_slots[i].conn.cleanup();
                    m_slots[i].active = false;
                }
            }
            import core.stdc.stdlib : free;

            free(m_slots);
            m_slots = null;
        }
        m_activeCount = 0;
        m_capacity = 0;
        m_stagedVictim = null;
        m_tokenCodec.cleanup();
        m_tlsCtx = null;
        m_resetKey[] = 0;
        m_retryNonceFloor = 0;
        m_nextPollIndex = 0;
        m_evictedCount = 0;
        m_resetTokensComputed = 0;
        m_retryNonceCounter = 0;
        m_resetBuckets = (HostResetBucket[RESET_BUCKETS]).init;
        m_globalReset = TokenBucket.init;
        m_globalResetInit = false;
        m_usedRetryNonces[] = 0;
        m_usedRetryExpiry[] = 0;
    }

    void moveFrom(ref QuicEndpoint other) @trusted @nogc nothrow
    {
        if (&this == &other)
            return;

        cleanup();

        this.m_slots = other.m_slots;
        this.m_capacity = other.m_capacity;
        this.m_activeCount = other.m_activeCount;
        this.m_tlsCtx = other.m_tlsCtx;
        this.m_serverParams = other.m_serverParams;
        this.m_tokenCodec.moveFrom(other.m_tokenCodec);
        this.m_requireRetry = other.m_requireRetry;
        this.m_resetKey = other.m_resetKey;
        this.m_supportedVersions = other.m_supportedVersions;
        this.m_numSupportedVersions = other.m_numSupportedVersions;
        this.m_retryNonceCounter = other.m_retryNonceCounter;
        this.m_usedRetryNonces = other.m_usedRetryNonces;
        this.m_usedRetryExpiry = other.m_usedRetryExpiry;
        this.m_retryNonceFloor = other.m_retryNonceFloor;
        this.m_nextPollIndex = other.m_nextPollIndex;
        this.m_evictedCount = other.m_evictedCount;
        this.m_resetTokensComputed = other.m_resetTokensComputed;
        this.m_resetBuckets = other.m_resetBuckets;
        this.m_globalReset = other.m_globalReset;
        this.m_globalResetInit = other.m_globalResetInit;

        other.m_slots = null;
        other.m_capacity = 0;
        other.m_activeCount = 0;
        other.m_tlsCtx = null;
        other.m_retryNonceCounter = 0;
        other.m_retryNonceFloor = 0;
        other.m_nextPollIndex = 0;
        other.m_evictedCount = 0;
        other.m_resetTokensComputed = 0;
        other.m_resetBuckets = (HostResetBucket[RESET_BUCKETS]).init;
        other.m_globalReset = TokenBucket.init;
        other.m_globalResetInit = false;
        other.m_resetKey[] = 0;
        other.m_usedRetryNonces[] = 0;
        other.m_usedRetryExpiry[] = 0;
    }

    /**
     * Initializes the server QuicEndpoint with TLS context, transport parameters,
     * Retry token codec secrets and connection capacity. A random static key is generated for
     * the per-connection stateless reset tokens (RFC 9000 Section 10.3.2); if the random
     * generator fails the endpoint stays unusable (`capacity == 0`).
     */
    void init(ref TlsContext tlsCtx, ref const TransportParameters params,
            const ref ubyte[32] tokenSecret, const ref ubyte[12] tokenIv,
            bool requireRetry = false, size_t capacity = 128) @trusted @nogc nothrow
    {
        cleanup();

        import core.stdc.stdlib : calloc;

        m_capacity = (capacity > 0) ? capacity : 128;
        m_slots = cast(ConnectionSlot*) calloc(m_physical, ConnectionSlot.sizeof);
        if (m_slots is null)
            return;

        m_tlsCtx = &tlsCtx;
        m_serverParams = params;
        m_tokenCodec.init(tokenSecret, tokenIv);
        m_requireRetry = requireRetry;
        m_activeCount = 0;
        m_nextPollIndex = 0;

        import slate.quic.crypto.c_openssl : RAND_bytes;

        // The static reset key must be unpredictable (Section 10.3.2); never run without it.
        if (RAND_bytes(m_resetKey.ptr, cast(int) m_resetKey.length) != 1)
        {
            cleanup();
            return;
        }
        // The Retry nonce counter starts at a random point in the lower half of the range, so it
        // cannot wrap within any realistic uptime (a wrap would reuse an AEAD nonce).
        if (RAND_bytes(cast(ubyte*)&m_retryNonceCounter, ulong.sizeof) != 1)
        {
            cleanup();
            return;
        }
        m_retryNonceCounter &= long.max;

        m_supportedVersions[0] = QUIC_VERSION_1;
        m_numSupportedVersions = 1;
    }

    @property size_t connectionCount() const @safe pure @nogc nothrow
    {
        return m_activeCount;
    }

    @property size_t capacity() const @safe pure @nogc nothrow
    {
        return m_capacity;
    }

    /**
     * Connections evicted to make room for a newer one (R-19). Every `QuicConnection*` obtained
     * earlier (`handleDatagram`'s `matchedConn`, `findConnection`, `slots`) refers to a slot, not
     * to a connection: once its connection is evicted, closed and reaped, or the slot is
     * reused, the pointer designates a different connection or none. Callers must look the
     * connection up again by CID or address instead of holding the pointer across calls; this
     * counter changes whenever an eviction has happened.
     *
     * The same holds for a handshaking connection that outlives `HANDSHAKE_TIMEOUT_MICROS`:
     * its slot is reclaimed by `onTimeout` or by the next admission without being counted here
     * (reclaiming an expired slot is not an eviction), so the pointer of a handshaking
     * connection must also be looked up again after that deadline. Idle timeout: a connection
     * that negotiated `max_idle_timeout = 0` on both sides has no idle timeout and an
     * established one then lives until it is closed explicitly, as RFC 9000 Section 10.1 allows;
     * the endpoint adds no default of its own, set a non-zero `maxIdleTimeout` in the transport
     * parameters to bound it.
     */
    @property size_t evictedCount() const @safe pure @nogc nothrow
    {
        return m_evictedCount;
    }

    /// The counter the next Retry token's nonce is derived from (random start, below 2^63).
    package @property ulong retryNonceCounter() const @safe pure @nogc nothrow
    {
        return m_retryNonceCounter;
    }

    /// Stateless Reset tokens derived for unmatched short-header packets. A packet refused by
    /// the rate limit does not count: the limit is checked before the HMAC is computed.
    @property size_t resetTokensComputed() const @safe pure @nogc nothrow
    {
        return m_resetTokensComputed;
    }

    /// Takes one Stateless Reset token for `peerAddr` from its per-host bucket and from the
    /// endpoint-wide bucket (RFC 9000 Section 10.3.3). False means the limit is reached.
    package bool allowStatelessReset(const ref SocketAddr peerAddr, ulong nowMicros) @safe @nogc nothrow
    {
        const HostKey host = hostKeyOf(peerAddr);
        size_t hbIdx = RESET_BUCKETS;
        size_t oldestIdx = 0;
        foreach (i; 0 .. RESET_BUCKETS)
        {
            const b = &m_resetBuckets[i];
            if (b.used && b.key == host)
            {
                hbIdx = i;
                break;
            }
            const o = &m_resetBuckets[oldestIdx];
            if ((!b.used && o.used) || (b.used == o.used && b.bucket.lastMicros
                    < o.bucket.lastMicros))
                oldestIdx = i;
        }
        if (hbIdx == RESET_BUCKETS)
        {
            hbIdx = oldestIdx;
            m_resetBuckets[hbIdx] = HostResetBucket(true, host,
                    TokenBucket(STATELESS_RESET_BURST, nowMicros));
        }
        auto hb = &m_resetBuckets[hbIdx];
        if (!m_globalResetInit)
        {
            m_globalReset = TokenBucket(STATELESS_RESET_GLOBAL_BURST, nowMicros);
            m_globalResetInit = true;
        }
        if (!hb.bucket.take(nowMicros, STATELESS_RESET_BURST, STATELESS_RESET_REFILL_MICROS))
            return false;
        if (!m_globalReset.take(nowMicros, STATELESS_RESET_GLOBAL_BURST,
                STATELESS_RESET_GLOBAL_REFILL_MICROS))
        {
            hb.bucket.tokens++; // the host did not get its reset: give its token back
            return false;
        }
        return true;
    }

    @property bool requireRetry() const @safe pure @nogc nothrow
    {
        return m_requireRetry;
    }

    @property void requireRetry(bool req) @safe pure @nogc nothrow
    {
        m_requireRetry = req;
    }

    /**
     * Derives the stateless reset token of connection ID `cid`:
     * `HMAC-SHA256(staticKey, cid)[0 .. 16]` (RFC 9000 Section 10.3.2) over the whole CID.
     * Only `SERVER_CID_LEN`-byte CIDs, the ones this endpoint issues, get a token. Returns false
     * for any other length, when the endpoint is not initialised or HMAC fails; `token` is then
     * all zero.
     */
    bool statelessResetTokenFor(const ConnectionId cid, out StatelessResetToken token) const @trusted @nogc nothrow
    {
        import slate.quic.crypto.c_openssl : HMAC, EVP_sha256;

        if (m_slots is null || cid.len != SERVER_CID_LEN)
            return false;
        const(ubyte)[] bytes = cid.asSlice();

        ubyte[32] mac;
        uint macLen = 0;
        if (HMAC(EVP_sha256(), m_resetKey.ptr, cast(int) m_resetKey.length,
                bytes.ptr, bytes.length, mac.ptr, &macLen) is null || macLen < token.length)
            return false;
        token[] = mac[0 .. token.length];
        return true;
    }

    /**
     * Finds active connection by server's local connection ID.
     */
    QuicConnection* findConnection(const ref ConnectionId cid) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return null;

        foreach (ref slot; m_slots[0 .. m_physical])
        {
            if (slot.active && slot.localCid == cid)
            {
                return &slot.conn;
            }
        }
        return null;
    }

    /**
     * Finds active connection by client's SocketAddr.
     */
    QuicConnection* findConnectionByPeer(const ref SocketAddr peerAddr) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return null;

        foreach (ref slot; m_slots[0 .. m_physical])
        {
            if (slot.active && slot.peerAddr == peerAddr)
            {
                return &slot.conn;
            }
        }
        return null;
    }

    /**
     * Returns the slice of connection slots managed by this endpoint.
     */
    @property ConnectionSlot[] slots() return @trusted @nogc nothrow pure
    {
        if (m_slots is null || m_physical == 0)
            return null;
        return m_slots[0 .. m_physical];
    }

    /**
     * Explicitly closes and deallocates a connection by connection ID.
     */
    void closeConnection(const ref ConnectionId cid) @trusted @nogc nothrow
    {
        deallocateSlot(cid);
    }

    /**
     * Advances timers across all active connections and cleans up expired connections.
     */
    void onTimeout(ulong nowMicros) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return;

        foreach (ref slot; m_slots[0 .. m_physical])
        {
            if (slot.active)
            {
                slot.conn.onTimeout(nowMicros);
                if (slot.conn.state == ConnectionState.closed || handshakeExpired(slot, nowMicros))
                {
                    slot.conn.cleanup();
                    slot.active = false;
                    slot.localCid = ConnectionId.init;
                    slot.origDcid = ConnectionId.init;
                    m_activeCount--;
                }
            }
        }
    }

    /**
     * Ingests an incoming UDP datagram from peerAddr.
     *
     * Handles Version Negotiation, Stateless Retry, Stateless Reset, and connection routing.
     */
    TransportErrorCode handleDatagram(const ref SocketAddr peerAddr, const(ubyte)[] datagram, ulong nowMicros,
            ubyte[] outResponse, out size_t responseLen, out QuicConnection* matchedConn) @trusted @nogc nothrow
    {
        responseLen = 0;
        matchedConn = null;

        if (datagram.length == 0)
            return TransportErrorCode.noError;

        const bool isLong = (datagram[0] & 0x80) != 0;

        // 1. Universal Long Header Version Negotiation (RFC 9000 Section 6 & 17.2)
        if (isLong && datagram.length >= MIN_VN_TRIGGER_DATAGRAM)
        {
            const uint ver = (cast(uint) datagram[1] << 24) | (cast(
                    uint) datagram[2] << 16) | (cast(uint) datagram[3] << 8) | cast(uint) datagram[4];

            if (ver != 0) // 0 is Version Negotiation itself
            {
                bool versionSupported = false;
                foreach (i; 0 .. m_numSupportedVersions)
                {
                    if (ver == m_supportedVersions[i])
                    {
                        versionSupported = true;
                        break;
                    }
                }

                if (!versionSupported)
                {
                    // RFC 8999 Section 5.1: an unknown version may carry connection IDs of up to
                    // 255 bytes; they are echoed back as they came, not limited to the 20 bytes
                    // of version 1 (only a version 1 packet with a longer CID is dropped).
                    const size_t dcidLen = datagram[5];
                    if (datagram.length >= 6 + dcidLen + 1)
                    {
                        const size_t scidOff = 6 + dcidLen;
                        const size_t scidLen = datagram[scidOff];
                        if (datagram.length >= scidOff + 1 + scidLen)
                        {
                            const err = encodeVersionNegotiationPacket(datagram[scidOff + 1 .. scidOff + 1 + scidLen],
                                    datagram[6 .. 6 + dcidLen],
                                    m_supportedVersions[0 .. m_numSupportedVersions],
                                    outResponse, responseLen);
                            return (err == WireError.none) ? TransportErrorCode.noError
                                : TransportErrorCode.internalError;
                        }
                    }
                    return TransportErrorCode.noError;
                }
            }
        }

        if (!isLong)
        {
            // Route Short Header on the fixed-length CID this endpoint issued, exact match only:
            // a prefix match would let a short CID capture other connections' packets.
            if (m_slots !is null && datagram.length >= 1 + SERVER_CID_LEN)
            {
                foreach (ref slot; m_slots[0 .. m_physical])
                {
                    if (slot.active && datagram[1 .. 1 + SERVER_CID_LEN] == slot.localCid.asSlice())
                    {
                        matchedConn = &slot.conn;
                        return slot.conn.handleDatagram(datagram, nowMicros);
                    }
                }
            }

            // 3. Unmatched Short Header (RFC 9000 Section 10.3: Stateless Reset) (F-25). The reset
            // must be smaller than the packet that triggered it, which also ends reset loops.
            if (datagram.length >= 44 && outResponse.length >= 43)
            {
                import slate.quic.crypto.c_openssl : RAND_bytes;

                const size_t resetLen = 43;
                StatelessResetToken token;
                const ConnectionId pktDcid = ConnectionId(datagram[1 .. 1 + SERVER_CID_LEN]);
                // The rate limit comes first: a packet that is not answered must not cost an
                // HMAC, or a flood of unmatched packets becomes a CPU lever (Section 10.3.3).
                if (!allowStatelessReset(peerAddr, nowMicros))
                    return TransportErrorCode.noError; // limit reached (RFC 9000 Section 10.3.3)
                m_resetTokensComputed++;
                if (!statelessResetTokenFor(pktDcid, token))
                    return TransportErrorCode.noError;
                outResponse[0] = 0x40 | 0x1a; // Short header with Fixed bit = 1
                if (RAND_bytes(outResponse.ptr + 1, resetLen - 17) != 1)
                    return TransportErrorCode.internalError;
                outResponse[resetLen - 16 .. resetLen] = token[];
                responseLen = resetLen;
            }
            return TransportErrorCode.noError;
        }

        PacketPrefix prefix;
        const parseErr = parsePacketPrefix(datagram, 8, prefix);
        if (parseErr != WireError.none)
            return TransportErrorCode.noError;

        // 2. Route Long Header to existing active connection
        if (m_slots !is null)
        {
            foreach (ref slot; m_slots[0 .. m_physical])
            {
                if (slot.active)
                {
                    // The client's original DCID is only valid on long headers until the handshake
                    // is confirmed; Initials keep it so a replayed one never spawns a connection.
                    if (slot.localCid == prefix.dcid || (slot.origDcid == prefix.dcid
                            && (prefix.type == PacketType.initial || !slot.conn.handshakeConfirmed)))
                    {
                        matchedConn = &slot.conn;
                        return slot.conn.handleDatagram(datagram, nowMicros);
                    }
                }
            }
        }

        // 4. Client Initial Packet (RFC 9000 Section 14.1 & Section 17.2)
        if (prefix.type == PacketType.initial)
        {
            // Drop undersized Client Initial (< 1200 bytes) silently
            if (datagram.length < 1200)
                return TransportErrorCode.noError;

            // RFC 9000 Section 7.2: the client's DCID MUST be at least 8 bytes; drop silently.
            if (prefix.dcid.len < MIN_CLIENT_INITIAL_DCID_LEN)
                return TransportErrorCode.noError;

            if (m_requireRetry)
            {
                // 4a. Client Initial without Retry Token -> Emit Stateless Retry (RFC 9000 §8.1.2)
                if (prefix.token.length == 0)
                {
                    m_retryNonceCounter++;
                    // The Retry SCID is 16 random bytes: it must not be predictable from the
                    // client address or from the token counter (RFC 9000 Section 5.1).
                    import slate.quic.crypto.c_openssl : RAND_bytes;

                    ubyte[SERVER_CID_LEN] retryScidBytes;
                    if (RAND_bytes(retryScidBytes.ptr, cast(int) retryScidBytes.length) != 1)
                        return TransportErrorCode.internalError;
                    ConnectionId retryScid = ConnectionId(retryScidBytes[]);

                    RetryTokenPayload rPayload;
                    rPayload.clientAddr = peerAddr;
                    rPayload.origDcid = prefix.dcid;
                    rPayload.retryScid = retryScid;
                    rPayload.issuedMicros = nowMicros;

                    ubyte[128] tokenBuf;
                    size_t tokenLen = 0;
                    if (!m_tokenCodec.sealToken(rPayload, m_retryNonceCounter,
                            tokenBuf[], tokenLen))
                        return TransportErrorCode.internalError;

                    ubyte[16] dummyTag;
                    if (encodeRetryPacket(QUIC_VERSION_1, prefix.scid, retryScid,
                            tokenBuf[0 .. tokenLen], dummyTag, outResponse, responseLen) != WireError
                            .none)
                    {
                        return TransportErrorCode.internalError;
                    }

                    // Compute and place RFC 9001 Section 5.8 Retry Integrity Tag
                    ubyte[16] tag;
                    computeRetryIntegrityTag(prefix.dcid.asSlice(),
                            outResponse[0 .. responseLen - 16], tag);
                    outResponse[responseLen - 16 .. responseLen] = tag[];
                    return TransportErrorCode.noError; // 0 connection state allocated!
                }

                // 4b. Client Initial with Retry Token -> Verify Token (RFC 9000 §8.1.3)
                RetryTokenPayload verified;
                const vErr = m_tokenCodec.verifyToken(prefix.token, peerAddr,
                        prefix.dcid, nowMicros, RETRY_TOKEN_LIFETIME_MICROS, verified);
                if (vErr != TransportErrorCode.noError)
                {
                    return vErr;
                }

                // Check for token replay (F-13)
                if (isRetryNonceUsed(verified.nonceCounter, nowMicros))
                    return TransportErrorCode.invalidToken;
                // The nonce is recorded by `admitClientInitial` once the Initial decrypts, so a
                // corrupted first Initial does not burn a valid token.
                return admitClientInitial(peerAddr, datagram, prefix, nowMicros, true,
                        verified.origDcid, &verified.retryScid, matchedConn,
                        &verified.nonceCounter);
            }

            // Normal Client Initial without Retry
            return admitClientInitial(peerAddr, datagram, prefix, nowMicros,
                    false, prefix.dcid, null, matchedConn);
        }

        return TransportErrorCode.noError;
    }

    /**
     * Polls pending outgoing transmissions across all active connections.
     */
    bool pollTransmit(out SocketAddr outPeerAddr, ubyte[] outDatagram,
            ulong nowMicros, out size_t bytesWritten) @trusted @nogc nothrow
    {
        outPeerAddr = SocketAddr.init;
        bytesWritten = 0;

        if (m_slots is null || outDatagram.length == 0 || m_physical == 0)
            return false;

        const size_t startIdx = m_nextPollIndex % m_physical;
        foreach (step; 0 .. m_physical)
        {
            const size_t idx = (startIdx + step) % m_physical;
            ref ConnectionSlot slot = m_slots[idx];
            if (slot.active)
            {
                if (slot.conn.pollTransmit(outDatagram, nowMicros, bytesWritten))
                {
                    outPeerAddr = slot.peerAddr;
                    m_nextPollIndex = (idx + 1) % m_physical;
                    return true;
                }
            }
        }

        return false;
    }

private:
    /// Picks a fresh random `SERVER_CID_LEN`-byte connection ID that no live slot uses.
    bool chooseServerCid(out ConnectionId cid) @trusted @nogc nothrow
    {
        import slate.quic.crypto.c_openssl : RAND_bytes;

        foreach (attempt; 0 .. 8)
        {
            ubyte[SERVER_CID_LEN] raw;
            if (RAND_bytes(raw.ptr, cast(int) raw.length) != 1)
                return false;
            const candidate = ConnectionId(raw[]);
            bool inUse = false;
            foreach (ref slot; m_slots[0 .. m_physical])
                if (slot.active && slot.localCid == candidate)
                    inUse = true;
            if (!inUse)
            {
                cid = candidate;
                return true;
            }
        }
        return false;
    }

    /// Whether a Retry token with this nonce was already spent (RFC 9000 Section 8.1.3), or is
    /// older than the nonces the bounded memory can still vouch for.
    package bool isRetryNonceUsed(ulong nonce, ulong nowMicros) const @safe pure @nogc nothrow
    {
        if (nonce <= m_retryNonceFloor)
            return true;
        foreach (i; 0 .. RETRY_NONCE_MEMORY)
            if (m_usedRetryExpiry[i] >= nowMicros && m_usedRetryNonces[i] == nonce)
                return true;
        return false;
    }

    /// Remembers a spent nonce until its token expires. Expired and unused entries are reused
    /// first; when every entry is live the oldest is overwritten and the floor rises to it.
    package void recordRetryNonce(ulong nonce, ulong nowMicros) @safe pure @nogc nothrow
    {
        size_t idx = 0;
        foreach (i; 0 .. RETRY_NONCE_MEMORY)
        {
            if (m_usedRetryExpiry[i] <= nowMicros)
            {
                idx = i;
                goto store;
            }
            if (m_usedRetryExpiry[i] < m_usedRetryExpiry[idx])
                idx = i;
        }
        // Every entry is live: the oldest one is forgotten, so refuse everything up to it.
        if (m_usedRetryNonces[idx] > m_retryNonceFloor)
            m_retryNonceFloor = m_usedRetryNonces[idx];
    store:
        m_usedRetryNonces[idx] = nonce;
        m_usedRetryExpiry[idx] = nowMicros + RETRY_TOKEN_LIFETIME_MICROS;
    }

    /// Admits a client Initial that passed Retry policy: the Initial must decrypt under the
    /// Initial keys before any state is touched. That check is not authentication: the Initial keys
    /// derive from the public DCID, so anyone can produce a decryptable Initial; `requireRetry`
    /// (address validation) is the real mitigation against Initial floods. `retryNonce`, when
    /// given, is recorded as used only after the decrypt check passes (so an undecryptable one cannot evict a legit
    /// half-open connection), then a slot is allocated under a server-chosen CID (RFC 9000
    /// Section 7.2) that is sent as SCID and advertised as `initial_source_connection_id`.
    TransportErrorCode admitClientInitial(const ref SocketAddr peerAddr,
            const(ubyte)[] datagram, ref const PacketPrefix prefix,
            ulong nowMicros, bool addressValidated, const ConnectionId originalDcid,
            const(ConnectionId)* retryScid, out QuicConnection* matchedConn,
            const(ulong)* retryNonce = null) @trusted @nogc nothrow
    {
        matchedConn = null;
        if (!QuicConnection.clientInitialDecrypts(datagram, prefix, prefix.dcid.asSlice()))
            return TransportErrorCode.noError;

        // One host cannot hold more than a few half-open slots (RFC 9000 Section 8.1). At the
        // cap the host's oldest half-open slot whose address is still unvalidated makes room
        // for the new Initial (it is staged and evicted only once the new Initial is admitted),
        // so spoofed Initials from a victim's address cannot lock the victim out. When every
        // half-open slot of the host is validated, the Initial is dropped.
        const HostKey host = hostKeyOf(peerAddr);
        size_t halfOpenOfHost = 0;
        ConnectionSlot* hostVictim = null;
        foreach (ref slot; m_slots[0 .. m_physical])
        {
            if (slot.active && slot.conn.state == ConnectionState.handshaking
                    && !handshakeExpired(slot, nowMicros) && hostKeyOf(slot.peerAddr) == host)
            {
                halfOpenOfHost++;
                if (!slot.conn.peerAddressValidated && (hostVictim is null
                        || slot.createdMicros < hostVictim.createdMicros))
                    hostVictim = &slot;
            }
        }
        if (halfOpenOfHost >= MAX_HALF_OPEN_PER_HOST)
        {
            if (hostVictim is null)
                return TransportErrorCode.noError;
        }
        else
            hostVictim = null;

        ConnectionId serverCid;
        if (!chooseServerCid(serverCid))
            return TransportErrorCode.internalError;

        TransportParameters tp = m_serverParams;
        tp.hasOriginalDestinationConnectionId = true;
        tp.originalDestinationConnectionId = originalDcid;
        if (retryScid !is null)
        {
            tp.hasRetrySourceConnectionId = true;
            tp.retrySourceConnectionId = *retryScid;
        }
        tp.hasInitialSourceConnectionId = true;
        tp.initialSourceConnectionId = serverCid;
        // Advertise the reset token of the server CID only (Section 18.2, 10.3.2).
        tp.hasStatelessResetToken = statelessResetTokenFor(serverCid, tp.statelessResetToken);
        if (!tp.hasStatelessResetToken)
            return TransportErrorCode.internalError;

        QuicConnection* newConn = allocateSlot(peerAddr, serverCid,
                prefix.dcid, nowMicros, hostVictim);
        if (newConn is null)
            return TransportErrorCode.internalError;

        if (!QuicConnection.create(Side.server, *m_tlsCtx, serverCid,
                ConnectionId.init, tp, nowMicros, *newConn, addressValidated,
                null, "h3", null, prefix.dcid))
        {
            abortStaged();
            deallocateSlot(serverCid);
            return TransportErrorCode.internalError;
        }

        const err = newConn.handleDatagram(datagram, nowMicros);
        if (err != TransportErrorCode.noError || newConn.ackRanges[0].empty)
        {
            abortStaged();
            deallocateSlot(serverCid);
            return err;
        }
        commitStaged();

        // The Retry token is spent only now that its connection is admitted: a token whose
        // Initial was refused (no slot, bad parameters) stays usable for a retry.
        if (retryNonce !is null)
        {
            recordRetryNonce(*retryNonce, nowMicros);
        }

        matchedConn = newConn;
        return err;
    }

    package QuicConnection* allocateSlot(const ref SocketAddr peerAddr, const ref ConnectionId localCid,
            const ref ConnectionId origDcid, ulong nowMicros, ConnectionSlot* hostVictim = null) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return null;

        // 1. First pass: find an inactive slot (the spare one is only staging space, step 3)
        foreach (ref slot; m_slots[0 .. m_physical])
        {
            if (m_activeCount >= m_capacity)
                break;
            if (!slot.active)
            {
                slot.active = true;
                slot.peerAddr = peerAddr;
                slot.localCid = localCid;
                slot.origDcid = origDcid;
                slot.createdMicros = nowMicros;
                m_activeCount++;
                m_stagedVictim = hostVictim;
                return &slot.conn;
            }
        }

        // 2. Second pass: reclaim closed or expired draining connections (F-25, D-09)
        foreach (ref slot; m_slots[0 .. m_physical])
        {
            if (slot.active && (slot.conn.state == ConnectionState.closed
                    || handshakeExpired(slot, nowMicros) || (slot.conn.state == ConnectionState.draining
                    && nowMicros >= slot.conn.drainingEndTimeMicros)))
            {
                slot.conn.cleanup();
                slot.active = true;
                slot.peerAddr = peerAddr;
                slot.localCid = localCid;
                slot.origDcid = origDcid;
                slot.createdMicros = nowMicros;
                m_stagedVictim = hostVictim;
                return &slot.conn;
            }
        }

        // 3. Table full of live connections: evict the oldest half-open slot whose peer address
        // is still unvalidated, so spoofed Initials cannot pin the table (R-19, RFC 9000
        // Section 8.1). Without one, the oldest address-validated half-open slot goes: a peer
        // that validated its address (a Retry token, or a Handshake packet) but never finishes
        // must not hold a slot forever either. Established and closing connections are never
        // evicted.
        ConnectionSlot* victim = null;
        ConnectionSlot* validatedVictim = null;
        foreach (ref slot; m_slots[0 .. m_physical])
        {
            if (!slot.active || slot.conn.state != ConnectionState.handshaking)
                continue;
            ConnectionSlot** best = slot.conn.peerAddressValidated ? &validatedVictim : &victim;
            if (*best is null || slot.createdMicros < (*best).createdMicros)
                *best = &slot;
        }
        if (victim is null)
            victim = validatedVictim;
        if (hostVictim !is null)
            victim = hostVictim; // the per-host cap names its own victim
        if (victim !is null && m_stagedVictim is null)
        {
            // The victim stays intact until the new connection is admitted (commitStaged), so
            // an Initial that decrypts but is then refused evicts nobody.
            foreach (ref slot; m_slots[0 .. m_physical])
            {
                if (!slot.active)
                {
                    slot.active = true;
                    slot.peerAddr = peerAddr;
                    slot.localCid = localCid;
                    slot.origDcid = origDcid;
                    slot.createdMicros = nowMicros;
                    m_activeCount++;
                    m_stagedVictim = victim;
                    return &slot.conn;
                }
            }
        }

        return null;
    }

    /// Admits the connection staged by `allocateSlot`: the half-open slot it displaces is evicted.
    package void commitStaged() @trusted @nogc nothrow
    {
        if (m_stagedVictim is null)
            return;
        m_evictedCount++;
        m_stagedVictim.conn.cleanup();
        m_stagedVictim.active = false;
        m_stagedVictim.localCid = ConnectionId.init;
        m_stagedVictim.origDcid = ConnectionId.init;
        m_activeCount--;
        m_stagedVictim = null;
    }

    /// Drops the staged connection's claim on its victim (the staged slot itself is released
    /// with `deallocateSlot`).
    package void abortStaged() @safe @nogc nothrow
    {
        m_stagedVictim = null;
    }

    package void deallocateSlot(const ref ConnectionId localCid) @trusted @nogc nothrow
    {
        if (m_slots is null)
            return;

        foreach (ref slot; m_slots[0 .. m_physical])
        {
            if (slot.active && slot.localCid == localCid)
            {
                slot.conn.cleanup();
                slot.active = false;
                slot.localCid = ConnectionId.init;
                slot.origDcid = ConnectionId.init;
                m_activeCount--;
                return;
            }
        }
    }
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x01;
/// const ubyte[12] tokenIv = 0x02;
/// QuicEndpoint endpoint;
/// endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 16);
/// const SocketAddr clientAddr = SocketAddr.ipv4(127, 0, 0, 1, 44333);
/// const ubyte[8] dcidBytes = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
/// const ubyte[8] scidBytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11];
/// ubyte[1200] unknownVerPacket;                    // long header, version 0x1a2a3a4a
/// unknownVerPacket[0] = 0xc0;
/// unknownVerPacket[1 .. 5] = [0x1a, 0x2a, 0x3a, 0x4a];
/// unknownVerPacket[5] = 8;
/// unknownVerPacket[6 .. 14] = dcidBytes[];
/// unknownVerPacket[14] = 8;
/// unknownVerPacket[15 .. 23] = scidBytes[];
/// ubyte[1500] respBuf;
/// size_t respLen;
/// QuicConnection* matched;
/// endpoint.handleDatagram(clientAddr, unknownVerPacket[], 1_000_000, respBuf[], respLen, matched);
/// PacketPrefix vnPrefix;
/// assert(parsePacketPrefix(respBuf[0 .. respLen], 8, vnPrefix) == WireError.none);
/// assert(vnPrefix.type == PacketType.versionNegotiation);
/// assert(vnPrefix.dcid == ConnectionId(scidBytes[]) && vnPrefix.scid == ConnectionId(dcidBytes[]));
/// assert(endpoint.connectionCount == 0);           // no state was created
/// ---
// Spec: RFC 9000 Section 6 - Version Negotiation Packet Routing (covers U1, U2, U3, E4)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    TlsContext serverCtx = makeServerCtx();
    assert(serverCtx.isValid);

    TransportParameters tp;
    tp.initialMaxData = 10_000_000;

    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

    QuicEndpoint endpoint;
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 16);
    assert(endpoint.capacity == 16);
    assert(endpoint.connectionCount == 0);

    const SocketAddr clientAddr = SocketAddr.ipv4(127, 0, 0, 1, 44333);
    const ubyte[8] dcidBytes = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88];
    const ubyte[8] scidBytes = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11];
    ConnectionId dcid = ConnectionId(dcidBytes[]);
    ConnectionId scid = ConnectionId(scidBytes[]);

    // Packet with unsupported version 0x1a2a3a4a
    ubyte[1200] unknownVerPacket;
    unknownVerPacket[0] = 0xc0; // Long header
    unknownVerPacket[1] = 0x1a;
    unknownVerPacket[2] = 0x2a;
    unknownVerPacket[3] = 0x3a;
    unknownVerPacket[4] = 0x4a; // Version
    unknownVerPacket[5] = 8;
    unknownVerPacket[6 .. 14] = dcidBytes[];
    unknownVerPacket[14] = 8;
    unknownVerPacket[15 .. 23] = scidBytes[];

    ubyte[1500] respBuf;
    size_t respLen = 0;
    QuicConnection* matched = null;
    assert(endpoint.handleDatagram(clientAddr, unknownVerPacket[], 1_000_000,
            respBuf[], respLen, matched) == TransportErrorCode.noError);
    assert(matched is null);
    assert(respLen > 0);

    // Verify response is Version Negotiation packet
    PacketPrefix vnPrefix;
    assert(parsePacketPrefix(respBuf[0 .. respLen], 8, vnPrefix) == WireError.none);
    assert(vnPrefix.type == PacketType.versionNegotiation);
    assert(vnPrefix.dcid == scid);
    assert(vnPrefix.scid == dcid);
    assert(endpoint.connectionCount == 0);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x13;
/// const ubyte[12] tokenIv = 0x31;
/// QuicEndpoint endpoint;
/// endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
/// const SocketAddr addr = SocketAddr.ipv4(127, 0, 0, 1, 40001);
/// // unknown version, 40-byte DCID and 30-byte SCID
/// ubyte[1200] pkt;
/// pkt[0] = 0xc0;
/// pkt[1 .. 5] = 0x1a;
/// pkt[5] = 40;
/// pkt[6 .. 46] = 0x80;
/// pkt[46] = 30;
/// pkt[47 .. 77] = 0x40;
/// ubyte[1500] resp;
/// size_t respLen;
/// QuicConnection* m;
/// assert(endpoint.handleDatagram(addr, pkt[], 1_000_000, resp[], respLen, m) == TransportErrorCode.noError);
/// // Version Negotiation echoes both IDs, swapped
/// assert(respLen == 7 + 30 + 40 + 4 && resp[5] == 30 && resp[6 + 30] == 40);
/// ---
// Spec: RFC 8999 Section 5.1 "The Destination Connection ID field follows
// the Destination Connection ID Length field and is between 0 and 255 bytes in length." and
// Section 6 "A QUIC endpoint that receives a packet with a long header and a version it either
// does not understand or does not support might send a Version Negotiation packet in response."
// - the IDs (up to 255 bytes) are echoed back; only a version 1 packet with a CID longer than 20
// bytes is dropped (RFC 9000 Section 17.2) (R-42, W24)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    TlsContext serverCtx = makeServerCtx();
    assert(serverCtx.isValid);
    TransportParameters tp;
    const ubyte[32] tokenSecret = 0x13;
    const ubyte[12] tokenIv = 0x31;
    QuicEndpoint endpoint;
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 4);
    const SocketAddr addr = SocketAddr.ipv4(127, 0, 0, 1, 40001);

    ubyte[1200] pkt;
    ubyte[1500] resp;
    size_t respLen;
    QuicConnection* matched;

    // Unknown version with 40-byte DCID and 30-byte SCID.
    pkt[0] = 0xc0;
    pkt[1 .. 5] = 0x1a;
    pkt[5] = 40;
    foreach (i; 0 .. 40)
        pkt[6 + i] = cast(ubyte)(0x80 + i);
    pkt[46] = 30;
    foreach (i; 0 .. 30)
        pkt[47 + i] = cast(ubyte)(0x20 + i);
    assert(endpoint.handleDatagram(addr, pkt[], 1_000_000, resp[], respLen,
            matched) == TransportErrorCode.noError);
    assert(respLen == 7 + 30 + 40 + 4, "a Version Negotiation echoing both IDs is sent");
    assert(resp[4] == 0 && resp[1] == 0 && resp[2] == 0 && resp[3] == 0, "version field is zero");
    assert(resp[5] == 30, "DCID of the reply is the client's SCID");
    foreach (i; 0 .. 30)
        assert(resp[6 + i] == 0x20 + i);
    assert(resp[36] == 40, "SCID of the reply is the client's DCID");
    foreach (i; 0 .. 40)
        assert(resp[37 + i] == 0x80 + i);
    assert(resp[77] == 0 && resp[78] == 0 && resp[79] == 0 && resp[80] == 1, "offers version 1");

    // Largest IDs the 8-bit length fields allow.
    pkt = 0;
    pkt[0] = 0xc0;
    pkt[1 .. 5] = 0x1a;
    pkt[5] = 255;
    pkt[6 .. 261] = 0xd1;
    pkt[261] = 255;
    pkt[262 .. 517] = 0x5c;
    respLen = 0;
    assert(endpoint.handleDatagram(addr, pkt[], 1_000_001, resp[], respLen,
            matched) == TransportErrorCode.noError);
    assert(respLen == 7 + 255 + 255 + 4);
    assert(resp[5] == 255 && resp[6] == 0x5c && resp[261] == 255 && resp[262] == 0xd1);

    // Still only for datagrams of at least 1200 bytes (amplification, RFC 9000 Section 6.1).
    respLen = 0;
    assert(endpoint.handleDatagram(addr, pkt[0 .. 1199], 1_000_002, resp[],
            respLen, matched) == TransportErrorCode.noError);
    assert(respLen == 0);

    // Version 1 with a 21-byte DCID is dropped, without a reply.
    pkt = 0;
    pkt[0] = 0xc0;
    pkt[4] = 1;
    pkt[5] = 21;
    respLen = 0;
    assert(endpoint.handleDatagram(addr, pkt[], 1_000_004, resp[], respLen,
            matched) == TransportErrorCode.noError);
    assert(respLen == 0 && endpoint.connectionCount == 0);
}

/// Example:
/// ---
/// TlsContext serverCtx = TlsContext.createServer("test/fixtures/quic_cert.pem", "test/fixtures/quic_key.pem");
/// TransportParameters tp;
/// const ubyte[32] tokenSecret = 0x21;
/// const ubyte[12] tokenIv = 0x12;
/// QuicEndpoint endpoint;
/// endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 16);
/// const SocketAddr clientAddr = SocketAddr.ipv4(10, 0, 0, 5, 54321);
/// ubyte[50] unknownShortPkt;                       // a short header packet for an unknown connection
/// unknownShortPkt[0] = 0x40;
/// unknownShortPkt[1 .. 17] = 0x77;
/// ubyte[1500] respBuf;
/// size_t respLen;
/// QuicConnection* matched;
/// endpoint.handleDatagram(clientAddr, unknownShortPkt[], 1_000_000, respBuf[], respLen, matched);
/// assert((respBuf[0] & 0x40) != 0);                // a Stateless Reset has the fixed bit set
/// StatelessResetToken expected;
/// assert(endpoint.statelessResetTokenFor(ConnectionId(unknownShortPkt[1 .. 17]), expected));
/// assert(respBuf[respLen - 16 .. respLen] == expected[]);
/// ---
// Spec: RFC 9000 Section 10.3 - Stateless Reset Emission for Unrecognized Short Header (covers U1, U2, U3, E4)
@nogc unittest
{
    auto makeServerCtx = () @trusted @nogc nothrow{
        alias ServerFn = TlsContext function(const(char)[], const(char)[]) @nogc nothrow;
        return (cast(ServerFn)&TlsContext.createServer)("test/fixtures/quic_cert.pem",
                "test/fixtures/quic_key.pem");
    };
    TlsContext serverCtx = makeServerCtx();
    assert(serverCtx.isValid);

    TransportParameters tp;
    const ubyte[32] tokenSecret = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32
    ];
    const ubyte[12] tokenIv = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

    QuicEndpoint endpoint;
    endpoint.init(serverCtx, tp, tokenSecret, tokenIv, false, 16);

    const SocketAddr clientAddr = SocketAddr.ipv4(10, 0, 0, 5, 54321);

    // Unrecognized Short Header packet of length 50 (>= 43)
    ubyte[50] unknownShortPkt;
    unknownShortPkt[0] = 0x40; // Short header (Header form = 0, Fixed bit = 1)
    unknownShortPkt[1 .. 17] = 0x77; // Unknown DCID (16 bytes, the length this endpoint issues)

    ubyte[1500] respBuf;
    size_t respLen = 0;
    QuicConnection* matched = null;
    assert(endpoint.handleDatagram(clientAddr, unknownShortPkt[], 1_000_000,
            respBuf[], respLen, matched) == TransportErrorCode.noError);
    assert(matched is null);
    assert(respLen >= 43, "Stateless Reset must be at least 43 bytes");
    assert((respBuf[0] & 0x80) == 0, "Stateless Reset must be short header form");
    assert((respBuf[0] & 0x40) != 0, "Stateless Reset must have fixed bit 1");

    // The last 16 bytes must be the token derived for the packet's Destination Connection ID
    StatelessResetToken expected;
    assert(endpoint.statelessResetTokenFor(ConnectionId(unknownShortPkt[1 .. 17]), expected));
    assert(respBuf[respLen - 16 .. respLen] == expected[]);
}
