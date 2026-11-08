# Reference architecture: instance-mcp on an Oracle Cloud Ubuntu VM

> Agent-friendly prompt block (copy-paste to set up a new VM)
>
> ```
> Set up instance-mcp 0.8.0 on an Oracle Cloud Ubuntu 24.04 arm64 VM as a Tailscale node.
> Follow docs/oracle-cloud-refarch.md sections 2 and 3 in order, then verify with section 4 from
> another tailnet machine. Run the daemon as a dedicated user with no sudo, bound to
> 127.0.0.1:8795, behind `tailscale serve --https=8444`. Never print or paste the bearer token.
> ```

**Status.** Written from the live VM `oracle-vm`, checked with read-only commands and one
handshake over the tailnet. Where the VM differs from the earlier investigation, this page
describes the VM. Section 9 lists the differences.

**Placeholders.**

| Placeholder | Meaning |
|---|---|
| `<tailnet-login>` | The Tailscale login (an email) allowed to call the daemon |
| `<token-file>` | `/home/oabmcp/.config/oab-instance-mcp/token` |
| `<node>.<tailnet>.ts.net` | The node's MagicDNS name on the reference tailnet. Use your own. |

Commands below run as the admin account (`ubuntu` on the reference VM) unless the step says
`oabmcp`. Run the daemon as `oabmcp`, never as `ubuntu`. Shell functions and `$(…)` in these
commands work in bash and zsh.

---

## 1. Architecture

An Oracle Cloud Ampere A1 VM runs `oab-instance-mcp` as a hands node. OpenAB Connect registers the
node by URL and bearer token. Connect then lends the node to a live openab-pty session. The node
dials back into that session's runtime, and the agent in the session calls the lent tools.

```
 OpenAB Connect (Mac)                  tailnet                    Oracle A1 VM (oracle-vm)
 ────────────────────                                             ─────────────────────────────────────────────
 computer entry ── HTTPS /mcp ──► tailscale serve :8444 ──► 127.0.0.1:8795  oab-instance-mcp   (user oabmcp)
 lend sheet ────── POST /attach ─►                                 │  /mcp  /attach  /healthz
                                                                   │  browser_* ─► 127.0.0.1:8794  @playwright/mcp 0.0.82
                                                                   │                └─► Chromium, headed, Wayland (seat wayland-1)
                                                                   │  sys_info · screenshot · bash · mouse · key
                                                                   │
                                                                   └─ WebSocket, dialled out ─► openab-pty pod :8090 /tools/attach/<session>
```

| Part | Role | Where it runs |
|---|---|---|
| `oab-instance-mcp` 0.8.0 | Serves `/mcp` and `/attach`, checks the bearer token and login, filters tools by profile | `~oabmcp/.local/oab-instance-mcp/` |
| `tailscale serve` | Terminates TLS on the tailnet address and sets the `Tailscale-User-Login` header | root-managed, port 8444 |
| Headless sway | Gives screenshot, mouse and key tools a Wayland output with no monitor attached | `oab-seat.service` |
| `@playwright/mcp` 0.0.82 | Browser tools. Bound to loopback. The daemon re-serves them through `MCP_UPSTREAM`. | `oab-pw-mcp.service` |

**Why Discord bots cannot use this node.** Connect gives a computer to an agent through one path:
`POST /attach` on the computer, which makes the computer dial an openab-pty runtime. The agent
that receives the tools is an openab-pty session. An openab bot has no configuration path to an
external MCP URL. Its `[mcp]` table configures the bot's own in-process facade, not a list of
external servers. A Discord bot therefore has no way to call this node, whether or not it runs on
the same host. In the investigation (2026-10), the colocated bot code was still on an unmerged
branch.

**Why a tailnet node and not a k3s node.** Host-level Tailscale on a Kubernetes node gives every
pod on that node tailnet access as the node. This VM runs no pods, so that path does not exist
here.

---

## 2. Prerequisites

### 2.1 Oracle instance

| Item | Reference VM (observed) |
|---|---|
| Shape | Ampere A1 Flex, `aarch64`, CPU model Neoverse-N1 |
| vCPU and RAM | 2 vCPU, 12 GB |
| Boot disk | 48 GB, 43 GB free after setup |
| OS | Ubuntu 24.04.5 LTS, Oracle kernel `6.17` |
| Public ingress | None needed. The daemon and serve listen on the tailnet only. |

Use an Ubuntu 24.04 image. The v0.8.0 arm64 binary needs glibc 2.39, which Ubuntu 24.04 provides.

