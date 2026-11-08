# reverse-attach (Linux hands node, Rust PoC)

Step-by-step install on a fresh box: [`docs/linux-setup.md`](../../docs/linux-setup.md).

Part of [#27](https://github.com/openabdev/instance-mcp/issues/27) (hands-node registry) and
[#15](https://github.com/openabdev/instance-mcp/issues/15) (Linux-first Rust port). A single
self-contained binary that makes a Linux box a lendable "hands" node for an openab-pty session,
mirroring the Swift `ReverseAttachClient` / `POST /attach` contract:

- `POST /attach` `{runtime, session, profile, ttl_secs, secret | admin_credential}` → HTTP 202
  with the same grant shape Connect decodes: `{id, runtime, session, profile, principal, state,
  expires_in_secs}`. Exactly one credential; the admin path mints at the runtime with
  `{"ttl_secs": N}` (ws:// only in this PoC) and forwards TTL end to end. Without `profile` the
  grant gets `observe` (until 0.8.2 it got `owner`, #59).
- `GET /attach` → `{grants:[…]}`; `GET /attach/{id}` → one grant; `DELETE /attach/{id}` →
  204 and promptly cancels the dial/socket. New grant for the same `(runtime, session)` replaces
  the old one. States match Swift: `idle / dialing / attached / redialing / ended` plus optional
  `ended` reason (`revoked`, `handshake_rejected_401`, `deadline`, …).
- Dial loop: `GET ws://…/tools/attach/{session}` with `Authorization: Bearer <secret>`, redial
  1 s → 30 s backoff until the grant deadline. Disposition per openab-pty §9.2: close `4001`
  expired / `4002` replaced / `4004` session ended / `4010` revoked and handshake non-2xx/429/5xx
  → **stop**; `1000` / `4006` / `4011` (liveness) / other / 2xx / 429 / 5xx → **redial**. A
  connection that stayed up for 60 s resets the backoff. Same table the
  `reverse-attach-conformance` suite (#24) checks 24/24 against the Swift oracle.
- Liveness (#70): the runtime pings every 20 s and closes an attach that stays silent for more
  than three intervals (`4011`). The read loop never waits on a tool: each frame is answered on
  its own thread and the loop, the socket's only writer, sends the replies between reads
  (20 ms while a call runs, up to 250 ms when idle), so pings are answered while a call runs.
  We also ping the runtime every 15 s. When a socket ends (close, error, `DELETE`), its running
  calls are cancelled and `bash` kills its process group.
- MCP over the socket: `initialize` (with instructions: keep calls under ~60 s, issue `mouse` /
  `key` steps one at a time), `ping`, `tools/list`, `tools/call`; notifications get no reply; a
  frame that does not parse gets the JSON-RPC envelope error with a null id, as from Swift
  (`conformance/mcp_wire_vectors.json`, #78); WebSocket ping → pong. The socket is the session:
  no `Mcp-Session-Id` on this path, as in Swift. Tools: `sys_info`, `screenshot`, `bash`, `mouse`,
  `key` and the job tools under `owner`; `sys_info` and `screenshot` under `observe`, the default.
  Two profiles since #59: `owner` is shell-equivalent, only `observe` is a boundary (#45), so
  lend a dedicated node for `owner`. The retired `desktop` runs as `observe` with a warning. `bash` = `bash -c`
  as the daemon user with `cwd` (`~` expands), `timeout_secs` (default 60, max 600; the whole
  process group is killed → exit 137, `timed_out=true`), `max_output_bytes` per stream (≤1 MiB).
  On a reverse attach `bash` refuses `timeout_secs` over 100 s, because the runtime fails any
  call still running after 120 s; the refusal and `initialize` point `owner` at
  `exec_start` + `exec_poll`. Under `observe` a long `bash` is an *unknown tool*.
- Background jobs (`src/jobs/`, #32 item 4, `owner` only): `exec_start` / `exec_poll` /
  `exec_list` / `exec_cancel`, same arguments and `structuredContent` as the Swift tools, with
  `bash -c` in a new session. stdout/stderr go to `$XDG_STATE_HOME/oab-instance-mcp/jobs/<id>.out`
  / `.err` (dir 700, files 600, never truncated); `exec_poll` reads by byte offset, at most
  1 MiB per stream per poll. A job stays `running` until its shell has exited and its process
  group is empty; the shell is reaped only then, so cancel and timeout can signal the group
  (children the shell left behind included) without ever hitting a recycled pid (#72's rule). Jobs belong to the daemon, so they **survive a reverse-attach
  socket drop** (in-flight calls do not); a daemon restart forgets them. Running jobs plus the
  10 most recently finished are kept, a finished one for at most 7 days; logs of jobs finished
  more than 7 days ago are deleted (a running job's are kept).

Deps: `serde_json` + `tungstenite` (rustls). Sync std threads, no tokio. ~28 KB.

## Verified on a Raspberry Pi (Debian 13, aarch64, Rust 1.98) — 2026-09-27

```sh
cargo build --release          # 31 s cold, 2.2 MB binary
bash smoke.sh                  # RESULT: 55 passed, 0 failed
```

`smoke.sh` runs the binary against `mock_runtime.py` (stdlib-only mock openab-pty: mint endpoint
+ WS attach endpoint that drives a scripted MCP turn and closes with a scripted code). Covered:

| area | checks |
|---|---|
| validation | non-ws runtime, bad session, both/neither credential, ttl 0, wrong admin → `400 mint failed: mint HTTP 401`, 404 route |
| mint path | `ttl_secs=60` seen by the runtime's mint endpoint; `expires_in_secs=60` in the grant |
| control contract | `POST /attach` 202 with every Connect-required grant field; `GET /attach` wrapper; `GET /attach/{id}`; `DELETE` 204 + removal; principal and dynamic expiry |
| redial / stop | close `1000` → redialed after 1 s; close `4010` → `state=ended, ended=revoked`; wrong secret → `ended=handshake_rejected_401` with exactly one attempt; unreachable runtime → `ended=deadline` |
| MCP | `serverInfo.name=instance-mcp-rpi`; owner list = `sys_info,screenshot,exec`; `sys_info.hostname=<node>`; `exec` ran on the node; unknown tool / method → `-32601` at the time (since #78: unknown tool `-32602`, method `-32601`); notification silent; ping → pong (since #78: `{}`) |
| desktop (removed in #59) | list = `sys_info,screenshot`; forced `exec` → error, not executed (2026-09-28 run). Since #59 `smoke.sh` checks that a `desktop` request runs as `observe` with `requested_profile` and a `warning`, and that a stored `desktop` grant resumes as `observe` |
| close handshake | client echoes the Close frame (was a bare EOF before the `socket.flush()` fix in `dial_loop`) |

## Direct `/mcp` for OpenAB Connect's Screens pane (added 2026-09-28)

The same binary now also serves MCP Streamable-HTTP (JSON mode) on `POST /mcp`, gated by an
`AuthPolicy` with the Swift daemon's semantics — `MCP_TOKEN` / `MCP_TOKEN_FILE` (bearer,
constant-time) AND `MCP_ALLOW_LOGIN` (matched against the `Tailscale-User-Login` header that
`tailscale serve` injects); `MCP_INSECURE_LOCAL=1` for loopback debugging; refuses to start with
nothing set. `/healthz` is open. HTTP behaviour after auth matches Swift `MCPHTTPEndpoint`
(`conformance/mcp_http_vectors.json`, #78): `Content-Type` must be `application/json` (else 415), a
body that fails the JSON-RPC envelope (including one that is not valid UTF-8) is 400 with the JSON-RPC error, `initialize` issues an
`Mcp-Session-Id` (random UUID v4, in memory, the oldest dropped past 1024), an id we did not issue
or that `DELETE /mcp` closed is 404 so the client re-initializes, a request without the header is
served, `GET /mcp` and other methods are 405. `screenshot` returns MCP `image` content with the Swift tool's arguments: `format` jpeg
(default) or png, `quality` 0–1 (default 0.7, floored at 0.1, so 1 = 100%; above 1 up to 100 is a percentage), `scale` (default 0.5, max 2),
`region` {x,y,width,height} in display pixels (clipped to the output layout) and `display` 0.
Debian's grim has no libjpeg, so for JPEG the daemon asks grim for raw PPM and encodes it
in-process (`jpeg-encoder`, pure Rust); grim still does the crop (`-g`) and the scaling (`-s`).
`structuredContent` carries `points` (layout size), `region`, `image` {width,height,bytes} and
`scale`, as on macOS. On a Raspberry Pi's labwc seat (#32 item 5): 1920×1080 at scale 1, q0.6 → 49 KiB
JPEG in 0.07 s vs a 2.0 MB PNG in 1.0 s.
`sys_info` carries the `host` / `displays` / `permissions.screen_recording` / `agent.version`
fields the Screens pane reads.

On a Raspberry Pi: systemd user unit `oab-instance-mcp.service` (BIND 127.0.0.1:8795, seat env
`WAYLAND_DISPLAY=wayland-0`, linger on) + `tailscale serve --bg --https=8444 http://127.0.0.1:8795`
→ `https://<node>.<tailnet>.ts.net:8444/mcp`. Verified from the laptop: wrong token 401,
initialize 200 with `Mcp-Session-Id`, `sys_info` host=<node> displays=1, Connect-shaped screenshot
call (`display 0, scale 1, quality 0.6, format jpeg`) → a 1920×1080 image (PNG at the time, 1.35 s; it is JPEG since #32 item 5, see above). Pi OS's labwc
desktop keeps a 1920×1080 headless output alive with no monitor attached, so no sway needed.

## `mouse` / `key` (added 2026-09-28, #26)

`mouse` → a persistent wlroots virtual pointer held by the daemon (`src/platform/linux/seat.rs`;
move / click / double_click / right_click / drag / scroll in wheel notches, display
pixels = screenshot pixels at scale 1); `key` → `wtype` (`type` unicode text, `press` combos like
`ctrl+shift+t`, `Return`, `Escape`; modifiers ctrl/shift/alt/super). Both run against the seat's
`wayland-0`; labwc (wlroots) accepts the virtual-pointer and virtual-keyboard protocols with no
config. Verified from the laptop: click into a field → `type` → screenshot shows the text →
`press Escape` clears it, ~0.3 s per call.

## Browser tools via `MCP_UPSTREAM` (added 2026-09-28)

Same pattern as the Mac: `@playwright/mcp` runs beside the daemon on loopback and the daemon
re-serves its tools under its own `tools/list`, filtered by the connection's profile.

- `pw-mcp.sh` + systemd user unit `oab-pw-mcp.service`: `@playwright/mcp@0.0.82` pinned (same
  as `poc/pw-mcp`), **headed** Chromium launched into the labwc seat (`WAYLAND_DISPLAY`,
  `XDG_RUNTIME_DIR`, `DISPLAY=:0` for labwc's Xwayland), using the distro Chromium
  (`--executable-path /usr/bin/chromium`, arm64-native, no Playwright download), persistent
  profile, `--allowed-hosts` must include the `host:port` form or every request is 403.
- Daemon: `MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp`. Mirrors Swift `UpstreamMCP`:
  request/response Streamable HTTP, upstream `Mcp-Session-Id` held and re-established on
  400/404 (the stale id must be dropped *before* re-`initialize`, or the upstream 404s that too),
  SSE or JSON replies, `tools/list` cached 30 s (failures not cached), upstream down → its
  tools absent. Local names win on collision.
- Profile filter (#59): `owner` sees every upstream tool (all 32, and any added later);
  `observe` sees none. `profile_conformance` checks both against the 32-tool fixture in
  `conformance/profile_vectors.json` through a fake upstream.
- Chromium managed policy `/etc/chromium/policies/managed/oab-instance-mcp.json` blocks
  camera/mic/notification/geolocation prompts: YouTube triggered the xdg-desktop-portal
  "Allow app to use the Camera?" dialog, which nothing but `mouse` could dismiss.

Verified on a Raspberry Pi: owner `/mcp` → 37 tools (5 local + 32 browser); after a pw-mcp restart the
next call re-initializes and still lists 37. Lent to a pod session (under the profile then named `sandbox`, later `desktop`, removed in #59):
22 tools = 5 local + 16 browser + `instance_status`; forced `browser_run_code_unsafe` →
`-32601 unknown tool`; `browser_navigate` example.com 13 s (Pi 4 class, first page), then
`browser_snapshot` → `heading "Example Domain"`, `link "Learn more"`. The Chromium window is
on the Pi's desktop, so `screenshot` / Connect's Screens pane show what the agent is doing.

## Grant persistence (#12)

Live grants are written to `MCP_GRANTS_FILE` (default `$XDG_STATE_HOME/oab-instance-mcp/grants.json`,
`off` disables), mode 600 in a 0700 directory, replaced atomically on every create / replace /
`DELETE` / terminal end. On start, grants still inside their deadline are re-dialled under the same
id. Smoke covers `kill -9` → restart → redial, same id, secret absent from `GET /attach`, and a
revoked grant not resumed.

## Not yet (vs the Swift implementation)

- `/mcp` has no SSE stream (`GET /mcp` is 405, as in Swift).
- `mouse` maps onto the layout the virtual pointer read at connect, so after an output hotplug
  it lags until the pointer reconnects. `screenshot` reads the outputs itself (no input device)
  unless a pointer is live, in which case it reports that pointer's layout so the two agree.
- `wss://` runtimes: the dial uses rustls with the ring provider (#66). Tests cover only the failure
  side (a TLS failure redials and ends at the deadline, never falls back to plaintext); a successful
  TLS handshake and certificate verification are not tested yet. Mint over https does not work.
- Real-runtime test against a live openab-pty pod is pending: the test host was not on the
  tailnet, and the pod's `PTY_ADMIN_HASH` is a hash, so the admin credential must come from the
  operator.
