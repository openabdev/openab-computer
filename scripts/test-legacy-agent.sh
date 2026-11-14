#!/bin/bash
# The installers only WARN about a 0.11-or-earlier agent (macOS LaunchAgent dev.openab.instance-mcp,
# Linux unit oab-instance-mcp.service). They must print the commands to remove it and must never run
# them. This test drives both installers against stub launchctl / systemctl that log every call and
# fail any call other than a read-only query, in a fake HOME. It touches no real launchd, systemd,
# Tailscale or user directory.
#
#   scripts/test-legacy-agent.sh
#
# macOS cases run only where /usr/libexec/PlistBuddy exists; Linux cases run wherever bash does.
# shellcheck disable=SC2016  # stub bodies are literal on purpose
# shellcheck disable=SC2015  # `A && ok || fail`: ok() always succeeds, so this is an if/else
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }
ok() { echo "ok: $*"; }
has() { grep -qF -- "$2" "$1"; }
has_line() { grep -qxF -- "$2" "$1"; }

OLD_LABEL=dev.openab.instance-mcp
OLD_PW_LABEL=dev.openab.instance-mcp.pw-mcp
OLD_SENTINEL='OLD-AGENT-FILE-MUST-STAY-BYTE-IDENTICAL'

# ---------------------------------------------------------------- macOS
if [ -x /usr/libexec/PlistBuddy ]; then
  UID_=$(id -u)
  printf '#!/bin/sh\necho 0.0.0\n' >"$T/fakebin"; chmod 755 "$T/fakebin"
  APP="$T/oab-computer.app"
  "$ROOT/scripts/assemble-app.sh" "$T/fakebin" "$APP" 0.0.0 >/dev/null || { echo "assemble-app failed" >&2; exit 1; }
  # The stub answers `print gui/<uid>/<label>` from $STUB_LOADED (comma list). Anything else exits 99.
  cat >"$T/launchctl" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG"
if [ "$1" = print ]; then
  label="${2##*/}"
  case ",$STUB_LOADED," in *",$label,"*) exit 0;; esac
  exit 1
fi
exit 99
EOF
  chmod 755 "$T/launchctl"

  mac_case() { # mac_case NAME LOADED_LABELS WITH_OLD_PLIST(0|1)
    local name="$1" loaded="$2" withplist="$3" home="$T/mac-$1/home"
    mkdir -p "$home/Library/LaunchAgents"
    if [ "$withplist" = 1 ]; then printf '%s' "$OLD_SENTINEL" >"$home/Library/LaunchAgents/$OLD_LABEL.plist"; fi
    : >"$T/mac-$name.log"
    ALLOW_UNSIGNED=1 INSTALL_HOME="$home" SKIP_LAUNCH=1 SKIP_TAILSCALE=1 \
      LEGACY_LAUNCHCTL="$T/launchctl" STUB_LOG="$T/mac-$name.log" STUB_LOADED="$loaded" \
      "$APP/Contents/Resources/install-prebuilt.sh" "$APP" --allow-login test@example.invalid \
      >"$T/mac-$name.out" 2>"$T/mac-$name.err"
    local rc=$?
    [ "$rc" = 0 ] || { cat "$T/mac-$name.err" >&2; fail "mac $name: installer exited $rc"; }
    [ -f "$home/Library/LaunchAgents/dev.openab.computer.plist" ] || fail "mac $name: new agent plist not written"
    # No mutating launchctl call, whatever the case.
    if grep -qv '^print ' "$T/mac-$name.log"; then fail "mac $name: launchctl called with a non-print subcommand: $(grep -v '^print ' "$T/mac-$name.log" | head -1)"; fi
    if [ "$withplist" = 1 ]; then
      [ "$(cat "$home/Library/LaunchAgents/$OLD_LABEL.plist")" = "$OLD_SENTINEL" ] || fail "mac $name: the old plist was changed"
    fi
  }

  mac_case clean "" 0
  if grep -q 'instance-mcp' "$T/mac-clean.err" "$T/mac-clean.out"; then fail "mac clean: warned although no old agent exists"; else ok "mac: no old agent, no warning"; fi

  mac_case loaded "$OLD_LABEL" 1
  e="$T/mac-loaded.err"
  has "$e" "WARNING" && has "$e" "port 8795" \
    && has_line "$e" "  launchctl bootout gui/$UID_/$OLD_LABEL" \
    && has "$e" "rm \"$T/mac-loaded/home/Library/LaunchAgents/$OLD_LABEL.plist\"" \
    && ok "mac: loaded old agent warns with the port, bootout and rm commands" \
    || { cat "$e" >&2; fail "mac loaded: warning text incomplete"; }
  if has_line "$e" "  launchctl bootout gui/$UID_/$OLD_PW_LABEL"; then fail "mac loaded: pw-mcp commands printed although it is not loaded"; fi

  mac_case pwonly "$OLD_PW_LABEL" 0
  e="$T/mac-pwonly.err"
  has_line "$e" "  launchctl bootout gui/$UID_/$OLD_PW_LABEL" \
    && ! has_line "$e" "  launchctl bootout gui/$UID_/$OLD_LABEL" \
    && ok "mac: only the old pw-mcp agent loaded prints only its commands" \
    || { cat "$e" >&2; fail "mac pwonly: wrong commands"; }

  mac_case plistonly "" 1
  has "$T/mac-plistonly.err" "WARNING" && ok "mac: old plist on disk but not loaded still warns" || fail "mac plistonly: no warning"