### 2.2 Tailscale

1. Install Tailscale (see `docs/linux-setup.md`, section 1). The reference VM runs `tailscale` 1.104.4.
2. Join the tailnet with a hostname you will recognize. The reference node is `oracle-vm`.
3. In the admin console, enable **MagicDNS** and **HTTPS Certificates**. Without HTTPS
   certificates, `tailscale serve --https` fails.
4. Prerequisite, not done: tag the node in the admin console before you rely on `owner` over the
   tailnet. The reference node has no tag yet. See section 5.4, item 3.

### 2.3 Accounts

| Account | Used for |
|---|---|
| Admin account with `sudo` (`ubuntu` on the reference VM) | Package installs, `tailscale serve`, linger, AppArmor, Chromium policy |
| `oabmcp` (created in 3.2) | Runs the daemon, the seat, and the browser. Has no `sudo`, no `lxd`, no `docker`. |
| `<tailnet-login>` | The human login that Connect uses. Must match `MCP_ALLOW_LOGIN`. |

---

## 3. Setup, step by step

### 3.1 Base packages (admin account)

```sh
sudo apt-get update && sudo apt-get upgrade -y         # optional housekeeping
sudo apt-get install -y sway grim wtype python3 \
  fonts-dejavu-core fonts-liberation fonts-noto-cjk fonts-noto-color-emoji
```

- `sway` 1.9 comes from the Ubuntu 24.04 archive. It runs the headless seat in 3.5.
- `grim` takes screenshots. `wtype` sends keys.
- Fonts stop pages from rendering as empty boxes.
- `wlrctl` is not installed on the reference VM. The hand-written units in this page do not need
  it. The installer does (section 7.7).

### 3.2 Service user (admin account)

```sh
sudo useradd --create-home --shell /bin/bash oabmcp
sudo loginctl enable-linger oabmcp                     # user units keep running after logout
test -e /var/lib/systemd/linger/oabmcp && echo "linger on"
sudo -l -U oabmcp 2>&1 | grep -q 'not allowed' && echo "no sudo, as intended"
```

Do not add `oabmcp` to the `sudo`, `lxd` or `docker` groups.

### 3.3 Node.js (admin account)

The reference VM runs **Node.js v26.13.0**, extracted to `/opt/node-v26.13.0-linux-arm64` and linked
into `/usr/local/bin`. Node 26 is the release line on that VM. This page did not check the LTS
status of 26 against the Node.js release schedule. Confirm the line you want before you copy
these commands.

```sh
V=26.13.0
cd /tmp
curl -fsSLO https://nodejs.org/dist/v$V/node-v$V-linux-arm64.tar.xz
curl -fsSLO https://nodejs.org/dist/v$V/SHASUMS256.txt
grep " node-v$V-linux-arm64.tar.xz\$" SHASUMS256.txt | sha256sum -c -
sudo tar -xJf node-v$V-linux-arm64.tar.xz -C /opt
for b in node npm npx; do sudo ln -sfn /opt/node-v$V-linux-arm64/bin/$b /usr/local/bin/$b; done
node --version
```

The service user only reads this tree. The reference VM's copy is owned by `ubuntu`, which also works.

### 3.4 Daemon binary (admin account, then the service user)

The v0.8.0 release contains `oab-instance-mcp-0.8.0-linux-arm64.tar.gz` and a `.sha256`. Checksums
from the reference VM, for comparison:

| File | SHA-256 |
|---|---|
| `oab-instance-mcp-0.8.0-linux-arm64.tar.gz` | `2426da2b317ad0e2b062cf90b2a050f0b93e1d01d84ba295804237bdebc7c626` |
| `oab-instance-mcp` (extracted binary) | `19875c16400260710838e7732ac1a61bf1d39d6dd125c2c11c1665e98aa74e19` |
| `pw-mcp.sh` (extracted) | `f9d4eed61880647a4f4ced2db01df59eda3cd4ca394a7bedd390af563ff21be6` |

