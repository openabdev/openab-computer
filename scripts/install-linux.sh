#!/bin/bash
# Install the Linux hands node from a release tarball (run ON the target, as the desktop user).
#
#   V=<release version, e.g. 0.12.0>; A=$(dpkg --print-architecture)   # arm64 | amd64
#   curl -fsSL "https://github.com/openabdev/openab-computer/releases/download/v$V/oab-computer-$V-linux-$A.tar.gz" | tar xz
#   cd oab-computer-$V-linux-$A && ./install-linux.sh [--allow-login you@example.com] [--browser managed|none] [--headless-seat]
#
# Installs the binary and the daemon unit under your home, generates or keeps the bearer token and
# detects the Tailscale login. The browser (Playwright and Chromium) is a separate step the binary
# itself performs, `oab-computer browser install`: this script shows what it downloads
# (`oab-computer browser plan`) and asks first. It writes no browser unit and no MCP_UPSTREAM line.
# Idempotent. Full walkthrough: docs/linux-setup.md.
#
# --browser managed|none  managed: download and install the pinned browser after showing what it
#                         downloads, with no question (the flag is the consent); none: skip it.
#                         Without either flag, a terminal gets the question [Y/n] and no terminal
#                         means nothing is downloaded.
# --no-browser            same as --browser none (kept for existing automation)
# --yes                   agree to the browser download without asking. Runs no root action.
# --apply-system-changes  run the root actions this script prints, each with sudo (linger,
#                         tailscale serve, the AppArmor profile, missing libraries, fonts).
#                         Without it they are only printed. Nothing here runs sudo by itself.
# --headless-seat         for a server install with no desktop (Ubuntu Server, a mini PC in a
#                         closet): needs sway already installed (apt-get install sway; exit 78
#                         if missing) and runs it headless (one 1920x1080 virtual output) as
#                         user unit oab-seat.service. Boxes that already run a wlroots desktop
#                         (Raspberry Pi OS labwc, sway) do not need it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$HOME/.local/oab-computer"
CFG="$HOME/.config/oab-computer"
UNITS="$HOME/.config/systemd/user"
ALLOW_LOGIN=""; BROWSER_MODE=""; NO_BROWSER=0; YES=0; APPLY=0; PORT=8795; SERVE_PORT=8444; HEADLESS_SEAT=0
USER="${USER:-$(id -un)}"

usage_err() { echo "install-linux.sh: $*" >&2; exit 64; }
val() { [ "$1" -ge 2 ] || usage_err "$2 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-login) val $# "$1"; ALLOW_LOGIN="$2"; shift 2;;
    --browser) val $# "$1"; BROWSER_MODE="$2"; shift 2;;
    --no-browser) NO_BROWSER=1; shift;;
    --yes) YES=1; shift;;
    --apply-system-changes) APPLY=1; shift;;
    --headless-seat) HEADLESS_SEAT=1; shift;;   # no desktop on this box: run a headless sway as the seat
    --port) val $# "$1"; PORT="$2"; shift 2;;
    --serve-port) val $# "$1"; SERVE_PORT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 64;;
  esac
done
case "$BROWSER_MODE" in ""|managed|none) ;; *) usage_err "--browser takes managed or none, not '$BROWSER_MODE'";; esac
[ "$NO_BROWSER" = 0 ] || [ "$BROWSER_MODE" != managed ] || usage_err "--no-browser and --browser managed contradict each other"
[ "$NO_BROWSER" = 0 ] || [ "$YES" = 0 ] || usage_err "--no-browser and --yes contradict each other"
[ "$BROWSER_MODE" != none ] || [ "$YES" = 0 ] || usage_err "--browser none and --yes contradict each other"
[ "$NO_BROWSER" = 0 ] || BROWSER_MODE=none
# These values are written into unit files and shell commands: digits and a plain login only.
case "$PORT$SERVE_PORT" in *[!0-9]*|"") usage_err "--port and --serve-port take numbers";; esac
case "$ALLOW_LOGIN" in *[[:space:]]*|*[\"\'\\\$\`]*) usage_err "--allow-login must not contain spaces or quotes";; esac
case "$USER" in *[!A-Za-z0-9_.-]*|"") usage_err "unexpected user name '$USER'";; esac

need() { command -v "$1" >/dev/null || { echo "missing: $1 (apt-get install $2)" >&2; exit 78; }; }
need tailscale tailscale; need grim grim; need wtype wtype; need python3 python3
[ "$(id -u)" != 0 ] || { echo "run as the desktop user, not root" >&2; exit 64; }

