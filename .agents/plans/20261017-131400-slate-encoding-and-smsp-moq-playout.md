# `slate-encoding` Library & SMSP QUIC-Native MoQ Subgroup / `rttVar` Playout Plan

- **Owning Projects**: `slate` (`slate-encoding` at `slate-encoding/`) and `smsp` (`../smsp/`)
- **Status**: `approved`
- **Revision**: `2`
- **Date**: `2026-10-17`

---

## 1. Goal, Scope, and Non-Goals

### Goal
1. Create a new standalone top-level DUB library **`slate-encoding`** at [`../../slate-encoding/`](../../slate-encoding/) (alongside [`../../slint-d/`](../../slint-d/) and [`../../slate-dlang/`](../../slate-dlang/)) providing modern, zero-legacy-ballast, pure-D (`@safe pure`) media codecs and container primitives tailored for **QUIC / HTTP/3 / IETF Media over QUIC (MoQ)** streaming over Home Wi-Fi and LAN.
2. Integrate `slate-encoding` into **SMSP** ([`../../../smsp/`](../../../smsp/)) alongside a **QUIC `rttVar`-Driven MoQ Playout Scheduler** ([`../../../smsp/source/smsp/jitter.d`](../../../smsp/source/smsp/jitter.d)) that reads `minRtt`, `smoothedRtt`, and `rttVar` directly from `slate.quic.recovery.rtt.RttEstimator` (`RFC 9002`) and uses prioritized **MoQ Subgroup Streams** (`Audio`, `Video Base`, `Video Delta`) with selective `RESET_STREAM` / `STOP_SENDING` shedding during Home Wi-Fi airtime stalls.

### Scope
- **`slate-encoding` (`../../slate-encoding/`)**:
  - `slate.encoding.qoi`: Complete **QOI (Quite OK Image)** lossless RGBA8 encoder/decoder (`encodeQoi`, `decodeQoi`, `QoiHeader`) using the 64-entry rolling pixel hash table (`(r*3 + g*5 + b*7 + a*11) % 64`), `QOI_OP_RUN`, `QOI_OP_INDEX`, `QOI_OP_DIFF`, `QOI_OP_LUMA`, `QOI_OP_RGB`, and `QOI_OP_RGBA`.
  - `slate.encoding.qoiv`: **Layered Delta-QOI Video (`QOIV`)** for MoQ Subgroups:
    - **Base Subgroup Layer**: Intra-coded anchor frame (or tiled intra-refresh blocks) encoded with QOI + optional `std.zlib` entropy flattening to prevent Home Wi-Fi AP bufferbloat spikes.
    - **Enhancement Delta Subgroup Layer**: Temporal byte residual $\Delta P[i] = (P_t[i] - P_{t-1}[i]) \bmod 256$ encoded with QOI (`QOI_OP_RUN` collapses static background pixels to 1 byte per 62 pixels, achieving $15\times\text{–}35\times$ P-frame compression).
    - **Codec Telemetry**: Reports `rawBytes`, `compressedBytes`, `compressionRatio`, and per-layer byte breakdown.
  - `slate.encoding.qoa`: **QOA (Quite OK Audio)** time-domain 4-tap LMS (Least Mean Squares) adaptive predictor audio codec (`QoaLmsState`, `encodeQoaSlice`, `decodeQoaSlice`, `encodeQoaFrame`, `decodeQoaFrame`):
    - Compresses 16-bit signed PCM audio at **3.2 bits/sample** ($5.33:1$ compression; 20 samples per 64-bit `ulong` slice) with `< 0.5 ms` algorithmic delay.
    - Includes **`concealQoaUnderrunSlice`** using the 4-tap LMS predictor weights/history to synthesize phase-continuous audio during a Home Wi-Fi stall without clicks or pops.
  - `slate.encoding.loc`: **IETF MoQ Low Overhead Container (`LOC`) & W3C WebCodecs Descriptors** (`MoqSubgroupKind`, `MoqObjectEnvelope`, `WebCodecsConfig` with standard codec strings `"qoi"`, `"qoiv-layered"`, `"qoa"`, `"av01.0.04M.08"`, `"opus"`).
