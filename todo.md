# Slate Networking (`slate:net`) — QUIC & HTTP/3 Follow-Up TODOs

While Phases 1–5 of the Sans-I/O QUIC (`slate.quic`, RFC 9000/9001/9002) and HTTP/3 + QPACK (`slate.h3`, RFC 9114/9204) stack are complete and verified for 1-RTT connections, the following items remain for full operational and extended RFC completeness:

## 1. Phase 6: OS UDP Socket Driver & Native HTTP/3 Server/Client (`slate.h3.server`)
- [ ] **Non-Blocking UDP Socket Loop**: Implement a native UDP socket I/O driver (`epoll` / `poll` / `recvmmsg` / `sendmmsg`) wrapping `QuicEndpoint` + `H3Connection` (server) and `QuicConnection` + `H3Connection` (client).
- [ ] **Monotonic Timer Wheel**: Drive `QuicConnection.nextTimeoutMicros` and `onTimeout` automatically from the event loop for PTO, loss recovery, and draining teardown.

## 2. RFC 9000 / RFC 9001 Transport Enhancements (`slate.quic`)
- [ ] **Dynamic `MAX_STREAMS` Auto-Replenishment (RFC 9000 §4.6)**: Automatically emit `MAX_STREAMS_BIDI` and `MAX_STREAMS_UNI` frames as finished streams are closed and retired so long-lived HTTP/3 connections can exceed `initial_max_streams_bidi` (e.g. >100 sequential requests).
- [ ] **Multi-CID Pool & Active Connection Migration (RFC 9000 §5.1, §9)**: Maintain a sequence-numbered pool of active local/remote Connection IDs (`NEW_CONNECTION_ID` / `RETIRE_CONNECTION_ID` with `retire_prior_to`), support `preferred_address` migration, and reset congestion control / RTT estimator on peer address change.
- [ ] **0-RTT Early Data & `NEW_TOKEN` (RFC 9000 §8.1.3, RFC 9001 §4.6–§4.7)**: Wire TLS 1.3 session tickets, `EncryptionLevel.earlyData` (`PacketType.zeroRtt`) packet protection, and `NEW_TOKEN` issuance/persistence.
- [ ] **DPLPMTUD & ECN Congestion Feedback (RFC 9000 §13.4, §14.3)**: Add Path MTU probing above the 1200-byte minimum datagram size and feed `ACK_ECN` (`ECT(0)`, `ECT(1)`, `ECN-CE`) counters into `NewRenoCongestionController`.

## 3. RFC 9204 / RFC 9221 Optional Extensions (`slate.h3` & `slate.quic`)
- [ ] **QPACK Dynamic Table (`qpackMaxTableCapacity > 0`, RFC 9204 §3.2)**: Optional ring-buffer dynamic table insertion/eviction and encoder/decoder stream (`0x02`/`0x03`) state synchronization (currently operates in standard `qpackMaxTableCapacity = 0` Static Table + Huffman mode).
- [ ] **Unreliable QUIC `DATAGRAM` Extension (RFC 9221)**: Add `DATAGRAM` frame (`0x30`/`0x31`) support in `QuicConnection` for WebTransport / MoQ unreliable datagram mode.
