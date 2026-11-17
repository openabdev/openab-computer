# Linux hands node setup

How to turn a Linux desktop box into an `oab-computer` hands node with the Rust PoC in
[`poc/reverse-attach-linux/`](../poc/reverse-attach-linux/). Written from two deployments,
both verified end to end on 2026-09-28 (lending to an openab-pty session, the OpenAB Connect
Screens pane, browser tools):

- Pi node: Raspberry Pi OS / Debian 13, aarch64, the stock labwc desktop (a display exists).
- Headless server: Ubuntu 24.04 Server, Intel N95, **no desktop at all**: a headless sway seat is created
  by the installer (`--headless-seat`).

The browser tools (`browser_*`) come from a **managed** Playwright that the daemon starts and
supervises, in releases after 0.12.0 (see [Browser tools](#4-browser-tools-playwrightmcp)). 0.12.0
and earlier ran Playwright as a separate unit on loopback `8794`; that path is described under
[Old external browser](#old-external-browser-deprecated).

Read the trust warning at the top of the [README](../README.md) first. On Linux it is stricter,
not looser: `bash`, `mouse`, `key`, the background-job tools (`exec_start` and friends, see
[Background jobs](#background-jobs)) and every browser tool are in the `owner` profile, so anyone
who can attach this node under `owner` gets a shell as the user running the daemon. `observe`
(the default for an attach that names no profile) serves only `sys_info` and `screenshot`. Those
are the only two profiles (#59); the retired `desktop` runs as `observe`.

## What you end up with

```mermaid
flowchart LR
    subgraph callers["Callers on the tailnet"]
        cli["Coding CLI or agent"]
        connect["OpenAB Connect Screens pane"]
        pod["openab-pty pod, reverse attach"]
    end

    subgraph node["Linux hands node, one box"]
        ts["tailscale serve port 8444, TLS, adds the caller identity header"]
        subgraph seat["Desktop seat, systemd user units, WAYLAND_DISPLAY wayland-0"]
            mcp["oab-computer.service, 127.0.0.1 port 8795, allow-login AND bearer, serves /mcp /attach /healthz, tools sys_info screenshot bash mouse key exec_start exec_poll exec_list exec_cancel"]
            pw["managed browser, a transient unit the daemon starts on the first browser_* call, stdio only, no port, headed when a seat exists, persistent profile"]
            chrom["Chromium and Node.js, the pinned downloads in your own data directory"]
        end
        subgraph hands["What the tools touch"]
            grim["grim for screenshot"]
            wl["virtual pointer and wtype for mouse and key"]
            sh["bash as the desktop user"]
        end
    end

    cli -- "HTTPS MCP" --> ts
    connect -- "screenshot loop" --> ts
    ts --> mcp
    mcp -- "WebSocket dial out to the pod" --> pod
    mcp -- "stdio pipes, profile filtered" --> pw
    pw --> chrom
    mcp --> hands
```

One systemd **user** unit with linger enabled, binding loopback only; `tailscale serve`
terminates TLS and stamps the caller's Tailscale identity. The browser is a managed child of the
daemon with no listening port of its own, the same shape as macOS
([#119](https://github.com/openabdev/openab-computer/issues/119),
[ADR](adr/linux-browser-tier.md)). The installer writes no browser unit and no `MCP_UPSTREAM` line.
The old `8794` listener, which has no authentication, exists only on a host that still runs an old
browser unit; see [Browser tools](#4-browser-tools-playwrightmcp) and
[Upgrading a host that already has a browser unit](#upgrading-a-host-that-already-has-a-browser-unit).

## Supported systems

Supported: Debian 12 and later, Raspberry Pi OS, and Ubuntu 22.04 and later, on amd64 and arm64,
with glibc 2.28 or newer (the floor measured from the pinned Node.js and Chromium builds; Node.js
needs 2.28 and Chromium 2.25). Other glibc distributions get the generic preflight and are best
effort. Alpine and other musl systems are refused with a clear message.

| System | glibc | amd64 and arm64 | Automated check | Manual run per release |
| --- | --- | --- | --- | --- |
| Debian 12 | 2.36 | supported | not yet (arrives with the release work, L5) | not yet |
| Raspberry Pi OS (Debian 12 based) | 2.36 | supported (arm64) | not yet | not yet |
| Ubuntu 22.04 | 2.35 | supported | not yet | not yet |
| Ubuntu 24.04 | 2.39 | supported | not yet | not yet |
| Debian 13 and newer, newer Ubuntu | 2.41 and newer | supported by the rule above, not listed as run | not yet | not yet |
| Other glibc distributions | 2.28 or newer | best effort | none | none |
| Alpine, other musl systems | n/a | refused | none | none |

"Tested" will mean an automated release smoke, a Debian 12 container job, and a manual full run per
release (ADR D16). None of the three exists yet: until the release work lands, every row says "not
yet", and the table is a statement of intent plus what the preflight checks, not a claim that a
release was run there. `oab-computer browser preflight` checks libc, the glibc floor, user
namespaces, disk and missing libraries on the host in front of you.

## Prerequisites

- A **wlroots compositor** as the seat (labwc, sway, wayfire): the daemon shells out to `grim`
  (screenshot) and `wtype` (keyboard) and holds its own virtual pointer, which need the compositor's
  `wlr-screencopy`, `virtual-pointer` and `virtual-keyboard` protocols. GNOME/Mutter and KDE do
  not expose these. Two ways to have one:
  - a desktop already running on seat0 (Raspberry Pi OS labwc, a sway login) — see
    [Raspberry Pi notes](#raspberry-pi-notes) for the no-monitor case;
  - **none** — pass `--headless-seat` to the installer and it runs `sway` with the headless
    wlroots backend as user unit `oab-seat.service`: one 1920×1080 virtual output, no input
    devices, no GPU or monitor needed (verified on a headless server, Ubuntu 24.04 Server).
- The node on the tailnet with **MagicDNS + HTTPS certificates** enabled (needed for
  `tailscale serve`). Do **not** do this on a k3s node that hosts openab-pty pods: host-level
  `tailscaled` gives every pod tailnet egress as the node (measured, see
  [`docs/adr/reverse-attach.md`](adr/reverse-attach.md)).
- `sudo` for the root actions the installer prints (see [Root actions](#root-actions)). The
  installer itself never runs `sudo`. Rust ≥ 1.85 (`rustup`) is needed only to build from source.

```sh
sudo apt-get install -y grim wtype python3       # + sway for --headless-seat
```

The daemon needs `grim` (screenshots) and `wtype` (keys); the installer needs `tailscale` and
`python3`. Nothing needs `wlrctl`: the daemon never calls it, since it holds its own virtual
pointer, and `install-linux.sh` no longer asks for it
([#130](https://github.com/openabdev/openab-computer/issues/130)). No system `node`, `npm` or
`chromium` is needed either: the managed browser brings its own pinned Node.js and Chromium
(see [Browser tools](#4-browser-tools-playwrightmcp)), so Ubuntu's snap-only Chromium is no
longer a problem.

## 1. Tailscale

```sh
curl -fsSL https://pkgs.tailscale.com/stable/debian/$(. /etc/os-release; echo $VERSION_CODENAME).noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/$(. /etc/os-release; echo $VERSION_CODENAME).tailscale-keyring.list \
  | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
sudo apt-get update && sudo apt-get install -y tailscale
sudo tailscale up --hostname="$(hostname)" --accept-dns=false --accept-routes=false
```

`tailscale up` prints a login URL; approve it in the browser (or pass `--authkey`). If it hangs
with no URL at all, check `curl -4 -m 8 https://controlplane.tailscale.com/` — see
[Gotchas](#gotchas).

## 2. Get the daemon

**Prebuilt (preferred).** Every `v*` release ships `oab-computer-VERSION-linux-arm64.tar.gz`
and `-linux-amd64.tar.gz` (built and smoke-tested in CI on native runners) beside the macOS
installer, with a `.sha256` each:

```sh
V=0.12.0   # the first release with oab-computer-* assets (v0.11.0 and older use the old names)
A=$(dpkg --print-architecture)          # arm64 or amd64
curl -fsSLO "https://github.com/openabdev/openab-computer/releases/download/v$V/oab-computer-$V-linux-$A.tar.gz"
curl -fsSLO "https://github.com/openabdev/openab-computer/releases/download/v$V/oab-computer-$V-linux-$A.tar.gz.sha256"
sha256sum -c "oab-computer-$V-linux-$A.tar.gz.sha256"
tar xzf "oab-computer-$V-linux-$A.tar.gz" && cd "oab-computer-$V-linux-$A"
./install-linux.sh                    # does steps 3 and 5 below, then asks about the browser (step 4)
./install-linux.sh --headless-seat    # same, on a box with no desktop (creates oab-seat.service)
```

`install-linux.sh` is idempotent: it keeps an existing token, detects your Tailscale login and
writes the daemon unit, with no `MCP_UPSTREAM` line and no browser unit. It then does the browser
step, which you can decline (`--browser none`), accept without a question (`--browser managed` or
`--yes`) or leave to the default. On a terminal the default is to show what a browser install
downloads (the output of `oab-computer browser plan`) and ask `[Y/n]`. With no terminal, nothing is
downloaded unless you gave `--browser managed` or `--yes`, and the installer prints the command to
run later (`~/.local/oab-computer/oab-computer browser install`). The installer exits 1 when you
asked for the browser (by flag or by answering yes) and it did not install; the daemon and the
token are then in place. If it did everything, skip to [Verify](#6-verify-from-another-tailnet-machine);
steps 3 to 5 describe what it did. A tarball older than the managed tier has the old behavior; see
[Old external browser](#old-external-browser-deprecated).

### Root actions

The installer does not run `sudo` on its own. It collects each action that needs root, prints the
exact command and why, and runs them only with `--apply-system-changes`, in this order: the
AppArmor profile and missing libraries (before the browser install, so its health check sees them),
then fonts, linger and `tailscale serve` at the end. `scripts/install-linux.sh` is the only entry
point for `--apply-system-changes`; `oab-computer browser ...` never runs a root action and refuses
the flag.

| Action | Command | Why |
| --- | --- | --- |
| Linger | `sudo loginctl enable-linger $USER` | The daemon and the browser keep running after you log out and start again at boot. Printed only when linger is off. |
| Publish | `sudo tailscale serve --bg --https=8444 http://127.0.0.1:8795` | Exposes the daemon on your tailnet over HTTPS (tailnet only). |
| AppArmor | `printf ... \| sudo tee /etc/apparmor.d/oab-computer-chromium` then `sudo apparmor_parser -r ...` | Only where `kernel.apparmor_restrict_unprivileged_userns` is 1 (Ubuntu 24.04): Chromium cannot make its sandbox without it. The profile names your own data path, not `/home/*`, and covers every version directory, so it serves later updates. `oab-computer browser preflight` prints the exact text. |
| Libraries | `sudo apt-get install ...` | Libraries the preflight found missing, with the package names. |
| Fonts | `sudo apt-get install -y fonts-dejavu-core fonts-liberation fonts-noto-cjk fonts-noto-color-emoji` | A server has none and pages render as boxes. Printed only when no font is found. |

`oab-computer browser preflight --root-actions` prints the preflight's own actions, one `command`, a
tab and the reason per line, for scripts.

**From source** (needs Rust ≥ 1.85):

```sh
git clone https://github.com/openabdev/openab-computer ~/repo/oab-computer
cd ~/repo/oab-computer/poc/reverse-attach-linux
cargo build --release              # ~30 s cold on a Pi 4/5; 2.2 MB binary
bash smoke.sh                      # 55 checks against the bundled mock runtime; all must pass
```

`smoke.sh` runs the binary with `MCP_INSECURE_LOCAL=1` against `mock_runtime.py` on loopback.
It does not need the desktop or the network, so run it first when something is off. The same
smoke runs in CI on amd64 and arm64 for every push.

## 3. Bearer token and the daemon unit

```sh
mkdir -p ~/.config/oab-computer
head -c 32 /dev/urandom | base64 | tr -d '=+/\n' | head -c 40 > ~/.config/oab-computer/token
chmod 600 ~/.config/oab-computer/token

LOGIN=$(sudo tailscale status --json | python3 -c \
  'import sys,json;d=json.load(sys.stdin);print(d["User"][str(d["Self"]["UserID"])]["LoginName"])')

mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/oab-computer.service <<EOF
[Unit]
Description=oab-computer (Rust hands node: /mcp + /attach)
After=graphical-session.target

[Service]
ExecStart=%h/.local/oab-computer/oab-computer   # or …/target/release/oab-computer from source
Environment=BIND=127.0.0.1:8795
Environment=MCP_TOKEN_FILE=%h/.config/oab-computer/token
Environment=MCP_ALLOW_LOGIN=$LOGIN
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_RUNTIME_DIR=/run/user/%U
Restart=always
RestartSec=2
# Apps opened via `bash` belong to the desktop, not to this daemon: a restart must not kill them.
KillMode=process

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now oab-computer.service
sudo loginctl enable-linger "$USER"      # keep user units alive without a login shell

curl -s 127.0.0.1:8795/healthz           # ok
curl -s -o /dev/null -w '%{http_code}\n' -X POST 127.0.0.1:8795/mcp -d '{}'   # 401
```

Configured checks are AND-combined, exactly like the Swift daemon: a request must carry the
bearer **and** arrive with an allow-listed `Tailscale-User-Login`. That header is only
trustworthy because `BIND` is loopback and `tailscale serve` overwrites it; never bind to a
LAN or tailnet address. A loopback request without the header is refused (`deny … no
Tailscale-User-Login header` in `journalctl --user -u oab-computer`), which is why even
local `POST /attach` goes through the `https://…:8444` URL below.

The unit has no `MCP_UPSTREAM` line. The managed browser needs none. If one is there (an older
installer wrote it), a managed install wins over it and the daemon logs one
`external_upstream_ignored` event; see
[Upgrading a host that already has a browser unit](#upgrading-a-host-that-already-has-a-browser-unit).

## 4. Browser tools (`@playwright/mcp`)

The daemon serves the 32 `browser_*` tools from a **managed** Playwright MCP: Node.js, the npm
packages and Chromium that `oab-computer browser install` downloads once, pinned by size and SHA-256
into the binary, into your own data directory. The daemon starts it on the first `browser_*` call
as a child talking over stdin and stdout, and stops it with the daemon. It opens no TCP, UDP or Unix
listener and does not use port `8794`. This is the same design as macOS
([Browser tools](browser-tools.md)); this section is what differs on Linux.

```sh
oab-computer browser plan        # what is downloaded, from where, how much, where it goes. Writes nothing
oab-computer browser preflight   # libc, glibc floor, user namespaces, disk, seat, missing libraries
oab-computer browser install     # shows the plan, installs, runs a headless health check
oab-computer browser status      # what is installed, what is running, what is left from before
oab-computer browser update      # prompted, never silent; the old version stays if the check fails
oab-computer browser remove      # deletes what the installer created, and says what it left
oab-computer browser signin      # a window for the one-time login, see Sign in
```

Run these as the user that runs the daemon (`~/.local/oab-computer/oab-computer browser ...`).
`install-linux.sh` runs `plan`, `preflight` and `install` for you.

### What the install downloads

Nothing is bundled in the release tarball and nothing is fetched until you agree. The install
downloads three things into `${XDG_DATA_HOME:-$HOME/.local/share}/oab-computer/playwright/` (not
`~/.local/oab-computer`, which holds the installer's binary), for the architecture of this node:

| What | From | Version |
| --- | --- | --- |
| Node.js (includes `npm`) | `https://nodejs.org/dist/v24.22.3/` | 24.22.3 |
| `@playwright/mcp` and its dependencies (3 npm packages) | `https://registry.npmjs.org/`, fetched by the downloaded Node's `npm ci --ignore-scripts` | 0.0.82 (with `playwright-core` 1.64.0-alpha-1789764292000) |
| Chromium (Chrome for Testing) | `https://storage.googleapis.com/chrome-for-testing-public/154.0.8037.0/` | 154.0.8037.0 |

| | linux-x64 (amd64) | linux-arm64 |
| --- | --- | --- |
| Download | about 259 MB | about 259 MB |
| On disk once installed | about 632 MB | about 629 MB |
| Free space needed while it runs | about 891 MB | about 888 MB |

The free space needed is the larger of three times the download and the download plus the unpacked
size; it is not the on-disk figure, which is what remains afterwards. An internet connection is
needed, unless you install from files (see [Offline install](#offline-install)).

- Every file is checked against sizes and SHA-256 digests built into the binary **before** it is
  extracted. The npm packages are checked against a lockfile built into the binary (`sha512`
  integrity for each package, all from `registry.npmjs.org`). A mismatch installs nothing. Redirects
  to any other host are refused.
- Archives are checked before anything is written (no absolute paths, `..`, links that leave the
  folder, devices, or oversize entries) and are extracted by the binary itself, not by `tar` or
  `unzip`.
- `npm` makes its own connections to `registry.npmjs.org`; the host list does not bound `npm`,
  which is why the lockfile allows no other host.
- Unlike macOS, the downloaded Node.js gets no code-signature check, only the pinned SHA-256.
  There is no quarantine step on Linux.
- The Chromium it installs is a browser: the connections it makes while running are Chromium's,
  not the installer's. On the pinned build it opened no listening TCP or UDP socket, and it exits
  when its stdin closes.
- The install adds no unit and no listener. An update is only ever offered, never applied silently.
- The figures come from the manifest in `release/playwright-pins/`; the release check
  (`scripts/playwright-pins.py`, run in CI) fails if they drift, and a test fails if this page
  stops matching it.

### What `remove` deletes

`oab-computer browser remove` deletes the version folders that carry the installer's marker
(`.oab-owned`), and, only when `install.json` is readable and was written by this installer, also
`install.json`, `pending-cleanup.json`, `pw-config.json`, `profile/` (the browser profile and its
cookies), `output/`, `home/` and `run/`, each only when it carries the installer's marker. Anything
else stays, and `remove` prints `left in place:` for it, including the root directory that holds
the lock file. A hand-made or unreadable `install.json` is never replaced or removed, and with it
the profile and output folders stay. `remove` refuses while a managed browser is running
(`browser_running`). It never touches the old locations: `~/.local/oab-computer/pw-mcp`,
`~/.local/oab-computer/pw-profile`, `~/.local/oab-computer/pw-config.json`,
`~/.cache/ms-playwright`, the old units and drop-ins, or the old AppArmor profile.

### Ports

The managed browser has no listener and does not use `8794`. The daemon listens on
`127.0.0.1:8795`; `tailscale serve` uses `--https=8444`. Chromium needs two private Unix sockets in
the child's own `0700` temporary directory; they are not listeners anyone can reach, but they are
sockets, and the claim "no socket of any kind" is therefore not made. Port `8794` is bound only by
an old browser unit (unauthenticated, loopback) or by whatever you start yourself for
`MCP_BROWSER_BACKEND=external`.

### Where it runs, and what keeps it contained

- **Containment.** The daemon starts the browser as a transient systemd user unit with
  `KillMode=control-group`, bound to the daemon's unit, with an environment rebuilt from an
  allow-list. Stopping the daemon, or killing it with `SIGKILL`, ends every process in the unit,
  detached Chromium helpers included. A host with no user manager or where the self-test fails has
  no managed browser (`unavailable: containment_unverified`) rather than a browser that could
  outlive the daemon. `oab-computer browser status` says which.
- **Headed or headless.** The browser is headed when the seat's Wayland socket exists, else
  headless. `pw-config.json` records the mode and the daemon rewrites it before every start, so an
  edit that drops a flag cannot survive.
- **Passwords and cookies.** The password-store line in the generated table below applies: it is
  obfuscation, not strong encryption.
- **Sites.** Some sites block automated browsers. This page makes no claim about any site.
- **Not set up by the installer.** Chromium's camera, microphone, notification and geolocation
  prompts are not blocked by a policy file any more (writing it needed root, and whether the
  pinned Chromium reads that directory is not established). A prompt that a page raises needs
  `mouse` to dismiss. This is a known limit.
- **Display on a headless seat.** The first headed run on a node with only a headless sway seat is
  the one that has not been verified for this build (Chromium's choice of Wayland or X11 on such a
  seat). If the window does not open, `browser signin` reports `launch_refused` or `spawn_failed`;
  please file an issue with the class.

### Preflight

`oab-computer browser preflight` reports libc, the glibc floor, whether user namespaces are
available, whether the AppArmor restriction is on, disk needed and free, whether a seat exists, and
every shared library the pinned builds need that the loader cache does not list, with package
hints for Debian-family hosts. It never installs a package and never uses root. The library list
covers libraries linked at build time; libraries a program loads at run time are not listed, so the
headless health check at install is the final test. On a blocker it exits 1 and prints one line on
stderr, `browser: preflight_failed class=<class>`, where the class is `musl`, `glibc_too_old`,
`disk_full` or `libraries_missing`.

### Offline install

A node with no route to the download hosts keeps the pinned build:

```sh
./install-linux.sh --browser none
# on a machine that can download, fetch the pinned files into DIR (the names and sizes are in
# `oab-computer browser plan`), copy DIR to the node, then:
~/.local/oab-computer/oab-computer browser install --from-dir DIR
```

The same checks apply (embedded sizes and digests, the lockfile integrity values, `npm ci
--offline`). Neither the download hosts nor the npm registry are contacted, and `plan` and the
install say so. `--from-dir` makes no network preflight. The installed-browser fallback
(`--use-system-chromium`) is not available in this build; it is allowed only after a recorded
sandbox refusal, and a failed libc or architecture check is not one.

### Update, remove, status

`browser update` offers a newer pinned set when the binary carries one, installs it beside the old
one, runs the health check, and keeps the old one if the check fails. Without a terminal it needs
`--yes`. `browser remove` is described above. `browser status` prints the state, the installed and pinned ids, whether an update is available,
the install path, the Chromium revision, any pending cleanup, the containment mode, whether an
external configuration is present (yes or no, no URL), the listener count and the last recorded
refusal, with no URL, token or page data; `--json` emits only fixed fields. `status --retry` clears
the "unavailable after failures" latch and runs the containment check again. A listing of leftovers
from an old setup (old units, old directories with sizes, the old profile that holds cookies) is
not in `status` yet: use the checklist under
[Removing the old browser setup after the soak](#removing-the-old-browser-setup-after-the-soak).

### Flags and environment variables

This table is generated from `poc/reverse-attach-linux/src/docs_table.rs`; CI fails when it is out
of date (`cargo test` in the Linux jobs, and `scripts/test-install-linux.sh` for the installer rows).
To change it, edit that file and run `OAB_UPDATE_DOCS=1 cargo test --release docs_table` in
`poc/reverse-attach-linux`.

<!-- BEGIN GENERATED: linux-flags-env (source: poc/reverse-attach-linux/src/docs_table.rs; rewrite with OAB_UPDATE_DOCS=1 cargo test --release docs_table) -->

| Command | Flag | What it does |
| --- | --- | --- |
| `scripts/install-linux.sh` | `--allow-login LOGIN` | The Tailscale login that may use this node. Default: the login this node is signed in with. |
| `scripts/install-linux.sh` | `--browser MODE` | `managed` downloads and installs the pinned browser (after showing what it downloads and asking, unless `--yes`); `none` skips it. With no terminal and neither `--browser managed` nor `--yes`, nothing is downloaded and the installer prints the command to run later. |
| `scripts/install-linux.sh` | `--no-browser` | Same as `--browser none`. Cannot be combined with `--browser managed` or `--yes`. |
| `scripts/install-linux.sh` | `--yes` | Agrees to the browser download without asking. It runs no root action. |
| `scripts/install-linux.sh` | `--apply-system-changes` | Runs the root actions the installer prints (linger, `tailscale serve`, the AppArmor profile, missing libraries, fonts), each with `sudo`. Without it they are only printed. |
| `scripts/install-linux.sh` | `--headless-seat` | No desktop on this node: install sway and run it headless as the user unit `oab-seat.service`. |
| `scripts/install-linux.sh` | `--port N` | The daemon's loopback port. Default 8795. |
| `scripts/install-linux.sh` | `--serve-port N` | The HTTPS port `tailscale serve` uses. Default 8444. |
| `oab-computer browser plan` | - | Prints what an install downloads, from where, how much, and where it goes. Downloads and writes nothing. |
| `oab-computer browser preflight` | - | Checks this host (libc and its floor, user namespaces, disk, seat, missing libraries). Installs nothing and never uses root. |
| `oab-computer browser preflight` | `--root-actions` | Prints only the root actions, one `command`, a tab and the reason per line. The installer reads this. |
| `oab-computer browser install` | - | Installs the pinned browser from the network. |
| `oab-computer browser install` | `--from-dir DIR` | Installs from files in DIR instead of the network. The same checks apply. |
| `oab-computer browser update` | `--yes` | Updates without asking. Without it a terminal is needed. |
| `oab-computer browser update` | `--from-dir DIR` | Updates from files in DIR. |
| `oab-computer browser remove` | - | Deletes what the installer created and nothing else. It prints what it left. |
| `oab-computer browser status` | `--json` | Prints the state as one JSON object. |
| `oab-computer browser status` | `--retry` | Clears the unavailable latch and runs the containment check again. |
| `oab-computer browser signin` | `--url URL` | Opens a window on the node's seat on the persistent profile, at URL (`http://` or `https://`, default a blank page), and waits for Enter. Run it over `ssh -t`. |
| `oab-computer browser install`, `update`, `remove`, `status` | `--apply-system-changes` | Refused with exit 2. This flag belongs to the installer script. |
| `oab-computer browser install`, `update` | `--use-system-chromium` | Refused with exit 2: not available in this build. |

| Variable | Read by | Meaning |
| --- | --- | --- |
| `BIND` | daemon | Listen address. The unit sets `127.0.0.1:8795`. Anything but loopback is refused unless the token and login checks are on. |
| `MCP_TOKEN` | daemon | The bearer token, inline. Prefer `MCP_TOKEN_FILE`. |
| `MCP_TOKEN_FILE` | daemon | A file that holds the bearer token. The installer writes it with mode 600. |
| `MCP_ALLOW_LOGIN` | daemon | The Tailscale login that may call without the token, by the `Tailscale-User-Login` header that `tailscale serve` adds. |
| `MCP_INSECURE_LOCAL` | daemon | Allows unauthenticated loopback calls. For tests only. |
| `MCP_AUDIT_FILE` | daemon | Where the audit log is written. Default: `$XDG_STATE_HOME` or `~/.local/state`. |
| `MCP_GRANTS_FILE` | daemon | Where lend grants are stored. Same default directory. |
| `MCP_UPSTREAM` | daemon | `name=url` entries of tool servers the daemon forwards to. Every URL must be a literal loopback address, `http://127.0.0.1:PORT` or `http://[::1]:PORT`; any other host stops the daemon with exit 64. The installer no longer writes it. Used only for the old external browser. |
| `MCP_BROWSER_BACKEND` | daemon | `external` is the explicit decision to use the `browser=` entry of `MCP_UPSTREAM` even when a managed install exists. Unset: a managed install wins. |
| `OAB_BROWSER` | daemon | `off` switches the managed tier off. With a managed install the result is no `browser_*` tools at all, and a stale `MCP_UPSTREAM` line is ignored. With nothing installed, a lone `MCP_UPSTREAM browser=` line still serves as external. |
| `WAYLAND_DISPLAY` | daemon, `browser signin` | The seat's socket name. The units set it. `signin` falls back to the highest `wayland-N` socket in `XDG_RUNTIME_DIR`. |
| `XDG_RUNTIME_DIR` | daemon, `browser` | The user's runtime directory (`/run/user/UID`). Needed for the seat, the child's short `TMPDIR` and the containment check. |
| `XDG_DATA_HOME` | `browser` | Where the browser is installed: `$XDG_DATA_HOME/oab-computer/playwright`. Default `~/.local/share`. |
| `XDG_STATE_HOME` | daemon | Base of the audit log, the grants file and the job store. Default `~/.local/state`. |
| `HOME` | daemon, `browser` | The user's home. `~/.local/oab-computer` holds the installer's binary, `~/.config/oab-computer` the token. |
| `DBUS_SESSION_BUS_ADDRESS` | daemon, `browser` | Lets the containment check reach the user manager. |
| `PATH` | daemon, `browser` | Where `systemd-run` and `systemctl` are found. |
| `TERM` | daemon | Set to `xterm-256color` for a terminal job when it is unset. |

The browser always starts with `--password-store=basic`: saved passwords and cookies are protected by obfuscation under a profile directory only you can read, not strong encryption. Anyone who can read your home directory as you can recover them.

<!-- END GENERATED: linux-flags-env -->

### Sign in

A login the browser keeps (a site you want the agent to use) is made once, in a headed window, on
the persistent profile:

```sh
ssh -t <node> '~/.local/oab-computer/oab-computer browser signin'                 # opens about:blank
ssh -t <node> '~/.local/oab-computer/oab-computer browser signin --url https://example.com/login'
```

`signin` needs a terminal (use `ssh -t`), an installed browser and a Wayland seat. It starts the
same pinned browser, headed, as a child of the command (in its own unit with a 30 minute bound, so a
daemon restart does not close it), opens the page, prints `Sign in in the browser window. Press
Enter here when finished.`, and waits. Press Enter, interrupt it, or wait out the bound; the browser
is then closed so it writes its cookies, and everything it started is stopped. If a browser already
holds the profile (the daemon's browser ends 30 minutes after its last call, or restart the daemon),
it reports `profile_locked`. Its failure classes are `terminal_required`, `not_installed`,
`no_seat`, `profile_locked`, `launch_refused`, `spawn_failed` and `invalid_url`; none prints page
data. Killing the command with `kill -9` leaves its unit running until the bound (30 minutes for
sign-in, 5 minutes for an install's health check) or the next sweep, which a later `browser`
command that starts a child runs.

**On a node with a seat you can see** (a desktop on a monitor, or a Raspberry Pi desktop), the
window is on that screen and you use it directly.

**On a headless seat** you drive the window through the daemon's own tools. From a coding CLI with
this node attached, use `screenshot` to see it, `mouse` to click and `key` to type. The caution
that goes with this: a password you type through `key` passes through every system between you and
the node. **Switchboards older than 0.2.2 log tool arguments**, so a typed password would sit in
their audit log. Prefer a login that needs no typed secret, or type it only through a path you
trust.

**Recipe, not installed by this project:** a VNC server for the headless seat. It is a listener
that exposes the whole desktop, which is why the project does not ship or start it. If you choose to
run `wayvnc`, bind it to loopback with authentication, reach it through an SSH port forward, and
stop it afterwards. This recipe is **not tested by this project**. The options below are the ones the
`wayvnc` README names (checked against its README, not run here); check them against the manual of
your version:

```sh
# on the node. ~/.config/wayvnc/config, mode 600 (the password stays in this file, not in a command line):
#   address=127.0.0.1
#   enable_auth=true
#   username=<a user name you choose>
#   password=<a password you choose>
#   rsa_private_key_file=rsa_key.pem    # key from: ssh-keygen -m pem -f ~/.config/wayvnc/rsa_key.pem -t rsa -N ""
WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/$(id -u) wayvnc 127.0.0.1 5900

# on your machine
ssh -N -L 5900:127.0.0.1:5900 <node>     # then point a VNC viewer at 127.0.0.1:5900

# when done, on the node: stop wayvnc, then check that nothing listens on 5900 any more
pkill -x wayvnc
ss -ltn 'sport = :5900'                  # must print no listener line
```

## 5. Expose it

```sh
sudo tailscale serve --bg --https=8444 http://127.0.0.1:8795
sudo tailscale serve status
# https://<host>.<tailnet>.ts.net:8444 (tailnet only)
# |-- / proxy http://127.0.0.1:8795
```

Only the daemon is served on the tailnet. The managed browser has no port. A host that still runs
an old browser unit has a Playwright on loopback `8794` **without authentication**: any local user
can reach it and call every browser tool, including `browser_run_code_unsafe` (arbitrary Node
code). Turn that unit off after the cutover (see
[Upgrading a host that already has a browser unit](#upgrading-a-host-that-already-has-a-browser-unit)).

## 6. Verify from another tailnet machine

```sh
TOKEN=$(ssh <host> cat ~/.config/oab-computer/token)
U=https://<host>.<tailnet>.ts.net:8444
curl -s $U/healthz                                                  # ok
curl -s -o /dev/null -w '%{http_code}\n' -X POST $U/mcp -H 'Authorization: Bearer nope' -d '{}'   # 401
curl -s -X POST $U/mcp -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | python3 -c 'import sys,json;print([t["name"] for t in json.load(sys.stdin)["result"]["tools"]])'
```

Expect the five local tools plus 32 `browser_*` (owner surface; direct `/mcp` is always owner).

**OpenAB Connect Screens pane:** Add a Mac screen with Name `<host>`, URL
`https://<host>.<tailnet>.ts.net:8444/mcp`, Display `0`, the token above, Max FPS `1`. Frames are
JPEG, encoded in the daemon because Debian's `grim` has no libjpeg: about 50 KB for a 1080p
desktop at Connect's quality 0.6, against about 2 MB as PNG.

**Lend to an openab-pty session:**

```mermaid
sequenceDiagram
    participant H as Human, CLI or Connect
    participant N as hands node port 8444
    participant R as openab-pty runtime port 8090
    participant A as agent in the session
    H->>N: POST /attach with runtime, session, profile, ttl_secs, admin_credential
    N->>R: POST /admin/sessions/SESSION/tools-attach with ttl_secs
    R-->>N: secret and expires_in_secs
    N-->>H: 202 grant with id, state idle
    N->>R: WebSocket GET /tools/attach/SESSION with Bearer secret
    R-->>N: 101, state attached
    A->>R: tools/list via OPENAB_TOOLS_MCP_URL
    R->>N: tools/list over the WebSocket
    N-->>R: owner gets 9 local tools and 32 browser tools, observe gets sys_info and screenshot
    A->>R: tools/call screenshot
    R->>N: tools/call screenshot
    N-->>R: image/jpeg
    Note over N,R: close 4010 or DELETE /attach/ID stops it, close 1000 redials with backoff
```

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' $U/attach \
  -d '{"runtime":"ws://<pod-tailnet-ip>:8090","session":"<name>","profile":"owner",
       "ttl_secs":3600,"admin_credential":"<openab-pty admin credential>"}'
# → 202 {"id":"grant-…","profile":"owner","requested_profile":"owner","state":"idle",…}
#   GET $U/attach lists, DELETE $U/attach/<id> revokes
```

`"profile"` is `owner` (full control) or `observe` (look only). A request without it gets
`observe`; up to 0.8.2 it got `owner`. Any other name is a 400
`profile must be one of [owner, observe]`. A request for the retired `desktop` gets `observe`,
and the grant shows `requested_profile: desktop` and a `warning`; a grant stored as `desktop`
resumes as `observe` the same way. See [`tool-profiles.md`](tool-profiles.md#upgrading-from-08x-59).

OpenAB Connect stores the runtime's admin credential in the macOS Keychain (service
`dev.openab.connect`, account = pod name). Inside the session, `$OPENAB_TOOLS_MCP_URL` then
lists, under `owner`, `sys_info screenshot bash mouse key exec_start exec_poll exec_list
exec_cancel` + 32 `browser_*` + the runtime's `instance_status`.

## Operate

```sh
systemctl --user status oab-computer
oab-computer browser status                       # the managed browser: state, containment, display
journalctl --user -u oab-computer -f            # one line per deny / upstream error
systemctl --user restart oab-computer           # grants are in memory: re-lend afterwards
sudo tailscale serve --https=8444 off               # stop exposing
WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u) wlr-randr    # outputs the tools see
```

Grants survive a daemon restart (#12): live grants are kept in
`~/.local/state/oab-computer/grants.json` (mode 600; override with `MCP_GRANTS_FILE`, or
`MCP_GRANTS_FILE=off` to disable), and on start every grant still inside its deadline is re-dialled
under its original id — `journalctl --user -u oab-computer` shows `grants: resuming <id>`. The
file holds the attach secrets, at the same trust level as the bearer token file. A grant whose
runtime has forgotten it (pod replaced) ends with `handshake_rejected_401`; lend again.

A request or stored grant that names the retired `desktop` profile runs as `observe` (#59). Each
such mapping is logged and appended to `~/.local/state/oab-computer/audit.jsonl` (mode 600;
override with `MCP_AUDIT_FILE`, or `MCP_AUDIT_FILE=off` to disable). See
[Upgrading from 0.8.x](tool-profiles.md#upgrading-from-08x-59).

### Background jobs

Under `owner`, `exec_start` / `exec_poll` / `exec_list` / `exec_cancel` run long work without one
long call: same arguments and `structuredContent` as on macOS (README Tools table), with
`bash -c` instead of `zsh -f -c`. On a reverse attach `bash` refuses `timeout_secs` over 100 s
(the runtime fails a call after 120 s), and both that refusal and the `initialize` instructions
point the agent here. Under `observe` neither `bash` nor the job tools exist, and a long `bash`
call is an *unknown tool*, not a refusal that names it.

- **Logs**: `$XDG_STATE_HOME/oab-computer/jobs/<job_id>.out` / `.err` (default
  `~/.local/state/…`; directory mode 700, files 600). The job writes to them directly, so they
  are never truncated and can be followed with `tail -f`. `exec_poll` reads them by byte offset
  (`stdout_since` / `stderr_since` → `stdout_next` / `stderr_next`), at most 1 MiB per stream per
  call.
- **States**: `running` while the shell or anything it left in the job's process group runs
  (`server &`), then `exited` (the shell ended on its own, `exit_code` = its status) or `killed`
  (cancelled, timed out or ended by a signal, `exit_code` = 128 + signal). `timeout_secs` 0, the default, means
  none.
- **Cancel**: `exec_cancel` sends `KILL` (default) or `TERM` to the job's process group (each job
  runs in its own session), children the shell left behind included. The shell is reaped only
  once the group is empty, and the group is signalled only before that, so a recycled pid is never
  hit (#72). Only a process that leaves the group (`setsid` or `setpgid`, as daemonizing code
  usually does) escapes the job and its cancel; a plain double fork stays in the group.
- **Lifetime**: jobs belong to the daemon, not to a connection. When a reverse-attach socket drops,
  its in-flight calls are cancelled, but a job it started keeps running and the next attach can
  poll it. A daemon restart forgets the jobs: their processes keep running (the unit uses
  `KillMode=process`) and their logs stay on disk. Running jobs plus the 10 most recently finished
  are listed; older finished jobs are forgotten. Seven days after a job finishes, its logs are
  deleted and the job is forgotten even if it is among those 10; a running job's logs are kept
  whatever their age. GC runs at start-up and on each `exec_start`.

```sh
ls -lt ~/.local/state/oab-computer/jobs/            # <job_id>.out / .err
tail -f ~/.local/state/oab-computer/jobs/<job_id>.out
```

## Headless server notes (Ubuntu 24.04)

What a box with no desktop needed beyond the Pi, all handled by `install-linux.sh --headless-seat`:

- **Seat**: `sway` with `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman`
  as `oab-seat.service`; `~/.config/sway/config` declares `output HEADLESS-1 1920x1080`. sway
  ignores `WAYLAND_DISPLAY` and takes the first free socket name — usually **`wayland-1`** — so
  the installer reads the socket back from `/run/user/<uid>` and writes that into both units.
- **Chromium**: the pinned Chrome for Testing build that `browser install` downloads (Ubuntu's own
  is a snap, unusable from a user unit). Ubuntu 24.04 restricts unprivileged user namespaces with
  AppArmor and Chromium's sandbox aborts with `No usable sandbox!`; `browser preflight` prints the
  profile that grants `userns` to the Chromium under your own data path (the distro-endorsed fix, the
  sandbox stays on; do not reach for `--no-sandbox`), and `install-linux.sh --apply-system-changes`
  loads it with `sudo`. The launch vector runs headed on the headless seat when its socket exists.
  Whether this build's Chromium picks Wayland on a seat with no Xwayland ("launched a headed
  browser without having a XServer" was the old unit's symptom, fixed there with
  `--ozone-platform=wayland`) is the open display check described under
  [Browser tools](#4-browser-tools-playwrightmcp).
- **Fonts and locale**: a server has neither; the first page rendered as tofu boxes, the second
  in Arabic (no `Accept-Language`, so example.com picked one). The installer prints the
  `fonts-dejavu-core`, `fonts-liberation`, `fonts-noto-cjk`, `fonts-noto-color-emoji` install as a
  root action. The old unit also set `--lang=en-US`, `locale: en-US` and `LANG=en_US.UTF-8`; the
  managed launch vector sets `LANG=C.UTF-8` and no locale option, so the page language follows the
  pages' own defaults.
- **Node from fnm/nvm**: no longer relevant. The managed browser runs its own downloaded Node.js
  and ignores the system `node` and `npm`.
- **Pod-host rule still applies**: The headless server runs k3s (ARC controller, traefik) *and* host
  `tailscaled`. That is fine only because it hosts no openab-pty pods; it must never start to.

## Raspberry Pi notes

- **Raspberry Pi OS's stock desktop is already a headless seat.** With no monitor plugged in,
  labwc keeps a 1920×1080 output alive (`wlr-randr`: `NOOP-1 "Headless output 2"`), the panel and
  file manager run on it, and `grim` captures it. Nothing from the "sway headless" spike (#23)
  is needed. Plug a monitor in and the geometry changes; `sys_info` and the captured frame follow.
  `mouse` keeps the old layout until the virtual pointer reconnects, and while that pointer is live
  `screenshot` reports the same layout for `points` and the `region` clip, so the two agree.
- labwc also runs an Xwayland on `:0`. The old browser unit set `DISPLAY=:0` alongside
  `WAYLAND_DISPLAY`; the managed child gets `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` only.
- The pinned Chromium is an arm64 build; the old unit used the Debian package, which was fast enough for
  `browser_snapshot`-style work (a first page load was ~10 s on a Pi 4, ~1 s warm on example.com).
  The managed build has not been timed on a Pi.
- `~/.cargo/bin` is not on the PATH of non-login shells (`ssh host cargo …` fails with "command
  not found"); use `export PATH=$HOME/.cargo/bin:$PATH` in scripts.
- 8 GB RAM is plenty: daemon ≈ 5 MB, Playwright MCP ≈ 80 MB, headed Chromium 300–600 MB.

## Gotchas

- **Tailscale login never prints a URL** and `curl https://controlplane.tailscale.com/` times out
  while github/8.8.8.8 work: a consumer router (TP-Link Deco here) was dropping the whole
  `192.200.0.0/24` control-plane range for one wifi client, keyed on a months-old association.
  `sudo nmcli con down <profile>; sudo nmcli con up <profile>` fixed it instantly; no reboot.
- **`nmcli` needs sudo** on Raspberry Pi OS ("Not authorized to control networking").
- **Anything that talks to the seat needs `WAYLAND_DISPLAY` + `XDG_RUNTIME_DIR`.** An
  ssh-started or systemd-started process has neither; the daemon defaults them to `wayland-0` /
  `/run/user/<uid>` when unset, the units set them explicitly, and `browser signin` over `ssh`
  looks for the highest `wayland-N` socket in your runtime directory.
- **`grim -t jpeg` → "jpeg support disabled"** on Debian's build. The daemon never asks grim
  for JPEG: it takes raw PPM from grim and encodes the JPEG itself.
- **A seat with no physical input silently drops transient virtual devices.** Headless sway
  and a Pi with no mouse advertise no pointer/keyboard capability, so a one-shot `wtype` call (or any short-lived virtual pointer) that
  creates a device, sends and exits within milliseconds is lost: Chromium never binds
  `wl_pointer`/`wl_keyboard` in time, yet the tool exits 0 and `mouse`/`key` report `ok: true`.
  The daemon therefore holds a **persistent** virtual pointer (its own Wayland connection, absolute
  motion over the output layout) and a long-lived `wtype -s` keyboard anchor from startup; the
  journal logs `seat: virtual pointer up` / `virtual keyboard anchor up`, and
  `swaymsg -t get_seats` shows `capabilities 3`. `wtype -s` overflows a C `int` above ~35 min and
  exits at once, so the anchor sleeps 30 min and is respawned.
- **Chromium's `ctrl+l` focuses the omnibox but typed text may append** rather than replace; send
  `ctrl+a` before typing a URL.
- **Playwright `--allowed-hosts` needs the `host:port` form** or every request is 403. This
  concerns only the old external listener; the managed child has no host check to pass.
- **A stale upstream `Mcp-Session-Id` must be dropped before re-`initialize`**, or the upstream
  404s the initialize too and the browser tools never come back after a Playwright restart.
  Fixed in the daemon; symptom was `tools/list` shrinking to the five local tools. External path
  only.
- **The daemon's `/attach` refuses loopback callers** without `Tailscale-User-Login` by design;
  use the `tailscale serve` URL even from the node itself.
- **`pkill -f` inside `ssh host 'sh -c …'` kills the `sh -c`** whose command line matches.
  Use `pkill -x <name>` — but `-x` matches at most 15 characters of the process name, so
  `pkill -x oab-computer` silently matches nothing.
- **Chromium `No usable sandbox!` / `Trace/breakpoint trap`** on Ubuntu 24.04+: AppArmor
  userns restriction; see [Headless server notes](#headless-server-notes-ubuntu-2404). The
  managed browser reports it as `sandbox_unavailable` and does not retry.
- **Headed browser "without having a XServer"** on a headless seat: Chromium picked X11. The old
  unit's `pw-config.json` added `--ozone-platform=wayland`; the managed launch vector does not, and
  whether it needs to is the open display check in [Browser tools](#4-browser-tools-playwrightmcp).

## Upgrading from 0.11

0.12.0 renamed the units to `oab-computer.service` and `oab-computer-pw-mcp.service`. The
installer only warns about the old ones. The old `oab-instance-mcp.service` holds port 8795, so
stop it before the new unit can bind:

```sh
systemctl --user disable --now oab-instance-mcp.service
systemctl --user restart oab-computer.service
```

An old browser unit (`oab-pw-mcp.service`) is handled as described in the next section. Full
steps, with backup and rollback: [Upgrading from 0.11 or earlier](upgrade-0.12.md). The README has
the table of old and new names:
[Upgrading from 0.11 or earlier](../README.md#upgrading-from-011-or-earlier).

## Upgrading a host that already has a browser unit

The installer never stops, disables, edits or deletes an old browser unit, a drop-in, an old
directory, an old profile or an old AppArmor profile, and never copies cookies. The managed browser
starts with a fresh profile, so a migrated host signs in again (`browser signin`); the old profile
stays where it is and holds the old cookies until you delete it. The cutover itself is a procedure
for a person
([requirements, section 2](requirements/linux-browser-tier.md#2-cutover-runbook)). What the
installer does on each kind of host:

| Host | What the installer does | What you do at cutover |
| --- | --- | --- |
| New: nothing from before | Writes the daemon unit without `MCP_UPSTREAM`, asks about the browser. | Nothing. |
| New-style unit: `oab-computer-pw-mcp.service` from 0.12.0, and an `MCP_UPSTREAM` line inside `oab-computer.service` | Warns, with the exact command to turn the unit off. Leaves `oab-computer.service` byte for byte as it is when it still has the `MCP_UPSTREAM` line (it rewrites it otherwise), and still replaces the binary and restarts the daemon. | After `browser status` shows the managed browser working: `systemctl --user disable --now oab-computer-pw-mcp.service`, then remove the `MCP_UPSTREAM` line (back it up first), `daemon-reload`, restart. |
| Old-style unit: `oab-pw-mcp.service` and an `MCP_UPSTREAM` drop-in under `oab-computer.service.d/` or `oab-instance-mcp.service.d/` | Warns the same way for `oab-pw-mcp.service`, names the drop-in file, writes `oab-computer.service` without the line and leaves the drop-in alone. | `systemctl --user disable --now oab-pw-mcp.service`, then remove the drop-in file (back it up first), `daemon-reload`, restart. |

A plain `systemctl stop` is not enough: those units come back at the next login or boot, and each
is an unauthenticated Playwright on loopback `8794`. While the old unit and its line exist, a
managed install still wins over them: the daemon uses the managed browser and logs one
`external_upstream_ignored` event, and `sys_info` shows it. With **nothing** installed, a lone
`MCP_UPSTREAM=browser=...` line still serves as the external browser, as before. To use the old
external unit on purpose after a managed install, set `MCP_BROWSER_BACKEND=external` (that is the
explicit decision to trust it). `OAB_BROWSER=off` switches the managed tier off. With a managed install that
means no `browser_*` tools at all, and a stale line is ignored; it is not a way back to the external
path. With nothing installed, a lone `MCP_UPSTREAM browser=` line still serves as external even with
`OAB_BROWSER=off`. Every `name=url`
entry of `MCP_UPSTREAM` must be a literal loopback `http://127.0.0.1:PORT` or `http://[::1]:PORT`
URL; any other host stops the daemon with exit 64.

## Removing the old browser setup after the soak

Only a person does this, after the managed browser has run for about a week without trouble. The
installer never deletes any of it. Take the old paths from your inventory of the host; each command
below is marked if it needs root.

1. Disable the old unit if you have not yet, then delete its file and the drop-in, and reload.
   No root:

   ```sh
   systemctl --user disable --now oab-pw-mcp.service oab-computer-pw-mcp.service   # whichever you had
   rm ~/.config/systemd/user/oab-pw-mcp.service ~/.config/systemd/user/oab-computer-pw-mcp.service
   rm ~/.config/systemd/user/oab-computer.service.d/*upstream*.conf       # the MCP_UPSTREAM drop-in, if any
   systemctl --user daemon-reload
   ```

2. Delete the old directories, after looking inside: the old profile holds cookies. No root:

   ```sh
   du -sh ~/.local/oab-computer/pw-mcp ~/.local/oab-computer/pw-profile ~/.local/oab-instance-mcp/pw-mcp
   rm -r ~/.local/oab-computer/pw-mcp ~/.local/oab-computer/pw-profile ~/.local/oab-computer/pw-config.json ~/.local/oab-computer/pw-mcp.sh
   rm -r ~/.cache/ms-playwright    # only if nothing else of yours uses Playwright's cache
   ```

3. Delete the old AppArmor profile that allowed `/home/*/.cache/ms-playwright/...`. **Root:**

   ```sh
   sudo rm /etc/apparmor.d/playwright-chromium && sudo apparmor_parser -R /etc/apparmor.d/playwright-chromium
   ```

   The profile for the managed browser is a different file, `/etc/apparmor.d/oab-computer-chromium`,
   and stays.

4. Delete the old Chromium policy file the old installer wrote. **Root:**
   `sudo rm /etc/chromium/policies/managed/oab-computer.json`.

## Old external browser (deprecated)

0.12.0 and earlier started Playwright as a separate unit, `oab-computer-pw-mcp.service`, on
`127.0.0.1:8794`, with `MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp` in the daemon unit, started
by `poc/reverse-attach-linux/pw-mcp.sh` (kept in the tarball one more release, marked deprecated, so
that a binary rollback has a script to restore). That path has no authentication on the listener
and no pinned downloads; it is only for a host that has not moved, or for
`MCP_BROWSER_BACKEND=external`. Its pieces: `PW_CHROMIUM` and `PW_NODE_BIN` (the script's own
environment, default `/usr/bin/chromium`), a persistent profile under
`~/.local/oab-computer/pw-profile`, and `--allowed-hosts` in both `host` and `host:port` forms.
Nothing here is written by the current installer.
