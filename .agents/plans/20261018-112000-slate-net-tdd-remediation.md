# Implementation Plan: `slate:net` Full TDD Remediation (`slate.quic`, `slate.h3`, `slate.http`, `durl`)

| Field | Value |
|---|---|
| **Owning Project** | `slate-dlang` ([`slate-dlang/packages/net/`](../../slate-dlang/packages/net/README.md)) |
| **Status** | `implemented & verified (Round 2 APPROVED)` |
| **Revision** | `1.2` |
| **Date** | `2026-10-18` |
| **Master Tracker** | [`20261018-112000-slate-net-findings-tracker.md`](20261018-112000-slate-net-findings-tracker.md) (`F-01` – `F-70`, including Critical, High, Medium, and Low/Nit/Style) |
| **Reference Specs** | RFC 9000 (QUIC), RFC 9001 (QUIC-TLS), RFC 9002 (QUIC Recovery), RFC 9114 (HTTP/3), RFC 9204 (QPACK), RFC 9110 (HTTP Semantics) |
| **Methodology** | Strict Adversarial Test-Driven Development (`Red → Green → Iterate`): write a failing `unittest` (`// Spec:` + `/// Example:`) reproducing each defect first, verify failure, implement the minimal fix, verify green, and audit with fresh-context Reviewer & Security Auditor subagents. |

---

## 1. Goal, Scope, and Non-Goals

### 1.1 Goal
Remediate all **70** Critical, High, Medium, and Low/Nit/Style findings (`F-01` – `F-70` in [`20261018-112000-slate-net-findings-tracker.md`](20261018-112000-slate-net-findings-tracker.md)) identified in the `slate:net` code review across all four networking subsystems (`slate.quic.crypto` & `wire`, `slate.quic.connection` / `stream` / `recovery` / `endpoint`, `slate.h3`, and `slate.http` / `durl`) using the multi-agent **Adversarial TDD Workflow** (`Red → Green → Iterate`).

### 1.2 Scope
1. **Phase 1 — QUIC Transport, Recovery, Stream & Endpoint (`slate.quic.{connection,stream,recovery,endpoint}`)**:
   - Fix truncated packet number decoding in [`connection.d`](../../slate-dlang/packages/net/source/slate/quic/connection/connection.d) to use `ackRanges[space].largestReceived` (when `!ackRanges[space].empty`) instead of `lossDetector.largestAckedPn[space]`, and compute dynamic outbound packet number lengths via `packetNumberLength`.
   - Fix [`packet_packer.d`](../../slate-dlang/packages/net/source/slate/quic/connection/packet_packer.d) to clear `hasPendingPathChallenge` upon encoding `PATH_CHALLENGE`, enforce `lossDetector.cc.canSend` (`bytesInFlight < cwnd`) for data frames, and remove the dead shadowed `close()` overload.
   - Implement receive-side flow-control window replenishment (`MAX_DATA`, `MAX_STREAM_DATA`, `MAX_STREAMS_BIDI`, `MAX_STREAMS_UNI`) triggered by `QuicConnection.streamRead` and stream closure, with loss retransmission via `SentFrameTracker`.
   - Separate local vs. remote initial stream flow-control parameters in [`stream_map.d`](../../slate-dlang/packages/net/source/slate/quic/stream/stream_map.d) (`applyPeerTransportParams`), reap fully closed streams (`isClosed`) from `StreamMap` so connections are not capped at 1024 lifetime streams, queue `RESET_STREAM` upon receiving `STOP_SENDING`, and retransmit lost `RESET_STREAM` / `STOP_SENDING` frames.
   - Cap unauthenticated `cryptoRecv` buffers in [`connection.d`](../../slate-dlang/packages/net/source/slate/quic/connection/connection.d) to `64 KiB` (instead of `16 MiB`), enforce the 1200-byte minimum datagram size only when a datagram contains an `Initial` packet, enforce mandatory RFC 9000 §7.3 transport parameter presence (`initial_source_connection_id`, `original_destination_connection_id`, `retry_source_connection_id`), and include idle timeout in `nextTimeoutMicros`.
   - Fix [`loss_detection.d`](../../slate-dlang/packages/net/source/slate/quic/recovery/loss_detection.d) so ACKs covering `> 128` packets still mark all acknowledged packets as `acked = true`, tag `SentPacketInfo` with `PacketNumberSpace` so `onTimeout` only retires lost packets from their own space, and use `peerParams.ackDelayExponent` / `peerParams.maxAckDelay`.
   - Fix [`endpoint.d`](../../slate-dlang/packages/net/source/slate/quic/endpoint/endpoint.d) short-header routing for variable-length CIDs, key Retry anti-replay by `nonceCounter` instead of `issuedMicros`, mix random/CSPRNG state into the initial Retry nonce counter and Stateless Reset payload, and use constant-time comparison for Stateless Reset tokens.
