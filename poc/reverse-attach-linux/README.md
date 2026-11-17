# oab-computer (Linux hands node, Rust PoC)

Step-by-step install on a fresh box: [`docs/linux-setup.md`](../../docs/linux-setup.md).

Part of [#27](https://github.com/openabdev/openab-computer/issues/27) (hands-node registry) and
[#15](https://github.com/openabdev/openab-computer/issues/15) (Linux-first Rust port). A single
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
  `bash -c` in a new session. stdout/stderr go to `$XDG_STATE_HOME/oab-computer/jobs/<id>.out`
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
| MCP | `serverInfo.name=instance-mcp-rpi` (named oab-computer-rpi since the 0.12.0 rename); owner list = `sys_info,screenshot,exec`; `sys_info.hostname=<node>`; `exec` ran on the node; unknown tool / method → `-32601` at the time (since #78: unknown tool `-32602`, method `-32601`); notification silent; ping → pong (since #78: `{}`) |
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

On a Raspberry Pi: systemd user unit `oab-computer.service` (BIND 127.0.0.1:8795, seat env
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

> Historical section: the external path of 0.12.0 and earlier. `install-linux.sh` no longer writes
> this unit or the `MCP_UPSTREAM` line (L3); the managed browser replaces them. A host that still
> runs the old unit has a `127.0.0.1:8794` listener with no authentication, so any local user on the
> node can call every browser tool. See [`docs/linux-setup.md`](../../docs/linux-setup.md) and
> [`docs/adr/linux-browser-tier.md`](../../docs/adr/linux-browser-tier.md).

Same pattern as the Mac: `@playwright/mcp` runs beside the daemon on loopback and the daemon
re-serves its tools under its own `tools/list`, filtered by the connection's profile.

- `pw-mcp.sh` + systemd user unit `oab-computer-pw-mcp.service`: `@playwright/mcp@0.0.82` pinned (same
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
- Chromium managed policy `/etc/chromium/policies/managed/oab-computer.json` blocks
  camera/mic/notification/geolocation prompts: YouTube triggered the xdg-desktop-portal
  "Allow app to use the Camera?" dialog, which nothing but `mouse` could dismiss.

Verified on a Raspberry Pi: owner `/mcp` → 37 tools (5 local + 32 browser); after a pw-mcp restart the
next call re-initializes and still lists 37. Lent to a pod session (under the profile then named `sandbox`, later `desktop`, removed in #59):
22 tools = 5 local + 16 browser + `instance_status`; forced `browser_run_code_unsafe` →
`-32601 unknown tool`; `browser_navigate` example.com 13 s (Pi 4 class, first page), then
`browser_snapshot` → `heading "Example Domain"`, `link "Learn more"`. The Chromium window is
on the Pi's desktop, so `screenshot` / Connect's Screens pane show what the agent is doing.

## Grant persistence (#12)

Live grants are written to `MCP_GRANTS_FILE` (default `$XDG_STATE_HOME/oab-computer/grants.json`,
`off` disables), mode 600 in a 0700 directory, replaced atomically on every create / replace /
`DELETE` / terminal end. On start, grants still inside their deadline are re-dialled under the same
id. Smoke covers `kill -9` → restart → redial, same id, secret absent from `GET /attach`, and a
revoked grant not resumed.

A `desktop` request or stored row runs as `observe` (#59), and each mapping is appended as one
JSON line to `MCP_AUDIT_FILE` (default `$XDG_STATE_HOME/oab-computer/audit.jsonl`, `off`
disables), mode 600. Smoke checks the `attach` and `resume` records.

## Managed Playwright tier, L1a and L1b (#119)

The install path of the managed tier. `oab-computer browser <plan|preflight|install|update|remove|status|signin>`
(L1b, below) calls the three L1a modules from `main`, so the stripped-size check in CI measures
them. Design: `docs/adr/linux-browser-tier.md` (D3, D16, D17) and
`docs/requirements/linux-browser-tier.md`.

- `src/manifest.rs`: reads the embedded `release/playwright-pins/pins.json` (schema 2, four
  platforms), validates it by the same rules as the Swift validator (the shared
  `conformance/pins_vectors.json` runs in `cargo test`), and selects the pin for the host.
  Darwin ids parse; only `linux-x64` and `linux-arm64` are selectable here.
- `src/download.rs`: bounded synchronous HTTPS download. https only, hosts from the manifest,
  every redirect hop re-checked, proxy variables ignored, size and time caps, SHA-256 computed
  while streaming into a private `.part` file and compared to the pin before the file gets its
  name. The result is a `VerifiedArtifact`, the only input `extract` accepts.
- `src/extract.rs`: `tar.gz` and `zip` extraction in two stages (validate every entry, then
  write below a directory fd with `openat` and `O_NOFOLLOW`/`O_EXCL`). No `tar`, `unzip` or other
  subprocess.

The new tests use a fake server on `127.0.0.1` and archives the tests generate; the one test
that downloads the real pinned artifacts is `#[ignore]`d (`real_pins_download`, see its doc
comment).

### `oab-computer browser ...` (L1b)

| Command | What it does |
| --- | --- |
| `plan` | Prints the consent text: what is downloaded, from where, how big, where it goes. No network, no writes. |
| `preflight [--root-actions]` | Reports libc, the glibc floor, user namespaces, disk needed and free, seat, and every missing shared library in one run. Installs nothing and never uses root; a root action is printed, not run. A blocker exits 1 and prints `browser: preflight_failed class=<musl\|glibc_too_old\|disk_full\|libraries_missing>` on stderr. `--root-actions` prints only the root actions, one `command<TAB>reason` line each; `install-linux.sh` reads it. `ldconfig -p` runs with a 10 s deadline. |
| `signin [--url URL]` | L3. A headed window on the persistent profile for a one-time login; needs a terminal (use `ssh -t`), an installed browser and a Wayland seat. See `src/signin.rs`. |
| `install [--from-dir DIR]` | Installs the pinned Node.js, Playwright MCP and Chromium below `${XDG_DATA_HOME:-~/.local/share}/oab-computer/playwright/`. `--from-dir` installs from pre-fetched files in `DIR` (the basenames of the pinned URLs and of the lockfile's `resolved` URLs), hash-checked the same way, with `npm ci --offline` and no network. |
| `update [--yes] [--from-dir DIR]` | Prompted, never silent (no terminal and no `--yes` is a refusal). Installs the new version beside the old one and keeps the old one if anything fails. |
| `remove` | Deletes only what carries the installer's marker and prints `left in place:` for everything else. |
| `status [--json] [--retry]` | Install state, ids, platform, whether an update is available, and (L2) `containment`, `external_configured`, `listeners` and `refusal`. `--json` has a fixed set of keys. `--retry` removes the unavailable latch and re-runs the containment self-test in this process. |

Exit codes: `0` success (including a no-op), `1` the operation failed or the preflight found a
blocker (one `browser: <command>_failed class=<token>` line on stderr), `2` a usage error. A usage
error also covers `--apply-system-changes` (a flag of `install-linux.sh`; this binary never runs a
root action) and `--use-system-chromium` (not available in this build).

- `src/state.rs`: the root, ownership markers (`.oab-owned`, `.oab-owned-data`, `.oab-staging`),
  `.install.lock` (`flock`, never unlinked, no stale-lock reclaim), `install.json`,
  `pending-cleanup.json` and the marker-gated delete walker (`openat`/`unlinkat` below directory fds,
  links are never followed).
- `src/install.rs`: the install, update, remove and status flows; staging, the staging guard, the
  atomic switch-over with `install.json` written last.
- `src/preflight.rs`, `src/elf.rs`: the host report and a bounded ELF reader. `src/health.rs`,
  `src/npm.rs`, `src/proc.rs`: the headless health check of the staged Playwright MCP over stdio,
  `npm ci` with the staged Node, and the child-process handling both use.
- `src/consent.rs`, `src/catalog.rs`, `src/cancel.rs`: the consent text, the 32 tool names (checked
  against the Swift catalog) and SIGINT/SIGTERM handling.

The L1b tests install into a temp root with a stub `node`; real Chromium runs only in the
manual end-to-end check recorded in the PR.

## Managed Playwright tier, L2: the managed child and the router (#119)

`@playwright/mcp` runs as a stdio child of the daemon, inside a kernel-enforced whole-tree stop
mechanism, and a router picks which Playwright serves `browser_*`. Design:
`docs/adr/linux-browser-tier.md` ("Process containment", "Router", D4, D5, D15, D17) and
`docs/requirements/linux-browser-tier.md` (R1, R4, R6.1, R6.2, R6.4).

- `src/containment.rs`, `src/unit.rs`: the mechanism is a transient `systemd-run --user` service
  (`KillMode=control-group`, `BindsTo` and `After` the daemon unit, `NoNewPrivileges`, `MemoryMax`,
  `TasksMax`, and the mount namespace tier where a probe shows it works). The command is
  `/usr/bin/env -i -C <dir> NAME=value ... node ...`, so the unit inherits nothing from the user
  manager. A self-test (two fixture units, a `SIGKILL` of the parent's main process, then a check
  that the bound unit and every process in its cgroup are gone and not revived when the parent
  restarts under `Restart=always`) must pass on the host before any child is started. Otherwise the
  backend is `unavailable: containment_unverified`. The daemon must be the main process of its own
  unit, or the answer is `daemon_not_unit_main`. The fixture design is this module's own: the ADR
  names the mechanism and says nothing about the fixture.
- `src/child.rs`: launch vector (`--password-store=basic` always, in `pw-config.json`, rewritten
  before every start; `--sandbox`; never `--no-sandbox`, `--port`, `--host`, `--allowed-hosts`),
  start, restart rules, stop. Restart happens on the next call only, with a backoff of 1, 2, 4, up to
  30 s; five failures in two minutes make the backend unavailable until `browser status --retry`
  (which removes `run/latch.json`) or the next daemon start. `sandbox_unavailable` and a
  `profile_locked` with a live holder are not retried, and the first is written as the recorded
  refusal (`run/refusal.json`) that a later `--use-system-chromium` needs. Long-lived children are forked
  by one thread that never exits, because `PR_SET_PDEATHSIG` is tied to the forking thread.
- `src/stdio_client.rs`: newline-delimited JSON-RPC; lines of at most 8 MiB, at most 64 calls in
  flight, a bounded write queue, `ping` for the health check (2 s), `notifications/cancelled` on a
  timeout. Errors are fixed classes (`upstream_timeout`, `upstream_bad_body`, `upstream_rpc_error`,
  `upstream_unreachable`, `upstream_busy`); no child text reaches one.
- `src/sweep.rs`, `src/run_record.rs`: the sweep before every child start (`.sweep.lock`, skipped
  while another start holds it) kills same-user processes whose executable is under a version or
  staging directory of the root, through a pidfd, except what a live run record claims. The same
  rule protects a sibling when a child is stopped: `Child::stop` walks the version directory too, and
  it now leaves alone what another live run record claims (`sweep::others_live`), so a sign-in and
  the daemon's child, which run from one version directory, never end each other's helpers. Run
  records (`run/<kind>-<pid>.json`: pid, start time, kind, unit) are at most 4 KiB each and at most 64.
  The sweep kills a process whose executable is there even if the user started it by hand.
- `src/sigstop.rs`: `SIGTERM`, `SIGINT` and `SIGHUP` stop the managed child and exit. A CLI child
  (the health check of `browser install|update`, 300 s, and the sign-in of `browser signin`, 30
  minutes) runs in its own transient unit with a `RuntimeMaxSec`, bound to nothing; `SIGKILL` of the CLI is cleaned by the next start's sweep, not by
  the kernel.
- `src/backend.rs`, `src/external.rs`, `src/procnet.rs`: the `Upstream` interface, the managed
  backend (`tools/list` filtered to the 32 catalog names), the external backend and the router.

Router, in order: `OAB_BROWSER=off` switches the managed tier off. With a managed install the
backend is `off` and a stale `MCP_UPSTREAM browser=` line is ignored (D5: external needs
`MCP_BROWSER_BACKEND=external`); with nothing installed a lone line still serves as external, and
with no line the backend is `off`. A valid managed install wins, and a `MCP_UPSTREAM browser=` line is ignored with
one `browser: external_upstream_ignored` log line and `sys_info.browser.external_upstream_ignored`,
unless `MCP_BROWSER_BACKEND=external`. `MCP_BROWSER_BACKEND=external` with no such line is
`unavailable: external_not_configured`. An installed but unusable managed tier is `unavailable` and
never falls to external. With nothing installed the line alone is external. No call is retried on
another backend.

An external upstream must be `http://127.0.0.1:<port>/<path>` or `http://[::1]:<port>/<path>`
(anything else, `localhost` included, makes the daemon exit 64 so its unit does not restart-loop).
Redirects are refused, errors are fixed classes with no upstream text, bodies are bounded, and the
owner uid of the server end of every connection is read from `/proc/net/tcp*` after the connect and
before any request byte; a different uid or an unreadable table fails closed
(`listener_owner_unknown`). Loopback is not private: a same-user process that listens on that port
is outside this control.

| Environment variable | Meaning |
| --- | --- |
| `OAB_BROWSER=off` | The managed tier starts no child (R1.6). With a managed install that means no `browser_*` tools, whatever `MCP_UPSTREAM` says. |
| `MCP_BROWSER_BACKEND=managed\|external` | Explicit choice. `external` is the explicit trust for the `MCP_UPSTREAM browser=` line. Any other value is `unavailable: backend_invalid`. |
| `MCP_UPSTREAM` | Unchanged name; used as external only as described above, and only with a literal loopback host. |

`sys_info` gains a `browser` object with fixed fields: `backend` (`managed`, `external`,
`unavailable`, `off`), `reason` (a fixed class), `containment` (`systemd`, `systemd+mount`,
`unverified`, `not_applicable`), `display` (`headed`, `headless`, `not_applicable`) and
`external_upstream_ignored`. It carries no URL, path, token or page data.

Known limit (V2): with the pinned Playwright and Chromium the managed tree opens no TCP or UDP
socket, but it does hold two listening Unix sockets inside its private `0700` `TMPDIR`
(Playwright's browser socket and Chromium's `SingletonSocket`). `browser status` reports them as
`listeners: tcp=0 udp=0 unix=2`. R1.1 says none, so this is open against the requirement.

The tests: the pure parts run anywhere; process, `/proc` and `systemd` tests are Linux-only. The
tests that need a user manager are `#[ignore]`d and run with `OAB_L2_SYSTEMD=1 cargo test --release
containment -- --ignored`; the end-to-end harness (`src/e2e_tests.rs`) runs as the main process of a
transient unit with `OAB_L2_E2E=1`. Their units are named `oab-l2-test-*`.

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