- **`smsp` (`../../../smsp/`)**:
  - Add `slate-encoding` dependency to [`../../../smsp/dub.json`](../../../smsp/dub.json).
  - Add [`../../../smsp/source/smsp/jitter.d`](../../../smsp/source/smsp/jitter.d) implementing **`MoqPlayoutScheduler`**:
    - Directly consumes `RttEstimator` (`minRtt`, `smoothedRtt`, `rttVar`) from [`../../slate-dlang/packages/net/source/slate/quic/recovery/rtt.d`](../../slate-dlang/packages/net/source/slate/quic/recovery/rtt.d).
    - Computes adaptive target playout delay $D_{\text{target}} = \text{minRtt} + 3 \cdot \text{rttVar} + B_{\text{wifiBurst}}$, bounded by `SmspLatencyClass`.
    - Schedules incoming MoQ Subgroup objects by `ptsMicros`, triggers LMS audio concealment on underrun, sheds only the `VideoDelta` subgroup on Wi-Fi airtime stall while preserving `Audio` and `VideoBase`, and applies $1.05\times$ micro-skew catch-up when a delayed Wi-Fi burst arrives.
  - Add a **"Home Wi-Fi (802.11 Burst)"** preset (`"wifi-home"`) to the Network Impairment Lab to model periodic `102.4 ms` beacon/airtime contention stalls (`35 ms` burst jitter, `1.5%` retry loss, `45 Mbps` ceiling).
  - Expose real-time codec compression ratio (`compressionRatio`, `qoiBytes`, `qoaBytes`) and playout scheduler metrics (`targetPlayoutDelayMs`, `quicRttVarMs`, `concealedAudioSlices`, `deltaSubgroupsDropped`, `playoutSpeedRate`) in [`../../../smsp/source/controller.d`](../../../smsp/source/controller.d) and [`../../../smsp/app.slint`](../../../smsp/app.slint).

### Non-Goals
- No legacy RTP (`RFC 3550`), RTCP, SDP, MPEG-TS, or ISO BMFF (`fMP4`/`CMAF`) container parsing.
- No mandatory external C codec dependencies (`ffmpeg`, `libavcodec`, `libaom`); `slate-encoding` compiles 100% with DMD + Phobos out of the box.

---

## 2. Evidence and Current Behavior

### Repository Evidence
1. **Workspace Layout ([`../../AGENTS.md`](../../AGENTS.md), [`../../Justfile`](../../Justfile))**:
   - Top-level libraries in `/home/developer/projects/slate` live at `slint-d/` and `slate-dlang/`. Placing `slate-encoding` at `slate-encoding/` follows the exact same convention and allows both `slate-dlang` and external apps like `smsp` to depend on `"slate-encoding": {"path": "..."}`.
2. **Native QUIC `RFC 9002` RTT & Jitter Telemetry ([`../../slate-dlang/packages/net/source/slate/quic/recovery/rtt.d`](../../slate-dlang/packages/net/source/slate/quic/recovery/rtt.d))**:
   - `RttEstimator` (`_server.lossDetector.rtt` and `_client.lossDetector.rtt`) already computes microsecond-accurate `minRtt`, `smoothedRtt`, `rttVar` (mean deviation of RTT = network jitter), and `latestRtt` per RFC 9002 Section 5.3.
3. **Current SMSP Media & Buffer Limitation ([`../../../smsp/source/smsp/media_gen.d`](../../../smsp/source/smsp/media_gen.d), [`../../../smsp/source/smsp/transport.d`](../../../smsp/source/smsp/transport.d))**:
   - Currently, `media_gen.d` pads synthetic macroblock frames with dummy bytes (`(i * 31 + frameNumber) & 0xFF`) to simulate bitrate, and `transport.d` uses a static step (`+60 ms` / `-90 ms`) for `bufferHealthMs` instead of real compression and `rttVar`-coupled playout scheduling.

### Dataflow & Failure Points (`F1`–`F4`)