2. **Phase 2 — QUIC Crypto & Wire Safety (`slate.quic.{crypto,wire}`)**:
   - Enable `SSL_VERIFY_PEER`, system CA paths, optional custom CA file loading, SNI (`SSL_set_tlsext_host_name`), and hostname verification (`SSL_set1_host`) by default in [`tls_session.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/tls_session.d) (`TlsContext.createClient`), while providing an explicit opt-in `createClientInsecure()` for raw self-signed test harnesses.
   - Fix `TlsContext.m_alpnConfig` lifetime (embed `wireData` directly inside `TlsContext` or free only after `SSL_CTX`), clear `m_state.inBufPtr` via `scope(exit)` in `provideCryptoData`, dynamically grow or enlarge `outHandshake` / `peerParams` buffers in `TlsSessionState` so >4 KiB cert chains and >512B transport parameters succeed, and guard self-move (`if (&this is &other) return;`) across all crypto structs.
   - Enforce key, IV, and output buffer length checks and OpenSSL return-code checks across all `@trusted` functions in [`kdf.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/kdf.d), [`aead.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/aead.d), [`header_protection.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/header_protection.d), and [`packet_keys.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/packet_keys.d), and use constant-time tag comparison in `verifyRetryIntegrityTag`.
   - Fix [`frame.d`](../../slate-dlang/packages/net/source/slate/quic/wire/frame.d) ACK range count bounds (`numRanges <= MAX_ACK_RANGES`), overflow-safe gap calculation, and `FrameType` discriminant consistency (`maxStreamsBidi`/`Uni`, `streamsBlockedBidi`/`Uni`, `connectionCloseQuic`/`App`), and scope test-only imports in [`wire/package.d`](../../slate-dlang/packages/net/source/slate/quic/wire/package.d) under `version (unittest)`.
3. **Phase 3 — HTTP/3 & QPACK (`slate.h3`)**:
   - Reclaim finished/reset stream slots in [`h3/connection.d`](../../slate-dlang/packages/net/source/slate/h3/connection.d) so connections can process unlimited sequential streams beyond `256`.
   - Prevent `H3Event` slice invalidation during a single `pollEvent` cycle and document/stabilize buffer ownership, validate `:authority` vs `Host` headers per RFC 9114 §4.3.1, reject server-initiated bidirectional streams on clients (`H3_STREAM_CREATION_ERROR`), and validate QPACK encoder/decoder unidirectional streams (`H3_QPACK_ENCODER_STREAM_ERROR` / `H3_QPACK_DECODER_STREAM_ERROR`).
   - Avoid buffering unknown/GREASE unidirectional streams before type check, fix control-stream `FIN` frame error precedence, allow `Content-Length` on `204`/`304`/`HEAD` responses, convert per-stream `H3_MESSAGE_ERROR` into stream resets (`resetStream`) rather than connection aborts where required by RFC 9114 §4.1.2, and guard `TestQuicPair` in [`h3/package.d`](../../slate-dlang/packages/net/source/slate/h3/package.d) with `version (unittest)`.
4. **Phase 4 — HTTP Client, `libcurl` FFI, Async Tasks & `durl` (`slate.http`, `slate.bin.durl`)**:
   - Fix `curl_slist*` memory leaks and dirty `CURL*` handle state when `applyRequestOptions` throws in [`http/client.d`](../../slate-dlang/packages/net/source/slate/http/client.d), and fix `scope(exit)` LIFO teardown order in [`http/http_task.d`](../../slate-dlang/packages/net/source/slate/http/http_task.d).
   - Validate request URLs and header names/values against `\r`, `\n`, and `\0`; set `CURLOPT_PROTOCOLS_STR` to `"http,https"` and `CURLOPT_NOSIGNAL = 1L`; stop fabricating HTTP `200` when `CURLINFO_RESPONSE_CODE == 0`; and enforce configurable maximum response body/header sizes (`maxResponseBytes`, `maxHeaderBytes`) with overflow-safe capacity doubling.
   - Replace shared mutable `__gshared` exception throwing in [`http/error.d`](../../slate-dlang/packages/net/source/slate/http/error.d) with thread-local (`static`) preallocated instances so concurrent worker threads never race on `Throwable` unwinder fields.
   - Clear intermediate redirect (`3xx`) and `1xx` headers in `parseHeaders` when a new `"HTTP/"` status line is encountered, decouple `verifyPeer` and `verifyHost` in `applyRequestOptions`, reset sticky handle options (`CURLOPT_HTTP_VERSION`, `CURLOPT_ACCEPT_ENCODING`, `CURLOPT_VERBOSE`) on handle reuse, deep-copy `Request` slices in `spawnHttpTask`, guard `HttpStubServer` import under `version (unittest)`, and validate CLI arguments in [`bin/durl.d`](../../slate-dlang/packages/net/source/slate/bin/durl.d) to return exit code `2` instead of throwing uncaught `AssertError`.

### 1.3 Non-Goals
- Implementing QUIC Multipath or HTTP/3 Server Push execution (Server Push ID bounds are validated, push stream generation is out of scope).
- Changing public DUB subpackage dependency boundaries (`slate:net` continues to depend only on `slate:core` + `libcurl`, `libssl`, `libcrypto`).

---

## 2. Evidence & Dataflow Analysis

```mermaid
sequenceDiagram
    participant Test as Red Unit Test (dub test :net)
    participant Peer as Remote Peer / Loopback
    participant Conn as QuicConnection / H3Connection / HttpClient
    participant Crypto as TlsSession / OpenSSL / libcurl

    Note over Test,Conn: Phase 1: QUIC Transport Red -> Green
    Peer->>Conn: 150x 1-RTT packets (1-byte PN, asymmetric traffic)
    Conn->>Conn: Decode PN using ackRanges[space].largestReceived
    Conn->>Peer: Emit MAX_STREAM_DATA / MAX_DATA / MAX_STREAMS as app reads
    Conn->>Conn: Reap closed QuicStream slots > 1024 lifetime streams

    Note over Test,Crypto: Phase 2: Crypto & Wire Red -> Green
    Conn->>Crypto: TlsContext.createClient() -> SSL_VERIFY_PEER + SNI + Hostname check
    Crypto-->>Conn: Reject untrusted self-signed or mismatched hostname cert

    Note over Test,Conn: Phase 3: HTTP/3 & QPACK Red -> Green
    Peer->>Conn: >256 sequential H3 requests + :authority/Host mismatch + QPACK stream data
    Conn->>Conn: Reap finished H3StreamTracker slots; reject conflicting :authority/Host

    Note over Test,Crypto: Phase 4: slate.http & durl Red -> Green
    Test->>Conn: CRLF header / file:// URL / invalid caInfo / 302->200 redirect headers
    Conn-->>Test: Reject CRLF & file://; free curl_slist on throw; return only final hop headers
```

---

## 3. Proposed Design and Material Decisions (`D1`–`D4`)

### `D1`: Secure-by-Default `TlsContext.createClient` with Explicit Test/CA Support
- **Problem**: `TlsContext.createClient()` currently leaves OpenSSL at `SSL_VERIFY_NONE`, accepting any MITM certificate. However, existing unit tests use a self-signed fixture (`test/fixtures/quic_cert.pem`).
- **Options**:
  1. Enable `SSL_VERIFY_PEER` + `SSL_CTX_set_default_verify_paths` in `createClient(scope const(char)[] caFilePath = null)` by default, add `TlsContext.createClientInsecure()` for tests that intentionally skip CA verification, and add `serverName` parameter to `TlsSession.init` / `QuicConnection.create` to configure SNI (`SSL_set_tlsext_host_name`) and hostname verification (`SSL_set1_host`).
  2. Keep `createClient()` insecure and add `createClientVerified()`.
- **Selected Approach**: **Option 1**. Security by default is mandatory (`SSL_VERIFY_PEER`). When `caFilePath` is passed (or default verify paths are used) and `serverName` is non-empty, `SSL_set1_host` and `SSL_set_tlsext_host_name` are enforced. Existing loopback tests can pass `"test/fixtures/quic_cert.pem"` or `createClientInsecure()`.

### `D2`: Thread-Local Preallocated `@nogc` Exceptions in `slate.http.error`
- **Problem**: `_preallocatedErrors` in [`http/error.d`](../../slate-dlang/packages/net/source/slate/http/error.d) are `__gshared`, causing data races in D's unwinder when thrown concurrently by multiple `HttpTask` worker threads.
- **Selected Approach**: Change `_preallocatedErrors`, `_preallocatedCancelled`, `_preallocatedTimeout`, `_preallocatedTooManyRedirects`, and `_preallocatedMultiErrors` from `__gshared` to thread-local (`static`) initialized per thread via `static this()` (in addition to `shared static this()`). In D, non-`__gshared` module variables are stored in Thread-Local Storage (TLS), eliminating cross-thread unwinder races while preserving 100% `@nogc` throwing.

### `D3`: Automatic Stream Reclamation in `StreamMap` and `H3Connection`
- **Problem**: Both `StreamMap` (`MAX_CONCURRENT_STREAMS_CEILING = 1024`) and `H3Connection` (`MAX_TRACKED_STREAMS = 256`) append to a flat array and never remove closed streams.
- **Selected Approach**:
  - In `StreamMap`: Add `reapClosedStreams()` (called when a stream transitions to `isClosed` after `streamRead` consumes `FIN` + all acks, or on `RESET_STREAM`, and before `addStream` checks capacity). When a peer-initiated stream is reaped, increment `localMaxStreamsBidi` / `localMaxStreamsUni` and mark a `maxStreamsBidiNeeded` / `maxStreamsUniNeeded` flag so `packOneRttPacket` emits `MAX_STREAMS`.
  - In `H3Connection`: Reclaim a `H3StreamTracker` slot (calling `tracker.cleanup()` and swap-removing/compacting the slot) once `requestFinishedEmitted` or `resetRecvd` has been emitted and all events for that stream have been drained.

### `D4`: Receive Flow-Control Auto-Tuning (`MAX_DATA` & `MAX_STREAM_DATA`)
- **Problem**: `FlowController.shouldSendMaxDataUpdate()` already exists in [`flow_control.d`](../../slate-dlang/packages/net/source/slate/quic/stream/flow_control.d), but `QuicConnection.streamRead` never calls `onBytesRead` and `QuicPacketPacker` never checks or encodes `MAX_DATA` / `MAX_STREAM_DATA`.
- **Selected Approach**:
  - In `QuicConnection.streamRead`: When `n > 0` bytes are read from `qs.recvBuf`, call `qs.flowCtrl.onBytesRead(n)` and `streams.connFlow.onBytesRead(n)`.
  - In `StreamMap`: Expose `pollFlowControlFrame(out Frame f, out SentFrameDesc desc)` that checks `connFlow.shouldSendMaxDataUpdate()`, each active stream's `flowCtrl.shouldSendMaxDataUpdate()`, and `maxStreamsBidi` / `maxStreamsUni` updates.
  - In `QuicPacketPacker.packOneRttPacket` and `QuicConnection`: Include `streams.hasPendingFlowControl` in `packOneRttPacket`'s readiness check, encode the frames, and re-arm the update flag if the carrying packet is declared lost.

---

## 4. Requirements (EARS) & Acceptance Scenarios (Gherkin)

### 4.1 EARS Requirements

| ID | Category | Requirement |
|---|---|---|
| `U1` | Ubiquitous | The `QuicConnection` shall decode incoming truncated packet numbers relative to `ackRanges[space].largestReceived` and encode outbound packet numbers using `packetNumberLength(pn, largestAcked)`. |
| `E1` | Event-driven | When `QuicConnection.streamRead` consumes bytes or a peer-initiated stream closes, `QuicConnection` shall update `FlowController` windows and emit `MAX_STREAM_DATA`, `MAX_DATA`, and `MAX_STREAMS` frames. |
| `E2` | Event-driven | When a `QuicStream` in `StreamMap` or an `H3StreamTracker` in `H3Connection` reaches terminal closed state, the container shall reclaim its slot and free its heap buffers so connections can exceed 1024 QUIC streams and 256 HTTP/3 streams. |
| `S1` | State-driven | While `lossDetector.cc.bytesInFlight >= lossDetector.cc.cwnd`, `QuicConnection.pollTransmit` shall not pack new `STREAM` data frames (allowing only ACKs/probes). |
| `E3` | Event-driven | When `QuicConnection` packs a `PATH_CHALLENGE` frame, it shall clear `hasPendingPathChallenge` so subsequent `pollTransmit` calls do not flood duplicate `PATH_CHALLENGE` packets. |
| `W1` | Unwanted | If an unauthenticated peer sends a `CRYPTO` frame with offset + length exceeding `65536` bytes, or omits mandatory RFC 9000 §7.3 CID transport parameters, `QuicConnection` shall reject the packet with `cryptoBufferExceeded` / `transportParameterError`. |
| `E4` | Event-driven | When a Server `QuicConnection` receives a datagram `< 1200` bytes before address validation that contains only `Handshake` packets (no `Initial` packet), it shall process the packet and validate the peer address. |
| `E5` | Event-driven | When `LossDetector` processes an `ACK` covering `> 128` packets or a timeout across multiple spaces, it shall mark all acknowledged packets as `acked` and retire lost frames only from the matching `PacketNumberSpace`. |
| `E6` | Event-driven | When `QuicEndpoint` routes a 1-RTT Short Header packet, it shall match against the active slot's actual `localCid.len` (8..20 bytes) and verify Retry anti-replay using the unique 64-bit `nonceCounter`. |
| `U2` | Ubiquitous | The `TlsContext.createClient` shall enable `SSL_VERIFY_PEER` by default and verify peer certificate chains and server hostnames (`SSL_set1_host` + SNI) when configured. |
| `W2` | Unwanted | If any key, IV, or output slice passed to `kdf.d`, `aead.d`, `header_protection.d`, or `packet_keys.d` is shorter than required by the cipher suite, or if an OpenSSL EVP/HMAC call fails, the function shall fail closed with `QuicCryptoError` without out-of-bounds memory access. |
| `W3` | Unwanted | If an HTTP/3 request has conflicting `:authority` and `Host` headers, missing `:authority`/`Host` for `http`/`https`, a server-initiated bidirectional stream on a client, or unexpected bytes on QPACK encoder/decoder streams when dynamic table capacity is 0, `H3Connection` shall reject it with the RFC 9114 / RFC 9204 error code. |
| `W4` | Unwanted | If `applyRequestOptions` in `slate.http.client` fails (e.g., invalid `caInfo` path or `curl_slist_append` OOM), `Client` shall free any partially constructed `curl_slist*` and reset `_handle` options without leaking memory. |
| `W5` | Unwanted | If a `Request` passed to `slate.http` contains `\r`, `\n`, or `\0` in its URL or headers, uses a non-`http`/`https` scheme, or receives a response body/header exceeding `maxResponseBytes`/`maxHeaderBytes`, `slate.http` shall reject the transfer with a `CurlException`. |
| `E7` | Event-driven | When `slate.http.client` follows HTTP redirects (`301`/`302`/`303`), `parseHeaders` shall retain only the final response hop's headers, and `301`/`302`/`303` redirects of `POST`/`PUT`/`DELETE`/`PATCH` shall not replay the custom method verb on the redirected `GET`. |
| `U3` | Ubiquitous | The `slate.http.error` module shall store preallocated `@nogc` exception instances in thread-local storage (`static`) and `spawnHttpTask` shall deep-copy `Request` buffers so concurrent worker threads execute without data races or dangling pointers. |

### 4.2 Gherkin Acceptance Scenarios

```gherkin
Scenario: T1 - Asymmetric 1-RTT traffic > 200 packets decodes packet numbers and replenishes flow control (covers U1, E1)
  Given an active QUIC client-server connection with initialMaxStreamData = 4096 and initialMaxData = 8192
  When the server transmits 200 sequential 1-RTT packets totaling 32 KiB while the client only reads and sends ACKs
  Then the client decodes all 200 packet numbers using largestReceived without AEAD failures
  And the client emits MAX_STREAM_DATA and MAX_DATA frames allowing all 32 KiB to be received

Scenario: T2 - StreamMap and H3Connection reclaim closed streams beyond 1024 / 256 lifetime limits (covers E1, E2)
  Given an active QUIC + HTTP/3 connection with initialMaxStreamsBidi = 64
  When the client sequentially opens, completes, and reads 300 HTTP/3 request streams (and 1100 raw QUIC streams)
  Then closed stream slots are reclaimed, MAX_STREAMS frames are emitted, and all 300 H3 / 1100 QUIC streams succeed

Scenario: T3 - Congestion window gating, PATH_CHALLENGE single emission, and multi-space loss recovery (covers S1, E3, E5)
  Given an active QUIC connection with a full congestion window and a queued PATH_CHALLENGE
  When pollTransmit is called repeatedly and an ACK covering > 128 packets arrives
  Then PATH_CHALLENGE is emitted only once, STREAM frames wait for cwnd credit, and all > 128 acked packets are marked acked without cross-space frame deletion

Scenario: T4 - Server accepts < 1200B Handshake datagram, enforces 64 KiB CRYPTO cap, and routes 16-byte CIDs (covers W1, E4, E6)
  Given a QuicEndpoint with requireRetry = false and a client using a 16-byte Initial DCID
  When the client sends an unpadded 200-byte Handshake datagram and then 1-RTT Short Header packets
  Then the server validates the client address on the Handshake datagram and routes the 16-byte CID Short Header packets
  And if an unauthenticated peer sends a CRYPTO frame at offset 1 MiB, it is rejected with cryptoBufferExceeded

Scenario: T5 - Client TLS certificate & hostname verification and @trusted crypto slice bounds (covers U2, W2)
  Given a TlsContext.createClient() with default SSL_VERIFY_PEER
  When handshaking with an untrusted self-signed server or a trusted server with a mismatched hostname
  Then the client aborts the handshake with a TLS certificate verification error
  And passing short key/IV/output slices to hkdfExtract, AeadKey.init, or HeaderProtectionKey.init returns invalidKeyLength without memory over-read/write

Scenario: T6 - HTTP/3 :authority/Host validation, QPACK stream validation, and non-fatal stream message errors (covers W3)
  Given an active H3Connection
  When a peer sends a request with conflicting :authority and Host headers, or writes to a QPACK encoder stream with capacity 0
  Then H3Connection rejects conflicting headers with H3_MESSAGE_ERROR and QPACK data with H3_QPACK_ENCODER_STREAM_ERROR

Scenario: T7 - HTTP Client slist cleanup on error, CRLF/scheme rejection, size caps, redirect headers, and thread safety (covers W4, W5, E7, U3)
  Given a slate.http.Client and MultiClient / HttpTask
  When requests contain CRLF headers, file:// URLs, invalid caInfo paths, responses exceeding maxResponseBytes, or 302 redirects
  Then invalid inputs and oversized responses are rejected without leaking curl_slist, redirect hop headers are cleared before final headers, and concurrent thread throws do not race
```

### 4.3 Coverage Matrix

| Scenario | Requirement IDs | Target Test File / Suite | Layer |
|---|---|---|---|
| `T1`, `T3`, `T4` | `U1`, `E1`, `S1`, `E3`, `W1`, `E4`, `E5`, `E6` | `slate-dlang/packages/net/source/slate/quic/connection/connection_test.d`, `endpoint/package.d` | Unit / Integration (`@nogc`) |
| `T2` | `E1`, `E2` | `slate-dlang/packages/net/source/slate/quic/stream/stream_map.d`, `slate/h3/package.d` | Unit / Integration (`@nogc`) |
| `T5` | `U2`, `W2` | `slate-dlang/packages/net/source/slate/quic/crypto/tls_session_test.d`, `kdf.d`, `aead.d`, `header_protection.d` | Unit (`@nogc`) |
| `T6` | `W3` | `slate-dlang/packages/net/source/slate/h3/connection.d`, `slate/h3/package.d` | Unit / Integration (`@nogc`) |
| `T7` | `W4`, `W5`, `E7`, `U3` | `slate-dlang/packages/net/source/slate/http/client_test.d`, `error_test.d`, `integration_test.d` | Unit / Integration |

---

## 5. Affected Files and TDD Implementation Steps (`Red → Green → Iterate`)

### Phase 1: QUIC Transport, Stream, Recovery & Endpoint
- `[MODIFY]` [`slate-dlang/packages/net/source/slate/quic/recovery/loss_detection.d`](../../slate-dlang/packages/net/source/slate/quic/recovery/loss_detection.d):
  - Add `PacketNumberSpace space` field to `SentPacketInfo`.
  - In `onAckReceived`, always mark `p.acked = true` and update `cc.onPacketAcked` even when `ackedCount >= newlyAckedOut.length`; only reset `ptoCount = 0` when `anyAckElicitingNewlyAcked` is true; invoke `cc.onPersistentCongestion()` when loss span exceeds persistent congestion duration.
- `[MODIFY]` [`slate-dlang/packages/net/source/slate/quic/stream/send_buffer.d`](../../slate-dlang/packages/net/source/slate/quic/stream/send_buffer.d) & [`recv_buffer.d`](../../slate-dlang/packages/net/source/slate/quic/stream/recv_buffer.d):
  - Add a 4096-byte compaction threshold to `SendBuffer.compactBufferOnAck` to prevent quadratic `memmove`.
  - In `RecvBuffer.compactBuffer`, only copy up to `intervals[0].end` when compacting or use offset advancement so a high-offset gap does not `memmove` megabytes of zeros.
- `[MODIFY]` [`slate-dlang/packages/net/source/slate/quic/stream/stream_map.d`](../../slate-dlang/packages/net/source/slate/quic/stream/stream_map.d):
  - Separate `localInitialMaxStreamData{BidiLocal,BidiRemote,Uni}` from `peerInitialMaxStreamData{BidiLocal,BidiRemote,Uni}` so `applyPeerTransportParams` never overwrites local receive windows.
  - Track `maxDataReceived` (`highestReceived`) on `QuicStream` and use it for `RESET_STREAM` final size validation; queue `resetQueued = true` in `onStopSendingFrame`.
  - Implement `reapClosedStreams()` and `pollFlowControlFrame()` to emit `MAX_DATA`, `MAX_STREAM_DATA`, and `MAX_STREAMS` frames and reclaim closed streams from `streams[0 .. m_streamCount]`.
- `[MODIFY]` [`slate-dlang/packages/net/source/slate/quic/connection/sent_frames.d`](../../slate-dlang/packages/net/source/slate/quic/connection/sent_frames.d), [`packet_packer.d`](../../slate-dlang/packages/net/source/slate/quic/connection/packet_packer.d), [`connection.d`](../../slate-dlang/packages/net/source/slate/quic/connection/connection.d), [`connection_test.d`](../../slate-dlang/packages/net/source/slate/quic/connection/connection_test.d):
  - **Red**: Add failing unit tests in `connection_test.d` for >128 asymmetric 1-RTT packets, flow-control credit exhaustion & `MAX_DATA`/`MAX_STREAM_DATA` recovery, >1024 sequential streams, single `PATH_CHALLENGE` emission, `cwnd` gating, <1200B client `Handshake` packet acceptance, 64 KiB `CRYPTO` buffer cap, and mandatory transport parameter presence.
  - **Green**:
    - Use `ackRanges[space].empty ? 0 : ackRanges[space].largestReceived` for `unprotectPacket` and `completeHeaderAfterUnprotect`.
    - Compute outbound `pnLen` via `packetNumberLength(pn, largestAcked)`.
    - Clear `hasPendingPathChallenge = false` when packed; check `lossDetector.cc.canSend` before polling `STREAM` frames; remove shadowed `QuicPacketPacker.close`.
    - Call `qs.flowCtrl.onBytesRead(n)` and `streams.connFlow.onBytesRead(n)` in `streamRead`, pack pending `MAX_DATA` / `MAX_STREAM_DATA` / `MAX_STREAMS` frames in `packOneRttPacket`, and re-arm on packet loss.
    - Cap `cryptoRecv[0..2]` at `65536` bytes (`64 KiB`).
    - Enforce `< 1200` byte drop only when the datagram contains a `PacketType.initial` packet.
    - Validate mandatory presence of `initial_source_connection_id`, `original_destination_connection_id`, and `retry_source_connection_id`.
    - Include `lastRxTimeMicros + effectiveIdleTimeoutMicros` in `nextTimeoutMicros`, use `peerParams.ackDelayExponent` and `peerParams.maxAckDelay`, and use `newlyLost[i].space` in `onTimeout`.
- `[MODIFY]` [`slate-dlang/packages/net/source/slate/quic/endpoint/token.d`](../../slate-dlang/packages/net/source/slate/quic/endpoint/token.d), [`endpoint.d`](../../slate-dlang/packages/net/source/slate/quic/endpoint/endpoint.d), [`endpoint/package.d`](../../slate-dlang/packages/net/source/slate/quic/endpoint/package.d):
  - **Red**: Add failing unit tests for 16-byte client Initial DCID routing on Short Header packets, same-microsecond Retry token issuance for two clients, and header version bit check in `verifyToken`.
  - **Green**: Route Short Header packets using each active slot's `localCid.len` (or prefix match), record `nonceCounter` in `RetryTokenPayload` and the anti-replay cache, seed `m_retryNonceCounter` with `RAND_bytes` on `init`, use constant-time comparison for `m_resetToken`, and round-robin `QuicEndpoint.pollTransmit` across active slots.

### Phase 2: QUIC Crypto & Wire Safety
- `[MODIFY]` [`slate-dlang/packages/net/source/slate/quic/crypto/c_openssl.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/c_openssl.d), [`kdf.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/kdf.d), [`aead.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/aead.d), [`header_protection.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/header_protection.d), [`packet_keys.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/packet_keys.d), [`tls_session.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/tls_session.d), [`tls_session_test.d`](../../slate-dlang/packages/net/source/slate/quic/crypto/tls_session_test.d):
  - **Red**: Add failing unit tests in `tls_session_test.d`, `kdf.d`, `aead.d`, and `header_protection.d` for untrusted server certificate rejection by default `createClient()`, trusted CA + hostname verification (`SSL_set1_host`), short key/IV/output slices returning `QuicCryptoError.invalidKeyLength`, self-move (`x.moveFrom(x)`), and >512B transport parameters.
  - **Green**:
    - Bind `SSL_CTX_set_verify`, `SSL_CTX_set_default_verify_paths`, `SSL_CTX_load_verify_locations`, `SSL_set1_host`, `SSL_ctrl` (`SSL_CTRL_SET_TLSEXT_HOSTNAME`), `SSL_get_verify_result`, `RAND_bytes`, and `CRYPTO_memcmp` in `c_openssl.d`.
    - Enable `SSL_VERIFY_PEER` by default in `TlsContext.createClient(scope const(char)[] caFilePath = null)`, add `TlsContext.createClientInsecure()` (and update existing raw self-signed unit tests that don't pass the CA path), and support `serverName` in `TlsSession.init`.
    - Validate key/IV/output slice lengths and OpenSSL return codes in `hkdfExtract`, `hkdfExpand`, `AeadKey.init`, `HeaderProtectionKey.init`, `HeaderProtectionKey.apply`, `decodePacketNumber`, and `computeRetryIntegrityTag`, and use constant-time tag comparison in `verifyRetryIntegrityTag`.
    - Clear `m_state.inBufPtr` via `scope(exit)` in `provideCryptoData`, enlarge/dynamically buffer `outHandshake` (`16384` bytes) and `peerParams` (`2048` bytes) with explicit error on overflow, and guard `&this == &other` in all `moveFrom` methods.
- `[MODIFY]` [`slate-dlang/packages/net/source/slate/quic/wire/frame.d`](../../slate-dlang/packages/net/source/slate/quic/wire/frame.d), [`packet.d`](../../slate-dlang/packages/net/source/slate/quic/wire/packet.d), [`transport_params.d`](../../slate-dlang/packages/net/source/slate/quic/wire/transport_params.d), [`wire/package.d`](../../slate-dlang/packages/net/source/slate/quic/wire/package.d):
  - **Red**: Add failing unit tests in `frame_test.d` for `encodeFrame` with `numRanges > MAX_ACK_RANGES`, `FrameType.maxStreamsBidi` with default `isBidirectional = false`, and Version Negotiation packet validation.
  - **Green**: Check `numRanges <= MAX_ACK_RANGES` and overflow-safe `largest + 2` in `encodeFrame`, honor `frame.type` discriminant in `encodeFrame`, validate `preferred_address` structure in `transport_params.d`, and guard crypto imports in `wire/package.d` with `version (unittest)`.

### Phase 3: HTTP/3 & QPACK (`slate.h3`)
- `[MODIFY]` [`slate-dlang/packages/net/source/slate/h3/connection.d`](../../slate-dlang/packages/net/source/slate/h3/connection.d), [`frame.d`](../../slate-dlang/packages/net/source/slate/h3/frame.d), [`qpack.d`](../../slate-dlang/packages/net/source/slate/h3/qpack.d), [`h3/package.d`](../../slate-dlang/packages/net/source/slate/h3/package.d):
  - **Red**: Add failing unit tests in `connection.d` and `h3/package.d` for >256 sequential HTTP/3 requests, conflicting `:authority` and `host` headers, missing `:authority`/`host` on `https`, non-empty QPACK encoder/decoder stream data when capacity is 0, >1 MiB GREASE unidirectional stream data, server-initiated bidirectional stream on client, and `204`/`304` responses with `Content-Length`.
  - **Green**:
    - Reclaim finished/reset `H3StreamTracker` entries from `streams[0 .. streamCount]` and call `tracker.cleanup()`.
    - Validate `:authority` and `host` consistency and non-emptiness in `validateHeaders` (RFC 9114 §4.3.1).
    - Reject bytes on QPACK encoder/decoder streams when dynamic table is unused (`H3ErrorCode.qpackEncoderStreamError` / `qpackDecoderStreamError`), discard unknown unidirectional stream data directly when draining `quicConn.streamRead` without buffering into `recvBuf`, and reject server-initiated bidirectional streams on a client (`H3ErrorCode.streamCreationError`).
    - Process remaining buffered frames on the control stream before checking `finReceived` (`H3ErrorCode.closedCriticalStream`), exempt `204`/`304` responses from body `Content-Length` mismatch, reset individual streams (`quicConn.resetStream` / `stopSending`) on per-stream `H3_MESSAGE_ERROR` instead of aborting the entire connection, and wrap `TestQuicPair` in `h3/package.d` inside `version (unittest)`.

### Phase 4: `slate.http` & `durl` (`slate.http`, `slate.bin.durl`)
- `[MODIFY]` [`slate-dlang/packages/net/source/slate/http/c_bind.d`](../../slate-dlang/packages/net/source/slate/http/c_bind.d), [`error.d`](../../slate-dlang/packages/net/source/slate/http/error.d), [`error_test.d`](../../slate-dlang/packages/net/source/slate/http/error_test.d), [`request.d`](../../slate-dlang/packages/net/source/slate/http/request.d), [`client.d`](../../slate-dlang/packages/net/source/slate/http/client.d), [`client_test.d`](../../slate-dlang/packages/net/source/slate/http/client_test.d), [`multi.d`](../../slate-dlang/packages/net/source/slate/http/multi.d), [`http_task.d`](../../slate-dlang/packages/net/source/slate/http/http_task.d), [`package.d`](../../slate-dlang/packages/net/source/slate/http/package.d), [`bin/durl.d`](../../slate-dlang/packages/net/source/slate/bin/durl.d):
  - **Red**: Add failing unit tests in `client_test.d` and `error_test.d` for:
    1. CRLF / NUL injection in request headers and URLs.
    2. `file://` URL rejection (`CURLE_UNSUPPORTED_PROTOCOL`).
    3. `applyRequestOptions` throwing on missing `caInfo` after building `headerList` (verifying handle reuse and no `curl_slist` leak).
    4. Response exceeding `config.maxResponseBytes` aborting transfer cleanly.
    5. `parseHeaders` with `HTTP/1.1 302 Found\r\nX-Hop: 1\r\n\r\nHTTP/1.1 200 OK\r\nX-Final: 2\r\n\r\n` returning only `X-Final: 2`.
    6. Concurrent threads throwing `@nogc` preallocated exceptions without racing on `Throwable` state.
    7. `durl` invalid CLI args (`""`, `--max-redirs -1`, `-H ": val"`) returning exit code `2` cleanly.
  - **Green**:
    - Add `CURLOPT_PROTOCOLS_STR` and `CURLOPT_NOSIGNAL` constants in `c_bind.d`; set `CURLOPT_NOSIGNAL = 1L` and `CURLOPT_PROTOCOLS_STR = "http,https"` in `applyRequestOptions`.
    - Register `scope(exit)` cleanup in `Client.perform*` *before* calling `applyOptions`, and free `headerList` inside `applyRequestOptions` on `scope(failure)` or if `curl_slist_append` returns `null`.
    - Validate URLs and headers against `\r`, `\n`, `\0` (and empty header names); decouple `verifyPeer` and `verifyHost`; reset `CURLOPT_HTTP_VERSION`, `CURLOPT_ACCEPT_ENCODING`, and `CURLOPT_VERBOSE` in `resetHandleOptions`; and avoid using `CURLOPT_CUSTOMREQUEST` for standard `POST`/`PUT` when following redirects or clear intermediate headers in `parseHeaders` upon encountering a new `HTTP/` status line.
    - Add `maxResponseBytes` (default `64 MiB`) and `maxHeaderBytes` (default `256 KiB`) to `ClientConfig` and enforce them with overflow-safe growth in `clientDynamicWriteCb` / `clientHeaderCollectCb`.
    - Convert `__gshared` preallocated exceptions in `error.d` to thread-local `static` instances initialized in `static this()`.
    - Fix `scope(exit)` ordering in `http_task.d`, check `bodyCtx.oom || headerCtx.oom`, and deep-copy `Request` slices in `spawnHttpTask`.
    - Guard `HttpStubServer` import in `client.d` under `version (unittest)`, roll back `_initCount` on `scope(failure)` in `CurlGlobal.initialize`, and validate CLI inputs in `durl.d`.

---

## 6. Verification Plan

```bash
# 1. Run pure-D unit tests for slate:net after each Red -> Green cycle:
just slate-test-net

# 2. Build the durl CLI executable:
cd slate-dlang && dub build :net --config=durl

# 3. Format all modified D files and run syntax + style static analysis:
just d-fmt
just d-lint

# 4. Run full umbrella test suite and clean leftover artifacts:
just slate-test
just clean
```

---

## 7. Risks, Assumptions, and Approval

- **Compatibility Note**: Enabling `SSL_VERIFY_PEER` by default in `TlsContext.createClient()` means existing loopback unit tests using the self-signed `test/fixtures/quic_cert.pem` must either pass `"test/fixtures/quic_cert.pem"` to `createClient` or call `TlsContext.createClientInsecure()`. We will update all internal unit tests accordingly while adding dedicated verification tests for `createClient()`.
- **Approval Status**: `in-review` — awaiting explicit user approval before executing Phase 1–4 code changes.
