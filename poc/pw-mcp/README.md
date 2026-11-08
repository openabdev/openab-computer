# Step 1 PoC — Playwright MCP on macmini, driven from the tailnet

> Done 2026-09-22. Design context: openabdev/openab#1544.
> Proves the transport half of the relay-agent design before any Swift is written:
> a headed browser living in macmini's Aqua session, exposed as a remote MCP server
> through `tailscale serve`, consumed by kiro-cli on the laptop.

## What is deployed on macmini

| Piece | Location |
|---|---|
| `@playwright/mcp@0.0.82` (pinned, `npm install --save-exact`) | `~/.local/oab-instance-mcp/pw-mcp/` |
| Wrapper script | `~/.local/oab-instance-mcp/pw-mcp.sh` (from `pw-mcp.sh` here) |
| LaunchAgent (`gui/<uid>`) | `~/Library/LaunchAgents/dev.openab.instance-mcp.pw-mcp.plist` (rendered by `install.sh`) |
| Persistent browser profile | `~/.local/oab-instance-mcp/pw-profile/` |
| Screenshot / snapshot output | `~/.local/oab-instance-mcp/pw-output/` |
| Logs | `~/Library/Logs/oab-instance-mcp/pw-mcp.{log,err}` |
| Listener | `127.0.0.1:8794` (loopback only) |
| Tailnet URL | `https://<host>.<tailnet>.ts.net:8443/mcp` via `tailscale serve --bg --https=8443 http://127.0.0.1:8794` |

Browser: Playwright's bundled Chromium (`~/Library/Caches/ms-playwright/chromium-1246`),
**headed**, spawned as a child of the LaunchAgent pid, so it is a real window in the
logged-in desktop session. No Google Chrome is installed on macmini.

Client side (laptop): `kiro-cli mcp add --name macmini-browser --url https://<host>.<tailnet>.ts.net:8443/mcp --scope global --timeout 20000`.

## Install / operate

```sh
ssh macmini 'cd ~/src/oab-instance-mcp && bash poc/pw-mcp/install.sh'   # idempotent
```

```sh
ssh macmini launchctl print gui/501/dev.openab.instance-mcp.pw-mcp | grep -E 'state|pid'
ssh macmini launchctl kickstart -k gui/501/dev.openab.instance-mcp.pw-mcp   # restart
ssh macmini tail -20 ~/Library/Logs/oab-instance-mcp/pw-mcp.err
ssh macmini /Applications/Tailscale.app/Contents/MacOS/Tailscale serve status
```

Smoke test from the laptop (no LLM in the loop):

```sh
kiro-cli chat --no-interactive --trust-tools=@macmini-browser --agent kiro_default \
  "Use macmini-browser only: navigate to https://example.com, browser_snapshot, report the title."
```

## Measurements (laptop → macmini over tailnet, direct connection)

| Call | Latency |
|---|---|
| MCP `initialize` | 80 ms |
| `tools/list` | 32 tools |
| `browser_navigate` cold (launches Chromium) | 2.6 s |
| `browser_navigate` warm | 0.3–0.56 s |
| `browser_snapshot` | 0.21 s |
| `browser_take_screenshot` (jpeg, 168 KB, viewport) | 1.65 s |
| Full kiro-cli turn: navigate + snapshot + navigate | 10 s wall, ~1 s of it in tools |

Latency is not the bottleneck; the LLM round trip is. Good enough for the thin-executor model.

## Gotchas (each cost a restart)

1. **`--allowed-hosts` is an exact string match on the `Host` header, port included.**
   `<host>.<tailnet>.ts.net` does *not* cover `<host>.<tailnet>.ts.net:8443`, and
   `127.0.0.1` does not cover `127.0.0.1:8794`. List every form the proxy will forward.
   (`tailscale serve` forwards the original Host, with port.)
2. **Default browser channel is `chrome`, not bundled Chromium.** Without
   `--browser chromium` the first tool call fails with
   `Chromium distribution 'chrome' is not found at /Applications/Google Chrome.app`. The
   server starts fine and `initialize` succeeds, so a health check on `/mcp` alone does not
   catch this — only a real `tools/call` does.
3. **One persistent profile, many MCP sessions → `Browser is already in use for <profile>`.**
   Each MCP client session (every kiro-cli run is a new one) tries to launch its own browser
   on the shared `--user-data-dir`. Fix: `--shared-browser-context`. Alternative `--isolated`
   loses login state between sessions, which defeats the point of a resident browser.
4. **Dedicated HTTPS port rather than a path on :443.** The existing `:443` mappings are
   path-prefixed (`/wdyt`, `/lossic`, …); the MCP server expects `/mcp` at root and the SSE
   endpoint at `/sse`, so `--https=8443` avoids any path rewriting question.
5. **RAID/TCC reminder held.** Everything lives on the internal disk (`~/.local/...`), per the
   home.md rule that LaunchAgents cannot read the external RAID. The `.zshenv: .cargo/env:
   operation not permitted` line in `pw-mcp.err` is that same restriction firing on the
   login shell's rc file — harmless here because the wrapper sets PATH itself and `exec`s node.
6. `launchctl print` shows `state = running` even when the wrapper is about to die; check
   the `.err` log, and check `lsof -nP -iTCP:8794 -sTCP:LISTEN`.

## Security posture of this PoC

- Reachable only inside the tailnet (`tailscale serve`, not `funnel`). Anyone on the tailnet
  can drive the browser; there is no token check yet. Add a Tailscale ACL restricting
  `macmini:8443` to the laptop before leaving this running unattended, or front it with the
  Swift daemon that checks `Tailscale-User-Login`.
- `browser_run_code_unsafe` is in the tool list — arbitrary Playwright JS on the box. Fine
  for "my CLI on my Mac". A lent session reaches the browser only through the daemon's
  `--upstream`, and only under the `owner` profile: `observe` gets no browser tool (#59).

## What this proves for the design

- The Aqua-session LaunchAgent + loopback listener + `tailscale serve` shape works and
  needs no custom transport. The Swift `oab-instance-mcp` (exec / screenshot / mouse / key /
  osascript) will sit behind the same pattern on the next port.
- Playwright MCP covers the browser half completely; the Swift daemon does not need to
  touch CDP. `connectOverCDP` from the sandbox was never needed.

## Next

Step 2 shipped 2026-09-22: the Swift `oab-instance-mcp` daemon (see top-level README) runs beside
this on `127.0.0.1:8795` → `tailscale serve --https=8444`, same LaunchAgent pattern, with
`exec` / `screenshot` / `sys_info` and Tailscale-identity auth. Remaining for the browser
half: a Tailscale ACL on :8443. Lent callers get the browser only under `owner` (#59).
