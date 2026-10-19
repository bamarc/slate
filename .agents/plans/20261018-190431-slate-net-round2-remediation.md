# Implementation Plan: `slate:net` Round-2 Remediation (post-`ce3ce86` regressions & open findings)

| Field | Value |
|---|---|
| **Owning Project** | `slate-dlang` ([`slate-dlang/packages/net/`](../../slate-dlang/packages/net/README.md)) |
| **Status** | `implemented & verified` (Phases A–C approved by fresh reviewer + security auditor; uncommitted) |
| **Revision** | `1.0` |
| **Date** | `2026-10-18` |
| **Predecessor** | [`20261018-112000-slate-net-tdd-remediation.md`](20261018-112000-slate-net-tdd-remediation.md), [`20261018-112000-slate-net-findings-tracker.md`](20261018-112000-slate-net-findings-tracker.md) (`F-01`–`F-70`) |
| **Reference Specs** | RFC 9000, 9001, 9002, 9110, 9114, 9204, RFC 6066 §3 |
| **Methodology** | Adversarial TDD workflow (`.agents/skills/adversarial-tdd-workflow`) — one implementor, fresh read-only Reviewer + Security Auditor per round, max 4 rounds per phase |

## Steps

- [x] Phase A — Critical/High regressions (`R-01`–`R-12`)
- [x] Phase B — Medium findings (`R-13`–`R-30`)
- [x] Phase C — Low findings & residual partial fixes (`R-31`–`R-45`)
- [x] Update findings tracker (`F-xx` entries that were wrongly marked `[x]`)

---

## 1. Goal, Scope, Non-Goals

**Goal.** Fix the regressions introduced by commit `ce3ce86` and the findings that the commit marked `[x]` but left open or partially fixed, as established by the 2026-10-18 re-review. Correct every unit test that currently asserts spec-violating behaviour.

**Non-goals.**
- QUIC v2 (RFC 9369) wire support — tracked as an explicit follow-up; Phase C only makes v2 packets be rejected cleanly instead of being misparsed.
- Path MTU discovery (DPLPMTUD). Phase A caps datagrams at a fixed safe size.
- ECN, GSO, connection migration, server push generation.
- Changing the DUB dependency boundary of `slate:net`.

## 2. Evidence (current behaviour at `ce3ce86`)

Baseline: `just slate-test-net` → `54 modules passed unittests` (executed 2026-10-18).

All paths relative to `slate-dlang/packages/net/source/slate/`.

