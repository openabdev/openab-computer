# Tool profiles

When a computer is lent to an `openab-pty` session (reverse attach, `POST /attach {profile}`),
the **profile decides which tools the agent in that session can see and call**. In IAM terms:
a profile is a managed policy, a grant attaches it to a principal (the session), and the lease
(1–24 hours) is the session duration.

There are two profiles, `observe` and `owner` ([#59](https://github.com/openabdev/openab-computer/issues/59)).
They are named after the one boundary that is real: shell-equivalent or not.

- The filter runs **on the lent computer** (macOS: `ToolProfile.swift`; Linux:
  `poc/reverse-attach-linux/src/mcp.rs`). The session in the pod cannot change it.
- A tool outside the profile is absent from `tools/list`. A forced `tools/call` gets *unknown
  tool*, the same answer as for a tool that does not exist.
- Unknown profile names are refused with HTTP 400 and the body
  `{"error":"profile must be one of [owner, observe]"}`, on both platforms. A stored grant with an
  unknown profile is dropped when it is loaded. Names never widen to `owner`. Matching is exact:
  `Owner`, `OBSERVE`, `sandbox` and `browser` are unknown.
- A `POST /attach` **without** `profile` (or with a non-string one) gets `observe`, on both
  platforms. Clients should still send `profile`.
- The retired name `desktop` is accepted as input only and runs as `observe`. See
  [Upgrading from 0.8.x](#upgrading-from-08x-59).

> ⚠️ **Only `observe` is a security boundary.** `owner` is shell-equivalent: it serves the shell
> tools, and GUI control is a shell too (`osascript` runs `do shell script`, `key` can type into a
> terminal, and `mouse` can open one). It also serves every browser tool. The browser uses this
> computer's persistent profile and network, so it is owner-level as well
> ([#45](https://github.com/openabdev/instance-mcp/issues/45)). When you grant `owner`, lend a
> **dedicated computer** (a Linux hands node, a throwaway machine or VM), not the one you work on.
>
> Every **local** tool is classified `observe` (reads only), `act` (changes state) or `shell`
> (reaches the desktop user's shell). The boundary tests fail on any **unclassified** local tool,
> on a profile that claims to be narrower than a shell while allowing a `shell` tool, and on
> `observe` holding anything but `observe` tools (macOS `ProfileBoundaryTests`, Linux
> `profile_tests`). Upstream `browser_*` tools are classified by profile: `owner` gets all of them,
> including tools the upstream adds later, and `observe` gets none. Both platforms check this
> against the same 32-tool fixture in `conformance/profile_vectors.json` (`BrowserProfileTests`,
> `profile_conformance`).

## 1. Available profiles

| Profile | Shell-equivalent? | Tools on macOS | Tools on Linux | Purpose |
|---|---|---|---|---|
| `owner` | **yes** | 44 | 41 | Full control: every local tool and every browser tool |
| `observe` | **no** | 2 | 2 | Look, never act: system info and screenshots. The default |

The counts include the 32 browser tools (`browser_*`), which exist only when the computer is
configured with the Playwright upstream (`--upstream browser=…` on macOS, `MCP_UPSTREAM` on
Linux). Without it, `owner` has 12 tools on macOS and 9 on Linux, and `observe` is unchanged.

## 2. Complete tool lists per profile

### `owner`

#### macOS — 44 tools

| Category | Tools |
|---|---|
| System | `sys_info` |
| Shell | `exec`, `exec_start`, `exec_poll`, `exec_list`, `exec_cancel` |
| Screen / input | `screenshot`, `ui_snapshot`, `ui_action`, `mouse`, `key`, `osascript` |
| Browser (32) | `browser_navigate`, `browser_navigate_back`, `browser_snapshot`, `browser_find`, `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_hover`, `browser_select_option`, `browser_wait_for`, `browser_tabs`, `browser_take_screenshot`, `browser_console_messages`, `browser_resize`, `browser_evaluate`, `browser_run_code_unsafe`, `browser_file_upload`, `browser_drop`, `browser_pdf_save`, `browser_network_requests`, `browser_network_request`, `browser_handle_dialog`, `browser_emulate_media`, `browser_close`, `browser_drag`, `browser_mouse_move_xy`, `browser_mouse_click_xy`, `browser_mouse_drag_xy`, `browser_mouse_down`, `browser_mouse_up`, `browser_mouse_wheel` |

#### Linux — 41 tools

| Category | Tools |
|---|---|
| System | `sys_info` |
| Shell | `bash`, `exec_start`, `exec_poll`, `exec_list`, `exec_cancel` |
| Screen / input | `screenshot`, `mouse`, `key` |
| Browser (32) | the same 32 as on macOS |

Linux has no `osascript`, and no `ui_snapshot` or `ui_action` yet (AT-SPI versions are planned,
[#67](https://github.com/openabdev/openab-computer/issues/67)). `bash` is the counterpart of macOS `exec`; the four job tools have
the same names and contract on both (#32 item 4).

`owner` gets every upstream tool, so a tool that Playwright adds later appears under `owner`
without a code change. The browser runs with the computer's **persistent profile**, including
cookies for sites it is logged in to, and it reaches whatever network the computer reaches,
localhost and the tailnet included. `browser_evaluate` and `browser_run_code_unsafe` run arbitrary
JavaScript in that profile.

### `observe`

#### macOS and Linux — 2 tools

| Category | Tools |
|---|---|
| System | `sys_info` |
| Screen | `screenshot` |

This is an allowlist. Any tool added later, local or upstream (browser), is denied under
`observe` until it is added to `ToolProfile.observeTools` (Linux: `OBSERVE_TOOLS`) **and**
classified `observe`. `exec_poll`, `exec_list` and `ui_snapshot` are `observe`-class on macOS
but are not in `observe`. `ui_snapshot` changes nothing, but it is `owner`-only in phase 1
([#67](https://github.com/openabdev/openab-computer/issues/67)): it reads field values and text
that a screenshot does not show (scrolled-out rows, collapsed content, other windows with
`all_windows`), so moving it into `observe` is a separate decision. `ui_action` (#67 phase 2)
presses buttons and sets values in other apps, so it is `shell`-class like `mouse` and `key` and
`owner` only. Through a switchboard older than openab-sb 0.2.2, `ui_action` arguments, including
`set_value` values, are written to the switchboard's audit log. openab-sb 0.2.2 includes
openabdev/openab-sb#16 (argument redaction) and records `value` and `key` `text` only as a
redacted length. Do not send secrets through `set_value` over an older switchboard; `key` typing
has the same exposure there, as it did before.
Through `--switchboard` this daemon also refuses `set_value` on secure fields, doing nothing,
unless the operator passes `--switchboard-allow-secure-set-value`. That stops the secret from
being typed into the app, but the switchboard has already logged the call when it arrives.

In `observe`, a screenshot still discloses whatever is on screen, but the agent cannot change
anything.

**`observe` protects the computer, not the agent.** Every screenshot goes into the agent's
context. If the screen shows a hostile page or message, its text can act as a prompt injection
against the agent — which cannot act on this computer under `observe`, but still has its own shell
in the pod, whatever credentials the session holds (for example git), and **outbound internet
access by default**: it can send whatever it reads to any host. Treat what is on screen as
untrusted input to the agent; deployments that need to contain this should give the pod an egress
allowlist (model API, git remotes, package registries).

## 3. What `observe` removes from `owner`

| | macOS | Linux |
|---|---|---|
| Local tools removed | `exec`, `exec_start`, `exec_poll`, `exec_list`, `exec_cancel`, `osascript`, `ui_snapshot`, `ui_action`, `mouse`, `key` (10) | `bash`, `exec_start`, `exec_poll`, `exec_list`, `exec_cancel`, `mouse`, `key` (7) |
| Browser tools removed | all 32, and any added later | all 32, and any added later |
| Total | 44 → 2 | 41 → 2 |
| **Less privilege?** | **Yes**: no tool can type, run or change state | **Yes** |

On a reverse attach, a long `exec`, `osascript` or `bash` call (`timeout_secs` over 100) is
refused with a pointer to `exec_start`. Under `observe` that refusal does not apply: the call is
an *unknown tool* like any other hidden call, so the agent is not told the tool exists.

## Upgrading from 0.8.x (#59)

Up to 0.8.4 there were three profiles: `owner`, `desktop` and `observe`. `desktop` hid the `exec*`
tools and allowed 15 browser tools, but it was still shell-equivalent through the GUI. It is
removed. Nothing in the upgrade grants `owner`: every old `desktop` input runs as `observe`, and
the change is reported to the granter.

| Input | Before | After |
|---|---|---|
| `POST /attach {"profile":"desktop"}` | a `desktop` grant | 202, runs as `observe`. The grant JSON has `"profile":"observe"`, `"requested_profile":"desktop"` and a `warning`. The daemon log and the audit file record the mapping |
| `POST /attach` without `profile` | macOS `desktop`, Linux `observe` | `observe` on both |
| `POST /attach` with `sandbox` or any other unknown name | 400 (two different messages) | 400 `profile must be one of [owner, observe]` on both |
| A grant stored as `desktop` (macOS `~/Library/Application Support/oab-instance-mcp/grants.json`, Linux `grants.json`) | resumed as `desktop` | kept and re-dialled under its id, as `observe`. `GET /attach` shows `profile: observe`, `requested_profile: desktop` and the `warning`. The file is rewritten with `profile: observe` and the requested name |
| A grant stored as `sandbox` or an unknown name | dropped | dropped (unchanged, #46) |
| macOS `--switchboard-profile desktop` (a flag in the LaunchAgent plist) | `desktop` | serves `observe`, prints the warning to the agent log, and logs `switchboard: dialling … as observe (requested desktop)`. Any other unknown value still exits with status 64 |
| macOS `~/.config/oab-instance-mcp/switchboard.profile` containing `desktop` | copied into the plist | the installer writes `--switchboard-profile observe` and prints a warning. It does not edit your file |
| Linux environment and config | no profile setting exists | nothing to migrate |

`requested_profile` is in every grant JSON (it equals `profile` when nothing was mapped).
`warning` appears only when `desktop` was mapped. Its text is the same on both platforms:

> The `desktop` profile was removed (openab-computer#59). This grant runs as `observe`: sys_info
> and screenshot only. Grant `owner` explicitly for shell and browser access.

For a stored row, `requested_profile` is display only. The effective profile is the narrower of
`profile` and `requested_profile`, so editing the file to `{"profile":"owner",
"requested_profile":"desktop"}` still loads as `observe`. A `requested_profile` that is not a
string counts as absent on both platforms: the row keeps its stored profile.

**Audit file.** Every mapping is also appended as one JSON line to an audit file, separate from
the daemon log so it survives log rotation: macOS
`~/Library/Application Support/oab-instance-mcp/audit.jsonl`, Linux
`~/.local/state/oab-instance-mcp/audit.jsonl` (`$XDG_STATE_HOME` if set; override with
`MCP_AUDIT_FILE`, or `MCP_AUDIT_FILE=off` to disable). The file is mode 600 in a 0700 directory and
is only appended to. A record looks like this:

```json
{"event":"profile_mapped","source":"attach","grant":"<id>","session":"<session>","principal":"<login>","requested_profile":"desktop","profile":"observe","ts_epoch_secs":1762300000}
```

`source` is `attach` (a new request), `resume` (a stored grant re-dialled at start, recorded on
every restart while the grant lives) or `switchboard` (macOS `--switchboard-profile desktop`, with
no `grant`, `session` or `principal`). A write failure is logged and never blocks the grant.

**To restore shell or browser access**, grant `owner` explicitly: pick Owner in OpenAB Connect or
OpenAB Remote, or send `POST /attach` with `"profile":"owner"`. The new grant replaces the old one
for the same runtime and session. For a switchboard, write `owner` to
`~/.config/oab-instance-mcp/switchboard.profile` and re-run the installer: the flag lives in the
plist, so restarting the agent alone does not apply it. To keep `observe` and silence the warning,
write `observe` there.

**Rolling back** to 0.8.x keeps migrated grants at `observe`: the old daemon reads
`profile: observe` and ignores the extra field. The file `version` stays 1.

**Clients.** OpenAB Connect and Remote decode the grant's `profile` as a string and ignore unknown
keys, so they keep working. Until they are updated, picking "Desktop" there gets `observe`.

## Planned (not yet available)

- **Isolated browser tier**: Playwright tools with a **per-grant throwaway** browser profile, an
  egress block or a separate VM. This decision covers only the current shared-profile browser;
  the isolated tier can be added later as a new profile or as a proxy in front of the browser, once
  it has a real boundary.
- **Typed app control** in place of generic `osascript` for restricted tiers: open an app, click a
  menu item, list windows, all limited by a bundle-ID allowlist. The allowlist must exclude
  Terminal, iTerm, Script Editor and System Settings.
- **Custom policies**: an allow/deny list supplied with the grant. It gets the same escalation
  check as `ProfileBoundaryTests`: any list that contains a shell-capable tool is marked
  shell-equivalent.
- **VMs**: lend a disposable macOS VM instead of the host.

All tracked in [#45](https://github.com/openabdev/instance-mcp/issues/45).
