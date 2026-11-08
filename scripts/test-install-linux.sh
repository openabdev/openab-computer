#!/bin/bash
# Run scripts/install-linux.sh against a fake HOME with stubbed system tools and check the
# systemd user units it writes (#90). Linux only; touches nothing outside a temp dir: systemctl,
# loginctl, sudo, tailscale, curl and the desktop tools are stubs that only log their arguments.
#
#   scripts/test-install-linux.sh
#
# Checks: each written unit equals its expected text byte for byte (so a stray backtick or $( in
# an unquoted heredoc shows up as a diff), the systemctl/loginctl calls, the token file, and
# `systemd-analyze verify` on the units when systemd-analyze is installed.
# shellcheck disable=SC2016  # stub bodies and expected text are literal on purpose
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

# Release-tarball layout: the installer, pw-mcp.sh and the binary side by side.
PKG="$T/pkg"; mkdir -p "$PKG"
cp "$HERE/install-linux.sh" "$PKG/"
cp "$HERE/../poc/reverse-attach-linux/pw-mcp.sh" "$PKG/"
printf '#!/bin/sh\nexit 0\n' >"$PKG/oab-instance-mcp"
chmod 755 "$PKG/install-linux.sh" "$PKG/pw-mcp.sh" "$PKG/oab-instance-mcp"

STUBS="$T/stubs"; mkdir -p "$STUBS"
LOG="$T/calls.log"
stub() { # stub NAME [BODY]: logs "NAME args" to $LOG, then runs BODY (default: exit 0)
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$LOG" "${2:-exit 0}" >"$STUBS/$1"
  chmod 755 "$STUBS/$1"
}
for c in grim wlrctl wtype sway systemctl loginctl curl node npm npx chromium; do stub "$c"; done
stub sudo 'exit 1'                       # no passwordless sudo: the installer takes its no-sudo paths
stub fc-list 'echo "DejaVuSans.ttf: DejaVu Sans:style=Book"'
stub tailscale '[ "$1 $2" = "status --json" ] && echo '"'"'{"Self":{"UserID":7,"DNSName":"node.example.ts.net."},"User":{"7":{"LoginName":"ci-user"}}}'"'"'
exit 0'
# The installer finds the Wayland socket with `ls /run/user/<uid>`; answer for that path only.
REAL_LS="$(command -v ls)"
stub ls 'case "$1" in /run/user/*) printf "wayland-0\nwayland-1\n";; *) exec '"$REAL_LS"' "$@";; esac'

# run NAME ARGS...: install into a fresh fake HOME at $T/NAME/home.
run() {
  local name="$1"; shift
  local home="$T/$name/home"
  mkdir -p "$home/.local/oab-instance-mcp/pw-mcp/node_modules/.bin"
  printf '#!/bin/sh\n' >"$home/.local/oab-instance-mcp/pw-mcp/node_modules/.bin/playwright-mcp"
  chmod 755 "$home/.local/oab-instance-mcp/pw-mcp/node_modules/.bin/playwright-mcp"
  : >"$LOG"
  # stdin is /dev/null: a command substitution such as `bash` in a heredoc must not wait on it.
  if ! (cd "$PKG" && HOME="$home" USER="${USER:-$(id -un)}" PATH="$STUBS:$PATH" ./install-linux.sh "$@") </dev/null >"$T/$name/out" 2>&1; then
    cat "$T/$name/out" >&2; fail "$name: installer exited non-zero"
  fi
  cp "$LOG" "$T/$name/calls"
}

# expect NAME UNIT LOGIN PORT: diff the written unit against the expected text below.
expect() {
  local name="$1" unit="$2" login="$3" port="$4" home="$T/$1/home"
  local base="$home/.local/oab-instance-mcp" cfg="$home/.config/oab-instance-mcp"
  local got="$home/.config/systemd/user/$unit"
  [ -f "$got" ] || { fail "$name: $unit not written"; return; }
  sed -e "s|@BASE@|$base|g" -e "s|@CFG@|$cfg|g" -e "s|@LOGIN@|$login|g" -e "s|@PORT@|$port|g" \
      -e "s|@STUBS@|$STUBS|g" "$T/expected-$unit" >"$T/$name/want-$unit"
  diff -u "$T/$name/want-$unit" "$got" || fail "$name: $unit differs from the expected text"
}