# ---- root actions: collected, printed with their reason, run only with --apply-system-changes ----
ROOT_CMDS=(); ROOT_WHY=(); ROOT_FAILED=0
want_root() { ROOT_CMDS+=("$1"); ROOT_WHY+=("$2"); }
# flush_root: print the pending root actions; with --apply-system-changes run them with sudo.
# Sets ROOT_RAN=1 when something ran. The list is empty afterwards.
ROOT_RAN=0
flush_root() {
  local i rc
  [ "${#ROOT_CMDS[@]}" -gt 0 ] || return 0
  if [ "$APPLY" = 1 ]; then
    echo "root actions (--apply-system-changes):"
  else
    echo "root actions, NOT run (add --apply-system-changes to run them with sudo, or run them yourself):"
  fi
  for i in "${!ROOT_CMDS[@]}"; do
    if [ "$APPLY" = 1 ]; then
      echo "  running: ${ROOT_CMDS[$i]}"
      echo "    why: ${ROOT_WHY[$i]}"
      rc=0; sh -c "${ROOT_CMDS[$i]}" || rc=$?
      if [ "$rc" = 0 ]; then ROOT_RAN=1; else echo "  failed (exit $rc): ${ROOT_CMDS[$i]}" >&2; ROOT_FAILED=1; fi
    else
      echo "  ${ROOT_CMDS[$i]}"
      echo "    why: ${ROOT_WHY[$i]}"
    fi
  done
  ROOT_CMDS=(); ROOT_WHY=()
}

# ---- old units: read only. This script never stops, disables, edits or deletes any of them (D5, D10).
unit_live() { systemctl --user is-active --quiet "$1" >/dev/null 2>&1 || systemctl --user is-enabled --quiet "$1" >/dev/null 2>&1; }
# A 0.11 or earlier node runs oab-instance-mcp.service on the same port; it would fight the new
# oab-computer.service for it.
if unit_live oab-instance-mcp.service; then
  {
    echo "install: WARNING: the old unit oab-instance-mcp.service (0.11 or earlier) is still active or enabled."
    echo "It listens on port 8795 (the default); if the new oab-computer.service uses the same port ($PORT), they will fight over it."
    echo "This installer does not touch it. To stop it for good, run: systemctl --user disable --now oab-instance-mcp.service"
    echo "(a plain stop is not enough: it comes back at the next login or boot)."
  } >&2
  INSTANCE_UNIT_LIVE=1
else
  INSTANCE_UNIT_LIVE=0
fi
# An old external browser unit is an unauthenticated Playwright on 127.0.0.1:8794. The managed
# browser replaces it; the unit stays until a person disables it after checking the new one.
for U in oab-pw-mcp.service oab-computer-pw-mcp.service; do
  if unit_live "$U"; then
    {
      echo "install: WARNING: the old browser unit $U is still active or enabled."
      echo "It is a Playwright without authentication on 127.0.0.1:8794. The managed browser (oab-computer browser install) replaces it and does not use that port."
      echo "This installer did not touch it. Once 'oab-computer browser status' shows the managed browser working, turn the old one off for good with:"
      echo "  systemctl --user disable --now $U"
      echo "A plain stop is not enough: the unit comes back at the next login or boot. Removing the files comes later, after a soak: docs/linux-setup.md."
    } >&2
  fi