```mermaid
sequenceDiagram
    participant Gen as Media Source (RGBA8 + PCM16)
    participant Enc as slate-encoding (QOIV + QOA + LOC)
    participant QuicTx as QUIC Server (Subgroup Streams)
    participant Wifi as Home Wi-Fi Channel (CSMA/CA Bursts)
    participant QuicRx as QUIC Client (LossDetector.rtt)
    participant Sched as MoqPlayoutScheduler (PTS + rttVar)
    participant Ui as Slint Studio Viewport & Audio

    Gen->>Enc: Raw RGBA8 frame + 16-bit PCM audio samples
    Enc->>Enc: Encode QOA Audio (Subgroup 0, Priority 0, 3.2 bps)
    Enc->>Enc: Encode QOIV Base Anchor (Subgroup 1, Priority 1)
    Enc->>Enc: Encode QOIV Temporal Delta + Zlib (Subgroup 2, Priority 2)
    Enc->>QuicTx: 3 MoQ Subgroup Objects with LOC Headers
    QuicTx->>Wifi: Transmit Subgroup 0 (Audio) -> Subgroup 1 (Base) -> Subgroup 2 (Delta)
    alt Clean Home Wi-Fi (rttVar ~ 2ms)
        Wifi->>QuicRx: All 3 Subgroups arrive within targetPlayoutDelay (12-25ms)
        QuicRx->>Sched: Feed RttEstimator (minRtt, smoothedRtt, rttVar) + Subgroups
        Sched->>Ui: Decode Base + Delta -> Full RGBA8 & QOA -> 1.00x Playout
    else Home Wi-Fi Airtime Stall (45ms burst delay, F1/F2)
        Wifi->>QuicRx: Subgroup 0 (Audio) & Subgroup 1 (Base) arrive; Subgroup 2 (Delta) stalls
        QuicRx->>Sched: Subgroup 2 exceeds PTS playout deadline
        Sched->>QuicTx: STOP_SENDING / RESET_STREAM on Subgroup 2 ONLY (F1 recovery)
        Sched->>Ui: Render Subgroup 0 Audio + Subgroup 1 Base Anchor (Zero freeze!)
    else Severe Wi-Fi Roaming Spike (> Playout Cushion, F3)
        Sched->>Ui: Conceal missing audio slice via QOA LMS predictor continuation (F3 recovery)
        Wifi->>QuicRx: Delayed burst arrives -> Queue depth > 1.5x target
        Sched->>Ui: Drain queue at 1.05x micro-skew speed until cushion normalizes
    end
```

- **`F1` (Home Wi-Fi Keyframe Burst Bufferbloat)**: Uncompressed keyframes overflow Wi-Fi AP queues. Mitigated by `QOIV` Base + Zlib entropy smoothing (`slate.encoding.qoiv`).
- **`F2` (Home Wi-Fi Airtime Contention Stall)**: A `25–60 ms` Wi-Fi stall delays P-frame enhancement bytes. Mitigated by isolating Audio (`Subgroup 0`), Video Base (`Subgroup 1`), and Video Delta (`Subgroup 2`) so only `Subgroup 2` is shed via `RESET_STREAM`.
- **`F3` (Audio Playout Underrun)**: Packet stall exceeds current playout cushion. Mitigated by `concealQoaUnderrunSlice` (LMS predictor continuation) and dynamic expansion of `targetPlayoutDelayMs` from `QUIC.rttVar`.
- **`F4` (Corrupted / Truncated Wire Payload)**: Malformed QOI/QOA/LOC headers or truncated byte slices. Mitigated by strict header bounds validation (`in`/`out` contracts and `CodecResult!T` status returns, never panicking).

---

## 3. Proposed Design and Material Decisions (`D1`–`D4`)

### `D1`: Library Placement & Dependency Graph (`slate-encoding`)
- **Selected Approach**: Top-level library at `/home/developer/projects/slate/slate-encoding` (`dub` package name `"slate-encoding"`, module root `slate.encoding`) with **zero external dependencies** (D runtime + Phobos `std.zlib` only).
- **Rationale**: Keeps `slate-encoding` fast to compile, 100% `@safe pure`, usable by `slate-dlang`, `smsp`, or any standalone D application without C library installation hurdles.

### `D2`: Layered Video Codec (`QOIV` = Standard `QOI` + Temporal Residual Delta + Zlib)
- **Selected Approach**:
  - Implement spec-compliant **QOI** (`qoi.d`) so standard `.qoi` images can be encoded/decoded losslessly.
  - Layer **`QOIV`** (`qoiv.d`) on top of QOI:
    - **Subgroup 1 (`VideoBase`)**: Encodes an anchor representation (for I-frames: full QOI + Zlib; for P-frames: a compact $16\times16$ macroblock anchor preview) so the receiver always has a valid visual anchor even if enhancement deltas are dropped.
    - **Subgroup 2 (`VideoDelta`)**: Computes byte-wise temporal residual $\Delta P[i] = (P_t[i] - P_{t-1}[i]) \bmod 256$ against the previous frame and compresses it with QOI + Zlib. Static regions compress at $>30:1$.

