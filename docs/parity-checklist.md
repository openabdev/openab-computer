# Parity checklist (Phase 3 gate)

This checklist is the gate for retiring the Swift daemon (Phase 3) in
`docs/adr/linux-rust-port.md`. The executable part is the suite in
[`conformance/`](../conformance/README.md), which runs in `swift test` (oracle)
and in `cargo test --release` (Rust port). This file lists what the suite does
not cover yet, and the status of each row. Status values: **pass** (both
backends agree and a test pins it), **drift** (the backends differ, pinned in
`known_drift`), **open** (not yet tested).

Refs #24.

## 1. Gate conditions

Every row must be green on both backends before Phase 3 starts:

- every file in `conformance/` passes in `swift test` and in `cargo test --release`;
- `conformance/mcp_wire_vectors.json` has an empty `known_drift` list;
- the reverse-attach negatives pass in both suites;
- the per-tool table in section 5 has no open row;
- the profile rows in section 6 are signed off after issue #59 lands.

## 2. Wire layer (JSON-RPC)

One row per case in `conformance/mcp_wire_vectors.json`. The Swift result is the
oracle. The Rust column reflects the `known_drift` list.

| Case | Swift | Rust | Test |
|------|-------|------|------|
| initialize negotiates 2024-11-05 | protocolVersion 2024-11-05 | pass | `WireConformanceTests`, `wire_conformance` |
| initialize negotiates 2025-06-18 | protocolVersion 2025-06-18 | drift: returns 2024-11-05 | same |
| initialize with unknown version | falls back to 2025-06-18 | drift: returns 2024-11-05 | same |
| ping | result `{}` | drift: error -32601 | same |
| tools/list shape | tools with name, description, inputSchema | pass | same |
| tools/call unknown tool | error -32602 | drift: error -32601 | same |
| tools/call missing name | error -32602 | pass | same |
| unknown method | error -32601 | pass | same |
| notification | no response | pass | same |
| malformed JSON | error -32700 | drift: no response | same |
| jsonrpc "1.0" | error -32600 | drift: result returned | same |
| batch array | error -32600 | drift: no response | same |

## 3. HTTP layer (not in the fixtures)

The fixtures stop at the JSON-RPC layer. These HTTP behaviours are open.

| Behaviour | Swift | Rust | Status |
|-----------|-------|------|--------|
| `Mcp-Session-Id` unknown on POST | 404 | not enforced (no session state) | open |
| `DELETE /mcp` | ends the session, 204 | bare 204, no session | open |
| non-JSON Content-Type on POST | 415 | no check | open |
| malformed JSON body on POST | 400 with JSON-RPC error -32700 | 202, no body | open (follows from the wire drift above) |
| `GET /mcp` | 405 | 405 | open (not tested) |

## 4. Reverse attach

| Row | Swift | Rust | Status |
|-----|-------|------|--------|
| close-code and handshake disposition | `ConformanceVectorTests` | `attach::conformance` | pass |
| attach URL | vectors | vectors | pass |
| dial with bearer, expected upgrade headers | not asserted (FakeRuntime accepts any bearer); bearer seen only on the 401 path, see `ReverseAttachRefusedUpgradeTests` | `attach::client::tests` | pass (Rust); Swift open |
| refused upgrade (401) stops after one dial | `ReverseAttachRefusedUpgradeTests` | `attach::client::tests`, `dial_loop` runs against the refusing runtime | pass |
| bearer compare is byte-exact (same length, case, trailing space); vectors check outcomes, not timing | `auth_vectors.json` | `auth::conformance` | pass |
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
`Upstream` re-serving code with `DESKTOP_BROWSER_TOOLS` and
`upstream_tool_allowed`) and `src/tools/`. The classification column is owned by #59 (see section 6), so it is
not filled here.

| Tool | Swift present | Rust present | Classification | Conformance test |
|------|---------------|--------------|----------------|------------------|
| `sys_info` | `SysInfoTool` | yes (`tools/sysinfo.rs`) | see #59 | none beyond tools/list shape |
| `screenshot` | `ScreenshotTool` | yes (`tools/screen.rs`) | see #59 | none beyond tools/list shape |
| shell (`exec` in Swift, `bash` in Rust) | `ExecTool` | yes (`tools/bash.rs`) | see #59 | none. Name differs between backends |
| `mouse` | `MouseTool` | yes (`tools/input.rs`) | see #59 | none |
| `key` | `KeyTool` | yes (`tools/input.rs`) | see #59 | none |
| `osascript` | `OsascriptTool` | no (macOS only) | see #59 | none |
| `exec_start`, `exec_poll`, `exec_list`, `exec_cancel` | `AsyncExecTools` | no | see #59 | none |
| `browser_*` (upstream Playwright) | `UpstreamMCP` | yes (`mcp.rs` `Upstream`, `MCP_UPSTREAM`); desktop allowlist `DESKTOP_BROWSER_TOOLS` matches Swift `ToolProfile.desktopBrowserTools` | see #59 | none |

## 6. Profile rows

Owned by issue #59 (profile collapse). Placeholder only. This PR does not
change profile semantics or profile tests. The rows to fill in after #59 are:
per-connection enforcement at dispatch (owner, desktop, observe), sandbox denies
`exec*`, and the shell-equivalence rule on Linux.

## 7. Open decisions

- Origin policy for the WebSocket upgrade and for `/mcp`. Neither backend defines one.
- Certificate pinning or verification for `wss://` runtimes.
- Whether the Rust `ping` gap (section 2) blocks Phase 3, or is fixed first.