```sh
V=0.8.0
cd /tmp
curl -fsSLO https://github.com/openabdev/instance-mcp/releases/download/v$V/oab-instance-mcp-$V-linux-arm64.tar.gz
curl -fsSLO https://github.com/openabdev/instance-mcp/releases/download/v$V/oab-instance-mcp-$V-linux-arm64.tar.gz.sha256
sha256sum -c oab-instance-mcp-$V-linux-arm64.tar.gz.sha256
tar -xzf oab-instance-mcp-$V-linux-arm64.tar.gz

sudo -u oabmcp install -D -m 755 oab-instance-mcp-$V-linux-arm64/oab-instance-mcp \
  /home/oabmcp/.local/oab-instance-mcp/oab-instance-mcp
sudo -u oabmcp install -D -m 755 oab-instance-mcp-$V-linux-arm64/pw-mcp.sh \
  /home/oabmcp/.local/oab-instance-mcp/pw-mcp.sh
```

The reference VM has no `gh`, so the commands above fetch the two release assets with `curl`.

### 3.5 Headless seat (service user)

The seat is a headless sway with one virtual 1920×1080 output and no input devices. `grim`, `wtype`
and the daemon's virtual pointer use its Wayland socket.

Write the files in 3.5 and 3.8 as `oabmcp`, so they keep that owner. For example:
`sudo -u oabmcp mkdir -p /home/oabmcp/.config/sway /home/oabmcp/.config/systemd/user`, then
`sudo -u oabmcp tee /home/oabmcp/.config/sway/config >/dev/null`, with the config as its input.

`~oabmcp/.config/sway/config`:

```
# Headless seat for the oab-instance-mcp hands node: one virtual 1080p output, no input devices.
output HEADLESS-1 resolution 1920x1080 position 0,0
default_border none
focus_follows_mouse no
```

`~oabmcp/.config/systemd/user/oab-seat.service`:

```ini
[Unit]
Description=Headless sway seat for the oab-instance-mcp hands node

[Service]
Environment=WLR_BACKENDS=headless
Environment=WLR_LIBINPUT_NO_DEVICES=1
Environment=WLR_RENDERER=pixman
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=XDG_SESSION_TYPE=wayland
ExecStart=/usr/bin/sway
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

Define a helper once in your admin shell. It runs `systemctl --user` as `oabmcp` with the right
runtime directory:

```sh
ouser() { sudo -u oabmcp env XDG_RUNTIME_DIR=/run/user/$(id -u oabmcp) "$@"; }
ouser systemctl --user daemon-reload
ouser systemctl --user enable --now oab-seat.service
ouser ls /run/user/$(id -u oabmcp)           # expect wayland-1
```

sway picks the first free socket name, which is `wayland-1` on the reference VM. The units in 3.8
hard-code `wayland-1`. If your socket name differs, change it in both units.

### 3.6 Browser tools: Playwright, Chromium, AppArmor (mixed)

`@playwright/mcp` is pinned to **0.0.82**. The browser is Playwright's own Chromium build,
`chromium-1246`. Ubuntu ships Chromium only as a snap, and a snap cannot run from a user unit.

**Playwright and Chromium (service user):**

```sh
sudo -u oabmcp bash -c '
  export PATH=/opt/node-v26.13.0-linux-arm64/bin:$PATH
  mkdir -p /home/oabmcp/.local/oab-instance-mcp/pw-mcp && cd /home/oabmcp/.local/oab-instance-mcp/pw-mcp
  npm install --save-exact @playwright/mcp@0.0.82
  npx playwright install chromium
'
```

The reference VM stores the browser at `~oabmcp/.cache/ms-playwright/chromium-1246/`.

**Wrapper config (service user).** `~oabmcp/.local/oab-instance-mcp/pw-config.json`:

```json
{ "browser": { "launchOptions": { "args": ["--ozone-platform=wayland", "--lang=en-US"] },
               "contextOptions": { "locale": "en-US" } } }
```

`--ozone-platform=wayland` is required. The headless seat has no Xwayland, so without it Chromium
fails with "launched a headed browser without having a XServer".

**AppArmor for Chromium's sandbox (admin account).** Ubuntu 24.04 restricts unprivileged user
namespaces. Without this profile, Chromium aborts with `No usable sandbox!`. The profile allows
`userns` for the Playwright Chromium binary only, and the sandbox stays on.

`/etc/apparmor.d/playwright-chromium`:

```
abi <abi/4.0>,
include <tunables/global>
profile playwright-chromium /home/*/.cache/ms-playwright/chromium-*/chrome-linux*/chrome flags=(unconfined) {
  userns,
  include if exists <local/playwright-chromium>
}
```

```sh
sudo apparmor_parser -r /etc/apparmor.d/playwright-chromium
```

**Chromium policy (admin account, optional but recommended).** Without it, a site that asks for
camera, microphone, notification or location access can leave a prompt that no tool can dismiss.
The reference VM does not have this policy yet (section 9).

```sh
sudo mkdir -p /etc/chromium/policies/managed
echo '{"DefaultMediaStreamSetting": 2, "DefaultNotificationsSetting": 2, "DefaultGeolocationSetting": 2}' \
  | sudo tee /etc/chromium/policies/managed/oab-instance-mcp.json >/dev/null