### `D3`: Audio Codec (`QOA` 4-Tap LMS Adaptive Predictor + Underrun Concealment)
- **Selected Approach**: Implement **QOA (Quite OK Audio)** in `slate.encoding.qoa`:
  - 4-tap LMS predictor (`weights[4]`, `history[4]`), 16 scale factors, 3-bit residual dequantization table, packing 20 samples into one 64-bit `ulong` slice (`3.2 bits/sample`, $5.33:1$ compression ratio).
  - Add `concealQoaSlice(ref QoaLmsState lms, double decay = 0.92)` which predicts the next 20 samples with zero residual and gentle energy decay when a Wi-Fi stall causes a temporary buffer underrun.

### `D4`: QUIC `rttVar`-Driven MoQ Playout Scheduler (`MoqPlayoutScheduler`)
- **Selected Approach**: Implement `MoqPlayoutScheduler` in `smsp/source/smsp/jitter.d`:
  - Coupled directly to `slate.quic.recovery.rtt.RttEstimator`:
    $$\text{targetDelayMicros} = \text{clamp}\!\left(\text{minRtt} + 3 \cdot \text{rttVar} + \text{burstMargin},\; \text{minClassDelay},\; \text{maxClassDelay}\right)$$
  - Maintains a PTS-ordered playout queue of decoded MoQ objects, tracks buffer depth (`bufferDepthMs`), drops expired `VideoDelta` subgroups without touching `Audio` or `VideoBase`, invokes QOA LMS concealment on underruns, and sets `playoutRate = 1.05` when `bufferDepthMs > 1.35 * targetDelayMs` to smoothly drain post-stall Wi-Fi bursts.

---

## 4. Requirements (EARS) and Acceptance Tests (Gherkin)

### EARS Requirements

| ID | Category | Requirement |
|----|----------|-------------|
| `U1` | Ubiquitous | The `slate-encoding` library (`slate.encoding.qoi`) shall losslessly encode and decode 4-channel RGBA8 pixel buffers to and from the standard QOI wire format (`"qoif"` 14-byte header + opcodes + 8-byte end marker). |
| `U2` | Ubiquitous | The `slate-encoding` library (`slate.encoding.qoiv`) shall encode video frames into layered `VideoBase` and `VideoDelta` (temporal residual + QOI + Zlib) payloads and reconstruct the exact RGBA8 frame when both layers are applied in sequence, achieving $\ge 4\times$ compression on keyframes and $\ge 10\times$ compression on low-motion delta P-frames. |
| `U3` | Ubiquitous | The `slate-encoding` library (`slate.encoding.qoa`) shall encode 16-bit signed PCM audio into 64-bit QOA slices (`20` samples per `ulong`, `5.33:1` compression) using a 4-tap LMS predictor and reconstruct the waveform with bounded SNR/MSE and phase-continuous underrun concealment (`concealQoaSlice`). |
| `U4` | Ubiquitous | The `slate-encoding` library (`slate.encoding.loc`) shall serialize and deserialize IETF MoQ Low Overhead Container (`LOC`) subgroup object headers carrying W3C WebCodecs codec identifiers, subgroup priority (`Audio=0`, `VideoBase=1`, `VideoDelta=2`), `groupId`, `objectId`, `ptsMicros`, and payload length. |
| `E1` | Event-driven | When `QuicConnection` updates its `RttEstimator` (`minRtt`, `smoothedRtt`, `rttVar`), the `MoqPlayoutScheduler` (`smsp.jitter`) shall recalculate `targetPlayoutDelayMs` as $\text{minRtt} + 3 \cdot \text{rttVar} + \text{burstMargin}$ clamped to the active `SmspLatencyClass` bounds. |
| `E2` | Event-driven | When a Home Wi-Fi airtime stall delays a GOP's `VideoDelta` subgroup past its presentation deadline while `Audio` and `VideoBase` subgroups have arrived, `SmspTransceiver` and `MoqPlayoutScheduler` shall issue QUIC `RESET_STREAM` / `STOP_SENDING` only on the `VideoDelta` stream and play out the `Audio` + `VideoBase` anchor without stalling playback. |
| `E3` | Event-driven | When the playout queue experiences an underrun during a severe network spike, `MoqPlayoutScheduler` shall synthesize a phase-continuous audio slice via `concealQoaSlice` and increment `concealedAudioSlices`; when the delayed Wi-Fi burst subsequently arrives and pushes queue depth above $1.35 \times \text{targetPlayoutDelayMs}$, the scheduler shall engage $1.05\times$ catch-up speed until the queue normalizes. |
| `W1` | Unwanted behavior | If any decoder in `slate.encoding` (`decodeQoi`, `decodeQoivFrame`, `decodeQoaFrame`, `decodeLocHeader`) receives truncated, zero-length, or corrupted bytes, then it shall return `ok = false` with a descriptive error message without throwing an unhandled exception or reading out of bounds. |