else
  echo "skip: macOS cases (no PlistBuddy)"
fi

# ---------------------------------------------------------------- Linux
PKG="$T/pkg"; mkdir -p "$PKG"
cp "$HERE/install-linux.sh" "$PKG/"
cp "$ROOT/poc/reverse-attach-linux/pw-mcp.sh" "$PKG/"
printf '#!/bin/sh\nexit 0\n' >"$PKG/oab-computer"
chmod 755 "$PKG/install-linux.sh" "$PKG/pw-mcp.sh" "$PKG/oab-computer"
STUBS="$T/stubs"; mkdir -p "$STUBS"
LOG="$T/calls.log"
stub() { printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$LOG" "${2:-exit 0}" >"$STUBS/$1"; chmod 755 "$STUBS/$1"; }
for c in grim wlrctl wtype sway loginctl curl node npm npx chromium; do stub "$c"; done
stub sudo 'exit 1'
stub fc-list 'echo "DejaVuSans.ttf: DejaVu Sans:style=Book"'
stub tailscale '[ "$1 $2" = "status --json" ] && echo '"'"'{"Self":{"UserID":7,"DNSName":"node.example.ts.net."},"User":{"7":{"LoginName":"ci-user"}}}'"'"'
exit 0'
REAL_LS="$(command -v ls)"
stub ls 'case "$1" in /run/user/*) printf "wayland-0\n";; *) exec '"$REAL_LS"' "$@";; esac'
# systemctl: is-active / is-enabled answer from $STUB_UNITS (comma list); everything else exits 0 and
# is logged. The test then checks that nothing but queries ever named an old unit.
stub systemctl 'case "$*" in "--user is-active"*|"--user is-enabled"*) unit="${@: -1}"; case ",$STUB_UNITS," in *",$unit,"*) exit 0;; esac; exit 1;; esac; exit 0'

linux_case() { # linux_case NAME UNITS_ACTIVE WITH_OLD_UNIT_FILES(0|1)
  local name="$1" units="$2" withfiles="$3" home="$T/lin-$1/home"
  mkdir -p "$home/.config/systemd/user" "$home/.local/oab-computer/pw-mcp/node_modules/.bin"
  printf '#!/bin/sh\n' >"$home/.local/oab-computer/pw-mcp/node_modules/.bin/playwright-mcp"
  chmod 755 "$home/.local/oab-computer/pw-mcp/node_modules/.bin/playwright-mcp"
  if [ "$withfiles" = 1 ]; then
    printf '%s' "$OLD_SENTINEL" >"$home/.config/systemd/user/oab-instance-mcp.service"
    printf '%s' "$OLD_SENTINEL" >"$home/.config/systemd/user/oab-pw-mcp.service"
  fi
  : >"$LOG"
  (cd "$PKG" && HOME="$home" USER="${USER:-$(id -un)}" PATH="$STUBS:$PATH" STUB_UNITS="$units" \
     ./install-linux.sh --no-browser) </dev/null >"$T/lin-$name.out" 2>"$T/lin-$name.err"
  local rc=$?
  cp "$LOG" "$T/lin-$name.calls"
  [ "$rc" = 0 ] || { cat "$T/lin-$name.err" >&2; fail "linux $name: installer exited $rc"; }
  [ -f "$home/.config/systemd/user/oab-computer.service" ] || fail "linux $name: new unit not written"
  # Only is-active / is-enabled may name an old unit.
  if grep -E 'oab-instance-mcp|oab-pw-mcp' "$T/lin-$name.calls" | grep -vqE '^systemctl --user is-(active|enabled) --quiet '; then
    fail "linux $name: a non-query systemctl call named an old unit: $(grep -E 'oab-instance-mcp|oab-pw-mcp' "$T/lin-$name.calls" | grep -vE '^systemctl --user is-(active|enabled) --quiet ' | head -1)"
  fi
  if [ "$withfiles" = 1 ]; then
    for u in oab-instance-mcp.service oab-pw-mcp.service; do
      [ "$(cat "$home/.config/systemd/user/$u" 2>/dev/null)" = "$OLD_SENTINEL" ] || fail "linux $name: old unit file $u was changed or removed"
    done
  fi
}

linux_case clean "" 0
if grep -q 'instance-mcp\|oab-pw-mcp' "$T/lin-clean.err" "$T/lin-clean.out"; then fail "linux clean: warned although no old unit exists"; else ok "linux: no old unit, no warning"; fi

linux_case active "oab-instance-mcp.service" 1
e="$T/lin-active.err"
home="$T/lin-active/home"
has "$e" "WARNING" && has "$e" "port 8795" \
  && has_line "$e" "  systemctl --user disable --now oab-instance-mcp.service" \
  && has "$e" "rm $home/.config/systemd/user/oab-instance-mcp.service" \
  && has_line "$e" "  systemctl --user daemon-reload" \
  && ok "linux: active old unit warns with the port, disable and rm commands" \
  || { cat "$e" >&2; fail "linux active: warning text incomplete"; }

linux_case pwonly "oab-pw-mcp.service" 1
has "$T/lin-pwonly.err" "WARNING" && has "$T/lin-pwonly.err" "oab-pw-mcp.service" \
  && ok "linux: old pw-mcp unit alone warns" || fail "linux pwonly: no warning"

[ "$FAIL" = 0 ] && echo "legacy-agent: all checks passed" || { echo "legacy-agent: FAILED" >&2; exit 1; }