# Expected units. @UPSTREAM@ becomes the browser line or an empty line (the installer writes
# an empty $UPSTREAM line with --no-browser).
cat >"$T/expected-oab-instance-mcp.service.in" <<'EOF'
[Unit]
Description=oab-instance-mcp (Linux hands node: /mcp + /attach)
After=graphical-session.target

[Service]
ExecStart=@BASE@/oab-instance-mcp
Environment=BIND=127.0.0.1:@PORT@
Environment=MCP_TOKEN_FILE=@CFG@/token
Environment=MCP_ALLOW_LOGIN=@LOGIN@
@UPSTREAM@
Environment=WAYLAND_DISPLAY=wayland-1
Environment=XDG_RUNTIME_DIR=/run/user/%U
Restart=always
RestartSec=2
# Apps opened via `bash` belong to the desktop, not to this daemon: a restart must not kill them.
KillMode=process

[Install]
WantedBy=default.target
EOF
cat >"$T/expected-oab-pw-mcp.service" <<'EOF'
[Unit]
Description=Playwright MCP for the oab-instance-mcp hands node (loopback :8794)
After=graphical-session.target oab-seat.service

[Service]
ExecStart=@BASE@/pw-mcp.sh
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=WAYLAND_DISPLAY=wayland-1
Environment=DISPLAY=:0
Environment=PW_CHROMIUM=@STUBS@/chromium
Environment=PW_NODE_BIN=@STUBS@
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
cat >"$T/expected-oab-seat.service" <<'EOF'
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
EOF

# 1. Defaults plus a headless seat: browser unit, login detected from `tailscale status`.
run browser --headless-seat
sed 's|@UPSTREAM@|Environment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp|' \
  "$T/expected-oab-instance-mcp.service.in" >"$T/expected-oab-instance-mcp.service"
expect browser oab-instance-mcp.service ci-user 8795
expect browser oab-pw-mcp.service ci-user 8795
expect browser oab-seat.service ci-user 8795
for want in "systemctl --user enable --now oab-seat.service" \
            "systemctl --user enable --now oab-pw-mcp.service" \
            "systemctl --user enable --now oab-instance-mcp.service" \
            "systemctl --user restart oab-instance-mcp.service" \
            "loginctl enable-linger"; do
  grep -qF "$want" "$T/browser/calls" || fail "browser: no call: $want"
done

# 2. --no-browser, explicit login and port: no browser unit, empty upstream line.
run nobrowser --no-browser --allow-login ci-other --port 9000
sed 's|@UPSTREAM@||' "$T/expected-oab-instance-mcp.service.in" >"$T/expected-oab-instance-mcp.service"
expect nobrowser oab-instance-mcp.service ci-other 9000
for u in oab-pw-mcp.service oab-seat.service; do
  [ ! -e "$T/nobrowser/home/.config/systemd/user/$u" ] || fail "nobrowser: $u written"
done
if grep -qF "oab-pw-mcp" "$T/nobrowser/calls"; then fail "nobrowser: oab-pw-mcp.service enabled"; fi

for name in browser nobrowser; do
  unit="$T/$name/home/.config/systemd/user/oab-instance-mcp.service"
  grep -qF '# Apps opened via `bash` belong to the desktop' "$unit" || fail "$name: KillMode comment mangled"
  tok="$T/$name/home/.config/oab-instance-mcp/token"
  if [ ! -s "$tok" ] || [ "$(stat -c %a "$tok")" != 600 ]; then fail "$name: token missing or not mode 600"; fi
done

# 3. systemd's own parser. The seat unit is skipped: its ExecStart (/usr/bin/sway) is not
# installed here, and verify rejects a missing executable.
if command -v systemd-analyze >/dev/null; then
  for name in browser nobrowser; do
    units=("$T/$name/home/.config/systemd/user/oab-instance-mcp.service")
    [ "$name" = nobrowser ] || units+=("$T/$name/home/.config/systemd/user/oab-pw-mcp.service")
    if ! out="$(HOME="$T/$name/home" systemd-analyze --user verify "${units[@]}" 2>&1)" || [ -n "$out" ]; then
      echo "$out" >&2; fail "$name: systemd-analyze verify"
    fi
  done
else
  echo "note: systemd-analyze not installed; skipped verify"
fi

[ "$FAIL" = 0 ] || exit 1
echo "install-linux.sh units: ok"
