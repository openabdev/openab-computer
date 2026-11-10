# Parity checklist (Phase 3 gate)

This checklist is the gate for retiring the Swift daemon (Phase 3) in
`docs/adr/linux-rust-port.md`. The executable part is the suite in
[`conformance/`](../conformance/README.md), which runs in `swift test` (oracle)
and in `cargo test --release` (Rust port). This file lists what the suite does
not cover yet, and the status of each row. Status values: **pass** (both
backends agree and a test pins it), **drift** (the backends differ, pinned in
`known_drift`), **open** (not yet tested).

Refs #24, #79.

## 1. Gate conditions

Every row must be green on both backends before Phase 3 starts:

- every file in `conformance/` passes in `swift test` and in `cargo test --release`;
- `conformance/mcp_wire_vectors.json` has an empty `known_drift` list;
- the reverse-attach negatives pass in both suites;
- the per-tool table in section 5 has no open row;
- the profile rows in section 6 pass (filled in by #59).

## 2. Wire layer (JSON-RPC)

One row per case in `conformance/mcp_wire_vectors.json`. The Swift result is the
oracle. The Rust column reflects the `known_drift` list, which has been empty
since #78. The Rust runner sends every case through both entry points, `POST /mcp`
(`mcp::answer`) and a reverse-attach socket (`mcp::answer_attached`), as Swift
uses one parser and dispatcher for both.

| Case | Swift | Rust | Test |
|------|-------|------|------|
| initialize negotiates 2024-11-05 | protocolVersion 2024-11-05 | pass | `WireConformanceTests`, `wire_conformance` |
| initialize negotiates 2025-03-26 | protocolVersion 2025-03-26 | pass | same |
| initialize negotiates 2025-06-18 | protocolVersion 2025-06-18 | pass (#78) | same |
| initialize with unknown version | falls back to 2025-06-18 | pass (#78) | same |
| initialize without a version | 2025-06-18 | pass | same |
| ping | result `{}` | pass (#78) | same |
| tools/list shape | tools with name, description, inputSchema | pass | same |
| tools/call unknown tool | error -32602 | pass (#78) | same |
| tools/call of a tool the profile hides | error -32602, same as unknown | pass (#78) | same |
| tools/call missing name | error -32602 | pass | same |
| unknown method | error -32601 | pass | same |
| resources/list, prompts/list | empty lists | pass (#78) | same |
| notification | no response | pass | same |
| `"id": null` | notification, no response | pass (#78) | same |
| malformed JSON | error -32700, id null | pass (#78) | same |
| empty array | error -32700 | pass (#78) | same |
| object without `method` | error -32700 (the Swift decoder fails before the envelope check) | pass (#78) | same |
| jsonrpc "1.0" | error -32600, id null | pass (#78) | same |
| batch array | error -32600, id null | pass (#78) | same |

## 3. HTTP layer

One row per case in `conformance/mcp_http_vectors.json` (#78), which covers
`/mcp` after auth. Swift runs it through `MCPHTTPEndpoint.handle`
(`HTTPConformanceTests`), Rust through `http::mcp_route`
(`http_conformance`); `http::mcp_socket_tests` repeats the main rows over a
real socket so the Rust header parsing is covered too.

| Behaviour | Swift | Rust | Status |
|-----------|-------|------|--------|
| `initialize` issues `Mcp-Session-Id` | yes, a UUID | yes, a random UUID v4 | pass |
| known `Mcp-Session-Id` on POST | served, no new id | same | pass |
| unknown `Mcp-Session-Id` on POST (request or notification) | 404 | 404 | pass |
| no `Mcp-Session-Id` on POST | served (stateless clients) | same | pass |
| `initialize` with a stale id | new session | same | pass |
| `DELETE /mcp` | ends the session, 204; the id is 404 afterwards | same | pass |
| `DELETE /mcp` without an id | 204 | 204 | pass |
| notification | 202, empty body | same | pass |
| non-JSON or missing Content-Type on POST | 415 | 415 | pass |
| Content-Type match | prefix `application/json`, case-insensitive | same | pass |
| malformed JSON body on POST | 400 with JSON-RPC -32700 | same | pass |
| body bytes that are not valid UTF-8 | 400 with JSON-RPC -32700 (`JSONDecoder` gets raw `Data`) | same, parsed from bytes (Rust socket test) | pass |
| batch body, or jsonrpc other than "2.0" | 400 with JSON-RPC -32600 | same | pass |
| JSON-RPC error on a valid envelope | HTTP 200 | HTTP 200 | pass |
| `GET /mcp` | 405 | 405 | pass |
| other methods on `/mcp` | 405 | 405 (was 404) | pass |
| session table bound | unbounded | 1024, oldest dropped (the client gets 404 and re-initializes) | differs by design, Rust unit test |
| `401` body on an auth deny | `text/plain` `unauthorized\n` | `{"error":"unauthorized"}` | open |

## 4. Reverse attach

| Row | Swift | Rust | Status |
|-----|-------|------|--------|
| close-code and handshake disposition | `ConformanceVectorTests` | `attach::conformance` | pass |
| attach URL | vectors | vectors | pass |
| dial with bearer, expected upgrade headers | not asserted (FakeRuntime accepts any bearer); bearer seen only on the 401 path, see `ReverseAttachRefusedUpgradeTests` | `attach::client::tests` | pass (Rust); Swift open |
| refused upgrade (401) stops after one dial | `ReverseAttachRefusedUpgradeTests` | `attach::client::tests`, `dial_loop` runs against the refusing runtime | pass |
| bearer compare is byte-exact on the parsed value (same length, case, trailing space left in the value); the parser strips whitespace around the header value first; vectors check outcomes, not timing | `auth_vectors.json`; `HTTPParserTests.testHeaderValueWhitespaceStripped` | `auth::conformance`; parser stripping by reading (`http.rs` `value.trim()`), no test | pass |
| login allowlist compare is case-insensitive; principal is the lowercased login | `auth_vectors.json` | `auth::conformance` | pass |
| deny-reason strings are part of parity as operator log text (never on the wire): `missing Authorization header`, `Authorization must be Bearer`, `bad token`, `login <login> not allowed`, `no Tailscale identity on request`, `unauthenticated` | `auth_vectors.json` (exact) | `auth::conformance` (exact) | pass |
| sha256 verifier (runtime stores the hash only) | not in this repo | not in this repo | open (runtime side, openab-pty) |
| credential never in shell output (grant body) | `AttachCredentialSecrecyTests` | `attach::grant_secrecy_tests` | pass (GET bodies, POST response) |
| pod stores only the verifier | not in this repo | not in this repo | open (runtime side) |
| successful wss:// handshake | not tested | not tested (ring provider installed since #66) | open (needs a TLS fixture) |
| wss:// never falls back to plaintext | not tested (`SwitchboardTests` checks URL validation only) | `attach::client::tests`: `tungstenite::connect` must return a TLS or I/O error, and `dial_loop` against a plaintext listener redials with backoff and ends at the deadline | pass (Rust); Swift open |
| TLS certificate verification | not tested | not tested | open (needs a cert fixture) |
| origin policy on the upgrade | undefined | undefined | open (decision needed) |

## 5. Per-tool table

Cells come from the source files on each side. The Swift names are from
`Sources/InstanceMCPCore/Tools/` and `UpstreamMCP.swift`. The Rust names are
from `poc/reverse-attach-linux/src/mcp.rs` (`LOCAL_TOOL_NAMES`, and the
`Upstream` re-serving code and `upstream_tool_allowed`) and `src/tools/`. The
classification column is `ToolProfile.localToolClass` (Swift) and `LOCAL_TOOL_CLASS`
(Rust), both pinned in `conformance/profile_vectors.json` (`tool_class`). Every
local tool is served under `owner` only, except `sys_info` and `screenshot`, which
`observe` also serves (#59).

| Tool | Swift present | Rust present | Classification | Conformance test |
|------|---------------|--------------|----------------|------------------|
| `sys_info` | `SysInfoTool` | yes (`tools/sysinfo.rs`) | `observe` on both; served by `observe` and `owner` | none beyond tools/list shape |
| `screenshot` | `ScreenshotTool` | yes (`tools/screen.rs`; same `format`/`quality`/`scale`/`region`/`display` arguments and defaults for format and quality, JPEG encoded in-process, #32 item 5) | `observe` on both; served by `observe` and `owner` | Rust unit tests only (argument parsing, region clip, PPM→JPEG); no shared vectors. Linux default `scale` is 0.5 (Swift 1.0) |
| shell (`exec` in Swift, `bash` in Rust) | `ExecTool` | yes (`tools/bash.rs`) | `shell` on both; `owner` only | none. Name differs between backends |
| `mouse` | `MouseTool` | yes (`tools/input.rs`) | `shell` on both; `owner` only | none |
| `key` | `KeyTool` | yes (`tools/input.rs`) | `shell` on both; `owner` only | none |
| `osascript` | `OsascriptTool` | no (macOS only) | `shell`; `owner` only | none |
| `ui_snapshot` | `UISnapshotTool` (`UISnapshot/`, AXUIElement) | no (Linux AT-SPI deferred, #102) | `observe`-class on macOS; `owner` only (not in `observe` in phase 1) | `profile_vectors.json` `macos` lists; Swift `UISnapshotWalkerTests`/`UISnapshotTargetTests`/`UISnapshotToolTests` (fake AX provider, no GUI); Rust `profile_conformance::macos_only_tools_are_not_served_on_linux` |
| `ui_action` | `UIActionTool` (`UISnapshot/UIAction.swift`, `UISnapshotCache.swift`; AX actions, no pointer movement) | no (Linux AT-SPI deferred, #102) | `shell` on macOS; `owner` only | `profile_vectors.json` `macos` lists; Swift `UIActionToolTests`/`UISnapshotCacheTests` (fake AX provider, no GUI), `ProfileBoundaryTests.testUIActionIsOwnerOnlyShellClass`; Rust `profile_conformance::macos_only_tools_are_not_served_on_linux` |
| `exec_start`, `exec_poll`, `exec_list`, `exec_cancel` | `AsyncExecTools`, `JobRegistry` | yes (`src/jobs/`, #32 item 4): same names, arguments and `structuredContent`; `bash -c` instead of `zsh -f -c`; logs under `$XDG_STATE_HOME/oab-instance-mcp/jobs/`; `shell`-class, `owner` only (Swift classes `exec_start` as `shell`, `exec_poll`/`exec_list` as `observe` and `exec_cancel` as `act`; both expose the four to `owner` only, so the gating is the same) | Swift: `exec_start` `shell`, `exec_poll`/`exec_list` `observe`, `exec_cancel` `act`; Rust: all `shell`. `owner` only on both | Rust unit tests `jobs::tests` and `smoke.sh` (start, offset polls, survives an attach drop, cancel → `killed`); no shared vectors. Differences: Rust keeps the 10 most recent finished jobs (Swift: finished metadata for ~10 min), pages `exec_poll` at 1 MiB per stream, and refuses a `signal` other than `KILL`/`TERM`. A job stays `running` until its shell has exited and its process group is empty (Swift: until its output pipes close), so a child the shell left behind can still be cancelled or timed out |
| `browser_*` (upstream Playwright) | `UpstreamMCP` | yes (`mcp.rs` `Upstream`, `MCP_UPSTREAM`) | not classified locally; every upstream tool is `owner` only on both, `observe` gets none (#59) | `profile_vectors.json` membership on both; the full 32-tool fixture through a fake upstream: `BrowserProfileTests` (Swift), `profile_conformance::owner_reaches_every_upstream_tool_and_observe_none` (Rust) |

## 6. Profile rows

Filled in by #59 (two profiles, `observe` and `owner`). The shared file is
`conformance/profile_vectors.json`; the Swift runner is
`ConformanceVectorTests.testProfileVectors` plus `BrowserProfileTests`, the Rust
runner is `profile_conformance`.

| Row | Swift | Rust | Status |
|---|---|---|---|
| exactly two profiles, `owner` and `observe`; one source constant | `ToolProfile.allCases`, `ProfileBoundaryTests.testOnlyOwnerAndObserveExist` | `mcp::PROFILES`, `profile_tests` | pass (vectors `profiles`) |
| per-connection enforcement at dispatch: `observe` serves exactly `sys_info` and `screenshot`, `owner` every local tool | `MCPServer.scoped(to:)`, `ProfileBoundaryTests` | `local_tool_allowed` in `tool_list` / `handle_tool_call`, `profile_tests` | pass (vectors `served`, `local_tools`) |
| every local tool classified; an unclassified tool fails | `testEveryServedToolIsClassified` | `every_served_tool_is_classified_and_the_lists_agree` | pass (vectors `tool_class`) |
| browser tools: `owner` gets the full upstream set, including tools not in the fixture; `observe` none | `BrowserProfileTests` | `profile_conformance::owner_reaches_every_upstream_tool_and_observe_none` | pass |
| a hidden tool on `tools/call` is *unknown tool* (local and upstream) | `ToolProfileTests`, `BrowserProfileTests` | `job_tools_are_shell_class_and_owner_only`, `profile_conformance` | pass (#78 + #59) |
| the long-call guard on a reverse attach does not name a hidden tool | `testLongExecUnderObserveIsAnUnknownTool` | `long_work_advice_follows_the_job_tools` | pass |
| bare attach (no or non-string `profile`) gets `observe` | `AttachEndpointTests.testCreateListRevoke` | `attach_profile_tests` | pass (vectors `attach_requests`) |
| requested `desktop` → `observe` with `requested_profile` and the shared `warning`, never `owner` | `testDesktopRequestRunsAsObserveWithAWarning` | `attach_profile_tests`, `smoke.sh` | pass (vectors `attach_requests`) |
| unknown names (`sandbox`, `Desktop`, `OWNER`, `browser`, empty) → 400 `profile must be one of [owner, observe]` | `testUnknownProfilesGetTheSharedRejection` | `attach_profile_tests`, `smoke.sh` | pass (vectors `attach_requests`) |
| stored `desktop` grant kept, resumes as `observe`, reported in `GET /attach` and the grants file; a stored row never widens | `GrantPersistenceTests.testAGrantStoredAsDesktopResumesAsObserve` | `store::tests::a_desktop_row_is_kept_as_observe_and_round_trips`, `smoke.sh` | pass (vectors `persisted_grants`) |
| every `desktop` → `observe` mapping (attach, resume; macOS also the switchboard flag) appends a `profile_mapped` line to the mode-600 audit file | `testCreateNeverServesWiderThanTheRequestedName`, `testAGrantStoredAsDesktopResumesAsObserve`, `testFileAuditLogAppendsPrivateJSONLines` | `audit::tests::records_are_private_appended_json_lines`, `smoke.sh` | pass |
| a non-string `requested_profile` in a stored row counts as absent; the rest of the file loads | `testANonStringRequestedProfileCountsAsAbsent` | `store::tests::a_non_string_requested_profile_counts_as_absent` | pass |
| stored `sandbox` or unknown grant dropped | `testAGrantStoredUnderTheOldSandboxNameIsDropped` | `grants_stored_under_the_old_sandbox_name_are_dropped` | pass (vectors `persisted_grants`) |
| shell-equivalence: `owner` yes, `observe` no; a profile claiming no shell allows no `shell` tool | `testNoProfileClaimsToBeNarrowerThanItIs` | `no_profile_claims_to_be_narrower_than_it_is` | pass (vectors `served.*.shell_equivalent`) |

Known gap: `OsascriptToolTests` is skipped in CI (#1), so the `osascript` path is
not tested end to end. Its profile gating is.

## 7. Open decisions

- Origin policy for the WebSocket upgrade and for `/mcp`. Neither backend defines one.
- Certificate pinning or verification for `wss://` runtimes.