| ID | Sev | Location | Current behaviour |
|---|---|---|---|
| R-01 | Critical | `h3/connection.d:205-241` `appendRecv` | Bound check uses unread bytes, write starts at `recvBufLen` (includes ≤4096 consumed bytes), capacity capped at 1 MiB ⇒ heap overflow ≤4 KiB, peer-triggerable. |
| R-02 | High | `quic/connection/connection.d:580-584` | Only server adopts peer SCID; client never switches `remoteCid` to server's SCID from first Initial (RFC 9000 §7.2). |
| R-03 | High | `quic/wire/frame.d:742-746`, `frame_test.d:404-411` | ACK frames with `≥ MAX_ACK_RANGES` ranges rejected with FRAME_ENCODING_ERROR; test asserts this. |
| R-04 | High | `quic/stream/stream_map.d:418-419, 476-480, 574-575, 672-681, 734-743` | Late STREAM/RESET_STREAM/MAX_STREAM_DATA/STOP_SENDING for reaped streams → STREAM_STATE_ERROR / INTERNAL_ERROR. |
| R-05 | High | `quic/udp.d:28,321,363,390`, `packet_packer.d:283,363-365` | Packer fills 2048-byte buffers; peer `max_udp_payload_size` ignored. |
| R-06 | High | `quic/crypto/tls_session.d:639-647` | Empty `serverName` silently disables hostname check while verifying peer; IP literals put in SNI and matched as DNS names; return codes ignored. |
| R-07 | High | `h3/connection.d:1112-1139, 1185-1212` | `pollEvent` drains all QUIC data into `recvBuf` and returns flow credit but emits one event; small DATA frames fill 1 MiB → EXCESSIVE_LOAD abort. |
| R-08 | High | `h3/connection.d:1737-1744, 1889-1896` | HEAD responses with non-zero `content-length` and no body abort the connection. |
| R-09 | High | `http/multi.d:377-382, 614-619`, `error.d:818-819, 874-875` | "No DONE message" check throws with `CURLE_OK`, which is a no-op. |
| R-10 | High | `quic/connection/connection_test.d:1086-1120` | F-01 test cannot detect the original PN-decode bug (server never sends). |
| R-11 | High | `quic/connection/connection_test.d:1151-1157` | F-10 test never asserts cwnd gating. |
| R-12 | High | `h3/connection.d:1665,1705,1742,1786`, `h3/package.d:339-344` | Malformed request/response messages abort the whole connection instead of a stream error (RFC 9114 §4.1.2); test asserts abort. |
| R-13 | Med | `stream_map.d:634-636`, `connection.d:1195` | Connection-level receive credit for RESET_STREAM final size and unread bytes of reaped streams is never returned. |
| R-14 | Med | `stream_map.d:854`, `connection.d:922` | Stream reaped while RESET_STREAM unacknowledged; lost RESET_STREAM never retransmitted. |
| R-15 | Med | `connection.d:597-604, 1127` | Server processes 1-RTT and confirms handshake before TLS completes (RFC 9001 §4.1.2, §5.7). |
| R-16 | Med | `recovery/loss_detection.d:290-301, 489-500` | Persistent congestion ignores RFC 9002 §7.6.2 conditions. |
| R-17 | Med | `connection.d:645`, `connection_test.d:1414-1420` | Second Retry → PROTOCOL_VIOLATION before integrity check; Retry after processed Initial not discarded. |
| R-18 | Med | `packet_packer.d:226,342,622` | `recordPacket` failure (1024 cap) ignored ⇒ frames never retransmitted. |
| R-19 | Med | `endpoint/endpoint.d:276, 560-588` | Half-open slots never evicted; VN sent for any ≥7-byte datagram (amplification). |
| R-20 | Med | `tls_session.d:774-783` | `SSL_get_verify_result` checked even when not verifying ⇒ insecure client fails on split cert flight. |
| R-21 | Med | `quic/wire/transport_params.d:520`, test `:728-735` | `preferred_address` with zero-length CID accepted. |
| R-22 | Med | `h3/connection.d:1394-1408`, `h3/package.d:1149,1166` | Any byte on peer QPACK encoder/decoder streams is an error, incl. legal Set Capacity 0 (`0x20`) and Stream Cancellation (`0x40|id`). |
| R-23 | Med | `h3/connection.d:1031-1037, 1264` | Reset request stream reclaimed without event; late events for freed IDs recreate a tracker. |
| R-24 | Med | `http/response.d:88-91`, `client.d:895,958,1066`, `multi.d:396` | Status 0 / ≥600 trips `Response` invariant (AssertError). |
| R-25 | Med | `client.d:1039-1059`, `multi.d:614-625` | Size-cap / OOM error mapping unreachable (`CURLE_WRITE_ERROR` thrown first). |
| R-26 | Med | `client.d:442,459,467,484` | PUT/DELETE/PATCH/OPTIONS via `CUSTOMREQUEST` keep their method after 303. |
| R-27 | Med | `h3/connection.d:1609, 222, 1456, 1602`, `h3/qpack.d:31` | 1 MiB DATA / 16 KiB control / 64 KiB headers / 64 fields abort the connection. |
| R-28 | Med | `quic/crypto/aead.d:66-69`, `header_protection.d:107-110`, `kdf.d:90-92, 302-359`, `packet_keys.d:134-143` | Unknown suites fall back to AES-128; `derive*` drop HKDF errors; `KeyPhaseUpdater.init` sets initialized on failure. |
| R-29 | Med | `tls_session.d:397-407` | `onCryptoSend` returns success on partial write. |
| R-30 | Med | `endpoint.d:322-334, 455-461, 489-493` | Single static stateless-reset token, never advertised. |
| R-31 | Low | `kdf.d:215` | `n == 255` counter wraps, returns success with unwritten output. |
| R-32 | Low | `frame.d:478-479, 516-517` | Encode type derived from flags, not discriminant. |
| R-33 | Low | `tls_session.d:444-464` | Secret > 48 bytes dropped but level advances. |
| R-34 | Low | `tls_session.d:752` | TP overflow flag not checked after `SSL_do_handshake`. |
| R-35 | Low | `quic/crypto/c_openssl.d:74-75,125` | C `long` declared as D `long`. |
| R-36 | Low | `connection.d:806-811`, `packet_packer.d:707-712` | Draining period 3·SRTT instead of 3·PTO. |
| R-37 | Low | `connection.d:411` | Idle timer reset before authentication. |
| R-38 | Low | `connection.d:615-617` | ACK_ECN treated as ack-eliciting. |
| R-39 | Low | `h3/connection.d:464, 527` | Host/`:authority` and TE comparisons case-sensitive. |
| R-40 | Low | `quic/udp.d:248,255,328,366,408` | No MSG_TRUNC check; empty datagram stops loop; send errors swallowed. |
| R-41 | Low | `packet_keys.d:285-302, 146-157` | `pnLen`/`decodedPn` not reset on failure; old read key discarded on update. |
| R-42 | Low | `quic/wire/packet.d:98,129,140`, `endpoint.d:296,301` | Unknown-version long headers with CID > 20 bytes dropped instead of VN. |
| R-43 | Low | `http/package.d:33-36` | `curl_global_cleanup` in module dtor while daemon workers may run. |
| R-44 | Low | `ack_ranges.d:121-132,149` | `insert` returns `true` when PN evicted/not stored. |
| R-45 | Low | `tls_session_test.d`, `http_task.d:428-438` | Missing F-34 test (>512 B TPs); F-64 test asserts nothing. |

