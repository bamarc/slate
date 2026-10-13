# P3 — Multi multiplex + H2/H3 pooling

Owns: ST-1, ST-2, ST-3, EV-2 (full), EV-4. Depends on P2 (reuses its types unchanged).

## 1. Goal

Concurrent connection-reusing path over `curl_multi` delivering real H2 multiplex and H3/QUIC.

## 2. EARS

- **ST-1:** WHILE a `Client` is reused, open H2/H3 connections SHALL be reused via `multi` (no per-request reconnect where server allows).
- **ST-2:** WHILE in `h3Only` the wrapper SHALL NOT silently fall back to TCP/H2; unavailability SHALL error.
- **ST-3:** WHILE in `auto_` the wrapper SHALL negotiate max version via ALPN/Alt-Svc per libcurl defaults.
- **EV-2b:** WHEN `h3Only` is set AND `hasHttp3()==false` THEN perform SHALL fail before socket creation.
- **EV-4:** WHEN cancellation is signalled THEN in-flight transfers SHALL abort via nonzero progress-callback return mapping to a documented `CancelledException`/result.

## 3. Design

- `multi.d`: `struct MultiClient` / pooled `Client` holding `CURLM*` + `CURLSH*` (optional share) + Alt-Svc cache dir option; `request` enqueues easy handles with `CURLOPT_HTTP_VERSION` per `HttpVersion`, `CURLOPT_ALT_SVC`, `CURLOPT_QUICK_EXIT` semantics as available; `performAll` drives `curl_multi_perform/wait` loop, all `@nogc`.
- Pooling: one `Client` instance == one pool; docs forbid per-request construction in hot loops (UN-2); pool counters exposed for tests (`numConnects` via `CURLINFO_NUM_CONNECTS`).
- Cancellation: `@nogc nothrow` progress callback polls shared atomic flag; maps to early abort.
- H3 specifics: `CURLOPT_HTTP_VERSION=CURL_HTTP_VERSION_3ONLY` vs `3`, UDP/QUIC errors surfaced distinctly from TCP errors.

## 4. TDD

```gherkin
  Scenario: TC-02 pooled reuse (ST-1)
    # Spec: RFC9110 GET; Best practice: reuse Client
    # Use: pooled Client.get example for docs
    Given a reused Client
    When I GET twice over H2
    Then both return 200 and connections are reused

  Scenario: TC-06 no silent H3 downgrade (ST-2, ST-3)
    # Spec: RFC9114 + Alt-Svc RFC9460; curl CURLOPT_HTTP_VERSION
    # Use: h3Only vs auto_ selection example
    Given h3Only Client
    When H3 is unavailable
    Then it errors rather than falling back to H2/H1

  Scenario: TC-07 cancellation (EV-4)
    # Best practice: cooperative abort without handle leak
    # Use: cancel flag example
    Given a slow transfer with cancel flag set mid-flight
    When the progress callback fires
    Then the transfer aborts and handles are freed
```

Needs P4's local H2/H3 servers for full green; P3 lands with interface + unit/mocked-info tests, integration marked `version(IntegrationTest)` pending P4 harness.

## 5. Done criteria

- Reuse assertion: two sequential H2 GETs → `numConnects==1` where server supports it.
- `h3Only`-without-H3 and H3-unreachable tests error, never 200-over-H2.
- Cancel test completes under timeout with zero handle growth.
