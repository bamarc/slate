# slate-encoding

Zero-legacy-ballast, `@safe pure` media codecs and container primitives tailored for QUIC, HTTP/3, and Media over QUIC (MoQ) streaming.

## Codecs and Modules

- `slate.encoding.qoi`: Lossless Quite OK Image (QOI) 24/32-bit encoder and decoder.
- `slate.encoding.qoiv`: Layered Delta-QOI Video (Base + Temporal Delta residual) for prioritized MoQ subgroup streaming.
- `slate.encoding.qoa`: Quite OK Audio (QOA) 4-tap LMS adaptive predictor audio codec (3.2 bits/sample, 5.33:1 compression) with phase-continuous Wi-Fi underrun concealment.
- `slate.encoding.loc`: IETF MoQ Low Overhead Container (LOC) object headers and W3C WebCodecs descriptors.
