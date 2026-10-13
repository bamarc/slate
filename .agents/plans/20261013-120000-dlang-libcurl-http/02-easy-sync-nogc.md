# P2 — Sync easy client with @nogc boundary

Owns: UB-1, UB-4, UB-5 (enforcement starts), EV-1, EV-3 (single-transfer half), UN-1, UN-3. Depends on P1.

## 1. Goal

Idiomatic `@safe` single-transfer path over `easy`: `Client`, `Request`, `Response`, streaming `byChunk`.

## 2. EARS

- **UB-1:** THE wrapper SHALL expose value-type `Client`/`Request`/`Response` + `HttpVersion{auto_,h1_1,h2,h2Tls,h3,h3Only}`; raw `CURLOPT_*` SHALL NOT appear publicly.
- **UB-4:** ALL hot-path execution (perform, write/header/progress callbacks, `byChunk`) SHALL be `@nogc` (`nothrow` for callbacks).
- **EV-1:** WHEN `request()` runs THEN it SHALL return `Result!Response` (status/headers/body) and map `CURLcode` to `CurlException`.
- **EV-3a:** WHEN body exceeds threshold THEN single transfer SHALL stream via `byChunk` input range without full buffering.
- **UN-1:** Hot paths SHALL NOT GC-allocate, close over GC delegates, or call non-`@nogc` runtime in callbacks.
- **UN-3:** Failures SHALL NOT leak `CURL*`; cleanup SHALL use `scope(exit)` RAII on all throw paths.

## 3. Design

- `request.d`: `struct Request{url, Method, headers[], Body}` with `in` contracts (non-empty URL, valid method); builder methods may allocate (cold path, documented).
- `response.d`: `struct Response{status, headers, body[]}` + `byChunk` `@nogc` input range over caller buffer; `invariant(status in 100..599)`.
- `client.d` (easy half): `struct Client` owns `CURL*` per transfer or short-lived handle; `@disable thisCopy`, move semantics; `get/post/request` are `@safe @nogc` (throwing via preallocated path); options struct maps to `CURLOPT_HTTP_VERSION`, timeouts, `SSL_VERIFYPEER/HOST`, `ACCEPT_ENCODING`.
- FFI boundary: callbacks are `extern(C) function … @nogc nothrow` + `void* ctx`; `@trusted` adapters convert to slices; userdata rooted for transfer duration (no GC move issue in D, but lifetime enforced by scope).
- Memory split doc: builder (GC ok) vs `perform` (never GC) with examples of each.

## 4. TDD

```gherkin
  Scenario: TC-03 hot path is nogc (UB-4, UN-1)
    # Best practice: @nogc callbacks + no GC delegates across C ABI
    # Use: compile-time @nogc perform example
    Given a @nogc unittest context
    When I perform a GET and iterate byChunk
    Then it compiles under @nogc and callbacks are function+void* only

  Scenario: TC-05 error mapping (EV-1, UN-3)
    # Spec: libcurl CURLcode docs
    # Use: try/catch CurlException example, handle leak-free
    Given an unroutable host
    When I perform
    Then I get CurlException with code preserved and handles freed

  Scenario: TC-04a streaming single body (EV-3)
    # Spec: RFC9110 framing; Best practice: no full buffering
    # Use: byChunk download-to-file example
    Given a large response
    When I consume byChunk
    Then chunks arrive without full-body allocation
```

Order: TC-05 → TC-03 → TC-04a. Red first against local HTTP/1.1 stub; H2/H3 servers arrive in P4 but version enum is unit-tested here with mocked gates.

## 5. Done criteria

- `@nogc:` blocks compile for perform + iteration; `grep` finds no `delegate` crossing into `c_bind`.
- Throw-injection test proves `CURL*` freed (handle-count or valgrind/asan gate where available).
- All unittests carry Spec/Example headers.