## 3. Decisions

- **D1 — Datagram size (R-05).** Cap outgoing datagrams at `min(1200, peer.max_udp_payload_size)` until PMTUD exists; keep 2048-byte receive buffers. *Alt:* 1452 (Ethernet IPv6) — rejected, unsafe on tunnels. Smallest safe choice.
- **D2 — Hostname policy (R-06).** `TlsSession.init` fails with a new `QuicCryptoError.missingServerName` when the context verifies peers and `serverName` is empty. IP literals use `SSL_set1_ip_asc` (new binding) and no SNI. Insecure contexts keep current behaviour.
- **D3 — H3 back-pressure (R-07).** `pollEvent` stops calling `streamRead` for a stream once its unread buffered bytes ≥ 64 KiB (`H3_RECV_HIGH_WATER`); QUIC flow-control credit is then only returned as frames are consumed. *Alt:* emit all events per read — rejected; breaks the slice-lifetime contract of F-47.
- **D4 — Stream errors (R-12).** Message errors (`H3_MESSAGE_ERROR`, content-length mismatch, invalid headers) reset only the request stream (`resetStream` + `stopSending`, code `0x010e`) and emit `H3EventType.streamReset`; connection-level errors (control stream, SETTINGS, QPACK streams) still abort.
- **D5 — Frame limits (R-27).** DATA frames are streamed: payload delivered in chunks as it arrives without buffering the whole frame. Unknown frame types on request streams are skipped incrementally. Control frames > 16 KiB remain rejected only for known frame types; unknown control frames are skipped. HEADERS limit is governed by `localSettings.maxFieldSectionSize` with stream error (not connection abort). `MAX_H3_HEADERS` raised to 256 and exceeding it is a stream error.
- **D6 — Reaped stream tracking (R-04, R-23).** Frames for stream IDs below the per-type "next expected / next local" counter whose stream no longer exists are ignored (with flow-control accounting for STREAM final size not required since the stream reached a terminal state). H3 tracks `highestReclaimedId` per stream type for the same purpose.
- **D7 — Stateless reset tokens (R-30).** Derive per-CID tokens as `HMAC-SHA256(staticKey, cid)[0..16]` (RFC 9000 §10.3.2) and advertise in server TPs.
- **D8 — Out-of-range status (R-24).** Throw `HttpException` with `CURLE_WEIRD_SERVER_REPLY` before constructing `Response`.

## 4. Requirements (EARS)