### Acceptance Scenarios

```gherkin
Scenario: T1 - Lossless QOI RGBA8 round-trip and compression ratio (covers U1, W1)
  Given a 64x64 RGBA8 SMPTE color bar & motion test image (16,384 raw bytes)
  When encoded with `encodeQoi` and decoded with `decodeQoi`
  Then the decoded RGBA8 buffer matches the input byte-for-byte
  And the compressed QOI payload is at least 4x smaller than 16,384 bytes
  And truncated or corrupted QOI buffers return `ok == false` safely

Scenario: T2 - Layered Delta-QOI (QOIV) Keyframe + Temporal Delta P-Frame round-trip (covers U2, W1)
  Given two consecutive 64x64 RGBA8 video frames where only a moving reticle changes position
  When Frame 0 is encoded as a QOIV Keyframe and Frame 1 is encoded as a QOIV Layered Delta (VideoBase + VideoDelta)
  Then Frame 1's VideoDelta layer achieves >= 10x compression over raw RGBA8
  And applying Frame 1's VideoDelta to Frame 0 reconstructs Frame 1 byte-for-byte
  And if Frame 1's VideoDelta layer is dropped, decoding Frame 1's VideoBase anchor still produces a valid 64x64 RGBA8 frame

Scenario: T3 - QOA 4-tap LMS Audio 5.33:1 encoding, decoding, and Wi-Fi underrun concealment (covers U3, W1)
  Given 240 samples (12 slices, 480 bytes) of 48 kHz 16-bit sine/harmonic PCM audio
  When encoded into QOA frame bytes and decoded back to 16-bit PCM
  Then the QOA payload is compressed at > 4.5x (96 bytes of slice data + 8-byte header)
  And the decoded waveform correlates closely with the original signal (normalized RMS error < 0.08)
  And calling `concealQoaSlice` on an underrun produces 20 non-NaN phase-continuous samples that decay smoothly

Scenario: T4 - MoQ LOC Header round-trip with Subgroup Priorities and WebCodecs descriptors (covers U4, W1)
  Given a MoQ LOC Object Header for Subgroup `VideoDelta` (priority 2, codec "qoiv-layered", groupId 42, objectId 3, ptsMicros 66666)
  When serialized and deserialized via `slate.encoding.loc`
  Then all fields round-trip identically and truncated buffers are rejected safely

Scenario: T5 - QUIC rttVar-Driven Playout Scheduler & Selective Subgroup Shedding on Home Wi-Fi Stall (covers E1, E2, E3)
  Given an `SmspTransceiver` and `MoqPlayoutScheduler` running under the `"wifi-home"` impairment preset
  When `RttEstimator` reports rising `rttVar` from a Wi-Fi airtime stall
  Then `targetPlayoutDelayMs` adapts dynamically from `minRtt + 3 * rttVar`
  And when Subgroup 2 (`VideoDelta`) exceeds the deadline while Subgroup 0 (`Audio`) and Subgroup 1 (`VideoBase`) arrive, only Subgroup 2 is reset via QUIC `RESET_STREAM`
  And when a burst of delayed frames arrives after an underrun, `concealedAudioSlices` > 0 and `playoutSpeedRate` rises to 1.05x to drain excess lag
```

### Coverage Matrix

