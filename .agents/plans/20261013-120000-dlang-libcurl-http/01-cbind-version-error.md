# P1 — Raw bind + version + error

Owns: UB-2, UB-3, EV-2 (gate half). Blocks P2.

## 1. Goal

Fresh minimal `extern(C)` binding to modern libcurl (`curl/curl.h`, `multi.h`) plus runtime feature detection and exception mapping. No public HTTP API yet.

## 2. EARS

- **UB-2:** THE binding SHALL cover `easy` + `multi` + `curl_version_info`; it SHALL NOT reuse `etc.c.curl`.
- **UB-3:** THE `Version` module SHALL expose `hasHttp2()`, `hasHttp3()` derived from `curl_version_info` `CURL_VERSION_HTTP2|HTTP3`.
- **EV-2a:** WHEN linked libcurl lacks H3 AND caller queries H3 THEN the query SHALL return `false` with a documented message naming the minimum libcurl/TLS backend.

## 3. Design

- `source/slate/http/c_bind.d`: private, `@system`, `extern(C)` decls only (`curl_easy_*`, `curl_multi_*`, `curl_version_info`, option/info enums needed by P2/P3). `version(HaveCurlHttp3)` guards H3-only opts.
- `source/slate/http/version_.d`: `@trusted @nogc nothrow` wrappers over `curl_version_info`; pure query functions + `describeBackend()` string for diagnostics (GC allowed in describe only).
- `source/slate/http/error.d`: `enum CurlCode`, `class CurlException : Exception` (code preserved), `class HttpStatusException`, pure `@nogc` mapping functions; preallocated-message path for `@nogc` throw sites.
- `dub.json`: `libs: ["curl"]`, `pkg-config` note, minimum 8.6 documented; CI matrix entry curl+nghttp2 (H3 absent) vs full H3 build.

## 4. TDD (each test needs Spec/Best-practice + Example)

```gherkin
  Scenario: TC-01 version gating (UB-3, EV-2)
    # Spec: curl docs curl_version_info + CURL_VERSION_HTTP3
    # Use: document hasHttp3() guard before h3Only
    Given system libcurl info
    When I query hasHttp2/hasHttp3
    Then results match CURL_VERSION bits
    And requesting h3Only without H3 fails fast with documented message
```

Unittests:

1. `version_`: bits → bool mapping (mocked `curl_version_data`), `@nogc` assert block.
2. `error`: table test `CURLcode` → message/code preserved; throw/catch preserves code; RAII: no handle involved yet.
3. `c_bind`: link smoke — `curl_global_init/cleanup` + `curl_version()` returns non-empty; skipped with clear message if libcurl < minimum.

## 5. Done criteria

- `dub test` P1 subset green on both matrix entries; H3-absent entry asserts `hasHttp3()==false`.
- No `etc.c.curl` import anywhere (`grep` gate).
- Review: every unittest has `// Spec:`/`// Best practice:` + `/// Example:`.