### Phase A
- **W1** (R-01) If appended data would exceed buffer capacity after accounting for already-consumed bytes, then `H3StreamTracker.appendRecv` shall compact before writing and shall never write beyond `recvBufCapacity`.
- **E1** (R-02) When a client receives the first Initial packet from the server, the connection shall set `remoteCid` to that packet's SCID and use it for all subsequent packets.
- **U1** (R-03) The ACK frame decoder shall accept any number of ACK ranges permitted by the frame length, retaining the first `MAX_ACK_RANGES` and reporting truncation without error.
- **E2** (R-04) When a STREAM, RESET_STREAM, MAX_STREAM_DATA, STOP_SENDING or STREAM_DATA_BLOCKED frame references a previously opened and since reaped stream, the connection shall ignore it without error.
- **U2** (R-05) The packet packer shall never produce a UDP datagram larger than `min(1200, peer max_udp_payload_size)`.
- **W2** (R-06) If a peer-verifying TLS client is initialised without a server name, then `TlsSession.init` shall fail with `missingServerName`. **E3** When the server name is an IP literal, the session shall verify it against IP SANs and shall not send SNI.
- **S1** (R-07) While a request stream holds ≥ `H3_RECV_HIGH_WATER` unconsumed bytes, `H3Connection` shall not read further data from that QUIC stream.
- **E4** (R-08) When a response to a HEAD request carries `content-length` and no DATA, the stream shall complete successfully.
- **W3** (R-09) If `MultiClient.performAll` ends with a transfer that never received CURLMSG_DONE, then it shall throw a `CurlException` with a non-OK code.
- **U3** (R-10, R-11) The F-01 and F-10 regression tests shall fail against the pre-`ce3ce86` behaviour (PN decode against `largestAckedPn`; ungated STREAM packing).
- **W4** (R-12) If a request stream carries a malformed message, then `H3Connection` shall reset that stream with `H3_MESSAGE_ERROR` and keep other streams and the connection open.

### Phase B
- **E5** (R-13) When a stream is reset by the peer or reaped with unread data, the connection shall credit `final size − bytes read` back to connection flow control.
- **S2** (R-14) While a RESET_STREAM is unacknowledged, the stream shall not be reaped.
- **S3** (R-15) While the TLS handshake is incomplete, a server shall not process 1-RTT packets and shall not confirm the handshake.
- **U4** (R-16) Persistent congestion shall be declared only per RFC 9002 §7.6.2 (all ack-eliciting packets lost across a period ≥ PTO·3, sent after the first RTT sample, no acked packet in between, across all spaces).
- **W5** (R-17) If a client receives a Retry after a valid Retry or after processing any Initial, then it shall silently discard it.
- **W6** (R-18) If the sent-frame tracker is full, then the packer shall not send an ack-eliciting packet.
- **W7** (R-19) If the slot table is full, then the endpoint shall evict the oldest unvalidated half-open slot; and it shall send VN only for datagrams ≥ 1200 bytes.
- **E6** (R-20) When the TLS context does not verify peers, handshake steps shall not fail on recorded chain verification errors.
- **W8** (R-21) If `preferred_address` has a zero-length CID, then decoding shall fail with TRANSPORT_PARAMETER_ERROR.
- **U5** (R-22) The QPACK encoder/decoder stream parser shall accept Set Dynamic Table Capacity 0 and Stream Cancellation, and reject inserts and Insert Count Increment.
- **E7** (R-23) When a request stream is reset, `H3Connection` shall emit `streamReset`; late events for reclaimed IDs shall be ignored.
- **W9** (R-24) If the response status is outside 100..599, then the client shall throw `CURLE_WEIRD_SERVER_REPLY`.
- **W10** (R-25) If the body/header cap or OOM triggered the abort, then the client shall throw the specific mapped error, not `WRITE_ERROR`.
- **E8** (R-26) When a 301/302/303 redirect is followed for a non-GET/HEAD custom method, the client shall follow RFC 9110 §15.4 (303 → GET; 301/302 keep method only for POST-compat per curl `POSTREDIR` semantics) by resetting `CUSTOMREQUEST` on method-changing redirects.
- **U6** (R-27) Per D5.
- **W11** (R-28) If a cipher suite is unknown or any HKDF/EVP step fails, then key derivation shall return an error and leave the object uninitialised.
- **W12** (R-29) If `onCryptoSend` cannot store all bytes, then it shall grow the buffer or fail the handshake.
- **U7** (R-30) Per D7.

### Phase B — follow-ups carried over from Phase A review (round 3, non-blocking Lows)
- **PB-1** Quote RFC 9000 §7.2 ("…discard any subsequent packet…") and §17.2.5.2 ("After the client has received and processed an Initial or Retry packet from the server, it MUST discard any subsequent Retry packets that it receives.") verbatim in `connection_test.d` (~2005, ~2218, ~2260).
- **PB-2** PING-only server Initial under small budget never sendable (HP sample needs `plainLen + pnLen ≥ 4`): pad the plaintext minimally.
- **PB-3** Server with amplification budget < 1200 and ack-eliciting Initial work shall wait rather than send an unpadded Initial (RFC 9000 §14.1).
- **PB-4** Locally reset H3 tracker shall be released once no event references it (fold into R-23), not pinned until peer FIN.
- **PB-5** `sendRequest` ddoc: when all slots are finished-but-unreaped the caller must `pollEvent` before retrying; `pollTransmit` `in` contract / ddoc requiring buffers ≥ 1200 bytes on clients.
- **PB-6** `validateServerName`: restrict DNS names to LDH labels (letters, digits, `-`), IDNs must be punycode; reject `*`.
- **PB-7** Fix misleading comment in `multi.d` (~972) test.

