# Browser tools

User guide to the 32 `browser_*` tools (navigate, snapshot, click, type, and so on) on macOS and
Linux. The server behind them is `@playwright/mcp`, which is not our code. What differs between the
platforms is who installs and runs it.

Reference material: the tool list is in [Tool profiles](tool-profiles.md), the network and download
details are in the README sections
[Browser tools](../README.md#browser-tools) and
[What the app downloads](../README.md#what-the-app-downloads), and the designs are in
[`adr/browser-tiers.md`](adr/browser-tiers.md) (macOS) and
[`adr/linux-browser-tier.md`](adr/linux-browser-tier.md) (Linux).

## At a glance

| | macOS | Linux |
|---|---|---|
| Who runs Playwright | The app, as a child process over stdio (**managed**), or an operator-run listener you point it at (**external**) | After 0.12.0: the daemon, as a child over stdio in its own systemd user unit (**managed**). In 0.12.0 and earlier, and on a host that still has the old unit: `oab-computer-pw-mcp.service` (**external**) |
| Listening port | Managed: none. External: `127.0.0.1:8794` | Managed: none. External: `127.0.0.1:8794`, no authentication |
| How you install it | Setup wizard page or menu item | `install-linux.sh` asks (`--browser managed` or `--yes` to agree, `--browser none` or `--no-browser` to skip), or `oab-computer browser install` |
| Browser | A pinned Chromium (Chrome for Testing) the app downloads | A pinned Chromium (Chrome for Testing) the install downloads, with a pinned Node.js |
| Update and remove | Menu items | `oab-computer browser update` and `remove` |
| Sign-in window | Menu item **Open Playwright window to sign in…** | `oab-computer browser signin`, run over `ssh -t`; the window is on the node's seat |
| Who can call the tools | Through oab-computer, the `owner` profile only. With an external listener, anyone who can reach its port directly bypasses that check | Through oab-computer, the `owner` profile only. A host that still runs the old unit has port `8794` open to every local user, see the warning below |

Every `browser_*` call acts as the user on the sites the browser is signed in to, and
`browser_evaluate` and `browser_run_code_unsafe` run arbitrary code in the page or in Node. Treat
browser access as owner-level. `observe` sessions get none of these tools.

## Tiers

The macOS app routes browser calls through a router with room for more than one backend. In 0.12.0
only the first slot exists.

| Tier | What it is | Status in 0.12.0 |
|---|---|---|
| Playwright (Tier P) | `@playwright/mcp` driving Chromium. Managed or external. | Built on macOS. Linux has both forms after 0.12.0, and the external form only before |
| Apple Events (Tier A) | Drive Safari or Chrome through Apple Events, no download | Not built. A call that asks for `appleEvents` answers "not set up" |
| CDP (Tier C) | Attach to a browser over the DevTools protocol | Not built |
| Installed-Chrome fallback | Use your own Chrome when macOS refuses the downloaded Chromium | Not built ([#128](https://github.com/openabdev/openab-computer/issues/128)) |

A caller can send an `OAB-Browser-Backend` request header with `auto`, `playwright` or `appleEvents`.
Only direct `/mcp` requests are read for it; switchboard and reverse-attach callers use the stored
preference, or `auto`. With only the Playwright slot filled, `auto` and `playwright` both use it.

## macOS

### What is downloaded, where, and how big

Nothing is bundled in the app and nothing is downloaded until you ask. The install fetches three
things for the architecture of this Mac into
`~/Library/Application Support/oab-computer/playwright/`, never into the app bundle:

| What | From | Version |
|---|---|---|
| Node.js (includes `npm`) | `nodejs.org` | 24.22.3 |
| `@playwright/mcp` and its dependencies (3 npm packages) | `registry.npmjs.org` | 0.0.82 |
| Chromium (Chrome for Testing) | `storage.googleapis.com/chrome-for-testing-public` | 154.0.8037.0 |

Sizes on Apple silicon: about 249 MB to download, about 593 MB once installed, and about 842 MB of
free disk while it runs (the downloads plus the unpacked files). Intel is slightly larger: about
260 MB, about 606 MB and about 867 MB. The wizard shows the exact figures, taken from the manifest
built into the app. Versions are pinned in the app and checked by the release process
([Releasing](releasing.md#playwright-pins)).

Every file is checked against sizes and SHA-256 digests built into the signed app before it is
extracted, and the npm packages against a built-in lockfile. A mismatch installs nothing. The
install adds no LaunchAgent and opens no listener. The managed browser's own profile and output
folders live in the same directory (`profile`, `output`), apart from your Chrome and Safari. The
full list of what the app fetches and never does is in the README
([What the app downloads](../README.md#what-the-app-downloads)).

### Install

- **Wizard.** The **Set Up Mac Permissions** window has a **Browser tools** page after Full Disk
  Access and before the optional tailnet page. The Playwright box is pre-checked and the text shows
  the download size, the hosts, the folder and the free disk needed. Uncheck it to skip; nothing is
  downloaded until you press **Continue** with it checked. Offline or after a failed download the page
  offers **Retry** and **Continue without**, and Playwright simply stays not installed.
- **Menu bar.** **Set up browser tools…** opens the wizard on that page. **Install Playwright…** asks
  first with the same text.

An install takes effect on the next `browser_*` call with no restart. With nothing installed the
browser tools are not listed, and a call says Playwright is not installed.

### Update

**Update Playwright… (x → y)** appears only when the Playwright version pinned in the app you run
differs from the installed one. The app compares the two ids for inequality, not their order. It asks before it downloads, and a failed update leaves the installed version
running. An update is only ever offered, never applied silently.

### Remove

**Remove Playwright…** asks first. It deletes the version folders that carry the installer's marker,
and the browser profile and its cookies when the installer's own, readable `install.json` confirms it
created them. If `install.json` is unreadable, invalid or hand-made, the profile and anything it points
to stay, and the app tells you it removed only part. Chrome, Safari and `~/.local/oab-computer/` are
never touched.

### Sign in once

**Open Playwright window to sign in…** starts the managed browser if needed and opens a headed
Chromium window on the managed browser's own profile (not your Chrome or Safari). Sign in to the
sites you want agents to use. The session stays in that profile, including after the app or the
browser restarts. Some sites may refuse an automated browser, and the app cannot change that.
Because the profile holds cookies, anything an agent can do on those sites it does as you.

### External provider and explicit trust

You can run Playwright yourself (the optional agent in
[`poc/pw-mcp/README.md`](../poc/pw-mcp/README.md), or any `@playwright/mcp` listener) and pass
`--upstream browser=http://127.0.0.1:8794/mcp` to the app. The installer adds that flag only when the
external Playwright LaunchAgent is already loaded.

- **Trust is explicit.** Nothing discovers port 8794 by itself. The backend is only used because you
  passed the flag. A later "Use it" prompt is reserved in the code and not built.
- **Strict address.** The host must be the literal `127.0.0.1` or `::1`, redirects are not followed,
  and the process listening on that port must run as your user.
- **The flag replaces the managed child.** With `--upstream browser=…`, the app uses the external
  Playwright and does not start the managed one. The menu shows the external address and who owns
  the port. The wizard page and the install and remove menu items are still offered, with a note
  that the external provider is used.
- **Port 8794 is loopback, not private.** Any process on this Mac can reach it, and it has no
  authentication of its own. The app's own authentication applies to callers before browser tools
  are relayed.

### Check the state

The menu's **Browser tools** row shows either the external address and owner, or the managed state:
**Playwright ready**, **Playwright not installed**, **Playwright install not usable**, or an
unavailable state with a short code. Opening the menu reads `install.json` and checks the installed
files. It starts nothing.

## Linux

### Managed (after 0.12.0)

`oab-computer browser install` downloads the pinned Node.js, `@playwright/mcp` and Chromium into
`${XDG_DATA_HOME:-$HOME/.local/share}/oab-computer/playwright/`, checks every file against sizes and
SHA-256 digests built into the binary, and runs a headless health check. The daemon then starts the
browser on the first `browser_*` call, as a child over stdio in a transient systemd user unit that
ends with the daemon. It has no port and no `MCP_UPSTREAM` line. What is downloaded, how big it is,
the root actions an install may ask for, offline install, sign-in and what `remove` deletes are in
[Linux setup](linux-setup.md#4-browser-tools-playwrightmcp); the figures are the same ones the
[macOS table](../README.md#what-the-app-downloads) uses, for the Linux builds (about 259 MB to
download, about 630 MB on disk, about 890 MB of free space while it runs).

- `install-linux.sh` shows what an install downloads and asks first. With no terminal it downloads
  nothing unless you pass `--browser managed` or `--yes`.
- The browser is headed when the seat's Wayland socket exists, else headless. It uses one persistent
  profile with `--password-store=basic`: saved passwords are obfuscated, not strongly encrypted.
- For a login the browser should keep, run `ssh -t <node> '~/.local/oab-computer/oab-computer browser signin'`
  and use the window ([Sign in](linux-setup.md#sign-in)). A node with no monitor is driven through the
  `screenshot`, `mouse` and `key` tools.
- `oab-computer browser update` is prompted, never silent, and keeps the old version if the new one
  fails its health check. `oab-computer browser remove` deletes only what carries the installer's
  marker and prints what it left.
- A migrated host starts with a fresh profile; the old profile stays and holds the old cookies
  ([Upgrading a host that already has a browser unit](linux-setup.md#upgrading-a-host-that-already-has-a-browser-unit)).

### External, on 8794 (0.12.0 and earlier, or by choice)

0.12.0 and earlier set up a user unit `oab-computer-pw-mcp.service` listening on `127.0.0.1:8794`
(with `@playwright/mcp` 0.0.82 installed by `npm`, a distro or Playwright-downloaded Chromium, the
`MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp` line in `oab-computer.service`, a Chromium policy file
and, on Ubuntu 24.04, an AppArmor profile). The current installer writes none of it. A host that
still runs that unit, or one where you set `MCP_BROWSER_BACKEND=external` on purpose, keeps this
behavior:

**Port 8794 is unauthenticated.** Any local user on the node can call every browser tool, including
`browser_run_code_unsafe` (arbitrary Node code). The installer creates no `tailscale serve` mapping
for 8794. A managed install wins over the old line unless `MCP_BROWSER_BACKEND=external` is set, and
the installer only warns about the old unit, with the exact `systemctl --user disable --now <unit>`
command. The steps to turn it off and to remove what is left are in
[Linux setup](linux-setup.md#upgrading-a-host-that-already-has-a-browser-unit).

## What differs by platform

| | macOS only | Linux only | Both |
|---|---|---|---|
| Managed Playwright (wizard and menu install, update, remove, sign-in window) | yes | | |
| Managed Playwright (`oab-computer browser install`, `update`, `remove`, `signin`, no port) | | yes, after 0.12.0 | |
| The router and the `OAB-Browser-Backend` header | yes | | |
| Profile filtering of upstream tools against the built-in catalog | yes (a tool Playwright adds later stays hidden until the catalog is updated) | | |
| Pass-through of whatever the external upstream lists (the managed backend filters to the catalog) | | yes | |
| `--browser managed\|none`, `--yes` and `--apply-system-changes` installer options, and the 8794 caveat of an old unit | | yes | |
| External Playwright on loopback 8794 | | | yes, on Linux only for an old install or `MCP_BROWSER_BACKEND=external` |
| `owner`-only access, persistent profile with cookies | | | yes |

The Linux external pass-through is described in [Tool profiles](tool-profiles.md).

## Troubleshooting

- **"Browser tools are not set up"** (macOS): install Playwright from the wizard, or pass
  `--upstream browser=…`. The menu row names the state.
- **macOS refuses to run the downloaded Chromium:** the install stops with that message. The app never
  adds or removes the `com.apple.quarantine` attribute, and the installed-Chrome fallback is not built
  ([#128](https://github.com/openabdev/openab-computer/issues/128)).
- **No `browser_*` tools on Linux:** run `oab-computer browser status` and read `sys_info.browser`. `not_installed` means run
  `oab-computer browser install`; `containment_unverified` means this host has no working user
  manager, and the managed browser will not start without one; `off` means `OAB_BROWSER=off`. On an
  old external install, check `systemctl --user status oab-computer-pw-mcp.service`.
- **A site shows a login wall or a captcha:** use the sign-in window (macOS) or
  `oab-computer browser signin` (Linux) to sign in once. Some sites refuse automated browsers.
