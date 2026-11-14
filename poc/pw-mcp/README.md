# Step 1 PoC — Playwright MCP on the Mac, driven from the tailnet

> Done 2026-09-22. Design context: openabdev/openab#1544.
> Proves the browser half of the relay-agent design before any Swift is written:
> a headed browser living in the Mac's Aqua session, served as an MCP server on loopback.
>
> **Playwright MCP is loopback only (`127.0.0.1:8794`) and has no authentication.** It is not
> mapped onto the tailnet and has no `:8443` access path (#115). Browser tools are reached only
> through `oab-computer` (`--upstream browser=http://127.0.0.1:8794/mcp`), which adds the
> Tailscale login check, the bearer token and the owner-only tool profile. The first version of
> this PoC mapped `:8443` with `tailscale serve`; see
> [Older installs](#older-installs-may-still-have-a-8443-mapping).

## What is deployed on the Mac

| Piece | Location |
|---|---|
| `@playwright/mcp@0.0.82` (pinned, `npm install --save-exact`) | `~/.local/oab-computer/pw-mcp/` |
| Wrapper script | `~/.local/oab-computer/pw-mcp.sh` (from `pw-mcp.sh` here) |
| LaunchAgent (`gui/<uid>`) | `~/Library/LaunchAgents/dev.openab.computer.pw-mcp.plist` (rendered by `install.sh`) |
| Persistent browser profile | `~/.local/oab-computer/pw-profile/` |
| Screenshot / snapshot output | `~/.local/oab-computer/pw-output/` |
| Logs | `~/Library/Logs/oab-computer/pw-mcp.{log,err}` |
| Listener | `127.0.0.1:8794` (loopback only; the wrapper passes `--host 127.0.0.1`) |
| Tailnet URL | None. `install.sh` creates no `tailscale serve` mapping |

Browser: Playwright's bundled Chromium (`~/Library/Caches/ms-playwright/chromium-1246`),
**headed**, spawned as a child of the LaunchAgent pid, so it is a real window in the
logged-in desktop session. No Google Chrome is installed on the Mac.

Client side: do not point a client at Playwright directly. Connect to `oab-computer`, which
re-serves the `browser_*` tools under its `owner` profile (top-level README, "Browser tools for
lent sessions").

## Install / operate

```sh
ssh <mac> 'cd ~/src/oab-computer && bash poc/pw-mcp/install.sh'   # idempotent
```

```sh
ssh <mac> launchctl print gui/501/dev.openab.computer.pw-mcp | grep -E 'state|pid'
ssh <mac> launchctl kickstart -k gui/501/dev.openab.computer.pw-mcp   # restart
ssh <mac> tail -20 ~/Library/Logs/oab-computer/pw-mcp.err
ssh <mac> lsof -nP -iTCP:8794 -sTCP:LISTEN   # one listener, on 127.0.0.1
```

At the end, `install.sh` runs a read-only check (`tailscale serve status`) and prints a warning
if a `:8443` mapping to `127.0.0.1:8794` exists. It never changes a mapping.

### Older installs may still have a :8443 mapping

Earlier versions of `install.sh` ran `tailscale serve --bg --https=8443 http://127.0.0.1:8794`.
Re-running the new installer does not remove it. That mapping lets any device on the tailnet call
every browser tool without a login check or token, including `browser_run_code_unsafe`. Check and
remove it on each Mac that ran the old installer:

```sh
tailscale serve status              # look for :8443 pointing at http://127.0.0.1:8794
tailscale serve --https=8443 off    # remove only that mapping
```

Browser tools keep working through `oab-computer`, which reaches Playwright over loopback.

## Measurements (first PoC, laptop → the Mac through the since-removed :8443 mapping)

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
   `127.0.0.1` does not cover `127.0.0.1:8794`. List every form a client will send.
   (oab-computer sends the bare `127.0.0.1`, which the wrapper allows.)
2. **Default browser channel is `chrome`, not bundled Chromium.** Without
   `--browser chromium` the first tool call fails with
   `Chromium distribution 'chrome' is not found at /Applications/Google Chrome.app`. The
   server starts fine and `initialize` succeeds, so a health check on `/mcp` alone does not
   catch this — only a real `tools/call` does.
3. **One persistent profile, many MCP sessions → `Browser is already in use for <profile>`.**
   Each MCP client session (every kiro-cli run is a new one) tries to launch its own browser
   on the shared `--user-data-dir`. Fix: `--shared-browser-context`. Alternative `--isolated`
   loses login state between sessions, which defeats the point of a resident browser.
4. **History: the first PoC used a dedicated HTTPS port** (`--https=8443`) because the MCP
   server expects `/mcp` at root. That mapping was removed from the design in #115.
5. **RAID/TCC reminder held.** Everything lives on the internal disk (`~/.local/...`), per the
   home.md rule that LaunchAgents cannot read the external RAID. The `.zshenv: .cargo/env:
   operation not permitted` line in `pw-mcp.err` is that same restriction firing on the
   login shell's rc file — harmless here because the wrapper sets PATH itself and `exec`s node.
6. `launchctl print` shows `state = running` even when the wrapper is about to die; check
   the `.err` log, and check `lsof -nP -iTCP:8794 -sTCP:LISTEN`.

## Security posture

- Playwright MCP has no authentication. It listens on `127.0.0.1:8794` only, so only processes
  on this Mac reach it. There is no `tailscale serve` mapping for it and no `:8443` access path.
- Browser tools reach other machines only through `oab-computer`'s `--upstream`, behind its
  login check and bearer token, and only under the `owner` profile: `observe` gets no browser
  tool (#59). A switchboard's per-caller allowlist applies on top.
- `browser_run_code_unsafe` is in the tool list: arbitrary Playwright JS in the logged-in
  browser profile. That is why Playwright must not be reachable without the daemon's auth.

## What this proves for the design

- The Aqua-session LaunchAgent + loopback listener shape works and needs no custom transport.
  The Swift `oab-computer` re-serves the browser tools to remote callers.
- Playwright MCP covers the browser half completely; the Swift daemon does not need to
  touch CDP. `connectOverCDP` from the sandbox was never needed.

## Next

The Swift `oab-computer` daemon (see top-level README) runs beside this on `127.0.0.1:8795`,
same LaunchAgent pattern, with Tailscale-identity auth, and re-serves these tools through
`--upstream`. Lent callers get the browser only under `owner` (#59).