### Phase C — follow-ups carried over from Phase B review (round 4, non-blocking Lows)
- **PC-1** Make the RFC quotes verbatim in `quic/endpoint/package.d` (~1139, RFC 9000 §8.1.3/§8.1.4) and `http/client_test.d` (~921, RFC 9110).
- **PC-2** `performFollowing` → `applyOptions`: verify that a partially built `fresh` header list is freed when the build throws (OOM). The reviewer and auditor disagreed on this; settle it with a test.
- **PC-3** `RedirectProbe`: do not lose a 3xx body when libcurl cannot resolve `Location` (`CURLINFO_REDIRECT_URL` null). Keep the body until the hop is confirmed, or document the behaviour.
- **PC-4** Add `/// ---` example blocks to the 23 pre-existing changed unittests that lack them (list in the Phase B round-4 review: `h3/connection.d:2454`, `h3/package.d:221/796/1287/1420`, `stream_map.d:1363`, `loss_detection.d:790`, `connection_test.d:674/1412/1505`, `endpoint.d:762/823`, `endpoint/package.d:181/312/367/426/568`, …).
- **PC-5** `throwCurlErrorNogc` leaks about 1 KiB of druntime trace info per throw (`error.d:838/846`). Set a static non-null `info` on the preallocated exceptions, or free and reset it before each throw.
- **PC-6** Endpoint: record the Retry nonce only after the connection is admitted, add a per-address cap on half-open slots, and document or emit evicted-connection invalidation of `QuicConnection*`.
- **PC-7** Rate-limit stateless resets with a token bucket (RFC 9000 §10.3).
- **PC-8** `smsp/source/smsp/http_fallback.d` does not handle `H3EventType.streamReset`. It is outside `packages/net`; report it to the user and do not edit it.

### Phase C
- One `W`/`U` requirement per row R-31..R-45 matching the "fix" column of §2 (e.g. **W13** If `n == 255`, `hkdfExpand` shall produce all 255 blocks).
- **W13** (R-31) If `n == 255`, `hkdfExpand` shall produce all 255 blocks.
- **W14** (R-33) If a handshake secret exceeds 48 bytes, the session shall fail instead of advancing the level.
- **W15** (R-34) If the transport-parameter overflow flag is set, `paramFailure()` shall report it after `SSL_do_handshake`.
- **W16** (R-32) The frame encoder shall derive the wire type from the frame discriminant, never from a flag.
- **W17** (R-35) C `long` shall be declared as `c_long`.
- **W18** (R-36) The draining period shall be 3 × PTO.
- **W19** (R-38) A packet carrying only ACK_ECN shall not be ack-eliciting.
- **W20** (R-37) The idle timer shall be restarted only by a packet that was authenticated.
- **W21** (R-39) Field names shall be lower case and `:authority`/`host` and `TE` comparisons case-insensitive.
- **W22** (R-40) A truncated datagram shall be dropped, an empty one shall not end the receive loop, and a refused send shall be counted apart from a hard error.
- **W23** (R-41, Reviewer M1) Failed unprotect shall leave no stale values; the previous read key shall be retained for 3 × PTO after the first packet under the new keys and then discarded.
- **W24** (R-42) An unknown-version long header with a CID over 20 bytes shall elicit Version Negotiation.
- **W25** (R-44) `AckRangeSet.insert` shall return `false` for a packet number it did not store.
- **W26** (R-43) The module destructor shall not call `curl_global_cleanup` while daemon workers may run.
- **W27** (Auditor M-1) A packet number below the floor raised by an evicted ACK range shall be dropped before any frame is processed.
- **W28** (R-45) Local transport parameters above the buffer limit shall be refused at init; peer parameters over 2048 bytes shall fail the handshake.

## 5. Acceptance Scenarios (selection — implementor adds one per requirement)