```

The wrapper `pw-mcp.sh` reads `PW_CHROMIUM` for the browser path and `PW_NODE_BIN` for the Node
directory. It launches Chromium headed, with a persistent profile at
`~oabmcp/.local/oab-instance-mcp/pw-profile`.

### 3.7 Bearer token (service user)

The file is mode 600. Do not print it.

```sh
sudo -u oabmcp bash -c '
  umask 077
  mkdir -p /home/oabmcp/.config/oab-instance-mcp
  head -c 32 /dev/urandom | base64 | tr -d "=+/\n" > /home/oabmcp/.config/oab-instance-mcp/token
  chmod 600 /home/oabmcp/.config/oab-instance-mcp/token
'
```

### 3.8 User units (service user)

Two units, under `~oabmcp/.config/systemd/user/`, written as `oabmcp` as in 3.5. Replace
`<token-file>` and `<tailnet-login>` with real values before you save. `<token-file>` becomes
`/home/oabmcp/.config/oab-instance-mcp/token`.

```sh
sudo -u oabmcp mkdir -p /home/oabmcp/.config/systemd/user
```

`oab-pw-mcp.service`:

```ini
[Unit]
Description=Playwright MCP for the oab-instance-mcp hands node (loopback :8794)
After=graphical-session.target oab-seat.service

[Service]
ExecStart=/home/oabmcp/.local/oab-instance-mcp/pw-mcp.sh
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-1
Environment=DISPLAY=:0
Environment=PW_CHROMIUM=/home/oabmcp/.cache/ms-playwright/chromium-1246/chrome-linux-arm64/chrome
Environment=PW_NODE_BIN=/opt/node-v26.13.0-linux-arm64/bin
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
```

`oab-instance-mcp.service`:

```ini
[Unit]
Description=oab-instance-mcp (Linux hands node: /mcp + /attach)
After=graphical-session.target

[Service]
ExecStart=/home/oabmcp/.local/oab-instance-mcp/oab-instance-mcp
Environment=BIND=127.0.0.1:8795
Environment=MCP_TOKEN_FILE=<token-file>
Environment=MCP_ALLOW_LOGIN=<tailnet-login>
Environment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp
Environment=WAYLAND_DISPLAY=wayland-1
Environment=XDG_RUNTIME_DIR=/run/user/%U
Restart=always
RestartSec=2
# Apps opened via bash belong to the desktop, not to this daemon: a restart must not kill them.
KillMode=process

[Install]
WantedBy=default.target
```

Notes:

- `BIND` stays on `127.0.0.1`. Never bind to a tailnet or LAN address. The login check trusts a
  header that only `tailscale serve` sets, and it trusts it only from loopback.
- `MCP_ALLOW_LOGIN` is the login allowed to call the daemon. Read the full login with
  `tailscale status --json`. Plain `tailscale status` truncates it. The login is the `LoginName` of the
  user whose `ID` equals `Self.UserID`:

  ```sh
  tailscale status --json | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["User"][str(s["Self"]["UserID"])]["LoginName"])'
  ```

- `MCP_UPSTREAM` routes `browser_*` calls to the Playwright unit. If that unit is down, the browser
  tools disappear and the local tools keep working.

Start the units, then check that they are active and that the daemon answers on loopback:

```sh
ouser systemctl --user daemon-reload
ouser systemctl --user enable --now oab-pw-mcp.service oab-instance-mcp.service
ouser systemctl --user is-active oab-seat oab-pw-mcp oab-instance-mcp   # three lines: active
curl -s -o /dev/null -w '%{http_code}\n' 127.0.0.1:8795/healthz         # 200
```

### 3.9 Expose through Tailscale serve (admin account)

Run this after 3.8, once the daemon answers on `127.0.0.1:8795`:

```sh
sudo tailscale serve --bg --https=8444 http://127.0.0.1:8795
sudo tailscale serve status
```

Expected output on the reference VM:

```
https://<node>.<tailnet>.ts.net:8444 (tailnet only)
|-- / proxy http://127.0.0.1:8795
```

Serve listens on the tailnet address only. The serve config survives daemon restarts.

---

## 4. Verification

### 4.1 Health through serve

Run from another tailnet machine. The node cannot probe its own MagicDNS name (section 7.7).

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://<node>.<tailnet>.ts.net:8444/healthz   # 200
```

