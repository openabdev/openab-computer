# Browser tools

User guide to the 32 `browser_*` tools (navigate, snapshot, click, type, and so on) on macOS and
Linux. The server behind them is `@playwright/mcp`, which is not our code. What differs between the
platforms is who installs and runs it.

Reference material: the tool list is in [Tool profiles](tool-profiles.md), the network and download
details are in the README sections
[Browser tools](../README.md#browser-tools) and
[What the app downloads](../README.md#what-the-app-downloads), and the designs are in
[`adr/browser-tiers.md`](adr/browser-tiers.md) (macOS) and
[`adr/linux-browser-tier.md`](adr/linux-browser-tier.md) (Linux, planned).

## At a glance

| | macOS | Linux |
|---|---|---|
| Who runs Playwright | The app, as a child process over stdio (**managed**), or an operator-run listener you point it at (**external**) | An operator-style unit, `oab-computer-pw-mcp.service`, that `install-linux.sh` creates (**external**) |
| Listening port | Managed: none. External: `127.0.0.1:8794` | `127.0.0.1:8794`, no authentication |
| How you install it | Setup wizard page or menu item | `install-linux.sh` (skip with `--no-browser`) |
| Browser | A pinned Chromium (Chrome for Testing) the app downloads | The distro `chromium` if present, otherwise Playwright's own Chromium |
| Update and remove | Menu items | By hand, see [Linux update and remove](#linux-update-and-remove) below |
| Sign-in window | Menu item **Open Playwright window to sign in…** | The browser window is on the node's desktop seat |
| Who can call the tools | `owner` profile only | `owner` profile only |

Every `browser_*` call acts as the user on the sites the browser is signed in to, and
`browser_evaluate` and `browser_run_code_unsafe` run arbitrary code in the page or in Node. Treat
browser access as owner-level. `observe` sessions get none of these tools.

## Tiers

The macOS app routes browser calls through a router with room for more than one backend. In 0.12.0
only the first slot exists.

| Tier | What it is | Status in 0.12.0 |
|---|---|---|
| Playwright (Tier P) | `@playwright/mcp` driving Chromium. Managed or external. | Built on macOS. Linux has the external form only |
| Apple Events (Tier A) | Drive Safari or Chrome through Apple Events, no download | Not built. A call that asks for `appleEvents` answers "not set up" |
| CDP (Tier C) | Attach to a browser over the DevTools protocol | Not built |
| Installed-Chrome fallback | Use your own Chrome when macOS refuses the downloaded Chromium | Not built ([#128](https://github.com/openabdev/openab-computer/issues/128)) |

A caller can send an `OAB-Browser-Backend` request header with `auto`, `playwright` or `appleEvents`.
With only the Playwright slot filled, `auto` and `playwright` both use it.

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

**Update Playwright… (x → y)** appears only when the app you run carries a newer pinned version than
the one installed. It asks before it downloads, and a failed update leaves the installed version
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

### Today: an external unit on 8794

`install-linux.sh` sets up, unless you pass `--no-browser`:

- `@playwright/mcp` 0.0.82, installed with `npm` under `~/.local/oab-computer/pw-mcp` (the installer
  needs `node` and `npm`; without them it skips the browser tools),
- a Chromium: the distro `chromium` when present, otherwise Playwright's own build downloaded into
  `~/.cache/ms-playwright` (this download has no size or hash pinned by this project),
- a user unit `oab-computer-pw-mcp.service` listening on `127.0.0.1:8794`, with a persistent profile
  in `~/.local/oab-computer/pw-profile`,
- the `MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp` line in `oab-computer.service`, and a Chromium
  policy file `/etc/chromium/policies/managed/oab-computer.json` (when `sudo` allows it) that blocks
  camera, microphone, notification and location prompts,
- on Ubuntu with `apparmor_restrict_unprivileged_userns` set (and `sudo` allowed), an AppArmor profile
  `/etc/apparmor.d/playwright-chromium` that lets Playwright's own Chromium create its sandbox,
- the font packages `fonts-dejavu-core`, `fonts-liberation`, `fonts-noto-cjk` and
  `fonts-noto-color-emoji` (when `sudo` allows it), so pages do not render as boxes.

**Port 8794 is unauthenticated.** Any local user on the node can call every browser tool, including
`browser_run_code_unsafe` (arbitrary Node code). On a shared host use `--no-browser`. The installer
creates no `tailscale serve` mapping for 8794.

The browser is headed and appears on the node's desktop seat (a real desktop, or the headless sway
seat from `--headless-seat`). Sign in to sites by using that window through the `screenshot` and
`mouse` tools or at the node itself. Linux has no wizard, no menu bar and no update or remove
commands for the browser: use `systemctl --user` and the steps in [Linux setup](linux-setup.md#4-browser-tools-playwrightmcp).

### Linux update and remove

There is no command for these. To update, stop the unit, change the version, and start it again:

```sh
systemctl --user stop oab-computer-pw-mcp.service
cd ~/.local/oab-computer/pw-mcp && npm install --save-exact @playwright/mcp@NEW_VERSION
systemctl --user start oab-computer-pw-mcp.service
```

To remove the browser tools:

```sh
systemctl --user disable --now oab-computer-pw-mcp.service
rm ~/.config/systemd/user/oab-computer-pw-mcp.service
rm -r ~/.local/oab-computer/pw-mcp ~/.local/oab-computer/pw-profile   # the profile holds your sign-ins
systemctl --user daemon-reload
```

Then delete the `MCP_UPSTREAM=browser=...` line from `oab-computer.service` and restart that unit.

### Planned: a managed Linux tier

A managed tier that installs a pinned Playwright on demand, like macOS, is designed and accepted but
**not implemented** as of v0.12.0 (no `oab-computer browser` command exists). See
[`adr/linux-browser-tier.md`](adr/linux-browser-tier.md), its
[requirements](requirements/linux-browser-tier.md), and issues
[#119](https://github.com/openabdev/openab-computer/issues/119) and
[#132](https://github.com/openabdev/openab-computer/issues/132).

## What differs by platform

| | macOS only | Linux only | Both |
|---|---|---|---|
| Managed Playwright (wizard and menu install, update, remove, sign-in window) | yes | | |
| The router and the `OAB-Browser-Backend` header | yes | | |
| Profile filtering of upstream tools against the built-in catalog | yes (a tool Playwright adds later stays hidden until the catalog is updated) | | |
| Pass-through of whatever the upstream lists | | yes | |
| `--no-browser` installer option and the 8794 caveat | | yes | |
| External Playwright on loopback 8794 | | | yes, on Linux by default |
| `owner`-only access, persistent profile with cookies | | | yes |

The Linux pass-through is described in [Tool profiles](tool-profiles.md).

## Troubleshooting

- **"Browser tools are not set up"** (macOS): install Playwright from the wizard, or pass
  `--upstream browser=…`. The menu row names the state.
- **macOS refuses to run the downloaded Chromium:** the install stops with that message. The app never
  adds or removes the `com.apple.quarantine` attribute, and the installed-Chrome fallback is not built
  ([#128](https://github.com/openabdev/openab-computer/issues/128)).
- **No `browser_*` tools on Linux:** the upstream is down. Check
  `systemctl --user status oab-computer-pw-mcp.service`; the tools come back when it answers.
- **A site shows a login wall or a captcha:** use the sign-in window (macOS) or the node's desktop
  (Linux) to sign in once. Some sites refuse automated browsers.