```gherkin
Scenario: T1 - H3 recv buffer does not overflow (W1)
  Given an H3 client stream that has consumed a 100-byte HEADERS frame
  When the peer delivers a DATA frame of (1 MiB - 64) bytes in chunks
  Then appendRecv never writes past recvBufCapacity (asserted via capacity/length invariant)
  And the stream either delivers the data or resets, without heap corruption

Scenario: T2 - Client adopts server SCID (E1)
  Given a client and a server whose endpoint chooses an SCID different from the client's DCID
  When the handshake completes
  Then the client's packets carry the server-chosen CID
  And transport-parameter CID validation succeeds

Scenario: T3 - ACK with 40 ranges (U1)
  Given an encoded ACK frame with 40 ranges
  When it is decoded
  Then decoding succeeds with 32 retained ranges and truncation flagged

Scenario: T4 - Late retransmission on reaped stream (E2)
  Given a bidi stream fully closed and reaped on both sides
  When a duplicate STREAM frame with FIN for it arrives
  Then the connection stays open and no new stream is created

Scenario: T5 - Datagram size cap (U2)
  Given a peer advertising max_udp_payload_size 1350 and a 64 KiB stream write
  When pollTransmit is drained
  Then every datagram is <= 1200 bytes

Scenario: T6 - Missing server name rejected (W2)
  Given TlsContext.createClient()
  When TlsSession.init is called with an empty serverName
  Then init fails with missingServerName

Scenario: T7 - SSE-style small frames (S1)
  Given a server sending 100000 DATA frames of 8 bytes on one request stream
  When the client polls events one by one
  Then the connection never aborts with EXCESSIVE_LOAD and all bytes are delivered

Scenario: T8 - HEAD with content-length (E4)
  Given a HEAD request
  When the response carries content-length: 1234 and FIN without DATA
  Then the stream finishes without error

Scenario: T9 - Malformed response resets one stream (W4)
  Given two concurrent requests
  When the response on stream A has a content-length mismatch
  Then stream A is reset with H3_MESSAGE_ERROR and stream B completes normally

Scenario: T10 - F-01 regression test bites (U3)
  Given >200 server-to-client 1-RTT packets with the client never sending ack-eliciting data
  When the client decodes them
  Then all are accepted (and the test fails if decoding uses largestAckedPn)
```

| Scenario | Requirements | Target test file | Layer |
|---|---|---|---|
| T1, T7, T8, T9 | W1, S1, E4, W4 | `h3/connection.d` / `h3/package.d` unittests | Unit (TestQuicPair) |
| T2, T4, T5, T10 | E1, E2, U2, U3 | `quic/connection/connection_test.d` | Unit (loopback pair) |
| T3 | U1 | `quic/wire/frame_test.d` | Unit |
| T6 | W2, E3 | `quic/crypto/tls_session_test.d` | Unit |
| W3, W9, W10, E8 | — | `http/client_test.d` (stub server) | Unit/Integration |
| Phase B/C | per requirement | owning module's test file | Unit |

## 6. Implementation Steps

Each phase is one adversarial-TDD cycle (implementor → fresh Reviewer + Security Auditor, ≤4 rounds).
1. **Phase A**: R-01 → R-12. Red test for each first (tests that currently assert wrong behaviour are rewritten first and must fail), then fix.
2. **Phase B**: R-13 → R-30.
3. **Phase C**: R-31 → R-45.
4. Update `20261018-112000-slate-net-findings-tracker.md`: reopen wrongly ticked F-items with a pointer to the R-ID that closes them.

## 7. Verification (gates)

- **G1** `just slate-test-net` passes (from repo root).
- **G2** `dub build --root=slate-dlang :net` and `--config=h3` build cleanly.
- **G3** `just d-lint` reports no new warnings for `packages/net`; `dfmt` applied to touched files.
- **G4** Every new/changed `unittest` carries `// Spec:` + `/// Example:` and fails against the pre-fix code (implementor records red output per R-ID).
- **G5** No new `@trusted` without an audit comment; no C-heap leaks on new error paths; no unrelated working-tree files modified (`git status` outside `packages/net` and `.agents/plans` unchanged).

## 8. Risks

- D3/D5 change the H3 event contract (DATA arrives in chunks; `streamReset` event added) — callers in `durl` and tests must be updated in the same phase.
- D2 is a breaking change for callers passing no server name with a verifying context.
- The working tree has unrelated uncommitted changes (Justfile, dub.json, slate-encoding, slint-d); they must not be touched or committed.

## 9. Approval

Approved by user 2026-10-18: all phases A–C; breaking decisions D2 and D5 accepted.
