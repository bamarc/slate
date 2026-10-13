# P5 — Hardening: TLS, timeouts, redirects, observability, leak audit

Depends on P2+P3+P4. No public-signature breaks except documented additions.

## 1. Goal

Production-grade defaults and auditability.

## 2. EARS

- TLS: Verification SHALL default ON; disabling SHALL require explicit opt-in flag that logs/audits. Bundle path SHALL be configurable; missing bundle SHALL error with actionable message.
- Timeouts: Connect + total-time defaults SHALL exist and be overrideable per-`Request`; timeout SHALL map to `TimeoutException` preserving `CURLE_OPERATION_TIMEDOUT`.
- Redirects: Redirect-following SHALL be opt-in with max-count; downgrade HTTPS→HTTP on redirect SHALL be refused by default.
- Observability (OPT-1): Debug builds MAY expose verbose/qlog callback hooks; hooks SHALL be `@nogc nothrow` sinks taking caller buffers.
- Leak audit (UN-3): All `CURL*`/`CURLM*`/`curl_slist` paths SHALL be `scope(exit)`-guarded; fault-injection suite SHALL prove zero growth over N iterations.

## 3. Design

- `client.d` additions: `TlsMode{verify, insecureOptIn}`, `Timeouts{connectMs,totalMs}`, `Redirect{off,follow}`; all `in`-contracted, propagated to `CURLOPT_SSL_VERIFYPEER/HOST`, `CAINFO`, `CONNECTTIMEOUT_MS`, `TIMEOUT_MS`, `FOLLOWLOCATION`, `MAXREDIRS`, `REDIR_PROTOCOLS_STR`.
- `debug_.d` (new, tiny): verbose-write sink interface, compiled in under `version(SlateHttpDebug)` only.
- Audit: `tests/leak_iterations.d` — 10k pooled GETs assert stable handle/RSSProxy (where measurable); throw-injection at each allocation point.

## 4. TDD

```gherkin
  Scenario: TC-10 TLS defaults
    # Spec: curl SSL_VERIFYPEER docs; Best practice: secure by default
    # Use: custom CA bundle example + explicit insecure opt-in example
    Given default Client against self-signed harness
    When I GET without bundle
    Then it fails closed; with bundle it succeeds; insecure flag logs opt-in

  Scenario: TC-11 timeouts + redirects
    # Spec: RFC9110 redirects; curl FOLLOWLOCATION/MAXREDIRS
    # Use: timeout + max-redirects example
    Given slow and redirecting endpoints
    When limits exceeded
    Then TimeoutException / TooManyRedirects with handles freed

  Scenario: TC-12 leak soak (UN-3)
    # Best practice: scope(exit) RAII on every handle path
    # Use: pooled soak example for high-iteration services
    Given pooled Client
    When I run N iterations with injected failures
    Then handle count is stable and no GC growth in hot path
```

## 5. Done criteria

- Fault-injection + soak green; default-verify proven against self-signed harness.
- Final review: EARS→TC matrix 100% mapped, UB-5 header check passes, G1–G5 meta gates green.
