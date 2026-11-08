# Conformance vectors

Language-neutral test vectors that **both** implementations must pass, so behaviour cannot drift
while the Swift daemon (macOS) and the Rust port (`poc/reverse-attach-linux`, Linux) coexist
(#24, `docs/adr/linux-rust-port.md`). The Swift implementation is the oracle.

| File | Covers | Swift test | Rust test |
|---|---|---|---|
| `auth_vectors.json` | `AuthPolicy`: validate + allow/deny decision and exact reason strings (reason strings: see parity checklist §4) | `ConformanceVectorTests.testAuthPolicyVectors` | `auth::conformance` |
| `reverse_attach_vectors.json` | §9.2 close-code / handshake-status disposition, `attachURL` | `ConformanceVectorTests.testReverseAttachVectors` | `attach::conformance` |
| `mcp_wire_vectors.json` | JSON-RPC layer: `initialize`, `ping`, `tools/list`, `tools/call` errors, notifications, parse and envelope errors. Rust runs each case over `POST /mcp` and the reverse-attach path; drift would be pinned in `known_drift` (empty since #78) | `WireConformanceTests.testEveryWireCaseMatchesTheSwiftOracle` | `wire_conformance::wire_fixtures_match_the_swift_oracle_and_pin_known_drift` |
| `mcp_http_vectors.json` | `/mcp` HTTP layer after auth: Content-Type (415), envelope errors as 400, `Mcp-Session-Id` issue / check (404) / `DELETE`, notifications (202), `GET` and other methods (405). Steps in a case share one endpoint | `HTTPConformanceTests.testEveryHTTPCaseMatchesTheSwiftOracle` | `http_conformance::http_fixtures_match_the_swift_oracle` |
| `profile_vectors.json` | Tool profiles (#59): the two names, the default (`observe`), `desktop` → `observe` with the retired warning, the 400 message, persisted-grant resolution (never widens), per-profile local and upstream membership against the full `browser_*` fixture, tool classes, shell-equivalence | `ConformanceVectorTests.testProfileVectors`, `BrowserProfileTests` | `profile_conformance` |

Both run in CI on every PR (`swift test`, `cargo test`). Change a vector only for an intended
behaviour change, and make both implementations pass in the same PR.

Dial-side and credential negatives that need code rather than a vector file live next to the
code: `ReverseAttachNegativeTests.swift` and `attach/client_tests.rs` (refused 401, wrong,
same-length or empty bearer, no plaintext fallback; plus a runtime-side check that an upgrade
with no Authorization is refused, which the dialer never sends), `attach/grant_secrecy_tests.rs` and
`AttachCredentialSecrecyTests` (the attach secret never appears in a grant body).

Open items, the parity gate, and the known drift list are in
[`docs/parity-checklist.md`](../docs/parity-checklist.md).