### 4.2 A 401 on loopback is expected

```sh
ssh ubuntu@<node>.<tailnet>.ts.net \
  'curl -s -o /dev/null -w "%{http_code}\n" -X POST 127.0.0.1:8795/mcp \
     -H "Authorization: Bearer $(sudo cat <token-file>)" \
     -H "Content-Type: application/json" -d "{}"'
# 401
```

The daemon requires both the bearer token and a `Tailscale-User-Login` header. Only
`tailscale serve` sets that header. A direct request to `127.0.0.1:8795` has no header, so it
gets a 401 even with the correct token. The 401 means the login check is working. The correct
check goes through the serve URL (4.3).

### 4.3 Handshake over the tailnet

Run from a tailnet machine logged in as `<tailnet-login>`. The token goes into a shell variable.
Nothing prints it.

```sh
U=https://<node>.<tailnet>.ts.net:8444
TOKEN=$(ssh ubuntu@<node>.<tailnet>.ts.net 'sudo cat <token-file>')
AUTH="Authorization: Bearer $TOKEN"
JSON='Content-Type: application/json'
ACCEPT='Accept: application/json, text/event-stream'
PROTO='MCP-Protocol-Version: 2025-06-18'

# 1. initialize. The response carries an Mcp-Session-Id header.
curl -s -D /tmp/mcp-headers.txt -o /dev/null -w '%{http_code}\n' -X POST $U/mcp \
  -H "$AUTH" -H "$JSON" -H "$ACCEPT" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"refarch-check","version":"0"}}}'
SID=$(grep -i '^mcp-session-id' /tmp/mcp-headers.txt | tr -d '\r' | awk '{print $2}')

# 2. notifications/initialized. Expect 202.
curl -s -o /dev/null -w '%{http_code}\n' -X POST $U/mcp \
  -H "$AUTH" -H "$JSON" -H "$ACCEPT" -H "Mcp-Session-Id: $SID" -H "$PROTO" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# 3. tools/list
curl -s -X POST $U/mcp \
  -H "$AUTH" -H "$JSON" -H "$ACCEPT" -H "Mcp-Session-Id: $SID" -H "$PROTO" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

unset TOKEN AUTH SID
rm -f /tmp/mcp-headers.txt
```

Expected on the reference VM: `initialize` returns 200, the notification returns 202, and
`tools/list` returns 37 tools. Direct `/mcp` always answers as `owner`, so the list is the owner
surface: 5 local tools (`sys_info`, `screenshot`, `bash`, `mouse`, `key`) and 32 `browser_*` tools.

### 4.4 Observe profile

Direct `/mcp` always uses `owner`. A session's profile is set at lend time, so `observe` can only be
tested by lending the node to a test session. Expected: `sys_info` and `screenshot`, and no browser
tools. Use a test session, not one doing real work.

---

## 5. Profiles and security

### 5.1 What each profile exposes

Source: `poc/reverse-attach-linux/src/mcp.rs` (`OBSERVE_TOOLS`, `upstream_tool_allowed`). The owner counts were checked live.