| Scenario | Requirement IDs | Target Test File / Suite | Layer |
|----------|-----------------|--------------------------|-------|
| `T1` | `U1`, `W1` | `slate-encoding/source/slate/encoding/qoi.d` (`dub test --root=slate-encoding`) | Unit |
| `T2` | `U2`, `W1` | `slate-encoding/source/slate/encoding/qoiv.d` (`dub test --root=slate-encoding`) | Unit |
| `T3` | `U3`, `W1` | `slate-encoding/source/slate/encoding/qoa.d` (`dub test --root=slate-encoding`) | Unit |
| `T4` | `U4`, `W1` | `slate-encoding/source/slate/encoding/loc.d` (`dub test --root=slate-encoding`) | Unit |
| `T5` | `E1`, `E2`, `E3` | `../smsp/source/smsp/jitter.d` & `../smsp/source/smsp/transport.d` (`dub test --root=../smsp`) | Integration |

---

## 5. Affected Files and Implementation Steps

### Phase 1: `slate-encoding` Standalone Library (`../../slate-encoding/`)
1. **`[NEW]` [`../../slate-encoding/dub.json`](../../slate-encoding/dub.json)** & **[`../../slate-encoding/README.md`](../../slate-encoding/README.md)**:
   - Configure DUB library `"slate-encoding"` (`targetType: "library"`, zero external dependencies).
2. **`[NEW]` [`../../slate-encoding/source/slate/encoding/package.d`](../../slate-encoding/source/slate/encoding/package.d)**:
   - Public umbrella re-exporting `qoi`, `qoiv`, `qoa`, and `loc`.
3. **`[NEW]` [`../../slate-encoding/source/slate/encoding/qoi.d`](../../slate-encoding/source/slate/encoding/qoi.d)** (`Red -> Green -> Iterate` for `T1`):
   - Implement `QoiDesc`, `QoiDecodeResult`, `encodeQoi`, and `decodeQoi`.
4. **`[NEW]` [`../../slate-encoding/source/slate/encoding/qoiv.d`](../../slate-encoding/source/slate/encoding/qoiv.d)** (`Red -> Green -> Iterate` for `T2`):
   - Implement `QoivLayerKind`, `QoivEncodedFrame` (`baseLayerBytes`, `deltaLayerBytes`, `rawBytes`, `compressionRatio`), `encodeQoivFrame`, and `decodeQoivFrame` (supporting both full Base+Delta reconstruction and Base-only fallback when Delta is shed on Wi-Fi).
5. **`[NEW]` [`../../slate-encoding/source/slate/encoding/qoa.d`](../../slate-encoding/source/slate/encoding/qoa.d)** (`Red -> Green -> Iterate` for `T3`):
   - Implement `QoaLmsState`, `encodeQoaSlice`, `decodeQoaSlice`, `encodeQoaFrame`, `decodeQoaFrame`, and `concealQoaSlice`.
6. **`[NEW]` [`../../slate-encoding/source/slate/encoding/loc.d`](../../slate-encoding/source/slate/encoding/loc.d)** (`Red -> Green -> Iterate` for `T4`):
   - Implement `MoqSubgroupKind` (`audio = 0`, `videoBase = 1`, `videoDelta = 2`), `MoqLocHeader`, `encodeLocHeader`, `decodeLocHeader`, and `WebCodecsDescriptor`.
7. **`[MODIFY]` [`../../Justfile`](../../Justfile)** & **[`../../AGENTS.md`](../../AGENTS.md)**:
   - Add `d-encoding-test` (`dub test --root=slate-encoding`) and include `slate-encoding/source` in `just d-lint` and `just d-fmt`.

### Phase 2: SMSP Integration & QUIC `rttVar` Playout Scheduler (`../../../smsp/`)
8. **`[MODIFY]` [`../../../smsp/dub.json`](../../../smsp/dub.json)**:
   - Add `"slate-encoding": {"path": "/home/developer/projects/slate/slate-encoding"}` dependency.
9. **`[NEW]` [`../../../smsp/source/smsp/jitter.d`](../../../smsp/source/smsp/jitter.d)** (`Red -> Green -> Iterate` for `T5`):
   - Implement `MoqPlayoutScheduler` coupled to `slate.quic.recovery.rtt.RttEstimator`, managing `targetPlayoutDelayMs`, `quicRttVarMs`, PTS-ordered frame playout, QOA LMS underrun concealment, selective `VideoDelta` subgroup shedding, and $1.05\times$ catch-up speed.
