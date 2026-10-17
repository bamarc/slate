# `slate:net` — Native QUIC & HTTP/1.1/2/3 Networking Stack

`slate:net` is the networking DUB subpackage of [`slate-dlang`](../../README.md). It provides a pure-D, sans-I/O implementation of the QUIC transport protocol (`RFC 9000`, `RFC 9001`, `RFC 9002`), native HTTP/3 framing (`RFC 9114`) with QPACK header compression (`RFC 9204`), an async-capable HTTP/1.1/2/3 client (`slate.http`), and the `durl` command-line diagnostic client.

---

## Key Packages (`source/slate/`)

| Package / Module | Path | Description |
|---|---|---|
| `slate.quic` | [`source/slate/quic/`](source/slate/quic/) | Sans-I/O QUIC state machine: variable-length integers (`varint.d`), packet codecs (`packet.d`), frames (`frame.d`), TLS 1.3 key derivation & AEAD header protection (`kdf.d`, `aead.d`, `header_protection.d`, `tls_session.d`), stream flow control (`flow_control.d`, `stream_map.d`), and NewReno/Cubic congestion control with loss detection (`congestion.d`, `loss_detection.d`, `rtt.d`) |
| `slate.http` | [`source/slate/http/`](source/slate/http/) | High-level `HttpClient`, `Request`, `Response`, `HttpTask` worker integration, multi-transfer handle (`multi.d`), and native HTTP/3 + QPACK protocol engines |
| `slate.bin.durl` | [`source/slate/bin/durl.d`](source/slate/bin/durl.d) | `durl` CLI tool for testing HTTP/1.1, HTTP/2, and QUIC/HTTP/3 endpoints |

---

## Build & Test

```bash
# From repository root:
just slate-test-net

# Or directly via DUB:
cd slate-dlang
dub test :net
dub build :net --config=durl
```