done
# An MCP_UPSTREAM line from an older install keeps pointing the daemon at that old listener. With a
# managed install present the managed browser wins over it. Nothing here edits such a line.
UPSTREAM_IN_UNIT=0
if [ -f "$UNITS/oab-computer.service" ] && grep -q '^Environment=MCP_UPSTREAM=' "$UNITS/oab-computer.service"; then UPSTREAM_IN_UNIT=1; fi
for D in "$UNITS/oab-computer.service.d" "$UNITS/oab-instance-mcp.service.d"; do
  [ -d "$D" ] || continue
  for F in "$D"/*.conf; do
    [ -f "$F" ] || continue
    if grep -q 'MCP_UPSTREAM' "$F"; then
      echo "install: note: $F sets MCP_UPSTREAM. It was left as it is. With a managed browser installed the managed one wins; remove that file at cutover (docs/linux-setup.md)." >&2
    fi
  done
done

mkdir -p "$BASE" "$CFG" "$UNITS"
if [ "$HEADLESS_SEAT" = 1 ]; then
  need sway sway
  mkdir -p "$HOME/.config/sway"
  [ -f "$HOME/.config/sway/config" ] || cat >"$HOME/.config/sway/config" <<'SWAY'
# Headless seat for the oab-computer hands node: one virtual 1080p output, no input devices.
output HEADLESS-1 resolution 1920x1080 position 0,0
default_border none
focus_follows_mouse no
SWAY
  cat >"$UNITS/oab-seat.service" <<'UNIT'
[Unit]
Description=Headless sway seat for the oab-computer hands node

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
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now oab-seat.service
  sleep 2
fi
# Which Wayland socket is the seat on? A desktop gives wayland-0; headless sway picks the first
# free name, usually wayland-1.
RT="/run/user/$(id -u)"
# shellcheck disable=SC2010  # the names matched are wayland-N; scripts/test-install-linux.sh stubs this ls
WL="$(ls "$RT" 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort -V | tail -1)"
[ -n "$WL" ] || { echo "no Wayland socket in $RT: start a wlroots desktop or pass --headless-seat" >&2; exit 78; }
echo "seat: $WL"

if [ -z "$ALLOW_LOGIN" ]; then
  ALLOW_LOGIN=$(tailscale status --json 2>/dev/null | python3 -c \
    'import sys,json;d=json.load(sys.stdin);print(d["User"][str(d["Self"]["UserID"])]["LoginName"])' 2>/dev/null || true)
  [ -n "$ALLOW_LOGIN" ] || { echo "cannot detect Tailscale login; is this node logged in? (or pass --allow-login)" >&2; exit 78; }
  case "$ALLOW_LOGIN" in *[[:space:]]*|*[\"\'\\\$\`]*) echo "unexpected Tailscale login; pass --allow-login" >&2; exit 78;; esac
fi

install -m 755 "$HERE/oab-computer" "$BASE/oab-computer"
# 0.11 and earlier kept the token under ~/.config/oab-instance-mcp. Copy it (source only, the old file
# stays) so existing clients keep working; generate a token only when neither file has one.
OLD_TOKEN="$HOME/.config/oab-instance-mcp/token"
if [ ! -s "$CFG/token" ] && [ -s "$OLD_TOKEN" ]; then
  mkdir -p "$CFG"; ( umask 077; cp "$OLD_TOKEN" "$CFG/token" ); chmod 600 "$CFG/token"
  echo "copied the bearer token from $OLD_TOKEN to $CFG/token"
fi
if [ ! -s "$CFG/token" ]; then
  head -c 32 /dev/urandom | base64 | tr -d '=+/\n' | head -c 40 > "$CFG/token"; chmod 600 "$CFG/token"
  echo "generated bearer token at $CFG/token"
fi

# The daemon unit. It carries no MCP_UPSTREAM line and there is no browser unit: the managed browser
# is started by the daemon as a transient unit. A unit from an older install that still has the line
# is left byte for byte as it is (this script did not write that line now, and the person doing the
# cutover removes it: docs/linux-setup.md).
# Unquoted heredoc so $VARS expand: escape any literal backtick or $ in it (#90).
# scripts/test-install-linux.sh diffs the written units against their expected text.
if [ "$UPSTREAM_IN_UNIT" = 1 ]; then
  echo "install: note: $UNITS/oab-computer.service still sets MCP_UPSTREAM (written by an older installer). It was left as it is, so --port and --allow-login did not change it. A managed browser wins over that line; remove the line at cutover (docs/linux-setup.md)." >&2
else
  cat >"$UNITS/oab-computer.service.new" <<UNIT
[Unit]
Description=oab-computer (Linux hands node: /mcp + /attach)
After=graphical-session.target

[Service]
ExecStart=$BASE/oab-computer
Environment=BIND=127.0.0.1:$PORT
Environment=MCP_TOKEN_FILE=$CFG/token
Environment=MCP_ALLOW_LOGIN=$ALLOW_LOGIN
Environment=WAYLAND_DISPLAY=$WL
Environment=XDG_RUNTIME_DIR=/run/user/%U
Restart=always
RestartSec=2
# Apps opened via \`bash\` belong to the desktop, not to this daemon: a restart must not kill them.
KillMode=process

[Install]
WantedBy=default.target
UNIT
  # A unit this script did not write (a hand-written one) is kept as a dated backup first.
  if [ -f "$UNITS/oab-computer.service" ] && ! cmp -s "$UNITS/oab-computer.service" "$UNITS/oab-computer.service.new"; then
    BAK="$UNITS/oab-computer.service.bak-$(date +%Y%m%d%H%M%S)"
    cp -p "$UNITS/oab-computer.service" "$BAK"
    echo "install: the existing $UNITS/oab-computer.service differed and was replaced; the old copy is at $BAK" >&2
  fi
  mv "$UNITS/oab-computer.service.new" "$UNITS/oab-computer.service"
fi

systemctl --user daemon-reload
systemctl --user enable --now oab-computer.service
systemctl --user restart oab-computer.service

# ---- the browser (Playwright and Chromium), a separate and optional step --------------------------
BROWSER_WANTED=0; BROWSER_FAILED=0; BROWSER_READY=0; PRE_ACTIONS=0
browser_later() { echo "To install the browser later: $BASE/oab-computer browser install"; }
# The consent text: exactly what `oab-computer browser plan` prints (what is downloaded, from where,
# how much, and where it goes).
show_plan() {
  local plan
  plan="$("$BASE/oab-computer" browser plan)" || {
    echo "browser: could not read the plan ($BASE/oab-computer browser plan failed); skipped" >&2
    BROWSER_WANTED=1; BROWSER_FAILED=1; return 1
  }
  echo; echo "$plan"; echo
}
browser_step() {
  local ans rc cmd why
  case "$BROWSER_MODE" in none) echo "browser: skipped (--browser none)"; return 0;; esac
  if [ "$BROWSER_MODE" = managed ] || [ "$YES" = 1 ]; then
    BROWSER_WANTED=1
    show_plan || return 0
  elif [ -t 0 ]; then
    show_plan || return 0
    printf 'Download and install the browser now? [Y/n] '
    ans=""; read -r ans || true
    case "$ans" in ""|y|Y|yes|YES|Yes) BROWSER_WANTED=1;; *) echo "browser: skipped"; browser_later; return 0;; esac
  else
    echo "browser: not downloaded (no terminal, and neither --browser managed nor --yes was given)."
    browser_later
    return 0
  fi
  "$BASE/oab-computer" browser preflight || true
  # Root actions the preflight found (the AppArmor profile for your own data path, missing
  # libraries). They are printed; with --apply-system-changes they run before the install, so its
  # health check sees them. Without it the install still runs, and says what to do if it fails.
  while IFS=$'\t' read -r cmd why; do
    [ -n "$cmd" ] || continue
    want_root "$cmd" "$why"
  done < <("$BASE/oab-computer" browser preflight --root-actions 2>/dev/null || true)
  PRE_ACTIONS=${#ROOT_CMDS[@]}
  ROOT_RAN=0
  flush_root
  if [ "$ROOT_RAN" = 1 ]; then "$BASE/oab-computer" browser preflight || true; fi
  # Fonts: a server install has none, and pages render as boxes. Printed at the end with the rest.
  if ! fc-list 2>/dev/null | grep -qiE "dejavu|liberation|noto" && command -v apt-get >/dev/null; then
    want_root "sudo apt-get install -y fonts-dejavu-core fonts-liberation fonts-noto-cjk fonts-noto-color-emoji" "this node has no fonts, and pages would render as boxes"
  fi
  rc=0; "$BASE/oab-computer" browser install || rc=$?
  if [ "$rc" = 0 ]; then
    BROWSER_READY=1
  else
    echo "browser: install failed (exit $rc); the daemon and the token are in place." >&2
    if [ "$PRE_ACTIONS" -gt 0 ] && [ "$APPLY" = 0 ]; then
      echo "If it failed on the sandbox or on missing libraries, run the root actions printed above (or re-run with --apply-system-changes)." >&2
    fi
    echo "Fix what is reported above, then: $BASE/oab-computer browser install" >&2
    BROWSER_FAILED=1
  fi
}
browser_step
# The daemon picks its browser backend once, at start. It started before the browser existed, so
# restart it now: a fresh node gains the browser_* tools, and a node with a stale MCP_UPSTREAM line
# switches to the managed browser (D5).
if [ "$BROWSER_READY" = 1 ]; then systemctl --user restart oab-computer.service; fi

# ---- the remaining root actions: printed, or run with --apply-system-changes -----------------------
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != yes ]; then
  want_root "sudo loginctl enable-linger $USER" "the daemon (and the browser it starts) keep running after you log out and start again at boot"
fi
want_root "sudo tailscale serve --bg --https=$SERVE_PORT http://127.0.0.1:$PORT" "publishes the daemon to your tailnet over HTTPS (tailnet only)"
flush_root

sleep 1
if [ "$INSTANCE_UNIT_LIVE" = 1 ]; then
  echo "daemon: not checked. The old unit oab-instance-mcp.service may hold port $PORT; turn it off as warned above, then run: systemctl --user restart oab-computer.service" >&2
else
  curl -fsS "127.0.0.1:$PORT/healthz" >/dev/null && echo "daemon: ok"
fi
DNS=$(tailscale status --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
echo "MCP URL : https://$DNS:$SERVE_PORT/mcp"
echo "token   : $CFG/token   (allow-login: $ALLOW_LOGIN)"
echo "lend    : POST https://$DNS:$SERVE_PORT/attach   (see docs/linux-setup.md)"
if [ "$BROWSER_READY" = 1 ]; then
  echo "Sign in once (a login that the browser keeps): ssh -t <this node> '$BASE/oab-computer browser signin'   (see docs/linux-setup.md)"
fi
if [ "$ROOT_FAILED" = 1 ]; then exit 1; fi
if [ "$BROWSER_WANTED" = 1 ] && [ "$BROWSER_FAILED" = 1 ]; then exit 1; fi