10. **`[MODIFY]` [`../../../smsp/source/smsp/media_gen.d`](../../../smsp/source/smsp/media_gen.d)**, **[`../../../smsp/source/smsp/transport.d`](../../../smsp/source/smsp/transport.d)**, **[`../../../smsp/source/controller.d`](../../../smsp/source/controller.d)**, **[`../../../smsp/source/main.d`](../../../smsp/source/main.d)**, and **[`../../../smsp/app.slint`](../../../smsp/app.slint)**:
    - Encode generated frames with `slate.encoding.qoiv` + `slate.encoding.qoa` + `slate.encoding.loc`.
    - Add the `"wifi-home"` (`Home Wi-Fi Burst`) preset and surface real-time compression ratio (`QOIV + QOA`), `QUIC rttVar`, `Target Playout Cushion (ms)`, `Delta Subgroups Shed`, and `Audio Concealment` telemetry in the Studio UI.

---

## 6. Verification

### Planned Verification Commands
1. **`slate-encoding` Unit Tests**:
   ```bash
   dub test --root=/home/developer/projects/slate/slate-encoding
   ```
2. **`smsp` Unit & Integration Tests**:
   ```bash
   dub test --root=/home/developer/projects/smsp
   ```
3. **Formatting & Static Analysis (`dfmt` + `dscanner` + `slint_check`)**:
   ```bash
   just d-fmt && just d-lint
   dscanner --syntaxCheck /home/developer/projects/smsp/source
   dscanner --styleCheck --config /home/developer/projects/slate/dscanner.ini /home/developer/projects/smsp/source
   ```
4. **Native Headless Snapshot Verification**:
   ```bash
   cd /home/developer/projects/smsp && \
     LD_LIBRARY_PATH="/home/developer/projects/slate/slint-d/bridge/target/debug:/home/developer/projects/slate/slate-dlang/lib" \
     SLINT_BACKEND=software dub run --config=native -- --shot preview.png
   ```

### Verification Gates (`G1`–`G5`)
- **`G1` (Encapsulation & Zero Legacy Ballast)**: `slate-encoding` has zero external C library dependencies beyond Phobos (`std.zlib`), exposes clean D structs/slices without leaking raw C pointers, and contains zero RTP/RTCP/fMP4 legacy ballast.
- **`G2` (Memory & Bounds Safety)**: All `slate.encoding.*` and `smsp.jitter` functions are `@safe` (`@trusted` only around audited Phobos `std.zlib.compress`/`uncompress` calls if required), validate untrusted dimensions/lengths against integer overflow (`width * height * channels` overflow guard and `maxPixels` cap), and never read or write out of bounds on truncated/malformed input (`W1`).
- **`G3` (Algorithmic Authenticity & Zero Hardcoding)**: QOI (`qoi.d`), Layered Delta-QOI (`qoiv.d`), QOA 4-tap LMS (`qoa.d`), MoQ LOC (`loc.d`), and `MoqPlayoutScheduler` (`jitter.d`) compute all outputs dynamically using real specifications—no hardcoded test vector return values or stubbed branches.
- **`G4` (Mandatory Test Headers & Lint Gate)**: Every `unittest` block across `slate-encoding` and `smsp` carries both a `// Spec:` comment header and a `/// Example:` Ddoc header, and passes `dfmt` + `dscanner --syntaxCheck` + `dscanner --styleCheck --config /home/developer/projects/slate/dscanner.ini` with zero warnings.
- **`G5` (Bounded Allocation & DoS Resilience)**: Decoders reject oversized dimensions (`width * height > MAX_QOI_PIXELS`, e.g., `16_777_216` pixels) and oversized audio frame sample counts before allocating output buffers to prevent memory exhaustion DoS attacks.

---

## 7. Risks and Delivery

- **Backward Compatibility**: Existing SMSP control commands, HTTP/3 fallback routes, and MCP actions remain 100% compatible while gaining real `QOIV`/`QOA` payload compression and `MoqPlayoutScheduler` telemetry.
- **Memory & Bounds Safety**: All `slate-encoding` codecs enforce strict bounds checks on untrusted input slices (`W1`) and avoid GC allocations in inner LMS/hash loops.

---

## 8. Assumptions, Open Questions, and Approval

- **Resolved Decision**: `slate-encoding` will be created at `/home/developer/projects/slate/slate-encoding` as a top-level library alongside `slint-d` and `slate-dlang`.
- **Approval Status**: Approved by user (`2026-10-17`) for execution via `/adversarial-tdd-workflow`.
