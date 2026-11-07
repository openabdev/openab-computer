# Tool profiles

When a computer is lent to an `openab-pty` session (reverse attach, `POST /attach {profile}`),
the **profile decides which tools the agent in that session can see and call**. In IAM terms:
a profile is a managed policy, a grant attaches it to a principal (the session), and the lease
(1–24 hours) is the session duration.

- The filter runs **on the lent computer** (macOS: `ToolProfile.swift`; Linux:
  `poc/reverse-attach-linux/src/mcp.rs`). The session in the pod cannot change it.
- A tool outside the profile is absent from `tools/list`. A forced `tools/call` gets *unknown
  tool*, the same answer as for a tool that does not exist.
- Unknown profile names are refused: HTTP 400 on `POST /attach`, and a stored grant with an
  unknown profile is dropped when it is loaded. They are never widened to `owner`.
- A `POST /attach` **without** `profile` gets the default profile. On Linux the default is
  `observe`. On macOS it is still `desktop`, which is shell-equivalent; moving it to `observe` is
  tracked in [#59](https://github.com/openabdev/openab-computer/issues/59). Clients should always
  send `profile`; OpenAB Connect and OpenAB Remote do.

> ⚠️ **Only `observe` is a security boundary.** GUI control is a shell: `osascript` runs
> `do shell script`, `key` can type into a terminal, and `mouse` can open one. `desktop` removes
> `exec*`, but that takes away a convenient entry point, not a privilege
> ([#45](https://github.com/openabdev/instance-mcp/issues/45)). When you grant full control, lend
> a **dedicated computer** (a Linux hands node, a throwaway machine or VM), not the one you work
> on. Every **local** tool is classified `observe` (reads only), `act` (changes state) or `shell`
> (reaches the desktop user's shell); the boundary tests fail on any **unclassified** local tool, on any
> profile that claims to be narrower than a shell while allowing a `shell` tool, and on `observe`
> holding anything but `observe` tools (macOS `ProfileBoundaryTests`, Linux `profile_tests`).
> Upstream `browser_*` tools are governed by their own allowlist (`desktop` gets 15, `observe`
> none) and are not in that classification yet; they must be before a `browser` tier ships.

## 1. Available profiles

| Profile | Shell-equivalent? | Tools on macOS | Tools on Linux | Purpose |
|---|---|---|---|---|
| `owner` | yes (directly) | 42 | 37 | The owner's own CLI: every tool |
| `desktop` | **yes** (through the GUI) | 20 | 20 | Let an agent drive the desktop: look, click, type, AppleScript, browser interaction |
| `observe` | **no** | 2 | 2 | Look, never act: system info and screenshots |

The former name `sandbox` has been **removed and is refused**, because it implied a boundary
that does not exist. Sending `sandbox` returns HTTP 400. A grant stored under `sandbox` is
dropped when it is loaded.

The counts include the browser tools (`browser_*`), which exist only when the computer is
configured with the Playwright upstream (`--upstream browser=…`; macmini, rpi1 and black are).
Without it, `owner` has 10 tools on macOS and 5 on Linux, `desktop` has 5 on both, and `observe`
is unchanged.

Lists taken on 2026-09-30 from the live `tools/list` of macmini (instance-mcp, macOS) and black
(Linux hands node), then filtered by this repository's profile rules.

## 2. Complete tool lists per profile

### `owner`

#### macOS — 42 tools

| Category | Tools |
|---|---|
| System | `sys_info` |
| Shell | `exec`, `exec_start`, `exec_poll`, `exec_list`, `exec_cancel` |
| Screen / input | `screenshot`, `mouse`, `key`, `osascript` |
| Browser (32) | `browser_navigate`, `browser_navigate_back`, `browser_snapshot`, `browser_find`, `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_hover`, `browser_select_option`, `browser_wait_for`, `browser_tabs`, `browser_take_screenshot`, `browser_console_messages`, `browser_resize`, `browser_evaluate`, `browser_run_code_unsafe`, `browser_file_upload`, `browser_drop`, `browser_pdf_save`, `browser_network_requests`, `browser_network_request`, `browser_handle_dialog`, `browser_emulate_media`, `browser_close`, `browser_drag`, `browser_mouse_move_xy`, `browser_mouse_click_xy`, `browser_mouse_drag_xy`, `browser_mouse_down`, `browser_mouse_up`, `browser_mouse_wheel` |

#### Linux — 37 tools

| Category | Tools |
|---|---|
| System | `sys_info` |
| Shell | `bash` |
| Screen / input | `screenshot`, `mouse`, `key` |
| Browser (32) | the same 32 as on macOS |

Linux has no `osascript`. `bash` is the counterpart of macOS `exec*`.

### `desktop`

#### macOS — 20 tools

| Category | Tools |
|---|---|
| System | `sys_info` |
| Screen / input | `screenshot`, `mouse`, `key`, `osascript` |
| Browser (15) | `browser_navigate`, `browser_navigate_back`, `browser_snapshot`, `browser_find`, `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_hover`, `browser_select_option`, `browser_wait_for`, `browser_tabs`, `browser_take_screenshot`, `browser_console_messages`, `browser_resize` |

#### Linux — 20 tools

| Category | Tools |
|---|---|
| System | `sys_info` |
| Shell | `bash` |
| Screen / input | `screenshot`, `mouse`, `key` |
| Browser (15) | the same 15 as macOS `desktop` |

The browser filter narrows the *tools*, not the browser. The browser runs with the computer's
**persistent profile**, including cookies for sites it is logged in to, and it reaches whatever
network the computer reaches, localhost and the tailnet included.

### `observe`

#### macOS and Linux — 2 tools

| Category | Tools |
|---|---|
| System | `sys_info` |
| Screen | `screenshot` |

This is an allowlist. Any tool added later, local or upstream (browser), is denied under
`observe` until it is added to `ToolProfile.observeTools` (Linux: `OBSERVE_TOOLS`) **and**
classified `observe`. A screenshot still discloses whatever is on screen, but the agent cannot
change anything.

**`observe` protects the computer, not the agent.** Every screenshot goes into the agent's
context. If the screen shows a hostile page or message, its text can act as a prompt injection
against the agent — which cannot act on this computer under `observe`, but still has its own shell
in the pod, whatever credentials the session holds (for example git), and **outbound internet
access by default**: it can send whatever it reads to any host. Treat what is on screen as
untrusted input to the agent; deployments that need to contain this should give the pod an egress
allowlist (model API, git remotes, package registries).

## 3. What each profile loses against the previous one

### `owner` → `desktop`

| | macOS | Linux |
|---|---|---|
| Local tools removed | `exec`, `exec_start`, `exec_poll`, `exec_list`, `exec_cancel` (5) | none (`bash` stays; see below) |
| Browser tools removed (17) | `browser_evaluate`, `browser_run_code_unsafe` (arbitrary JavaScript); `browser_file_upload`, `browser_drop`, `browser_pdf_save` (filesystem); `browser_network_requests`, `browser_network_request` (network inspection); `browser_handle_dialog`, `browser_emulate_media`, `browser_close`; `browser_drag`, `browser_mouse_move_xy`, `browser_mouse_click_xy`, `browser_mouse_drag_xy`, `browser_mouse_down`, `browser_mouse_up`, `browser_mouse_wheel` (raw coordinate mouse) | the same 17 |
| Total | 42 → 20 | 37 → 20 |
| **Less privilege?** | **No**: `osascript`, `key` and `mouse` still reach the desktop user's shell | **No**: `bash` is a shell |

Linux `desktop` keeps `bash` because `mouse` and `key` can open a terminal anyway. Hiding it would
only inconvenience the agent without removing any privilege, and the profile does not pretend
otherwise.

### `desktop` → `observe`

| | macOS | Linux |
|---|---|---|
| Local tools removed | `mouse`, `key`, `osascript` (3) | `bash`, `mouse`, `key` (3) |
| Browser tools removed | all 15 | all 15 |
| Total | 20 → 2 | 20 → 2 |
| **Less privilege?** | **Yes**: no tool can type, run or change state | **Yes** |

## Compatibility and status

- **Accepted wire values:** `owner`, `desktop`, `observe`. Anything else is a 400, including the
  former `sandbox`.
- **Breaking change:** clients and computers must be updated together. An older Connect or Remote
  that sends `sandbox` is refused by an updated computer. An updated client that sends `desktop`
  or `observe` is refused by an older computer. The client side is oablab/oab-pty-mac#77, which
  also makes `observe` the default choice.
- **Existing grants:** a grant stored as `sandbox` by an older build is dropped when the updated
  daemon loads it, so the grant ends and must be made again.
- **Linux default profile (behaviour change):** up to 0.8.2 the Linux daemon gave a bare
  `POST /attach` (no `profile`) the `owner` profile. It now gives `observe`. A caller that relied
  on the implicit `owner` gets a grant with only `sys_info` and `screenshot`, and must send
  `"profile":"owner"` (or `desktop`) explicitly. Grants already stored keep the profile they were
  made with.
- **Downgrade:** grants stored by this build carry `desktop` or `observe`. An older daemon does
  not recognize them and drops them, so the grant ends instead of widening.

## Planned (not yet available)

- **`browser`**: Playwright tools only, with a **per-grant throwaway** browser profile and no
  `browser_evaluate`. The browser provides the boundary. It still reaches the computer's network,
  and the documentation must say so.
- **Typed app control** in place of generic `osascript` for restricted tiers: open an app, click a
  menu item, list windows, all limited by a bundle-ID allowlist. The allowlist must exclude
  Terminal, iTerm, Script Editor and System Settings.
- **Custom policies**: an allow/deny list supplied with the grant. It gets the same escalation
  check as `ProfileBoundaryTests`: any list that contains a shell-capable tool is marked
  shell-equivalent.
- **VMs**: lend a disposable macOS VM instead of the host.

All tracked in [#45](https://github.com/openabdev/instance-mcp/issues/45).