These are the two profiles the code has since [#59](https://github.com/openabdev/openab-computer/issues/59).

| Profile | Local tools | Browser tools | Shell-equivalent? |
|---|---|---|---|
| `owner` | `sys_info`, `screenshot`, `bash`, `mouse`, `key`, `exec_start`, `exec_poll`, `exec_list`, `exec_cancel` | all 32, including `browser_evaluate` and `browser_run_code_unsafe` | **Yes** |
| `observe` | `sys_info`, `screenshot` | none | No |

`owner` is the only profile with `bash`, `mouse`, `key` and the browser tools. `bash` runs as
`oabmcp`, and `mouse` and `key` can open a terminal or type into one. `observe` is the only real
boundary. Treat `owner` as shell-equivalent.

### 5.2 The browser is not isolated

The browser (`@playwright/mcp`, run as `oabmcp`) belongs to `owner`. It is not isolated from the
node. Through the browser, an `owner` session can reach:

- loopback services on the VM, including the daemon on `127.0.0.1:8795`,
- tailnet hosts that the VM can reach,
- `file://` paths that `oabmcp` can read, including the bearer token file and the grants file.

We accept this and treat the browser as owner-level access, which is shell-equivalent. It is not a
sandbox. The open issue is
[openabdev/instance-mcp#45](https://github.com/openabdev/instance-mcp/issues/45): the sandbox profile
is not a boundary, because GUI control is a shell. Until that issue is fixed, a session that reads
untrusted pages, issues or email must not get `owner`, because a page can steer the browser into
any of the paths above.

### 5.3 What `oabmcp` can read

The service user has no `sudo`, but a `bash` call under `owner` runs as that user and can
read everything it owns:

- the bearer token (`<token-file>`),
- live grants (`~oabmcp/.local/state/oab-instance-mcp/grants.json`, which holds attach secrets),
- the Playwright profile (`~oabmcp/.local/oab-instance-mcp/pw-profile`, which holds cookies and
  logins for every site the browser opened).

Lend `owner` only to sessions you trust. Never lend it to a session that reads untrusted pages,
issues or email.

### 5.4 Recommendations

1. **Default to `observe`** for any session that reads untrusted content.
2. **Keep the service user unprivileged.** No `sudo`, `lxd` or `docker`.
3. **Prerequisite, not done: restrict the tailnet ACL.** The reference node is owned by a personal
   login and has no tag. Before you rely on `owner` over the tailnet, tag the node (for example
   `tag:oab-hands`, a suggested name) and write an ACL that lets only the openab-pty sidecars and
   the Connect Mac that registers the node reach port 8444. The ACL limits who can call the node.
   It does not limit what the browser reaches from the VM (5.2). The investigation did not review
   the tailnet ACL, so review it before you rely on this.
4. **Keep the bearer token and `MCP_ALLOW_LOGIN` set.** Never run the daemon with
   `MCP_INSECURE_LOCAL`.
5. **Do not run the daemon as `ubuntu`.** That account has passwordless `sudo` and `lxd` membership,
   which is root-equivalent.

---

## 6. Connect setup

**Add the computer.** In OpenAB Connect, open the sidebar and choose **Add a computer
(instance-mcp)**.

| Field | Value |
|---|---|
| Name | `oracle-vm` (any label works) |
| URL | `https://<node>.<tailnet>.ts.net:8444/mcp` |
| Token | The content of `<token-file>`. Paste it, then clear the clipboard. |

Connect accepts any http(s) `/mcp` URL. Use the serve URL from 3.9.

**Lend to a session.** Open the openab-pty session, then choose **Give this session access to a
computer**.

| Field | Choice |
|---|---|
| Computer | `oracle-vm` |
| Profile | `observe` for any session that reads untrusted content. Use `owner` only for trusted tasks (section 5). |
| Lease | 1 to 24 hours |

Connect calls `POST /attach` on the node. The grant shows `idle` until the runtime dials back, then
`attached`.

**Check inside the session.** The agent's tool list should show the computer tools for the profile
you chose. For `observe`, that is `sys_info` and `screenshot` only.

---

## 7. Operations

### 7.1 Where the token lives

- Path: `<token-file>` (`/home/oabmcp/.config/oab-instance-mcp/token`), mode 600, owned by `oabmcp`.
- Read it only to paste into Connect. Never paste it into chat, a ticket or a log.

### 7.2 Rotate the token

1. Generate a new value in the same file with the command in 3.7. The file is replaced in place.
2. Restart the daemon (7.3). The daemon reads the token file at start.
3. In Connect, edit the `oracle-vm` computer and paste the new token.

Connect cannot reach the node until its stored token matches the file again. Rotation was not run on
the reference VM. These steps follow the installer's generation command and the daemon's start-time
read.

### 7.3 Restart

```sh
ouser systemctl --user restart oab-instance-mcp        # daemon
ouser systemctl --user restart oab-pw-mcp              # browser upstream
ouser systemctl --user status oab-instance-mcp oab-pw-mcp oab-seat --no-pager
```

Grants are kept in `grants.json` and resumed on start. A grant whose runtime has forgotten it, for
example after a pod replacement, ends with `handshake_rejected_401`. Lend the computer again.

### 7.4 Logs

```sh
sudo journalctl _SYSTEMD_USER_UNIT=oab-instance-mcp.service -n 100 --no-pager   # denies, attach events
sudo journalctl _SYSTEMD_USER_UNIT=oab-pw-mcp.service -n 100 --no-pager         # browser upstream
sudo journalctl _SYSTEMD_USER_UNIT=oab-seat.service -n 50 --no-pager            # sway
```

The `oabmcp` user cannot read these logs with `journalctl --user`. The admin account reads them from
the system journal, filtered by unit.

A line `deny POST /mcp : no Tailscale identity on request` means a request reached loopback without
going through serve. The daemon answers 401 for every denied request, whatever the reason.

### 7.5 Upgrade

1. Read the release notes. Check whether a unit file or the Playwright pin changes.
2. Keep the current binary for rollback before you touch the new release. Keep one older copy
   too: `.prev2` receives the old `.prev`, then `.prev` receives the current binary. Use absolute
   paths, because `~` is expanded by the admin shell before `sudo` runs:

   ```sh
   D=/home/oabmcp/.local/oab-instance-mcp
   if sudo -u oabmcp test -e $D/oab-instance-mcp.prev; then
     sudo -u oabmcp cp $D/oab-instance-mcp.prev $D/oab-instance-mcp.prev2
   fi
   sudo -u oabmcp cp $D/oab-instance-mcp $D/oab-instance-mcp.prev
   ```

3. Download and verify the new tarball. Set `V` to the new version (`0.8.1` below is a
   placeholder). The extracted binary is `/tmp/oab-instance-mcp-$V-linux-arm64/oab-instance-mcp`:

   ```sh
   V=0.8.1
   cd /tmp
   curl -fsSLO https://github.com/openabdev/instance-mcp/releases/download/v$V/oab-instance-mcp-$V-linux-arm64.tar.gz
   curl -fsSLO https://github.com/openabdev/instance-mcp/releases/download/v$V/oab-instance-mcp-$V-linux-arm64.tar.gz.sha256
   sha256sum -c oab-instance-mcp-$V-linux-arm64.tar.gz.sha256
   tar -xzf oab-instance-mcp-$V-linux-arm64.tar.gz
   ```

4. Stop the daemon, install the new binary, and start it again. Stopping first avoids replacing a
   running executable:

   ```sh
   ouser systemctl --user stop oab-instance-mcp
   sudo -u oabmcp install -m 755 /tmp/oab-instance-mcp-$V-linux-arm64/oab-instance-mcp \
     /home/oabmcp/.local/oab-instance-mcp/oab-instance-mcp
   ouser systemctl --user start oab-instance-mcp
   ```

5. Run the handshake (4.3) and confirm the tool count.
6. To roll back, stop the daemon, copy `oab-instance-mcp.prev` back over the binary, and start it:

   ```sh
   ouser systemctl --user stop oab-instance-mcp
   sudo -u oabmcp install -m 755 /home/oabmcp/.local/oab-instance-mcp/oab-instance-mcp.prev \
     /home/oabmcp/.local/oab-instance-mcp/oab-instance-mcp
   ouser systemctl --user start oab-instance-mcp
   ```

`.prev2` holds the binary from one upgrade earlier. To roll back to it, use the step 6 commands
with `.prev2` in place of `.prev`.

Before you rely on a rollback copy, compare its SHA-256 with the release it should match (3.4).

### 7.6 Stop exposing the node

```sh
sudo tailscale serve --https=8444 off
```

### 7.7 Gotchas found while installing

- **The installer exits 78 without `wlrctl`.** `scripts/install-linux.sh` checks for `tailscale`,
  `grim`, `wlrctl`, `wtype` and `python3`, and stops at the first missing one. The reference VM
  has no `wlrctl`, so the installer was not run there. The hand-written units in section 3 do the
  same job. `wlrctl` is not in the Ubuntu 24.04 archive (`apt-cache show wlrctl` finds nothing),
  so the installer cannot run on that release as written.
- **The installer exits 78 without a Wayland socket.** It needs a running desktop or
  `--headless-seat`. The `--headless-seat` path was not run on this VM. Section 3.5 is what runs
  here.
- **The installer's `sudo` steps need a sudo-capable user.** The service user has none. The
  installer then prints the `tailscale serve` command for you to run as the admin account.
- **Linger must be on.** Without `loginctl enable-linger oabmcp`, the user units stop at logout and
  do not start at boot. The reference VM has linger on.
- **A 401 on `127.0.0.1` is expected.** See 4.2.
- **The node cannot probe its own MagicDNS name.** From the VM, the serve URL returns `000`. From
  a laptop on the tailnet, the same URL returns 200. Probe from another machine.
- **arm64 sway was untested before this VM.** The reference VM runs sway 1.9 headless as
  `oab-seat`, with the pixman renderer. Screenshot and input need that seat running.
- **Node sits under `/opt`.** If the admin account removes it, Playwright stops.
- **Ubuntu's Chromium is a snap.** The daemon uses Playwright's own build instead (3.6).
- **`pkill -x` matches only the first 15 characters of a process name.** `pkill -x oab-instance-mcp`
  matches nothing. Use `pkill -f` from a plain shell. Inside `ssh host 'sh -c …'`, `pkill -f`
  matches the `sh -c` itself, so use `pkill -x` with a short name there.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401` on `127.0.0.1:8795` with a valid token | No `Tailscale-User-Login` header on loopback | Expected. Test through the serve URL (4.3). |
| Serve URL returns `000` from the node itself | The node cannot route to its own MagicDNS name | Probe from another tailnet machine |
| Installer exits 78, "missing: wlrctl" | Installer's hard requirement. `wlrctl` is not in the Ubuntu 24.04 archive. | Use the hand-written units in section 3 |
| Installer exits 78, "no Wayland socket" | No seat running | Use `--headless-seat`, or start a desktop. Check `oab-seat` is active. |
| Connect cannot reach the computer | Serve mapping missing, or daemon down | `sudo tailscale serve status`; `ouser systemctl --user status oab-instance-mcp` |
| Connect reports an auth failure | Token in Connect differs from `<token-file>` | Re-paste the token (7.2) |
| Calls refused on the serve URL | Caller login is not `<tailnet-login>` | Sign in as the allowed login, or change `MCP_ALLOW_LOGIN` and restart |
| `browser_*` tools missing | `oab-pw-mcp` down, or `MCP_UPSTREAM` unset | `ouser systemctl --user status oab-pw-mcp`; read its journal (7.4) |
| Browser fails with `No usable sandbox!` | AppArmor profile missing or not reloaded | Install the profile (3.6), then `sudo apparmor_parser -r` |
| Browser fails with "without having a XServer" | Chromium chose X11 on a headless seat | Check `pw-config.json` has `--ozone-platform=wayland` |
| Screenshot fails | Seat down, or wrong Wayland socket name | `ouser systemctl --user status oab-seat`; `ouser ls /run/user/$(id -u oabmcp)`; fix the name in both units |
| Pages render as empty boxes | No fonts installed | Install the font packages (3.1) |
| A camera or mic prompt blocks the page | Chromium policy missing | Install the policy (3.6), then restart `oab-pw-mcp` |
| Units stop after logout or reboot | Linger off | `sudo loginctl enable-linger oabmcp` |
| Lend returns HTTP 501 | Runtime side: the openab-pty pod has no tools listener | Set `PTY_TOOLS_LISTEN` on the openab-pty runtime (not this node) |
| Grant ends with `handshake_rejected_401` | Runtime forgot the grant, for example after a pod replacement | Lend the computer again |

---

## 9. Differences from the earlier investigation, and checks

### 9.1 VM state compared with the earlier report

| Item | Earlier report | Reference VM |
|---|---|---|
| Service user | Recommended: create one | `oabmcp` exists, no sudo, linger on |
| Daemon | Not installed | v0.8.0 installed. Binary SHA-256 matches the release. |
| Serve | "No serve config" | `:8444` maps to `127.0.0.1:8795`, tailnet only |
| Seat | Untested on arm64 | `oab-seat` (sway 1.9, headless) active |
| Browser upstream | Not set up | `oab-pw-mcp` active (0.0.82, Chromium 1246), `MCP_UPSTREAM` set |
| Node.js | Not installed | v26.13.0 under `/opt` |
| `wlrctl` | Missing | Still missing. The installer would stop at it. |
| Chromium policy | Not checked | Missing |
| Pre-upgrade backup | Not checked | `/home/oabmcp/pre-0.8-install-backup-…/oab-instance-mcp` has the **same SHA-256 as 0.8.0**. It is not a pre-0.8 binary, so it cannot serve as a rollback. |
| `MCP_ALLOW_LOGIN` | Recommended | Set to the owner's personal login (not reproduced here) |

### 9.2 Checks behind this page

- The v0.8.0 arm64 tarball matches its published `.sha256`.
- The binary on the VM matches the release binary, and `pw-mcp.sh` on the VM matches the release file.
- The tailnet handshake (4.3) returned 200, 202, and the 37-tool owner list.
- A request to loopback without the login header returned 401.
- `tailscale serve status` shows the 8444 mapping.
- The Linux profile source on `main` confirms the `observe` and `owner` lists in 5.1. These are the only two profiles since [#59](https://github.com/openabdev/openab-computer/issues/59).
